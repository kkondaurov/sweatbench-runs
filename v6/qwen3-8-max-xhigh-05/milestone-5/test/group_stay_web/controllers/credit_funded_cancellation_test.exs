defmodule GroupStayWeb.CreditFundedCancellationTest do
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

  defp open_target(conn, overrides \\ %{}) do
    open_group_fixture(
      conn,
      Map.merge(
        %{
          "operation_id" => "op-open-target",
          "group_id" => "group-target",
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23"
        },
        overrides
      )
    )
  end

  defp apply_credit(conn, amount_cents, occurred_on \\ "2026-11-27") do
    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-apply-target",
          "type" => "apply_hotel_credit",
          "occurred_on" => occurred_on,
          "group_id" => "group-target",
          "amount_cents" => amount_cents
        }
      ])

    result
  end

  test "refundable cash cancellation restores applied credit to its original lot", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")
    open_target(conn)
    assert apply_credit(conn, 3300)["status"] == "applied"

    result = cancel_group(conn, "group-target", "2026-11-30")

    assert result["status"] == "applied"
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0
    assert result["credit_issued_cents"] == 0

    # The restored credit returns to its original lot, expiry, and amount:
    # no second bonus is applied.
    assert guest_credit_data(conn, "guest-22") == %{
             "guest_id" => "guest-22",
             "available_cents" => 5500,
             "lots" => [
               %{
                 "source_operation_id" => "op-cancel-group-fund-a",
                 "remaining_cents" => 5500,
                 "expires_on" => "2027-11-26"
               }
             ]
           }

    assert ledger_data(conn)["credit_liability_cents"] == 5500
  end

  test "refundable cash cancellation refunds cash and restores credit together", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")
    open_target(conn)
    pay_group(conn, "group-target", 2000)
    assert apply_credit(conn, 1000)["status"] == "applied"

    result = cancel_group(conn, "group-target", "2026-11-30")

    assert result["refunded_cents"] == 2000
    assert result["retained_cents"] == 0
    assert result["credit_issued_cents"] == 0

    assert guest_credit_data(conn, "guest-22")["available_cents"] == 5500
    assert ledger_data(conn)["cash_refunded_cents"] == 2000
    assert ledger_data(conn)["credit_liability_cents"] == 5500
  end

  test "refundable hotel-credit cancellation converts cash and restores credit", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")
    open_target(conn)
    pay_group(conn, "group-target", 2000)
    assert apply_credit(conn, 1000)["status"] == "applied"

    result =
      cancel_group(conn, "group-target", "2026-11-30", %{"refund_method" => "hotel_credit"})

    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 0
    assert result["credit_issued_cents"] == 2200

    credit = guest_credit_data(conn, "guest-22")
    assert credit["available_cents"] == 7700

    assert credit["lots"] == [
             %{
               "source_operation_id" => "op-cancel-group-fund-a",
               "remaining_cents" => 5500,
               "expires_on" => "2027-11-26"
             },
             %{
               "source_operation_id" => "op-cancel-group-target",
               "remaining_cents" => 2200,
               "expires_on" => "2027-11-30"
             }
           ]

    ledger = ledger_data(conn)
    assert ledger["cash_converted_to_credit_cents"] == 7000
    assert ledger["credit_liability_cents"] == 7700
    assert ledger["cash_held_cents"] == 0
  end

  test "credit restored after its lot expiry expires immediately", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")

    open_target(conn, %{
      "occurred_on" => "2026-11-27",
      "arrival_on" => "2027-12-20",
      "departure_on" => "2027-12-23"
    })

    assert apply_credit(conn, 3000, "2026-11-28")["status"] == "applied"

    # Past the lot expiry of 2027-11-26, only the paused application remains
    # in the liability.
    assert ledger_data(conn, %{"on" => "2027-12-01"})["credit_liability_cents"] == 3000

    # Cancellation on 2027-12-01 is refundable (19 days before arrival), but
    # the restored amount's expiry has already passed.
    result = cancel_group(conn, "group-target", "2027-12-01")

    assert result["status"] == "applied"
    assert result["refunded_cents"] == 0
    assert result["credit_issued_cents"] == 0

    assert ledger_data(conn, %{"on" => "2027-12-01"})["credit_liability_cents"] == 0
    assert guest_credit_data(conn, "guest-22", %{"on" => "2027-12-01"})["available_cents"] == 0
  end

  test "credit restored before its lot expiry becomes available again", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")
    open_target(conn)
    assert apply_credit(conn, 3000)["status"] == "applied"

    assert guest_credit_data(conn, "guest-22")["available_cents"] == 2500

    cancel_group(conn, "group-target", "2026-11-30")

    assert guest_credit_data(conn, "guest-22")["available_cents"] == 5500
    assert ledger_data(conn)["credit_liability_cents"] == 5500
  end

  test "credit restored exactly on its lot expiry is still available", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")

    open_target(conn, %{
      "occurred_on" => "2026-11-27",
      "arrival_on" => "2027-12-10",
      "departure_on" => "2027-12-13"
    })

    assert apply_credit(conn, 3000, "2026-11-28")["status"] == "applied"

    # The lot expires on 2027-11-26; cancellation on that date is refundable
    # (14 days before arrival) and the expiry has not yet passed.
    result = cancel_group(conn, "group-target", "2027-11-26")

    assert result["status"] == "applied"

    assert guest_credit_data(conn, "guest-22", %{"on" => "2027-11-26"})["available_cents"] ==
             5500

    assert guest_credit_data(conn, "guest-22", %{"on" => "2027-11-27"})["available_cents"] == 0
  end

  test "non-refundable cancellation consumes applied credit", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")
    open_target(conn)
    pay_group(conn, "group-target", 1000)
    assert apply_credit(conn, 1500)["status"] == "applied"

    # 2026-12-09 is inside the 14-day window for the 2026-12-10 arrival.
    result = cancel_group(conn, "group-target", "2026-12-09")

    assert result["status"] == "applied"
    assert result["refunded_cents"] == 0
    assert result["retained_cents"] == 1000
    assert result["credit_issued_cents"] == 0

    # The consumed credit never becomes available again.
    assert guest_credit_data(conn, "guest-22")["available_cents"] == 4000

    assert ledger_data(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 1000,
             "cash_converted_to_credit_cents" => 5000,
             "credit_liability_cents" => 4000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_shortfall_cents" => 0
           }
  end

  test "credit applied to one group does not fund another guest's group", %{conn: conn} do
    fund_credit(conn, "a", 5000, "2026-11-26")

    open_group_fixture(conn, %{
      "operation_id" => "op-open-other",
      "group_id" => "group-other",
      "guest_id" => "guest-99"
    })

    %{"results" => [result]} =
      submit_batch(conn, [
        %{
          "operation_id" => "op-apply-other",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-11-27",
          "group_id" => "group-other",
          "amount_cents" => 100
        }
      ])

    assert result["status"] == "rejected"
    assert result["code"] == "insufficient_credit"
  end
end
