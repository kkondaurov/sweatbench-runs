defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :group_stay, adapter: Ecto.Adapters.SQLite3
  end

  test "an earlier release upgrades booking policies and cash without changing settlements" do
    path = Path.expand("_build/upgrade-#{System.unique_integer([:positive])}.db")
    start_supervised!({UpgradeRepo, database: path, pool_size: 1})

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_260_905_000_000, log: false)

    for {id, booked, plan, status, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 0, 0},
          {"new", "2027-01-01", "flexible", "active", 0, 0},
          {"advance", "2026-12-31", "advance_purchase", "cancelled", 0, 100},
          {"refunded", "2026-12-31", "flexible", "cancelled", 100, 0}
        ] do
      Ecto.Adapters.SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, rooms, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, refunded_cents, retained_cents)
        VALUES (?, 'guest', 'hotel', ?, '2027-03-01', '2027-03-02', ?, ?, 2, '[]', 1000, ?, 100, ?, ?)
        """,
        [id, booked, plan, status, if(status == "active", do: 200, else: 0), refunded, retained]
      )
    end

    Ecto.Migrator.run(UpgradeRepo, migrations, :up, all: true, log: false)
    previous = GroupStay.Repo.put_dynamic_repo(UpgradeRepo)

    try do
      assert GroupStay.Reservations.get("old").policy_version == "flex-14"
      assert GroupStay.Reservations.get("new").policy_version == "flex-30"
      assert GroupStay.Reservations.get("advance").refundable_until == nil
      assert GroupStay.Reservations.get("old").cash_paid_cents == 100
      assert GroupStay.Reservations.get("old").credit_paid_cents == 0

      assert GroupStay.Reservations.ledger() == %{
               cash_held_cents: 200,
               cash_refunded_cents: 100,
               cash_retained_cents: 100,
               cash_converted_to_credit_cents: 0,
               credit_liability_cents: 0
             }

      assert [%{status: "applied", revision: 3, credit_issued_cents: 110}] =
               GroupStay.Reservations.batch([
                 %{
                   "operation_id" => "convert",
                   "type" => "cancel_group",
                   "group_id" => "old",
                   "occurred_on" => "2027-02-15",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 2
                 }
               ])
    after
      GroupStay.Repo.put_dynamic_repo(previous)
    end
  end
end
