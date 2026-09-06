defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase

  defp fund_credit(conn, suffix, cash_cents, cancel_on, open_on \\ "2026-10-03") do
    group_id = "group-fund-#{suffix}"

    open_group_fixture(conn, %{
      "operation_id" => "op-open-fund-#{suffix}",
      "group_id" => group_id,
      "occurred_on" => open_on
    })

    pay_group(conn, group_id, cash_cents)
    cancel_group(conn, group_id, cancel_on, %{"refund_method" => "hotel_credit"})
  end

  test "returns zero credit for a guest with no lots", %{conn: conn} do
    assert guest_credit_data(conn, "guest-22") == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "returns lots ordered by expiry, then source operation", %{conn: conn} do
    fund_credit(conn, "later", 1000, "2026-11-26")
    fund_credit(conn, "sooner", 2000, "2026-11-20")
    fund_credit(conn, "also-later", 500, "2026-11-26")

    data = guest_credit_data(conn, "guest-22")
    assert data["available_cents"] == 3850

    assert Enum.map(data["lots"], & &1["source_operation_id"]) == [
             "op-cancel-group-fund-sooner",
             "op-cancel-group-fund-also-later",
             "op-cancel-group-fund-later"
           ]

    assert Enum.map(data["lots"], & &1["expires_on"]) == [
             "2027-11-20",
             "2027-11-26",
             "2027-11-26"
           ]
  end

  test "omits exhausted lots", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")
    open_group_fixture(conn)

    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-apply-all",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-81",
          "amount_cents" => 5500
        }
      ])

    assert result["status"] == "applied"
    assert guest_credit_data(conn, "guest-22")["lots"] == []
    assert guest_credit_data(conn, "guest-22")["available_cents"] == 0
  end

  test "reports expiry as of the on parameter", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")

    # The lot expires on 2027-11-26: available through that date, expired the
    # following day.
    assert guest_credit_data(conn, "guest-22", %{"on" => "2027-11-26"})["available_cents"] ==
             5500

    assert guest_credit_data(conn, "guest-22", %{"on" => "2027-11-27"})["available_cents"] == 0
    assert guest_credit_data(conn, "guest-22", %{"on" => "2027-11-27"})["lots"] == []
  end

  test "omits lots already expired on the current date", %{conn: conn} do
    fund_credit(conn, "old", 2000, "2025-01-01", "2024-12-01")

    # The lot expired on 2026-01-01, but is still visible as of earlier dates.
    assert guest_credit_data(conn, "guest-22")["available_cents"] == 0

    assert guest_credit_data(conn, "guest-22", %{"on" => "2025-06-01"})["available_cents"] ==
             2200
  end

  test "rejects an on parameter that cannot be parsed", %{conn: conn} do
    conn = get(conn, "/api/v1/guests/guest-22/credit", %{"on" => "soon"})

    assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_parameter"}}
  end
end
