defmodule Skein.Runtime.ValidationError do
  @moduledoc """
  Structured validation failure for the JSON request boundary (`req.json[T]`).

  `req.json[T]` returns `{:error, %ValidationError{}}` when the body is missing
  a required field or violates a field constraint (`@min`/`@max`/`@one_of`). The
  HTTP handler dispatch maps this to a clean **400** (rather than a 500) whether
  it is propagated with `?` or raised with `!` — so callers get a structured
  client error naming exactly which field/constraint failed (skein-testing#25).

  It is an exception so the `!` unwrap (`erlang:error/1`) raises it as a
  first-class exception the dispatch can `rescue`.
  """

  defexception [:message, :violations, status: 400]

  @type t :: %__MODULE__{
          message: String.t(),
          violations: [String.t()],
          status: non_neg_integer()
        }

  @doc "Builds a validation error from a list of human-readable violations."
  @spec new([String.t()]) :: t()
  def new(violations) when is_list(violations) do
    %__MODULE__{
      message: Enum.join(violations, "; "),
      violations: violations,
      status: 400
    }
  end
end
