defmodule Skein.Runtime.Llm do
  @moduledoc """
  Provider-agnostic LLM client for Skein.

  Provides `chat/4` for unstructured text responses, `json/5` for
  schema-constrained structured responses, `stream/5` for streaming
  chunked responses, and `embed/3` for text embeddings. Called by compiled
  Skein code when `llm.chat(...)`, `llm.json(...)`, `llm.stream(...)`,
  or `llm.embed(...)` effect calls are encountered.

  Uses a pluggable backend system:
  - `Skein.Runtime.Llm.TestBackend` — deterministic responses for testing
  - `Skein.Runtime.Llm.StreamingTestBackend` — deterministic streaming for testing
  - Custom backends implement the `Skein.Runtime.Llm.Backend` behaviour

  Every operation is:
  1. Checked against the module's declared `model` capabilities
  2. Traced with model, token counts, and timing metadata
  3. Returns `{:ok, result}` or `{:error, %Llm.Error{}}`
  """

  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.Response
  alias Skein.Runtime.Trace

  @default_truncate_length 200

  @doc """
  Sends an unstructured chat request to the LLM.

  Returns `{:ok, response_text}` or `{:error, %Llm.Error{}}`.
  """
  @spec chat(String.t(), String.t(), any(), [map()]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def chat(model, system, input, capabilities)
      when is_binary(model) and is_binary(system) and is_list(capabilities) do
    with_enriched_span(%{kind: :llm, method: :chat, model: model}, system, input, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
          backend = get_backend()
          backend.chat(model, system, input)

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
  end

  @doc """
  Sends a schema-constrained JSON request to the LLM.

  The `schema` is a JSON Schema map that the response must conform to.
  The response is parsed as JSON and validated against the schema.

  Returns `{:ok, parsed_map}` or `{:error, %Llm.Error{}}`.
  """
  @spec json(String.t(), String.t(), any(), map(), [map()]) ::
          {:ok, map()} | {:error, Error.t()}
  def json(model, system, input, schema, capabilities)
      when is_binary(model) and is_binary(system) and is_map(schema) and is_list(capabilities) do
    with_enriched_span(%{kind: :llm, method: :json, model: model}, system, input, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
          backend = get_backend()

          case backend.json(model, system, input, schema) do
            {:ok, %Response{text: raw_text} = resp} ->
              case parse_json_response(raw_text) do
                {:ok, parsed} -> {:ok, parsed, resp}
                error -> error
              end

            {:ok, raw_text} when is_binary(raw_text) ->
              parse_json_response(raw_text)

            {:ok, %{} = parsed} ->
              {:ok, parsed}

            {:error, _} = error ->
              error
          end

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
  end

  @doc """
  Sends a streaming request to the LLM, delivering chunks via `on_chunk` callback.

  The `on_chunk` callback receives each text chunk as it arrives.
  The full response is assembled from all chunks and returned.

  When called from compiled Skein code without a callback (e.g. `llm.stream(model, system, input)`),
  the codegen passes a no-op callback and returns the assembled response.

  Returns `{:ok, assembled_text}` or `{:error, %Llm.Error{}}`.
  """
  @spec stream(String.t(), String.t(), any(), function(), [map()]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def stream(model, system, input, on_chunk, capabilities)
      when is_binary(model) and is_binary(system) and is_function(on_chunk, 1) and
             is_list(capabilities) do
    with_enriched_span(%{kind: :llm, method: :stream, model: model}, system, input, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
          backend = get_backend()

          case call_stream(backend, model, system, input, on_chunk) do
            {:ok, chunks} when is_list(chunks) ->
              Enum.each(chunks, on_chunk)
              {:ok, Enum.join(chunks, "")}

            {:error, _} = error ->
              error
          end

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
  end

  @doc """
  Generates an embedding vector for the given input text.

  Returns `{:ok, [float()]}` or `{:error, %Llm.Error{}}`.
  The vector dimensionality depends on the model used.
  """
  @spec embed(String.t(), String.t(), [map()]) ::
          {:ok, [float()]} | {:error, Error.t()}
  def embed(model, input, capabilities)
      when is_binary(model) and is_binary(input) and is_list(capabilities) do
    Trace.with_span(%{kind: :llm, method: :embed, model: model}, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
          backend = get_backend()
          call_embed(backend, model, input)

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
  end

  @doc """
  Sets the active LLM backend. Useful for testing.

  Accepts a module atom or a `{module, config}` tuple for dynamic backends.
  """
  @spec set_backend(module() | {module(), any()}) :: :ok
  def set_backend(backend) when is_atom(backend) do
    :persistent_term.put(:skein_llm_backend, backend)
    :ok
  end

  def set_backend({module, _config} = backend) when is_atom(module) do
    :persistent_term.put(:skein_llm_backend, backend)
    :ok
  end

  @doc """
  Returns the currently active LLM backend.
  """
  @spec get_backend() :: module() | {module(), any()}
  def get_backend do
    try do
      :persistent_term.get(:skein_llm_backend)
    rescue
      ArgumentError ->
        # Fall back to Application config, then TestBackend
        Application.get_env(:skein_runtime, :llm_backend, Skein.Runtime.Llm.TestBackend)
    end
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  # Call stream on the backend, handling both module and {module, config} tuple backends
  defp call_stream({module, config}, model, system, input, _on_chunk) do
    module.stream(model, system, input, config)
  end

  defp call_stream(module, model, system, input, _on_chunk) when is_atom(module) do
    module.stream(model, system, input)
  end

  # Call embed on the backend, handling both module and {module, config} tuple backends
  defp call_embed({module, _config}, model, input) do
    module.embed(model, input)
  end

  defp call_embed(module, model, input) when is_atom(module) do
    module.embed(model, input)
  end

  defp check_model_capability(model, capabilities) do
    model_caps =
      Enum.filter(capabilities, fn cap ->
        cap.kind == "model"
      end)

    case model_caps do
      [] ->
        {:error, "Model capability 'model(...)' not declared. LLM calls blocked."}

      caps ->
        # Check if the requested model matches any declared capability.
        # Capability params: ["provider", "model"] or ["model"] (single param).
        match =
          Enum.any?(caps, fn cap ->
            case cap.params do
              [] -> true
              [single] -> single == model
              [_provider, declared_model | _] -> declared_model == model
            end
          end)

        if match do
          :ok
        else
          declared =
            caps
            |> Enum.map(fn cap -> Enum.join(cap.params, "/") end)
            |> Enum.join(", ")

          {:error, "Model '#{model}' not declared in capabilities. Declared models: #{declared}"}
        end
    end
  end

  defp parse_json_response(raw_text) do
    case Jason.decode(raw_text) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, %Jason.DecodeError{} = decode_error} ->
        {:error, Error.parse_failed(raw_text, "JSON", Exception.message(decode_error))}
    end
  end

  # -- Enriched span recording ---------------------------------------------

  defp with_enriched_span(metadata, system, input, fun) do
    truncate = @default_truncate_length
    input_str = if is_binary(input), do: input, else: inspect(input)
    input_type = if is_binary(input), do: :text, else: :structured

    span_meta =
      Map.merge(metadata, %{
        system: Response.truncate(system, truncate),
        input: Response.truncate(input_str, truncate),
        input_type: input_type
      })

    start = System.monotonic_time(:microsecond)

    try do
      result = fun.()
      duration = System.monotonic_time(:microsecond) - start

      {outcome, caller_result, response_meta} = extract_result_meta(result, truncate)

      span =
        span_meta
        |> Map.merge(response_meta)
        |> Map.merge(%{duration_us: duration, outcome: outcome})

      Trace.record_span(span)
      caller_result
    rescue
      exception ->
        duration = System.monotonic_time(:microsecond) - start

        span =
          Map.merge(span_meta, %{
            duration_us: duration,
            outcome: :error,
            error: Exception.message(exception)
          })

        Trace.record_span(span)
        reraise exception, __STACKTRACE__
    end
  end

  # Extract trace metadata from backend result, normalizing Response vs raw strings
  defp extract_result_meta({:ok, %Response{} = resp}, truncate) do
    meta = %{
      output: Response.truncate(resp.text, truncate),
      actual_model: resp.model,
      stop_reason: resp.stop_reason
    }

    meta =
      if resp.usage do
        Map.put(meta, :usage, %{
          input_tokens: resp.usage.input_tokens,
          output_tokens: resp.usage.output_tokens
        })
      else
        meta
      end

    {:ok, {:ok, resp.text}, meta}
  end

  # json method returns {parsed, response} as a 3-tuple
  defp extract_result_meta({:ok, parsed, %Response{} = resp}, truncate) do
    meta = %{
      output: Response.truncate(resp.text || inspect(parsed), truncate),
      actual_model: resp.model,
      stop_reason: resp.stop_reason
    }

    meta =
      if resp.usage do
        Map.put(meta, :usage, %{
          input_tokens: resp.usage.input_tokens,
          output_tokens: resp.usage.output_tokens
        })
      else
        meta
      end

    {:ok, {:ok, parsed}, meta}
  end

  defp extract_result_meta({:ok, text} = result, truncate) when is_binary(text) do
    {:ok, result, %{output: Response.truncate(text, truncate)}}
  end

  defp extract_result_meta({:ok, _} = result, _truncate) do
    {:ok, result, %{}}
  end

  defp extract_result_meta({:error, _} = result, _truncate) do
    {:error, result, %{}}
  end
end

defmodule Skein.Runtime.Llm.Error do
  @moduledoc """
  Structured error type for LLM operations.

  Matches the Skein `LlmError` enum with variants:
  - `:parse_failed` — response couldn't be parsed as expected type
  - `:refused` — LLM refused to generate a response
  - `:rate_limit` — rate limited, includes retry-after duration
  - `:timeout` — request timed out
  - `:content_filtered` — response was filtered by content policy
  - `:invalid_schema` — response didn't match the expected JSON schema
  - `:provider_error` — provider returned an error
  - `:capability_error` — missing capability declaration
  """

  defstruct [:kind, :detail]

  @type kind ::
          :parse_failed
          | :refused
          | :rate_limit
          | :timeout
          | :content_filtered
          | :invalid_schema
          | :provider_error
          | :capability_error

  @type t :: %__MODULE__{
          kind: kind(),
          detail: map()
        }

  @spec parse_failed(String.t(), String.t(), String.t()) :: t()
  def parse_failed(raw, expected_type, parse_error) do
    %__MODULE__{
      kind: :parse_failed,
      detail: %{raw: raw, expected_type: expected_type, parse_error: parse_error}
    }
  end

  @spec refused(String.t()) :: t()
  def refused(reason) do
    %__MODULE__{kind: :refused, detail: %{reason: reason}}
  end

  @spec rate_limit(non_neg_integer()) :: t()
  def rate_limit(retry_after_ms) do
    %__MODULE__{kind: :rate_limit, detail: %{retry_after_ms: retry_after_ms}}
  end

  @spec timeout(non_neg_integer()) :: t()
  def timeout(elapsed_ms) do
    %__MODULE__{kind: :timeout, detail: %{elapsed_ms: elapsed_ms}}
  end

  @spec content_filtered(String.t()) :: t()
  def content_filtered(filter) do
    %__MODULE__{kind: :content_filtered, detail: %{filter: filter}}
  end

  @spec invalid_schema([String.t()]) :: t()
  def invalid_schema(violations) do
    %__MODULE__{kind: :invalid_schema, detail: %{violations: violations}}
  end

  @spec provider_error(String.t(), String.t()) :: t()
  def provider_error(code, message) do
    %__MODULE__{kind: :provider_error, detail: %{code: code, message: message}}
  end

  @spec capability_error(String.t()) :: t()
  def capability_error(reason) do
    %__MODULE__{kind: :capability_error, detail: %{reason: reason}}
  end
end

defmodule Skein.Runtime.Llm.Backend do
  @moduledoc """
  Behaviour for LLM provider backends.
  """

  @callback chat(model :: String.t(), system :: String.t(), input :: any()) ::
              {:ok, String.t()} | {:error, Skein.Runtime.Llm.Error.t()}

  @callback json(model :: String.t(), system :: String.t(), input :: any(), schema :: map()) ::
              {:ok, String.t() | map()} | {:error, Skein.Runtime.Llm.Error.t()}

  @callback stream(model :: String.t(), system :: String.t(), input :: any()) ::
              {:ok, [String.t()]} | {:error, Skein.Runtime.Llm.Error.t()}

  @callback embed(model :: String.t(), input :: String.t()) ::
              {:ok, [float()]} | {:error, Skein.Runtime.Llm.Error.t()}

  @optional_callbacks [stream: 3, embed: 2]
end

defmodule Skein.Runtime.Llm.TestBackend do
  @moduledoc """
  Test backend that returns deterministic responses.
  """

  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, input) do
    {:ok, "Test response for: #{inspect(input)}"}
  end

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok, %{"action" => "approve", "amount" => 100, "reason" => "Test decision"}}
  end

  @impl true
  def embed(_model, input) do
    # Generate a deterministic 8-dimensional embedding vector from the input hash.
    # Same input always produces the same vector; different inputs produce different vectors.
    hash = :erlang.phash2(input, 1_000_000)

    vector =
      for i <- 0..7 do
        # Seed-based deterministic float in [-1.0, 1.0]
        :erlang.phash2({hash, i}, 2_000_001) / 1_000_000 - 1.0
      end

    {:ok, vector}
  end
end

defmodule Skein.Runtime.Llm.FailingBackend do
  @moduledoc """
  Test backend that always returns provider errors.
  """

  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input) do
    {:error, Skein.Runtime.Llm.Error.provider_error("500", "Internal server error")}
  end

  @impl true
  def json(_model, _system, _input, _schema) do
    {:error, Skein.Runtime.Llm.Error.provider_error("500", "Internal server error")}
  end

  @impl true
  def embed(_model, _input) do
    {:error, Skein.Runtime.Llm.Error.provider_error("500", "Embedding failed")}
  end
end

defmodule Skein.Runtime.Llm.InvalidJsonBackend do
  @moduledoc """
  Test backend that returns invalid JSON text.
  """

  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input) do
    {:ok, "not valid json at all"}
  end

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok, "this is not { valid json"}
  end
end

defmodule Skein.Runtime.Llm.StreamingTestBackend do
  @moduledoc """
  Test backend that returns deterministic streaming chunks.
  """

  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, input) do
    {:ok, "Test response for: #{inspect(input)}"}
  end

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok, %{"action" => "approve", "amount" => 100, "reason" => "Test decision"}}
  end

  @impl true
  def stream(_model, _system, _input) do
    {:ok, ["Hello, ", "world!"]}
  end
end

defmodule Skein.Runtime.Llm.EmptyStreamBackend do
  @moduledoc """
  Test backend that streams zero chunks (empty response).
  """

  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input), do: {:ok, ""}

  @impl true
  def json(_model, _system, _input, _schema), do: {:ok, %{}}

  @impl true
  def stream(_model, _system, _input) do
    {:ok, []}
  end
end

defmodule Skein.Runtime.Llm.FailingStreamBackend do
  @moduledoc """
  Test backend that returns errors during streaming.
  """

  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input) do
    {:error, Skein.Runtime.Llm.Error.provider_error("500", "Internal server error")}
  end

  @impl true
  def json(_model, _system, _input, _schema) do
    {:error, Skein.Runtime.Llm.Error.provider_error("500", "Internal server error")}
  end

  @impl true
  def stream(_model, _system, _input) do
    {:error, Skein.Runtime.Llm.Error.provider_error("500", "Stream failed")}
  end
end

defmodule Skein.Runtime.Llm.DynamicStreamBackend do
  @moduledoc """
  Test backend that streams a configurable list of chunks.
  Used with `set_backend({DynamicStreamBackend, chunks})`.
  """

  @spec stream(String.t(), String.t(), any(), [String.t()]) ::
          {:ok, [String.t()]}
  def stream(_model, _system, _input, chunks) when is_list(chunks) do
    {:ok, chunks}
  end
end
