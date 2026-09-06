defmodule GroupStay.MigrationTestRepo do
  @moduledoc """
  A throwaway repository used to exercise the release migrations against a
  database created by an earlier release.
  """

  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3
end
