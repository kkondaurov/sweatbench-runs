defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp open_group(conn, group_id, rate_plan \\ "flexible") do
    [result] =
      conn
      |> submit([
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
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert result["status"] == "applied"
    :ok
  end

  defp pay(conn, group_id, amount_cents, op_id) do
    [result] =
      conn
      |> submit([
        %{
          "operation_id" => op_id,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert result["status"] == "applied"
    :ok
  end

  defp cancel(conn, group_id, occurred_on, op_id) do
    [result] =
      conn
      |> submit([
        %{
          "operation_id" => op_id,
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id
        }
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert result["status"] == "applied"
    result
  end

  test "starts at zero", %{conn: conn} do
    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cash applied to active reservations is held", %{conn: conn} do
    open_group(conn, "group-1")
    open_group(conn, "group-2")
    pay(conn, "group-1", 1000, "op-pay-1")
    pay(conn, "group-1", 500, "op-pay-2")
    pay(conn, "group-2", 2000, "op-pay-3")

    assert ledger(conn) == %{
             "cash_held_cents" => 3500,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "cancellation moves held cash to refunded or retained", %{conn: conn} do
    open_group(conn, "group-refund")
    open_group(conn, "group-retain")
    open_group(conn, "group-stays")
    pay(conn, "group-refund", 1000, "op-pay-1")
    pay(conn, "group-retain", 2000, "op-pay-2")
    pay(conn, "group-stays", 3000, "op-pay-3")

    # 14 days before arrival: refunded. 13 days out: retained.
    cancel(conn, "group-refund", "2026-11-26", "op-cancel-1")
    cancel(conn, "group-retain", "2026-11-27", "op-cancel-2")

    assert ledger(conn) == %{
             "cash_held_cents" => 3000,
             "cash_refunded_cents" => 1000,
             "cash_retained_cents" => 2000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
    open_group(conn, "group-1")
    # Deposit due is 6000 (3 nights at 10000, flexible), but no cash moved.
    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end
end
