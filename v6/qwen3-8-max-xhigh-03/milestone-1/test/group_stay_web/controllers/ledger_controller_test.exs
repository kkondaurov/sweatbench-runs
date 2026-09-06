defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp open_op(group_id, rate_plan \\ "flexible") do
    %{
      "operation_id" => "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
    }
  end

  defp payment_op(group_id, amount_cents) do
    %{
      "operation_id" => "op-pay-#{group_id}-#{amount_cents}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(group_id, occurred_on) do
    %{
      "operation_id" => "op-cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  test "starts with zero totals", %{conn: conn} do
    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
    submit(conn, [open_op("group-a")])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "counts cash applied to active reservations as held", %{conn: conn} do
    submit(conn, [open_op("group-a"), open_op("group-b"), payment_op("group-a", 2_000)])

    assert ledger(conn)["cash_held_cents"] == 2_000
  end

  test "moves held cash to refunded or retained on cancellation", %{conn: conn} do
    submit(conn, [
      open_op("refundable"),
      open_op("retained"),
      payment_op("refundable", 2_000),
      payment_op("retained", 3_000),
      # 2026-11-26 is 14 days before arrival: refundable for a flexible group.
      cancel_op("refundable", "2026-11-26"),
      # 2026-12-01 is inside the refund window: non-refundable.
      cancel_op("retained", "2026-12-01")
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 2_000,
             "cash_retained_cents" => 3_000
           }
  end
end
