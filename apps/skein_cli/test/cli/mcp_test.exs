defmodule Skein.CLI.McpTest do
  use ExUnit.Case, async: false

  alias Skein.CLI.Mcp

  @tmp_dir Path.expand("../../tmp/mcp_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    %{tmp_dir: @tmp_dir}
  end

  defp request(method, params, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp call_tool(name, arguments) do
    {:reply, response} =
      Mcp.handle_message(request("tools/call", %{"name" => name, "arguments" => arguments}))

    result = response["result"]
    [%{"type" => "text", "text" => text}] = result["content"]
    {result["isError"], text}
  end

  describe "protocol" do
    test "initialize returns server info and tool capability" do
      message = request("initialize", %{"protocolVersion" => "2024-11-05"})

      assert {:reply, response} = Mcp.handle_message(message)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["protocolVersion"] == "2024-11-05"
      assert response["result"]["serverInfo"]["name"] == "skein"
      assert Map.has_key?(response["result"]["capabilities"], "tools")
    end

    test "initialized notification gets no reply" do
      assert :noreply =
               Mcp.handle_message(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    end

    test "ping is answered" do
      assert {:reply, %{"result" => %{}}} = Mcp.handle_message(request("ping", %{}))
    end

    test "tools/list exposes the three Skein tools" do
      assert {:reply, response} = Mcp.handle_message(request("tools/list", %{}))

      names = Enum.map(response["result"]["tools"], & &1["name"])
      assert "skein_spec_lookup" in names
      assert "skein_docs_search" in names
      assert "skein_compile_check" in names

      for tool <- response["result"]["tools"] do
        assert %{"type" => "object"} = tool["inputSchema"]
        assert is_binary(tool["description"])
      end
    end

    test "unknown method returns a JSON-RPC error" do
      assert {:reply, %{"error" => %{"code" => -32601}}} =
               Mcp.handle_message(request("bogus/method", %{}))
    end

    test "unknown tool returns a JSON-RPC error" do
      assert {:reply, %{"error" => %{"code" => -32602, "message" => message}}} =
               Mcp.handle_message(request("tools/call", %{"name" => "nope", "arguments" => %{}}))

      assert message =~ "nope"
    end
  end

  describe "skein_spec_lookup" do
    test "finds a section by number" do
      {is_error, text} = call_tool("skein_spec_lookup", %{"section" => "6.4"})

      assert is_error == false
      assert text =~ "6.4 LLM"
      assert text =~ "llm.chat"
    end

    test "finds a section by title fragment" do
      {is_error, text} = call_tool("skein_spec_lookup", %{"section" => "capabilities"})

      assert is_error == false
      assert text =~ "capability"
    end

    test "lists available sections when nothing matches" do
      {is_error, text} = call_tool("skein_spec_lookup", %{"section" => "zzz_nonexistent"})

      assert is_error == true
      assert text =~ "Available sections"
      assert text =~ "6.4 LLM"
    end
  end

  describe "skein_docs_search" do
    test "returns sections with matching lines" do
      {is_error, text} = call_tool("skein_docs_search", %{"query" => "idempotent"})

      assert is_error == false
      assert text =~ "idempotent"
      assert text =~ "##"
    end

    test "reports no matches" do
      {is_error, text} = call_tool("skein_docs_search", %{"query" => "zzz_nonexistent_term"})

      assert is_error == false
      assert text =~ "No matches"
    end

    test "rejects an empty query" do
      {is_error, text} = call_tool("skein_docs_search", %{"query" => "   "})

      assert is_error == true
      assert text =~ "empty"
    end
  end

  describe "skein_compile_check" do
    test "returns ok for a valid file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "good.skein")

      File.write!(path, """
      module Good {
        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }
      }
      """)

      {is_error, text} = call_tool("skein_compile_check", %{"path" => path})

      assert is_error == false
      assert {:ok, result} = Jason.decode(text)
      assert result["ok"] == true
      assert result["files_checked"] == 1
      assert result["errors"] == []
    end

    test "returns structured errors with fix_hint and fix_code", %{tmp_dir: tmp} do
      path = Path.join(tmp, "bad.skein")

      # http.get without the http.out capability -> E0012 with fix hints
      File.write!(path, """
      module Bad {
        fn fetch() -> String {
          let r = http.get("https://example.com/data")
          "done"
        }
      }
      """)

      {is_error, text} = call_tool("skein_compile_check", %{"path" => path})

      assert is_error == false
      assert {:ok, result} = Jason.decode(text)
      assert result["ok"] == false
      assert [error | _] = result["errors"]
      assert error["code"] =~ ~r/^E\d{4}$/
      assert is_binary(error["message"])
      assert error["location"]["line"]
      assert is_binary(error["fix_hint"])
      assert is_binary(error["fix_code"])
    end

    test "machine-applicable errors surface span and edit_kind", %{tmp_dir: tmp} do
      path = Path.join(tmp, "fixable.skein")

      # http.get without the http.out capability -> E0012 with an
      # insert_line edit at the module body's first line
      File.write!(path, """
      module Fixable {
        fn fetch() -> Result[String, HttpError] {
          let r = http.get("https://example.com/data")
          r
        }
      }
      """)

      {is_error, text} = call_tool("skein_compile_check", %{"path" => path})

      assert is_error == false
      assert {:ok, result} = Jason.decode(text)
      assert [error | _] = result["errors"]
      assert error["code"] == "E0012"
      assert error["edit_kind"] == "insert_line"

      assert %{"start" => %{"line" => 2, "col" => 3}, "end" => %{"line" => 2, "col" => 3}} =
               error["span"]
    end

    test "compiles a project directory's src tree", %{tmp_dir: tmp} do
      project = Path.join(tmp, "proj")
      File.mkdir_p!(Path.join(project, "src"))

      File.write!(Path.join(project, "src/a.skein"), """
      module ProjA {
        fn one() -> Int { 1 }
      }
      """)

      File.write!(Path.join(project, "src/b.skein"), """
      module ProjB {
        fn two() -> Int { 2 }
      }
      """)

      {is_error, text} = call_tool("skein_compile_check", %{"path" => project})

      assert is_error == false
      assert {:ok, %{"ok" => true, "files_checked" => 2}} = Jason.decode(text)
    end

    test "warnings-only file reports ok true with populated warnings", %{tmp_dir: tmp} do
      path = Path.join(tmp, "warny.skein")

      # Declared but never exercised capability -> W0002
      File.write!(path, """
      module Warny {
        capability http.out("example.com")

        fn pure() -> Int { 42 }
      }
      """)

      {is_error, text} = call_tool("skein_compile_check", %{"path" => path})

      assert is_error == false
      assert {:ok, result} = Jason.decode(text)
      assert result["ok"] == true
      assert result["errors"] == []
      assert [warning | _] = result["warnings"]
      assert warning["code"] == "W0002"
      assert warning["severity"] == "warning"
      assert warning["location"]["line"]
      assert is_binary(warning["fix_hint"])
    end

    test "project mode checks test/ files too and reports their warnings", %{tmp_dir: tmp} do
      project = Path.join(tmp, "proj_with_tests")
      File.mkdir_p!(Path.join(project, "src"))
      File.mkdir_p!(Path.join(project, "test"))

      File.write!(Path.join(project, "src/main.skein"), """
      module Main {
        fn one() -> Int { 1 }
      }
      """)

      File.write!(Path.join(project, "test/main_test.skein"), """
      module MainTest {
        capability http.out("never.used")

        test "one is one" {
          assert 1 == 1
        }
      }
      """)

      {is_error, text} = call_tool("skein_compile_check", %{"path" => project})

      assert is_error == false
      assert {:ok, result} = Jason.decode(text)
      assert result["ok"] == true
      assert result["files_checked"] == 2
      assert [warning] = result["warnings"]
      assert warning["code"] == "W0002"
      assert warning["location"]["file"] =~ "test/main_test.skein"
    end

    test "errors for a missing path" do
      {is_error, text} = call_tool("skein_compile_check", %{"path" => "/nope/missing.skein"})

      assert is_error == true
      assert text =~ "No such file or directory"
    end

    test "errors for a project with no sources", %{tmp_dir: tmp} do
      project = Path.join(tmp, "empty_proj")
      File.mkdir_p!(project)

      {is_error, text} = call_tool("skein_compile_check", %{"path" => project})

      assert is_error == true
      assert text =~ "No .skein files found"
    end
  end

  describe "stdio framing" do
    test "serve/1 answers requests line by line and stops at EOF" do
      input =
        [
          request("initialize", %{"protocolVersion" => "2024-11-05"}),
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          request("tools/list", %{}, 2)
        ]
        |> Enum.map_join("\n", &Jason.encode!/1)
        |> Kernel.<>("\n")

      {:ok, stdin} = StringIO.open(input)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Skein.CLI.Mcp.serve(stdin)
        end)

      responses =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      # Notification produced no response: two replies for three messages
      assert [init_response, list_response] = responses
      assert init_response["id"] == 1
      assert init_response["result"]["serverInfo"]["name"] == "skein"
      assert list_response["id"] == 2
      assert length(list_response["result"]["tools"]) == 3
    end

    test "malformed JSON yields a parse error response" do
      {:ok, stdin} = StringIO.open("not json\n")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Skein.CLI.Mcp.serve(stdin)
        end)

      assert %{"error" => %{"code" => -32700}} = Jason.decode!(String.trim(output))
    end
  end
end
