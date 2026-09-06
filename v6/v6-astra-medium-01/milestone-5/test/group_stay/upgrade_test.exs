defmodule GroupStay.UpgradeTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Group, Repo, Reservations}

  test "an earlier database upgrades policies and cash without changing prior settlements" do
    directory = Path.expand("../../tmp", __DIR__)
    File.mkdir_p!(directory)
    database = Path.join(directory, "upgrade-#{System.unique_integer([:positive])}.db")

    {:ok, pid} =
      Repo.start_link(
        name: nil,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous = Repo.put_dynamic_repo(pid)

    try do
      migrations = Application.app_dir(:group_stay, "priv/repo/migrations")

      assert Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_000, log: false) == [
               20_260_905_000_000
             ]

      for {id, booked, plan, status, refund, retain} <- [
            {"old", "2026-12-31", "flexible", "active", 0, 0},
            {"new", "2027-01-01", "flexible", "active", 0, 0},
            {"advance", "2026-12-31", "advance_purchase", "active", 0, 0},
            {"refunded", "2026-12-31", "flexible", "cancelled", 100, 0},
            {"retained", "2026-12-31", "advance_purchase", "cancelled", 0, 100}
          ] do
        Repo.insert_all("groups", [
          %{
            group_id: id,
            guest_id: "guest",
            property_id: "hotel",
            booked_on: booked,
            arrival_on: "2027-06-01",
            departure_on: "2027-06-02",
            rate_plan: plan,
            status: status,
            rooms: Jason.encode!([%{room_id: "room", nightly_rate_cents: 10000}]),
            revision: 7,
            lodging_total_cents: 10000,
            deposit_due_cents: 2000,
            deposit_paid_cents: 100,
            refunded_cents: refund,
            retained_cents: retain
          }
        ])
      end

      assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
               20_260_905_000_001,
               20_260_905_000_002,
               20_260_905_000_003,
               20_260_905_000_004
             ]

      assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []

      assert Repo.aggregate(GroupStay.Operation, :count) == 0

      for {id, policy, cutoff} <- [
            {"old", "flex-14", ~D[2027-05-18]},
            {"new", "flex-30", ~D[2027-05-02]},
            {"advance", "advance-nonrefundable", nil},
            {"refunded", "flex-14", ~D[2027-05-18]},
            {"retained", "advance-nonrefundable", nil}
          ] do
        group = Reservations.get_group(id)
        assert group.policy_version == policy
        assert group.refundable_until == cutoff
        assert group.cash_paid_cents == if(group.status == "active", do: 100, else: 0)
        assert group.credit_paid_cents == 0
        assert group.deposit_paid_cents == if(group.status == "active", do: 100, else: 0)
        assert group.revision == 7
      end

      assert Reservations.ledger(~D[2027-05-02]) == %{
               cash_held_cents: 300,
               cash_refunded_cents: 100,
               cash_retained_cents: 100,
               cash_converted_to_credit_cents: 0,
               credit_liability_cents: 0,
               cash_reduced_cents: 0,
               cash_charged_back_cents: 0,
               credit_shortfall_cents: 0
             }

      assert [%{revision: 8, credit_issued_cents: 110}] =
               Reservations.batch([
                 %{
                   "operation_id" => "upgraded-cancel",
                   "group_id" => "old",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-05-18",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 7
                 }
               ])

      assert Repo.get!(Group, "old").status == "cancelled"
      assert Reservations.guest_credit("guest", ~D[2027-05-18]).available_cents == 110
      before_transfer = Reservations.ledger(~D[2027-05-18])

      assert [%{source_revision: 8, destination_revision: 8}] =
               Reservations.batch([
                 %{
                   "operation_id" => "legacy-transfer",
                   "type" => "transfer_deposit",
                   "occurred_on" => "2027-05-18",
                   "source_group_id" => "new",
                   "destination_group_id" => "advance",
                   "amount_cents" => 100
                 }
               ])

      assert Reservations.ledger(~D[2027-05-18]) == before_transfer
      assert Reservations.get_group("new").cash_paid_cents == 0
      assert Reservations.get_group("advance").cash_paid_cents == 200
      assert {:error, "operation_not_found"} = Reservations.get_payment("legacy-transfer-payment")
    after
      Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
      # SQLite may remove its WAL sidecars during shutdown. Keep the shared temp
      # directory and tolerate sidecars already removed by the connection.
      for path <- [database, database <> "-wal", database <> "-shm"] do
        assert File.rm(path) in [:ok, {:error, :enoent}]
      end
    end
  end
end
