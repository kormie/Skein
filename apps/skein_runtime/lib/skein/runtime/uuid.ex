defmodule Skein.Runtime.Uuid do
  @moduledoc """
  The `uuid.new()` effect (#261).

  UUID generation is nondeterministic, so it's a capability-gated effect, not
  ambient stdlib: `uuid.new()` requires `capability uuid`. The value is resolved
  by `Skein.Runtime.Nondeterminism` (scenario `implement` provider → replay →
  live).

  The pure operations (`Uuid.parse`, `Uuid.to_string`) remain stdlib.
  Compiled Skein code lowers `uuid.new()` to `Skein.Runtime.Uuid.new(capabilities)`.
  """

  alias Skein.Runtime.Capability
  alias Skein.Runtime.Nondeterminism

  @doc """
  Produces a new UUID. Requires `capability uuid`.

  Returns the UUID string directly (generation cannot fail). A missing
  capability raises — it is already a compile-time error (E0012); the runtime
  check is defense-in-depth.
  """
  @spec new([map()]) :: binary()
  def new(capabilities) when is_list(capabilities) do
    case Capability.check_scoped("uuid", nil, capabilities) do
      :ok -> Nondeterminism.uuid()
      {:error, reason} -> raise RuntimeError, reason
    end
  end
end
