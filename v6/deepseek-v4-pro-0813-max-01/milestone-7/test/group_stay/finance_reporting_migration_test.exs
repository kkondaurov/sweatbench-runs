defmodule GroupStay.FinanceReportingMigrationTest do
  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  alias GroupStay.FinanceReportingMigrationTest.LegacyRepo

  @migrations "priv/repo/migrations"

  # Migrations released with this change.
  @to 20_260_830_000_000
  # The deposit-transfers release that preceded it.
  @pre 20_260_829_000_000

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

  test "a database built by the earlier release upgrades and backfills settlement attribution" do
    database =
      Path.join(
        System.tmp_dir!(),
        "group_stay_finance_reporting_#{System.unique_integer([:positive])}.db"
      )

    File.rm(database)

    start_supervised!({LegacyRepo, database: database, busy_timeout: 30_000})
    on_exit(fn -> File.rm(database) end)

    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: @pre)

    query!("""
    INSERT INTO groups (id, group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
                        rate_plan, status, revision, deposit_paid_cents, refunded_cents,
                        retained_cents, policy_version, cash_paid_cents, credit_paid_cents,
                        cash_converted_to_credit_cents, cash_reduced_cents,
                        cash_charged_back_cents, inserted_at, updated_at)
    VALUES
      ('a1111111-1111-1111-1111-111111111111', 'settled-group', 'g-1', 'p-old',
       '2026-10-03', '2026-12-10', '2026-12-13', 'flexible', 'cancelled', 4, 0, 800, 200,
       'flex-14', 0, 0, 500, 0, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    query!("""
    INSERT INTO payment_dispositions (id, group_id, payment_operation_id, recorded_cents,
                                      refunded_cents, retained_cents, converted_cents,
                                      reduced_cents, charged_back_cents,
                                      participated_in_transfer, inserted_at, updated_at)
    VALUES
      ('d1111111-1111-1111-1111-111111111111',
       'a1111111-1111-1111-1111-111111111111', 'old-pay-1', 1000,
       800, 200, 500, 0, 0, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00'),
      ('d2222222-2222-2222-2222-222222222222',
       'a1111111-1111-1111-1111-111111111111', 'old-pay-2', 2000,
       0, 0, 0, 0, 0, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    Ecto.Migrator.run(LegacyRepo, @migrations, :up, to: @to)

    tables =
      query!("""
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name IN (
        'finance_reporting', 'finance_movements', 'finance_lot_events',
        'payment_group_settlements')
      ORDER BY name
      """).rows

    assert tables == [
             ["finance_lot_events"],
             ["finance_movements"],
             ["finance_reporting"],
             ["payment_group_settlements"]
           ]

    # Payments with settled portions were attributed to the group recorded on
    # their disposition; untouched payments received no row.
    assert query!("""
           SELECT payment_operation_id, group_id, refunded_cents, retained_cents,
                  converted_cents
           FROM payment_group_settlements ORDER BY payment_operation_id
           """).rows == [
             ["old-pay-1", "a1111111-1111-1111-1111-111111111111", 800, 200, 500]
           ]

    assert query!("SELECT COUNT(*) FROM finance_reporting").rows == [[0]]

    # The original settlement data is untouched.
    assert query!("""
           SELECT COUNT(*) FROM payment_dispositions
           WHERE refunded_cents > 0 OR retained_cents > 0 OR converted_cents > 0
           """).rows == [[1]]
  end
end
