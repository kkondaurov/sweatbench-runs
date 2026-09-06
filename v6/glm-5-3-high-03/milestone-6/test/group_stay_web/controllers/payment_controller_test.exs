defmodule GroupStayWeb.PaymentControllerTest do
  @moduledoc """
  Coverage of the payment reconciliation endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  test "returns the current disposition of one payment's cash" do
    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 6_000),
      pay_operation("op-3", "group-81", 4_000),
      reduce_cash_operation("op-4", "op-3", 1_000),
      cancel_rooms_operation("op-5", "group-81", ["room-a"], %{"occurred_on" => "2026-11-20"}),
      charge_back_operation("op-6", "op-2")
    ])

    assert json_response(get_payment("op-2"), 200) == %{
             "data" => %{
               "payment_operation_id" => "op-2",
               "original_group_id" => "group-81",
               "recorded_cents" => 6_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 6_000
             }
           }

    assert json_response(get_payment("op-3"), 200)["data"] == %{
             "payment_operation_id" => "op-3",
             "original_group_id" => "group-81",
             "recorded_cents" => 4_000,
             "held_cents" => 0,
             "refunded_cents" => 3_000,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 1_000,
             "charged_back_cents" => 0
           }

    # the statements agree with the ledger: recorded cash equals held,
    # refunded, retained, converted, reduced, and charged-back cash
    assert json_response(get_ledger("2026-12-01"), 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 3_000,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 1_000,
             "cash_charged_back_cents" => 6_000,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "all seven monetary fields are present, including when zero" do
    post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 6_000)])

    assert json_response(get_payment("op-2"), 200)["data"] == %{
             "payment_operation_id" => "op-2",
             "original_group_id" => "group-81",
             "recorded_cents" => 6_000,
             "held_cents" => 6_000,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }
  end

  test "the disposition fields sum exactly to the recorded amount" do
    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 6_000),
      pay_operation("op-3", "group-81", 4_000),
      reduce_cash_operation("op-4", "op-3", 1_000),
      charge_back_operation("op-5", "op-3")
    ])

    data = json_response(get_payment("op-3"), 200)["data"]

    assert data["held_cents"] + data["refunded_cents"] + data["retained_cents"] +
             data["converted_to_credit_cents"] + data["reduced_cents"] +
             data["charged_back_cents"] == data["recorded_cents"]
  end

  test "reading a statement never changes state" do
    post_batch([open_group_operation("op-1"), pay_operation("op-2", "group-81", 6_000)])

    statement = json_response(get_payment("op-2"), 200)["data"]
    group = json_response(get_group("group-81"), 200)["data"]
    ledger = json_response(get_ledger("2026-12-01"), 200)["data"]

    assert json_response(get_payment("op-2"), 200)["data"] == statement
    assert json_response(get_group("group-81"), 200)["data"] == group
    assert json_response(get_ledger("2026-12-01"), 200)["data"] == ledger
  end

  test "a payment fully held on active rooms agrees with the room view" do
    post_batch([
      open_group_operation("op-1", %{
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
          %{"room_id" => "room-c", "nightly_rate_cents" => 10_000}
        ]
      }),
      pay_operation("op-2", "group-81", 14_000)
    ])

    # room deposits: 9_000 + 10_500 + 6_000
    data = json_response(get_group("group-81"), 200)["data"]
    held_on_rooms = Enum.sum(Enum.map(data["rooms"], & &1["cash_paid_cents"]))

    assert json_response(get_payment("op-2"), 200)["data"]["held_cents"] == held_on_rooms
    assert data["deposit_paid_cents"] == held_on_rooms
  end

  test "a missing record returns 404 operation_not_found" do
    assert json_response(get_payment("op-none"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "a record that is not an applied cash payment returns 422" do
    post_batch([
      open_group_operation("op-1"),
      pay_operation("op-2", "group-81", 99_999),
      cancel_operation("op-3", "group-81")
    ])

    # an open_group record
    assert json_response(get_payment("op-1"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }

    # a rejected payment
    assert json_response(get_payment("op-2"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }

    # a cancellation record
    assert json_response(get_payment("op-3"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end
end
