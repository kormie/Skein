defmodule Skein.Lsp.HoverProvider do
  @moduledoc """
  Provides hover information and go-to-definition for Skein source.

  Resolves the symbol at a given cursor position by walking the AST
  and matching source locations.
  """

  alias GenLSP.Structures.{
    Hover,
    MarkupContent,
    Position
  }

  @doc """
  Returns hover info for the symbol at the given position, or nil.
  """
  @spec hover(any(), String.t(), Position.t()) :: Hover.t() | nil
  def hover(ast, source, %Position{line: line, character: character}) do
    # LSP positions are 0-indexed; Skein AST is 1-indexed
    target_line = line + 1
    target_col = character + 1

    word = word_at(source, line, character)

    case find_symbol(ast, word, target_line, target_col) do
      nil -> nil
      {kind, info} -> make_hover(kind, info, word)
    end
  end

  @doc """
  Returns `{line, col}` for the definition of the symbol at position, or nil.
  """
  @spec definition(any(), String.t(), Position.t()) :: {pos_integer(), pos_integer()} | nil
  def definition(ast, source, %Position{line: line, character: character}) do
    word = word_at(source, line, character)
    find_definition(ast, word)
  end

  # -- Symbol resolution --

  defp find_symbol(ast, word, _line, _col) when is_binary(word) do
    # Search declarations for matching name
    find_in_declarations(ast, word) || find_builtin(word)
  end

  defp find_symbol(_, _, _, _), do: nil

  defp find_in_declarations(%{__struct__: Skein.AST.Module} = mod, word) do
    find_in_declaration_list(mod.declarations || [], word)
  end

  defp find_in_declarations(%{__struct__: Skein.AST.Agent} = agent, word) do
    cond do
      agent.name == word ->
        {:agent, %{name: agent.name, meta: agent.meta}}

      true ->
        find_in_agent(agent, word)
    end
  end

  defp find_in_declarations(_, _), do: nil

  defp find_in_declaration_list(declarations, word) do
    Enum.find_value(declarations, fn
      %{__struct__: Skein.AST.Fn, name: ^word} = f ->
        {:function, fn_info(f)}

      %{__struct__: Skein.AST.TypeDecl, name: ^word} = t ->
        {:type, %{name: t.name, fields: t.fields, meta: t.meta}}

      %{__struct__: Skein.AST.EnumDecl, name: ^word} = e ->
        {:enum, %{name: e.name, variants: e.variants, meta: e.meta}}

      %{__struct__: Skein.AST.ToolDecl, name: ^word} = t ->
        {:tool, %{name: t.name, description: t.description, meta: t.meta}}

      _ ->
        nil
    end)
  end

  defp find_in_agent(agent, word) do
    # Check functions
    fn_match =
      (agent.fns || [])
      |> Enum.find(fn f -> f.name == word end)

    if fn_match do
      {:function, fn_info(fn_match)}
    else
      # Check state fields
      state_match =
        (agent.state || [])
        |> Enum.find(fn
          %{name: ^word} -> true
          _ -> false
        end)

      if state_match do
        {:field, %{name: state_match.name, type: state_match.type}}
      else
        # Check phase enum
        check_phase_enum(agent.phases, word)
      end
    end
  end

  defp check_phase_enum(%{__struct__: Skein.AST.EnumDecl} = e, word) do
    if e.name == word do
      {:enum, %{name: e.name, variants: e.variants, meta: e.meta}}
    else
      variant =
        (e.variants || [])
        |> Enum.find(fn %{name: name} -> name == word end)

      if variant do
        {:variant, %{name: variant.name, enum: e.name, transitions: variant.transitions}}
      else
        nil
      end
    end
  end

  defp check_phase_enum(_, _), do: nil

  defp find_builtin(word) do
    builtins = %{
      "Int" => "Built-in 64-bit signed integer type",
      "Float" => "Built-in 64-bit IEEE 754 floating point type",
      "String" => "Built-in UTF-8 string type",
      "Bool" => "Built-in boolean type (true | false)",
      "Uuid" => "Built-in UUID type (RFC 4122)",
      "Instant" => "Built-in UTC timestamp type",
      "Duration" => "Built-in duration type (milliseconds)",
      "Email" => "Built-in email address type (validated format)",
      "Url" => "Built-in URL type (validated format)",
      "Option" => "Container type: Some(value) | None",
      "Result" => "Container type: Ok(value) | Err(error)",
      "List" => "Ordered collection type: List<T>",
      "Map" => "Key-value collection type: Map<K, V>",
      "Set" => "Unique collection type: Set<T>"
    }

    case Map.get(builtins, word) do
      nil -> nil
      desc -> {:builtin, %{name: word, description: desc}}
    end
  end

  # -- Definition resolution --

  defp find_definition(%{__struct__: Skein.AST.Module} = mod, word) do
    Enum.find_value(mod.declarations || [], fn
      %{__struct__: Skein.AST.Fn, name: ^word, meta: meta} ->
        {meta[:line] || 1, meta[:col] || 1}

      %{__struct__: Skein.AST.TypeDecl, name: ^word, meta: meta} ->
        {meta[:line] || 1, meta[:col] || 1}

      %{__struct__: Skein.AST.EnumDecl, name: ^word, meta: meta} ->
        {meta[:line] || 1, meta[:col] || 1}

      _ ->
        nil
    end)
  end

  defp find_definition(%{__struct__: Skein.AST.Agent} = agent, word) do
    fn_def =
      (agent.fns || [])
      |> Enum.find(fn f -> f.name == word end)

    case fn_def do
      %{meta: meta} -> {meta[:line] || 1, meta[:col] || 1}
      nil -> nil
    end
  end

  defp find_definition(_, _), do: nil

  # -- Hover formatting --

  defp make_hover(:function, info, _word) do
    params =
      (info.params || [])
      |> Enum.map(fn
        %{name: name, type: type} -> "#{name}: #{format_type(type)}"
        %{name: name} -> name
        _ -> "?"
      end)
      |> Enum.join(", ")

    ret = format_type(info.return_type)

    markdown = """
    ```skein
    fn #{info.name}(#{params}) -> #{ret}
    ```
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(:type, info, _word) do
    fields =
      (info.fields || [])
      |> Enum.map(fn
        %{name: name, type: type} -> "  #{name}: #{format_type(type)}"
        _ -> ""
      end)
      |> Enum.join("\n")

    markdown = """
    ```skein
    type #{info.name} {
    #{fields}
    }
    ```
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(:enum, info, _word) do
    variants =
      (info.variants || [])
      |> Enum.map(fn %{name: name} -> "  #{name}" end)
      |> Enum.join("\n")

    markdown = """
    ```skein
    enum #{info.name} {
    #{variants}
    }
    ```
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(:variant, info, _word) do
    transitions =
      case info.transitions do
        nil -> "[]"
        t -> "[#{Enum.join(t, ", ")}]"
      end

    markdown = """
    ```skein
    #{info.enum}.#{info.name} -> #{transitions}
    ```
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(:agent, info, _word) do
    markdown = """
    ```skein
    agent #{info.name}
    ```
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(:field, info, _word) do
    markdown = """
    ```skein
    #{info.name}: #{format_type(info.type)}
    ```
    State field
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(:builtin, info, _word) do
    markdown = """
    ```skein
    #{info.name}
    ```
    #{info.description}
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(:tool, info, _word) do
    markdown = """
    ```skein
    tool #{info.name}
    ```
    #{info.description || ""}
    """

    %Hover{contents: %MarkupContent{kind: "markdown", value: String.trim(markdown)}}
  end

  defp make_hover(_, _, _), do: nil

  # -- Helpers --

  defp fn_info(f) do
    %{
      name: f.name,
      params: f.params,
      return_type: f.return_type,
      meta: f.meta
    }
  end

  defp format_type(nil), do: "?"
  defp format_type(%{__struct__: Skein.AST.TypeRef, name: name, params: []}), do: name

  defp format_type(%{__struct__: Skein.AST.TypeRef, name: name, params: params}) do
    inner = Enum.map_join(params, ", ", &format_type/1)
    "#{name}<#{inner}>"
  end

  defp format_type(name) when is_binary(name), do: name
  defp format_type(_), do: "?"

  defp word_at(source, line_0, char_0) do
    lines = String.split(source, "\n")

    case Enum.at(lines, line_0) do
      nil ->
        nil

      line_text ->
        # Walk backward and forward from cursor position to find word boundaries
        chars = String.graphemes(line_text)

        start_idx =
          char_0
          |> min(length(chars) - 1)
          |> max(0)
          |> find_word_start(chars)

        end_idx = find_word_end(start_idx, chars)

        if start_idx <= end_idx do
          chars
          |> Enum.slice(start_idx..end_idx)
          |> Enum.join()
        else
          nil
        end
    end
  end

  defp find_word_start(idx, chars) when idx > 0 do
    char = Enum.at(chars, idx - 1)

    if word_char?(char) do
      find_word_start(idx - 1, chars)
    else
      idx
    end
  end

  defp find_word_start(0, chars) do
    case Enum.at(chars, 0) do
      nil -> 0
      c -> if word_char?(c), do: 0, else: 1
    end
  end

  defp find_word_end(idx, chars) when idx < length(chars) do
    char = Enum.at(chars, idx)

    if word_char?(char) do
      find_word_end(idx + 1, chars)
    else
      idx - 1
    end
  end

  defp find_word_end(idx, _chars), do: idx - 1

  defp word_char?(nil), do: false

  defp word_char?(char) do
    Regex.match?(~r/[a-zA-Z0-9_]/, char)
  end
end
