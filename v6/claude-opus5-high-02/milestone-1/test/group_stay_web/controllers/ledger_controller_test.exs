defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "starts at zero" do
    assert read_ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "unpaid deposit requirements are not cash" do
    submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))

    assert read_ledger()["cash_held_cents"] == 0
  end

  test "holds cash applied to active reservations across groups" do
    submit([
      open_group(%{"group_id" => "group-1", "rooms" => [room("room-a", 10_000)]}),
      record_cash_payment(%{
        "operation_id" => "op-pay-1",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      }),
      open_group(%{
        "operation_id" => "op-open-2",
        "group_id" => "group-2",
        "rooms" => [room("room-a", 20_000)]
      }),
      record_cash_payment(%{
        "operation_id" => "op-pay-2",
        "group_id" => "group-2",
        "amount_cents" => 2_500
      })
    ])

    assert read_ledger() == %{
             "cash_held_cents" => 3_500,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "cancellation moves held cash to refunded or retained" do
    submit([
      open_group(%{"group_id" => "group-1", "rooms" => [room("room-a", 10_000)]}),
      record_cash_payment(%{
        "operation_id" => "op-pay-1",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      }),
      open_group(%{
        "operation_id" => "op-open-2",
        "group_id" => "group-2",
        "rate_plan" => "advance_purchase",
        "rooms" => [room("room-a", 20_000)]
      }),
      record_cash_payment(%{
        "operation_id" => "op-pay-2",
        "group_id" => "group-2",
        "amount_cents" => 2_500
      }),
      open_group(%{
        "operation_id" => "op-open-3",
        "group_id" => "group-3",
        "rooms" => [room("room-a", 30_000)]
      }),
      record_cash_payment(%{
        "operation_id" => "op-pay-3",
        "group_id" => "group-3",
        "amount_cents" => 3_000
      }),
      cancel_group(%{
        "operation_id" => "op-cancel-1",
        "group_id" => "group-1",
        "occurred_on" => "2026-11-01"
      }),
      cancel_group(%{
        "operation_id" => "op-cancel-2",
        "group_id" => "group-2",
        "occurred_on" => "2026-11-01"
      })
    ])

    assert read_ledger() == %{
             "cash_held_cents" => 3_000,
             "cash_refunded_cents" => 1_000,
             "cash_retained_cents" => 2_500
           }
  end
end
