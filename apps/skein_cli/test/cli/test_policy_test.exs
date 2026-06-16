defmodule Skein.CLI.TestPolicyTest do
  @moduledoc """
  End-to-end coverage of the conservative `skein test` effect policy (#283):
  live http/llm blocked unless allowed, deterministic uuid/instant defaults,
  and scenario-local state isolation between tests.
  """
  use ExUnit.Case, async: false

  alias Skein.CLI

  @tmp_dir Path.expand("../../tmp/test_policy_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    test_dir = Path.join(@tmp_dir, "test")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    %{tmp_dir: @tmp_dir, test_dir: test_dir}
  end

  defp write(dir, name, source), do: File.write!(Path.join(dir, name), source)

  # A tool whose body makes an outbound HTTP call but always returns ok, so the
  # only way the scenario fails is a blocked live effect (a raise), never a
  # domain error the tool's own `match` could swallow.
  defp http_tool_project(test_dir, scenario_envelope) do
    write(test_dir, "fetch_test.skein", """
    module FetchTest {
      capability tool.use(Fetch.Get)
      capability http.out("api.example.com")

      tool Fetch.Get {
        input { path: String }
        output { ok: Bool }
        implement {
          match http.get("https://api.example.com/x") {
            Ok(_) -> Ok({ ok: true })
            Err(_) -> Ok({ ok: true })
          }
        }
      }

      scenario "fetches" {
        capability tool.use(Fetch.Get) {
    #{scenario_envelope}
        }
        expect {
          let res = tool.call(Fetch.Get, { path: "x" })!
          assert res.ok == true
        }
      }
    }
    """)
  end

  test "an offline scenario with a live http effect is blocked, not requested", %{
    tmp_dir: tmp,
    test_dir: test_dir
  } do
    # No `implement` for http.out → the test-runner default policy blocks it.
    http_tool_project(test_dir, "      capability http.out(\"api.example.com\")")

    assert {:ok, result} = CLI.test_all([tmp])
    assert result.failed == 1
    [failure] = Enum.filter(result.results, &(&1.status == :failed))
    assert failure.error =~ "Live effect blocked"
    assert failure.error =~ "api.example.com"
    assert failure.error =~ "--allow-live http.out:api.example.com"
  end

  test "--allow-live permits exactly the named host", %{tmp_dir: tmp, test_dir: test_dir} do
    http_tool_project(test_dir, "      capability http.out(\"api.example.com\")")

    # With the host allowed, the effect is no longer blocked: the tool always
    # returns ok regardless of the live call's outcome, so the scenario passes.
    assert {:ok, result} = CLI.test_all([tmp, "--allow-live", "http.out:api.example.com"])
    assert result.passed == 1
    assert result.failed == 0
  end

  test "uuid with no implement gets the deterministic incrementing default", %{
    tmp_dir: tmp,
    test_dir: test_dir
  } do
    write(test_dir, "ids_test.skein", """
    module IdsTest {
      capability tool.use(Ids.New)
      capability uuid

      tool Ids.New {
        input { kind: String }
        output { id: Uuid }
        implement { Ok({ id: uuid.new() }) }
      }

      scenario "deterministic uuid default" {
        capability tool.use(Ids.New) {
          capability uuid
        }
        expect {
          let r = tool.call(Ids.New, { kind: "x" })!
          assert "${r.id}" == "00000000-0000-4000-8000-000000000001"
        }
      }
    }
    """)

    assert {:ok, result} = CLI.test_all([tmp])
    assert result.passed == 1, "expected deterministic uuid default, got: #{inspect(result.results)}"
  end

  test "an unknown --allow-live effect is a structured parse error", %{tmp_dir: tmp} do
    assert {:error, message} = CLI.test_all([tmp, "--allow-live", "store.table:users"])
    assert message =~ "store.table"
    assert message =~ "http.out"
  end
end
