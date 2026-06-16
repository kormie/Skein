defmodule Skein.Runtime.Tool do
  @moduledoc """
  Runtime dispatcher for compiled Skein tool calls.

  Provides `call/3` for executing registered tools, `list/1` for listing
  available tools, and `schema/2` for retrieving a tool's input/output schema.

  Called by compiled Skein code when `tool.call(...)`, `tool.list()`, or
  `tool.schema(...)` effect calls are encountered.

  Every operation is:
  1. Checked against the module's declared `tool.use` capabilities
  2. Traced with tool name, timing, and outcome metadata
  3. Returns `{:ok, result}` or `{:error, %Tool.Error{}}`

  Tools are registered at module load time from compiled Skein `tool` declarations.
  The registry is an ETS table keyed by tool name.
  """

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.Replay
  alias Skein.Runtime.Tool.Error
  alias Skein.Runtime.Trace

  @registry_table :skein_tool_registry

  @doc """
  Starts the tool registry. Called during application startup.
  """
  @spec init() :: :ok
  def init do
    Skein.Runtime.EtsTables.ensure_table(@registry_table, [:named_table, :public, :set])
  end

  @doc """
  Registers a tool with its schema and implementation function.

  The `impl` function receives an input map and must return
  `{:ok, result_map}` or `{:error, reason}`.
  """
  @spec register(String.t(), map(), (map() -> {:ok, map()} | {:error, any()})) :: :ok
  def register(name, schema, impl)
      when is_binary(name) and is_map(schema) and is_function(impl, 1) do
    init()
    :ets.insert(@registry_table, {name, schema, impl})
    :ok
  end

  @doc """
  Registers every tool declared by a compiled Skein module.

  Scans the module's `__tools__/0` metadata (emitted by the code
  generator for each `tool` declaration) and registers each tool under
  its declared name. Tools with an `implement` block dispatch to the
  module's compiled `__tool_impl_N__/1` entry point; tools without one
  are registered with a stub that returns an execution error, so
  `tool.list()` and `tool.schema(...)` still see them.

  Registration is idempotent: the registry is keyed by tool name, so
  reloading a module simply overwrites its previous entries.

  Modules with no `__tools__/0` function are a no-op.
  """
  @spec register_module(module()) :: :ok
  def register_module(mod) when is_atom(mod) do
    if function_exported?(mod, :__tools__, 0) do
      Enum.each(mod.__tools__(), &register_declared_tool(mod, &1))
    end

    :ok
  end

  defp register_declared_tool(mod, %{name: name} = tool_meta) do
    impl_fn = Map.get(tool_meta, :impl)

    field_names =
      tool_meta
      |> Map.get(:input, [])
      |> Enum.map(& &1.name)

    impl =
      if impl_fn do
        fn input ->
          normalized = normalize_input_keys(input, field_names)

          case apply(mod, impl_fn, [normalized]) do
            {:ok, _} = ok -> ok
            {:error, _} = error -> error
            bare -> {:ok, bare}
          end
        end
      else
        fn _input ->
          {:error, "Tool '#{name}' declares no implement block"}
        end
      end

    register(name, Map.delete(tool_meta, :impl), impl)
  end

  # Compiled implement bodies read input fields with atom keys; callers
  # (HTTP, tests) may pass string keys. Remap only the declared field
  # names — their atoms already exist from the compiled module.
  defp normalize_input_keys(input, field_names) when is_map(input) do
    Map.new(input, fn {key, value} ->
      with true <- is_binary(key),
           true <- key in field_names,
           atom when not is_nil(atom) <- safe_to_atom(key) do
        {atom, value}
      else
        _ -> {key, value}
      end
    end)
  end

  defp normalize_input_keys(input, _field_names), do: input

  @doc """
  Calls a registered tool by name with the given input.

  Returns `{:ok, result_map}` or `{:error, %Tool.Error{}}`.

  Requires `tool.use` capability in the capabilities list.
  """
  @spec call(String.t(), any(), [map()]) :: {:ok, any()} | {:error, Error.t()}
  def call(name, input, capabilities)
      when is_binary(name) and is_list(capabilities) do
    Trace.with_recorded_span(%{kind: :tool, method: :call, name: name}, fn ->
      case check_tool_capability(capabilities, name) do
        :ok ->
          # Push the scenario capability envelope for this tool (if any) so the
          # tool's effects resolve against its `implement` providers (#282). In
          # production no envelope is registered, so this is a transparent no-op.
          CapabilityStack.with_tool_envelope(name, fn -> dispatch_call(name, input) end)

        {:error, reason} ->
          {{:error, Error.capability_error(reason)}, %{}}
      end
    end)
  end

  # An active replay context serves recorded tool results instead of
  # executing the registered implementation. The recorded event must name
  # the same tool — divergence is a clear error. Live results are recorded
  # on the span so the trace is replayable.
  defp dispatch_call(name, input) do
    case Replay.next_response(:tool, %{method: :call, name: name}) do
      :no_replay ->
        case execute_tool(name, input) do
          {:ok, result} = ok -> {ok, %{response: result}}
          {:error, _} = error -> {error, %{}}
        end

      {:ok, recorded} ->
        {{:ok, recorded}, %{replayed: true}}

      :exhausted ->
        {{:error,
          Error.execution_error(
            name,
            "Replay trace exhausted: no recorded tool call remains for '#{name}'"
          )}, %{replayed: true}}

      {:mismatch, message} ->
        {{:error, Error.execution_error(name, message)}, %{replayed: true}}
    end
  end

  @doc """
  Lists all registered tools.

  Returns `{:ok, [%{name: String.t(), schema: map()}]}`.

  Requires `tool.use` capability.
  """
  @spec list([map()]) :: {:ok, [map()]} | {:error, Error.t()}
  def list(capabilities) when is_list(capabilities) do
    Trace.with_span(%{kind: :tool, method: :list, name: "*"}, fn ->
      case check_tool_capability(capabilities) do
        :ok ->
          init()

          tools =
            :ets.tab2list(@registry_table)
            |> Enum.map(fn {name, schema, _impl} ->
              %{name: name, schema: schema}
            end)

          {:ok, tools}

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
  end

  @doc """
  Returns the schema for a registered tool.

  Returns `{:ok, schema_map}` or `{:error, %Tool.Error{}}`.

  Requires `tool.use` capability.
  """
  @spec schema(String.t(), [map()]) :: {:ok, map()} | {:error, Error.t()}
  def schema(name, capabilities) when is_binary(name) and is_list(capabilities) do
    Trace.with_span(%{kind: :tool, method: :schema, name: name}, fn ->
      case check_tool_capability(capabilities, name) do
        :ok ->
          init()

          case :ets.lookup(@registry_table, name) do
            [{^name, schema, _impl}] ->
              {:ok, schema}

            [] ->
              {:error, Error.not_found(name)}
          end

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
  end

  @doc """
  Clears all registered tools. Used in testing.
  """
  @spec clear_registry() :: :ok
  def clear_registry do
    init()
    :ets.delete_all_objects(@registry_table)
    :ok
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp check_tool_capability(capabilities, tool_name \\ nil) do
    tool_caps =
      Enum.filter(capabilities, fn cap ->
        cap.kind == "tool.use"
      end)

    case tool_caps do
      [] ->
        {:error, "Capability 'tool.use(...)' not declared. Tool calls blocked."}

      caps when tool_name != nil ->
        # Check if the specific tool name is declared
        match =
          Enum.any?(caps, fn cap ->
            case cap.params do
              [] -> true
              params -> tool_name in params
            end
          end)

        if match do
          :ok
        else
          declared =
            caps
            |> Enum.flat_map(fn cap -> cap.params end)
            |> Enum.join(", ")

          {:error,
           "Tool '#{tool_name}' not declared in tool.use capabilities. Declared tools: #{declared}"}
        end

      _caps ->
        :ok
    end
  end

  defp execute_tool(name, input) do
    init()

    case :ets.lookup(@registry_table, name) do
      [{^name, schema, impl}] ->
        case validate_input(name, input, schema) do
          :ok ->
            case impl.(input) do
              {:ok, result} when is_map(result) ->
                {:ok, result}

              {:ok, result} ->
                {:ok, result}

              {:error, reason} ->
                {:error, Error.execution_error(name, inspect(reason))}
            end

          {:error, _} = error ->
            error
        end

      [] ->
        {:error, Error.not_found(name)}
    end
  end

  @doc """
  Validates tool input against the tool's declared input schema.

  Supports two schema formats:
  - Simple: `%{input: %{field_name => type_atom}}` where type_atom is `:int`, `:string`, `:float`, `:bool`
  - JSON Schema: `%{"type" => "object", "properties" => %{...}, "required" => [...]}`

  Returns `:ok` or `{:error, %Tool.Error{kind: :validation_error}}`.
  """
  @spec validate_input(String.t(), any(), map()) :: :ok | {:error, Error.t()}
  def validate_input(name, input, schema) do
    # Determine which schema format we have
    input_spec = get_input_spec(schema)

    case input_spec do
      nil ->
        # No input schema declared — skip validation
        :ok

      spec when spec == %{} ->
        :ok

      spec ->
        violations = check_fields(input, spec)

        case violations do
          [] -> :ok
          vs -> {:error, Error.validation_error(name, vs)}
        end
    end
  end

  defp get_input_spec(%{input: spec}) when is_map(spec) and map_size(spec) > 0, do: spec

  defp get_input_spec(%{"input_schema" => %{"properties" => _} = schema}),
    do: {:json_schema, schema}

  defp get_input_spec(%{input_schema: %{"properties" => _} = schema}), do: {:json_schema, schema}
  defp get_input_spec(_), do: nil

  defp check_fields(input, {:json_schema, schema}) when not is_map(input) do
    case Map.get(schema, "required", []) do
      [] -> []
      _required -> ["input expected an object, got #{inspect(input)}"]
    end
  end

  defp check_fields(input, {:json_schema, schema}) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    missing =
      required
      |> Enum.reject(fn field_name ->
        map_has_key_flex?(input, field_name)
      end)
      |> Enum.map(fn field -> "missing required field '#{field}'" end)

    type_errors =
      properties
      |> Enum.flat_map(fn {field_name, prop_schema} ->
        case map_get_flex(input, field_name) do
          :missing -> []
          {:found, value} -> check_json_schema_type(field_name, value, prop_schema)
        end
      end)

    missing ++ type_errors
  end

  defp check_fields(input, spec) when is_map(spec) and is_map(input) do
    Enum.flat_map(spec, fn {field_name, expected_type} ->
      case map_get_flex(input, field_name) do
        :missing -> []
        {:found, v} -> check_type(field_name, v, expected_type)
      end
    end)
  end

  defp check_fields(_input, _spec), do: []

  # Flexible map access: tries both string and atom keys
  defp map_has_key_flex?(map, key) when is_map(map) do
    Map.has_key?(map, key) or
      (is_binary(key) and Map.has_key?(map, safe_to_atom(key))) or
      (is_atom(key) and Map.has_key?(map, Atom.to_string(key)))
  end

  defp map_get_flex(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        {:found, Map.get(map, key)}

      is_binary(key) ->
        atom_key = safe_to_atom(key)

        if atom_key && Map.has_key?(map, atom_key),
          do: {:found, Map.get(map, atom_key)},
          else: :missing

      is_atom(key) ->
        str_key = Atom.to_string(key)
        if Map.has_key?(map, str_key), do: {:found, Map.get(map, str_key)}, else: :missing

      true ->
        :missing
    end
  end

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp check_type(field, value, :int) when not is_integer(value),
    do: ["field '#{field}' expected Int, got #{inspect(value)}"]

  defp check_type(field, value, :string) when not is_binary(value),
    do: ["field '#{field}' expected String, got #{inspect(value)}"]

  defp check_type(field, value, :float) when not is_float(value) and not is_integer(value),
    do: ["field '#{field}' expected Float, got #{inspect(value)}"]

  defp check_type(field, value, :bool) when not is_boolean(value),
    do: ["field '#{field}' expected Bool, got #{inspect(value)}"]

  defp check_type(_field, _value, _type), do: []

  defp check_json_schema_type(field, value, %{"type" => "string"}) when not is_binary(value),
    do: ["field '#{field}' expected String, got #{inspect(value)}"]

  defp check_json_schema_type(field, value, %{"type" => "integer"}) when not is_integer(value),
    do: ["field '#{field}' expected Int, got #{inspect(value)}"]

  defp check_json_schema_type(field, value, %{"type" => "number"}) when not is_number(value),
    do: ["field '#{field}' expected Number, got #{inspect(value)}"]

  defp check_json_schema_type(field, value, %{"type" => "boolean"}) when not is_boolean(value),
    do: ["field '#{field}' expected Bool, got #{inspect(value)}"]

  defp check_json_schema_type(_field, _value, _schema), do: []
end

defmodule Skein.Runtime.Tool.Error do
  @moduledoc """
  Structured error type for tool operations.

  Variants:
  - `:capability_error` — missing `tool.use` capability declaration
  - `:not_found` — tool name not registered
  - `:execution_error` — tool implementation returned an error
  - `:validation_error` — input didn't match tool's input schema
  """

  defstruct [:kind, :detail]

  @type kind :: :capability_error | :not_found | :execution_error | :validation_error

  @type t :: %__MODULE__{
          kind: kind(),
          detail: map()
        }

  @spec capability_error(String.t()) :: t()
  def capability_error(reason) do
    %__MODULE__{kind: :capability_error, detail: %{reason: reason}}
  end

  @spec not_found(String.t()) :: t()
  def not_found(name) do
    %__MODULE__{kind: :not_found, detail: %{name: name}}
  end

  @spec execution_error(String.t(), String.t()) :: t()
  def execution_error(tool_name, error) do
    %__MODULE__{kind: :execution_error, detail: %{tool: tool_name, error: error}}
  end

  @spec validation_error(String.t(), [String.t()]) :: t()
  def validation_error(tool_name, violations) do
    %__MODULE__{kind: :validation_error, detail: %{tool: tool_name, violations: violations}}
  end
end
