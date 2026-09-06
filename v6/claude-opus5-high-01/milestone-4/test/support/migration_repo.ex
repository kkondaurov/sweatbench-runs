defmodule GroupStay.MigrationRepo do
  @moduledoc """
  A second repo used only by the upgrade test.

  It points at a throwaway database file so the migrations can be replayed from
  an earlier release's schema without touching the sandboxed test database.
  """

  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3
end
