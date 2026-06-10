defmodule Skein.CLI.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) server for Skein, speaking JSON-RPC 2.0
  over stdio (newline-delimited messages).

  Exposes three tools to coding agents:

  - `skein_spec_lookup` — fetch a named section of the language spec
  - `skein_docs_search` — search the spec corpus for a query
  - `skein_compile_check` — compile a file or project and return the
    structured JSON errors (`code`, `fix_hint`, `fix_code`)

  The language spec is embedded at build time from `docs/SKEIN_SPEC.md`,
  so the server works from a standalone binary with no repo checkout.

  Started via `skein mcp`. Register with Claude Code:

      claude mcp add skein -- skein mcp
  """

  alias Skein.Compiler

  @protocol_version "2024-11-05"

  @spec_path Path.expand("../../../../../docs/SKEIN_SPEC.md", __DIR__)
  @external_resource @spec_path
  @spec_source File.read!(@spec_path)

  @tools [
    %{
      "name" => "skein_spec_lookup",
      "description" =>
        "Fetch a named section of the Skein language specification. " <>
          "Pass a section number (e.g. \"6.4\") or a title fragment (e.g. \"agents\", \"llm\").",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "section" => %{
            "type" => "string",
            "description" => "Section number or title fragment to look up"
          }
        },
        "required" => ["section"]
      }
    },
    %{
      "name" => "skein_docs_search",
      "description" =>
        "Search the Skein language spec corpus for a query string. " <>
          "Returns matching sections with the matching lines.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Case-insensitive search query"}
        },
        "required" => ["query"]
      }
    },
    %{
      "name" => "skein_compile_check",
      "description" =>
        "Compile a .skein file or a Skein project directory and return structured " <>
          "JSON compile results. Errors include code, message, location, fix_hint, and fix_code.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to a .skein file or a project directory (compiles src/)"
          }
        },
        "required" => ["path"]
      }
    }
  ]

  # ------------------------------------------------------------------
  # stdio transport
  # ------------------------------------------------------------------

  @doc """
  Reads newline-delimited JSON-RPC messages from `device` until EOF,
  writing responses to standard output.
  """
  @spec serve(IO.device()) :: :ok
  def serve(device \\ :stdio) do
    case IO.read(device, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        handle_line(String.trim(line))
        serve(device)
    end
  end

  defp handle_line(""), do: :ok

  defp handle_line(line) do
    response =
      case Jason.decode(line) do
        {:ok, message} ->
          case handle_message(message) do
            {:reply, reply} -> reply
            :noreply -> nil
          end

        {:error, _} ->
          error_response(nil, -32700, "Parse error")
      end

    if response, do: IO.puts(Jason.encode!(response))
    :ok
  end

  # ------------------------------------------------------------------
  # JSON-RPC message handling
  # ------------------------------------------------------------------

  @doc """
  Handles a decoded JSON-RPC message. Returns `{:reply, response}` for
  requests and `:noreply` for notifications.
  """
  @spec handle_message(map()) :: {:reply, map()} | :noreply
  def handle_message(%{"method" => "initialize", "id" => id} = message) do
    client_version = get_in(message, ["params", "protocolVersion"])

    {:reply,
     result_response(id, %{
       "protocolVersion" => negotiated_version(client_version),
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "skein", "version" => version()}
     })}
  end

  def handle_message(%{"method" => "ping", "id" => id}) do
    {:reply, result_response(id, %{})}
  end

  def handle_message(%{"method" => "tools/list", "id" => id}) do
    {:reply, result_response(id, %{"tools" => @tools})}
  end

  def handle_message(%{"method" => "tools/call", "id" => id} = message) do
    name = get_in(message, ["params", "name"])
    arguments = get_in(message, ["params", "arguments"]) || %{}

    case call_tool(name, arguments) do
      {:ok, text} ->
        {:reply, result_response(id, tool_result(text, false))}

      {:error, text} ->
        {:reply, result_response(id, tool_result(text, true))}

      :unknown_tool ->
        {:reply, error_response(id, -32602, "Unknown tool: #{name}")}
    end
  end

  # Notifications (no id) require no response.
  def handle_message(%{"method" => _method} = message) when not is_map_key(message, "id") do
    :noreply
  end

  def handle_message(%{"method" => method, "id" => id}) do
    {:reply, error_response(id, -32601, "Method not found: #{method}")}
  end

  def handle_message(_message), do: :noreply

  defp negotiated_version(client_version) when is_binary(client_version), do: client_version
  defp negotiated_version(_), do: @protocol_version

  defp result_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp tool_result(text, is_error) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error}
  end

  # ------------------------------------------------------------------
  # Tools
  # ------------------------------------------------------------------

  defp call_tool("skein_spec_lookup", %{"section" => section}) when is_binary(section) do
    spec_lookup(section)
  end

  defp call_tool("skein_spec_lookup", _args) do
    {:error, "Missing required argument: section"}
  end

  defp call_tool("skein_docs_search", %{"query" => query}) when is_binary(query) do
    docs_search(query)
  end

  defp call_tool("skein_docs_search", _args) do
    {:error, "Missing required argument: query"}
  end

  defp call_tool("skein_compile_check", %{"path" => path}) when is_binary(path) do
    compile_check(path)
  end

  defp call_tool("skein_compile_check", _args) do
    {:error, "Missing required argument: path"}
  end

  defp call_tool(_name, _args), do: :unknown_tool

  # --- skein_spec_lookup ---

  defp spec_lookup(section) do
    query = section |> String.trim() |> String.downcase()

    case Enum.find(spec_sections(), &section_matches?(&1, query)) do
      %{title: title, content: content} ->
        {:ok, "## #{title}\n\n#{content}"}

      nil ->
        titles = spec_sections() |> Enum.map_join("\n", &"- #{&1.title}")
        {:error, "No spec section matches '#{section}'. Available sections:\n#{titles}"}
    end
  end

  defp section_matches?(%{title: title}, query) do
    lowered = String.downcase(title)

    String.starts_with?(lowered, query <> " ") or lowered == query or
      String.contains?(lowered, query)
  end

  # --- skein_docs_search ---

  @max_search_sections 8
  @max_lines_per_section 5

  defp docs_search(query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      {:error, "Search query is empty"}
    else
      lowered = String.downcase(trimmed)

      hits =
        spec_sections()
        |> Enum.map(fn section -> {section, matching_lines(section, lowered)} end)
        |> Enum.filter(fn {section, lines} ->
          lines != [] or String.contains?(String.downcase(section.title), lowered)
        end)
        |> Enum.take(@max_search_sections)

      if hits == [] do
        {:ok, "No matches for '#{trimmed}' in the Skein spec."}
      else
        body =
          Enum.map_join(hits, "\n\n", fn {section, lines} ->
            shown = Enum.take(lines, @max_lines_per_section)
            "## #{section.title}\n" <> Enum.map_join(shown, "\n", &("  " <> &1))
          end)

        {:ok, "Matches for '#{trimmed}':\n\n#{body}"}
      end
    end
  end

  defp matching_lines(%{content: content}, lowered_query) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      line != "" and String.contains?(String.downcase(line), lowered_query)
    end)
  end

  # --- skein_compile_check ---

  defp compile_check(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        files =
          expanded
          |> Path.join("src/**/*.skein")
          |> Path.wildcard()
          |> Enum.sort()

        if files == [] do
          {:error, "No .skein files found in #{Path.join(expanded, "src")}/"}
        else
          {:ok, check_files(files)}
        end

      File.regular?(expanded) ->
        {:ok, check_files([expanded])}

      true ->
        {:error, "No such file or directory: #{path}"}
    end
  end

  defp check_files(files) do
    errors =
      Enum.flat_map(files, fn file ->
        case Compiler.compile_file(file) do
          {:module, _mod} -> []
          {:error, errors} -> errors |> List.wrap() |> Enum.map(&normalize_error(&1, file))
        end
      end)

    Jason.encode!(%{ok: errors == [], files_checked: length(files), errors: errors})
  end

  defp normalize_error(%Skein.Error{} = error, _file), do: error
  defp normalize_error(message, file) when is_binary(message), do: %{file: file, message: message}
  defp normalize_error(other, file), do: %{file: file, message: inspect(other)}

  # ------------------------------------------------------------------
  # Spec section index
  # ------------------------------------------------------------------

  @doc false
  @spec spec_sections() :: [%{title: String.t(), content: String.t()}]
  def spec_sections do
    case :persistent_term.get({__MODULE__, :spec_sections}, nil) do
      nil ->
        sections = parse_sections(@spec_source)
        :persistent_term.put({__MODULE__, :spec_sections}, sections)
        sections

      sections ->
        sections
    end
  end

  defp parse_sections(source) do
    source
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^##+ (.+)$/, line) do
        [_, title] ->
          [%{title: String.trim(title), lines: []} | acc]

        nil ->
          case acc do
            [] -> []
            [current | rest] -> [%{current | lines: [line | current.lines]} | rest]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn %{title: title, lines: lines} ->
      %{title: title, content: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()}
    end)
  end

  defp version do
    case Application.spec(:skein_cli, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
