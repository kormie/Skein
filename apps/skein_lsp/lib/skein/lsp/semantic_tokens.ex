defmodule Skein.Lsp.SemanticTokens do
  @moduledoc """
  Provides semantic token highlighting for Skein source files.

  Encodes tokens as relative positions per the LSP semantic tokens spec.
  Each token is encoded as 5 integers:
  [deltaLine, deltaStart, length, tokenType, tokenModifiers]
  """

  # Token type indices matching the legend in Server
  @token_types %{
    namespace: 0,
    type: 1,
    class: 2,
    enum: 3,
    interface: 4,
    struct: 5,
    type_parameter: 6,
    parameter: 7,
    variable: 8,
    property: 9,
    enum_member: 10,
    event: 11,
    function: 12,
    method: 13,
    macro: 14,
    keyword: 15,
    modifier: 16,
    comment: 17,
    string: 18,
    number: 19,
    regexp: 20,
    operator: 21,
    decorator: 22
  }

  # Token modifier bitmask
  @token_modifiers %{
    declaration: 1,
    definition: 2,
    readonly: 4,
    static: 8,
    deprecated: 16,
    abstract: 32,
    async: 64,
    modification: 128,
    documentation: 256,
    default_library: 512
  }

  @doc """
  Encodes the source into a flat list of semantic token data.

  Returns the LSP-standard encoded list of integers.
  """
  @spec encode(String.t()) :: [integer()]
  def encode(source) do
    case Skein.Lexer.tokenize(source) do
      {:ok, tokens} ->
        tokens
        |> classify_tokens()
        |> encode_relative()

      {:error, _} ->
        []
    end
  end

  # Classify each token into {line, col, length, type_index, modifier_mask}
  defp classify_tokens(tokens) do
    tokens
    |> Enum.flat_map(&classify_token/1)
    |> Enum.sort_by(fn {line, col, _, _, _} -> {line, col} end)
  end

  defp classify_token({:eof, _}), do: []

  # Keywords
  defp classify_token({kw, {line, col}})
       when kw in [
              :module,
              :fn,
              :let,
              :match,
              :type,
              :enum,
              :handler,
              :agent,
              :tool,
              :capability,
              :supervisor,
              :test,
              :scenario,
              :golden,
              :on,
              :emit,
              :transition,
              :stop,
              :suspend,
              :resume,
              :replay,
              :implement,
              :input,
              :output,
              :errors,
              :policy,
              :description,
              :state,
              :phase,
              :strategy,
              :child,
              :pub,
              :extern,
              :import,
              :from,
              :given,
              :expect,
              :assert,
              :return
            ] do
    name = Atom.to_string(kw)
    [{line, col, String.length(name), @token_types[:keyword], 0}]
  end

  # Booleans
  defp classify_token({:true, {line, col}}) do
    [{line, col, 4, @token_types[:keyword], 0}]
  end

  defp classify_token({:false, {line, col}}) do
    [{line, col, 5, @token_types[:keyword], 0}]
  end

  # Identifiers
  defp classify_token({:ident, {line, col}, name}) do
    [{line, col, String.length(name), @token_types[:variable], 0}]
  end

  # Upper identifiers (types, enum variants)
  defp classify_token({:upper_ident, {line, col}, name}) do
    type_idx =
      if name in ~w(Int Float String Bool Uuid Instant Duration Email Url Option Result List Map Set) do
        @token_types[:type]
      else
        @token_types[:class]
      end

    [{line, col, String.length(name), type_idx, 0}]
  end

  # Numbers
  defp classify_token({:int, {line, col}, value}) do
    [{line, col, digit_length(value), @token_types[:number], 0}]
  end

  defp classify_token({:float, {line, col}, _value}) do
    # Approximate float length
    [{line, col, 1, @token_types[:number], 0}]
  end

  # Strings
  defp classify_token({:string, {line, col}, _segments}) do
    # We mark just the opening position; full string highlighting is handled by TextMate
    [{line, col, 1, @token_types[:string], 0}]
  end

  # HTTP methods
  defp classify_token({:http_method, {line, col}, method}) do
    [{line, col, String.length(method), @token_types[:keyword], @token_modifiers[:static]}]
  end

  # Operators
  defp classify_token({op, {line, col}})
       when op in [
              :arrow,
              :fat_arrow,
              :pipe,
              :eq,
              :double_eq,
              :not_eq,
              :lt,
              :gt,
              :lt_eq,
              :gt_eq,
              :and_op,
              :or_op,
              :plus,
              :minus,
              :star,
              :slash,
              :bang,
              :question
            ] do
    len = operator_length(op)
    [{line, col, len, @token_types[:operator], 0}]
  end

  # Delimiters and punctuation — skip for semantic tokens
  defp classify_token({delim, {_line, _col}})
       when delim in [
              :lbrace,
              :rbrace,
              :lparen,
              :rparen,
              :lbracket,
              :rbracket,
              :colon,
              :comma,
              :dot
            ] do
    []
  end

  # Catch-all for unrecognized tokens
  defp classify_token(_), do: []

  # Encode absolute positions to LSP-standard relative positions
  defp encode_relative(tokens) do
    {encoded, _} =
      Enum.reduce(tokens, {[], {0, 0}}, fn {line, col, len, type, mods},
                                            {acc, {prev_line, prev_col}} ->
        # LSP lines/cols are 0-indexed; Skein tokens are 1-indexed
        lsp_line = line - 1
        lsp_col = col - 1

        delta_line = lsp_line - prev_line

        delta_start =
          if delta_line == 0 do
            lsp_col - prev_col
          else
            lsp_col
          end

        entry = [delta_line, delta_start, len, type, mods]
        {[entry | acc], {lsp_line, lsp_col}}
      end)

    encoded
    |> Enum.reverse()
    |> List.flatten()
  end

  defp operator_length(:arrow), do: 2
  defp operator_length(:fat_arrow), do: 2
  defp operator_length(:pipe), do: 2
  defp operator_length(:double_eq), do: 2
  defp operator_length(:not_eq), do: 2
  defp operator_length(:lt_eq), do: 2
  defp operator_length(:gt_eq), do: 2
  defp operator_length(:and_op), do: 2
  defp operator_length(:or_op), do: 2
  defp operator_length(_), do: 1

  defp digit_length(n) when is_integer(n) and n >= 0 do
    n |> Integer.to_string() |> String.length()
  end

  defp digit_length(n) when is_integer(n) do
    n |> Integer.to_string() |> String.length()
  end

  defp digit_length(_), do: 1
end
