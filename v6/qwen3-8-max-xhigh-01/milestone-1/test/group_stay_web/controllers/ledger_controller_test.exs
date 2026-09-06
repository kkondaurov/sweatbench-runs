defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"
  @ledger_path "/api/v1/ledger"

  defp submit(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  defp open_group(conn, group_id, rate_plan \\ "flexible") do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "open-#{group_id}",
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

    assert result["status"] == "applied"
    {conn, result}
  end

  defp pay(conn, group_id, amount_cents) do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "pay-#{group_id}-#{amount_cents}",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp cancel(conn, group_id, occurred_on \\ "2026-10-04") do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "cancel-#{group_id}",
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp ledger(conn) do
    conn = get(conn, @ledger_path)
    {conn, json_response(conn, 200)["data"]}
  end

  test "starts at zero", %{conn: conn} do
    {_conn, data} = ledger(conn)

    assert data == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "unpaid deposit requirements are not cash", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    {_conn, data} = ledger(conn)
    assert data["cash_held_cents"] == 0
  end

  test "cash payments are held while the group is active", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    {conn, _} = open_group(conn, "group-b")
    conn = pay(conn, "group-a", 4000)
    conn = pay(conn, "group-b", 2500)

    {_conn, data} = ledger(conn)
    assert data["cash_held_cents"] == 6500
    assert data["cash_refunded_cents"] == 0
    assert data["cash_retained_cents"] == 0
  end

  test "a refundable cancellation moves held cash to refunded", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    conn = pay(conn, "group-a", 4000)
    # arrival 2026-12-10, cancelled 2026-10-04: well outside the 14-day window
    conn = cancel(conn, "group-a")

    {_conn, data} = ledger(conn)
    assert data["cash_held_cents"] == 0
    assert data["cash_refunded_cents"] == 4000
    assert data["cash_retained_cents"] == 0
  end

  test "a non-refundable cancellation moves held cash to retained", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a", "advance_purchase")
    conn = pay(conn, "group-a", 4000)
    conn = cancel(conn, "group-a")

    {_conn, data} = ledger(conn)
    assert data["cash_held_cents"] == 0
    assert data["cash_refunded_cents"] == 0
    assert data["cash_retained_cents"] == 4000
  end

  test "settles each group independently", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    {conn, _} = open_group(conn, "group-b", "advance_purchase")
    {conn, _} = open_group(conn, "group-c")
    conn = pay(conn, "group-a", 1000)
    conn = pay(conn, "group-b", 2000)
    conn = pay(conn, "group-c", 3000)
    conn = cancel(conn, "group-a")
    conn = cancel(conn, "group-b")

    {_conn, data} = ledger(conn)
    assert data["cash_held_cents"] == 3000
    assert data["cash_refunded_cents"] == 1000
    assert data["cash_retained_cents"] == 2000
  end
end
