defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Credits, Finance, Operations, Payments, Repo, Reservations}
  alias GroupStay.Credits.{Allocation, Entitlement, Lot}
  alias GroupStay.Finance.{CashAllocation, CashEntry}
  alias GroupStay.Operations.Record
  alias GroupStay.Reservations.{Group, Room}

  test "upgrades mixed legacy and durable funding in senior and commit order without changing balances" do
    directory = Path.expand("tmp/room-upgrade-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: Path.join(directory, "old.db"),
         pool: DBConnection.ConnectionPool,
         pool_size: 1}
      )

    previous = Repo.put_dynamic_repo(repo)

    try do
      Ecto.Migrator.run(Repo, :up, to: 20_260_907_020_000, log: false)
      seed_previous_release()
      audit_before = Repo.query!("SELECT * FROM operation_records ORDER BY id").rows
      cash_before = Repo.query!("SELECT * FROM cash_entries ORDER BY id").rows
      lots_before = lot_balances()
      credit_before = credit_allocations()

      group_before =
        Repo.query!(
          "SELECT group_id, revision, cash_paid_cents, credit_paid_cents, deposit_paid_cents, deposit_due_cents FROM groups ORDER BY group_id"
        ).rows

      assert [20_260_907_030_000, 20_260_907_040_000] =
               Ecto.Migrator.run(Repo, :up, all: true, log: false)

      assert Repo.query!("SELECT * FROM operation_records ORDER BY id").rows == audit_before
      assert Repo.query!("SELECT * FROM cash_entries ORDER BY id").rows == cash_before
      assert lot_balances() == lots_before
      assert credit_allocations() == credit_before

      assert Repo.query!(
               "SELECT group_id, revision, cash_paid_cents, credit_paid_cents, deposit_paid_cents, deposit_due_cents FROM groups ORDER BY group_id"
             ).rows == group_before

      group = Reservations.get_group("main")

      assert Enum.map(group.rooms, &{&1.room_id, &1.cash_paid_cents, &1.credit_paid_cents}) ==
               [{"z", 30, 20}, {"a", 15, 35}, {"m", 50, 0}, {"b", 30, 0}]

      assert group.revision == 6
      assert group.lodging_total_cents == 1000

      assert Finance.totals(~D[2026-10-03]) == %{
               cash_held_cents: 125,
               cash_refunded_cents: 0,
               cash_retained_cents: 0,
               cash_converted_to_credit_cents: 200,
               cash_reduced_cents: 0,
               cash_charged_back_cents: 0,
               credit_liability_cents: 220,
               credit_shortfall_cents: 0
             }

      assert Credits.balance("guest-22", ~D[2026-10-03]).available_cents == 165
      assert {:error, "operation_not_found"} = Payments.statement("legacy-cash")
      assert {:ok, %{recorded_cents: 95, held_cents: 95}} = Payments.statement("a-cash")

      assert {:ok, %{recorded_cents: 5, converted_to_credit_cents: 5}} =
               Payments.statement("source-payment")

      assert {:error, "payment_not_reconcilable"} = Payments.statement("z-credit")
      assert Enum.all?(Reservations.get_group("source-a").rooms, &(&1.status == :cancelled))
      assert Reservations.get_group("source-a").lodging_total_cents == 0

      # Credit consumption order survives splitting into rooms. Legacy lot B
      # preceded A even though A expires first; durable credit followed both.
      assert Repo.query!(
               """
               SELECT credit_lot_id, amount_cents FROM credit_allocations
               WHERE room_id = ? ORDER BY id
               """,
               [hd(group.rooms).id]
             ).rows == [[2, 15], [1, 5]]

      verify_legacy_transfer_order()

      before = snapshot()
      assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
      assert snapshot() == before

      assert [%{"cancelled_room_ids" => ["z", "a"], "refunded_cents" => 45, "revision" => 7}] =
               Operations.apply_batch([
                 operation("cancel_rooms", %{
                   "group_id" => "main",
                   "room_ids" => ["a", "z"],
                   "expected_revision" => 6
                 })
               ])

      assert Credits.balance("guest-22", ~D[2026-10-03]).available_cents == 220
      assert {:ok, %{held_cents: 80, refunded_cents: 15}} = Payments.statement("a-cash")

      assert [
               %{"revision" => 8},
               %{"charged_back_cents" => 65, "revision" => 9},
               %{"charged_back_cents" => 5, "revision" => 5}
             ] =
               Operations.apply_batch([
                 correction("reduce_cash_payment", "a-cash", %{"amount_cents" => 30}),
                 correction("charge_back_payment", "a-cash"),
                 correction("charge_back_payment", "source-payment")
               ])

      assert {:ok,
              %{
                recorded_cents: 95,
                reduced_cents: 30,
                charged_back_cents: 65,
                held_cents: 0,
                refunded_cents: 0
              }} = Payments.statement("a-cash")

      # The unattributed 95 cents are senior: their rounded entitlement is 105,
      # leaving exactly 5 cents for the durable source payment in the 110-cent lot.
      assert Finance.totals(~D[2026-10-03]) == %{
               cash_held_cents: 0,
               cash_refunded_cents: 30,
               cash_retained_cents: 0,
               cash_converted_to_credit_cents: 195,
               cash_reduced_cents: 30,
               cash_charged_back_cents: 70,
               credit_liability_cents: 215,
               credit_shortfall_cents: 0
             }

      assert Operations.get_result("a-cash")["revision"] == 6
      assert Operations.get_result("a-cash")["outstanding_deposit_cents"] == 20

      Ecto.Migrator.run(Repo, :down, step: 1, log: false)
      before_downgrade = storage_snapshot()

      assert_raise Ecto.MigrationError, ~r/cannot downgrade room accounting/, fn ->
        Ecto.Migrator.run(Repo, :down, step: 1, log: false)
      end

      assert storage_snapshot() == before_downgrade
    after
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
      Repo.put_dynamic_repo(previous)
      stop_supervised!(Repo)
    end
  end

  defp seed_previous_release do
    for {id, status, cash, credit, due, revision, rates} <- [
          {"source-a", "cancelled", 0, 0, 0, 4, [500]},
          {"source-b", "cancelled", 0, 0, 0, 3, [500]},
          {"main", "active", 125, 55, 200, 6, [250, 250, 250, 250]}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, policy_version, status, revision, lodging_total_cents, deposit_due_cents,
          deposit_paid_cents, cash_paid_cents, credit_paid_cents, inserted_at, updated_at)
        VALUES (?, 'guest-22', 'ams-canal', '2026-01-01', '2026-12-10', '2026-12-11',
          'flexible', 'flex-14', ?, ?, ?, ?, ?, ?, ?, '2026-01-01T00:00:00.000000', '2026-10-03T00:00:00.000000')
        """,
        [id, status, revision, Enum.sum(rates), due, cash + credit, cash, credit]
      )

      for {{room_id, rate}, position} <-
            Enum.zip(["z", "a", "m", "b"], rates) |> Enum.with_index() do
        Repo.query!(
          "INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents) VALUES (?, ?, ?, ?)",
          [id, room_id, position, rate]
        )
      end
    end

    for {group_id, operation_id, kind, amount} <- [
          {"source-a", "legacy-a", "payment", 95},
          {"source-a", "source-payment", "payment", 5},
          {"source-a", "legacy-cancellation", "credit_conversion", 100},
          {"source-b", "legacy-b", "payment", 100},
          {"source-b", "legacy-cancellation", "credit_conversion", 100},
          {"main", "legacy-cash", "payment", 30},
          {"main", "a-cash", "payment", 95}
        ] do
      Repo.query!(
        """
        INSERT INTO cash_entries (group_id, operation_id, kind, amount_cents, occurred_on, inserted_at)
        VALUES (?, ?, ?, ?, '2026-10-03', '2026-10-03T00:00:00.000000')
        """,
        [group_id, operation_id, kind, amount]
      )
    end

    # Before idempotency, source operation references could be reused across groups.
    for {id, group_id, remaining, expiry} <- [
          {1, "source-a", 70, "2027-10-03"},
          {2, "source-b", 95, "2027-11-03"}
        ] do
      Repo.query!(
        """
        INSERT INTO credit_lots (id, guest_id, source_group_id, source_operation_id, issued_cents,
          remaining_cents, expires_on, inserted_at, updated_at)
        VALUES (?, 'guest-22', ?, 'legacy-cancellation', 110, ?, ?, '2026-10-03T00:00:00.000000', '2026-10-03T00:00:00.000000')
        """,
        [id, group_id, remaining, expiry]
      )
    end

    for {lot_id, id, amount} <- [
          {2, "legacy-credit-b", 15},
          {1, "legacy-credit-a", 15},
          {1, "z-credit", 25}
        ] do
      Repo.query!(
        """
        INSERT INTO credit_allocations (group_id, credit_lot_id, operation_id, amount_cents, status, inserted_at, updated_at)
        VALUES ('main', ?, ?, ?, 'applied', '2026-10-03T00:00:00.000000', '2026-10-03T00:00:00.000000')
        """,
        [lot_id, id, amount]
      )
    end

    for {id, type, group_id, amount, revision, outstanding, on} <- [
          {"source-payment", "record_cash_payment", "source-a", 5, 3, 0, "2026-10-03"},
          {"z-credit", "apply_hotel_credit", "main", 25, 5, 115, "2026-11-01"},
          {"a-cash", "record_cash_payment", "main", 95, 6, 20, "2026-09-01"}
        ] do
      payload = %{
        "operation_id" => id,
        "type" => type,
        "group_id" => group_id,
        "amount_cents" => amount,
        "occurred_on" => on
      }

      result = %{
        "operation_id" => id,
        "status" => "applied",
        "group_id" => group_id,
        "amount_cents" => amount,
        "revision" => revision,
        "outstanding_deposit_cents" => outstanding
      }

      Repo.query!(
        """
        INSERT INTO operation_records (operation_id, operation_type, payload, result, inserted_at)
        VALUES (?, ?, ?, ?, '2026-10-03T00:00:00.000000')
        """,
        [id, type, Jason.encode!(payload), Jason.encode!(result)]
      )
    end
  end

  defp verify_legacy_transfer_order do
    # Exercise imported senior cash and credit alongside recorded funding, then
    # roll back this probe so the earlier migration/settlement checks still run.
    assert {:error, :probe_complete} =
             Repo.transaction(fn ->
               results =
                 Operations.apply_batch([
                   open_group(%{
                     "group_id" => "destination",
                     "departure_on" => "2026-12-11",
                     "rooms" =>
                       Enum.map(0..3, &%{"room_id" => "r-#{&1}", "nightly_rate_cents" => 250})
                   }),
                   transfer_deposit("main", "destination", 180)
                 ])

               assert Enum.all?(results, &(&1["status"] == "applied"))

               assert Enum.map(
                        Reservations.get_group("destination").rooms,
                        &{&1.cash_paid_cents, &1.credit_paid_cents}
                      ) == [{50, 0}, {45, 5}, {0, 50}, {30, 0}]

               assert [%{"refunded_cents" => 95}] =
                        Operations.apply_batch([
                          operation("cancel_rooms", %{
                            "group_id" => "destination",
                            "room_ids" => ["r-0", "r-1"]
                          })
                        ])

               assert {:ok, %{held_cents: 0, refunded_cents: 95, held_by_group: []}} =
                        Payments.statement("a-cash")

               assert Credits.balance("guest-22", ~D[2026-10-03]).available_cents == 170
               Repo.rollback(:probe_complete)
             end)
  end

  defp lot_balances,
    do:
      Repo.query!(
        "SELECT id, remaining_cents, issued_cents, expires_on FROM credit_lots ORDER BY id"
      ).rows

  defp credit_allocations,
    do:
      Repo.query!(
        "SELECT group_id, credit_lot_id, operation_id, status, SUM(amount_cents) FROM credit_allocations GROUP BY group_id, credit_lot_id, operation_id, status ORDER BY operation_id"
      ).rows

  defp correction(type, target, params \\ %{}),
    do: operation(type, Map.put(params, "payment_operation_id", target)) |> Map.delete("group_id")

  defp snapshot,
    do:
      Map.new(
        [Group, Room, CashEntry, CashAllocation, Lot, Allocation, Entitlement, Record],
        &{&1, Repo.all(&1)}
      )

  defp storage_snapshot do
    Map.new(
      ~w(groups rooms cash_entries cash_allocations credit_lots credit_allocations credit_entitlements operation_records),
      &{&1, Repo.query!("SELECT * FROM #{&1} ORDER BY 1").rows}
    )
  end
end
