defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias GroupStay.Groups.{
    CashPayment,
    CashPaymentSettlement,
    CreditLot,
    CreditLotContribution,
    Group,
    Room,
    RoomAllocation
  }

  alias GroupStay.MigrationTestRepo, as: Repo

  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @durable_operations_version 20_260_826_000_003

  setup_all do
    path =
      Path.join(
        System.tmp_dir!(),
        "group_stay_migration_#{System.unique_integer([:positive])}.db"
      )

    {:ok, _pid} = Repo.start_link(database: path, pool_size: 1)

    on_exit(fn ->
      File.rm(path)
    end)

    :ok
  end

  # Each test starts from an empty database and runs the migrations itself.
  setup do
    Repo.query!("PRAGMA foreign_keys = OFF")

    for [table] <-
          Repo.query!(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
          ).rows do
      Repo.query!("DROP TABLE \"#{table}\"")
    end

    Repo.query!("PRAGMA foreign_keys = ON")
    :ok
  end

  defp migrate_to(version) do
    purge_migration_modules()

    Ecto.Migrator.run(Repo, @migrations_path, :up,
      to: version,
      log: false,
      migration_lock: false
    )
  end

  defp migrate_all do
    purge_migration_modules()

    Ecto.Migrator.run(Repo, @migrations_path, :up, all: true, log: false, migration_lock: false)
  end

  # The main test run already migrated (and therefore loaded) these modules;
  # purging them keeps the in-test re-runs from redefining loaded modules.
  @migration_modules [
    GroupStay.Repo.Migrations.CreateOperationalCore,
    GroupStay.Repo.Migrations.AddCancellationEconomics,
    GroupStay.Repo.Migrations.AddDurableOperations,
    GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions,
    GroupStay.Repo.Migrations.AddDepositTransfers,
    GroupStay.Repo.Migrations.AddDailyFinanceReport,
    GroupStay.Repo.Migrations.AddFinancePeriodClose
  ]

  defp purge_migration_modules do
    for module <- @migration_modules do
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp now, do: NaiveDateTime.utc_now(:second)

  defp insert_group(attrs) do
    defaults = %{
      status: "active",
      revision: 1,
      deposit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      inserted_at: now(),
      updated_at: now()
    }

    {_count, [group]} = Repo.insert_all("groups", [Map.merge(defaults, attrs)], returning: [:id])
    group.id
  end

  defp insert_room(group_pk, room_id, nightly_rate_cents, position) do
    {_count, [room]} =
      Repo.insert_all(
        "rooms",
        [
          %{
            group_id: group_pk,
            room_id: room_id,
            nightly_rate_cents: nightly_rate_cents,
            position: position,
            inserted_at: now(),
            updated_at: now()
          }
        ],
        returning: [:id]
      )

    room.id
  end

  defp insert_payment(group_pk, amount_cents, operation_id, occurred_on \\ "2026-10-04") do
    {_count, [payment]} =
      Repo.insert_all(
        "cash_payments",
        [
          %{
            group_id: group_pk,
            amount_cents: amount_cents,
            occurred_on: occurred_on,
            operation_id: operation_id,
            inserted_at: now(),
            updated_at: now()
          }
        ],
        returning: [:id]
      )

    payment.id
  end

  defp insert_lot(guest_id, source_operation_id, cents, expires_on \\ "2027-10-04") do
    {_count, [lot]} =
      Repo.insert_all(
        "credit_lots",
        [
          %{
            guest_id: guest_id,
            source_operation_id: source_operation_id,
            original_cents: cents,
            remaining_cents: cents,
            expires_on: expires_on,
            inserted_at: now(),
            updated_at: now()
          }
        ],
        returning: [:id]
      )

    lot.id
  end

  defp insert_application(lot_pk, group_pk, amount_cents) do
    {_count, [application]} =
      Repo.insert_all(
        "credit_applications",
        [
          %{
            lot_id: lot_pk,
            group_id: group_pk,
            amount_cents: amount_cents,
            inserted_at: now(),
            updated_at: now()
          }
        ],
        returning: [:id]
      )

    application.id
  end

  defp insert_record(operation_id, type, payload, result) do
    Repo.insert_all("operation_records", [
      %{
        operation_id: operation_id,
        type: type,
        payload: Jason.encode!(payload),
        result: Jason.encode!(result),
        inserted_at: now(),
        updated_at: now()
      }
    ])
  end

  defp count(table) do
    Repo.aggregate(table, :count)
  end

  describe "upgrading a database created by an earlier release" do
    setup do
      # A database at the durable-operations release: two active-group
      # rooms, funding that predates durable records, one recorded payment,
      # and two settled groups.
      migrate_to(@durable_operations_version)

      active_pk =
        insert_group(%{
          group_id: "group-active",
          guest_id: "guest-22",
          property_id: "ams-canal",
          arrival_on: "2026-12-10",
          departure_on: "2026-12-13",
          booked_on: "2026-10-03",
          rate_plan: "flexible",
          lodging_total_cents: 45000,
          deposit_due_cents: 9000,
          deposit_paid_cents: 8500,
          credit_paid_cents: 1500
        })

      room_a = insert_room(active_pk, "room-a", 10000, 0)
      room_b = insert_room(active_pk, "room-b", 5000, 1)

      legacy_pay_1 = insert_payment(active_pk, 4000, "op-legacy-pay-1")
      legacy_pay_2 = insert_payment(active_pk, 1000, nil)

      old_lot = insert_lot("guest-22", "op-old-cancel", 1650)
      application = insert_application(old_lot, active_pk, 1500)

      insert_record(
        "op-recorded-pay",
        "record_cash_payment",
        %{"type" => "record_cash_payment", "group_id" => "group-active", "amount_cents" => 2000},
        %{"status" => "applied", "group_id" => "group-active"}
      )

      recorded_pay = insert_payment(active_pk, 2000, "op-recorded-pay")

      converted_pk =
        insert_group(%{
          group_id: "group-converted",
          guest_id: "guest-22",
          property_id: "ams-canal",
          arrival_on: "2026-12-10",
          departure_on: "2026-12-13",
          booked_on: "2026-10-03",
          rate_plan: "flexible",
          status: "cancelled",
          lodging_total_cents: 30000,
          deposit_due_cents: 6000,
          deposit_paid_cents: 3000,
          converted_cents: 3000
        })

      insert_room(converted_pk, "room-a", 10000, 0)

      insert_payment(converted_pk, 1000, "op-legacy-pay-3")

      insert_record(
        "op-recorded-pay-2",
        "record_cash_payment",
        %{
          "type" => "record_cash_payment",
          "group_id" => "group-converted",
          "amount_cents" => 2000
        },
        %{"status" => "applied", "group_id" => "group-converted"}
      )

      insert_payment(converted_pk, 2000, "op-recorded-pay-2")

      lot = insert_lot("guest-22", "op-cancel-converted", 3300)

      insert_record(
        "op-cancel-converted",
        "cancel_group",
        %{
          "type" => "cancel_group",
          "group_id" => "group-converted",
          "refund_method" => "hotel_credit"
        },
        %{"status" => "applied", "group_id" => "group-converted", "credit_issued_cents" => 3300}
      )

      refunded_pk =
        insert_group(%{
          group_id: "group-refunded",
          guest_id: "guest-22",
          property_id: "ams-canal",
          arrival_on: "2026-12-10",
          departure_on: "2026-12-13",
          booked_on: "2026-10-03",
          rate_plan: "flexible",
          status: "cancelled",
          lodging_total_cents: 30000,
          deposit_due_cents: 6000,
          deposit_paid_cents: 500,
          refunded_cents: 500
        })

      insert_room(refunded_pk, "room-a", 10000, 0)
      insert_payment(refunded_pk, 500, "op-legacy-pay-4")

      %{
        active_pk: active_pk,
        room_a: room_a,
        room_b: room_b,
        legacy_pay_1: legacy_pay_1,
        legacy_pay_2: legacy_pay_2,
        application: application,
        recorded_pay: recorded_pay,
        lot: lot
      }
    end

    test "rooms keep their lodging and deposit amounts and the group totals", ctx do
      migrate_all()

      rooms =
        Repo.all(
          from r in Room,
            where: r.group_id == ^ctx.active_pk,
            order_by: [asc: r.position]
        )

      assert [room_a, room_b] = rooms
      assert room_a.status == "active"
      assert room_a.lodging_cents == 30000
      assert room_a.deposit_cents == 6000
      assert room_b.lodging_cents == 15000
      assert room_b.deposit_cents == 3000

      # Settled groups' rooms are already cancelled.
      settled_rooms = Repo.all(from r in Room, where: r.group_id != ^ctx.active_pk)
      assert settled_rooms != []
      assert Enum.all?(settled_rooms, &(&1.status == "cancelled"))

      # The stored group totals are unchanged.
      [group] = Repo.all(from g in Group, where: g.id == ^ctx.active_pk)
      assert group.deposit_due_cents == 9000
      assert group.deposit_paid_cents == 8500
      assert group.credit_paid_cents == 1500

      # Settled groups describe no active rooms.
      settled_groups = Repo.all(from g in Group, where: g.status != "active", select: g)
      assert settled_groups != []

      for group <- settled_groups do
        assert group.lodging_total_cents == 0
        assert group.deposit_due_cents == 0
        assert group.deposit_paid_cents == 0
        assert group.credit_paid_cents == 0
      end
    end

    test "brings legacy funding forward as one unattributed senior block", ctx do
      migrate_all()

      allocations =
        Repo.all(
          from a in RoomAllocation,
            join: r in Room,
            on: a.room_id == r.id,
            where: r.group_id == ^ctx.active_pk,
            order_by: [asc: r.position, asc: a.id]
        )

      # Aggregate legacy cash fills room-a first, then the legacy credit
      # lot finishes room-a and starts room-b, and the recorded payment
      # follows in durable-record commit order.
      assert Enum.map(
               allocations,
               &{&1.room_id, &1.cash_payment_id, &1.credit_application_id, &1.amount_cents}
             ) ==
               [
                 {ctx.room_a, ctx.legacy_pay_1, nil, 4000},
                 {ctx.room_a, ctx.legacy_pay_2, nil, 1000},
                 {ctx.room_a, nil, ctx.application, 1000},
                 {ctx.room_b, nil, ctx.application, 500},
                 {ctx.room_b, ctx.recorded_pay, nil, 2000}
               ]

      rooms =
        Repo.all(
          from r in Room,
            where: r.group_id == ^ctx.active_pk,
            order_by: [asc: r.position]
        )

      assert [room_a, room_b] = rooms
      assert room_a.cash_paid_cents == 5000
      assert room_a.credit_paid_cents == 1000
      assert room_b.cash_paid_cents == 2000
      assert room_b.credit_paid_cents == 500

      # Creating the allocations changed no aggregate balance: the room
      # funding sums to the group's stored paid deposit.
      assert room_a.cash_paid_cents + room_b.cash_paid_cents + room_a.credit_paid_cents +
               room_b.credit_paid_cents == 8500
    end

    test "settled payments keep the disposition chosen by their cancellation", _ctx do
      migrate_all()

      payments =
        Repo.all(
          from p in CashPayment,
            join: g in Group,
            on: p.group_id == g.id,
            order_by: [asc: g.group_id, asc: p.id],
            select: %{
              group_id: g.group_id,
              amount_cents: p.amount_cents,
              refunded_cents: p.refunded_cents,
              retained_cents: p.retained_cents,
              converted_cents: p.converted_cents,
              reduced_cents: p.reduced_cents,
              charged_back_cents: p.charged_back_cents
            }
        )

      by_group = Enum.group_by(payments, & &1.group_id)

      # Active-group funding is still entirely held.
      for payment <- by_group["group-active"] do
        assert payment.refunded_cents == 0
        assert payment.retained_cents == 0
        assert payment.converted_cents == 0
      end

      # The converted group's payments moved to credit; the refunded
      # group's payment was refunded.
      assert Enum.map(by_group["group-converted"], &{&1.amount_cents, &1.converted_cents}) ==
               [{1000, 1000}, {2000, 2000}]

      assert [{500, 500}] =
               Enum.map(by_group["group-refunded"], &{&1.amount_cents, &1.refunded_cents})
    end

    test "attributes settled dispositions to the payment's own group", ctx do
      migrate_all()

      settlements =
        Repo.all(
          from s in CashPaymentSettlement,
            join: p in CashPayment,
            on: s.cash_payment_id == p.id,
            join: g in Group,
            on: s.group_id == g.id,
            order_by: [asc: g.group_id, asc: p.id],
            select: %{
              group_id: g.group_id,
              own_group: g.id == p.group_id,
              amount_cents: p.amount_cents,
              refunded_cents: s.refunded_cents,
              retained_cents: s.retained_cents,
              converted_cents: s.converted_cents
            }
        )

      # Funding could not cross groups before transfers existed, so every
      # settled disposition stays attributed to the payment's own group.
      assert Enum.all?(settlements, & &1.own_group)

      assert Enum.map(settlements, &{&1.group_id, &1.amount_cents, &1.converted_cents}) ==
               [
                 {"group-converted", 1000, 1000},
                 {"group-converted", 2000, 2000},
                 {"group-refunded", 500, 0}
               ]

      [refunded] = Enum.filter(settlements, &(&1.group_id == "group-refunded"))
      assert refunded.refunded_cents == 500

      # Held funding has no settlements, and no payment has transferred yet.
      assert Repo.all(
               from s in CashPaymentSettlement,
                 join: p in CashPayment,
                 on: s.cash_payment_id == p.id,
                 where: p.group_id == ^ctx.active_pk
             ) == []

      assert Repo.all(CashPayment) |> Enum.all?(&(&1.transferred == false))
    end

    test "retains lot contributions in funding order for future chargebacks", ctx do
      migrate_all()

      contributions =
        Repo.all(
          from c in CreditLotContribution,
            where: c.lot_id == ^ctx.lot,
            order_by: [asc: c.position]
        )

      # The unattributed senior block first, then the recorded payment in
      # commit order.
      assert [block, recorded] = contributions
      assert block.cash_payment_id == nil
      assert block.amount_cents == 1000
      assert block.position == 0
      assert recorded.cash_payment_id != nil
      assert recorded.amount_cents == 2000
      assert recorded.position == 1

      # The lot issued before durable records has no chargeable payments
      # and keeps no contributions.
      old_lot =
        Repo.one(from l in CreditLot, where: l.source_operation_id == "op-old-cancel", select: l)

      assert Repo.all(from c in CreditLotContribution, where: c.lot_id == ^old_lot.id) == []
    end
  end

  test "a fresh database migrates cleanly" do
    migrate_all()
    assert count("groups") == 0
    assert count("room_allocations") == 0
    assert count("credit_lot_contributions") == 0
    assert count("cash_payment_settlements") == 0
  end
end
