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

  defp credit_cancel_op(group_id, occurred_on) do
    Map.put(cancel_op(group_id, occurred_on), "refund_method", "hotel_credit")
  end

  defp apply_credit_op(group_id, amount_cents) do
    %{
      "operation_id" => "op-credit-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp ledger_as_of(conn, on) do
    conn |> get("/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")
  end

  test "starts with zero totals", %{conn: conn} do
    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
    submit(conn, [open_op("group-a")])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
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
             "cash_retained_cents" => 3_000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "moves converted cash out of held totals when credit is chosen", %{conn: conn} do
    submit(conn, [
      open_op("converted"),
      payment_op("converted", 2_000),
      credit_cancel_op("converted", "2026-11-26")
    ])

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 2_000,
             "credit_liability_cents" => 2_200
           }
  end

  test "counts credit applied to active groups in the liability but not as held cash", %{
    conn: conn
  } do
    submit(conn, [
      open_op("funder"),
      payment_op("funder", 2_000),
      credit_cancel_op("funder", "2026-11-26"),
      open_op("funded"),
      apply_credit_op("funded", 1_500)
    ])

    ledger = ledger(conn)
    assert ledger["cash_held_cents"] == 0
    assert ledger["credit_liability_cents"] == 2_200
  end

  test "reports credit expiry as of the on date", %{conn: conn} do
    submit(conn, [
      open_op("funder"),
      payment_op("funder", 1_000),
      credit_cancel_op("funder", "2026-10-20")
    ])

    assert ledger_as_of(conn, "2027-10-20")["credit_liability_cents"] == 1_100
    assert ledger_as_of(conn, "2027-10-21")["credit_liability_cents"] == 0
  end

  test "credit applied to an active group keeps its expiry paused", %{conn: conn} do
    submit(conn, [
      open_op("funder"),
      payment_op("funder", 1_000),
      credit_cancel_op("funder", "2026-10-20"),
      open_op("funded"),
      apply_credit_op("funded", 1_100)
    ])

    assert ledger_as_of(conn, "2027-10-20")["credit_liability_cents"] == 1_100
    assert ledger_as_of(conn, "2027-10-21")["credit_liability_cents"] == 1_100
    assert ledger(conn)["credit_liability_cents"] == 1_100
  end

  test "rejects an unusable on date", %{conn: conn} do
    response = get(conn, "/api/v1/ledger?on=soon")

    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_date"}}
  end
end
