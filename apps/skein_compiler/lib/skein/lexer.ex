defmodule Skein.Lexer do
  @moduledoc """
  Tokenizer for Skein source code.

  Converts UTF-8 source text into a list of `{token_type, location, value?}` tuples.
  Location is `{line, col}`, both 1-indexed.

  Token formats:
  - Keywords: `{:keyword_name, {line, col}}`
  - Identifiers: `{:ident, {line, col}, name}` or `{:upper_ident, {line, col}, name}`
  - Literals: `{:int, {line, col}, value}`, `{:float, {line, col}, value}`,
    `{:string, {line, col}, segments}`
  - Operators/delimiters: `{:op_name, {line, col}}`
  - End of file: `{:eof, {line, col}}`

  String tokens with interpolation are represented as a list of segments:

      {:string, {1, 1}, [
        {:literal, "Hello, "},
        {:interpolation, {:ident, {1, 10}, "name"}},
        {:literal, "!"}
      ]}
  """

  @keywords ~w(
    module fn let match type enum handler agent tool capability
    supervisor test scenario golden on emit transition stop suspend
    resume true false implement idempotent
  )a

  # Contextual keywords (input, output, errors, policy, description, state,
  # strategy, child, replay, given, expect, assert, if) are NOT in @keywords.
  # They are emitted as :ident tokens and recognised contextually by the parser.
  # See expect_ident_value/3 and direct {:ident, _, "word"} matches in parser.

  @keyword_strings Enum.map(@keywords, &Atom.to_string/1)

  @spec tokenize(String.t()) :: {:ok, list()} | {:error, [Skein.Error.t()]}
  def tokenize(source) do
    case do_tokenize(source, 1, 1, []) do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      {:error, _} = error -> error
    end
  end

  # Main tokenization loop
  defp do_tokenize(<<>>, line, col, acc) do
    {:ok, [{:eof, {line, col}} | acc]}
  end

  # Newlines
  defp do_tokenize(<<"\r\n", rest::binary>>, line, _col, acc) do
    do_tokenize(rest, line + 1, 1, acc)
  end

  defp do_tokenize(<<"\n", rest::binary>>, line, _col, acc) do
    do_tokenize(rest, line + 1, 1, acc)
  end

  defp do_tokenize(<<"\r", rest::binary>>, line, _col, acc) do
    do_tokenize(rest, line + 1, 1, acc)
  end

  # Whitespace (space, tab)
  defp do_tokenize(<<c, rest::binary>>, line, col, acc) when c in [?\s, ?\t] do
    do_tokenize(rest, line, col + 1, acc)
  end

  # Comments: -- to end of line
  defp do_tokenize(<<"--", rest::binary>>, line, col, acc) do
    {rest, skipped} = skip_to_eol(rest, 0)
    # The newline handler resets the position; tracking the skipped width
    # keeps the :eof column correct when a comment ends the file.
    do_tokenize(rest, line, col + 2 + skipped, acc)
  end

  # String literals
  defp do_tokenize(<<"\"", rest::binary>>, line, col, acc) do
    case lex_string(rest, line, col + 1, []) do
      {:ok, segments, rest, end_line, end_col} ->
        token = {:string, {line, col}, normalize_string_segments(segments)}
        do_tokenize(rest, end_line, end_col, [token | acc])

      {:error, error} ->
        {:error, [error]}
    end
  end

  # Numbers
  defp do_tokenize(<<c, _::binary>> = source, line, col, acc) when c in ?0..?9 do
    case lex_number(source, line, col) do
      {:error, error} ->
        {:error, [error]}

      {number_token, rest, new_col} ->
        do_tokenize(rest, line, new_col, [number_token | acc])
    end
  end

  # Two-character operators (must come before single-character)
  defp do_tokenize(<<"->", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:arrow, {line, col}} | acc])
  end

  defp do_tokenize(<<"|>", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:pipe, {line, col}} | acc])
  end

  defp do_tokenize(<<"==", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:eq_eq, {line, col}} | acc])
  end

  defp do_tokenize(<<"!=", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:neq, {line, col}} | acc])
  end

  defp do_tokenize(<<"<=", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:lte, {line, col}} | acc])
  end

  defp do_tokenize(<<">=", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:gte, {line, col}} | acc])
  end

  defp do_tokenize(<<"&&", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:and_and, {line, col}} | acc])
  end

  defp do_tokenize(<<"||", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 2, [{:or_or, {line, col}} | acc])
  end

  # Single-character operators and delimiters
  defp do_tokenize(<<"=", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:eq, {line, col}} | acc])
  end

  defp do_tokenize(<<"!", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:bang, {line, col}} | acc])
  end

  defp do_tokenize(<<"?", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:question, {line, col}} | acc])
  end

  defp do_tokenize(<<".", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:dot, {line, col}} | acc])
  end

  defp do_tokenize(<<":", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:colon, {line, col}} | acc])
  end

  defp do_tokenize(<<",", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:comma, {line, col}} | acc])
  end

  defp do_tokenize(<<"@", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:at, {line, col}} | acc])
  end

  defp do_tokenize(<<"&", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:ampersand, {line, col}} | acc])
  end

  defp do_tokenize(<<"{", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lbrace, {line, col}} | acc])
  end

  defp do_tokenize(<<"}", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:rbrace, {line, col}} | acc])
  end

  defp do_tokenize(<<"(", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lparen, {line, col}} | acc])
  end

  defp do_tokenize(<<")", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:rparen, {line, col}} | acc])
  end

  defp do_tokenize(<<"[", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lbracket, {line, col}} | acc])
  end

  defp do_tokenize(<<"]", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:rbracket, {line, col}} | acc])
  end

  defp do_tokenize(<<"|", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:pipe_single, {line, col}} | acc])
  end

  # Arithmetic operators
  defp do_tokenize(<<"+", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:plus, {line, col}} | acc])
  end

  defp do_tokenize(<<"-", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:minus, {line, col}} | acc])
  end

  defp do_tokenize(<<"*", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:star, {line, col}} | acc])
  end

  defp do_tokenize(<<"/", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:slash, {line, col}} | acc])
  end

  # Comparison operators (single char, after two-char checks)
  defp do_tokenize(<<"<", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:lt, {line, col}} | acc])
  end

  defp do_tokenize(<<">", rest::binary>>, line, col, acc) do
    do_tokenize(rest, line, col + 1, [{:gt, {line, col}} | acc])
  end

  # Identifiers and keywords
  defp do_tokenize(<<c, _::binary>> = source, line, col, acc) when c in ?a..?z or c == ?_ do
    {name, rest, new_col} = lex_lower_ident(source, col)

    token =
      if name in @keyword_strings do
        keyword = String.to_atom(name)
        {keyword, {line, col}}
      else
        {:ident, {line, col}, name}
      end

    do_tokenize(rest, line, new_col, [token | acc])
  end

  # Upper identifiers (type names, module names)
  defp do_tokenize(<<c, _::binary>> = source, line, col, acc) when c in ?A..?Z do
    {name, rest, new_col} = lex_upper_ident(source, col)
    do_tokenize(rest, line, new_col, [{:upper_ident, {line, col}, name} | acc])
  end

  # Semicolon — common habit from other languages; give a targeted hint
  defp do_tokenize(<<";", _rest::binary>>, line, col, _acc) do
    {:error,
     [
       %Skein.Error{
         code: "E0001",
         severity: :error,
         message: "Unexpected character: ;",
         location: %{file: "unknown", line: line, col: col},
         fix_hint: "Skein does not use semicolons; a statement ends at the end of the line",
         fix_code: ""
       }
     ]}
  end

  # Unknown character
  defp do_tokenize(<<c::utf8, _rest::binary>>, line, col, _acc) do
    {:error,
     [
       %Skein.Error{
         code: "E0001",
         severity: :error,
         message: "Unexpected character: #{<<c::utf8>>}",
         location: %{file: "unknown", line: line, col: col},
         fix_hint: "Remove or replace this character",
         fix_code: ""
       }
     ]}
  end

  # --- String lexing ---

  defp lex_string(<<>>, line, col, _segments) do
    {:error,
     %Skein.Error{
       code: "E0002",
       severity: :error,
       message: "Unterminated string literal",
       location: %{file: "unknown", line: line, col: col},
       fix_hint: "Add a closing double quote",
       fix_code: "\""
     }}
  end

  defp lex_string(<<"\"", rest::binary>>, line, col, segments) do
    {:ok, Enum.reverse(segments), rest, line, col + 1}
  end

  defp lex_string(<<"\\n", rest::binary>>, line, col, segments) do
    lex_string(rest, line, col + 2, add_literal_char(segments, "\n"))
  end

  defp lex_string(<<"\\t", rest::binary>>, line, col, segments) do
    lex_string(rest, line, col + 2, add_literal_char(segments, "\t"))
  end

  defp lex_string(<<"\\\\", rest::binary>>, line, col, segments) do
    lex_string(rest, line, col + 2, add_literal_char(segments, "\\"))
  end

  defp lex_string(<<"\\\"", rest::binary>>, line, col, segments) do
    lex_string(rest, line, col + 2, add_literal_char(segments, "\""))
  end

  defp lex_string(<<"\\$", rest::binary>>, line, col, segments) do
    lex_string(rest, line, col + 2, add_literal_char(segments, "$"))
  end

  defp lex_string(<<"${", rest::binary>>, line, col, segments) do
    case lex_interpolation(rest, line, col + 2) do
      {:ok, interp_tokens, rest, end_line, end_col} ->
        lex_string(rest, end_line, end_col, [{:interpolation, interp_tokens} | segments])

      {:error, _} = error ->
        error
    end
  end

  defp lex_string(<<"\n", rest::binary>>, line, _col, segments) do
    lex_string(rest, line + 1, 1, add_literal_char(segments, "\n"))
  end

  defp lex_string(<<c::utf8, rest::binary>>, line, col, segments) do
    lex_string(rest, line, col + 1, add_literal_char(segments, <<c::utf8>>))
  end

  defp add_literal_char([{:literal, existing} | rest], char) do
    [{:literal, existing <> char} | rest]
  end

  defp add_literal_char(segments, char) do
    [{:literal, char} | segments]
  end

  # Lex a string interpolation expression: everything between ${ and }
  # For Phase 1, supports simple identifiers and dotted access (e.g., name, req.params.id)
  defp lex_interpolation(source, line, col) do
    case lex_interpolation_expr(source, line, col) do
      {:ok, nil, <<"}", _::binary>>, end_line, end_col} ->
        {:error,
         %Skein.Error{
           code: "E0002",
           severity: :error,
           message: "Empty string interpolation: '${}' must name a value to interpolate",
           location: %{file: "unknown", line: end_line, col: end_col},
           fix_hint:
             "Interpolate a binding (e.g. ${name}), or escape the dollar sign as \\${ for literal text",
           fix_code: nil
         }}

      {:ok, tokens, <<"}", rest::binary>>, end_line, end_col} ->
        {:ok, tokens, rest, end_line, end_col + 1}

      {:ok, _tokens, rest, end_line, end_col} ->
        if closing_brace_ahead?(rest) do
          {:error,
           %Skein.Error{
             code: "E0002",
             severity: :error,
             message:
               "Expressions are not allowed in string interpolation; " <>
                 "only an identifier with optional dot access is supported " <>
                 "(e.g. ${name}, ${user.id})",
             location: %{file: "unknown", line: end_line, col: end_col},
             fix_hint:
               "Bind the expression to a variable with 'let' first, " <>
                 "then interpolate the variable",
             fix_code: nil
           }}
        else
          {:error,
           %Skein.Error{
             code: "E0002",
             severity: :error,
             message: "Unterminated string interpolation, expected '}'",
             location: %{file: "unknown", line: end_line, col: end_col},
             fix_hint: "Add a closing '}' after the interpolation expression",
             fix_code: "}"
           }}
        end

      {:error, _} = error ->
        error
    end
  end

  # A '}' later on the same line means the interpolation is closed but
  # contains more than the supported identifier/dot-access form.
  defp closing_brace_ahead?(<<"}", _::binary>>), do: true
  defp closing_brace_ahead?(<<"\"", _::binary>>), do: false
  defp closing_brace_ahead?(<<"\n", _::binary>>), do: false
  defp closing_brace_ahead?(<<_, rest::binary>>), do: closing_brace_ahead?(rest)
  defp closing_brace_ahead?(<<>>), do: false

  # Simple interpolation: just an identifier, possibly with dot access
  defp lex_interpolation_expr(<<c, _::binary>> = source, line, col) when c in ?a..?z or c == ?_ do
    {name, rest, new_col} = lex_lower_ident(source, col)
    token = {:ident, {line, col}, name}
    lex_interpolation_dot(rest, line, new_col, token)
  end

  defp lex_interpolation_expr(<<c, _::binary>> = source, line, col) when c in ?A..?Z do
    {name, rest, new_col} = lex_upper_ident(source, col)
    token = {:upper_ident, {line, col}, name}
    lex_interpolation_dot(rest, line, new_col, token)
  end

  defp lex_interpolation_expr(source, line, col) do
    {:ok, nil, source, line, col}
  end

  defp lex_interpolation_dot(<<".", rest::binary>>, line, col, left_token) do
    case rest do
      <<c, _::binary>> when c in ?a..?z or c == ?_ ->
        {name, rest2, new_col} = lex_lower_ident(rest, col + 1)
        dot_expr = {:field_access, left_token, name}
        lex_interpolation_dot(rest2, line, new_col, dot_expr)

      _ ->
        {:ok, left_token, <<".", rest::binary>>, line, col}
    end
  end

  defp lex_interpolation_dot(rest, line, col, token) do
    {:ok, token, rest, line, col}
  end

  # Normalize string segments: if there's only a single literal with no interpolation,
  # represent it simply. Otherwise, return the segment list.
  defp normalize_string_segments([{:literal, text}]), do: [{:literal, text}]
  defp normalize_string_segments(segments), do: segments

  # --- Number lexing ---

  defp lex_number(source, line, col) do
    {digits, rest, new_col} = lex_digits(source, col)

    case rest do
      <<".", c, _::binary>> when c in ?0..?9 ->
        {frac_digits, rest2, new_col2} =
          lex_digits(<<c, binary_part(rest, 2, byte_size(rest) - 2)::binary>>, new_col + 1)

        text = "#{digits}.#{frac_digits}"

        if String.contains?(text, "_") do
          {:error,
           %Skein.Error{
             code: "E0003",
             severity: :error,
             message:
               "Invalid number literal: underscores are not allowed in float literals (got '#{text}')",
             location: %{file: "unknown", line: line, col: col},
             fix_hint: "Remove the underscores from the float literal",
             fix_code: String.replace(text, "_", "")
           }}
        else
          value = String.to_float(text)
          {{:float, {line, col}, value}, rest2, new_col2}
        end

      _ ->
        clean_digits = String.replace(digits, "_", "")
        value = String.to_integer(clean_digits)
        {{:int, {line, col}, value}, rest, new_col}
    end
  end

  defp lex_digits(source, col) do
    lex_digits(source, col, "")
  end

  defp lex_digits(<<c, rest::binary>>, col, acc) when c in ?0..?9 do
    lex_digits(rest, col + 1, acc <> <<c>>)
  end

  defp lex_digits(<<"_", c, rest::binary>>, col, acc) when c in ?0..?9 do
    lex_digits(<<c, rest::binary>>, col + 1, acc <> "_")
  end

  defp lex_digits(rest, col, acc) do
    {acc, rest, col}
  end

  # --- Identifier lexing ---

  defp lex_lower_ident(source, col) do
    lex_ident_chars(source, col, "")
  end

  defp lex_upper_ident(source, col) do
    lex_ident_chars(source, col, "")
  end

  defp lex_ident_chars(<<c, rest::binary>>, col, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    lex_ident_chars(rest, col + 1, acc <> <<c>>)
  end

  defp lex_ident_chars(rest, col, acc) do
    {acc, rest, col}
  end

  # --- Comment handling ---

  # Skips to end of line, counting the characters consumed so the caller
  # can keep column tracking accurate.
  defp skip_to_eol(<<"\n", _rest::binary>> = source, count), do: {source, count}
  defp skip_to_eol(<<"\r\n", _rest::binary>> = source, count), do: {source, count}
  defp skip_to_eol(<<"\r", _rest::binary>> = source, count), do: {source, count}
  defp skip_to_eol(<<>>, count), do: {<<>>, count}
  defp skip_to_eol(<<_::utf8, rest::binary>>, count), do: skip_to_eol(rest, count + 1)
end
