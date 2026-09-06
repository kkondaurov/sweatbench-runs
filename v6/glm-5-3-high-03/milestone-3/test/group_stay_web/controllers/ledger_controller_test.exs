defmodule GroupStayWeb.LedgerControllerTest do
  @moduledoc """
  Coverage of the finance totals endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  @zeroed %{
    "cash_held_cents" => 0,
    "cash_refunded_cents" => 0,
    "cash_retained_cents" => 0,
    "cash_converted_to_credit_cents" => 0,
    "credit_liability_cents" => 0
  }

  test "starts with zeroed totals" do
    assert json_response(get_ledger(), 200)["data"] == @zeroed
  end

  test "unpaid deposit requirements are not cash" do
    post_batch([open_group_operation("op-1")])

    assert json_response(get_ledger(), 200)["data"] == @zeroed
  end

  test "cash held sums the cash deposits paid across active groups" do
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
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
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
             "cash_retained_cents" => 10_000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
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
             "cash_retained_cents" => 20_000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  describe "credit liability" do
    test "includes available credit and credit applied to active groups" do
      post_batch([
        # cancel-1 issues a lot worth 11_000 to guest-22
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        # a second group funded in part by that credit
        open_group_operation("op-4", %{"group_id" => "group-82"}),
        apply_credit_operation("op-5", "group-82", 4_000, %{"occurred_on" => "2026-11-27"})
      ])

      # 7_000 available + 4_000 applied to the active group
      assert json_response(get_ledger("2026-12-01"), 200)["data"]["credit_liability_cents"] ==
               11_000
    end

    test "expiry as of the on date reduces the liability" do
      post_batch([
        # lot expires on 2027-11-27: available through 2027-11-26
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        })
      ])

      assert json_response(get_ledger("2027-11-26"), 200)["data"]["credit_liability_cents"] ==
               11_000

      assert json_response(get_ledger("2027-11-27"), 200)["data"]["credit_liability_cents"] == 0
    end

    test "without on the ledger uses the current UTC date" do
      today = Date.utc_today()

      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => Date.to_iso8601(today),
          "refund_method" => "hotel_credit"
        })
      ])

      # a lot issued today is available for 365 more days
      assert json_response(get_ledger(), 200)["data"]["credit_liability_cents"] == 11_000
    end

    test "a non-refundable cancellation consumes applied credit" do
      post_batch([
        # issue 11_000 of credit to guest-22
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 10_000),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-26",
          "refund_method" => "hotel_credit"
        }),
        # fund a non-refundable group with it and cancel
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "rate_plan" => "advance_purchase"
        }),
        apply_credit_operation("op-5", "group-82", 11_000, %{"occurred_on" => "2026-11-27"}),
        cancel_operation("op-6", "group-82", %{"occurred_on" => "2026-11-28"})
      ])

      assert json_response(get_ledger("2026-12-01"), 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 10_000,
               "credit_liability_cents" => 0
             }
    end
  end
end
