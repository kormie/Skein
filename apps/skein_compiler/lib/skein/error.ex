defmodule Skein.Error do
  @moduledoc """
  Structured compiler error.

  All errors are JSON-serializable and include machine-readable fix hints
  for LLM-driven code correction loops.
  """

  @derive Jason.Encoder
  defstruct [:code, :severity, :message, :location, :context, :fix_hint, :fix_code]

  @type t :: %__MODULE__{
          code: String.t(),
          severity: :error | :warning,
          message: String.t(),
          location: %{file: String.t(), line: pos_integer(), col: pos_integer()},
          context: String.t() | nil,
          fix_hint: String.t() | nil,
          fix_code: String.t() | nil
        }

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = error) do
    Jason.encode!(error)
  end

  @spec to_json_list([t()]) :: String.t()
  def to_json_list(errors) when is_list(errors) do
    Jason.encode!(%{errors: errors})
  end
end
