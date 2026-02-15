defmodule Skein.Runtime.Llm.Response do
  @moduledoc """
  Normalized LLM response. Provider backends translate their native
  responses into this struct. Skein code never sees provider-specific formats.
  """

  alias __MODULE__.Usage

  defstruct [
    :text,
    :usage,
    :model,
    :stop_reason,
    :raw
  ]

  @type stop_reason :: :end | :max_tokens | :content_filtered | :tool_use

  @type t :: %__MODULE__{
          text: String.t() | nil,
          usage: Usage.t() | nil,
          model: String.t() | nil,
          stop_reason: stop_reason() | nil,
          raw: map() | nil
        }

  @doc """
  Truncates a string to `max_length` characters, appending "..." if truncated.
  Returns nil for nil input.
  """
  @spec truncate(String.t() | nil, pos_integer()) :: String.t() | nil
  def truncate(nil, _max_length), do: nil

  def truncate(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  defmodule Usage do
    @moduledoc """
    Normalized token usage counts.
    """

    defstruct input_tokens: 0, output_tokens: 0

    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer()
          }
  end
end
