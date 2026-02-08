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
    case parse_module(tokens, "unknown") do
      {:ok, ast, _rest} -> {:ok, ast}
      {:error, errors} -> {:error, errors}
    end
  end

  @spec parse(tokens(), String.t()) :: parse_result()
  def parse(tokens, file) do
    case parse_module(tokens, file) do
      {:ok, ast, _rest} -> {:ok, ast}
      {:error, errors} -> {:error, errors}
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

  defp parse_declaration([{token_type, {line, col}} | _], file) do
    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message:
           "Unexpected token #{inspect(token_type)}, expected a declaration (fn, type, enum, capability, handler)",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add a valid declaration keyword"
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
           "Unexpected token #{inspect(token_type)}, expected a declaration (fn, type, enum, capability, handler)",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add a valid declaration keyword"
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
    with {:ok, source, rest} <- expect_lower_ident(rest, file),
         {:ok, method, rest} <- expect_http_method(rest, file),
         {:ok, route, rest} <- expect_string_literal(rest, file),
         {:ok, _lparen, rest} <- expect(:lparen, rest, file),
         {:ok, param, rest} <- expect_lower_ident(rest, file),
         {:ok, _rparen, rest} <- expect(:rparen, rest, file),
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, body, rest} <- parse_block(rest, file) do
      handler = %AST.Handler{
        source: source,
        method: method,
        route: route,
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
         fix_hint: "Add a closing '}'"
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

  defp parse_let_or_match_or_pipe(tokens, file) do
    parse_pipe_expr(tokens, file)
  end

  # ------------------------------------------------------------------
  # Let binding
  # ------------------------------------------------------------------

  defp parse_let([{:let, {line, col}} | rest], file) do
    with {:ok, name, rest} <- expect_lower_ident(rest, file),
         {:ok, _eq, rest} <- expect(:eq, rest, file),
         {:ok, value, rest} <- parse_expression(rest, file) do
      let_node = %AST.Let{
        name: name,
        type: nil,
        value: value,
        meta: %{line: line, col: col, file: file}
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
         {:ok, _arrow, rest} <- expect(:arrow, rest, file),
         {:ok, body, rest} <- parse_expression(rest, file) do
      arm = %AST.MatchArm{
        pattern: pattern,
        guard: nil,
        body: body,
        meta: meta_from_tokens(tokens, file)
      }

      {:ok, arm, rest}
    end
  end

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
    {:ok, %AST.StringLit{segments: segments, meta: %{line: line, col: col, file: file}}, rest}
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
  # Unary: prefix !, postfix ! and ?
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

  defp parse_unary_expr(tokens, file) do
    case parse_postfix_expr(tokens, file) do
      {:ok, expr, [{:bang, {line, col}} | rest]} ->
        node = %AST.UnaryOp{
          op: :unwrap,
          operand: expr,
          meta: %{line: line, col: col, file: file}
        }

        {:ok, node, rest}

      {:ok, expr, [{:question, {line, col}} | rest]} ->
        node = %AST.UnaryOp{
          op: :propagate,
          operand: expr,
          meta: %{line: line, col: col, file: file}
        }

        {:ok, node, rest}

      other ->
        other
    end
  end

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

  defp parse_postfix_chain(expr, [{:lparen, {line, col}} | rest], file) do
    # Function call
    case parse_args(rest, file, []) do
      {:ok, args, rest} ->
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

  defp parse_postfix_chain(expr, rest, _file) do
    {:ok, expr, rest}
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
    {:ok, %AST.StringLit{segments: segments, meta: %{line: line, col: col, file: file}}, rest}
  end

  defp parse_primary([{:ident, {line, col}, name} | rest], file) do
    {:ok, %AST.Identifier{name: name, meta: %{line: line, col: col, file: file}}, rest}
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

  # Block as primary expression
  defp parse_primary([{:lbrace, _} | _] = tokens, file) do
    parse_block(tokens, file)
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
  # Helpers
  # ------------------------------------------------------------------

  defp expect(expected, [{expected, {line, col}} | rest], _file) do
    {:ok, {line, col}, rest}
  end

  defp expect(expected, tokens, file) do
    {line, col} = token_location(tokens)

    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Expected '#{expected}', got #{describe_token(tokens)}",
         location: %{file: file, line: line, col: col},
         fix_hint: "Add '#{expected}' here"
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
         fix_hint: "Add an identifier here"
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
         fix_hint: "Add a capitalized name here"
       }
     ]}
  end

  defp token_location([{_, {line, col}} | _]), do: {line, col}
  defp token_location([{_, {line, col}, _} | _]), do: {line, col}
  defp token_location(_), do: {0, 0}

  defp describe_token([{:eof, _} | _]), do: "end of file"
  defp describe_token([{type, _} | _]), do: "'#{type}'"
  defp describe_token([{type, _, _} | _]), do: "'#{type}'"
  defp describe_token(_), do: "unknown"

  defp meta_from_tokens([{_, {line, col}} | _], file), do: %{line: line, col: col, file: file}
  defp meta_from_tokens([{_, {line, col}, _} | _], file), do: %{line: line, col: col, file: file}
  defp meta_from_tokens(_, file), do: %{line: 0, col: 0, file: file}

  defp unexpected_token_error(tokens, file, expected) do
    {line, col} = token_location(tokens)

    {:error,
     [
       %Error{
         code: "E0001",
         severity: :error,
         message: "Expected #{expected}, got #{describe_token(tokens)}",
         location: %{file: file, line: line, col: col},
         fix_hint: "Expected #{expected}"
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
end
