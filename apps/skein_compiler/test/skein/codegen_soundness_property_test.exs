defmodule Skein.CodegenSoundnessPropertyTest do
  @moduledoc """
  The B4 (#293) soundness bridge: **every program the analyzer accepts
  generates Core Erlang that BEAM-compiles and loads**.

  The generator builds random well-typed modules — typed fns over
  Int/String/Bool/Float, let chains, match on Bool, guarded match arms
  (`pattern if guard ->` over the guard-safe subset), string interpolation
  of in-scope scalar vars, calls to previously declared fns, `&fn`
  callbacks through stdlib higher-order slots, a record type with an
  Option field, Result construction with `!` unwrapping, and `?`
  propagation through generated Result-returning fns (#290/B1). Each
  module may additionally grow (widened by #314):

    * an effectful fn behind `capability memory.kv(..)` + `capability
      uuid` using `memory.put`/`memory.get` with `!` and `uuid.new()`,
    * a nested agent with a generated Phase enum, `on start` transition,
      and per-phase handlers ending in `stop()` (optionally calling a
      module-level fn),
    * a tool with randomized input/output fields, an `errors` block, and
      an `implement` body constructing the output from the input,
    * an `handler http ...` route behind `capability http.in`.

  Every generated program must pass the analyzer by construction; a
  rejection means the generator drifted from the language, and an accepted
  program that fails Core generation, `:compile.forms/2`, or module load
  is exactly the soundness hole this gate exists to catch (unbound Core
  variables from silent `:unknown`s). Effectful/agent/tool/handler code is
  compile+load only — the single cheap runtime probe stays `unwrapped/0`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Compiler

  # ------------------------------------------------------------------
  # Expression generators, parameterized by scope (%{name => type})
  # ------------------------------------------------------------------

  defp vars_of(scope, type) do
    for {name, ^type} <- scope, do: name
  end

  defp int_expr(scope, size) do
    literal = StreamData.map(StreamData.integer(0..99), &Integer.to_string/1)

    var_or_literal =
      case vars_of(scope, :int) do
        [] -> literal
        names -> StreamData.one_of([literal, StreamData.member_of(names)])
      end

    if size <= 0 do
      var_or_literal
    else
      # Operands parenthesize freely — since #311, a "(" starting a line is a
      # new expression, so generated programs need no parser trivia.
      binop =
        StreamData.bind(StreamData.member_of(["+", "-", "*"]), fn op ->
          StreamData.bind(int_expr(scope, size - 1), fn left ->
            StreamData.map(int_expr(scope, size - 1), fn right ->
              "(#{left} #{op} #{right})"
            end)
          end)
        end)

      StreamData.frequency([{3, var_or_literal}, {2, binop}])
    end
  end

  defp float_literal do
    StreamData.map(StreamData.integer(0..99), fn n -> "#{div(n, 10)}.#{rem(n, 10)}" end)
  end

  defp float_expr(scope, size) do
    var_or_literal =
      case vars_of(scope, :float) do
        [] -> float_literal()
        names -> StreamData.one_of([float_literal(), StreamData.member_of(names)])
      end

    if size <= 0 do
      var_or_literal
    else
      # Mixed numeric arithmetic: a Float left operand keeps the result Float
      # whether the right operand is Float or Int.
      binop =
        StreamData.bind(StreamData.member_of(["+", "-", "*"]), fn op ->
          StreamData.bind(float_expr(scope, size - 1), fn left ->
            StreamData.map(
              StreamData.one_of([float_expr(scope, size - 1), int_expr(scope, 0)]),
              fn right -> "(#{left} #{op} #{right})" end
            )
          end)
        end)

      StreamData.frequency([{3, var_or_literal}, {2, binop}])
    end
  end

  defp string_expr(scope, _size) do
    literal =
      StreamData.map(
        StreamData.string(Enum.concat([?a..?z, ?0..?9]), min_length: 1, max_length: 8),
        &~s("#{&1}")
      )

    # Typed interpolation (#310): every scope entry is scalar-typed
    # (Int/String/Bool/Float), so any in-scope var may render in a `${..}`
    # segment. Interpolation segments are ident-only — never calls (E0002).
    interpolated =
      case Map.keys(scope) do
        [] ->
          []

        names ->
          [
            StreamData.bind(
              StreamData.list_of(StreamData.member_of(names), min_length: 1, max_length: 2),
              fn vars ->
                StreamData.map(StreamData.string(?a..?z, max_length: 4), fn prefix ->
                  ~s("#{prefix}#{Enum.map_join(vars, " ", &"${#{&1}}")}")
                end)
              end
            )
          ]
      end

    string_vars =
      case vars_of(scope, :string) do
        [] -> []
        names -> [StreamData.member_of(names)]
      end

    StreamData.one_of([literal] ++ string_vars ++ interpolated)
  end

  defp bool_expr(scope, size) do
    literal = StreamData.member_of(["true", "false"])

    comparison =
      StreamData.bind(StreamData.member_of(["==", "!=", "<", ">"]), fn op ->
        StreamData.bind(int_expr(scope, 0), fn left ->
          StreamData.map(int_expr(scope, 0), fn right ->
            "(#{left} #{op} #{right})"
          end)
        end)
      end)

    # Ordering accepts any numeric mix (Int/Float on either side).
    float_comparison =
      StreamData.bind(StreamData.member_of(["<", ">", "<=", ">="]), fn op ->
        StreamData.bind(float_expr(scope, 0), fn left ->
          StreamData.map(
            StreamData.one_of([float_expr(scope, 0), int_expr(scope, 0)]),
            fn right -> "(#{left} #{op} #{right})" end
          )
        end)
      end)

    base =
      case vars_of(scope, :bool) do
        [] ->
          StreamData.one_of([literal, comparison, float_comparison])

        names ->
          StreamData.one_of([literal, comparison, float_comparison, StreamData.member_of(names)])
      end

    if size <= 0 do
      base
    else
      matched =
        StreamData.bind(bool_expr(scope, 0), fn subject ->
          StreamData.bind(bool_expr(scope, size - 1), fn on_true ->
            StreamData.map(bool_expr(scope, size - 1), fn on_false ->
              "match #{subject} { true -> #{on_true} false -> #{on_false} }"
            end)
          end)
        end)

      StreamData.frequency([{3, base}, {1, matched}])
    end
  end

  defp expr_of(:int, scope, size), do: int_expr(scope, size)
  defp expr_of(:string, scope, size), do: string_expr(scope, size)
  defp expr_of(:bool, scope, size), do: bool_expr(scope, size)
  defp expr_of(:float, scope, size), do: float_expr(scope, size)

  # A match on a Bool subject whose arms both produce `type` — exercises the
  # arm-unification path.
  defp match_expr(type, scope, size) do
    StreamData.bind(bool_expr(scope, 0), fn subject ->
      StreamData.bind(expr_of(type, scope, size), fn on_true ->
        StreamData.map(expr_of(type, scope, size), fn on_false ->
          "match #{subject} { true -> #{on_true} false -> #{on_false} }"
        end)
      end)
    end)
  end

  # A Bool expression from the guard-safe subset only (E0027): literals,
  # bindings, comparisons, `&&`/`||`/prefix-`!`, and `+`/`-`/`*` arithmetic.
  # No calls, effects, division, interpolation, or match blocks.
  defp guard_expr(scope, size) do
    int_comparison =
      StreamData.bind(StreamData.member_of(["==", "!=", "<", ">", "<=", ">="]), fn op ->
        StreamData.bind(int_expr(scope, 1), fn left ->
          StreamData.map(int_expr(scope, 1), fn right ->
            "(#{left} #{op} #{right})"
          end)
        end)
      end)

    float_comparison =
      StreamData.bind(StreamData.member_of(["<", ">", "<=", ">="]), fn op ->
        StreamData.bind(float_expr(scope, 0), fn left ->
          StreamData.map(
            StreamData.one_of([float_expr(scope, 0), int_expr(scope, 0)]),
            fn right -> "(#{left} #{op} #{right})" end
          )
        end)
      end)

    base =
      case vars_of(scope, :bool) do
        [] ->
          StreamData.one_of([
            StreamData.member_of(["true", "false"]),
            int_comparison,
            float_comparison
          ])

        names ->
          StreamData.one_of([
            StreamData.member_of(["true", "false"]),
            int_comparison,
            float_comparison,
            StreamData.member_of(names)
          ])
      end

    if size <= 0 do
      base
    else
      combined =
        StreamData.bind(StreamData.member_of(["&&", "||"]), fn op ->
          StreamData.bind(guard_expr(scope, size - 1), fn left ->
            StreamData.map(guard_expr(scope, size - 1), fn right ->
              "(#{left} #{op} #{right})"
            end)
          end)
        end)

      negated = StreamData.map(guard_expr(scope, size - 1), &"(!#{&1})")

      StreamData.frequency([{3, base}, {2, combined}, {1, negated}])
    end
  end

  # A match on an Int/Float subject with a guarded binder arm followed by a
  # catch-all — exercises E0027-checked guard codegen and binder scoping.
  # (Float literals are not patterns; binder + guard is the sanctioned form.)
  defp guarded_match_expr(type, scope, size, binder) do
    StreamData.bind(StreamData.member_of([:int, :float]), fn subject_type ->
      StreamData.bind(expr_of(subject_type, scope, 1), fn subject ->
        arm_scope = Map.put(scope, binder, subject_type)

        StreamData.bind(guard_expr(arm_scope, 1), fn guard ->
          StreamData.bind(expr_of(type, arm_scope, size), fn guarded_body ->
            StreamData.map(expr_of(type, scope, size), fn fallback ->
              "match #{subject} { #{binder} if #{guard} -> #{guarded_body} _ -> #{fallback} }"
            end)
          end)
        end)
      end)
    end)
  end

  # A call to a previously declared fn with correctly-typed arguments.
  defp call_expr(%{name: name, params: params}, scope) do
    params
    |> Enum.map(fn {_pname, ptype} -> expr_of(ptype, scope, 0) end)
    |> StreamData.fixed_list()
    |> StreamData.map(fn args -> "#{name}(#{Enum.join(args, ", ")})" end)
  end

  # ------------------------------------------------------------------
  # Fn generator: 0..2 typed params, 0..2 lets, a body of the return type.
  # `prior_fns` are earlier fns callable from this body.
  # ------------------------------------------------------------------

  @types [:int, :string, :bool, :float]
  @type_names %{int: "Int", string: "String", bool: "Bool", float: "Float"}

  defp fn_source(index, prior_fns) do
    StreamData.bind(StreamData.member_of(@types), fn return_type ->
      StreamData.bind(param_list(index), fn params ->
        scope = Map.new(params)

        StreamData.bind(let_chain(scope, index), fn {lets, scope} ->
          StreamData.bind(body_expr(return_type, scope, prior_fns, index), fn body ->
            param_src =
              Enum.map_join(params, ", ", fn {p, t} -> "#{p}: #{@type_names[t]}" end)

            source =
              "  fn f#{index}(#{param_src}) -> #{@type_names[return_type]} {\n" <>
                Enum.join(lets, "") <> "    #{body}\n  }\n"

            StreamData.constant(%{
              name: "f#{index}",
              params: params,
              return_type: return_type,
              source: source
            })
          end)
        end)
      end)
    end)
  end

  defp param_list(index) do
    StreamData.bind(StreamData.integer(0..2), fn count ->
      1..count//1
      |> Enum.map(fn i ->
        StreamData.map(StreamData.member_of(@types), fn t -> {"p#{index}_#{i}", t} end)
      end)
      |> StreamData.fixed_list()
    end)
  end

  defp let_chain(scope, index) do
    StreamData.bind(StreamData.integer(0..2), fn count ->
      Enum.reduce(1..count//1, StreamData.constant({[], scope}), fn i, acc ->
        StreamData.bind(acc, fn {lets, scope} ->
          StreamData.bind(StreamData.member_of(@types), fn t ->
            StreamData.map(expr_of(t, scope, 1), fn value ->
              name = "v#{index}_#{i}"
              {lets ++ ["    let #{name} = #{value}\n"], Map.put(scope, name, t)}
            end)
          end)
        end)
      end)
    end)
  end

  defp body_expr(return_type, scope, prior_fns, index) do
    plain = expr_of(return_type, scope, 2)
    matched = match_expr(return_type, scope, 1)
    guarded = guarded_match_expr(return_type, scope, 1, "g#{index}")

    callable = Enum.filter(prior_fns, &(&1.return_type == return_type))

    case callable do
      [] ->
        StreamData.frequency([{3, plain}, {1, matched}, {1, guarded}])

      fns ->
        call = StreamData.bind(StreamData.member_of(fns), &call_expr(&1, scope))
        StreamData.frequency([{3, plain}, {1, matched}, {1, guarded}, {1, call}])
    end
  end

  # ------------------------------------------------------------------
  # `?` propagation: a Result-returning helper plus a consumer whose body
  # propagates the helper's Err with `?` (in let or argument position) —
  # exercises B1 (#290) wrapping through generated code.
  # ------------------------------------------------------------------

  defp result_fn_sources(index) do
    StreamData.bind(StreamData.member_of(["+", "-", "*"]), fn op ->
      StreamData.bind(StreamData.integer(0..99), fn threshold ->
        StreamData.bind(StreamData.integer(1..9), fn delta ->
          StreamData.bind(
            StreamData.string(?a..?z, min_length: 1, max_length: 6),
            fn message ->
              StreamData.map(StreamData.member_of([:let, :argument]), fn shape ->
                consumer_body =
                  case shape do
                    :let ->
                      "    let a#{index} = rh#{index}((p #{op} #{delta}))?\n" <>
                        "    Ok((a#{index} + 1))\n"

                    :argument ->
                      "    Ok((rh#{index}(p)? #{op} #{delta}))\n"
                  end

                "  fn rh#{index}(x: Int) -> Result[Int, String] {\n" <>
                  "    match x > #{threshold} {\n" <>
                  "      true -> Ok((x #{op} #{delta}))\n" <>
                  "      false -> Err(\"#{message}\")\n" <>
                  "    }\n" <>
                  "  }\n\n" <>
                  "  fn rp#{index}(p: Int) -> Result[Int, String] {\n" <>
                  consumer_body <>
                  "  }\n"
              end)
            end
          )
        end)
      end)
    end)
  end

  # ------------------------------------------------------------------
  # Effects: memory.put/get with `!` and uuid.new() behind module-level
  # capabilities. Compile+load only — the property never calls this fn.
  # ------------------------------------------------------------------

  defp effects_source(index) do
    StreamData.bind(StreamData.member_of(@types), fn value_type ->
      StreamData.map(expr_of(value_type, %{"key" => :string}, 1), fn value ->
        "  fn eff#{index}(key: String) -> String {\n" <>
          "    let stored#{index} = memory.put(key, #{value})!\n" <>
          "    let fetched#{index} = memory.get(key)!\n" <>
          "    let id#{index} = uuid.new()\n" <>
          "    \"eff ${key} ${id#{index}}\"\n" <>
          "  }\n"
      end)
    end)
  end

  # ------------------------------------------------------------------
  # Nested agent: generated Phase enum (a 2..3-phase chain), `on start`
  # transitioning into the first phase, per-phase handlers with stop() in
  # the terminal one, optionally calling a module-level fn. Compile+load
  # only — compiles to its own Skein.Agent.* module alongside the parent.
  # ------------------------------------------------------------------

  @phase_pool ~w(Alpha Beta Gamma Delta Sigma Omega)

  defp agent_source(index, fns) do
    maybe_call =
      case fns do
        [] ->
          StreamData.constant(nil)

        [first | _] ->
          StreamData.one_of([StreamData.constant(nil), call_expr(first, %{})])
      end

    StreamData.bind(
      StreamData.uniq_list_of(StreamData.member_of(@phase_pool),
        min_length: 2,
        max_length: 3
      ),
      fn phases ->
        StreamData.map(maybe_call, fn call ->
          transitions =
            phases
            |> Enum.chunk_every(2, 1)
            |> Enum.map_join("", fn
              [phase, next] -> "      #{phase} -> [#{next}]\n"
              [terminal] -> "      #{terminal} -> []\n"
            end)

          handlers =
            phases
            |> Enum.chunk_every(2, 1)
            |> Enum.with_index(1)
            |> Enum.map_join("", fn
              {[phase, next], position} ->
                call_line =
                  if call && position == 1, do: "      let w#{index} = #{call}\n", else: ""

                "    on phase(Phase.#{phase}) -> {\n" <>
                  call_line <>
                  "      transition(Phase.#{next})\n    }\n"

              {[terminal], _position} ->
                "    on phase(Phase.#{terminal}) -> {\n      stop()\n    }\n"
            end)

          "  agent Worker#{index} {\n" <>
            "    state { n: Int }\n" <>
            "    enum Phase {\n" <>
            transitions <>
            "    }\n" <>
            "    on start(n: Int) -> { transition(Phase.#{hd(phases)}) }\n" <>
            handlers <>
            "  }\n"
        end)
      end
    )
  end

  # ------------------------------------------------------------------
  # Tool: randomized input/output fields (Int/String/Bool), an errors
  # block, and an implement body constructing the output map from the
  # input fields. Declaring a tool needs no capability (only calling one
  # does) — and the property never calls it.
  # ------------------------------------------------------------------

  defp tool_source(index) do
    field_types = [:int, :string, :bool]

    StreamData.bind(StreamData.integer(1..2), fn input_count ->
      input_fields_gen =
        1..input_count
        |> Enum.map(fn i ->
          StreamData.map(StreamData.member_of(field_types), fn t -> {"ti#{index}_#{i}", t} end)
        end)
        |> StreamData.fixed_list()

      StreamData.bind(input_fields_gen, fn input_fields ->
        StreamData.bind(StreamData.member_of(field_types), fn out_type ->
          input_scope = Map.new(input_fields)

          StreamData.bind(expr_of(out_type, input_scope, 1), fn out_expr ->
            StreamData.map(
              StreamData.string(?a..?z, min_length: 1, max_length: 8),
              fn description ->
                input_src =
                  Enum.map_join(input_fields, "", fn {name, t} ->
                    "      #{name}: #{@type_names[t]}\n"
                  end)

                "  tool Gen.Tool#{index} {\n" <>
                  "    description: \"#{description}\"\n" <>
                  "    input {\n#{input_src}    }\n" <>
                  "    output {\n      to#{index}: #{@type_names[out_type]}\n    }\n" <>
                  "    errors { GenError#{index} }\n" <>
                  "    implement { Ok({ to#{index}: #{out_expr} }) }\n" <>
                  "  }\n"
              end
            )
          end)
        end)
      end)
    end)
  end

  # ------------------------------------------------------------------
  # HTTP handler behind `capability http.in`. Compile+load only.
  # ------------------------------------------------------------------

  defp handler_source(index) do
    StreamData.bind(StreamData.member_of(["GET", "POST"]), fn method ->
      StreamData.bind(StreamData.member_of([200, 201]), fn status ->
        StreamData.map(string_expr(%{}, 0), fn body ->
          "  handler http #{method} \"/gen#{index}\" (req) -> {\n" <>
            "    respond.json(#{status}, #{body})\n" <>
            "  }\n"
        end)
      end)
    end)
  end

  # nil-first so shrinking drops whole feature blocks before shrinking
  # their contents.
  defp optional(generator) do
    StreamData.frequency([{1, StreamData.constant(nil)}, {2, generator}])
  end

  # ------------------------------------------------------------------
  # Module generator: 1..4 fns + fixed feature blocks that pin record
  # construction, Option totality, Result + `!`, and &fn callbacks — plus
  # optional generated `?`-propagation fns, effects, an agent, a tool,
  # and an HTTP handler (#314).
  # ------------------------------------------------------------------

  defp module_source(index) do
    StreamData.bind(StreamData.integer(1..4), fn fn_count ->
      fns_gen =
        Enum.reduce(1..fn_count, StreamData.constant([]), fn i, acc ->
          StreamData.bind(acc, fn fns ->
            StreamData.map(fn_source(i, fns), fn f -> fns ++ [f] end)
          end)
        end)

      StreamData.bind(fns_gen, fn fns ->
        StreamData.bind(optional(result_fn_sources(index)), fn result_src ->
          StreamData.bind(optional(effects_source(index)), fn effects_src ->
            StreamData.bind(optional(tool_source(index)), fn tool_src ->
              StreamData.bind(optional(handler_source(index)), fn handler_src ->
                StreamData.map(optional(agent_source(index, fns)), fn agent_src ->
                  assemble_module(index, fns, %{
                    result: result_src,
                    effects: effects_src,
                    tool: tool_src,
                    handler: handler_src,
                    agent: agent_src
                  })
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end

  defp assemble_module(index, fns, blocks) do
    capabilities =
      if(blocks.effects,
        do: "  capability memory.kv(\"gen_ns\")\n  capability uuid\n",
        else: ""
      ) <>
        if(blocks.handler, do: "  capability http.in\n", else: "")

    fn_sources = Enum.map_join(fns, "\n", & &1.source)

    generated_blocks =
      [blocks.result, blocks.effects, blocks.tool, blocks.handler, blocks.agent]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("\n", & &1)

    """
    module Gen#{index} {
    #{capabilities}  type Item {
        label: String
        count: Int
        note: Option[String]
      }

      fn build(label: String, count: Int) -> Item {
        Item { label: label, count: count }
      }

      fn describe(item: Item) -> String {
        match item.note {
          Some(n) -> n
          None -> item.label
        }
      }

      fn half(n: Int) -> Result[Int, String] {
        match n > 0 {
          true -> Ok(n)
          false -> Err("negative")
        }
      }

      fn increment(n: Int) -> Int { n + 1 }

      fn pipeline(values: List[Int]) -> List[Int] {
        List.map(values, &increment)
      }

      fn unwrapped() -> Int {
        half(4)!
      }

    #{fn_sources}
    #{generated_blocks}
    }
    """
  end

  # ------------------------------------------------------------------
  # The gate
  # ------------------------------------------------------------------

  property "analyzer-accepted generated programs compile to Core Erlang, BEAM-compile, and load" do
    check all(source <- StreamData.bind(StreamData.integer(1..1_000_000), &module_source/1)) do
      case Compiler.compile_string(source) do
        {:module, mod} ->
          assert Code.ensure_loaded?(mod)
          assert function_exported?(mod, :unwrapped, 0)
          assert mod.unwrapped() == 4

        {:error, errors} ->
          bridge_failure? =
            Enum.any?(errors, &(&1.message =~ "Core Erlang compilation failed"))

          flunk("""
          #{if bridge_failure?, do: "SOUNDNESS BRIDGE FAILURE: the analyzer accepted this program but BEAM compilation failed", else: "generator drift: the analyzer rejected a generated program"}:

          #{inspect(Enum.map(errors, &{&1.code, &1.message}))}

          #{source}
          """)
      end
    end
  end
end
