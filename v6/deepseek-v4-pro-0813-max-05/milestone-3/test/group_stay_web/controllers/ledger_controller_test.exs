defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  test "starts at zero", %{conn: conn} do
    assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "holds cash applied to active reservations", %{conn: conn} do
    open_group!(conn)
    json_post(conn, payment(%{"amount_cents" => 12_345}))

    assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 12_345,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "cancellation moves held cash to refunded or retained", %{conn: conn} do
    open_group!(conn)
    json_post(conn, payment(%{"amount_cents" => 5_000}))
    json_post(conn, cancel())

    ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
    assert ledger["cash_refunded_cents"] == 5_000
    assert ledger["cash_held_cents"] == 0

    submit(conn, [open_group(%{"operation_id" => "op-open-2", "group_id" => "group-2"})])

    json_post(
      conn,
      payment(%{"operation_id" => "op-pay-2", "group_id" => "group-2", "amount_cents" => 7_000})
    )

    json_post(
      conn,
      cancel(%{
        "operation_id" => "op-cancel-2",
        "group_id" => "group-2",
        "occurred_on" => "2026-12-05"
      })
    )

    ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 5_000,
             "cash_retained_cents" => 7_000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           } = ledger
  end

  test "unpaid deposit requirements never appear in finance totals", %{conn: conn} do
    submit(conn, [open_group()])

    assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "rejects an unusable on date with invalid_date", %{conn: conn} do
    for on <- ["soon", "2026-02-30"] do
      assert json_response(get(conn, "/api/v1/ledger?on=#{on}"), 422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end
end
