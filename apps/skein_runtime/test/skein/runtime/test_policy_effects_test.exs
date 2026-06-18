defmodule Skein.Runtime.TestPolicyEffectsTest do
  @moduledoc """
  The test-runner policy (#283) wired through the effect modules: uuid/instant
  get deterministic defaults, http.out/model are blocked unless allowed, and
  production (no policy) is untouched.
  """
  # async: false — the `llm` cases mutate the node-global LLM backend
  # (`Llm.set_backend/1`, backed by `:persistent_term`), so this module must not
  # run concurrently with other async tests, matching every other backend-mutating
  # test file. Running async raced the global backend and flaked intermittently.
  use ExUnit.Case, async: false

  alias Skein.Runtime.Http
  alias Skein.Runtime.LiveEffectError
  alias Skein.Runtime.Nondeterminism
  alias Skein.Runtime.TestPolicy

  setup do
    on_exit(fn -> TestPolicy.clear() end)
    :ok
  end

  describe "uuid/instant under the policy" do
    test "uuid is the deterministic incrementing default" do
      TestPolicy.with_policy([], fn ->
        assert Nondeterminism.uuid() == "00000000-0000-4000-8000-000000000001"
        assert Nondeterminism.uuid() == "00000000-0000-4000-8000-000000000002"
      end)
    end

    test "instant is the deterministic stepping default" do
      TestPolicy.with_policy([], fn ->
        assert Nondeterminism.instant() == "2026-01-01T00:00:00Z"
        assert Nondeterminism.instant() == "2026-01-01T00:00:01Z"
      end)
    end

    test "--allow-live uuid restores real (non-deterministic) generation" do
      TestPolicy.with_policy([allow_live: [{"uuid", :all}]], fn ->
        id = Nondeterminism.uuid()
        refute id == "00000000-0000-4000-8000-000000000001"
        assert {:ok, _} = Skein.Runtime.Stdlib.Uuid.parse(id)
      end)
    end

    test "outside a policy, uuid is live (production untouched)" do
      id = Nondeterminism.uuid()
      refute id == "00000000-0000-4000-8000-000000000001"
    end
  end

  describe "http.out under the policy" do
    @caps [%{kind: "http.out", params: []}]

    test "a request with no implement/replay is blocked" do
      TestPolicy.with_policy([], fn ->
        assert_raise LiveEffectError, ~r/Live effect blocked/, fn ->
          Http.get("https://api.stripe.com/v1/charges", @caps)
        end
      end)
    end

    test "the blocked error names the host and the fixes" do
      error =
        assert_raise LiveEffectError, fn ->
          TestPolicy.with_policy([], fn ->
            Http.get("https://api.stripe.com/v1/charges", @caps)
          end)
        end

      assert error.effect == "http.out"
      assert error.scope == "api.stripe.com"
      assert error.message =~ "api.stripe.com"
      assert error.message =~ "--allow-live http.out:api.stripe.com"
      assert error.message =~ "implement"
    end

    test "--allow-live permits exactly the allowed host and still blocks others" do
      TestPolicy.with_policy([allow_live: [{"http.out", "api.stripe.com"}]], fn ->
        # The allowed host falls through to a real request: it returns a normal
        # Result (a transport error offline, or an upstream status online) rather
        # than raising LiveEffectError — proving it was not blocked.
        result = Http.get("https://api.stripe.com/v1/charges", @caps)
        assert match?({:ok, _}, result) or match?({:error, _}, result)

        assert_raise LiveEffectError, fn ->
          Http.get("https://evil.example.com/", @caps)
        end
      end)
    end
  end

  describe "llm under the policy" do
    setup do
      previous = Skein.Runtime.Llm.get_backend()
      on_exit(fn -> Skein.Runtime.Llm.set_backend(previous) end)
      :ok
    end

    @caps [%{kind: "model", params: ["test-model"]}]

    test "a live backend is blocked under the policy" do
      Skein.Runtime.Llm.set_backend(LiveStubBackend)

      TestPolicy.with_policy([], fn ->
        assert_raise LiveEffectError, ~r/Live effect blocked/, fn ->
          Skein.Runtime.Llm.chat("test-model", "sys", "hi", @caps)
        end
      end)
    end

    test "the deterministic test backend is allowed (no setup needed)" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      TestPolicy.with_policy([], fn ->
        assert {:ok, _} = Skein.Runtime.Llm.chat("test-model", "sys", "hi", @caps)
      end)
    end

    test "--allow-live model lets a live backend through" do
      Skein.Runtime.Llm.set_backend(LiveStubBackend)

      TestPolicy.with_policy([allow_live: [{"model", :all}]], fn ->
        # Allowed → not blocked; the call reaches the (live-classified) backend.
        assert {:ok, "live-stub"} = Skein.Runtime.Llm.chat("test-model", "sys", "hi", @caps)
      end)
    end
  end
end

defmodule Skein.Runtime.TestPolicyIsolationTest do
  @moduledoc "reset_scenario_state/0 clears store/memory/event so state never leaks (#283)."
  use ExUnit.Case, async: false

  alias Skein.Runtime.{Memory, Store, TestPolicy}

  @store_caps [%{kind: "store.table", params: ["users"]}]
  @mem_caps [%{kind: "memory.kv", params: ["sess"]}]

  test "reset clears store and memory state" do
    assert {:ok, _} = Store.put("users", %{id: "u1", name: "Alice"}, @store_caps)
    assert {:ok, _} = Memory.put("sess", "k", "v", @mem_caps)
    assert {:ok, _} = Store.get("users", "u1", @store_caps)

    TestPolicy.reset_scenario_state()

    assert {:error, :not_found} = Store.get("users", "u1", @store_caps)
    assert {:error, :not_found} = Memory.get("sess", "k", @mem_caps)
  end
end

defmodule LiveStubBackend do
  @moduledoc "A backend that is not in the offline allow-list, so it counts as live."
  alias Skein.Runtime.Llm.Response

  def chat(_model, _system, _input), do: {:ok, %Response{text: "live-stub"}}
end
