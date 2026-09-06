defmodule GroupStay.PeriodCloseMigrationTest do
  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  alias GroupStay.PeriodCloseMigrationTest.LegacyRepo

  @migrations "priv/repo/migrations"

  # The period-close release.
  @to 20_260_831_000_000
  # The finance-reporting release that preceded it.
  @pre 20_260_830_000_000

  defp query!(sql), do: Ecto.Adapters.SQL.query!(LegacyRepo, sql, [])

  setup do
    for {module, _path} <- :code.all_loaded() do
      if Atom.to_string(module) =~ "GroupStay.Repo.Migrations" do
        :code.purge(module)
        :code.delete(module)
      end
    end

    :ok
  end

  test "a database built by the earlier release upgrades with the close tables and is_late" do
    database =
      Path.join(
        System.tmp_dir!(),
        "group_stay_period_close_#{System.unique_integer([:positive])}.db"
      )

    File.rm(database)

    start_supervised!({LegacyRepo, database: database, busy_timeout: 30_000})
    on_exit(fn -> File.rm(database) end)

    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: @pre)

    query!("""
    INSERT INTO finance_movements
      (posting_date, kind, property_id, amount_cents, inserted_at, updated_at)
    VALUES ('2027-01-10', 'received', 'ams-canal', 1000,
            '2027-01-10 00:00:00', '2027-01-10 00:00:00')
    """)

    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: @to)

    tables =
      query!("""
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name IN ('finance_period_closes', 'finance_report_snapshots')
      ORDER BY name
      """).rows

    assert tables == [["finance_period_closes"], ["finance_report_snapshots"]]

    # Pre-existing movement rows gained the flag and default to ordinary.
    assert query!(
             "SELECT posting_date, kind, property_id, amount_cents, is_late FROM finance_movements"
           ).rows ==
             [["2027-01-10", "received", "ams-canal", 1000, 0]]

    now = "2027-01-10 00:00:00"

    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO finance_period_closes (period_end_on, inserted_at, updated_at)
      VALUES ('2027-01-31', '#{now}', '#{now}')
      """,
      []
    )

    assert query!("SELECT period_end_on FROM finance_period_closes").rows == [["2027-01-31"]]
  end
end
