defmodule GroupStayWeb.LedgerControllerTest do
  use GroupStayWeb.ConnCase

  test "starts with zero totals", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ledger")

    assert json_response(conn, 200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
    open_group_fixture(conn)

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
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
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
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
             "cash_retained_cents" => 4000,
             "cash_converted_to_credit_cents" => 0,
             "credit_liability_cents" => 0
           }
  end

  describe "credit liability" do
    defp fund_credit(conn, cash_cents, cancel_on) do
      open_group_fixture(conn)
      pay_group(conn, "group-81", cash_cents)

      cancel_group(conn, "group-81", cancel_on, %{"refund_method" => "hotel_credit"})
    end

    test "includes issued credit", %{conn: conn} do
      fund_credit(conn, 5000, "2026-11-26")

      ledger = ledger_data(conn)
      assert ledger["cash_converted_to_credit_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5500
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_retained_cents"] == 0
    end

    test "includes credit applied to active groups", %{conn: conn} do
      fund_credit(conn, 5000, "2026-11-26")

      open_group_fixture(conn, %{"operation_id" => "op-1002", "group_id" => "group-82"})

      submit_batch(conn, [
        %{
          "operation_id" => "op-6001",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-82",
          "amount_cents" => 2000
        }
      ])

      # Applying credit redeems it into a deposit without changing liability.
      assert ledger_data(conn)["credit_liability_cents"] == 5500
    end

    test "reports expiry as of the on parameter", %{conn: conn} do
      fund_credit(conn, 5000, "2026-11-26")

      assert ledger_data(conn, %{"on" => "2027-11-26"})["credit_liability_cents"] == 5500
      assert ledger_data(conn, %{"on" => "2027-11-27"})["credit_liability_cents"] == 0
    end

    test "rejects an on parameter that cannot be parsed", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/ledger", %{"on" => "someday"})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_parameter"}}
    end
  end
end
