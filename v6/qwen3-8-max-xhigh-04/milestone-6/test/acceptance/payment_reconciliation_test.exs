defmodule GroupStayWeb.Acceptance.PaymentReconciliationTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
      },
      overrides
    )
  end

  defp pay_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp payment(conn, payment_operation_id) do
    get(conn, "/api/v1/payments/#{payment_operation_id}")
  end

  test "returns all seven monetary fields for a freshly applied payment" do
    submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

    conn = payment(build_conn(), "pay-1")

    assert json_response(conn, 200) == %{
             "data" => %{
               "payment_operation_id" => "pay-1",
               "original_group_id" => "group-a",
               "recorded_cents" => 3000,
               "held_cents" => 3000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }
  end

  test "dispositions always sum to recorded_cents" do
    submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 4000)])

    # Reduce 1000, then cancel refundably (refunds the 3000 still held).
    submit(build_conn(), [
      %{
        "operation_id" => "reduce-1",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 1000
      }
    ])

    submit(build_conn(), [
      %{
        "operation_id" => "cancel-group-a",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-a"
      }
    ])

    %{"data" => statement} = json_response(payment(build_conn(), "pay-1"), 200)

    assert statement["recorded_cents"] == 4000

    assert statement["held_cents"] + statement["refunded_cents"] + statement["retained_cents"] +
             statement["converted_to_credit_cents"] + statement["reduced_cents"] +
             statement["charged_back_cents"] == statement["recorded_cents"]

    assert statement["refunded_cents"] == 3000
    assert statement["reduced_cents"] == 1000
  end

  test "reflects a chargeback" do
    submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

    submit(build_conn(), [
      %{
        "operation_id" => "cb-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "pay-1"
      }
    ])

    %{"data" => statement} = json_response(payment(build_conn(), "pay-1"), 200)
    assert statement["held_cents"] == 0
    assert statement["charged_back_cents"] == 3000
    assert statement["recorded_cents"] == 3000
  end

  test "reflects converted credit" do
    submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

    submit(build_conn(), [
      %{
        "operation_id" => "cancel-group-a",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-a",
        "refund_method" => "hotel_credit"
      }
    ])

    %{"data" => statement} = json_response(payment(build_conn(), "pay-1"), 200)
    assert statement["converted_to_credit_cents"] == 3000
    assert statement["held_cents"] == 0
  end

  test "reading a statement never changes state" do
    submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 3000)])

    ledger_before = json_response(get(build_conn(), "/api/v1/ledger"), 200)
    group_before = json_response(get(build_conn(), "/api/v1/groups/group-a"), 200)

    payment(build_conn(), "pay-1") |> json_response(200)
    payment(build_conn(), "pay-1") |> json_response(200)

    assert json_response(get(build_conn(), "/api/v1/ledger"), 200) == ledger_before
    assert json_response(get(build_conn(), "/api/v1/groups/group-a"), 200) == group_before
  end

  test "a missing operation returns 404 operation_not_found" do
    conn = payment(build_conn(), "never-seen")

    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "a non-payment record returns 422 payment_not_reconcilable" do
    submit(build_conn(), [open_op("group-a")])

    conn = payment(build_conn(), "open-group-a")

    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "a rejected payment returns 422 payment_not_reconcilable" do
    submit(build_conn(), [open_op("group-a")])
    submit(build_conn(), [pay_op("pay-bad", "group-a", 0)])

    conn = payment(build_conn(), "pay-bad")

    assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end
end
