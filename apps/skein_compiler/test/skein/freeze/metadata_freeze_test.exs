defmodule Skein.Freeze.MetadataFreezeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Wave F freeze gate (#332) for the compiled-module metadata classes.

  `docs/STABILITY.md` classes this surface **Evolving**: entries may GAIN
  fields in minors; existing fields never change meaning or disappear
  before a major. These tests pin the exact dunder-export inventory and
  the exact key set of every metadata entry — an additive change is made
  visible by deliberately updating the pins here (and the CHANGELOG); a
  failing pin you did not intend to change is a breaking change.
  """

  @module_source """
  module Frozen {
    capability http.in
    capability memory.kv("frozen")
    capability tool.use(Frozen.Do)

    type Payload { id: String @primary, note: String }

    fn helper(n: Int) -> Int { n + 1 }

    handler http GET "/frozen/:id" (req) -> {
      respond.json(200, { id: req.params.id })
    }

    tool Frozen.Do {
      description: "frozen fixture tool"
      input  { amount: Int }
      output { doubled: Int }
      implement { Ok({ doubled: amount * 2 }) }
    }

    test "pure" { assert helper(1) == 2 }

    scenario "effectful" {
      capability tool.use(Frozen.Do) { }
      expect {
        let result = tool.call(Frozen.Do, { amount: 2 })!
        assert result.doubled == 4
      }
    }

    supervisor Pool {
      child W1(Worker) { max: 5, restart: permanent }
      strategy: one_for_one
      max_restarts: 10 per 60s
    }

    agent Worker {
      state { label: String }

      enum Phase {
        Ready -> [Done]
        Done  -> []
      }

      on start(label: String) -> { transition(Phase.Ready) }
      on phase(Phase.Ready) -> { transition(Phase.Done) }
      on phase(Phase.Done) -> { stop() }
    }
  }
  """

  setup_all do
    {:module, mod} = Skein.Compiler.compile_string(@module_source)
    %{mod: mod, agent_mod: Module.concat(["Skein", "Agent", "Frozen", "Worker"])}
  end

  test "the module dunder-export inventory is frozen", %{mod: mod} do
    metadata_exports =
      :erlang.get_module_info(mod, :exports)
      |> Enum.filter(fn {name, _} -> name |> Atom.to_string() |> String.starts_with?("__") end)
      |> Enum.reject(fn {name, arity} ->
        # __info__/1 is the BEAM module descriptor; the indexed internal
        # entry points (one per declaration) are not a metadata class —
        # their count varies with the program.
        {name, arity} == {:__info__, 1} or
          Atom.to_string(name) =~ ~r/\A__(handler|tool_impl|test)_\d+__\z/
      end)
      |> Enum.sort()

    assert metadata_exports == [
             __capabilities__: 0,
             __handlers__: 0,
             __supervisors__: 0,
             __tests__: 0,
             __tools__: 0
           ]
  end

  test "the agent dunder-export inventory is frozen", %{agent_mod: agent_module} do
    assert Code.ensure_loaded?(agent_module)

    dunders =
      :erlang.get_module_info(agent_module, :exports)
      |> Enum.filter(fn {name, _} -> name |> Atom.to_string() |> String.starts_with?("__") end)
      |> Enum.reject(fn {name, arity} -> {name, arity} == {:__info__, 1} end)
      |> Enum.sort()

    assert dunders == [__phase_handler__: 3, __phases__: 0, __start_handler__: 2]
    assert function_exported?(agent_module, :start_link, 1)
  end

  test "__capabilities__/0 entry keys are frozen", %{mod: mod} do
    for entry <- mod.__capabilities__() do
      assert entry |> Map.keys() |> Enum.sort() == [:kind, :params]
      assert is_list(entry.params)
    end
  end

  test "__handlers__/0 entry keys are frozen", %{mod: mod} do
    assert [handler] = mod.__handlers__()
    assert handler |> Map.keys() |> Enum.sort() == [:handler, :method, :route, :source]
    assert handler.source == :http
    assert handler.method == :get
    assert is_atom(handler.handler)
  end

  test "__tools__/0 entry keys are frozen", %{mod: mod} do
    assert [tool] = mod.__tools__()

    assert tool |> Map.keys() |> Enum.sort() == [
             :description,
             :impl,
             :input,
             :input_schema,
             :name,
             :output,
             :output_schema
           ]

    for field <- tool.input ++ tool.output do
      assert field |> Map.keys() |> Enum.sort() == [:name, :type]
    end

    assert is_map(tool.input_schema)
    assert is_map(tool.output_schema)
  end

  test "__tests__/0 entry keys and kinds are frozen", %{mod: mod} do
    tests = mod.__tests__()
    assert length(tests) == 2

    for entry <- tests do
      assert entry |> Map.keys() |> Enum.sort() == [:description, :fn, :kind]
      assert entry.kind in [:test, :scenario, :golden]
    end
  end

  test "__supervisors__/0 entry keys are frozen", %{mod: mod} do
    assert [supervisor] = mod.__supervisors__()

    assert supervisor |> Map.keys() |> Enum.sort() == [
             :children,
             :max_restarts,
             :name,
             :strategy
           ]

    assert supervisor.strategy == :one_for_one
    assert supervisor.max_restarts == {10, 60}

    for child <- supervisor.children do
      assert child |> Map.keys() |> Enum.sort() == [:args, :options, :target]
    end
  end

  test "__phases__/0 entry keys are frozen", %{agent_mod: agent_module} do
    phases = agent_module.__phases__()
    assert length(phases) == 2

    for phase <- phases do
      assert phase |> Map.keys() |> Enum.sort() == [:name, :transitions]
      assert is_atom(phase.name)
      assert is_list(phase.transitions)
    end
  end
end
