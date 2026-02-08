defmodule Skein.Runtime.Repo do
  @moduledoc """
  Ecto Repo for Skein's storage backend.

  Uses SQLite for local development. Production deployments can configure
  Postgres by setting `:skein_runtime, Skein.Runtime.Repo` in config.

  The Repo is started as part of the runtime supervision tree when
  Ecto-backed storage is enabled.
  """

  use Ecto.Repo,
    otp_app: :skein_runtime,
    adapter: Ecto.Adapters.SQLite3
end
