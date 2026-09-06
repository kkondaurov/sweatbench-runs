defmodule GroupStayWeb.LegacyFundingTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  alias GroupStay.Credit.CreditApplication
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Record, as: OperationRecord
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  import Ecto.Query

  defp get_group(group_id) do
    {body, 200} = api_get(build_conn(), "/api/v1/groups/#{group_id}")
    body["data"]
  end

  defp get_ledger(query \\ "") do
    api_get(build_conn(), "/api/v1/ledger#{query}")
  end

  defp get_payment(payment_operation_id) do
    api_get(build_conn(), "/api/v1/payments/#{payment_operation_id}")
  end

  defp insert_group(group_id, status, cash, attrs \\ %{}) do
    base = %{
      group_id: group_id,
      guest_id: Map.get(attrs, :guest_id, "guest-legacy"),
      property_id: "p-1",
      booked_on: ~D[2026-06-05],
      arrival_on: ~D[2026-09-01],
      departure_on: ~D[2026-09-03],
      rate_plan: Map.get(attrs, :rate_plan, "flexible"),
      status: status,
      revision: 1,
      policy_version: nil,
      lodging_total_cents: Map.get(attrs, :lodging_total_cents, 60_000),
      deposit_due_cents: Map.get(attrs, :deposit_due_cents, 12_000),
      deposit_paid_cents: cash,
      cash_paid_cents: cash
    }

    {:ok, group} = Repo.insert(struct(Group, base))
    group
  end

  defp insert_room(group, room_id, nightly_rate_cents, position) do
    {:ok, room} =
      Repo.insert(%Room{
        room_id: room_id,
        nightly_rate_cents: nightly_rate_cents,
        position: position,
        group_id: group.id
      })

    room
  end

  defp insert_applied_payment_record(operation_id, group_id, amount_cents) do
    Repo.insert!(%OperationRecord{
      operation_id: operation_id,
      type: "record_cash_payment",
      payload: "{}",
      result:
        Jason.encode!(%{
          "operation_id" => operation_id,
          "status" => "applied",
          "group_id" => group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => 0,
          "revision" => 2
        })
    })
  end

  test "brings forward unattributed cash as a senior block allocated in room order" do
    group = insert_group("legacy-cash", "active", 8_000)
    insert_room(group, "room-a", 15_000, 0)
    insert_room(group, "room-b", 5_000, 1)
    # Two nights long: a requires 6,000 (30,000 * 20%) and b requires 2,000
    # (10,000 * 20%). The senior block funds a first.

    RoomAccounting.backfill()

    data = get_group("legacy-cash")

    assert data["cash_paid_cents"] == 8_000
    assert Enum.map(data["rooms"], & &1["deposit_due_cents"]) == [6_000, 2_000]
    assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [6_000, 2_000]

    rows =
      RoomAccounting.allocations_for_group(group.id)
      |> Enum.sort_by(& &1.seq)

    assert Enum.map(rows, &{&1.amount_cents, &1.payment_operation_id, &1.disposition}) == [
             {6_000, nil, "held"},
             {2_000, nil, "held"}
           ]
  end

  test "allocates the senior block before durable records, regardless of occurred_on" do
    group = insert_group("legacy-mix", "active", 8_000)
    insert_room(group, "room-a", 15_000, 0)
    insert_room(group, "room-b", 5_000, 1)

    # Durable records committed in this order; their occurred_on dates are
    # deliberately out of order.
    Repo.insert!(%OperationRecord{
      operation_id: "durable-1",
      type: "record_cash_payment",
      payload: "{}",
      result:
        Jason.encode!(%{
          "operation_id" => "durable-1",
          "status" => "applied",
          "group_id" => "legacy-mix",
          "amount_cents" => 3_000,
          "outstanding_deposit_cents" => 0,
          "revision" => 3,
          "occurred_on" => "2026-06-20"
        })
    })

    RoomAccounting.backfill()

    rows =
      RoomAccounting.allocations_for_group(group.id)
      |> Enum.sort_by(& &1.seq)

    # Legacy cash (8,000 paid minus 3,000 recorded) fills room-a first;
    # the durable payment, committed after the senior block, finishes room-a
    # and fills room-b.
    assert Enum.map(rows, &{&1.amount_cents, &1.payment_operation_id}) == [
             {5_000, nil},
             {1_000, "durable-1"},
             {2_000, "durable-1"}
           ]

    data = get_group("legacy-mix")
    assert Enum.map(data["rooms"], & &1["cash_paid_cents"]) == [6_000, 2_000]
    assert data["cash_paid_cents"] == 8_000
  end

  test "brings forward legacy hotel credit per lot in consumption order" do
    group =
      insert_group("legacy-credit", "active", 0, %{guest_id: "guest-legacy-credit"})

    insert_room(group, "room-a", 15_000, 0)
    insert_room(group, "room-b", 5_000, 1)

    {:ok, lot_early} =
      Repo.insert(%CreditLot{
        guest_id: "guest-legacy-credit",
        source_operation_id: "cancel-early",
        expires_on: ~D[2027-01-01],
        remaining_cents: 6_000
      })

    {:ok, lot_late} =
      Repo.insert(%CreditLot{
        guest_id: "guest-legacy-credit",
        source_operation_id: "cancel-late",
        expires_on: ~D[2027-02-01],
        remaining_cents: 6_000
      })

    # The group's credit_paid figure covers the market; applications were
    # recorded by the earlier release and predate durable records.
    {:ok, _} =
      Repo.insert(%CreditApplication{
        lot_id: lot_early.id,
        group_id: group.id,
        amount_cents: 4_000
      })

    {:ok, _} =
      Repo.insert(%CreditApplication{
        lot_id: lot_late.id,
        group_id: group.id,
        amount_cents: 3_000
      })

    Repo.update_all(
      from(g in Group, where: g.id == ^group.id),
      set: [credit_paid_cents: 7_000, deposit_paid_cents: 7_000]
    )

    RoomAccounting.backfill()

    rows =
      RoomAccounting.allocations_for_group(group.id)
      |> Enum.filter(&(&1.kind == "credit"))
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(&{&1.amount_cents, &1.lot_id})

    # Two nights long: room-a requires 6,000 and room-b 2,000. The early
    # lot's 4,000 funds a first, then the late lot finishes a and funds b.
    assert Enum.map(rows, &elem(&1, 0)) == [4_000, 2_000, 1_000]
    assert Enum.at(rows, 0) |> elem(1) == lot_early.id
    assert Enum.at(rows, 1) |> elem(1) == lot_late.id
    assert Enum.at(rows, 2) |> elem(1) == lot_late.id

    data = get_group("legacy-credit")
    assert Enum.map(data["rooms"], & &1["credit_paid_cents"]) == [6_000, 1_000]
    assert data["credit_paid_cents"] == 7_000
  end

  test "backfilling never changes aggregate cash, credit, or ledger totals" do
    group = insert_group("legacy-keep", "active", 5_000)
    insert_room(group, "room-a", 15_000, 0)

    RoomAccounting.backfill()

    stored = Repo.get!(Group, group.id)
    assert stored.cash_paid_cents == 5_000
    assert stored.deposit_paid_cents == 5_000
    assert stored.deposit_due_cents == 12_000

    # The group's own columns are untouched and the ledger now agrees with
    # them: nothing paid is lost or invented by materializing allocations.
    {ledger_after, 200} = get_ledger()
    assert ledger_after["data"]["cash_held_cents"] == 5_000
    assert ledger_after["data"]["cash_refunded_cents"] == 0
    assert ledger_after["data"]["credit_liability_cents"] == 0
  end

  test "preserves settled totals for groups cancelled before the release" do
    group =
      Repo.insert!(%Group{
        group_id: "legacy-cancelled",
        guest_id: "guest-legacy",
        property_id: "p-1",
        booked_on: ~D[2026-06-05],
        arrival_on: ~D[2026-09-01],
        departure_on: ~D[2026-09-03],
        rate_plan: "flexible",
        status: "cancelled",
        revision: 3,
        policy_version: nil,
        lodging_total_cents: 30_000,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        refunded_cents: 2_000,
        retained_cents: 3_000,
        cash_converted_to_credit_cents: 1_000
      })

    insert_room(group, "room-a", 15_000, 0)

    insert_applied_payment_record("legacy-settled-pay", "legacy-cancelled", 4_000)

    RoomAccounting.backfill()

    {ledger, 200} = get_ledger()
    assert ledger["data"]["cash_refunded_cents"] == 2_000
    assert ledger["data"]["cash_retained_cents"] == 3_000
    assert ledger["data"]["cash_converted_to_credit_cents"] == 1_000

    {body, 200} = get_payment("legacy-settled-pay")

    disposition =
      body["data"]
      |> Map.take([
        "held_cents",
        "refunded_cents",
        "retained_cents",
        "converted_to_credit_cents",
        "reduced_cents",
        "charged_back_cents"
      ])
      |> Map.values()
      |> Enum.sum()

    assert disposition == body["data"]["recorded_cents"]
    assert body["data"]["original_group_id"] == "legacy-cancelled"
  end

  test "does not duplicate allocations on a second backfill run" do
    group = insert_group("legacy-idem", "active", 6_000)
    insert_room(group, "room-a", 15_000, 0)

    RoomAccounting.backfill()
    RoomAccounting.backfill()

    rows = RoomAccounting.allocations_for_group(group.id)
    assert length(rows) == 1
  end
end
