defmodule Skein.Runtime.AssertionError do
  @moduledoc """
  Structured assertion failure raised by compiled Skein `assert`
  expressions.

  Carries the comparison operator and both operand values (for
  comparison asserts), the rendered source expression, and the assert's
  source location — so test failures show expected vs actual instead of
  a bare "Assertion failed".
  """

  defexception [:op, :left, :right, :expr, :file, :line]

  @type t :: %__MODULE__{
          op: atom() | nil,
          left: term(),
          right: term(),
          expr: String.t() | nil,
          file: String.t() | nil,
          line: pos_integer() | nil
        }

  @impl true
  def message(%__MODULE__{} = error) do
    header =
      case error.expr do
        nil -> "Assertion failed"
        expr -> "Assertion failed: #{expr}"
      end

    if error.op do
      header <>
        "\n        left:  #{inspect(error.left)}" <>
        "\n        right: #{inspect(error.right)}"
    else
      header
    end
  end

  @doc """
  The assert's source location as `file:line`, or nil when unknown.
  """
  @spec location(t()) :: String.t() | nil
  def location(%__MODULE__{file: file, line: line})
      when is_binary(file) and is_integer(line) do
    "#{file}:#{line}"
  end

  def location(%__MODULE__{}), do: nil
end
