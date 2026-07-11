defmodule Skein.Conformance.AiSurfaceSoundnessTest do
  @moduledoc """
  Soundness checks for the constructs agent-authored Skein programs lean on most.

  These fixtures intentionally go past parse/analyze: each source is compiled and
  loaded, then exercised through its generated entry points or runtime adapters so
  analyzer-accepted programs must also generate/load and return spec-shaped values.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Compiler
  alias Skein.Runtime.{CapabilityStack, Store, Tool}

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("compile failed: #{inspect(errors)}\n\n#{source}")
    end
  end

  defp call_router(mod, method, path, body \\ nil) do
    router = Skein.Runtime.Router.build(mod)

    conn =
      if body do
        Plug.Test.conn(method, path, body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        Plug.Test.conn(method, path)
      end

    router.call(conn, router.init([]))
  end

  setup do
    Tool.clear_registry()
    Store.clear_all()
    CapabilityStack.clear()
    Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

    on_exit(fn ->
      Tool.clear_registry()
      Store.clear_all()
      CapabilityStack.clear()
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)
    end)

    :ok
  end

  test "conformance fixture covers agent transitions, llm.json, store.table, structured errors, and propagation" do
    mod =
      compile!("""
      module AiSurfaceFixture {
        capability http.in
        capability store.table("ai_surface_records", Item)
        capability uuid
        capability model("anthropic", "claude-opus-4-8")
        capability tool.use(AiSurface.Double)

        type Item { id: Uuid @primary name: String count: Int }
        type Decision { action: String count: Int }
        type CreateItem { name: String count: Int }

        fn save(name: String, count: Int) -> Result[Item, StoreError] {
          store.ai_surface_records.put(Item { id: uuid.new(), name: name, count: count })
        }

        fn missing_store_error() -> String {
          match store.ai_surface_records.get(uuid.new()) {
            Ok(_) -> "found"
            Err(StoreError.NotFound) -> "missing"
            Err(_) -> "other"
          }
        }

        fn decide(input: String) -> Result[Decision, LlmError] {
          llm.json[Decision](model: "claude-opus-4-8", system: "decide", input: input)
        }

        fn propagated(n: Int) -> Result[Int, StoreError] {
          let item = save("propagated", n)?
          Ok(item.count)
        }

        fn unwrapped(n: Int) -> Int {
          let item = save("unwrapped", n)!
          item.count
        }

        tool AiSurface.Double {
          input { value: Int }
          output { doubled: Int }
          errors { BadInput }
          implement { Ok({ doubled: value * 2 }) }
        }

        handler http POST "/items" (req) -> {
          let body = req.json[CreateItem]?
          let item = save(body.name, body.count)?
          respond.json(201, { id: item.id, name: item.name, count: item.count })
        }

        agent Worker {
          state { count: Int }
          enum Phase { Load -> [Done] Done -> [] }
          on start(count: Int) -> { transition(Phase.Load) }
          on phase(Phase.Load) -> {
            let item = save("agent", count)!
            transition(Phase.Done)
          }
          on phase(Phase.Done) -> { stop() }
        }
      }
      """)

    assert mod.unwrapped(7) == 7
    assert {:ok, 8} = mod.propagated(8)
    assert mod.missing_store_error() == "missing"
    assert {:ok, %{action: action, count: count}} = mod.decide("shape")
    assert is_binary(action)
    assert is_integer(count)
    assert {:ok, %{doubled: 10}} = mod.__tool_impl_0__(%{value: 5})

    conn = call_router(mod, :post, "/items", ~s({"name":"http","count":3}))
    assert conn.status == 201
    assert %{"count" => 3, "name" => "http"} = Jason.decode!(conn.resp_body)

    bad_conn = call_router(mod, :post, "/items", ~s({"name":"bad"}))
    assert bad_conn.status == 400

    assert {:transition, :done, _state, _events} =
             Skein.Agent.AiSurfaceFixture.Worker.__phase_handler__(:load, %{count: 4}, [])
  end

  property "accepted tool/handler/llm/store programs execute with spec-shaped values" do
    check all(suffix <- StreamData.integer(1..100_000), value <- StreamData.integer(0..50)) do
      mod =
        compile!("""
        module GenAiSurface#{suffix} {
          capability http.in
          capability store.table("gen_ai_surface_#{suffix}", Row)
          capability uuid
          capability model("anthropic", "claude-opus-4-8")

          type Row { id: Uuid @primary value: Int label: String }
          type Answer { action: String count: Int }
          type Payload { value: Int }

          fn persist(value: Int) -> Result[Row, StoreError] {
            store.gen_ai_surface_#{suffix}.put(Row { id: uuid.new(), value: value, label: "v${value}" })
          }

          fn round_trip(value: Int) -> Result[Int, StoreError] {
            let row = persist(value)?
            Ok(row.value)
          }

          fn ask() -> Result[Answer, LlmError] {
            llm.json[Answer](model: "claude-opus-4-8", system: "shape", input: "x")
          }

          tool Gen.Shape#{suffix} {
            input { value: Int }
            output { value: Int label: String }
            implement { Ok({ value: value, label: "v${value}" }) }
          }

          handler http POST "/shape" (req) -> {
            let payload = req.json[Payload]?
            respond.json(200, { value: payload.value, label: "v${payload.value}" })
          }
        }
        """)

      assert Code.ensure_loaded?(mod)
      assert {:ok, ^value} = mod.round_trip(value)
      assert {:ok, %{action: action, count: count}} = mod.ask()
      assert is_binary(action)
      assert is_integer(count)
      assert {:ok, %{value: ^value, label: label}} = mod.__tool_impl_0__(%{value: value})
      assert label == "v#{value}"

      conn = call_router(mod, :post, "/shape", Jason.encode!(%{value: value}))
      assert conn.status == 200
      assert %{"value" => ^value, "label" => ^label} = Jason.decode!(conn.resp_body)
    end
  end
end
