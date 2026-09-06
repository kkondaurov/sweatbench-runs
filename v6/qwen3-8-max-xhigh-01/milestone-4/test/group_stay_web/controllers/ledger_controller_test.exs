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

  defp cancel_for_credit(conn, group_id, occurred_on \\ "2026-10-04") do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "cancel-#{group_id}",
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "refund_method" => "hotel_credit"
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp apply_credit(conn, group_id, amount_cents, occurred_on \\ "2026-10-05") do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "credit-#{group_id}-#{amount_cents}",
          "type" => "apply_hotel_credit",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp ledger(conn) do
    conn = get(conn, @ledger_path)
    {conn, json_response(conn, 200)["data"]}
  end

  defp ledger_on(conn, on) do
    conn = get(conn, @ledger_path, %{"on" => on})
    {conn, json_response(conn, 200)["data"]}
  end

  test "starts at zero", %{conn: conn} do
    {_conn, data} = ledger(conn)

    assert data == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
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

  test "hotel-credit cancellations move held cash to the converted total", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    {conn, _} = open_group(conn, "group-b")
    conn = pay(conn, "group-a", 4000)
    conn = pay(conn, "group-b", 2500)
    conn = cancel_for_credit(conn, "group-a")
    conn = cancel_for_credit(conn, "group-b")

    {_conn, data} = ledger_on(conn, "2026-10-04")
    assert data["cash_held_cents"] == 0
    assert data["cash_refunded_cents"] == 0
    assert data["cash_retained_cents"] == 0
    assert data["cash_converted_to_credit_cents"] == 6500
    # 110% of each cash amount: 4400 + 2750
    assert data["credit_liability_cents"] == 7150
  end

  test "credit applied to an active group stays in the liability", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    conn = pay(conn, "group-a", 4000)
    conn = cancel_for_credit(conn, "group-a")
    {conn, _} = open_group(conn, "group-b")
    conn = apply_credit(conn, "group-b", 3000)

    {conn, data} = ledger_on(conn, "2026-10-05")
    assert data["credit_liability_cents"] == 4400
    assert data["cash_held_cents"] == 0

    # a refundable cancellation restores the credit without changing liability
    conn = cancel(conn, "group-b")

    {_conn, after_restore} = ledger_on(conn, "2026-10-05")
    assert after_restore["credit_liability_cents"] == 4400
  end

  test "the on parameter reports lot expiry as of a date", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    conn = pay(conn, "group-a", 4000)
    # lot expires 2027-10-05
    conn = cancel_for_credit(conn, "group-a")

    {conn, before_expiry} = ledger_on(conn, "2027-10-04")
    assert before_expiry["credit_liability_cents"] == 4400

    {_conn, after_expiry} = ledger_on(conn, "2027-10-05")
    assert after_expiry["credit_liability_cents"] == 0
  end

  test "non-refundable consumption reduces the liability", %{conn: conn} do
    {conn, _} = open_group(conn, "group-a")
    conn = pay(conn, "group-a", 4000)
    conn = cancel_for_credit(conn, "group-a")
    {conn, _} = open_group(conn, "group-b")
    conn = apply_credit(conn, "group-b", 3000)

    # arrival 2026-12-10: cancelled inside the 14-day window
    conn = cancel(conn, "group-b", "2026-11-27")

    {_conn, data} = ledger_on(conn, "2026-11-27")
    assert data["credit_liability_cents"] == 1400
  end

  test "rejects an unusable on parameter", %{conn: conn} do
    for params <- [%{"on" => "not-a-date"}, %{"on" => "2026-13-01"}, %{"on" => 42}] do
      conn = get(conn, @ledger_path, params)
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end
end
