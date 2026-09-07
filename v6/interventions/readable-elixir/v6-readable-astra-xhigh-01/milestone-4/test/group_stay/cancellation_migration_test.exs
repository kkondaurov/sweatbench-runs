defmodule GroupStay.CancellationMigrationTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Finance, Repo, Reservations}

  @previous_version 20_260_907_000_000

  test "upgrades an earlier release using original booking dates and preserves its accounting" do
    directory = Path.expand("tmp/upgrade-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "legacy.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      Ecto.Migrator.run(Repo, :up, to: @previous_version, log: false)
      seed_legacy_groups()
      cash_before = Repo.query!("SELECT * FROM cash_entries ORDER BY id").rows

      rooms_before =
        Repo.query!(
          "SELECT id, group_id, room_id, position, nightly_rate_cents FROM rooms ORDER BY id"
        ).rows

      assert [20_260_907_010_000, 20_260_907_020_000, 20_260_907_030_000] =
               Ecto.Migrator.run(Repo, :up, all: true, log: false)

      assert Repo.aggregate(GroupStay.Operations.Record, :count) == 0

      for {id, version, cash, revision} <- [
            {"legacy", "flex-14", 100, 4},
            {"newer", "flex-30", 200, 2},
            {"advance", "advance-nonrefundable", 300, 2},
            {"cancelled", "flex-14", 0, 3}
          ] do
        group = Reservations.get_group(id)
        assert group.policy_version == version
        assert group.cash_paid_cents == cash
        assert group.deposit_paid_cents == cash
        assert group.credit_paid_cents == 0
        assert group.revision == revision
        assert Enum.map(group.rooms, & &1.room_id) == ["room-b", "room-a"]
      end

      assert Repo.query!("SELECT * FROM cash_entries ORDER BY id").rows == cash_before

      assert Repo.query!(
               "SELECT id, group_id, room_id, position, nightly_rate_cents FROM rooms ORDER BY id"
             ).rows == rooms_before

      assert Finance.totals() == %{
               cash_held_cents: 600,
               cash_refunded_cents: 400,
               cash_retained_cents: 0,
               cash_converted_to_credit_cents: 0,
               cash_reduced_cents: 0,
               cash_charged_back_cents: 0,
               credit_shortfall_cents: 0,
               credit_liability_cents: 0
             }

      assert [
               %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2028-02-16",
                 "revision" => 5
               }
             ] =
               Reservations.apply_batch([
                 operation("reschedule_group", %{
                   "group_id" => "legacy",
                   "occurred_on" => "2027-12-01",
                   "new_arrival_on" => "2028-03-01",
                   "expected_revision" => 4
                 })
               ])

      # Both cancellations are on the old policy's boundary. The newer booking
      # must already be non-refundable, even though it predates this release.
      assert [%{"refunded_cents" => 100}, %{"retained_cents" => 200}] =
               Reservations.apply_batch([
                 operation("cancel_group", %{
                   "group_id" => "legacy",
                   "occurred_on" => "2028-02-16"
                 }),
                 operation("cancel_group", %{"group_id" => "newer", "occurred_on" => "2028-02-16"})
               ])

      assert Finance.totals().cash_held_cents == 300
      assert Finance.totals().cash_refunded_cents == 500
      assert Finance.totals().cash_retained_cents == 200
      group = Reservations.get_group("legacy")
      assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
      assert Reservations.get_group("legacy") == group
    after
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
      Repo.put_dynamic_repo(previous_repo)
      stop_supervised!(Repo)
    end
  end

  defp seed_legacy_groups do
    for {id, booked_on, plan, status, paid, revision} <- [
          {"legacy", "2026-12-31", "flexible", "active", 100, 4},
          {"newer", "2027-01-01", "flexible", "active", 200, 2},
          {"advance", "2026-12-31", "advance_purchase", "active", 300, 2},
          {"cancelled", "2026-12-31", "flexible", "cancelled", 0, 3}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
          cancelled_on, inserted_at, updated_at)
        VALUES (?, 'guest-22', 'ams-canal', ?, '2028-03-01', '2028-03-04', ?, ?, ?, 97500, ?, ?, ?,
          '2027-01-01T00:00:00.000000', '2027-02-01T00:00:00.000000')
        """,
        [
          id,
          booked_on,
          plan,
          status,
          revision,
          if(status == "active", do: 19500, else: 0),
          paid,
          if(status == "cancelled", do: "2027-01-01", else: nil)
        ]
      )

      for {room_id, position, rate} <- [{"room-b", 0, 15000}, {"room-a", 1, 17500}] do
        Repo.query!(
          "INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents) VALUES (?, ?, ?, ?)",
          [id, room_id, position, rate]
        )
      end

      entries =
        if status == "active", do: [{"payment", paid}], else: [{"payment", 400}, {"refund", 400}]

      for {kind, amount} <- entries do
        Repo.query!(
          """
          INSERT INTO cash_entries (group_id, operation_id, occurred_on, kind, amount_cents, inserted_at)
          VALUES (?, ?, '2027-01-01', ?, ?, '2027-01-01T00:00:00.000000')
          """,
          [id, "#{id}-#{kind}", kind, amount]
        )
      end
    end
  end
end
