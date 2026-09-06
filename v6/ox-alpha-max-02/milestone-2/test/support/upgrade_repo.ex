defmodule GroupStay.UpgradeRepo do
  @moduledoc """
  A standalone repo started against throwaway databases so tests can exercise
  real migrations, including upgrading a database created by an earlier
  release, without touching the application's own repository.
  """

  use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
end
