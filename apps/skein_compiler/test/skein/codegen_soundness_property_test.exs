defmodule Skein.CodegenSoundnessPropertyTest do
  @moduledoc """
  The B4 (#293) soundness bridge: **every program the analyzer accepts
  generates Core Erlang that BEAM-compiles and loads**.

  The generator builds random well-typed modules — typed fns over
  Int/String/Bool, let chains, match on Bool, calls to previously declared
  fns, `&fn` callbacks through stdlib higher-order slots, a record type with
  an Option field, and Result construction with `!` unwrapping. Every
  generated program must pass the analyzer by construction; a rejection means
  the generator drifted from the language, and an accepted program that fails
  Core generation, `:compile.forms/2`, or module load is exactly the
  soundness hole this gate exists to catch (unbound Core variables from
  silent `:unknown`s).
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
      # A generated line must not START with "(" — the parser reads a
      # newline-separated paren group as a call of the previous expression.
      # So the left operand is always atomic; only the right operand may be
      # a parenthesized subexpression.
      binop =
        StreamData.bind(StreamData.member_of(["+", "-", "*"]), fn op ->
          StreamData.bind(int_expr(scope, 0), fn left ->
            StreamData.map(int_operand(scope, size - 1), fn right ->
              "#{left} #{op} #{right}"
            end)
          end)
        end)

      StreamData.frequency([{3, var_or_literal}, {2, binop}])
    end
  end

  defp int_operand(scope, size) do
    StreamData.map(int_expr(scope, size), fn expr ->
      if String.contains?(expr, " "), do: "(#{expr})", else: expr
    end)
  end

  defp string_expr(scope, _size) do
    literal =
      StreamData.map(
        StreamData.string(Enum.concat([?a..?z, ?0..?9]), min_length: 1, max_length: 8),
        &~s("#{&1}")
      )

    case vars_of(scope, :string) do
      [] -> literal
      names -> StreamData.one_of([literal, StreamData.member_of(names)])
    end
  end

  defp bool_expr(scope, size) do
    literal = StreamData.member_of(["true", "false"])

    comparison =
      StreamData.bind(StreamData.member_of(["==", "!=", "<", ">"]), fn op ->
        StreamData.bind(int_expr(scope, 0), fn left ->
          StreamData.map(int_expr(scope, 0), fn right ->
            "#{left} #{op} #{right}"
          end)
        end)
      end)

    base =
      case vars_of(scope, :bool) do
        [] -> StreamData.one_of([literal, comparison])
        names -> StreamData.one_of([literal, comparison, StreamData.member_of(names)])
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

  @types [:int, :string, :bool]
  @type_names %{int: "Int", string: "String", bool: "Bool"}

  defp fn_source(index, prior_fns) do
    StreamData.bind(StreamData.member_of(@types), fn return_type ->
      StreamData.bind(param_list(index), fn params ->
        scope = Map.new(params)

        StreamData.bind(let_chain(scope, index), fn {lets, scope} ->
          StreamData.bind(body_expr(return_type, scope, prior_fns), fn body ->
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

  defp body_expr(return_type, scope, prior_fns) do
    plain = expr_of(return_type, scope, 2)
    matched = match_expr(return_type, scope, 1)

    callable = Enum.filter(prior_fns, &(&1.return_type == return_type))

    case callable do
      [] ->
        StreamData.frequency([{3, plain}, {1, matched}])

      fns ->
        call = StreamData.bind(StreamData.member_of(fns), &call_expr(&1, scope))
        StreamData.frequency([{3, plain}, {1, matched}, {1, call}])
    end
  end

  # ------------------------------------------------------------------
  # Module generator: 1..4 fns + fixed feature blocks that pin record
  # construction, Option totality, Result + `!`, and &fn callbacks.
  # ------------------------------------------------------------------

  defp module_source(index) do
    StreamData.bind(StreamData.integer(1..4), fn fn_count ->
      Enum.reduce(1..fn_count, StreamData.constant([]), fn i, acc ->
        StreamData.bind(acc, fn fns ->
          StreamData.map(fn_source(i, fns), fn f -> fns ++ [f] end)
        end)
      end)
      |> StreamData.map(fn fns ->
        fn_sources = Enum.map_join(fns, "\n", & &1.source)

        """
        module Gen#{index} {
          type Item {
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
        }
        """
      end)
    end)
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
