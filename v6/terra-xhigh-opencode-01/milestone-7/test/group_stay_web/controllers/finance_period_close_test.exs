defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: true

  test "closes immutable reports and posts old operations as late adjustments", %{conn: conn} do
    conn =
      post_operations(conn, [
        close_period("before-reporting", "2027-01-03"),
        start_reporting("start-reporting", "2027-01-03"),
        close_period("before-start", "2027-01-02"),
        open_operation("settled"),
        open_operation("deferred"),
        cash_payment("settled-payment", "settled", "2027-01-01", 1),
        close_period("close-first-period", "2027-01-03"),
        cash_payment("deferred-payment", "deferred", "2027-01-01", 1)
      ])

    assert %{
             "results" => [
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_period"},
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{
                 "operation_id" => "close-first-period",
                 "status" => "applied",
                 "period_end_on" => "2027-01-03"
               } = first_close,
               %{"revision" => 2}
             ]
           } = json_response(conn, 200)

    assert first_close == %{
             "operation_id" => "close-first-period",
             "status" => "applied",
             "period_end_on" => "2027-01-03"
           }

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-03")

    assert %{
             "data" => %{
               "status" => "closed",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{"received_cents" => 100},
                   "closing_held_cents" => 100
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = json_response(conn, 200)

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "refund-settled",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-01",
          "group_id" => "settled",
          "expected_revision" => 2
        }
      ])

    assert %{"results" => [%{"status" => "applied", "revision" => 3}]} =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-04")
    open_second_day = json_response(conn, 200)

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 100,
                   "movements" => %{"received_cents" => 0, "refunded_cents" => 0},
                   "closing_held_cents" => 100
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{"received_cents" => 100, "refunded_cents" => 100}
                   }
                 ]
               }
             }
           } = open_second_day

    conn = post_operations(conn, [close_period("close-second-period", "2027-01-04")])

    assert %{
             "results" => [
               %{
                 "operation_id" => "close-second-period",
                 "status" => "applied",
                 "period_end_on" => "2027-01-04"
               } = second_close
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-04")
    closed_second_day = json_response(conn, 200)
    assert put_in(open_second_day, ["data", "status"], "closed") == closed_second_day

    conn =
      post_operations(conn, [
        %{
          "operation_id" => "charge-back-settled",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-01-01",
          "payment_operation_id" => "settled-payment",
          "expected_revision" => 3
        }
      ])

    assert %{"results" => [%{"status" => "applied", "charged_back_cents" => 100}]} =
             json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-04")
    assert ^closed_second_day = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-05")

    assert %{
             "data" => %{
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 100,
                   "movements" => %{"refunded_cents" => 0, "charged_back_cents" => 0},
                   "closing_held_cents" => 100
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{
                       "refunded_cents" => -100,
                       "charged_back_cents" => 100
                     }
                   }
                 ]
               }
             }
           } = json_response(conn, 200)

    conn = post_operations(conn, [close_period("close-first-period", "2027-01-03")])
    assert %{"results" => [^first_close]} = json_response(conn, 200)

    conn = post_operations(conn, [close_period("duplicate-period", "2027-01-04")])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             json_response(conn, 200)

    conn = post_operations(conn, [close_period("invalid-period", "not-a-date")])

    assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
             json_response(conn, 200)

    conn = post_operations(conn, [close_period("close-first-period", "2027-01-05")])

    assert %{"results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]} =
             json_response(conn, 200)

    assert second_close == %{
             "operation_id" => "close-second-period",
             "status" => "applied",
             "period_end_on" => "2027-01-04"
           }
  end

  test "reports late credit issuance separately from ordinary movements", %{conn: conn} do
    conn =
      post_operations(conn, [
        start_reporting("credit-start", "2027-01-03"),
        open_operation("credit-group"),
        cash_payment("credit-payment", "credit-group", "2027-01-01", 1),
        close_period("credit-close", "2027-01-03"),
        %{
          "operation_id" => "late-credit-cancellation",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-01",
          "group_id" => "credit-group",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }
      ])

    assert %{
             "results" => [
               %{"status" => "applied"},
               %{"revision" => 1},
               %{"revision" => 2},
               %{"status" => "applied"},
               %{"status" => "applied", "credit_issued_cents" => 110, "revision" => 3}
             ]
           } = json_response(conn, 200)

    conn = get(conn, ~p"/api/v1/finance/daily-report?date=2027-01-04")

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 100,
                   "movements" => %{"converted_to_credit_cents" => 0},
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{"issued_cents" => 0},
                 "closing_liability_cents" => 110
               },
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{"converted_to_credit_cents" => 100}
                   }
                 ],
                 "credit" => %{
                   "issued_cents" => 110,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = json_response(conn, 200)
  end

  defp post_operations(conn, operations) do
    post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_period(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open_operation(group_id) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2027-03-05",
      "departure_on" => "2027-03-06",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 500}]
    }
  end

  defp cash_payment(operation_id, group_id, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => 100,
      "expected_revision" => expected_revision
    }
  end
end
