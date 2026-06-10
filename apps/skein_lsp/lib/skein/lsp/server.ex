defmodule Skein.Lsp.Server do
  @moduledoc """
  Skein Language Server Protocol implementation.

  Provides IDE features for the Skein programming language:
  - Diagnostics (compile errors and warnings)
  - Document symbols (module, function, type, handler outlines)
  - Hover information (type info, documentation)
  - Go-to-definition
  - Code completion
  - Semantic token highlighting
  """
  use GenLSP

  alias GenLSP.Enumerations.TextDocumentSyncKind

  alias GenLSP.Structures.{
    CompletionList,
    CompletionOptions,
    DidOpenTextDocumentParams,
    DidSaveTextDocumentParams,
    DidChangeTextDocumentParams,
    DidCloseTextDocumentParams,
    InitializeParams,
    InitializeResult,
    Location,
    Position,
    Range,
    SaveOptions,
    SemanticTokensLegend,
    SemanticTokensOptions,
    ServerCapabilities,
    TextDocumentSyncOptions
  }

  alias GenLSP.Requests.{
    Initialize,
    Shutdown,
    TextDocumentCompletion,
    TextDocumentDefinition,
    TextDocumentDocumentSymbol,
    TextDocumentHover,
    TextDocumentSemanticTokensFull
  }

  alias GenLSP.Notifications.{
    Exit,
    Initialized,
    TextDocumentDidChange,
    TextDocumentDidClose,
    TextDocumentDidOpen,
    TextDocumentDidSave
  }

  alias Skein.Lsp.Diagnostics
  alias Skein.Lsp.Symbols
  alias Skein.Lsp.Completions
  alias Skein.Lsp.HoverProvider
  alias Skein.Lsp.SemanticTokens, as: SkeinSemanticTokens

  # -- Initialization --

  @doc """
  Starts the language server process.

  Options are forwarded to `GenLSP.start_link/3` (e.g. `:buffer`, `:assigns`,
  `:task_supervisor`, or `:communication` for the transport). This is also
  the start function used by the `child_spec/1` that `use GenLSP` generates.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenLSP.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(lsp, _args) do
    {:ok,
     assign(lsp,
       documents: %{},
       asts: %{},
       root_uri: nil
     )}
  end

  # -- Request Handlers --

  @impl true
  def handle_request(%Initialize{params: %InitializeParams{root_uri: root_uri}}, lsp) do
    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           save: %SaveOptions{include_text: true},
           change: TextDocumentSyncKind.full()
         },
         completion_provider: %CompletionOptions{
           trigger_characters: [".", ":", "@", "&", "|"],
           resolve_provider: false
         },
         hover_provider: true,
         definition_provider: true,
         document_symbol_provider: true,
         semantic_tokens_provider: %SemanticTokensOptions{
           legend: semantic_tokens_legend(),
           full: true
         }
       },
       server_info: %{name: "Skein Language Server", version: "0.1.0"}
     }, assign(lsp, root_uri: root_uri)}
  end

  def handle_request(%Shutdown{}, lsp) do
    {:reply, nil, lsp}
  end

  def handle_request(
        %TextDocumentDocumentSymbol{
          params: %{text_document: %{uri: uri}}
        },
        lsp
      ) do
    symbols =
      case Map.get(assigns(lsp).asts, uri) do
        nil -> []
        ast -> Symbols.document_symbols(ast)
      end

    {:reply, symbols, lsp}
  end

  def handle_request(
        %TextDocumentHover{
          params: %{text_document: %{uri: uri}, position: position}
        },
        lsp
      ) do
    hover =
      case Map.get(assigns(lsp).asts, uri) do
        nil ->
          nil

        ast ->
          source = Map.get(assigns(lsp).documents, uri, "")
          HoverProvider.hover(ast, source, position)
      end

    {:reply, hover, lsp}
  end

  def handle_request(
        %TextDocumentDefinition{
          params: %{text_document: %{uri: uri}, position: position}
        },
        lsp
      ) do
    location =
      case Map.get(assigns(lsp).asts, uri) do
        nil ->
          nil

        ast ->
          source = Map.get(assigns(lsp).documents, uri, "")

          case HoverProvider.definition(ast, source, position) do
            nil -> nil
            {line, col} -> %Location{uri: uri, range: pos_to_range(line, col)}
          end
      end

    {:reply, location, lsp}
  end

  def handle_request(
        %TextDocumentCompletion{
          params: %{text_document: %{uri: uri}, position: position}
        },
        lsp
      ) do
    ast = Map.get(assigns(lsp).asts, uri)
    source = Map.get(assigns(lsp).documents, uri, "")
    items = Completions.complete(ast, source, position)

    {:reply, %CompletionList{is_incomplete: false, items: items}, lsp}
  end

  def handle_request(
        %TextDocumentSemanticTokensFull{
          params: %{text_document: %{uri: uri}}
        },
        lsp
      ) do
    tokens =
      case Map.get(assigns(lsp).documents, uri) do
        nil ->
          %GenLSP.Structures.SemanticTokens{data: []}

        source ->
          data = SkeinSemanticTokens.encode(source)
          %GenLSP.Structures.SemanticTokens{data: data}
      end

    {:reply, tokens, lsp}
  end

  def handle_request(_request, lsp) do
    {:noreply, lsp}
  end

  # -- Notification Handlers --

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    GenLSP.log(lsp, "[Skein] Language server initialized")
    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidOpen{
          params: %DidOpenTextDocumentParams{
            text_document: %{uri: uri, text: text}
          }
        },
        lsp
      ) do
    lsp = put_document(lsp, uri, text)
    lsp = compile_and_publish(lsp, uri, text)
    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidChange{
          params: %DidChangeTextDocumentParams{
            text_document: %{uri: uri},
            content_changes: [%{text: text} | _]
          }
        },
        lsp
      ) do
    lsp = put_document(lsp, uri, text)
    lsp = compile_and_publish(lsp, uri, text)
    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidSave{
          params: %DidSaveTextDocumentParams{
            text_document: %{uri: uri},
            text: text
          }
        },
        lsp
      ) do
    text = text || Map.get(assigns(lsp).documents, uri, "")
    lsp = put_document(lsp, uri, text)
    lsp = compile_and_publish(lsp, uri, text)
    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidClose{
          params: %DidCloseTextDocumentParams{text_document: %{uri: uri}}
        },
        lsp
      ) do
    # Clear diagnostics for closed document
    Diagnostics.publish_clear(lsp, uri)

    lsp =
      lsp
      |> update_assign(:documents, &Map.delete(&1, uri))
      |> update_assign(:asts, &Map.delete(&1, uri))

    {:noreply, lsp}
  end

  def handle_notification(%Exit{}, lsp) do
    System.halt(0)
    {:noreply, lsp}
  end

  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  # -- Private Helpers --

  defp put_document(lsp, uri, text) do
    update_assign(lsp, :documents, &Map.put(&1, uri, text))
  end

  defp compile_and_publish(lsp, uri, source) do
    file = uri_to_path(uri)

    {diagnostics, ast} = Diagnostics.compile_diagnostics(source, file)

    Diagnostics.publish(lsp, uri, diagnostics)

    case ast do
      nil -> update_assign(lsp, :asts, &Map.delete(&1, uri))
      ast -> update_assign(lsp, :asts, &Map.put(&1, uri, ast))
    end
  end

  defp update_assign(lsp, key, fun) do
    assign(lsp, [{key, fun.(assigns(lsp)[key])}])
  end

  defp uri_to_path("file://" <> path), do: URI.decode(path)
  defp uri_to_path(path), do: path

  defp pos_to_range(line, col) do
    %Range{
      start: %Position{line: max(line - 1, 0), character: max(col - 1, 0)},
      end: %Position{line: max(line - 1, 0), character: max(col - 1, 0)}
    }
  end

  defp semantic_tokens_legend do
    %SemanticTokensLegend{
      token_types: [
        "namespace",
        "type",
        "class",
        "enum",
        "interface",
        "struct",
        "typeParameter",
        "parameter",
        "variable",
        "property",
        "enumMember",
        "event",
        "function",
        "method",
        "macro",
        "keyword",
        "modifier",
        "comment",
        "string",
        "number",
        "regexp",
        "operator",
        "decorator"
      ],
      token_modifiers: [
        "declaration",
        "definition",
        "readonly",
        "static",
        "deprecated",
        "abstract",
        "async",
        "modification",
        "documentation",
        "defaultLibrary"
      ]
    }
  end
end
