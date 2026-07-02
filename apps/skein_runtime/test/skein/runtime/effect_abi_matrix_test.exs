defmodule Skein.Runtime.EffectABIMatrixTest do
  @moduledoc """
  The registry-driven **runtime ABI-matrix** (C1/#296): for every effect
  method in `Skein.EffectABI`, this file asserts

  1. the runtime dispatch target exists (module + function exported), and
  2. the **live success and failure value shapes** the compiled code will
     see — `{:ok, _}`/`{:error, _}` for `Result`-typed effects (failure =
     capability/scope denial, plus method-specific failures), bare values
     for the non-`Result` effects (`memory.list`, `uuid.new`,
     `instant.now`, `trace.annotate`), where a capability denial raises
     (defense-in-depth behind the compile-time check).

  **Completeness is enforced**: a registry entry without a shape check here
  fails the completeness test, so a new/renamed effect method cannot ship
  without its runtime shape pinned. This is the gate that turns
  analyzer/runtime drift (the old `timer.cancel` `Result` vs bare `:ok`)
  into a test failure.

  Replay shapes are pinned separately by `replay_test.exs`/`llm` golden
  tests (replay intercepts http/llm/tool/uuid/instant only).
  """
  use ExUnit.Case, async: false

  alias Skein.EffectABI

  alias Skein.Runtime.{
    EventStore,
    Http,
    Instant,
    Llm,
    Memory,
    Process,
    Queue,
    Store,
    Timer,
    Tool,
    Topic,
    Trace,
    Uuid
  }

  # Wildcard (parameterless) capability for a kind.
  defp cap(kind), do: [%{kind: kind, params: []}]

  setup_all do
    previous_backend = Llm.get_backend()
    Llm.set_backend(Skein.Runtime.Llm.TestBackend)
    on_exit(fn -> Llm.set_backend(previous_backend) end)
    :ok
  end

  setup do
    EventStore.clear()
    Timer.reset_all()
    :ok
  end

  # ── Completeness: every registry method has a shape check below ────────

  @shape_checked [
    {"http", "get"},
    {"http", "post"},
    {"http", "put"},
    {"http", "patch"},
    {"http", "delete"},
    {"memory", "put"},
    {"memory", "get"},
    {"memory", "delete"},
    {"memory", "list"},
    {"llm", "chat"},
    {"llm", "json"},
    {"llm", "stream"},
    {"llm", "embed"},
    {"tool", "call"},
    {"tool", "list"},
    {"tool", "schema"},
    {"topic", "publish"},
    {"queue", "publish"},
    {"trace", "annotate"},
    {"event", "log"},
    {"process", "spawn"},
    {"timer", "after"},
    {"timer", "interval"},
    {"timer", "cancel"},
    {"uuid", "new"},
    {"instant", "now"}
  ]

  @store_shape_checked ["get", "put", "delete", "query"]

  test "every registry effect method has a live shape check in this file" do
    registry = EffectABI.entries() |> Enum.map(&{&1.ns, &1.method}) |> Enum.sort()

    assert registry == Enum.sort(@shape_checked),
           "the ABI matrix is incomplete — add a shape check (and its " <>
             "@shape_checked row) for every Skein.EffectABI entry"
  end

  test "every registry store method has a live shape check in this file" do
    assert EffectABI.store_methods() |> Enum.sort() == Enum.sort(@store_shape_checked)
  end

  test "every registry runtime dispatch target is a real exported function" do
    checked =
      for entry <- EffectABI.entries() ++ EffectABI.store_entries() do
        {mod, fun} = entry.runtime
        {:module, ^mod} = Code.ensure_loaded(mod)

        exported? =
          mod.__info__(:functions)
          |> Enum.any?(fn {name, _arity} -> name == fun end)

        {mod, fun, exported?}
      end

    missing = for {mod, fun, false} <- checked, do: "#{inspect(mod)}.#{fun}"
    assert missing == [], "registry names missing runtime functions: #{inspect(missing)}"
  end

  # ── HTTP (stub server: success + denial + transport failure) ───────────

  describe "http shapes" do
    setup do
      # A tiny local stub so success shapes are exercised live, offline.
      {:ok, server} =
        Bandit.start_link(
          plug: fn conn, _opts ->
            Plug.Conn.send_resp(conn, 200, ~s({"ok": true}))
          end,
          port: 0,
          startup_log: false
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Elixir.Process.exit(server, :normal) end)
      %{url: "http://127.0.0.1:#{port}/x"}
    end

    test "http.get/post/put/patch/delete return {:ok, %{status/body/headers}} | {:error, _}",
         %{url: url} do
      caps = cap("http.out")

      assert {:ok, %{status: 200, body: _, headers: _}} = Http.get(url, caps)
      assert {:ok, %{status: 200}} = Http.post(url, %{a: 1}, caps)
      assert {:ok, %{status: 200}} = Http.put(url, %{a: 1}, caps)
      assert {:ok, %{status: 200}} = Http.patch(url, %{a: 1}, caps)
      assert {:ok, %{status: 200}} = Http.delete(url, caps)

      # Failure shape 1: capability denial.
      assert {:error, _} = Http.get(url, [])
      # Failure shape 2: transport error (unreachable port).
      assert {:error, _} = Http.get("http://127.0.0.1:1/x", caps)
    end
  end

  # ── Memory ──────────────────────────────────────────────────────────────

  test "memory.put/get/delete return {:ok, _} | {:error, _}; memory.list returns a bare list" do
    caps = cap("memory.kv")

    assert {:ok, "v"} = Memory.put("abi_ns", "abi_k", "v", caps)
    assert {:ok, "v"} = Memory.get("abi_ns", "abi_k", caps)
    assert {:ok, "abi_k"} = Memory.delete("abi_ns", "abi_k", caps)
    assert {:error, _} = Memory.get("abi_ns", "abi_missing", caps)

    assert {:error, _} = Memory.put("abi_ns", "abi_k", "v", [])

    assert is_list(Memory.list("abi_ns", "abi", caps))
  end

  # ── LLM (deterministic test backend) ────────────────────────────────────

  test "llm.chat/stream return {:ok, String} | {:error, _}" do
    caps = cap("model")

    assert {:ok, text} = Llm.chat("claude-opus-4-8", "sys", "hi", caps)
    assert is_binary(text)

    assert {:ok, text} = Llm.stream("claude-opus-4-8", "sys", "hi", fn _chunk -> :ok end, caps)
    assert is_binary(text)

    assert {:error, _} = Llm.chat("claude-opus-4-8", "sys", "hi", [])
    assert {:error, _} = Llm.stream("claude-opus-4-8", "sys", "hi", fn _chunk -> :ok end, [])
  end

  test "llm.json returns {:ok, map} | {:error, _}" do
    caps = cap("model")
    schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

    assert {:ok, decoded} = Llm.json("claude-opus-4-8", "sys", "hi", schema, caps)
    assert is_map(decoded)

    assert {:error, _} = Llm.json("claude-opus-4-8", "sys", "hi", schema, [])
  end

  test "llm.embed returns {:ok, [Float]} | {:error, _}" do
    caps = cap("model")

    assert {:ok, vector} = Llm.embed("voyage-3-large", "hello", caps)
    assert is_list(vector) and Enum.all?(vector, &is_float/1)

    assert {:error, _} = Llm.embed("voyage-3-large", "hello", [])
  end

  # ── Tools ───────────────────────────────────────────────────────────────

  describe "tool shapes" do
    setup do
      Tool.register("abi_matrix_echo", %{input: %{}}, fn input -> {:ok, input} end)
      :ok
    end

    test "tool.call/list/schema return {:ok, _} | {:error, <ToolError ABI tuple>}" do
      caps = cap("tool.use")

      assert {:ok, %{"x" => 1}} = Tool.call("abi_matrix_echo", %{"x" => 1}, caps)

      assert {:error, {:not_found, "abi_matrix_missing"}} =
               Tool.call("abi_matrix_missing", %{}, caps)

      assert {:error, {:denied, _}} = Tool.call("abi_matrix_echo", %{}, [])

      assert {:ok, tools} = Tool.list(caps)
      assert Enum.any?(tools, &(&1.name == "abi_matrix_echo"))
      assert {:error, {:denied, _}} = Tool.list([])

      assert {:ok, %{}} = Tool.schema("abi_matrix_echo", caps)

      assert {:error, {:not_found, "abi_matrix_missing"}} =
               Tool.schema("abi_matrix_missing", caps)
    end
  end

  # ── Topics / Queues ─────────────────────────────────────────────────────

  test "topic.publish and queue.publish return {:ok, String} | {:error, _}" do
    assert {:ok, "abi_topic"} = Topic.publish("abi_topic", %{}, cap("topic.publish"))
    assert {:error, _} = Topic.publish("abi_topic", %{}, [])

    assert {:ok, "abi_queue"} = Queue.publish("abi_queue", %{}, cap("queue.publish"))
    assert {:error, _} = Queue.publish("abi_queue", %{}, [])
  end

  # ── Trace / Event ───────────────────────────────────────────────────────

  test "trace.annotate returns bare :ok (spec `()`; no capability, cannot fail)" do
    assert :ok = Trace.annotate("k", "v", [])
  end

  test "event.log returns {:ok, name} | {:error, _} (spec Result[String, String])" do
    assert {:ok, "abi.event"} = EventStore.log(nil, "abi.event", %{}, cap("event.log"))
    assert {:error, _} = EventStore.log(nil, "abi.event", %{}, [])

    assert {:error, _} =
             EventStore.log("other", "abi.event", %{}, [%{kind: "event.log", params: ["audit"]}])
  end

  # ── Background work ─────────────────────────────────────────────────────

  test "process.spawn returns {:ok, pid} | {:error, _}" do
    assert {:ok, pid} = Process.spawn(nil, "abi_task", cap("process.spawn"))
    assert is_pid(pid)
    assert {:error, _} = Process.spawn(nil, "abi_task", [])
  end

  test "timer.after/interval/cancel return {:ok, ref} | {:error, _}" do
    caps = cap("timer")

    assert {:ok, ref} = Timer.after(nil, 60_000, "abi_once", caps)
    assert is_binary(ref)
    # cancel: Ok carries the ref back; idempotent for unknown refs.
    assert {:ok, ^ref} = Timer.cancel(nil, ref, caps)
    assert {:ok, "unknown-ref"} = Timer.cancel(nil, "unknown-ref", caps)

    assert {:ok, iref} = Timer.interval(nil, 60_000, "abi_every", caps)
    assert {:ok, ^iref} = Timer.cancel(nil, iref, caps)

    assert {:error, _} = Timer.after(nil, 10, "abi_once", [])
    assert {:error, _} = Timer.interval(nil, 10, "abi_every", [])
    assert {:error, _} = Timer.cancel(nil, "any", [])
  end

  # ── Nondeterminism (bare values; denial raises behind the compile gate) ─

  test "uuid.new returns a bare uuid string; denial raises" do
    value = Uuid.new(cap("uuid"))
    assert is_binary(value) and byte_size(value) == 36
    assert_raise RuntimeError, fn -> Uuid.new([]) end
  end

  test "instant.now returns a bare instant string; denial raises" do
    value = Instant.now(cap("instant"))
    assert is_binary(value)
    assert_raise RuntimeError, fn -> Instant.now([]) end
  end

  # ── Store ───────────────────────────────────────────────────────────────

  test "store.get/put/delete/query return {:ok, _} | {:error, _}" do
    caps = [%{kind: "store.table", params: ["abi_records"]}]
    record = %{id: "00000000-0000-4000-8000-00000000abcd", name: "abi"}

    assert {:ok, ^record} = Store.put("abi_records", record, caps)
    assert {:ok, ^record} = Store.get("abi_records", record.id, caps)
    assert {:ok, rows} = Store.query("abi_records", %{}, caps)
    assert is_list(rows)
    assert {:ok, _} = Store.delete("abi_records", record.id, caps)

    assert {:error, _} = Store.get("abi_records", record.id, caps)
    assert {:error, _} = Store.put("abi_records", record, [])
  end
end
