defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  test "starts with zero totals" do
    assert get_ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "tracks held cash and moves it on cancellation across groups" do
    submit([
      open_group_op(%{"group_id" => "refund-me"}),
      open_group_op(%{"group_id" => "keep-it", "rate_plan" => "advance_purchase"}),
      open_group_op(%{"group_id" => "still-open"}),
      open_group_op(%{"group_id" => "unpaid"}),
      payment_op(%{"group_id" => "refund-me", "amount_cents" => 1000}),
      payment_op(%{"group_id" => "refund-me", "amount_cents" => 500}),
      payment_op(%{"group_id" => "keep-it", "amount_cents" => 20_000}),
      payment_op(%{"group_id" => "still-open", "amount_cents" => 300})
    ])

    assert get_ledger() == %{
             "cash_held_cents" => 21_800,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }

    submit([
      cancel_op(%{"group_id" => "refund-me"}),
      cancel_op(%{"group_id" => "keep-it"}),
      cancel_op(%{"group_id" => "unpaid"}),
      payment_op(%{"group_id" => "still-open", "amount_cents" => 0})
    ])

    assert get_ledger() == %{
             "cash_held_cents" => 300,
             "cash_refunded_cents" => 1500,
             "cash_retained_cents" => 20_000
           }
  end
end
