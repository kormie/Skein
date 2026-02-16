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

  alias Skein.Runtime.Tool.Error
  alias Skein.Runtime.Trace

  @registry_table :skein_tool_registry

  @doc """
  Starts the tool registry. Called during application startup.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@registry_table) == :undefined do
      :ets.new(@registry_table, [:named_table, :public, :set])
    end

    :ok
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
  Calls a registered tool by name with the given input.

  Returns `{:ok, result_map}` or `{:error, %Tool.Error{}}`.

  Requires `tool.use` capability in the capabilities list.
  """
  @spec call(String.t(), any(), [map()]) :: {:ok, any()} | {:error, Error.t()}
  def call(name, input, capabilities)
      when is_binary(name) and is_list(capabilities) do
    Trace.with_span(%{kind: :tool, method: :call, name: name}, fn ->
      case check_tool_capability(capabilities, name) do
        :ok ->
          execute_tool(name, input)

        {:error, reason} ->
          {:error, Error.capability_error(reason)}
      end
    end)
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
      [{^name, _schema, impl}] ->
        case impl.(input) do
          {:ok, result} when is_map(result) ->
            {:ok, result}

          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            {:error, Error.execution_error(name, inspect(reason))}
        end

      [] ->
        {:error, Error.not_found(name)}
    end
  end
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
