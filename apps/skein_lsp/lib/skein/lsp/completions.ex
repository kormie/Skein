defmodule Skein.Lsp.Completions do
  @moduledoc """
  Provides code completion for Skein source files.

  Offers completions for:
  - Keywords and declaration starters
  - Built-in types
  - Effect namespaces and their methods
  - User-defined symbols from the current file's AST
  """

  alias GenLSP.Enumerations.CompletionItemKind

  alias GenLSP.Structures.{
    CompletionItem,
    Position
  }

  @doc """
  Returns completion items for the given position in source.
  """
  @spec complete(any() | nil, String.t(), Position.t()) :: [CompletionItem.t()]
  def complete(ast, source, %Position{line: line, character: character}) do
    prefix = prefix_at(source, line, character)
    context = context_at(source, line, character)

    items =
      cond do
        # After a dot — provide method completions
        context == :dot_access ->
          namespace = namespace_before_dot(source, line, character)
          effect_method_completions(namespace) ++ type_method_completions(namespace, ast)

        # After "@" — provide annotation completions
        String.starts_with?(prefix, "@") ->
          annotation_completions()

        # Inside a type position (after `:` or `->`)
        context == :type_position ->
          type_completions(ast)

        # General completions
        true ->
          keyword_completions(prefix) ++
            type_completions(ast) ++
            symbol_completions(ast, prefix) ++
            effect_namespace_completions() ++
            snippet_completions(prefix)
      end

    items
    |> Enum.filter(fn item -> matches_prefix?(item.label, prefix) end)
    |> Enum.uniq_by(& &1.label)
  end

  # -- Keyword completions --

  defp keyword_completions(_prefix) do
    keywords = [
      {"module", "Module declaration", "keyword"},
      {"agent", "Agent declaration", "keyword"},
      {"fn", "Function declaration", "keyword"},
      {"let", "Variable binding", "keyword"},
      {"match", "Pattern match expression", "keyword"},
      {"type", "Type declaration", "keyword"},
      {"enum", "Enum declaration", "keyword"},
      {"handler", "Handler declaration", "keyword"},
      {"tool", "Tool declaration", "keyword"},
      {"capability", "Capability declaration", "keyword"},
      {"supervisor", "Supervisor declaration", "keyword"},
      {"test", "Test declaration", "keyword"},
      {"scenario", "Scenario test", "keyword"},
      {"golden", "Golden test", "keyword"},
      {"emit", "Emit an event", "keyword"},
      {"transition", "Phase transition", "keyword"},
      {"stop", "Stop the agent", "keyword"},
      {"import", "Import declaration", "keyword"},
      {"from", "Import source", "keyword"},
      {"pub", "Public modifier", "keyword"},
      {"state", "Agent state block", "keyword"},
      {"on", "Agent event handler", "keyword"},
      {"true", "Boolean true", "constant"},
      {"false", "Boolean false", "constant"},
      {"given", "Scenario given block", "keyword"},
      {"expect", "Scenario expect block", "keyword"},
      {"assert", "Assertion", "keyword"},
      {"suspend", "Suspend the agent", "keyword"},
      {"resume", "Resume a suspended agent", "keyword"},
      {"idempotent", "Idempotent guard", "keyword"},
      {"return", "Return value", "keyword"}
    ]

    Enum.map(keywords, fn {label, detail, kind} ->
      %CompletionItem{
        label: label,
        detail: detail,
        kind: item_kind(kind)
      }
    end)
  end

  # -- Type completions --

  defp type_completions(ast) do
    builtin_types() ++ user_type_completions(ast)
  end

  defp builtin_types do
    types = [
      {"Int", "64-bit signed integer"},
      {"Float", "64-bit IEEE 754 float"},
      {"String", "UTF-8 string"},
      {"Bool", "Boolean (true | false)"},
      {"Uuid", "UUID (RFC 4122)"},
      {"Instant", "UTC timestamp"},
      {"Duration", "Duration in milliseconds"},
      {"Email", "Validated email address"},
      {"Url", "Validated URL"},
      {"Option", "Optional value: Some(T) | None"},
      {"Result", "Result type: Ok(T) | Err(E)"},
      {"List", "Ordered collection: List<T>"},
      {"Map", "Key-value map: Map<K, V>"},
      {"Set", "Unique set: Set<T>"}
    ]

    Enum.map(types, fn {name, detail} ->
      %CompletionItem{
        label: name,
        detail: detail,
        kind: CompletionItemKind.type_parameter()
      }
    end)
  end

  defp user_type_completions(nil), do: []

  defp user_type_completions(%{__struct__: Skein.AST.Module} = mod) do
    (mod.declarations || [])
    |> Enum.flat_map(fn
      %{__struct__: Skein.AST.TypeDecl, name: name} ->
        [
          %CompletionItem{
            label: name,
            detail: "User type",
            kind: CompletionItemKind.struct()
          }
        ]

      %{__struct__: Skein.AST.EnumDecl, name: name} ->
        [
          %CompletionItem{
            label: name,
            detail: "Enum",
            kind: CompletionItemKind.enum()
          }
        ]

      _ ->
        []
    end)
  end

  defp user_type_completions(%{__struct__: Skein.AST.Agent} = agent) do
    phase_completions =
      case agent.phases do
        %{__struct__: Skein.AST.EnumDecl, name: name} ->
          [
            %CompletionItem{
              label: name,
              detail: "Phase enum",
              kind: CompletionItemKind.enum()
            }
          ]

        _ ->
          []
      end

    phase_completions
  end

  defp user_type_completions(_), do: []

  # -- Symbol completions (functions, variables) --

  defp symbol_completions(nil, _prefix), do: []

  defp symbol_completions(%{__struct__: Skein.AST.Module} = mod, _prefix) do
    (mod.declarations || [])
    |> Enum.flat_map(fn
      %{__struct__: Skein.AST.Fn, name: name, params: params, return_type: ret} ->
        param_str =
          (params || [])
          |> Enum.map(fn
            %{name: n} -> n
            _ -> "?"
          end)
          |> Enum.join(", ")

        [
          %CompletionItem{
            label: name,
            detail: "fn #{name}(#{param_str}) -> #{format_type(ret)}",
            kind: CompletionItemKind.function(),
            insert_text: "#{name}($1)"
          }
        ]

      _ ->
        []
    end)
  end

  defp symbol_completions(%{__struct__: Skein.AST.Agent} = agent, _prefix) do
    fn_items =
      (agent.fns || [])
      |> Enum.map(fn f ->
        %CompletionItem{
          label: f.name,
          detail: "fn #{f.name}",
          kind: CompletionItemKind.function(),
          insert_text: "#{f.name}($1)"
        }
      end)

    state_items =
      (agent.state || [])
      |> Enum.map(fn
        %{name: name, type: type} ->
          %CompletionItem{
            label: name,
            detail: "state field: #{format_type(type)}",
            kind: CompletionItemKind.property()
          }

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    fn_items ++ state_items
  end

  defp symbol_completions(_, _), do: []

  # -- Effect namespace completions --

  defp effect_namespace_completions do
    namespaces = [
      {"llm", "LLM operations (chat, json, stream, embed)"},
      {"memory", "Key-value memory (get, put, delete, list)"},
      {"store", "Persistent storage (get, put, delete, query)"},
      {"http", "HTTP client operations"},
      {"topic", "Pub/sub topic operations"},
      {"queue", "Message queue operations"},
      {"trace", "Trace annotations"},
      {"event", "Structured event logging"},
      {"process", "Process spawning"},
      {"timer", "Timer scheduling"},
      {"respond", "Response helpers (json, text, html)"}
    ]

    Enum.map(namespaces, fn {name, detail} ->
      %CompletionItem{
        label: name,
        detail: detail,
        kind: CompletionItemKind.module()
      }
    end)
  end

  # -- Effect method completions (after dot) --

  defp effect_method_completions(namespace) do
    methods =
      case namespace do
        "llm" ->
          [
            {"chat", "Send a chat message to an LLM", "llm.chat(model, prompt, input)"},
            {"json", "Get structured JSON from LLM", "llm.json[Type](model: m, system: s, input: i)"},
            {"stream", "Stream tokens from LLM", "llm.stream(model, prompt, input)"},
            {"embed", "Get embedding vector from LLM", "llm.embed(model, input)"}
          ]

        "memory" ->
          [
            {"get", "Get a value from memory", "memory.get(key)"},
            {"get!", "Get a value or raise", "memory.get!(key)"},
            {"put", "Store a value in memory", "memory.put(key, value)"},
            {"delete", "Delete a key from memory", "memory.delete(key)"},
            {"list", "List keys by prefix", "memory.list(prefix)"}
          ]

        "store" ->
          [
            {"get", "Get a record by key", "store.get(table, key)"},
            {"put", "Insert or update a record", "store.put(table, record)"},
            {"delete", "Delete a record by key", "store.delete(table, key)"},
            {"query", "Query records", "store.query(table, filter)"}
          ]

        "respond" ->
          [
            {"json", "Respond with JSON", "respond.json(status, body)"},
            {"text", "Respond with plain text", "respond.text(status, body)"},
            {"html", "Respond with HTML", "respond.html(status, body)"}
          ]

        "http" ->
          [
            {"get", "HTTP GET request", "http.get(url)"},
            {"post", "HTTP POST request", "http.post(url, body)"},
            {"put", "HTTP PUT request", "http.put(url, body)"},
            {"delete", "HTTP DELETE request", "http.delete(url)"}
          ]

        "topic" ->
          [
            {"publish", "Publish to topic", "topic.publish(name, message)"}
          ]

        "queue" ->
          [
            {"publish", "Enqueue a message", "queue.publish(name, message)"}
          ]

        "trace" ->
          [
            {"annotate", "Add trace annotation", "trace.annotate(key, value)"}
          ]

        "event" ->
          [
            {"log", "Log a structured event", "event.log(name, data)"}
          ]

        "process" ->
          [
            {"spawn", "Spawn a supervised process", "process.spawn(name)"}
          ]

        "timer" ->
          [
            {"after", "One-shot timer", "timer.after(delay_ms, callback)"},
            {"interval", "Recurring timer", "timer.interval(interval_ms, callback)"},
            {"cancel", "Cancel a timer", "timer.cancel(timer_ref)"}
          ]

        _ ->
          []
      end

    Enum.map(methods, fn {label, detail, doc} ->
      %CompletionItem{
        label: label,
        detail: detail,
        documentation: doc,
        kind: CompletionItemKind.method()
      }
    end)
  end

  defp type_method_completions(_namespace, _ast), do: []

  # -- Annotation completions --

  defp annotation_completions do
    # Exactly the implemented constraint annotations (spec section 4.2) —
    # the LSP must not offer surface the compiler doesn't accept.
    annotations = [
      {"@description", "Add a description to a field or tool"},
      {"@min", "Minimum value constraint"},
      {"@max", "Maximum value constraint"},
      {"@one_of", "Allowed values constraint"},
      {"@primary", "Mark field as primary key"},
      {"@unique", "Mark field as unique"},
      {"@default", "Default value for field"}
    ]

    Enum.map(annotations, fn {label, detail} ->
      %CompletionItem{
        label: label,
        detail: detail,
        kind: CompletionItemKind.property()
      }
    end)
  end

  # -- Snippet completions for common patterns --

  defp snippet_completions(_prefix) do
    [
      %CompletionItem{
        label: "handler http",
        detail: "HTTP handler template",
        kind: CompletionItemKind.snippet(),
        insert_text: "handler http ${1|GET,POST,PUT,PATCH,DELETE|} \"${2:/path}\" (${3:req}) -> {\n  $0\n}"
      },
      %CompletionItem{
        label: "on phase",
        detail: "Phase handler template",
        kind: CompletionItemKind.snippet(),
        insert_text: "on phase(Phase.${1:Name}) -> {\n  $0\n}"
      },
      %CompletionItem{
        label: "on start",
        detail: "Start handler template",
        kind: CompletionItemKind.snippet(),
        insert_text: "on start(${1:param}: ${2:String}) -> {\n  $0\n}"
      }
    ]
  end

  # -- Context detection --

  defp context_at(source, line_0, char_0) do
    lines = String.split(source, "\n")

    case Enum.at(lines, line_0) do
      nil ->
        :general

      line_text ->
        before = String.slice(line_text, 0, max(char_0, 0))
        trimmed = String.trim_trailing(before)

        cond do
          String.ends_with?(trimmed, ".") -> :dot_access
          Regex.match?(~r/:\s*$/, trimmed) -> :type_position
          Regex.match?(~r/->\s*$/, trimmed) -> :type_position
          true -> :general
        end
    end
  end

  defp namespace_before_dot(source, line_0, char_0) do
    lines = String.split(source, "\n")

    case Enum.at(lines, line_0) do
      nil ->
        ""

      line_text ->
        before = String.slice(line_text, 0, max(char_0, 0))

        case Regex.run(~r/(\w+)\.\s*$/, before) do
          [_, namespace] -> namespace
          _ -> ""
        end
    end
  end

  defp prefix_at(source, line_0, char_0) do
    lines = String.split(source, "\n")

    case Enum.at(lines, line_0) do
      nil ->
        ""

      line_text ->
        before = String.slice(line_text, 0, max(char_0 + 1, 0))

        case Regex.run(~r/([@&]?[\w]*)$/, before) do
          [_, prefix] -> prefix
          _ -> ""
        end
    end
  end

  defp matches_prefix?(_label, ""), do: true

  defp matches_prefix?(label, prefix) do
    String.starts_with?(String.downcase(label), String.downcase(prefix))
  end

  defp item_kind("keyword"), do: CompletionItemKind.keyword()
  defp item_kind("constant"), do: CompletionItemKind.constant()
  defp item_kind(_), do: CompletionItemKind.text()

  defp format_type(nil), do: "?"
  defp format_type(%{__struct__: Skein.AST.TypeRef, name: name, params: []}), do: name

  defp format_type(%{__struct__: Skein.AST.TypeRef, name: name, params: params}) do
    inner = Enum.map_join(params, ", ", &format_type/1)
    "#{name}<#{inner}>"
  end

  defp format_type(name) when is_binary(name), do: name
  defp format_type(_), do: "?"
end
