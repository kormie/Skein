defmodule Skein.Runtime.Instant do
  @moduledoc """
  The `instant.now()` effect (#261).

  Reading the wall clock is nondeterministic, so it's a capability-gated effect,
  not ambient stdlib: `instant.now()` requires `capability instant`. The value is
  resolved by `Skein.Runtime.Nondeterminism` (scenario `implement` provider →
  replay → live).

  (The capability is `instant`, not `clock` — "clock" is the timer/scheduling
  concept, which Skein already exposes as the `timer` effect.)

  The pure operations (`Instant.parse`, `Instant.add`, `Instant.diff`, ...)
  remain stdlib. Compiled Skein code lowers `instant.now()` to
  `Skein.Runtime.Instant.now(capabilities)`.
  """

  alias Skein.Runtime.Capability
  alias Skein.Runtime.Nondeterminism

  @doc """
  Produces the current instant. Requires `capability instant`.

  Returns the instant string directly (reading the clock cannot fail). A missing
  capability raises — it is already a compile-time error (E0012); the runtime
  check is defense-in-depth.
  """
  @spec now([map()]) :: binary()
  def now(capabilities) when is_list(capabilities) do
    case Capability.check_scoped("instant", nil, capabilities) do
      :ok -> Nondeterminism.instant()
      {:error, reason} -> raise RuntimeError, reason
    end
  end
end
