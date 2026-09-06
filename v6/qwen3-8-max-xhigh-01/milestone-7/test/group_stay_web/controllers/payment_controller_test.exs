defmodule GroupStayWeb.PaymentControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"
  @payments_path "/api/v1/payments"

  defp open_group_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  defp open_group(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [open_group_op(overrides)])
    assert %{"status" => "applied"} = result
    {conn, result}
  end

  defp pay(conn, op_id, group_id, amount_cents) do
    {conn, [result]} =
      post_batch(conn, [
        %{
          "operation_id" => op_id,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp get_payment(conn, payment_operation_id) do
    conn = get(conn, "#{@payments_path}/#{payment_operation_id}")
    {conn, conn.status, json_response(conn, conn.status)}
  end

  test "returns the full disposition of an applied payment", %{conn: conn} do
    {conn, _} = open_group(conn)
    conn = pay(conn, "pay-1", "group-81", 5000)

    {_conn, status, body} = get_payment(conn, "pay-1")

    assert status == 200

    assert body == %{
             "data" => %{
               "payment_operation_id" => "pay-1",
               "original_group_id" => "group-81",
               "recorded_cents" => 5000,
               "held_cents" => 5000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
           }
  end

  test "the six dispositions always sum to the recorded amount", %{conn: conn} do
    {conn, _} = open_group(conn)
    conn = pay(conn, "pay-1", "group-81", 5000)

    {conn, [_]} =
      post_batch(conn, [
        %{
          "operation_id" => "reduce-1",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-1",
          "amount_cents" => 1500
        }
      ])

    {conn, [_]} =
      post_batch(conn, [
        %{
          "operation_id" => "chargeback-1",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "pay-1"
        }
      ])

    {_conn, status, body} = get_payment(conn, "pay-1")
    assert status == 200
    data = body["data"]

    assert data["held_cents"] + data["refunded_cents"] + data["retained_cents"] +
             data["converted_to_credit_cents"] + data["reduced_cents"] +
             data["charged_back_cents"] == data["recorded_cents"]

    assert data["reduced_cents"] == 1500
    assert data["charged_back_cents"] == 3500
  end

  test "reflects refunded cash after a refundable cancellation", %{conn: conn} do
    {conn, _} = open_group(conn)
    conn = pay(conn, "pay-1", "group-81", 5000)

    {conn, [_]} =
      post_batch(conn, [
        %{
          "operation_id" => "cancel-1",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81"
        }
      ])

    {_conn, status, body} = get_payment(conn, "pay-1")
    assert status == 200
    assert body["data"]["refunded_cents"] == 5000
    assert body["data"]["held_cents"] == 0
  end

  test "returns 404 for an unknown payment operation", %{conn: conn} do
    {_conn, status, body} = get_payment(conn, "nope")
    assert status == 404
    assert body == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "returns 422 for a record that is not an applied cash payment", %{conn: conn} do
    {conn, _} = open_group(conn)

    {_conn, status, body} = get_payment(conn, "op-open")
    assert status == 422
    assert body == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end

  test "returns 422 for a rejected payment", %{conn: conn} do
    {conn, _} = open_group(conn)

    {conn, [_]} =
      post_batch(conn, [
        %{
          "operation_id" => "pay-bad",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -5
        }
      ])

    {_conn, status, body} = get_payment(conn, "pay-bad")
    assert status == 422
    assert body == %{"error" => %{"code" => "payment_not_reconcilable"}}
  end
end
