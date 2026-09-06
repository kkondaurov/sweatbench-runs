defmodule GroupStay.RequestSevenMigrationRepo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3
end

defmodule GroupStay.RequestSevenMigrationTest do
  use ExUnit.Case, async: false

  alias GroupStay.RequestSevenMigrationRepo, as: Repo

  @migrations Path.expand("../../priv/repo/migrations", __DIR__)
  @request_six 20_260_829_000_005

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "group_stay_request_seven_#{System.unique_integer([:positive])}.db"
      )

    :ok = Ecto.Adapters.SQLite3.storage_up(database: database)
    start_supervised!({Repo, database: database, pool_size: 1})
    Ecto.Migrator.run(Repo, @migrations, :up, to: @request_six)

    on_exit(fn ->
      File.rm(database)
      File.rm("#{database}-shm")
      File.rm("#{database}-wal")
    end)

    :ok
  end

  test "adds close storage and defaults existing finance records to ordinary movements" do
    Repo.query!("""
    INSERT INTO finance_reporting_starts (id, starts_on, opening_credit_liability_cents, inserted_at, updated_at)
    VALUES (1, '2027-01-10', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """)

    Repo.query!("""
    INSERT INTO finance_postings (
      reporting_start_id, posting_on, kind, amount_cents, inserted_at, updated_at
    )
    VALUES (1, '2027-01-10', 'issued', 10, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """)

    Repo.query!("""
    INSERT INTO credit_lots (
      guest_id, source_operation_id, remaining_cents, expires_on, unrecovered_clawback_cents,
      inserted_at, updated_at
    )
    VALUES ('guest', 'credit-source', 10, '2027-01-11', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """)

    Repo.query!("""
    INSERT INTO finance_credit_expiry_schedules (
      reporting_start_id, credit_lot_id, expires_on, amount_cents, inserted_at, updated_at
    )
    VALUES (1, 1, '2027-01-11', 10, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    """)

    Ecto.Migrator.run(Repo, @migrations, :up, all: true)

    assert %{rows: [[0]]} =
             Repo.query!("SELECT late_adjustment FROM finance_postings")

    assert %{rows: [[10, 0]]} =
             Repo.query!(
               "SELECT reported_amount_cents, late_adjustment FROM finance_credit_expiry_schedules"
             )

    assert %{rows: [["finance_closed_daily_reports"], ["finance_period_closes"]]} =
             Repo.query!("""
             SELECT name
             FROM sqlite_master
             WHERE type = 'table' AND name IN ('finance_closed_daily_reports', 'finance_period_closes')
             ORDER BY name
             """)
  end
end
