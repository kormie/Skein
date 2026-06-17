defmodule Skein.CLI.Json do
  @moduledoc """
  Pure, framework-neutral JSON output for the CLI (`--json`, #284).

  Every `--json`-capable command emits one stable, documented envelope:

      %{"schema" => "skein.<cmd>/v1", "ok" => boolean, "data" => map}

  This is the agent contract — schemas are versioned (`/v1`) so the shape can
  evolve without silently breaking consumers. The `ok` flag is the machine
  success signal (the CLI also mirrors it in the process exit code: 0 when
  `ok`, 1 otherwise). `data` is per-command; its shape is documented in
  `docs/site/src/content/docs/reference/json-output.md`.

  The builder functions take the raw `{:ok, ...}` / `{:error, ...}` tuple a
  `Skein.CLI` command returns and produce the envelope as a plain map (atom
  keys); `encode/1` renders that to a newline-terminated JSON string. Building
  and encoding are separate so the envelope structure can be asserted directly
  in tests without depending on byte-level JSON ordering.

  Span maps are projected down to a fixed field set (`:kind`, `:method`,
  `:url`, `:status`, `:outcome`, `:duration_us`) so arbitrary, non-JSON-
  encodable payloads recorded on a live span (tuples, pids, ...) never leak
  into — or break — the contract.
  """

  alias Skein.Error

  @trace_span_fields [:kind, :method, :url, :status, :outcome, :duration_us]

  @doc """
  Renders an envelope map (from `compile/1`, `build/1`, `test/1`, `trace/1`) to
  a JSON string terminated by a single newline.
  """
  @spec encode(map()) :: String.t()
  def encode(envelope) when is_map(envelope) do
    Jason.encode!(envelope) <> "\n"
  end

  # ------------------------------------------------------------------
  # trace
  # ------------------------------------------------------------------

  @doc """
  Builds the `skein.trace/v1` envelope from a `Skein.CLI.trace/1` result.
  """
  @spec trace({:ok, map()} | {:error, String.t()}) :: map()
  def trace({:ok, %{spans: spans, count: count}}) do
    envelope("skein.trace/v1", true, %{
      spans: Enum.map(spans, &project_span/1),
      count: count
    })
  end

  def trace({:error, message}), do: error_envelope("skein.trace/v1", message)

  defp project_span(span) do
    @trace_span_fields
    |> Enum.reduce(%{}, fn key, acc ->
      case field(span, key) do
        nil -> acc
        value -> Map.put(acc, key, scalar(value))
      end
    end)
  end

  # ------------------------------------------------------------------
  # test
  # ------------------------------------------------------------------

  @doc """
  Builds the `skein.test/v1` envelope from a `Skein.CLI.test_all/1` result.
  """
  @spec test({:ok, map()} | {:error, String.t()}) :: map()
  def test({:ok, result}) do
    compile_errors = Map.get(result, :compile_errors, 0)
    ok? = result.failed == 0 and compile_errors == 0

    envelope("skein.test/v1", ok?, %{
      total: result.total,
      passed: result.passed,
      failed: result.failed,
      files: Map.get(result, :files, 0),
      compile_errors: compile_errors,
      compile_failed: Enum.map(Map.get(result, :compile_failed, []), &compile_failure/1),
      results: Enum.map(result.results, &test_result/1)
    })
  end

  def test({:error, message}), do: error_envelope("skein.test/v1", message)

  # Keep only the documented, JSON-safe fields; `error`/`location` appear only
  # on failures (they carry the Wave 3 structured failure detail).
  defp test_result(result) do
    base = %{
      description: result.description,
      status: scalar(result.status),
      kind: scalar(Map.get(result, :kind, :test))
    }

    base
    |> maybe_put(:file, Map.get(result, :file))
    |> maybe_put(:error, Map.get(result, :error))
    |> maybe_put(:location, Map.get(result, :location))
  end

  # ------------------------------------------------------------------
  # compile (Skein's "check" command)
  # ------------------------------------------------------------------

  @doc """
  Builds the `skein.compile/v1` envelope from a `Skein.CLI.compile/1` result.
  """
  @spec compile({:ok, module(), [Error.t()]} | {:error, term()}) :: map()
  def compile({:ok, module, warnings}) do
    envelope("skein.compile/v1", true, %{
      module: module_name(module),
      errors: [],
      warnings: warnings
    })
  end

  def compile({:error, errors}) when is_list(errors) do
    envelope("skein.compile/v1", false, %{module: nil, errors: errors, warnings: []})
  end

  def compile({:error, message}) do
    envelope("skein.compile/v1", false, %{
      module: nil,
      errors: [message_error(message)],
      warnings: []
    })
  end

  # ------------------------------------------------------------------
  # build
  # ------------------------------------------------------------------

  @doc """
  Builds the `skein.build/v1` envelope from a `Skein.CLI.build/1` result.
  """
  @spec build({:ok, map()} | {:error, String.t()}) :: map()
  def build({:ok, result}) do
    envelope("skein.build/v1", result.errors == 0, %{
      compiled: result.compiled,
      errors: result.errors,
      modules: Enum.map(result.modules, &module_name/1),
      failed: Enum.map(result.failed, &compile_failure/1)
    })
  end

  def build({:error, message}), do: error_envelope("skein.build/v1", message)

  # ------------------------------------------------------------------
  # shared helpers
  # ------------------------------------------------------------------

  defp envelope(schema, ok?, data) do
    %{schema: schema, ok: ok?, data: data}
  end

  # A top-level error (bad flag, no files, missing file) — distinct from a
  # per-file/per-test failure — carries a single human-readable message.
  defp error_envelope(schema, message) do
    envelope(schema, false, %{message: to_string(message)})
  end

  defp compile_failure(%{file: file, errors: errors}) do
    %{file: file, errors: errors}
  end

  # Reason strings (usage / filesystem) become a minimal error-shaped map so
  # `data.errors` is uniformly a list of objects.
  defp message_error(message), do: %{message: to_string(message)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(other), do: to_string(other)

  # Atoms render as their text so the JSON stays string-typed for consumers;
  # numbers and binaries pass through untouched.
  defp scalar(value) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp scalar(value), do: value

  # Span maps may use atom or string keys (live vs replayed from JSON).
  defp field(span, key) when is_map(span) do
    case Map.get(span, key) do
      nil -> Map.get(span, Atom.to_string(key))
      value -> value
    end
  end
end
