defmodule GroupStay.AllocationsTest do
  @moduledoc """
  Covers bringing forward the funding of groups that predate room
  allocations: the unattributed senior block, the durable-record commit
  order, and the virtual views served before materialization persists.
  """

  use GroupStay.DataCase, async: false

  import Ecto.Query
  import GroupStay.PartnerHelpers

  alias GroupStay.Allocations.RoomAllocation
  alias GroupStay.Groups
  alias GroupStay.Operations
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  # Simulates a group carried over from an earlier release: its funding is
  # intact, but it has no room allocations.
  defp carry_over(group_id, delete_operation_ids \\ []) do
    group = Repo.get_by!(GroupStay.Groups.Group, group_id: group_id)

    Repo.delete_all(from a in RoomAllocation, where: a.group_id == ^group.id)
    Repo.delete_all(from r in OperationRecord, where: r.operation_id in ^delete_operation_ids)

    group
    |> Ecto.Changeset.change(%{allocations_initialized: false})
    |> Repo.update!()
  end

  defp room_funding(group_id) do
    {:ok, group} = Groups.fetch_group(group_id)

    group
    |> Groups.group_data()
    |> Map.fetch!("rooms")
    |> Map.new(&{&1["room_id"], {&1["cash_paid_cents"], &1["credit_paid_cents"]}})
  end

  defp issue_credit_lot do
    Operations.run([
      open_group_operation("credit-open", %{"group_id" => "group-x"}),
      pay_operation("credit-pay", "group-x", 10_000),
      cancel_operation("credit-cancel", "group-x", %{
        "occurred_on" => "2026-11-10",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  test "a carried-over group is read virtually until it is materialized" do
    issue_credit_lot()

    Operations.run([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 12_000),
      apply_credit_operation("op-3", "group-81", 2_000, %{"occurred_on" => "2026-11-20"})
    ])

    carry_over("group-81")

    # nothing was written, but the rooms report the virtually materialized
    # funding: the durable payment in commit order, then the credit
    assert room_funding("group-81") == %{
             "room-a" => {9_000, 0},
             "room-b" => {3_000, 2_000}
           }

    # a new payment materializes the carried-over funding first
    Operations.run([pay_operation("op-4", "group-81", 5_500)])

    assert room_funding("group-81") == %{
             "room-a" => {9_000, 0},
             "room-b" => {8_500, 2_000}
           }

    {:ok, group} = Groups.fetch_group("group-81")
    assert group.allocations_initialized

    # the materialized rows address the recorded payment: the reduction
    # removes its held cash in reverse fill order, room-b's portion first
    Operations.run([reduce_cash_operation("op-5", "op-2", 1_000)])

    assert room_funding("group-81") == %{
             "room-a" => {9_000, 0},
             "room-b" => {7_500, 2_000}
           }
  end

  test "funding without durable records becomes one unattributed senior block" do
    issue_credit_lot()

    # the credit was applied before the cash
    Operations.run([
      open_group_operation("op-1"),
      apply_credit_operation("op-2", "group-81", 2_000, %{"occurred_on" => "2026-11-20"}),
      pay_operation("op-3", "group-81", 12_000)
    ])

    # neither the credit application nor the payment left a durable record
    carry_over("group-81", ["op-2", "op-3"])

    # the block allocates its aggregate cash first, then its credit lots,
    # regardless of the order in which they were originally applied
    assert room_funding("group-81") == %{
             "room-a" => {9_000, 0},
             "room-b" => {3_000, 2_000}
           }

    # funding without a durable operation identity cannot be targeted
    assert [result] = Operations.run([reduce_cash_operation("op-4", "op-3", 100)])
    assert result["code"] == "operation_not_found"

    assert [result] = Operations.run([charge_back_operation("op-5", "op-3")])
    assert result["code"] == "operation_not_found"

    assert Operations.fetch_payment_statement("op-3") == {:error, :operation_not_found}

    # materializing through a durable operation settles the block per room
    Operations.run([
      pay_operation("op-6", "group-81", 1_000),
      cancel_rooms_operation("op-7", "group-81", ["room-a"], %{"occurred_on" => "2026-11-21"})
    ])

    assert room_funding("group-81") == %{
             "room-a" => {0, 0},
             "room-b" => {4_000, 2_000}
           }

    assert Groups.ledger_totals(~D[2026-12-01]) == %{
             "cash_held_cents" => 4_000,
             "cash_refunded_cents" => 9_000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 10_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 11_000,
             "credit_shortfall_cents" => 0
           }
  end

  test "the senior block is allocated before durable recorded funding" do
    issue_credit_lot()

    Operations.run([
      open_group_operation("op-1"),
      # this credit application predates durable operation records
      apply_credit_operation("op-2", "group-81", 2_000, %{"occurred_on" => "2026-11-20"}),
      # these payments are durably recorded
      pay_operation("op-3", "group-81", 5_000),
      pay_operation("op-4", "group-81", 7_000)
    ])

    carry_over("group-81", ["op-2"])

    # the unattributed credit block fills first, then the durable payments
    # in commit order
    Operations.run([pay_operation("op-5", "group-81", 1_000)])

    assert room_funding("group-81") == %{
             "room-a" => {7_000, 2_000},
             "room-b" => {6_000, 0}
           }

    # the durable payments are addressed through their materialized rows
    Operations.run([reduce_cash_operation("op-6", "op-3", 500)])

    assert room_funding("group-81") == %{
             "room-a" => {6_500, 2_000},
             "room-b" => {6_000, 0}
           }

    {:ok, statement} = Operations.fetch_payment_statement("op-3")

    assert statement["held_cents"] == 4_500
    assert statement["recorded_cents"] == 5_000

    # the legacy credit cannot be addressed
    assert Operations.fetch_payment_statement("op-2") == {:error, :operation_not_found}
  end

  test "a group cancelled before this release can still reconcile and charge back" do
    Operations.run([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 10_000),
      cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-20"})
    ])

    carry_over("group-81")

    assert {:ok, statement} = Operations.fetch_payment_statement("op-2")
    assert statement["refunded_cents"] == 10_000
    assert statement["held_cents"] == 0

    assert [result] = Operations.run([charge_back_operation("op-4", "op-2")])
    assert result["status"] == "applied"
    assert result["charged_back_cents"] == 10_000

    assert Groups.ledger_totals(~D[2026-12-01]) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 10_000,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert {:ok, statement} = Operations.fetch_payment_statement("op-2")
    assert statement["charged_back_cents"] == 10_000

    # the chargeback was remembered, so it cannot happen twice
    assert [result] = Operations.run([charge_back_operation("op-5", "op-2")])
    assert result["code"] == "payment_not_chargeable"
  end

  test "materializing never changes an aggregate balance" do
    issue_credit_lot()

    Operations.run([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 12_000),
      apply_credit_operation("op-3", "group-81", 2_000, %{"occurred_on" => "2026-11-20"})
    ])

    before = Groups.ledger_totals(~D[2026-12-01])
    carry_over("group-81")

    assert room_funding("group-81") == %{
             "room-a" => {9_000, 0},
             "room-b" => {3_000, 2_000}
           }

    assert Groups.ledger_totals(~D[2026-12-01]) == before
  end

  test "a carried-over group materializes when a transfer withdraws its funding" do
    issue_credit_lot()

    Operations.run([
      open_group_operation("op-1"),
      open_group_operation("op-2", %{"group_id" => "group-82"}),
      pay_operation("op-3", "group-81", 12_000),
      apply_credit_operation("op-4", "group-81", 2_000, %{"occurred_on" => "2026-11-20"})
    ])

    carry_over("group-81")

    # the transfer materializes the source group, draws room-b's funding
    # first, and fills the destination's rooms in their original order
    assert [result] =
             Operations.run([
               transfer_operation("op-5", "group-81", "group-82", 5_000)
             ])

    assert result["status"] == "applied"
    assert result["source_revision"] == 4
    assert result["destination_revision"] == 2

    assert room_funding("group-81") == %{"room-a" => {9_000, 0}, "room-b" => {0, 0}}
    assert room_funding("group-82") == %{"room-a" => {3_000, 2_000}, "room-b" => {0, 0}}

    # the payment keeps its identity across the transfer
    assert {:ok, statement} = Operations.fetch_payment_statement("op-3")
    assert statement["held_cents"] == 12_000

    assert statement["held_by_group"] == [
             %{"group_id" => "group-81", "amount_cents" => 9_000},
             %{"group_id" => "group-82", "amount_cents" => 3_000}
           ]

    # the transferred credit stays applied, in its original lot
    assert Groups.ledger_totals(~D[2026-12-01]) == %{
             "cash_held_cents" => 12_000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 10_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 11_000,
             "credit_shortfall_cents" => 0
           }
  end
end
