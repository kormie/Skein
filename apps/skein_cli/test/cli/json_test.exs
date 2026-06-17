defmodule Skein.CLI.JsonTest do
  @moduledoc """
  Contract tests for the versioned JSON output envelope (#284).

  Every command's `--json` output is a stable, documented envelope:
  `%{"schema" => "skein.<cmd>/v1", "ok" => bool, "data" => {...}}`. These
  tests pin the schema string, the `ok` flag semantics, and the `data` shape
  for each command — the agent contract.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.CLI.Json

  describe "encode/1" do
    test "produces valid JSON terminated by a single newline" do
      envelope = Json.trace({:ok, %{spans: [], count: 0}})
      encoded = Json.encode(envelope)

      assert String.ends_with?(encoded, "\n")
      assert {:ok, decoded} = Jason.decode(String.trim_trailing(encoded))
      assert decoded["schema"] == "skein.trace/v1"
    end
  end

  describe "trace/1" do
    test "wraps spans + count in the trace envelope, projecting known fields only" do
      result =
        {:ok,
         %{
           count: 1,
           spans: [
             %{
               kind: :http,
               method: :get,
               url: "/x",
               status: 200,
               outcome: :ok,
               duration_us: 1500,
               # non-serializable noise that must be dropped from the contract
               response: {:tuple, :not, :json}
             }
           ]
         }}

      assert %{schema: "skein.trace/v1", ok: true, data: data} = Json.trace(result)
      assert data.count == 1
      assert [span] = data.spans

      assert span == %{
               kind: "http",
               method: "get",
               url: "/x",
               status: 200,
               outcome: "ok",
               duration_us: 1500
             }

      # round-trips through Jason cleanly despite the dropped tuple field
      assert {:ok, _} = Jason.decode(Json.encode(Json.trace(result)))
    end

    test "an empty trace is ok with zero spans" do
      assert %{schema: "skein.trace/v1", ok: true, data: %{spans: [], count: 0}} =
               Json.trace({:ok, %{spans: [], count: 0}})
    end

    test "a malformed-flag error is ok:false with a message" do
      assert %{schema: "skein.trace/v1", ok: false, data: %{message: "bad flag"}} =
               Json.trace({:error, "bad flag"})
    end
  end

  describe "test/1" do
    test "ok:true when nothing failed and everything compiled" do
      result =
        {:ok,
         %{
           total: 2,
           passed: 2,
           failed: 0,
           files: 1,
           compile_errors: 0,
           compile_failed: [],
           results: [
             %{description: "a", status: :passed, kind: :test, file: "src/main.skein"},
             %{description: "b", status: :passed, kind: :scenario, file: "src/main.skein"}
           ]
         }}

      assert %{schema: "skein.test/v1", ok: true, data: data} = Json.test(result)
      assert data.total == 2
      assert data.passed == 2
      assert [%{description: "a", status: "passed", kind: "test"} | _] = data.results
    end

    test "ok:false with structured failure (error + location) when a test fails" do
      result =
        {:ok,
         %{
           total: 1,
           passed: 0,
           failed: 1,
           files: 1,
           compile_errors: 0,
           compile_failed: [],
           results: [
             %{
               description: "boom",
               status: :failed,
               kind: :scenario,
               file: "test/x.skein",
               error: "expected ok, got err",
               location: "test/x.skein:12"
             }
           ]
         }}

      assert %{ok: false, data: data} = Json.test(result)

      assert [
               %{
                 description: "boom",
                 status: "failed",
                 kind: "scenario",
                 file: "test/x.skein",
                 error: "expected ok, got err",
                 location: "test/x.skein:12"
               }
             ] = data.results
    end

    test "ok:false when a file failed to compile even if all run tests passed" do
      result =
        {:ok,
         %{
           total: 1,
           passed: 1,
           failed: 0,
           files: 1,
           compile_errors: 1,
           compile_failed: [%{file: "src/bad.skein", errors: [%{message: "boom"}]}],
           results: [%{description: "a", status: :passed, kind: :test, file: "src/main.skein"}]
         }}

      assert %{ok: false, data: data} = Json.test(result)
      assert data.compile_errors == 1
      assert [%{file: "src/bad.skein"}] = data.compile_failed
    end

    test "a top-level error is ok:false with a message" do
      assert %{schema: "skein.test/v1", ok: false, data: %{message: "No .skein files found"}} =
               Json.test({:error, "No .skein files found"})
    end

    property "ok mirrors (failed == 0 and compile_errors == 0)" do
      check all(
              passed <- StreamData.integer(0..50),
              failed <- StreamData.integer(0..50),
              compile_errors <- StreamData.integer(0..10)
            ) do
        result =
          {:ok,
           %{
             total: passed + failed,
             passed: passed,
             failed: failed,
             files: 1,
             compile_errors: compile_errors,
             compile_failed: [],
             results: []
           }}

        assert %{ok: ok} = Json.test(result)
        assert ok == (failed == 0 and compile_errors == 0)
      end
    end
  end

  describe "compile/1" do
    test "ok:true carries the module name and warnings, no errors" do
      result = {:ok, Skein.User.Demo, [%{message: "unused", code: "W0002"}]}

      assert %{schema: "skein.compile/v1", ok: true, data: data} = Json.compile(result)
      assert data.module == "Skein.User.Demo"
      assert data.errors == []
      assert [%{message: "unused"}] = data.warnings
    end

    test "a list of compile errors is ok:false in data.errors" do
      errors = [%{message: "type mismatch", code: "E0020"}]
      assert %{ok: false, data: data} = Json.compile({:error, errors})
      assert data.module == nil
      assert [%{message: "type mismatch"}] = data.errors
    end

    test "a string error (usage / missing file) is ok:false with a single message error" do
      assert %{ok: false, data: data} =
               Json.compile({:error, "Usage: skein compile <file.skein>"})

      assert [%{message: "Usage: skein compile <file.skein>"}] = data.errors
    end
  end

  describe "build/1" do
    test "ok:true when no files failed" do
      result =
        {:ok,
         %{
           compiled: 2,
           errors: 0,
           modules: [Skein.User.A, Skein.User.B],
           failed: []
         }}

      assert %{schema: "skein.build/v1", ok: true, data: data} = Json.build(result)
      assert data.compiled == 2
      assert data.modules == ["Skein.User.A", "Skein.User.B"]
      assert data.failed == []
    end

    test "ok:false when some files failed, surfacing per-file errors" do
      result =
        {:ok,
         %{
           compiled: 1,
           errors: 1,
           modules: [Skein.User.A],
           failed: [%{file: "src/bad.skein", errors: [%{message: "boom", code: "E0001"}]}]
         }}

      assert %{ok: false, data: data} = Json.build(result)
      assert data.errors == 1
      assert [%{file: "src/bad.skein", errors: [%{message: "boom"}]}] = data.failed
    end

    test "a top-level error (no files) is ok:false with a message" do
      assert %{schema: "skein.build/v1", ok: false, data: %{message: msg}} =
               Json.build({:error, "No .skein files found in ./src/"})

      assert msg =~ "No .skein files"
    end
  end
end
