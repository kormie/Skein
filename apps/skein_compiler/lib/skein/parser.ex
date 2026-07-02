defmodule Skein.Parser do
  @moduledoc """
  Recursive descent parser for Skein.

  Converts a token list into an AST. Uses synchronization-point error
  recovery to report multiple errors per compilation.

  ## Operator Precedence (lowest to highest)

  1. Pipe:        `|>`
  2. Logical OR:  `||`
  3. Logical AND: `&&`
  4. Equality:    `==`, `!=`
  5. Comparison:  `<`, `>`, `<=`, `>=`
  6. Additive:    `+`, `-`
  7. Multiplicative: `*`, `/`
  8. Unary:       `!`, postfix `!`, postfix `?`
  9. Call / Field: `f(...)`, `x.y`
  """

  alias Skein.AST
  alias Skein.Error

  @type tokens :: [tuple()]
  @type parse_result :: {:ok, AST.Module.t()} | {:error, [Error.t()]}

  @spec parse(tokens()) :: parse_result()
  def parse(tokens) do
    parse(tokens, "unknown")
  end

  @spec parse(tokens(), String.t()) :: parse_result()
  def parse(tokens, file) do
    case tokens do
      [{:agent, _} | _] ->
        case parse_agent(tokens, file) do
          {:ok, ast, _rest} -> {:ok, ast}
          {:error, errors} -> {:error, errors}
        end

      _ ->
        case parse_module(tokens, file) do
          {:ok, ast, _rest} -> {:ok, ast}
          {:error, errors} -> {:error, errors}
        end
    end
  end

  # ------------------------------------------------------------------
  # Module
  # ------------------------------------------------------------------

  defp parse_module(tokens, file) do
    with {:ok, {line, col}, rest} <- expect(:module, tokens, file),
         {:ok, name, rest} <- expect_upper_ident(rest, file),
         {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, declarations, rest} <- parse_declarations(rest, file, []),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      ast = %AST.Module{
        name: name,
        capabilities: [],
        declarations: declarations,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, ast, rest}
    end
  end

  # ------------------------------------------------------------------
  # Agent
  # ------------------------------------------------------------------

  defp parse_agent([{:agent, {line, col}} | rest], file) do
    with {:ok, name, rest} <- expect_upper_ident(rest, file),
         {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, agent_parts, rest} <-
           parse_agent_body(rest, file, %{
             capabilities: [],
             state: [],
             phases: nil,
             handlers: [],
             fns: []
           }),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      ast = %AST.Agent{
        name: name,
        capabilities: agent_parts.capabilities,
        state: agent_parts.state,
        phases: agent_parts.phases,
        handlers: agent_parts.handlers,
        fns: agent_parts.fns,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, ast, rest}
    end
  end

  defp parse_agent_body([{:rbrace, _} | _] = tokens, _file, acc) do
    {:ok, acc, tokens}
  end

  defp parse_agent_body([{:eof, _} | _] = tokens, _file, acc) do
    {:ok, acc, tokens}
  end

  defp parse_agent_body([{:capability, _} | _] = tokens, file, acc) do
    case parse_capability(tokens, file) do
      {:ok, cap, rest} ->
        parse_agent_body(rest, file, %{acc | capabilities: acc.capabilities ++ [cap]})

      {:error, _} = error ->
        error
    end
  end

  defp parse_agent_body([{:ident, {line, col}, "state"} | rest], file, acc) do
    with {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, fields, rest} <- parse_fields(rest, file, []),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      state_fields =
        Enum.map(fields, fn field ->
          %{field | meta: Map.put(field.meta, :file, file)}
        end)

      _ = {line, col}
      parse_agent_body(rest, file, %{acc | state: state_fields})
    end
  end

  defp parse_agent_body([{:enum, _}, {:upper_ident, _, "Phase"} | _] = tokens, file, acc) do
    case parse_enum_decl(tokens, file) do
      {:ok, enum_decl, rest} ->
        parse_agent_body(rest, file, %{acc | phases: enum_decl})

      {:error, _} = error ->
        error
    end
  end

  defp parse_agent_body([{:on, _} | _] = tokens, file, acc) do
    case parse_agent_handler(tokens, file) do
      {:ok, handler, rest} ->
        parse_agent_body(rest, file, %{acc | handlers: acc.handlers ++ [handler]})

      {:error, _} = error ->
        error
    end
  end

  defp parse_agent_body([{:fn, _} | _] = tokens, file, acc) do
    case parse_fn(tokens, file) do
      {:ok, fn_decl, rest} ->
        parse_agent_body(rest, file, %{acc | fns: acc.fns ++ [fn_decl]})

      {:error, _} = error ->
        error
    end
  end

  defp parse_agent_body(tokens, file, _acc) do
    unexpected_token_error(
      tokens,
      file,
      "an agent body element (capability, state, enum Phase, on, fn)"
    )
  end

  # Parse agent event handler: on start(...) -> { ... } or on phase(Phase.X) -> { ... }
  defp parse_agent_handler([{:on, {line, col}} | rest], file) do
    case rest do
      [{:ident, _, "start"}, {:lparen, _} | rest2] ->
        # on start(params...) -> { ... }
        with {:ok, params, rest3} <- parse_params(rest2, file),
             {:ok, _rparen, rest3} <- expect(:rparen, rest3, file),
             {:ok, _arrow, rest3} <- expect(:arrow, rest3, file),
             {:ok, body, rest3} <- parse_block(rest3, file) do
          handler = %AST.AgentHandler{
            kind: :start,
            phase: nil,
            params: params,
            body: body,
            meta: %{line: line, col: col, file: file}
          }

          {:ok, handler, rest3}
        end

      [{:ident, _, "phase"}, {:lparen, _} | rest2] ->
        # on phase(Phase.VariantName) -> { ... }
        with {:ok, phase_ref, rest3} <- parse_phase_ref(rest2, file),
             {:ok, _rparen, rest3} <- expect(:rparen, rest3, file),
             {:ok, _arrow, rest3} <- expect(:arrow, rest3, file),
             {:ok, body, rest3} <- parse_block(rest3, file) do
          handler = %AST.AgentHandler{
            kind: :phase,
            phase: phase_ref,
            params: [],
            body: body,
            meta: %{line: line, col: col, file: file}
          }

          {:ok, handler, rest3}
        end

      _ ->
        unexpected_token_error(rest, file, "'start' or 'phase' after 'on'")
    end
  end

  # Parse Phase.VariantName reference
  defp parse_phase_ref(
         [{:upper_ident, _, "Phase"}, {:dot, _}, {:upper_ident, _, variant} | rest],
         _file
       ) do
    {:ok, variant, rest}
  end

  defp parse_phase_ref(tokens, file) do
    unexpected_token_error(tokens, file, "a phase reference (Phase.VariantName)")
  end

  # ------------------------------------------------------------------
  # Declarations (inside module body)
  # ------------------------------------------------------------------

  defp parse_declarations([{:rbrace, _} | _] = tokens, _file, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_declarations([{:eof, _} | _] = tokens, _file, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_declarations(tokens, file, acc) do
    case parse_declaration(tokens, file) do
      {:ok, decl, rest} ->
        parse_declarations(rest, file, [decl | acc])

      {:error, _} = error ->
        error
    end
  end

  defp parse_declaration([{:fn, _} | _] = tokens, file) do
    parse_fn(tokens, file)
  end

  defp parse_declaration([{:type, _} | _] = tokens, file) do
    parse_type_decl(tokens, file)
  end

  defp parse_declaration([{:enum, _} | _] = tokens, file) do
    parse_enum_decl(tokens, file)
  end

  defp parse_declaration([{:capability, _} | _] = tokens, file) do
    parse_capability(tokens, file)
  end

  defp parse_declaration([{:handler, _} | _] = tokens, file) do
    parse_handler(tokens, file)
  end

  defp parse_declaration([{:tool, _} | _] = tokens, file) do
    parse_tool_decl(tokens, file)
  end

  defp parse_declaration([{:test, _} | _] = tokens, file) do
    parse_test_decl(tokens, file)
  end

  defp parse_declaration([{:scenario, _} | _] = tokens, file) do
    parse_scenario_decl(tokens, file)
  end

  defp parse_declaration([{:golden, _} | _] = tokens, file) do
    parse_golden_decl(tokens, file)
  end

  defp parse_declaration([{:supervisor, _} | _] = tokens, file) do
    parse_supervisor(tokens, file)
  end

  defp parse_declaration([{:agent, _} | _] = tokens, file) do
    parse_agent(tokens, file)
  end

  defp parse_declaration([{token_type, {line, col}} | _], file) do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message:
           "Unexpected token #{inspect(token_type)}, expected a declaration (fn, type, enum, capability, handler, tool, test, scenario, golden, supervisor, agent)",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add a valid declaration keyword",
         fix_code: "fn name() -> Type { ... }"
       }
     ]}
  end

  defp parse_declaration([{token_type, {line, col}, _} | _], file) do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message:
           "Unexpected token #{inspect(token_type)}, expected a declaration (fn, type, enum, capability, handler, tool, test, scenario, golden, supervisor)",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add a valid declaration keyword",
         fix_code: "fn name() -> Type { ... }"
       }
     ]}
  end

  # ------------------------------------------------------------------
  # Capability declaration
  # ------------------------------------------------------------------

  defp parse_capability([{:capability, {line, col}} | rest], file) do
    # Parse the dotted kind: e.g. http.out, store.table, memory.kv
    case parse_dotted_ident(rest, file) do
      {:ok, kind, rest} ->
        # Optional parenthesized params
        case rest do
          [{:lparen, _} | rest2] ->
            case parse_capability_params(rest2, file, []) do
              {:ok, params, rest3} ->
                # Convert params to ToolRef nodes for tool.use capabilities
                params =
                  if kind == "tool.use",
                    do: convert_tool_use_params(params),
                    else: params

                cap = %AST.Capability{
                  kind: kind,
                  params: params,
                  meta: %{line: line, col: col, file: file}
                }

                {:ok, cap, rest3}

              {:error, _} = error ->
                error
            end

          _ ->
            cap = %AST.Capability{
              kind: kind,
              params: [],
              meta: %{line: line, col: col, file: file}
            }

            {:ok, cap, rest}
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_capability_params([{:rparen, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_capability_params([{:comma, _} | rest], file, acc) do
    parse_capability_params(rest, file, acc)
  end

  defp parse_capability_params(tokens, file, acc) do
    case parse_expression(tokens, file) do
      {:ok, expr, rest} ->
        parse_capability_params(rest, file, [expr | acc])

      {:error, _} = error ->
        error
    end
  end

  defp parse_dotted_ident([{:ident, _, name} | rest], file) do
    parse_dotted_ident_rest(rest, file, name)
  end

  # Handle keywords that can appear as capability kind prefixes (e.g., "tool.use")
  defp parse_dotted_ident([{:tool, _} | rest], file) do
    parse_dotted_ident_rest(rest, file, "tool")
  end

  defp parse_dotted_ident(tokens, file) do
    unexpected_token_error(tokens, file, "a capability kind (e.g., http.out)")
  end

  defp parse_dotted_ident_rest([{:dot, _}, {:ident, _, part} | rest], file, acc) do
    parse_dotted_ident_rest(rest, file, acc <> "." <> part)
  end

  defp parse_dotted_ident_rest(rest, _file, acc) do
    {:ok, acc, rest}
  end

  # ------------------------------------------------------------------
  # Handler declaration
  # handler http GET "/path/:param" (req) -> { ... }
  # ------------------------------------------------------------------

  @http_methods ~w(GET POST PUT PATCH DELETE)

  defp parse_handler([{:handler, {line, col}} | rest], file) do
    with {:ok, source, rest} <- expect_lower_ident(rest, file) do
      case source do
        "http" ->
          parse_http_handler(rest, file, line, col)

        "queue" ->
          parse_queue_handler(rest, file, line, col)

        "schedule" ->
          parse_schedule_handler(rest, file, line, col)

        "topic" ->
          parse_topic_handler(rest, file, line, col)

        _ ->
          {:error,
           [
             %Error{
               code: "E0001",
               severity: :error,
               message:
                 "Unknown handler source '#{source}', expected 'http', 'queue', 'schedule', or 'topic'",
               location: %{file: file, line: line, col: col},
               fix_hint: "Use 'http', 'queue', 'schedule', or 'topic'",
               fix_code: "handler http GET \"/path\" (req) -> { ... }"
             }
           ]}
      end
    end
  end

  # handler http METHOD "/path" (param) -> { body }
  defp parse_http_handler(rest, file, line, col) do
    with {:ok, method, rest} <- expect_http_method(rest, file),
         {:ok, route, rest} <- expect_string_literal(rest, file),
         {:ok, _lparen, rest} <- expect(:lparen, rest, file),
         {:ok, param, rest} <- expect_lower_ident(rest, file),
         {:ok, _rparen, rest} <- expect(:rparen, rest, file),
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, body, rest} <- parse_block(rest, file) do
      handler = %AST.Handler{
        source: "http",
        method: method,
        route: route,
        param: param,
        body: body,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, handler, rest}
    end
  end

  # handler queue "queue-name" (param) -> { body }
  defp parse_queue_handler(rest, file, line, col) do
    with {:ok, queue_name, rest} <- expect_string_literal(rest, file),
         {:ok, _lparen, rest} <- expect(:lparen, rest, file),
         {:ok, param, rest} <- expect_lower_ident(rest, file),
         {:ok, _rparen, rest} <- expect(:rparen, rest, file),
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, body, rest} <- parse_block(rest, file) do
      handler = %AST.Handler{
        source: "queue",
        method: nil,
        route: queue_name,
        param: param,
        body: body,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, handler, rest}
    end
  end

  # handler schedule "cron-expr" () -> { body }
  defp parse_schedule_handler(rest, file, line, col) do
    with {:ok, cron_expr, rest} <- expect_string_literal(rest, file),
         {:ok, _lparen, rest} <- expect(:lparen, rest, file) do
      # Schedule handlers may have an empty param list or a single param
      case rest do
        [{:rparen, _} | rest2] ->
          with {:ok, _arrow, rest3} <- expect(:arrow, rest2, file),
               {:ok, body, rest3} <- parse_block(rest3, file) do
            handler = %AST.Handler{
              source: "schedule",
              method: nil,
              route: cron_expr,
              param: nil,
              body: body,
              meta: %{line: line, col: col, file: file}
            }

            {:ok, handler, rest3}
          end

        _ ->
          with {:ok, param, rest2} <- expect_lower_ident(rest, file),
               {:ok, _rparen, rest2} <- expect(:rparen, rest2, file),
               {:ok, _arrow, rest2} <- expect(:arrow, rest2, file),
               {:ok, body, rest2} <- parse_block(rest2, file) do
            handler = %AST.Handler{
              source: "schedule",
              method: nil,
              route: cron_expr,
              param: param,
              body: body,
              meta: %{line: line, col: col, file: file}
            }

            {:ok, handler, rest2}
          end
      end
    end
  end

  # handler topic "topic-name" (param) -> { body }
  defp parse_topic_handler(rest, file, line, col) do
    with {:ok, topic_name, rest} <- expect_string_literal(rest, file),
         {:ok, _lparen, rest} <- expect(:lparen, rest, file),
         {:ok, param, rest} <- expect_lower_ident(rest, file),
         {:ok, _rparen, rest} <- expect(:rparen, rest, file),
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, body, rest} <- parse_block(rest, file) do
      handler = %AST.Handler{
        source: "topic",
        method: nil,
        route: topic_name,
        param: param,
        body: body,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, handler, rest}
    end
  end

  defp expect_http_method([{:upper_ident, _, name} | rest], _file)
       when name in @http_methods do
    {:ok, String.downcase(name), rest}
  end

  defp expect_http_method(tokens, file) do
    unexpected_token_error(tokens, file, "an HTTP method (GET, POST, PUT, PATCH, DELETE)")
  end

  defp expect_string_literal([{:string, _, segments} | rest], _file) do
    # Extract the route string from segments (should be a single literal)
    route =
      segments
      |> Enum.map(fn
        {:literal, text} -> text
        {:interpolation, _} -> ""
      end)
      |> Enum.join()

    {:ok, route, rest}
  end

  defp expect_string_literal(tokens, file) do
    unexpected_token_error(tokens, file, "a route string")
  end

  # ------------------------------------------------------------------
  # Tool declaration
  # tool DottedName { description: "..." input { ... } output { ... } errors { ... } implement { ... } }
  # ------------------------------------------------------------------

  defp parse_tool_decl([{:tool, {line, col}} | rest], file) do
    with {:ok, name, rest} <- parse_tool_name(rest, file),
         {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, tool_parts, rest} <-
           parse_tool_body(rest, file, %{
             description: nil,
             input: nil,
             output: nil,
             errors: [],
             implement: nil
           }),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      # Validate required blocks
      cond do
        tool_parts.input == nil ->
          {:error,
           [
             %Error{
               code: "E0001",
               severity: :error,
               message: "Tool '#{name}' is missing required 'input' block",
               location: %{file: file, line: line, col: col},
               fix_hint: "Add an input block: input { field: Type }",
               fix_code: "input { field: Type }"
             }
           ]}

        tool_parts.output == nil ->
          {:error,
           [
             %Error{
               code: "E0001",
               severity: :error,
               message: "Tool '#{name}' is missing required 'output' block",
               location: %{file: file, line: line, col: col},
               fix_hint: "Add an output block: output { field: Type }",
               fix_code: "output { field: Type }"
             }
           ]}

        tool_parts.implement == nil ->
          {:error,
           [
             %Error{
               code: "E0001",
               severity: :error,
               message: "Tool '#{name}' is missing required 'implement' block",
               location: %{file: file, line: line, col: col},
               fix_hint: "Add an implement block: implement { ... }",
               fix_code: "implement { ... }"
             }
           ]}

        true ->
          tool = %AST.ToolDecl{
            name: name,
            description: tool_parts.description,
            input: tool_parts.input,
            output: tool_parts.output,
            errors: tool_parts.errors,
            implement: tool_parts.implement,
            meta: %{line: line, col: col, file: file}
          }

          {:ok, tool, rest}
      end
    end
  end

  # Parse dotted tool name: UpperIdent ("." UpperIdent)*
  defp parse_tool_name([{:upper_ident, _, name} | rest], file) do
    parse_tool_name_rest(rest, file, name)
  end

  defp parse_tool_name(tokens, file) do
    unexpected_token_error(
      tokens,
      file,
      "a tool name (e.g., CreateRefund or Stripe.CreateRefund)"
    )
  end

  defp parse_tool_name_rest([{:dot, _}, {:upper_ident, _, part} | rest], file, acc) do
    parse_tool_name_rest(rest, file, acc <> "." <> part)
  end

  defp parse_tool_name_rest(rest, _file, acc) do
    {:ok, acc, rest}
  end

  # Parse tool body: description, input, output, errors, policy, implement blocks
  defp parse_tool_body([{:rbrace, _} | _] = tokens, _file, acc) do
    {:ok, acc, tokens}
  end

  defp parse_tool_body([{:eof, _} | _] = tokens, _file, acc) do
    {:ok, acc, tokens}
  end

  defp parse_tool_body([{:ident, _, "description"}, {:colon, _} | rest], file, acc) do
    case rest do
      [{:string, _, segments} | rest2] ->
        desc =
          segments
          |> Enum.map(fn
            {:literal, text} -> text
            {:interpolation, _} -> ""
          end)
          |> Enum.join()

        parse_tool_body(rest2, file, %{acc | description: desc})

      _ ->
        unexpected_token_error(rest, file, "a description string")
    end
  end

  defp parse_tool_body([{:ident, _, "input"}, {:lbrace, _} | rest], file, acc) do
    case parse_fields(rest, file, []) do
      {:ok, fields, [{:rbrace, _} | rest2]} ->
        parse_tool_body(rest2, file, %{acc | input: fields})

      {:ok, _, rest2} ->
        unexpected_token_error(rest2, file, "'}'")

      {:error, _} = error ->
        error
    end
  end

  defp parse_tool_body([{:ident, _, "output"}, {:lbrace, _} | rest], file, acc) do
    case parse_fields(rest, file, []) do
      {:ok, fields, [{:rbrace, _} | rest2]} ->
        parse_tool_body(rest2, file, %{acc | output: fields})

      {:ok, _, rest2} ->
        unexpected_token_error(rest2, file, "'}'")

      {:error, _} = error ->
        error
    end
  end

  defp parse_tool_body([{:ident, _, "errors"}, {:lbrace, _} | rest], file, acc) do
    case parse_error_names(rest, file, []) do
      {:ok, names, rest2} ->
        parse_tool_body(rest2, file, %{acc | errors: names})

      {:error, _} = error ->
        error
    end
  end

  defp parse_tool_body([{:implement, _} | rest], file, acc) do
    case parse_block(rest, file) do
      {:ok, block, rest2} ->
        parse_tool_body(rest2, file, %{acc | implement: block})

      {:error, _} = error ->
        error
    end
  end

  # Tool `policy` blocks were cut from the language (#319) — a parse of the
  # removed form gets a targeted structured error, not the generic fallback.
  defp parse_tool_body([{:ident, {line, col}, "policy"} | _], file, _acc) do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Tool 'policy' blocks are not part of the language",
         location: %{file: file, line: line, col: col},
         fix_hint:
           "Delete the policy block. Tool sections are: description, input, output, errors, implement",
         fix_code: nil
       }
     ]}
  end

  # A known section name not followed by its required token gets a targeted
  # error naming the missing token instead of re-listing the alternatives.
  defp parse_tool_body([{:ident, {line, col}, "description"} | _], file, _acc) do
    missing_token_after_error("description", ":", {line, col}, file)
  end

  defp parse_tool_body([{:ident, {line, col}, section} | _], file, _acc)
       when section in ["input", "output", "errors"] do
    missing_token_after_error(section, "{", {line, col}, file)
  end

  defp parse_tool_body(tokens, file, _acc) do
    unexpected_token_error(
      tokens,
      file,
      "a tool section (description, input, output, errors, implement)"
    )
  end

  # Parse error names: UpperIdent ("," UpperIdent)* "}"
  defp parse_error_names([{:rbrace, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_error_names([{:comma, _} | rest], file, acc) do
    parse_error_names(rest, file, acc)
  end

  defp parse_error_names([{:upper_ident, _, name} | rest], file, acc) do
    parse_error_names(rest, file, [name | acc])
  end

  defp parse_error_names(tokens, file, _acc) do
    unexpected_token_error(tokens, file, "an error type name")
  end

  # ------------------------------------------------------------------
  # Test declaration
  # test "description" { body }
  # ------------------------------------------------------------------

  defp parse_test_decl([{:test, {line, col}} | rest], file) do
    case rest do
      [{:string, _, segments} | rest2] ->
        description =
          segments
          |> Enum.map(fn
            {:literal, text} -> text
            {:interpolation, _} -> ""
          end)
          |> Enum.join()

        case parse_block(rest2, file) do
          {:ok, body, rest3} ->
            test_node = %AST.Test{
              description: description,
              body: body,
              meta: %{line: line, col: col, file: file}
            }

            {:ok, test_node, rest3}

          {:error, _} = error ->
            error
        end

      _ ->
        unexpected_token_error(rest, file, "a test description string")
    end
  end

  # ------------------------------------------------------------------
  # Scenario declaration
  # scenario "description" { given { k: v, ... } expect { assertions } }
  # ------------------------------------------------------------------

  defp parse_scenario_decl([{:scenario, {line, col}} | rest], file) do
    case rest do
      [{:string, _, segments} | rest2] ->
        description =
          segments
          |> Enum.map(fn
            {:literal, text} -> text
            {:interpolation, _} -> ""
          end)
          |> Enum.join()

        with {:ok, _lbrace, rest3} <- expect(:lbrace, rest2, file),
             {:ok, items, rest3} <-
               parse_scenario_items(rest3, file, %{
                 capabilities: [],
                 given_vars: [],
                 expect_body: nil
               }) do
          scenario = %AST.Scenario{
            description: description,
            capabilities: Enum.reverse(items.capabilities),
            given_vars: items.given_vars,
            expect_body: items.expect_body,
            meta: %{line: line, col: col, file: file}
          }

          {:ok, scenario, rest3}
        end

      _ ->
        unexpected_token_error(rest, file, "a scenario description string")
    end
  end

  # scenario_item = capability_envelope | given_block | expect_block
  # Items may appear in any order; the closing '}' ends the scenario.
  defp parse_scenario_items([{:rbrace, _} | rest], _file, acc) do
    {:ok, acc, rest}
  end

  defp parse_scenario_items([{:capability, _} | _] = tokens, file, acc) do
    with {:ok, cap, rest} <- parse_scenario_capability(tokens, file) do
      parse_scenario_items(rest, file, %{acc | capabilities: [cap | acc.capabilities]})
    end
  end

  defp parse_scenario_items([{:ident, _, "given"} | _] = tokens, file, acc) do
    with {:ok, given_vars, rest} <- parse_given_block(tokens, file) do
      parse_scenario_items(rest, file, %{acc | given_vars: acc.given_vars ++ given_vars})
    end
  end

  defp parse_scenario_items([{:ident, _, "expect"} | _] = tokens, file, acc) do
    with {:ok, expect_body, rest} <- parse_expect_block(tokens, file) do
      parse_scenario_items(rest, file, %{acc | expect_body: expect_body})
    end
  end

  defp parse_scenario_items(tokens, file, _acc) do
    unexpected_token_error(tokens, file, "a 'capability' envelope, 'given', or 'expect'")
  end

  # A scenario capability may open a nested envelope: `capability K(args) { ... }`
  # whose body holds nested capabilities and/or a single `implement` block.
  defp parse_scenario_capability(tokens, file) do
    with {:ok, %AST.Capability{} = cap, rest} <- parse_capability(tokens, file) do
      case rest do
        [{:ident, {l, c}, "via"} | _] ->
          via_not_supported_error(l, c, file)

        [{:lbrace, _} | rest2] ->
          with {:ok, nested, implement, rest3} <-
                 parse_envelope_body(rest2, file, [], nil) do
            {:ok, %{cap | nested: Enum.reverse(nested), implement: implement}, rest3}
          end

        _ ->
          {:ok, %{cap | nested: [], implement: nil}, rest}
      end
    end
  end

  # Body of a capability envelope: nested `capability` declarations and at most
  # one `implement` provider block, in any order, until the closing '}'.
  defp parse_envelope_body([{:rbrace, _} | rest], _file, nested, implement) do
    {:ok, nested, implement, rest}
  end

  defp parse_envelope_body([{:capability, _} | _] = tokens, file, nested, implement) do
    with {:ok, cap, rest} <- parse_scenario_capability(tokens, file) do
      parse_envelope_body(rest, file, [cap | nested], implement)
    end
  end

  defp parse_envelope_body([{:implement, {line, col}} | _], file, _nested, implement)
       when implement != nil do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "A capability envelope may contain at most one 'implement' block",
         location: %{file: file, line: line, col: col},
         context: nil,
         fix_hint: "Remove the duplicate 'implement' block",
         fix_code: "implement(...) -> Type { ... }"
       }
     ]}
  end

  defp parse_envelope_body([{:implement, _} | _] = tokens, file, nested, nil) do
    with {:ok, impl, rest} <- parse_capability_implement(tokens, file) do
      parse_envelope_body(rest, file, nested, impl)
    end
  end

  defp parse_envelope_body(tokens, file, _nested, _implement) do
    unexpected_token_error(tokens, file, "a nested 'capability' or an 'implement' block")
  end

  # implement(params) -> ReturnType { body }
  defp parse_capability_implement([{:implement, {line, col}} | rest], file) do
    with {:ok, _lparen, rest} <- expect(:lparen, rest, file),
         {:ok, params, rest} <- parse_params(rest, file),
         {:ok, _rparen, rest} <- expect(:rparen, rest, file),
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, return_type, rest} <- parse_type_expr(rest, file),
         {:ok, body, rest} <- parse_block(rest, file) do
      impl = %AST.CapabilityImplement{
        params: params,
        return_type: return_type,
        body: body,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, impl, rest}
    end
  end

  defp via_not_supported_error(line, col, file) do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message:
           "'via' is not a Skein construct; scenarios control effects with a nested capability envelope, not 'via'",
         location: %{file: file, line: line, col: col},
         context: nil,
         fix_hint:
           "Replace the 'via' binding with a nested capability envelope and an 'implement' block",
         fix_code:
           "capability http.out(\"host\") {\n  implement(req: HttpRequest) -> Result[HttpResponse, HttpError] { ... }\n}"
       }
     ]}
  end

  # Parse given { key: expr, key: expr, ... }
  defp parse_given_block([{:ident, _, "given"}, {:lbrace, _} | rest], file) do
    parse_given_vars(rest, file, [])
  end

  defp parse_given_block(tokens, file) do
    unexpected_token_error(tokens, file, "'given'")
  end

  defp parse_given_vars([{:rbrace, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_given_vars([{:comma, _} | rest], file, acc) do
    parse_given_vars(rest, file, acc)
  end

  defp parse_given_vars(tokens, file, acc) do
    with {:ok, name, rest} <- expect_lower_ident(tokens, file),
         {:ok, _colon, rest} <- expect(:colon, rest, file),
         {:ok, value, rest} <- parse_expression(rest, file) do
      parse_given_vars(rest, file, [{name, value} | acc])
    end
  end

  # Parse expect { assert expr, assert expr, ... }
  defp parse_expect_block([{:ident, _, "expect"}, {:lbrace, _} | rest], file) do
    case parse_block_body(rest, file, []) do
      {:ok, exprs, rest2} ->
        block = %AST.Block{
          expressions: exprs,
          meta: meta_from_tokens(rest, file)
        }

        {:ok, block, rest2}

      {:error, _} = error ->
        error
    end
  end

  defp parse_expect_block(tokens, file) do
    unexpected_token_error(tokens, file, "'expect'")
  end

  # ------------------------------------------------------------------
  # Golden declaration
  # golden "description" from trace "file" { body }
  # ------------------------------------------------------------------

  defp parse_golden_decl([{:golden, {line, col}} | rest], file) do
    case rest do
      [{:string, _, segments} | rest2] ->
        description =
          segments
          |> Enum.map(fn
            {:literal, text} -> text
            {:interpolation, _} -> ""
          end)
          |> Enum.join()

        with {:ok, _from, rest3} <- expect_ident_value(rest2, file, "from"),
             {:ok, _trace, rest3} <- expect_ident_value(rest3, file, "trace"),
             {:ok, trace_file, rest3} <- expect_string_literal(rest3, file),
             {:ok, body, rest3} <- parse_block(rest3, file) do
          golden = %AST.Golden{
            description: description,
            trace_file: trace_file,
            body: body,
            meta: %{line: line, col: col, file: file}
          }

          {:ok, golden, rest3}
        end

      _ ->
        unexpected_token_error(rest, file, "a golden test description string")
    end
  end

  # Expect a specific identifier value (for parsing contextual keywords like "from", "trace")
  defp expect_ident_value([{:ident, _, value} | rest], _file, value) do
    {:ok, value, rest}
  end

  defp expect_ident_value(tokens, file, expected) do
    unexpected_token_error(tokens, file, "'#{expected}'")
  end

  # ------------------------------------------------------------------
  # Function declaration
  # ------------------------------------------------------------------

  defp parse_fn([{:fn, {line, col}} | rest], file) do
    with {:ok, name, rest} <- expect_lower_ident(rest, file),
         {:ok, _lparen, rest} <- expect(:lparen, rest, file),
         {:ok, params, rest} <- parse_params(rest, file),
         {:ok, _rparen, rest} <- expect(:rparen, rest, file),
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, return_type, rest} <- parse_type_expr(rest, file),
         {:ok, body, rest} <- parse_block(rest, file) do
      fn_node = %AST.Fn{
        name: name,
        params: params,
        return_type: return_type,
        body: body,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, fn_node, rest}
    end
  end

  # ------------------------------------------------------------------
  # Parameters
  # ------------------------------------------------------------------

  defp parse_params([{:rparen, _} | _] = tokens, _file) do
    {:ok, [], tokens}
  end

  defp parse_params(tokens, file) do
    parse_params_list(tokens, file, [])
  end

  defp parse_params_list(tokens, file, acc) do
    with {:ok, name, rest} <- expect_lower_ident(tokens, file),
         {:ok, _colon, rest} <- expect(:colon, rest, file),
         {:ok, type, rest} <- parse_type_expr(rest, file) do
      param = %AST.Field{
        name: name,
        type: type,
        annotations: [],
        meta: meta_from_tokens(tokens, file)
      }

      case rest do
        [{:comma, _} | rest2] ->
          parse_params_list(rest2, file, [param | acc])

        _ ->
          {:ok, Enum.reverse([param | acc]), rest}
      end
    end
  end

  # ------------------------------------------------------------------
  # Type expressions
  # ------------------------------------------------------------------

  defp parse_type_expr([{:upper_ident, {line, col}, name} | rest], file) do
    # Check for parameterized type: Type[A, B]
    case rest do
      [{:lbracket, _} | rest2] ->
        case parse_type_params(rest2, file, []) do
          {:ok, params, rest3} ->
            type = %AST.TypeRef{
              name: name,
              params: params,
              meta: %{line: line, col: col, file: file}
            }

            {:ok, type, rest3}

          {:error, _} = error ->
            error
        end

      _ ->
        type = %AST.TypeRef{
          name: name,
          params: [],
          meta: %{line: line, col: col, file: file}
        }

        {:ok, type, rest}
    end
  end

  defp parse_type_expr(tokens, file) do
    unexpected_token_error(tokens, file, "a type name")
  end

  defp parse_type_params([{:rbracket, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_type_params([{:comma, _} | rest], file, acc) do
    parse_type_params(rest, file, acc)
  end

  defp parse_type_params(tokens, file, acc) do
    case parse_type_expr(tokens, file) do
      {:ok, type, rest} -> parse_type_params(rest, file, [type | acc])
      {:error, _} = error -> error
    end
  end

  # ------------------------------------------------------------------
  # Type declaration
  # ------------------------------------------------------------------

  defp parse_type_decl([{:type, {line, col}} | rest], file) do
    with {:ok, name, rest} <- expect_upper_ident(rest, file),
         {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, fields, rest} <- parse_fields(rest, file, []),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      type_decl = %AST.TypeDecl{
        name: name,
        fields: fields,
        constraints: [],
        meta: %{line: line, col: col, file: file}
      }

      {:ok, type_decl, rest}
    end
  end

  defp parse_fields([{:rbrace, _} | _] = tokens, _file, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_fields(tokens, file, acc) do
    with {:ok, name, rest} <- expect_lower_ident(tokens, file),
         {:ok, _colon, rest} <- expect(:colon, rest, file),
         {:ok, type, rest} <- parse_type_expr(rest, file) do
      # Parse optional annotations (@min, @max, etc.)
      {annotations, rest} = parse_annotations(rest, file)

      field = %AST.Field{
        name: name,
        type: type,
        annotations: annotations,
        meta: meta_from_tokens(tokens, file)
      }

      # Optional comma separator
      rest =
        case rest do
          [{:comma, _} | r] -> r
          r -> r
        end

      parse_fields(rest, file, [field | acc])
    end
  end

  # Handle keywords used as annotation names (e.g., @description where description is a keyword)
  defp parse_annotations([{:at, _}, {keyword, {line, col}} | rest], file)
       when keyword in [:description, :input, :output, :errors, :implement] do
    name = Atom.to_string(keyword)

    case rest do
      [{:lparen, _} | rest2] ->
        case parse_expression(rest2, file) do
          {:ok, value, [{:rparen, _} | rest3]} ->
            annotation = %AST.Annotation{
              name: name,
              value: value,
              meta: %{line: line, col: col, file: file}
            }

            {more, rest4} = parse_annotations(rest3, file)
            {[annotation | more], rest4}

          {:ok, _, rest3} ->
            {[], rest3}

          {:error, _} ->
            {[], rest}
        end

      _ ->
        annotation = %AST.Annotation{
          name: name,
          value: nil,
          meta: %{line: line, col: col, file: file}
        }

        {more, rest2} = parse_annotations(rest, file)
        {[annotation | more], rest2}
    end
  end

  defp parse_annotations([{:at, _}, {:ident, {line, col}, name} | rest], file) do
    case rest do
      [{:lparen, _} | rest2] ->
        case parse_expression(rest2, file) do
          {:ok, value, [{:rparen, _} | rest3]} ->
            annotation = %AST.Annotation{
              name: name,
              value: value,
              meta: %{line: line, col: col, file: file}
            }

            {more, rest4} = parse_annotations(rest3, file)
            {[annotation | more], rest4}

          {:ok, _, rest3} ->
            # Missing closing paren, just return what we have
            {[], rest3}

          {:error, _} ->
            {[], rest}
        end

      _ ->
        annotation = %AST.Annotation{
          name: name,
          value: nil,
          meta: %{line: line, col: col, file: file}
        }

        {more, rest2} = parse_annotations(rest, file)
        {[annotation | more], rest2}
    end
  end

  defp parse_annotations(tokens, _file) do
    {[], tokens}
  end

  # ------------------------------------------------------------------
  # Enum declaration
  # ------------------------------------------------------------------

  defp parse_enum_decl([{:enum, {line, col}} | rest], file) do
    with {:ok, name, rest} <- expect_upper_ident(rest, file),
         {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, variants, rest} <- parse_variants(rest, file, []),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      enum_decl = %AST.EnumDecl{
        name: name,
        variants: variants,
        transitions: [],
        meta: %{line: line, col: col, file: file}
      }

      {:ok, enum_decl, rest}
    end
  end

  defp parse_variants([{:rbrace, _} | _] = tokens, _file, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_variants([{:upper_ident, {line, col}, name} | rest], file, acc) do
    # Check for transition declaration: -> [Phase1, Phase2]
    {transitions, rest} = parse_optional_transitions(rest, file)

    # Check for variant fields: (field: Type, ...)
    {fields, rest} =
      case rest do
        [{:lparen, _} | rest2] ->
          case parse_variant_fields(rest2, file, []) do
            {:ok, fields, rest3} -> {fields, rest3}
            {:error, _} -> {[], rest}
          end

        _ ->
          {[], rest}
      end

    variant = %AST.Variant{
      name: name,
      fields: fields,
      transitions: transitions,
      meta: %{line: line, col: col, file: file}
    }

    parse_variants(rest, file, [variant | acc])
  end

  defp parse_variants(tokens, file, _acc) do
    unexpected_token_error(tokens, file, "a variant name")
  end

  defp parse_optional_transitions([{:arrow, _}, {:lbracket, _} | rest], file) do
    parse_transition_targets(rest, file, [])
  end

  defp parse_optional_transitions(rest, _file) do
    {[], rest}
  end

  defp parse_transition_targets([{:rbracket, _} | rest], _file, acc) do
    {Enum.reverse(acc), rest}
  end

  defp parse_transition_targets([{:comma, _} | rest], file, acc) do
    parse_transition_targets(rest, file, acc)
  end

  defp parse_transition_targets([{:upper_ident, _, name} | rest], file, acc) do
    parse_transition_targets(rest, file, [name | acc])
  end

  defp parse_transition_targets(rest, _file, acc) do
    {Enum.reverse(acc), rest}
  end

  defp parse_variant_fields([{:rparen, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_variant_fields([{:comma, _} | rest], file, acc) do
    parse_variant_fields(rest, file, acc)
  end

  defp parse_variant_fields(tokens, file, acc) do
    with {:ok, name, rest} <- expect_lower_ident(tokens, file),
         {:ok, _colon, rest} <- expect(:colon, rest, file),
         {:ok, type, rest} <- parse_type_expr(rest, file) do
      field = %AST.Field{
        name: name,
        type: type,
        annotations: [],
        meta: meta_from_tokens(tokens, file)
      }

      parse_variant_fields(rest, file, [field | acc])
    end
  end

  # ------------------------------------------------------------------
  # Supervisor declaration
  # ------------------------------------------------------------------

  defp parse_supervisor([{:supervisor, {line, col}} | rest], file) do
    with {:ok, name, rest} <- expect_upper_ident(rest, file),
         {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, children, strategy, max_restarts, rest} <-
           parse_supervisor_body(rest, file, [], nil, nil),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      supervisor = %AST.Supervisor{
        name: name,
        children: children,
        strategy: strategy,
        max_restarts: max_restarts,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, supervisor, rest}
    end
  end

  # Parse the body of a supervisor: children, strategy, max_restarts (in any order)
  defp parse_supervisor_body([{:rbrace, _} | _] = tokens, _file, children, strategy, max_restarts) do
    {:ok, Enum.reverse(children), strategy, max_restarts, tokens}
  end

  defp parse_supervisor_body(
         [{:ident, _, "child"} | _] = tokens,
         file,
         children,
         strategy,
         max_restarts
       ) do
    case parse_child_decl(tokens, file) do
      {:ok, child, rest} ->
        parse_supervisor_body(rest, file, [child | children], strategy, max_restarts)

      {:error, _} = error ->
        error
    end
  end

  defp parse_supervisor_body(
         [{:ident, _, "strategy"}, {:colon, _}, {:ident, _, strategy_name} | rest],
         file,
         children,
         _strategy,
         max_restarts
       )
       when strategy_name in ["one_for_one", "one_for_all", "rest_for_one"] do
    strategy = String.to_atom(strategy_name)
    parse_supervisor_body(rest, file, children, strategy, max_restarts)
  end

  # max_restarts: N per Ns
  defp parse_supervisor_body(
         [
           {:ident, _, "max_restarts"},
           {:colon, _},
           {:int, _, max_count},
           {:ident, _, "per"},
           {:int, _, period},
           {:ident, _, "s"} | rest
         ],
         file,
         children,
         strategy,
         _max_restarts
       ) do
    parse_supervisor_body(rest, file, children, strategy, {max_count, period})
  end

  # A known entry name with a wrong following token gets a targeted error
  # naming the actual problem instead of re-listing the alternatives.
  defp parse_supervisor_body(
         [{:ident, _, "strategy"}, {:colon, _} | rest],
         file,
         _children,
         _strategy,
         _max_restarts
       ) do
    unexpected_token_error(
      rest,
      file,
      "a supervisor strategy (one_for_one, one_for_all, rest_for_one)",
      "one_for_one"
    )
  end

  defp parse_supervisor_body(
         [{:ident, {line, col}, "strategy"} | _],
         file,
         _children,
         _strategy,
         _max_restarts
       ) do
    missing_token_after_error("strategy", ":", {line, col}, file)
  end

  defp parse_supervisor_body(
         [{:ident, _, "max_restarts"}, {:colon, _} | rest],
         file,
         _children,
         _strategy,
         _max_restarts
       ) do
    unexpected_token_error(rest, file, "'N per Ns' (e.g., 3 per 60s)", "3 per 60s")
  end

  defp parse_supervisor_body(
         [{:ident, {line, col}, "max_restarts"} | _],
         file,
         _children,
         _strategy,
         _max_restarts
       ) do
    missing_token_after_error("max_restarts", ":", {line, col}, file)
  end

  defp parse_supervisor_body(tokens, file, _children, _strategy, _max_restarts) do
    unexpected_token_error(
      tokens,
      file,
      "a supervisor body element (child, strategy:, max_restarts:)"
    )
  end

  # Parse a child declaration: child Target or child Target(Args...) { opts }
  defp parse_child_decl([{:ident, {line, col}, "child"} | rest], file) do
    with {:ok, target, rest} <- expect_upper_ident(rest, file) do
      # Check for arguments: child Target(Arg1, Arg2)
      {args, rest} =
        case rest do
          [{:lparen, _} | rest2] ->
            parse_child_args(rest2, file, [])

          _ ->
            {[], rest}
        end

      # Check for options: { key: value, ... }
      {options, rest} =
        case rest do
          [{:lbrace, _} | rest2] ->
            parse_child_options(rest2, file, %{})

          _ ->
            {%{}, rest}
        end

      child = %AST.Child{
        target: target,
        args: args,
        options: options,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, child, rest}
    end
  end

  defp parse_child_args([{:rparen, _} | rest], _file, acc) do
    {Enum.reverse(acc), rest}
  end

  defp parse_child_args([{:comma, _} | rest], file, acc) do
    parse_child_args(rest, file, acc)
  end

  defp parse_child_args([{:upper_ident, _, name} | rest], file, acc) do
    parse_child_args(rest, file, [name | acc])
  end

  defp parse_child_args(rest, _file, acc) do
    {Enum.reverse(acc), rest}
  end

  # Parse child options: key: value pairs terminated by }
  defp parse_child_options([{:rbrace, _} | rest], _file, acc) do
    {acc, rest}
  end

  defp parse_child_options([{:comma, _} | rest], file, acc) do
    parse_child_options(rest, file, acc)
  end

  defp parse_child_options([{:ident, _, key}, {:colon, _}, {:int, _, value} | rest], file, acc) do
    parse_child_options(rest, file, Map.put(acc, key, value))
  end

  defp parse_child_options(
         [{:ident, _, key}, {:colon, _}, {:ident, _, value} | rest],
         file,
         acc
       ) do
    parse_child_options(rest, file, Map.put(acc, key, value))
  end

  defp parse_child_options(rest, _file, acc) do
    {acc, rest}
  end

  # ------------------------------------------------------------------
  # Block: { expr1 expr2 ... exprN }
  # ------------------------------------------------------------------

  defp parse_block([{:lbrace, {line, col}} | rest], file) do
    case parse_block_body(rest, file, []) do
      {:ok, exprs, rest} ->
        block = %AST.Block{
          expressions: exprs,
          meta: %{line: line, col: col, file: file}
        }

        {:ok, block, rest}

      {:error, _} = error ->
        error
    end
  end

  defp parse_block(tokens, file) do
    unexpected_token_error(tokens, file, "'{'")
  end

  defp parse_block_body([{:rbrace, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_block_body([{:eof, {line, col}} | _], file, _acc) do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Unexpected end of file, expected '}'",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add a closing '}'",
         fix_code: "}"
       }
     ]}
  end

  defp parse_block_body(tokens, file, acc) do
    case parse_expression(tokens, file) do
      {:ok, expr, rest} ->
        parse_block_body(rest, file, [expr | acc])

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------
  # Expressions — Pratt-style precedence climbing
  # ------------------------------------------------------------------

  defp parse_expression(tokens, file) do
    case parse_let_or_match_or_pipe(tokens, file) do
      {:ok, _expr, _rest} = result -> result
      {:error, _} = error -> error
    end
  end

  # Let expression
  defp parse_let_or_match_or_pipe([{:let, _} | _] = tokens, file) do
    parse_let(tokens, file)
  end

  # Match expression
  defp parse_let_or_match_or_pipe([{:match, _} | _] = tokens, file) do
    parse_match(tokens, file)
  end

  # Emit expression: emit EventName { field: value, ... }
  defp parse_let_or_match_or_pipe(
         [{:emit, {line, col}}, {:upper_ident, _, event_name} | rest],
         file
       ) do
    case rest do
      [{:lbrace, _} | rest2] ->
        case parse_emit_fields(rest2, file, []) do
          {:ok, fields, rest3} ->
            emit = %AST.Emit{
              event_name: event_name,
              fields: fields,
              meta: %{line: line, col: col, file: file}
            }

            {:ok, emit, rest3}

          {:error, _} = error ->
            error
        end

      _ ->
        # emit with no fields
        emit = %AST.Emit{
          event_name: event_name,
          fields: [],
          meta: %{line: line, col: col, file: file}
        }

        {:ok, emit, rest}
    end
  end

  # Assert expression: assert expr
  defp parse_let_or_match_or_pipe([{:ident, {line, col}, "assert"} | rest], file) do
    case parse_pipe_expr(rest, file) do
      {:ok, expr, rest2} ->
        assert_node = %AST.Call{
          target: %AST.Identifier{name: "__assert__", meta: %{line: line, col: col, file: file}},
          args: [expr],
          meta: %{line: line, col: col, file: file}
        }

        {:ok, assert_node, rest2}

      {:error, _} = error ->
        error
    end
  end

  defp parse_let_or_match_or_pipe(tokens, file) do
    parse_pipe_expr(tokens, file)
  end

  # ------------------------------------------------------------------
  # Let binding
  # ------------------------------------------------------------------

  defp parse_let([{:let, {line, col}} | rest], file) do
    name_meta =
      case rest do
        [{:ident, {name_line, name_col}, _} | _] ->
          %{line: name_line, col: name_col, file: file}

        _ ->
          nil
      end

    with {:ok, name, rest} <- expect_lower_ident(rest, file),
         {:ok, _eq, rest} <- expect(:eq, rest, file),
         {:ok, value, rest} <- parse_expression(rest, file) do
      let_node = %AST.Let{
        name: name,
        type: nil,
        value: value,
        meta: %{line: line, col: col, file: file},
        name_meta: name_meta
      }

      {:ok, let_node, rest}
    end
  end

  # ------------------------------------------------------------------
  # Match expression
  # ------------------------------------------------------------------

  defp parse_match([{:match, {line, col}} | rest], file) do
    with {:ok, subject, rest} <- parse_pipe_expr(rest, file),
         {:ok, _lbrace, rest} <- expect(:lbrace, rest, file),
         {:ok, arms, rest} <- parse_match_arms(rest, file, []),
         {:ok, _rbrace, rest} <- expect(:rbrace, rest, file) do
      match_node = %AST.Match{
        subject: subject,
        arms: arms,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, match_node, rest}
    end
  end

  defp parse_match_arms([{:rbrace, _} | _] = tokens, _file, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_match_arms(tokens, file, acc) do
    case parse_match_arm(tokens, file) do
      {:ok, arm, rest} ->
        parse_match_arms(rest, file, [arm | acc])

      {:error, _} = error ->
        error
    end
  end

  defp parse_match_arm(tokens, file) do
    with {:ok, pattern, rest} <- parse_pattern(tokens, file),
         {:ok, guard, rest} <- parse_optional_guard(rest, file),
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, body, rest} <- parse_expression(rest, file) do
      arm = %AST.MatchArm{
        pattern: pattern,
        guard: guard,
        body: body,
        meta: meta_from_tokens(tokens, file)
      }

      {:ok, arm, rest}
    end
  end

  # Optional guard between the arm pattern and its arrow: `pattern if expr ->`.
  # `if` is contextual — it only introduces a guard in this position.
  defp parse_optional_guard([{:ident, _, "if"} | rest], file) do
    parse_pipe_expr(rest, file)
  end

  defp parse_optional_guard(tokens, _file), do: {:ok, nil, tokens}

  # ------------------------------------------------------------------
  # Patterns (for match arms)
  # ------------------------------------------------------------------

  defp parse_pattern([{true, {line, col}} | rest], file) do
    {:ok, %AST.BoolLit{value: true, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_pattern([{false, {line, col}} | rest], file) do
    {:ok, %AST.BoolLit{value: false, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_pattern([{:ident, {line, col}, "_"} | rest], file) do
    {:ok, %AST.Wildcard{meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_pattern([{:ident, {line, col}, name} | rest], file) do
    {:ok, %AST.Identifier{name: name, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_pattern([{:upper_ident, {line, col}, name} | rest], file) do
    # Enum variant pattern: Variant or Variant(fields...)
    # Also handles dotted: Enum.Variant
    {full_name, rest} =
      case rest do
        [{:dot, _}, {:upper_ident, _, sub} | rest2] ->
          {name <> "." <> sub, rest2}

        _ ->
          {name, rest}
      end

    case rest do
      [{:lparen, _} | rest2] ->
        case parse_pattern_args(rest2, file, []) do
          {:ok, args, rest3} ->
            variant = %AST.Call{
              target: %AST.Identifier{name: full_name, meta: %{line: line, col: col, file: file}},
              args: args,
              meta: %{line: line, col: col, file: file}
            }

            {:ok, variant, rest3}

          {:error, _} = error ->
            error
        end

      _ ->
        {:ok, %AST.Identifier{name: full_name, meta: %{line: line, col: col, file: file}}, rest}
    end
  end

  defp parse_pattern([{:int, {line, col}, value} | rest], file) do
    {:ok, %AST.IntLit{value: value, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_pattern([{:string, {line, col}, segments} | rest], file) do
    {:ok,
     %AST.StringLit{
       segments: normalize_string_segments(segments, file),
       meta: %{line: line, col: col, file: file}
     }, rest}
  end

  defp parse_pattern(tokens, file) do
    unexpected_token_error(tokens, file, "a pattern")
  end

  defp parse_pattern_args([{:rparen, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_pattern_args([{:comma, _} | rest], file, acc) do
    parse_pattern_args(rest, file, acc)
  end

  defp parse_pattern_args(tokens, file, acc) do
    case parse_pattern(tokens, file) do
      {:ok, pattern, rest} ->
        parse_pattern_args(rest, file, [pattern | acc])

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------
  # Pipe expression: expr |> expr |> expr ...
  # ------------------------------------------------------------------

  defp parse_pipe_expr(tokens, file) do
    case parse_or_expr(tokens, file) do
      {:ok, left, [{:pipe, {line, col}} | rest]} ->
        parse_pipe_rhs(rest, file, left, line, col)

      other ->
        other
    end
  end

  defp parse_pipe_rhs(tokens, file, left, line, col) do
    case parse_or_expr(tokens, file) do
      {:ok, right, [{:pipe, {line2, col2}} | rest]} ->
        pipe = %AST.Pipe{left: left, right: right, meta: %{line: line, col: col, file: file}}
        parse_pipe_rhs(rest, file, pipe, line2, col2)

      {:ok, right, rest} ->
        pipe = %AST.Pipe{left: left, right: right, meta: %{line: line, col: col, file: file}}
        {:ok, pipe, rest}

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------
  # Logical OR: ||
  # ------------------------------------------------------------------

  defp parse_or_expr(tokens, file) do
    case parse_and_expr(tokens, file) do
      {:ok, left, [{:or_or, {line, col}} | rest]} ->
        parse_binary_rhs(rest, file, :or_or, left, line, col, &parse_and_expr/2, &parse_or_rhs/6)

      other ->
        other
    end
  end

  defp parse_or_rhs(tokens, file, left, _line, _col, _parse_lower) do
    case tokens do
      [{:or_or, {line2, col2}} | rest] ->
        parse_binary_rhs(
          rest,
          file,
          :or_or,
          left,
          line2,
          col2,
          &parse_and_expr/2,
          &parse_or_rhs/6
        )

      _ ->
        {:ok, left, tokens}
    end
  end

  # ------------------------------------------------------------------
  # Logical AND: &&
  # ------------------------------------------------------------------

  defp parse_and_expr(tokens, file) do
    case parse_equality_expr(tokens, file) do
      {:ok, left, [{:and_and, {line, col}} | rest]} ->
        parse_binary_rhs(
          rest,
          file,
          :and_and,
          left,
          line,
          col,
          &parse_equality_expr/2,
          &parse_and_rhs/6
        )

      other ->
        other
    end
  end

  defp parse_and_rhs(tokens, file, left, _line, _col, _parse_lower) do
    case tokens do
      [{:and_and, {line2, col2}} | rest] ->
        parse_binary_rhs(
          rest,
          file,
          :and_and,
          left,
          line2,
          col2,
          &parse_equality_expr/2,
          &parse_and_rhs/6
        )

      _ ->
        {:ok, left, tokens}
    end
  end

  # ------------------------------------------------------------------
  # Equality: ==, !=
  # ------------------------------------------------------------------

  defp parse_equality_expr(tokens, file) do
    case parse_comparison_expr(tokens, file) do
      {:ok, left, [{op, {line, col}} | rest]} when op in [:eq_eq, :neq] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line,
          col,
          &parse_comparison_expr/2,
          &parse_equality_rhs/6
        )

      other ->
        other
    end
  end

  defp parse_equality_rhs(tokens, file, left, _line, _col, _parse_lower) do
    case tokens do
      [{op, {line2, col2}} | rest] when op in [:eq_eq, :neq] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line2,
          col2,
          &parse_comparison_expr/2,
          &parse_equality_rhs/6
        )

      _ ->
        {:ok, left, tokens}
    end
  end

  # ------------------------------------------------------------------
  # Comparison: <, >, <=, >=
  # ------------------------------------------------------------------

  defp parse_comparison_expr(tokens, file) do
    case parse_additive_expr(tokens, file) do
      {:ok, left, [{op, {line, col}} | rest]} when op in [:lt, :gt, :lte, :gte] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line,
          col,
          &parse_additive_expr/2,
          &parse_comparison_rhs/6
        )

      other ->
        other
    end
  end

  defp parse_comparison_rhs(tokens, file, left, _line, _col, _parse_lower) do
    case tokens do
      [{op, {line2, col2}} | rest] when op in [:lt, :gt, :lte, :gte] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line2,
          col2,
          &parse_additive_expr/2,
          &parse_comparison_rhs/6
        )

      _ ->
        {:ok, left, tokens}
    end
  end

  # ------------------------------------------------------------------
  # Additive: +, -
  # ------------------------------------------------------------------

  defp parse_additive_expr(tokens, file) do
    case parse_multiplicative_expr(tokens, file) do
      {:ok, left, [{op, {line, col}} | rest]} when op in [:plus, :minus] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line,
          col,
          &parse_multiplicative_expr/2,
          &parse_additive_rhs/6
        )

      other ->
        other
    end
  end

  defp parse_additive_rhs(tokens, file, left, _line, _col, _parse_lower) do
    case tokens do
      [{op, {line2, col2}} | rest] when op in [:plus, :minus] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line2,
          col2,
          &parse_multiplicative_expr/2,
          &parse_additive_rhs/6
        )

      _ ->
        {:ok, left, tokens}
    end
  end

  # ------------------------------------------------------------------
  # Multiplicative: *, /
  # ------------------------------------------------------------------

  defp parse_multiplicative_expr(tokens, file) do
    case parse_unary_expr(tokens, file) do
      {:ok, left, [{op, {line, col}} | rest]} when op in [:star, :slash] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line,
          col,
          &parse_unary_expr/2,
          &parse_multiplicative_rhs/6
        )

      other ->
        other
    end
  end

  defp parse_multiplicative_rhs(tokens, file, left, _line, _col, _parse_lower) do
    case tokens do
      [{op, {line2, col2}} | rest] when op in [:star, :slash] ->
        parse_binary_rhs(
          rest,
          file,
          op,
          left,
          line2,
          col2,
          &parse_unary_expr/2,
          &parse_multiplicative_rhs/6
        )

      _ ->
        {:ok, left, tokens}
    end
  end

  # Helper for left-associative binary operators
  defp parse_binary_rhs(tokens, file, op, left, line, col, parse_lower, continue) do
    case parse_lower.(tokens, file) do
      {:ok, right, rest} ->
        op_atom = op_to_atom(op)

        node = %AST.BinaryOp{
          op: op_atom,
          left: left,
          right: right,
          meta: %{line: line, col: col, file: file}
        }

        continue.(rest, file, node, line, col, parse_lower)

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------
  # Unary: prefix ! and -, postfix ! and ?
  # ------------------------------------------------------------------

  defp parse_unary_expr([{:bang, {line, col}} | rest], file) do
    case parse_unary_expr(rest, file) do
      {:ok, operand, rest} ->
        node = %AST.UnaryOp{
          op: :not,
          operand: operand,
          meta: %{line: line, col: col, file: file}
        }

        {:ok, node, rest}

      {:error, _} = error ->
        error
    end
  end

  # Prefix minus (arithmetic negation): binds tighter than binary
  # arithmetic, so `-2 + 3` is `(-2) + 3` and `-x.field` is `-(x.field)`.
  defp parse_unary_expr([{:minus, {line, col}} | rest], file) do
    case parse_unary_expr(rest, file) do
      {:ok, operand, rest} ->
        node = %AST.UnaryOp{
          op: :negate,
          operand: operand,
          meta: %{line: line, col: col, file: file}
        }

        {:ok, node, rest}

      {:error, _} = error ->
        error
    end
  end

  defp parse_unary_expr(tokens, file) do
    case parse_postfix_expr(tokens, file) do
      {:ok, expr, rest} -> parse_unwrap_suffix(expr, rest, file)
      {:error, _} = error -> error
    end
  end

  # Postfix `!` (unwrap) and `?` (propagate) bind to the expression before
  # them, and the postfix chain may continue afterwards — `get(id)!.name`,
  # `memory.get(k)!.load()!.value` (#268: `get(k)!` is the one spelling).
  defp parse_unwrap_suffix(expr, [{:bang, {line, col}} | rest], file) do
    node = %AST.UnaryOp{
      op: :unwrap,
      operand: expr,
      meta: %{line: line, col: col, file: file}
    }

    case parse_postfix_chain(node, rest, file) do
      {:ok, chained, rest2} -> parse_unwrap_suffix(chained, rest2, file)
      {:error, _} = error -> error
    end
  end

  defp parse_unwrap_suffix(expr, [{:question, {line, col}} | rest], file) do
    node = %AST.UnaryOp{
      op: :propagate,
      operand: expr,
      meta: %{line: line, col: col, file: file}
    }

    case parse_postfix_chain(node, rest, file) do
      {:ok, chained, rest2} -> parse_unwrap_suffix(chained, rest2, file)
      {:error, _} = error -> error
    end
  end

  defp parse_unwrap_suffix(expr, tokens, _file), do: {:ok, expr, tokens}

  # ------------------------------------------------------------------
  # Postfix: call f(...), field access x.y
  # ------------------------------------------------------------------

  defp parse_postfix_expr(tokens, file) do
    case parse_primary(tokens, file) do
      {:ok, expr, rest} ->
        parse_postfix_chain(expr, rest, file)

      {:error, _} = error ->
        error
    end
  end

  # The pre-paren forms `method!(args)` / `method?(args)` were removed
  # (#268): `!`/`?` come after the closing paren — `get(k)!` is the one
  # spelling. A parse of the removed form gets a targeted structured error.
  defp parse_postfix_chain(expr, [{:bang, {bline, bcol}}, {:lparen, _} | _], file) do
    removed_prefix_unwrap_error(expr, "!", {bline, bcol}, file)
  end

  defp parse_postfix_chain(expr, [{:question, {qline, qcol}}, {:lparen, _} | _], file) do
    removed_prefix_unwrap_error(expr, "?", {qline, qcol}, file)
  end

  defp parse_postfix_chain(expr, [{:lparen, {line, _col}} | _] = tokens, file) do
    # A call "(" must sit on the same line as the end of its target — a "("
    # that starts a new line is the grouping paren of the NEXT expression,
    # never a call of the previous one (#311). Identifier and FieldAccess
    # metas carry exactly the last token of a target chain, so same-line is
    # checkable without threading token positions.
    if same_line_call_target?(expr, line) do
      parse_call_continuation(expr, tokens, file)
    else
      {:ok, expr, tokens}
    end
  end

  defp parse_postfix_chain(expr, [{:dot, _}, {:ident, {line, col}, field_name} | rest], file) do
    field = %AST.FieldAccess{
      subject: expr,
      field: field_name,
      meta: %{line: line, col: col, file: file}
    }

    parse_postfix_chain(field, rest, file)
  end

  defp parse_postfix_chain(expr, [{:dot, _}, {:upper_ident, {line, col}, name} | rest], file) do
    # For things like Phase.Analyze, String.trim, etc.
    field = %AST.FieldAccess{
      subject: expr,
      field: name,
      meta: %{line: line, col: col, file: file}
    }

    parse_postfix_chain(field, rest, file)
  end

  # Type-parameterized postfix: expr[TypeExpr](args...)
  # Used for llm.json[T](...) syntax
  defp parse_postfix_chain(expr, [{:lbracket, _}, {:upper_ident, _, _} | _] = tokens, file) do
    [{:lbracket, _} | rest] = tokens

    case parse_type_expr(rest, file) do
      {:ok, type_ref, [{:rbracket, {rb_line, _}}, {:lparen, {line, col}} | rest2]}
      when rb_line == line ->
        # Type-parameterized call: expr[T](args...) — same-line "(" only (#311)
        case parse_args(rest2, file, []) do
          {:ok, args, rest3} ->
            call = %AST.Call{
              target: expr,
              args: args,
              type_param: type_ref,
              meta: %{line: line, col: col, file: file}
            }

            parse_postfix_chain(call, rest3, file)

          {:error, _} = error ->
            error
        end

      {:ok, type_ref, [{:rbracket, {line, col}} | rest2]} ->
        # Type parameter without call args — e.g., req.json[T]
        call = %AST.Call{
          target: expr,
          args: [],
          type_param: type_ref,
          meta: %{line: line, col: col, file: file}
        }

        parse_postfix_chain(call, rest2, file)

      _ ->
        # Not a valid type parameter, stop the chain
        {:ok, expr, tokens}
    end
  end

  defp parse_postfix_chain(expr, rest, _file) do
    {:ok, expr, rest}
  end

  # Call targets are identifiers or dotted chains; their metas point at the
  # final token of the chain (FieldAccess meta is the FIELD's position), so a
  # legal call's "(" always shares that line. Any other node as a call target
  # is an illegal expression-call anyway — refusing the continuation lets the
  # paren group parse as the next expression instead.
  defp same_line_call_target?(%AST.Identifier{meta: %{line: target_line}}, line),
    do: target_line == line

  defp same_line_call_target?(%AST.FieldAccess{meta: %{line: target_line}}, line),
    do: target_line == line

  defp same_line_call_target?(_expr, _line), do: false

  defp parse_call_continuation(expr, [{:lparen, {line, col}} | rest], file) do
    case parse_args(rest, file, []) do
      {:ok, args, rest} ->
        # When the call target is tool.call or tool.schema, convert the
        # first argument from Identifier/FieldAccess to a ToolRef node.
        args = maybe_convert_tool_ref_arg(expr, args)

        call = %AST.Call{
          target: expr,
          args: args,
          meta: %{line: line, col: col, file: file}
        }

        parse_postfix_chain(call, rest, file)

      {:error, _} = error ->
        error
    end
  end

  # The removed `method!(args)` / `method?(args)` spelling (#268): name the
  # method in the message and point at the postfix form.
  defp removed_prefix_unwrap_error(expr, op_text, {line, col}, file) do
    method =
      case expr do
        %AST.FieldAccess{field: field} -> field
        %AST.Identifier{name: name} -> name
        _ -> "method"
      end

    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message:
           "'#{method}#{op_text}(...)' is not valid Skein — write '#{method}(...)#{op_text}'",
         location: %{file: file, line: line, col: col},
         fix_hint: "'#{op_text}' comes after the closing paren: it unwraps the call's result",
         fix_code: nil
       }
     ]}
  end

  # ------------------------------------------------------------------
  # Call arguments
  # ------------------------------------------------------------------

  defp parse_args([{:rparen, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_args([{:comma, _} | rest], file, acc) do
    parse_args(rest, file, acc)
  end

  # Named argument: `name: expr`. The two-token lookahead (ident then
  # colon) is unambiguous — no expression can start that way.
  defp parse_args([{:ident, {line, col}, name}, {:colon, _} | rest], file, acc) do
    case parse_expression(rest, file) do
      {:ok, value, rest2} ->
        named = %AST.NamedArg{
          name: name,
          value: value,
          meta: %{line: line, col: col, file: file}
        }

        parse_args(rest2, file, [named | acc])

      {:error, _} = error ->
        error
    end
  end

  defp parse_args(tokens, file, acc) do
    case parse_expression(tokens, file) do
      {:ok, expr, rest} ->
        parse_args(rest, file, [expr | acc])

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------
  # Primary expressions (atoms)
  # ------------------------------------------------------------------

  defp parse_primary([{:int, {line, col}, value} | rest], file) do
    {:ok, %AST.IntLit{value: value, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_primary([{:float, {line, col}, value} | rest], file) do
    {:ok, %AST.FloatLit{value: value, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_primary([{true, {line, col}} | rest], file) do
    {:ok, %AST.BoolLit{value: true, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_primary([{false, {line, col}} | rest], file) do
    {:ok, %AST.BoolLit{value: false, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_primary([{:string, {line, col}, segments} | rest], file) do
    {:ok,
     %AST.StringLit{
       segments: normalize_string_segments(segments, file),
       meta: %{line: line, col: col, file: file}
     }, rest}
  end

  defp parse_primary([{:ident, {line, col}, name} | rest], file) do
    {:ok, %AST.Identifier{name: name, meta: %{line: line, col: col, file: file}}, rest}
  end

  # Record literal: TypeName { field: expr, ... } (incl. empty TypeName {}).
  # Disambiguated exactly like map literals: the brace must be empty or open
  # with `ident :`. This keeps `match Upper { arm -> ... }` (arms are patterns,
  # not `ident :`) parsing as a match, not a record literal.
  defp parse_primary(
         [{:upper_ident, {line, col}, name}, {:lbrace, _}, {:rbrace, _} | rest],
         file
       ) do
    record = %AST.RecordLit{
      type_name: name,
      fields: [],
      meta: %{line: line, col: col, file: file}
    }

    {:ok, record, rest}
  end

  defp parse_primary(
         [{:upper_ident, {line, col}, name}, {:lbrace, _}, {:ident, _, _}, {:colon, _} | _] =
           [_upper, _lbrace | after_brace],
         file
       ) do
    case parse_map_entries(after_brace, file, []) do
      {:ok, fields, rest} ->
        record = %AST.RecordLit{
          type_name: name,
          fields: fields,
          meta: %{line: line, col: col, file: file}
        }

        {:ok, record, rest}

      {:error, _} = error ->
        error
    end
  end

  defp parse_primary([{:upper_ident, {line, col}, name} | rest], file) do
    {:ok, %AST.Identifier{name: name, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_primary([{:ampersand, {line, col}}, {:ident, _, name} | rest], file) do
    {:ok, %AST.FnRef{name: name, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_primary([{:lparen, _} | rest], file) do
    # Parenthesized expression
    case parse_expression(rest, file) do
      {:ok, expr, [{:rparen, _} | rest2]} ->
        {:ok, expr, rest2}

      {:ok, _expr, rest2} ->
        unexpected_token_error(rest2, file, "')'")

      {:error, _} = error ->
        error
    end
  end

  # List literal: [expr, expr, ...]
  defp parse_primary([{:lbracket, {line, col}} | rest], file) do
    case parse_list_elements(rest, file, []) do
      {:ok, elements, rest} ->
        list = %AST.ListLit{
          elements: elements,
          meta: %{line: line, col: col, file: file}
        }

        {:ok, list, rest}

      {:error, _} = error ->
        error
    end
  end

  # tool as primary expression (for tool.call, tool.list, tool.schema)
  defp parse_primary([{:tool, {line, col}} | rest], file) do
    {:ok, %AST.Identifier{name: "tool", meta: %{line: line, col: col, file: file}}, rest}
  end

  # Map literal or block as primary expression
  # Disambiguate: { ident: ... } is a map literal, { expr ... } is a block
  defp parse_primary([{:lbrace, _}, {:ident, _, _}, {:colon, _} | _] = tokens, file) do
    parse_map_literal(tokens, file)
  end

  # Empty braces: treat as empty map literal
  defp parse_primary([{:lbrace, {line, col}}, {:rbrace, _} | rest], file) do
    {:ok, %AST.MapLit{entries: [], meta: %{line: line, col: col, file: file}}, rest}
  end

  # Block as primary expression (fallback)
  defp parse_primary([{:lbrace, _} | _] = tokens, file) do
    parse_block(tokens, file)
  end

  # transition(Phase.VariantName)
  defp parse_primary([{:transition, {line, col}}, {:lparen, _} | rest], file) do
    with {:ok, phase_ref, rest2} <- parse_phase_ref(rest, file),
         {:ok, _rparen, rest2} <- expect(:rparen, rest2, file) do
      transition = %AST.Transition{
        phase: phase_ref,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, transition, rest2}
    end
  end

  # stop()
  defp parse_primary([{:stop, {line, col}}, {:lparen, _}, {:rparen, _} | rest], file) do
    {:ok, %AST.Stop{meta: %{line: line, col: col, file: file}}, rest}
  end

  # suspend(reason_expr)
  defp parse_primary([{:suspend, {line, col}}, {:lparen, _} | rest], file) do
    with {:ok, reason, rest2} <- parse_expression(rest, file),
         {:ok, _rparen, rest2} <- expect(:rparen, rest2, file) do
      suspend = %AST.Suspend{
        reason: reason,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, suspend, rest2}
    end
  end

  # idempotent(key_expr)
  defp parse_primary([{:idempotent, {line, col}}, {:lparen, _} | rest], file) do
    with {:ok, key, rest2} <- parse_expression(rest, file),
         {:ok, _rparen, rest2} <- expect(:rparen, rest2, file) do
      idempotent = %AST.Idempotent{
        key: key,
        meta: %{line: line, col: col, file: file}
      }

      {:ok, idempotent, rest2}
    end
  end

  defp parse_primary(tokens, file) do
    unexpected_token_error(tokens, file, "an expression")
  end

  # ------------------------------------------------------------------
  # List elements
  # ------------------------------------------------------------------

  defp parse_list_elements([{:rbracket, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_list_elements([{:comma, _} | rest], file, acc) do
    parse_list_elements(rest, file, acc)
  end

  defp parse_list_elements(tokens, file, acc) do
    case parse_expression(tokens, file) do
      {:ok, expr, rest} ->
        parse_list_elements(rest, file, [expr | acc])

      {:error, _} = error ->
        error
    end
  end

  # ------------------------------------------------------------------
  # Map literal: { key: value, key: value }
  # ------------------------------------------------------------------

  defp parse_map_literal([{:lbrace, {line, col}} | rest], file) do
    case parse_map_entries(rest, file, []) do
      {:ok, entries, rest} ->
        {:ok, %AST.MapLit{entries: entries, meta: %{line: line, col: col, file: file}}, rest}

      {:error, _} = error ->
        error
    end
  end

  defp parse_map_entries([{:rbrace, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_map_entries([{:comma, _} | rest], file, acc) do
    parse_map_entries(rest, file, acc)
  end

  defp parse_map_entries(tokens, file, acc) do
    with {:ok, name, rest} <- expect_lower_ident(tokens, file),
         {:ok, _colon, rest} <- expect(:colon, rest, file),
         {:ok, value, rest} <- parse_expression(rest, file) do
      parse_map_entries(rest, file, [{name, value} | acc])
    end
  end

  # ------------------------------------------------------------------
  # Emit fields: { field: value, field: value }
  # ------------------------------------------------------------------

  defp parse_emit_fields([{:rbrace, _} | rest], _file, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp parse_emit_fields([{:comma, _} | rest], file, acc) do
    parse_emit_fields(rest, file, acc)
  end

  defp parse_emit_fields(tokens, file, acc) do
    with {:ok, name, rest} <- expect_lower_ident(tokens, file),
         {:ok, _colon, rest} <- expect(:colon, rest, file),
         {:ok, value, rest} <- parse_expression(rest, file) do
      parse_emit_fields(rest, file, [{name, value} | acc])
    end
  end

  # ------------------------------------------------------------------
  # String interpolation segments
  # ------------------------------------------------------------------

  # The lexer represents interpolation segments as raw tokens
  # ({:ident, ...}, {:upper_ident, ...}, {:field_access, ...}). Normalize
  # them into AST nodes here so every downstream walker (analyzer passes,
  # codegen, source rendering) handles them like any other expression.
  defp normalize_string_segments(segments, file) do
    Enum.map(segments, fn
      {:interpolation, token} -> {:interpolation, interpolation_expr_to_ast(token, file)}
      literal -> literal
    end)
  end

  defp interpolation_expr_to_ast({kind, {line, col}, name}, file)
       when kind in [:ident, :upper_ident] do
    %AST.Identifier{name: name, meta: %{line: line, col: col, file: file}}
  end

  defp interpolation_expr_to_ast({:field_access, subject, field}, file) do
    subject_ast = interpolation_expr_to_ast(subject, file)
    %AST.FieldAccess{subject: subject_ast, field: field, meta: subject_ast.meta}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp expect(expected, [{expected, {line, col}} | rest], _file) do
    {:ok, {line, col}, rest}
  end

  defp expect(expected, tokens, file) do
    {line, col} = token_location(tokens)
    expected_text = token_text(expected)

    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Expected '#{expected_text}', got #{describe_token(tokens)}",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add '#{expected_text}' here",
         fix_code: expected_text,
         span: token_span(tokens),
         edit_kind: :insert_before
       }
     ]}
  end

  defp expect_lower_ident([{:ident, _, name} | rest], _file) do
    {:ok, name, rest}
  end

  defp expect_lower_ident(tokens, file) do
    {line, col} = token_location(tokens)

    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Expected an identifier, got #{describe_token(tokens)}",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add an identifier here",
         fix_code: "name",
         span: token_span(tokens)
       }
     ]}
  end

  defp expect_upper_ident([{:upper_ident, _, name} | rest], _file) do
    {:ok, name, rest}
  end

  defp expect_upper_ident(tokens, file) do
    {line, col} = token_location(tokens)

    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Expected a type/module name (uppercase), got #{describe_token(tokens)}",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add a capitalized name here",
         fix_code: "TypeName",
         span: token_span(tokens)
       }
     ]}
  end

  defp token_location([{_, {line, col}} | _]), do: {line, col}
  defp token_location([{_, {line, col}, _} | _]), do: {line, col}
  defp token_location(_), do: {0, 0}

  # Span covering the offending token's source text, where its length is
  # knowable (identifiers and fixed-text tokens). Number and string
  # literals lose their source length in lexing, so they get a point span.
  defp token_span([{kind, {line, col}, name} | _])
       when kind in [:ident, :upper_ident] and is_binary(name) do
    Error.span(line, col, String.length(name))
  end

  defp token_span([{_, {line, col}, _} | _]), do: Error.point(line, col)

  defp token_span([{:eof, {line, col}} | _]), do: Error.point(line, col)

  defp token_span([{type, {line, col}} | _]) do
    Error.span(line, col, String.length(token_text(type)))
  end

  defp token_span(_), do: nil

  defp describe_token([{:eof, _} | _]), do: "end of file"
  defp describe_token([{type, _} | _]), do: "'#{type}'"
  defp describe_token([{type, _, _} | _]), do: "'#{type}'"
  defp describe_token(_), do: "unknown"

  # Source text for punctuation tokens used with expect/3, so fix_code
  # carries insertable code rather than a token atom name.
  defp token_text(:lbrace), do: "{"
  defp token_text(:rbrace), do: "}"
  defp token_text(:lparen), do: "("
  defp token_text(:rparen), do: ")"
  defp token_text(:lbracket), do: "["
  defp token_text(:rbracket), do: "]"
  defp token_text(:arrow), do: "->"
  defp token_text(:colon), do: ":"
  defp token_text(:comma), do: ","
  defp token_text(:dot), do: "."
  defp token_text(:eq), do: "="
  defp token_text(other), do: to_string(other)

  # Derives an insertable code snippet from an expected-token description
  # for unexpected_token_error/3. A quoted description names the literal
  # token itself — an exact insertion; anything else gets an illustrative
  # template (no edit_kind).
  defp default_fix_code(expected) do
    case Regex.run(~r/^'([^']*)'$/, expected) do
      [_, literal] -> {literal, :insert_before}
      nil -> {example_fix_code(expected), nil}
    end
  end

  defp example_fix_code("an expression"), do: "value"
  defp example_fix_code("a pattern"), do: "_"
  defp example_fix_code("a type name"), do: "TypeName"
  defp example_fix_code("a variant name"), do: "VariantName"
  defp example_fix_code("a route string"), do: "\"/path\""
  defp example_fix_code("a description string"), do: "\"description\""
  defp example_fix_code("a test description string"), do: "\"description\""
  defp example_fix_code("a scenario description string"), do: "\"description\""
  defp example_fix_code("a golden test description string"), do: "\"description\""
  defp example_fix_code("an error type name"), do: "ErrorName"

  defp example_fix_code("an HTTP method (GET, POST, PUT, PATCH, DELETE)"), do: "GET"

  defp example_fix_code("a capability kind (e.g., http.out)"), do: "http.out"

  defp example_fix_code("a tool name (e.g., CreateRefund or Stripe.CreateRefund)"),
    do: "CreateRefund"

  defp example_fix_code("a phase reference (Phase.VariantName)"), do: "Phase.VariantName"

  defp example_fix_code("'start' or 'phase' after 'on'"),
    do: "on start(param: Type) -> { ... }"

  defp example_fix_code("an agent body element (capability, state, enum Phase, on, fn)"),
    do: "on start(param: Type) -> { ... }"

  defp example_fix_code("a tool section (description, input, output, errors, implement)"),
    do: "input { field: Type }"

  defp example_fix_code("a supervisor body element (child, strategy:, max_restarts:)"),
    do: "strategy: one_for_one"

  defp example_fix_code(expected), do: expected

  defp meta_from_tokens([{_, {line, col}} | _], file), do: %{line: line, col: col, file: file}
  defp meta_from_tokens([{_, {line, col}, _} | _], file), do: %{line: line, col: col, file: file}
  defp meta_from_tokens(_, file), do: %{line: 0, col: 0, file: file}

  defp unexpected_token_error(tokens, file, expected) do
    {fix_code, edit_kind} = default_fix_code(expected)
    unexpected_token_error(tokens, file, expected, fix_code, edit_kind)
  end

  defp unexpected_token_error(tokens, file, expected, fix_code, edit_kind \\ nil) do
    {line, col} = token_location(tokens)

    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Expected #{expected}, got #{describe_token(tokens)}",
         location: %{file: file, line: line, col: col},
         fix_hint: "Expected #{expected}",
         fix_code: fix_code,
         span: token_span(tokens),
         edit_kind: edit_kind
       }
     ]}
  end

  # Targeted error for a known section/entry name followed by the wrong
  # token (issue #83): names the missing token so the fix is mechanical.
  # The location is the keyword's start, so the span covers the keyword
  # and the fix inserts immediately after it.
  defp missing_token_after_error(keyword, token, {line, col}, file) do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Missing '#{token}' after '#{keyword}'",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add '#{token}' after '#{keyword}'",
         fix_code: token,
         span: Error.span(line, col, String.length(keyword)),
         edit_kind: :insert_after
       }
     ]}
  end

  defp op_to_atom(:plus), do: :+
  defp op_to_atom(:minus), do: :-
  defp op_to_atom(:star), do: :*
  defp op_to_atom(:slash), do: :/
  defp op_to_atom(:eq_eq), do: :==
  defp op_to_atom(:neq), do: :!=
  defp op_to_atom(:lt), do: :<
  defp op_to_atom(:gt), do: :>
  defp op_to_atom(:lte), do: :<=
  defp op_to_atom(:gte), do: :>=
  defp op_to_atom(:and_and), do: :&&
  defp op_to_atom(:or_or), do: :||

  # ------------------------------------------------------------------
  # ToolRef conversion helpers
  # ------------------------------------------------------------------

  # For tool.call(ToolName, args) and tool.schema(ToolName), convert the
  # first PascalCase identifier arg to a ToolRef AST node.
  defp maybe_convert_tool_ref_arg(
         %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: method},
         [first_arg | rest]
       )
       when method in ["call", "schema"] do
    [expr_to_tool_ref(first_arg) | rest]
  end

  defp maybe_convert_tool_ref_arg(_target, args), do: args

  # Convert capability tool.use params to ToolRef nodes.
  defp convert_tool_use_params(params) do
    Enum.map(params, &expr_to_tool_ref/1)
  end

  # Convert a PascalCase Identifier or dotted FieldAccess chain to a ToolRef.
  # Non-matching expressions pass through unchanged.
  defp expr_to_tool_ref(%AST.Identifier{name: <<first, _::binary>> = name, meta: meta})
       when first in ?A..?Z do
    %AST.ToolRef{name: name, meta: meta}
  end

  defp expr_to_tool_ref(%AST.FieldAccess{meta: meta} = fa) do
    case collect_dotted_tool_name(fa) do
      nil -> fa
      name -> %AST.ToolRef{name: name, meta: meta}
    end
  end

  defp expr_to_tool_ref(other), do: other

  # Collect "Stripe.CreateRefund" from nested FieldAccess(Identifier("Stripe"), "CreateRefund")
  defp collect_dotted_tool_name(%AST.FieldAccess{subject: subject, field: field}) do
    case collect_dotted_tool_name(subject) do
      nil -> nil
      prefix -> prefix <> "." <> field
    end
  end

  defp collect_dotted_tool_name(%AST.Identifier{name: <<first, _::binary>> = name})
       when first in ?A..?Z do
    name
  end

  defp collect_dotted_tool_name(_), do: nil
end
