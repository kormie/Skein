defmodule Skein.Lsp.ServerTest do
  @moduledoc """
  Full request/response integration tests for the Skein language server.

  Drives `Skein.Lsp.Server` over a real LSP transport via `GenLSP.Test`,
  covering the initialize handshake, document lifecycle notifications,
  diagnostics publishing, and the main read requests (symbols, hover,
  completion, semantic tokens).
  """
  use ExUnit.Case, async: false

  import GenLSP.Test

  @valid_source """
  module Hello {
    fn greet(name: String) -> String {
      "Hello, ${name}!"
    }
  }
  """

  @invalid_source """
  module Broken {
    fn nope( -> String {
      "x"
    }
  }
  """

  setup do
    server = server(Skein.Lsp.Server)
    client = client(server)

    request(client, %{
      method: "initialize",
      id: 1,
      jsonrpc: "2.0",
      params: %{capabilities: %{}, rootUri: "file:///tmp/skein-lsp-test"}
    })

    assert_result(1, %{"capabilities" => _})

    notify(client, %{method: "initialized", jsonrpc: "2.0", params: %{}})

    [server: server, client: client]
  end

  defp did_open(client, uri, text) do
    notify(client, %{
      method: "textDocument/didOpen",
      jsonrpc: "2.0",
      params: %{textDocument: %{uri: uri, languageId: "skein", version: 1, text: text}}
    })
  end

  describe "initialize" do
    test "advertises the expected capabilities", %{client: client} do
      request(client, %{
        method: "initialize",
        id: 10,
        jsonrpc: "2.0",
        params: %{capabilities: %{}, rootUri: "file:///tmp/other"}
      })

      assert_result(10, %{
        "capabilities" => %{
          "textDocumentSync" => %{
            "openClose" => true,
            "save" => %{"includeText" => true},
            "change" => 1
          },
          "hoverProvider" => true,
          "definitionProvider" => true,
          "documentSymbolProvider" => true,
          "completionProvider" => %{"triggerCharacters" => _}
        },
        "serverInfo" => %{"name" => "Skein Language Server"}
      })
    end
  end

  describe "diagnostics" do
    test "publishes empty diagnostics for a valid document", %{client: client} do
      uri = "file:///tmp/valid.skein"
      did_open(client, uri, @valid_source)

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => []
      })
    end

    test "publishes error diagnostics for an invalid document", %{client: client} do
      uri = "file:///tmp/invalid.skein"
      did_open(client, uri, @invalid_source)

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [diagnostic | _]
      })

      assert diagnostic["severity"] == 1
      assert is_binary(diagnostic["message"])
    end

    test "clears diagnostics when a document is closed", %{client: client} do
      uri = "file:///tmp/closing.skein"
      did_open(client, uri, @invalid_source)

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [_ | _]
      })

      notify(client, %{
        method: "textDocument/didClose",
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: uri}}
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => []
      })
    end

    test "republishes diagnostics on change", %{client: client} do
      uri = "file:///tmp/changing.skein"
      did_open(client, uri, @valid_source)

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => []
      })

      notify(client, %{
        method: "textDocument/didChange",
        jsonrpc: "2.0",
        params: %{
          textDocument: %{uri: uri, version: 2},
          contentChanges: [%{text: @invalid_source}]
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [_ | _]
      })
    end
  end

  describe "textDocument/documentSymbol" do
    test "returns module and function symbols", %{client: client} do
      uri = "file:///tmp/symbols.skein"
      did_open(client, uri, @valid_source)
      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri})

      request(client, %{
        method: "textDocument/documentSymbol",
        id: 2,
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: uri}}
      })

      assert_result(2, [module_symbol | _])
      assert module_symbol["name"] == "Hello"
      assert Enum.any?(module_symbol["children"], &(&1["name"] =~ "greet"))
    end

    test "returns an empty list for an unknown document", %{client: client} do
      request(client, %{
        method: "textDocument/documentSymbol",
        id: 3,
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: "file:///tmp/never-opened.skein"}}
      })

      assert_result(3, [])
    end
  end

  describe "textDocument/hover" do
    test "returns hover info for a function name", %{client: client} do
      uri = "file:///tmp/hover.skein"
      did_open(client, uri, @valid_source)
      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri})

      # Position on "greet" (line index 1, character of the fn name)
      request(client, %{
        method: "textDocument/hover",
        id: 4,
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: uri}, position: %{line: 1, character: 6}}
      })

      assert_result(4, %{"contents" => %{"kind" => "markdown", "value" => value}})
      assert value =~ "greet"
    end
  end

  describe "textDocument/completion" do
    test "returns completion items", %{client: client} do
      uri = "file:///tmp/completion.skein"
      did_open(client, uri, @valid_source)
      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri})

      request(client, %{
        method: "textDocument/completion",
        id: 5,
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: uri}, position: %{line: 2, character: 4}}
      })

      assert_result(5, %{"isIncomplete" => false, "items" => items})
      assert is_list(items)
      assert items != []
    end
  end

  describe "textDocument/semanticTokens/full" do
    test "returns encoded semantic token data", %{client: client} do
      uri = "file:///tmp/tokens.skein"
      did_open(client, uri, @valid_source)
      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri})

      request(client, %{
        method: "textDocument/semanticTokens/full",
        id: 6,
        jsonrpc: "2.0",
        params: %{textDocument: %{uri: uri}}
      })

      assert_result(6, %{"data" => data})
      assert is_list(data)
      assert data != []
      assert rem(length(data), 5) == 0
    end
  end

  describe "shutdown" do
    test "responds to shutdown", %{client: client} do
      request(client, %{method: "shutdown", id: 7, jsonrpc: "2.0", params: nil})
      assert_result(7, nil)
    end
  end
end
