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

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.LiveEffectError
  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.Response
  alias Skein.Runtime.Replay
  alias Skein.Runtime.TestPolicy
  alias Skein.Runtime.Trace

  @default_truncate_length 200

  @doc """
  Sends an unstructured chat request to the LLM.

  Returns `{:ok, response_text}` or `{:error, <LlmError ABI tuple>}` —
  the frozen matchable form (C2/#297), e.g. `{:provider_error, code, message}`.
  """
  @spec chat(String.t(), String.t(), any(), [map()]) ::
          {:ok, String.t()} | {:error, Error.abi()}
  def chat(model, system, input, capabilities)
      when is_binary(model) and is_binary(system) and is_list(capabilities) do
    backend = resolve_backend(model)
    span = Map.merge(%{kind: :llm, method: :chat, model: model}, backend_span_meta(backend))

    with_enriched_span(span, system, input, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
          call_chat(backend, model, system, input)

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
    |> Error.to_abi_result()
  end

  @doc """
  Sends a schema-constrained JSON request to the LLM.

  The `schema` is a JSON Schema map that the response must conform to.
  The response is parsed as JSON and validated against the schema.

  Returns `{:ok, parsed_map}` or `{:error, <LlmError ABI tuple>}` (C2/#297).
  """
  @spec json(String.t(), String.t(), any(), map(), [map()]) ::
          {:ok, map()} | {:error, Error.abi()}
  def json(model, system, input, schema, capabilities)
      when is_binary(model) and is_binary(system) and is_map(schema) and is_list(capabilities) do
    backend = resolve_backend(model)
    span = Map.merge(%{kind: :llm, method: :json, model: model}, backend_span_meta(backend))

    with_enriched_span(span, system, input, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
          case call_json(backend, model, system, input, schema) do
            {:ok, %Response{text: raw_text} = resp} ->
              case parse_json_response(raw_text) do
                {:ok, parsed} ->
                  case decode_by_schema(parsed, schema) do
                    {:ok, decoded} -> {:ok, decoded, resp}
                    error -> error
                  end

                error ->
                  error
              end

            {:ok, raw_text} when is_binary(raw_text) ->
              case parse_json_response(raw_text) do
                {:ok, parsed} -> decode_by_schema(parsed, schema)
                error -> error
              end

            {:ok, %{} = parsed} ->
              decode_by_schema(parsed, schema)

            {:error, _} = error ->
              error
          end

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
    |> Error.to_abi_result()
  end

  @doc """
  Sends a streaming request to the LLM, delivering chunks via `on_chunk` callback.

  The `on_chunk` callback receives each text chunk as it arrives.
  The full response is assembled from all chunks and returned.

  When called from compiled Skein code without a callback (e.g. `llm.stream(model, system, input)`),
  the codegen passes a no-op callback and returns the assembled response.

  Returns `{:ok, assembled_text}` or `{:error, <LlmError ABI tuple>}` (C2/#297).
  """
  @spec stream(String.t(), String.t(), any(), function(), [map()]) ::
          {:ok, String.t()} | {:error, Error.abi()}
  def stream(model, system, input, on_chunk, capabilities)
      when is_binary(model) and is_binary(system) and is_function(on_chunk, 1) and
             is_list(capabilities) do
    backend = resolve_backend(model)
    span = Map.merge(%{kind: :llm, method: :stream, model: model}, backend_span_meta(backend))

    with_enriched_span(span, system, input, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
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
    |> Error.to_abi_result()
  end

  @doc """
  Generates an embedding vector for the given input text.

  Returns `{:ok, [float()]}` or `{:error, %Llm.Error{}}`.
  The vector dimensionality depends on the model used.
  """
  @spec embed(String.t(), String.t(), [map()]) ::
          {:ok, [float()]} | {:error, Error.abi()}
  def embed(model, input, capabilities)
      when is_binary(model) and is_binary(input) and is_list(capabilities) do
    backend = resolve_embed_backend(model)
    span = Map.merge(%{kind: :llm, method: :embed, model: model}, backend_span_meta(backend))

    Trace.with_recorded_span(span, fn ->
      case check_model_capability(model, capabilities) do
        :ok ->
          case call_embed(backend, model, input) do
            {:ok, vector} = ok -> {ok, %{response: vector}}
            {:error, _} = error -> {error, %{}}
          end

        {:error, reason} ->
          {{:error, Error.capability_error(reason)}, %{}}
      end
    end)
    |> Error.to_abi_result()
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

  # Resolution order (#282/#283): a scenario `model` implement provider on the
  # active capability stack wins; then an active replay context; then the
  # configured backend. Under `skein test` (TestPolicy active) a *live* backend
  # is blocked unless the run opted in with `--allow-live model[:<model>]` — a
  # deterministic test backend stays allowed so offline tests run without setup.
  defp resolve_backend(model) do
    cond do
      match?({:implement, _}, CapabilityStack.resolve("model")) ->
        Skein.Runtime.Llm.ProviderBackend

      Replay.active?() ->
        Skein.Runtime.Llm.ReplayBackend

      true ->
        enforce_live_policy(get_backend(), model)
    end
  end

  # `llm.embed` has no `implement` provider form — `LlmResponse` is
  # text-only (#279) — so it resolves PAST a scenario `model` provider,
  # through the normal remaining order: replay, then the configured
  # backend under the live policy (a live backend stays blocked under
  # `skein test` unless `--allow-live model`). This keeps embeds
  # deterministic offline inside scenario envelopes instead of erroring.
  defp resolve_embed_backend(model) do
    cond do
      Replay.active?() ->
        Skein.Runtime.Llm.ReplayBackend

      true ->
        enforce_live_policy(get_backend(), model)
    end
  end

  # Backends that never touch the network — safe under the test policy.
  @offline_backends [
    Skein.Runtime.Llm.TestBackend,
    Skein.Runtime.Llm.StreamingTestBackend,
    Skein.Runtime.Llm.ReplayBackend,
    Skein.Runtime.Llm.ProviderBackend
  ]

  defp enforce_live_policy(backend, model) do
    if live_backend?(backend) and TestPolicy.block_live?("model", model) do
      raise LiveEffectError.new("model", model)
    end

    backend
  end

  defp live_backend?({module, _config}), do: live_backend?(module)
  defp live_backend?(module) when is_atom(module), do: module not in @offline_backends

  # Span metadata identifying which backend (and base_url, for local
  # servers) serves the call — a trace should never leave you guessing
  # whether tokens were spent.
  defp backend_span_meta({module, config}) do
    meta = %{backend: backend_name(module)}

    case config do
      %{base_url: base_url} when is_binary(base_url) -> Map.put(meta, :base_url, base_url)
      _ -> meta
    end
  end

  defp backend_span_meta(module) when is_atom(module) do
    %{backend: backend_name(module)}
  end

  defp backend_name(module), do: module |> Module.split() |> List.last()

  # Call chat on the backend, handling both module and {module, config} tuple backends
  defp call_chat({module, config}, model, system, input) do
    module.chat(model, system, input, config)
  end

  defp call_chat(module, model, system, input) when is_atom(module) do
    module.chat(model, system, input)
  end

  # Call json on the backend, handling both module and {module, config} tuple backends
  defp call_json({module, config}, model, system, input, schema) do
    module.json(model, system, input, schema, config)
  end

  defp call_json(module, model, system, input, schema) when is_atom(module) do
    module.json(model, system, input, schema)
  end

  # Call stream on the backend, handling both module and {module, config} tuple backends
  defp call_stream({module, config}, model, system, input, _on_chunk) do
    module.stream(model, system, input, config)
  end

  defp call_stream(module, model, system, input, _on_chunk) when is_atom(module) do
    module.stream(model, system, input)
  end

  # Call embed on the backend, handling both module and {module, config} tuple backends
  defp call_embed({module, config}, model, input) do
    module.embed(model, input, config)
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
        # Models often wrap the JSON object in prose or a ```json code
        # fence. Retry against any embedded candidate before giving up so
        # a chatty-but-correct response still parses (skein-testing #27).
        case extract_json_candidate(raw_text) do
          {:ok, candidate} ->
            case Jason.decode(candidate) do
              {:ok, parsed} ->
                {:ok, parsed}

              {:error, _} ->
                {:error, Error.parse_failed(raw_text, "JSON", Exception.message(decode_error))}
            end

          :error ->
            {:error, Error.parse_failed(raw_text, "JSON", Exception.message(decode_error))}
        end
    end
  end

  # Pull a JSON object/array out of surrounding prose or markdown fences.
  # Prefers a fenced block (```json ... ```), then falls back to the span
  # from the first opening bracket to the last matching closing bracket.
  defp extract_json_candidate(raw_text) do
    fenced =
      Regex.run(~r/```(?:json)?\s*(.*?)```/s, raw_text, capture: :all_but_first)

    cond do
      is_list(fenced) and fenced != [] ->
        {:ok, fenced |> hd() |> String.trim()}

      true ->
        bracket_span(raw_text)
    end
  end

  defp bracket_span(text) do
    # Whichever of the object/array spans opens earliest in the text wins.
    [slice_between(text, "{", "}"), slice_between(text, "[", "]")]
    |> Enum.flat_map(fn
      {:ok, {offset, span}} -> [{offset, span}]
      :error -> []
    end)
    |> Enum.min_by(fn {offset, _span} -> offset end, fn -> nil end)
    |> case do
      nil -> :error
      {_offset, span} -> {:ok, span}
    end
  end

  defp slice_between(text, open, close) do
    with [{start, _} | _] <- :binary.matches(text, open),
         matches when matches != [] <- :binary.matches(text, close),
         {last, _} <- List.last(matches),
         true <- last > start do
      {:ok, {start, binary_part(text, start, last - start + 1)}}
    else
      _ -> :error
    end
  end

  # Schema-directed key atomization is shared with the HTTP JSON path so
  # llm.json[T] and req.json[T] coerce keys identically.
  # C3/#298: llm.json[T] now VALIDATES against the derived schema (the
  # moduledoc always promised this; before C3 it only atomized). A
  # well-formed-JSON response that violates the schema is
  # LlmError.InvalidSchema(violations).
  defp decode_by_schema(parsed, schema) do
    case Skein.Runtime.JsonSchema.decode(parsed, schema) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, violations} -> {:error, Error.invalid_schema(violations)}
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

  # Extract trace metadata from backend result, normalizing Response vs raw
  # strings. The full (untruncated) response is recorded under :response so
  # the trace can later be replayed via Skein.Runtime.Replay.
  defp extract_result_meta({:ok, %Response{} = resp}, truncate) do
    meta = %{
      output: Response.truncate(resp.text, truncate),
      response: resp.text,
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
      response: resp.text || parsed,
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
    {:ok, result, %{output: Response.truncate(text, truncate), response: text}}
  end

  defp extract_result_meta({:ok, value} = result, _truncate) do
    {:ok, result, %{response: value}}
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

  @typedoc """
  The frozen structured-error ABI form (C2/#297): the tuple/atom shape a
  Skein `LlmError` variant pattern lowers to, so `Err(LlmError.RateLimit(ms))`
  really matches. See `Skein.EffectABI.error_enums/0` and spec §6.4.
  """
  @type abi ::
          {:parse_failed, String.t(), String.t(), String.t()}
          | {:refused, String.t()}
          | {:rate_limit, integer()}
          | {:timeout, integer()}
          | {:content_filtered, String.t()}
          | {:invalid_schema, [String.t()]}
          | {:provider_error, String.t(), String.t()}
          | {:denied, String.t()}

  @doc """
  Converts the internal error struct to its frozen ABI tuple (C2/#297).
  Already-converted tuples (e.g. from a scenario `implement` provider, whose
  compiled body returns lowered `LlmError` variants) pass through unchanged.
  """
  @spec to_abi(t() | abi()) :: abi()
  def to_abi(%__MODULE__{kind: :parse_failed, detail: d}) do
    {:parse_failed, d.raw, d.expected_type, d.parse_error}
  end

  def to_abi(%__MODULE__{kind: :refused, detail: d}), do: {:refused, d.reason}
  def to_abi(%__MODULE__{kind: :rate_limit, detail: d}), do: {:rate_limit, d.retry_after_ms}
  def to_abi(%__MODULE__{kind: :timeout, detail: d}), do: {:timeout, d.elapsed_ms}
  def to_abi(%__MODULE__{kind: :content_filtered, detail: d}), do: {:content_filtered, d.filter}
  def to_abi(%__MODULE__{kind: :invalid_schema, detail: d}), do: {:invalid_schema, d.violations}

  def to_abi(%__MODULE__{kind: :provider_error, detail: d}) do
    {:provider_error, d.code, d.message}
  end

  def to_abi(%__MODULE__{kind: :capability_error, detail: d}), do: {:denied, d.reason}
  def to_abi(already_abi), do: already_abi

  @doc "Applies `to_abi/1` to the error side of a result; success passes through."
  @spec to_abi_result({:ok, any()} | {:error, t() | abi()}) :: {:ok, any()} | {:error, abi()}
  def to_abi_result({:error, error}), do: {:error, to_abi(error)}
  def to_abi_result(other), do: other
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
  def json(_model, _system, _input, schema) do
    # Synthesize a value that conforms to the requested schema so
    # structured-output logic can be unit-tested deterministically against
    # any type T, not only the old canned {action, amount, reason} shape
    # (skein-testing #4).
    {:ok, Skein.Runtime.Llm.TestData.synthesize(schema)}
  end

  @impl true
  def stream(_model, _system, input) do
    # Chunk the same canned text chat/1 returns so llm.stream can be
    # exercised offline like chat/embed (skein-testing #19).
    text = "Test response for: #{inspect(input)}"
    {:ok, chunk_text(text)}
  end

  defp chunk_text(text) do
    text
    |> String.codepoints()
    |> Enum.chunk_every(8)
    |> Enum.map(&Enum.join/1)
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

defmodule Skein.Runtime.Llm.TestData do
  @moduledoc """
  Synthesizes deterministic values conforming to a JSON Schema, used by
  the test LLM backend so `llm.json[T]` returns a value shaped like the
  requested type `T` rather than a single canned map. Keys are strings
  (the backend convention); `Skein.Runtime.Llm` atomizes declared fields.
  """

  @spec synthesize(map()) :: term()
  # An empty/unconstrained schema (schemaless `llm.json`) still needs to
  # decode as a JSON object, so yield a map rather than a scalar.
  def synthesize(schema) when map_size(schema) == 0, do: %{}
  def synthesize(%{"oneOf" => [branch | _]}), do: synthesize(branch)
  def synthesize(%{"const" => value}), do: value
  def synthesize(%{"enum" => [first | _]}), do: first

  def synthesize(%{"type" => "object", "properties" => properties}) do
    Map.new(properties, fn {name, sub_schema} -> {name, synthesize(sub_schema)} end)
  end

  # Map[K, V] / opaque object: keys are data, so an empty map conforms.
  def synthesize(%{"type" => "object"}), do: %{}

  def synthesize(%{"type" => "array", "items" => items}), do: [synthesize(items)]
  def synthesize(%{"type" => "array"}), do: []

  def synthesize(%{"type" => "integer"} = schema), do: Map.get(schema, "minimum", 1)
  def synthesize(%{"type" => "number"} = schema), do: Map.get(schema, "minimum", 1) * 1.0
  def synthesize(%{"type" => "boolean"}), do: true

  def synthesize(%{"type" => "string", "format" => format}), do: string_for_format(format)
  def synthesize(%{"type" => "string"}), do: "test"

  # Unconstrained / unrecognized schema.
  def synthesize(_schema), do: "test"

  defp string_for_format("uuid"), do: "00000000-0000-0000-0000-000000000000"
  defp string_for_format("date-time"), do: "2026-01-01T00:00:00Z"
  defp string_for_format("email"), do: "test@example.com"
  defp string_for_format("uri"), do: "https://example.com"
  defp string_for_format(_), do: "test"
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
