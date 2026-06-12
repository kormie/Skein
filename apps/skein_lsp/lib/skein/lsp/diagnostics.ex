defmodule Skein.Lsp.Diagnostics do
  @moduledoc """
  Converts Skein compiler errors into LSP diagnostics.
  """

  alias GenLSP.Enumerations.DiagnosticSeverity

  alias GenLSP.Structures.{
    Diagnostic,
    Position,
    Range
  }

  alias GenLSP.Notifications.TextDocumentPublishDiagnostics

  @doc """
  Compiles source and returns `{diagnostics, ast | nil}`.

  Runs lexer -> parser -> analyzer pipeline, collecting errors at each stage.
  Returns the AST if parsing succeeds (even if analysis finds warnings).
  """
  @spec compile_diagnostics(String.t(), String.t()) :: {[Diagnostic.t()], any() | nil}
  def compile_diagnostics(source, file) do
    case Skein.Lexer.tokenize(source) do
      {:error, errors} ->
        {errors_to_diagnostics(errors), nil}

      {:ok, tokens} ->
        case Skein.Parser.parse(tokens, file) do
          {:error, errors} ->
            {errors_to_diagnostics(errors), nil}

          {:ok, ast} ->
            case Skein.Analyzer.analyze(ast) do
              {:error, errors} ->
                {errors_to_diagnostics(errors), ast}

              {:ok, analyzed_ast, warnings} ->
                {errors_to_diagnostics(warnings), analyzed_ast}

              {:ok, analyzed_ast} ->
                {[], analyzed_ast}
            end
        end
    end
  end

  @doc """
  Publishes diagnostics to the client for a given URI.
  """
  @spec publish(GenLSP.LSP.t(), String.t(), [Diagnostic.t()]) :: :ok
  def publish(lsp, uri, diagnostics) do
    GenLSP.notify(lsp, %TextDocumentPublishDiagnostics{
      params: %GenLSP.Structures.PublishDiagnosticsParams{
        uri: uri,
        diagnostics: diagnostics
      }
    })
  end

  @doc """
  Clears diagnostics for a URI by publishing an empty list.
  """
  @spec publish_clear(GenLSP.LSP.t(), String.t()) :: :ok
  def publish_clear(lsp, uri) do
    publish(lsp, uri, [])
  end

  @doc """
  Converts a list of `Skein.Error` structs to LSP `Diagnostic` structs.
  """
  @spec errors_to_diagnostics([Skein.Error.t()]) :: [Diagnostic.t()]
  def errors_to_diagnostics(errors) do
    Enum.map(errors, &error_to_diagnostic/1)
  end

  defp error_to_diagnostic(%Skein.Error{} = error) do
    message =
      build_message(error.code, error.message, error.fix_hint)

    %Diagnostic{
      range: diagnostic_range(error),
      severity: severity(error.severity),
      code: error.code,
      source: "skein",
      message: message,
      # Fix data rides along so textDocument/codeAction can answer from
      # the diagnostic alone (string keys survive the JSON round-trip)
      data: %{
        "code" => error.code,
        "fix_hint" => error.fix_hint,
        "fix_code" => error.fix_code,
        "span" => encode_span(error.span),
        "edit_kind" => error.edit_kind && to_string(error.edit_kind)
      }
    }
  end

  # A non-empty span gives the diagnostic its exact extent; otherwise fall
  # back to the point location (widened by the context line when known).
  defp diagnostic_range(%Skein.Error{span: %{start: start, end: stop}})
       when start != stop do
    %Range{
      start: %Position{line: start.line - 1, character: start.col - 1},
      end: %Position{line: stop.line - 1, character: stop.col - 1}
    }
  end

  defp diagnostic_range(%Skein.Error{} = error) do
    line = max((error.location[:line] || 1) - 1, 0)
    col = max((error.location[:col] || 1) - 1, 0)

    %Range{
      start: %Position{line: line, character: col},
      end: %Position{line: line, character: col + diagnostic_length(error)}
    }
  end

  # String-keyed so server-side reads and client JSON round-trips agree.
  defp encode_span(%{start: start, end: stop}) do
    %{
      "start" => %{"line" => start.line, "col" => start.col},
      "end" => %{"line" => stop.line, "col" => stop.col}
    }
  end

  defp encode_span(nil), do: nil

  defp build_message(code, message, nil), do: "[#{code}] #{message}"

  defp build_message(code, message, fix_hint) do
    "[#{code}] #{message}\nHint: #{fix_hint}"
  end

  defp severity(:error), do: DiagnosticSeverity.error()
  defp severity(:warning), do: DiagnosticSeverity.warning()
  defp severity(_), do: DiagnosticSeverity.information()

  defp diagnostic_length(%{context: context}) when is_binary(context) do
    String.length(context)
  end

  defp diagnostic_length(_), do: 1
end
