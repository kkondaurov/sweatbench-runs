defmodule GroupStayWeb.LedgerControllerTest do
  @moduledoc """
  Coverage of the finance totals endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  test "starts with zeroed totals" do
    assert json_response(get_ledger(), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "unpaid deposit requirements are not cash" do
    post_batch([open_group_operation("op-1")])

    assert json_response(get_ledger(), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "cash held sums the deposits paid across active groups" do
    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 5_000),
      open_group_operation("op-3", %{"group_id" => "group-82"}),
      pay_operation("op-4", "group-82", 6_000)
    ])

    assert json_response(get_ledger(), 200)["data"]["cash_held_cents"] == 11_000
  end

  test "a refundable cancellation moves cash to refunded" do
    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 10_000),
      cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-26"})
    ])

    assert json_response(get_ledger(), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 10_000,
             "cash_retained_cents" => 0
           }
  end

  test "a non-refundable cancellation moves cash to retained" do
    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 10_000),
      cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-12-01"})
    ])

    assert json_response(get_ledger(), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 10_000
           }
  end

  test "totals combine several groups and keep active cash held" do
    post_batch([
      # refunded: cancelled 14 days out
      open_group_operation("op-1", %{"group_id" => "group-refunded"}),
      pay_operation("op-2", "group-refunded", 4_000),
      cancel_operation("op-3", "group-refunded", %{"occurred_on" => "2026-11-26"}),
      # retained: advance purchase
      open_group_operation("op-4", %{
        "group_id" => "group-retained",
        "rate_plan" => "advance_purchase"
      }),
      pay_operation("op-5", "group-retained", 20_000),
      cancel_operation("op-6", "group-retained"),
      # still active
      open_group_operation("op-7", %{"group_id" => "group-active"}),
      pay_operation("op-8", "group-active", 3_000)
    ])

    assert json_response(get_ledger(), 200)["data"] == %{
             "cash_held_cents" => 3_000,
             "cash_refunded_cents" => 4_000,
             "cash_retained_cents" => 20_000
           }
  end
end
