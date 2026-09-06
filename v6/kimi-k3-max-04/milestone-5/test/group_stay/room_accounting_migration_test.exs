defmodule GroupStay.RoomAccountingMigrationTest do
  @moduledoc """
  Verifies that a database created before room accounting upgrades by running
  the new release's migrations: legacy funding comes forward as one
  unattributed senior block, durable-record funding is attributed in commit
  order, and aggregate balances stay unchanged.
  """
  use GroupStay.DataCase, async: false

  @fixture Path.expand("../../priv/test_fixtures/room_accounting_migration.exs", __DIR__)

  test "an earlier-release database upgrades through the new migrations" do
    path = scratch_path()

    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-start", @fixture],
        env: [
          {"MIX_ENV", "dev"},
          {"GROUP_STAY_DATABASE_PATH", path},
          {"PORT", free_port()}
        ],
        stderr_to_stdout: true,
        cd: Path.expand("../../", __DIR__)
      )

    assert status == 0, "migration fixture failed: #{output}"
    assert output =~ "migration-fixture-ok"

    for suffix <- ["", "-shm", "-wal"], do: File.rm(path <> suffix)
  end

  # The fixture starts the application's endpoint; give it a port nobody uses.
  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    Integer.to_string(port)
  end

  defp scratch_path do
    Path.join(
      System.tmp_dir!(),
      "group-stay-migration-test-#{System.unique_integer([:positive])}.db"
    )
  end
end
