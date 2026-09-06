defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  test "starts with zero totals", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
           }
  end

  test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
    open_group_fixture(conn)

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "tracks cash across payments and cancellations", %{conn: conn} do
    open_group_fixture(conn)
    open_group_fixture(conn, %{"operation_id" => "op-1002", "group_id" => "group-82"})

    pay = fn group_id, operation_id ->
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "amount_cents" => 4000
      }
    end

    submit_batch(conn, [pay.("group-81", "op-2001"), pay.("group-82", "op-2002")])
    assert ledger_data(conn)["cash_held_cents"] == 8000

    submit_batch(conn, [
      %{
        "operation_id" => "op-4001",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      }
    ])

    assert ledger_data(conn) == %{
             "cash_held_cents" => 4000,
             "cash_refunded_cents" => 4000,
             "cash_retained_cents" => 0
           }

    submit_batch(conn, [
      %{
        "operation_id" => "op-4002",
        "type" => "cancel_group",
        "occurred_on" => "2026-12-09",
        "group_id" => "group-82"
      }
    ])

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 4000,
             "cash_retained_cents" => 4000
           }
  end
end
