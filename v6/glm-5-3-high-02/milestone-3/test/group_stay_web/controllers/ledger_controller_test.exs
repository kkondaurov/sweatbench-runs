defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: true

  @occurred_on "2026-10-03"

  defp submit!(conn, operations) do
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    assert conn.status == 200
    json_response(conn, 200)["results"]
  end

  defp open_operation(group_id, rate_plan \\ "flexible") do
    %{
      "operation_id" => "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => rate_plan,
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  defp payment_operation(group_id, amount_cents) do
    %{
      "operation_id" => "op-pay-#{group_id}-#{amount_cents}",
      "type" => "record_cash_payment",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id, occurred_on) do
    %{
      "operation_id" => "op-cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp ledger do
    conn = get(build_conn(), "/api/v1/ledger")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  test "an empty ledger reports zeros" do
    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "unpaid deposit requirements are not cash" do
    conn = build_conn()
    submit!(conn, [open_operation("group-unpaid")])

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cash held is the sum of cash applied to active groups" do
    conn = build_conn()
    submit!(conn, [open_operation("group-one")])
    submit!(conn, [open_operation("group-two")])
    submit!(conn, [payment_operation("group-one", 5000)])
    submit!(conn, [payment_operation("group-two", 3000)])

    assert ledger()["cash_held_cents"] == 8000
  end

  test "cancellation moves cash from held to refunded or retained" do
    conn = build_conn()

    # Refundable: cancelled 14+ days before arrival.
    submit!(conn, [open_operation("group-early")])
    submit!(conn, [payment_operation("group-early", 5000)])
    submit!(conn, [cancel_operation("group-early", "2026-11-20")])

    # Non-refundable: cancelled inside 14 days.
    submit!(conn, [open_operation("group-late")])
    submit!(conn, [payment_operation("group-late", 2000)])
    submit!(conn, [cancel_operation("group-late", "2026-12-01")])

    # Still active.
    submit!(conn, [open_operation("group-active")])
    submit!(conn, [payment_operation("group-active", 1000)])

    assert ledger() == %{
             "cash_held_cents" => 1000,
             "cash_refunded_cents" => 5000,
             "cash_retained_cents" => 2000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end
end
