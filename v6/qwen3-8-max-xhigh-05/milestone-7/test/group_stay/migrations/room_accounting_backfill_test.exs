defmodule GroupStay.Migrations.RoomAccountingBackfillTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Finance.CreditApplication
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Migrations.RoomAccountingBackfill
  alias GroupStay.Repo

  setup %{conn: conn} do
    open_group_fixture(conn)
    :ok
  end

  defp allocations(group_id) do
    Repo.all(
      from a in RoomAllocation,
        join: g in Group,
        on: a.group_id == g.id,
        where: g.group_id == ^group_id,
        order_by: [asc: a.id]
    )
  end

  defp rooms(group_id) do
    Repo.all(
      from r in Room,
        join: g in Group,
        on: r.group_id == g.id,
        where: g.group_id == ^group_id,
        order_by: [asc: r.position]
    )
  end

  defp strip_room_accounting(group_id) do
    group = Repo.get_by!(Group, group_id: group_id)

    Repo.delete_all(from a in RoomAllocation, where: a.group_id == ^group.id)

    Repo.update_all(
      from(r in Room, where: r.group_id == ^group.id),
      set: [deposit_due_cents: 0, cash_paid_cents: 0, credit_paid_cents: 0]
    )

    group
  end

  defp restore_historical_totals(group, cash_paid_cents) do
    Repo.update_all(
      from(g in Group, where: g.id == ^group.id),
      set: [
        lodging_total_cents: 97500,
        deposit_due_cents: 19500,
        deposit_paid_cents: cash_paid_cents,
        cash_paid_cents: cash_paid_cents,
        credit_paid_cents: 0
      ]
    )

    :ok
  end

  test "carries legacy funding forward as one unattributed senior block", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    group_db_id = Ecto.UUID.generate()

    Repo.insert_all(Group, [
      %{
        id: group_db_id,
        group_id: "group-legacy",
        guest_id: "guest-22",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        status: "active",
        lodging_total_cents: 97500,
        deposit_due_cents: 19500,
        deposit_paid_cents: 12000,
        cash_paid_cents: 9000,
        credit_paid_cents: 3000,
        revision: 4,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(Room, [
      %{
        id: Ecto.UUID.generate(),
        group_id: group_db_id,
        room_id: "room-a",
        nightly_rate_cents: 15000,
        position: 0,
        status: "active",
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        group_id: group_db_id,
        room_id: "room-b",
        nightly_rate_cents: 17500,
        position: 1,
        status: "active",
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    lot_id = Ecto.UUID.generate()

    Repo.insert_all(CreditLot, [
      %{
        id: lot_id,
        guest_id: "guest-22",
        source_operation_id: "old-cancel",
        remaining_cents: 2000,
        expires_on: ~D[2027-06-01],
        unrecovered_clawback_cents: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(CreditApplication, [
      %{
        id: Ecto.UUID.generate(),
        group_id: group_db_id,
        lot_id: lot_id,
        amount_cents: 3000,
        status: "active",
        inserted_at: now,
        updated_at: now
      }
    ])

    RoomAccountingBackfill.run()

    [room_a, room_b] = rooms("group-legacy")
    assert room_a.status == "active"
    assert room_a.deposit_due_cents == 9000
    assert room_a.cash_paid_cents == 9000
    assert room_a.credit_paid_cents == 0
    assert room_b.deposit_due_cents == 10500
    assert room_b.cash_paid_cents == 0
    assert room_b.credit_paid_cents == 3000

    # The senior block's aggregate cash fills first, then its credit lots.
    assert [cash, credit] = allocations("group-legacy")
    assert %{kind: "cash", amount_cents: 9000, funding_operation_id: nil, status: "held"} = cash
    assert %{kind: "credit", amount_cents: 3000, lot_id: ^lot_id, status: "held"} = credit
    assert credit.funding_operation_id == nil

    # No aggregate balance changes.
    data = group_data(conn, "group-legacy")
    assert data["deposit_paid_cents"] == 12000
    assert data["outstanding_deposit_cents"] == 7500

    ledger = ledger_data(conn)
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_reduced_cents"] == 0
    assert ledger["credit_liability_cents"] == 5000
    assert ledger["credit_shortfall_cents"] == 0
  end

  test "allocates recorded funding after the senior block in commit order", %{conn: conn} do
    pay_group(conn, "group-81", 5000, %{"operation_id" => "op-pay-1"})
    pay_group(conn, "group-81", 4000, %{"operation_id" => "op-pay-2"})

    group = strip_room_accounting("group-81")

    # Funding that predates durable records: 2000 of unattributed cash.
    Repo.update_all(
      from(g in Group, where: g.id == ^group.id),
      inc: [cash_paid_cents: 2000, deposit_paid_cents: 2000]
    )

    RoomAccountingBackfill.run()

    fundings =
      allocations("group-81")
      |> Enum.map(&{&1.funding_operation_id, &1.amount_cents, &1.status})

    # op-pay-2 fills room-a's remaining capacity and then room-b.
    assert fundings == [
             {nil, 2000, "held"},
             {"op-pay-1", 5000, "held"},
             {"op-pay-2", 2000, "held"},
             {"op-pay-2", 2000, "held"}
           ]

    [room_a, room_b] = rooms("group-81")
    assert room_a.cash_paid_cents == 9000
    assert room_b.cash_paid_cents == 2000

    assert group_data(conn, "group-81")["deposit_paid_cents"] == 11000
  end

  test "attributes recorded credit applications to their lots", %{conn: conn} do
    open_group_fixture(conn, %{"operation_id" => "op-open-fund", "group_id" => "group-fund"})
    pay_group(conn, "group-fund", 5000)
    cancel_group(conn, "group-fund", "2026-11-26", %{"refund_method" => "hotel_credit"})

    submit_batch(conn, [
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81",
        "amount_cents" => 3000
      }
    ])

    group = strip_room_accounting("group-81")
    lot = Repo.get_by!(CreditLot, source_operation_id: "op-cancel-group-fund")

    # Release-03 funding recorded which lots funded the group.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(CreditApplication, [
      %{
        id: Ecto.UUID.generate(),
        group_id: group.id,
        lot_id: lot.id,
        amount_cents: 3000,
        status: "active",
        inserted_at: now,
        updated_at: now
      }
    ])

    RoomAccountingBackfill.run()

    assert [allocation] = allocations("group-81")
    assert allocation.kind == "credit"
    assert allocation.funding_operation_id == "op-credit"
    assert allocation.lot_id == lot.id
    assert allocation.amount_cents == 3000
    assert allocation.status == "held"

    # The carried-forward credit still restores to its original lot.
    result =
      cancel_group(conn, "group-81", "2026-11-26")

    assert result["status"] == "applied"
    assert guest_credit_data(conn, "guest-22")["available_cents"] == 5500
  end

  test "carries settled recorded cash forward for cancelled groups", %{conn: conn} do
    pay_group(conn, "group-81", 5000, %{"operation_id" => "op-pay"})
    cancel_group(conn, "group-81", "2026-11-26")

    group = strip_room_accounting("group-81")
    restore_historical_totals(group, 5000)

    RoomAccountingBackfill.run()

    assert [allocation] = allocations("group-81")
    assert allocation.funding_operation_id == "op-pay"
    assert allocation.amount_cents == 5000
    assert allocation.status == "refunded"

    [room_a, _room_b] = rooms("group-81")
    assert room_a.status == "cancelled"
    assert room_a.deposit_due_cents == 9000
    assert room_a.cash_paid_cents == 5000

    data = group_data(conn, "group-81")
    assert data["status"] == "cancelled"
    assert data["deposit_due_cents"] == 0
    assert data["deposit_paid_cents"] == 0

    # The carried-forward cash is chargeable through the payment's identity.
    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-charge-back",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-12-01",
          "payment_operation_id" => "op-pay"
        }
      ])

    assert result["status"] == "applied"
    assert result["charged_back_cents"] == 5000

    ledger = ledger_data(conn)
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 5000
  end

  test "links converted cash to the lot issued by the cancellation", %{conn: conn} do
    pay_group(conn, "group-81", 5000, %{"operation_id" => "op-pay"})
    cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})

    group = strip_room_accounting("group-81")
    restore_historical_totals(group, 5000)

    RoomAccountingBackfill.run()

    lot = Repo.get_by!(CreditLot, source_operation_id: "op-cancel-group-81")

    assert [allocation] = allocations("group-81")
    assert allocation.status == "converted"
    assert allocation.lot_id == lot.id

    # A chargeback revokes the entitlement from the carried-forward lot.
    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-charge-back",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-12-01",
          "payment_operation_id" => "op-pay"
        }
      ])

    assert result["status"] == "applied"
    assert guest_credit_data(conn, "guest-22")["available_cents"] == 5000
    assert ledger_data(conn)["cash_converted_to_credit_cents"] == 0
  end

  test "chargeback entitlements account for the unattributed senior block", %{conn: conn} do
    pay_group(conn, "group-81", 5000, %{"operation_id" => "op-pay"})

    group = strip_room_accounting("group-81")

    # 1000 of legacy cash predates durable records.
    Repo.update_all(
      from(g in Group, where: g.id == ^group.id),
      inc: [cash_paid_cents: 1000, deposit_paid_cents: 1000]
    )

    RoomAccountingBackfill.run()

    cancel_group(conn, "group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})

    # The lot is 110% of the combined 6000.
    assert guest_credit_data(conn, "guest-22")["available_cents"] == 6600

    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-charge-back",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-12-01",
          "payment_operation_id" => "op-pay"
        }
      ])

    assert result["status"] == "applied"
    assert result["charged_back_cents"] == 5000

    # The entitlement is round(10% of 6000) - round(10% of 1000) = 500, with
    # the senior block first in the funding order.
    assert guest_credit_data(conn, "guest-22")["available_cents"] == 6100
  end

  test "legacy credit is attributed to lots in original consumption order", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    group_db_id = Ecto.UUID.generate()

    Repo.insert_all(Group, [
      %{
        id: group_db_id,
        group_id: "group-legacy",
        guest_id: "guest-22",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        status: "active",
        lodging_total_cents: 97500,
        deposit_due_cents: 19500,
        deposit_paid_cents: 3000,
        cash_paid_cents: 0,
        credit_paid_cents: 3000,
        revision: 3,
        inserted_at: now,
        updated_at: now
      }
    ])

    room_a = Ecto.UUID.generate()

    Repo.insert_all(Room, [
      %{
        id: room_a,
        group_id: group_db_id,
        room_id: "room-a",
        nightly_rate_cents: 15000,
        position: 0,
        status: "active",
        deposit_due_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    first_lot = Ecto.UUID.generate()
    second_lot = Ecto.UUID.generate()

    Repo.insert_all(CreditLot, [
      %{
        id: first_lot,
        guest_id: "guest-22",
        source_operation_id: "old-cancel-1",
        remaining_cents: 0,
        expires_on: ~D[2027-06-01],
        unrecovered_clawback_cents: 0,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: second_lot,
        guest_id: "guest-22",
        source_operation_id: "old-cancel-2",
        remaining_cents: 0,
        expires_on: ~D[2027-06-01],
        unrecovered_clawback_cents: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(CreditApplication, [
      %{
        id: Ecto.UUID.generate(),
        group_id: group_db_id,
        lot_id: first_lot,
        amount_cents: 1000,
        status: "active",
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        group_id: group_db_id,
        lot_id: second_lot,
        amount_cents: 2000,
        status: "active",
        inserted_at: now,
        updated_at: now
      }
    ])

    RoomAccountingBackfill.run()

    assert [first, second] = allocations("group-legacy")
    assert %{kind: "credit", amount_cents: 1000, lot_id: ^first_lot} = first
    assert %{kind: "credit", amount_cents: 2000, lot_id: ^second_lot} = second

    # A refundable cancellation restores each portion to its original lot.
    result = cancel_group(conn, "group-legacy", "2026-11-26")
    assert result["status"] == "applied"

    lots =
      guest_credit_data(conn, "guest-22")["lots"]
      |> Enum.map(&{&1["source_operation_id"], &1["remaining_cents"]})

    assert lots == [{"old-cancel-1", 1000}, {"old-cancel-2", 2000}]
  end

  test "leaves groups that already carry room accounting untouched", %{conn: conn} do
    pay_group(conn, "group-81", 5000)

    before = allocations("group-81")
    assert before != []

    RoomAccountingBackfill.run()

    assert allocations("group-81") == before
    assert group_data(conn, "group-81")["deposit_paid_cents"] == 5000
  end
end
