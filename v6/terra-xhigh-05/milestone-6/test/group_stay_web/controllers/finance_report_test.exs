defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  describe "daily finance reporting" do
    test "captures the opening state in batch order and reports later cash and credit movements",
         %{
           conn: conn
         } do
      submit(conn, [
        open_group("open-source", "source", "finance-guest", "ams-canal", "flexible"),
        payment("opening-payment", "source", 100, "2026-10-03"),
        %{
          "operation_id" => "start-reporting",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-10-05"
        },
        payment("received-after-start", "source", 50, "2026-10-06")
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{"status" => "applied"},
                   %{"status" => "applied"},
                   %{
                     "operation_id" => "start-reporting",
                     "status" => "applied",
                     "starts_on" => "2026-10-05"
                   },
                   %{"status" => "applied"}
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "date" => "2026-10-05",
                 "status" => "open",
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 100,
                     "movements" => %{
                       "received_cents" => 0,
                       "transferred_in_cents" => 0,
                       "transferred_out_cents" => 0,
                       "refunded_cents" => 0,
                       "retained_cents" => 0,
                       "converted_to_credit_cents" => 0,
                       "reduced_cents" => 0,
                       "charged_back_cents" => 0
                     },
                     "closing_held_cents" => 100
                   }
                 ],
                 "credit" => %{
                   "opening_liability_cents" => 0,
                   "movements" => %{
                     "issued_cents" => 0,
                     "expired_cents" => 0,
                     "consumed_cents" => 0,
                     "revoked_cents" => 0,
                     "absorbed_cents" => 0
                   },
                   "closing_liability_cents" => 0
                 }
               }
             } = daily_report("2026-10-05")

      assert %{
               "data" => %{
                 "cash" => [
                   %{
                     "opening_held_cents" => 100,
                     "movements" => %{"received_cents" => 50},
                     "closing_held_cents" => 150
                   }
                 ]
               }
             } = daily_report("2026-10-06")

      submit(build_conn(), [
        %{
          "operation_id" => "convert-source",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-10",
          "group_id" => "source",
          "refund_method" => "hotel_credit"
        },
        open_group(
          "open-credit-target",
          "credit-target",
          "finance-guest",
          "rtm-centre",
          "advance_purchase"
        ),
        %{
          "operation_id" => "apply-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-11",
          "group_id" => "credit-target",
          "amount_cents" => 100
        },
        %{
          "operation_id" => "consume-credit",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-11",
          "group_id" => "credit-target"
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{
                     "status" => "applied",
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "credit_issued_cents" => 165
                   },
                   %{"status" => "applied"},
                   %{"status" => "applied"},
                   %{"status" => "applied", "credit_issued_cents" => 0}
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "cash" => [
                   %{
                     "opening_held_cents" => 150,
                     "movements" => %{"converted_to_credit_cents" => 150},
                     "closing_held_cents" => 0
                   }
                 ],
                 "credit" => %{
                   "opening_liability_cents" => 0,
                   "movements" => %{"issued_cents" => 165},
                   "closing_liability_cents" => 165
                 }
               }
             } = daily_report("2026-10-10")

      assert %{
               "data" => %{
                 "credit" => %{
                   "opening_liability_cents" => 165,
                   "movements" => %{"consumed_cents" => 100},
                   "closing_liability_cents" => 65
                 }
               }
             } = daily_report("2026-10-11")

      assert %{
               "data" => %{
                 "credit" => %{
                   "opening_liability_cents" => 65,
                   "movements" => %{"expired_cents" => 65},
                   "closing_liability_cents" => 0
                 }
               }
             } = daily_report("2027-10-11")
    end

    test "validates availability and keeps the start operation durably idempotent", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_reporting_date"}} =
               get(conn, "/api/v1/finance/daily-report") |> json_response(422)

      assert %{"error" => %{"code" => "invalid_reporting_date"}} =
               get(build_conn(), "/api/v1/finance/daily-report?date=nope") |> json_response(422)

      assert %{"error" => %{"code" => "report_not_available"}} =
               get(build_conn(), "/api/v1/finance/daily-report?date=2026-10-05")
               |> json_response(404)

      rejected = %{
        "operation_id" => "bad-start",
        "type" => "start_finance_reporting",
        "starts_on" => "not-a-date"
      }

      submit(build_conn(), [rejected])
      |> json_response(200)
      |> then(fn response ->
        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_reporting_date"}]} =
                 response
      end)

      submit(build_conn(), [rejected])
      |> json_response(200)
      |> then(fn response ->
        assert %{"results" => [%{"status" => "rejected", "code" => "invalid_reporting_date"}]} =
                 response
      end)

      start = %{
        "operation_id" => "start-once",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-05"
      }

      submit(build_conn(), [start])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{
                     "operation_id" => "start-once",
                     "status" => "applied",
                     "starts_on" => "2026-10-05"
                   }
                 ]
               } = response
      end)

      submit(build_conn(), [start])
      |> json_response(200)
      |> then(fn response ->
        assert %{"results" => [%{"status" => "applied", "starts_on" => "2026-10-05"}]} = response
      end)

      submit(build_conn(), [Map.put(start, "operation_id", "second-start")])
      |> json_response(200)
      |> then(fn response ->
        assert %{"results" => [%{"status" => "rejected", "code" => "reporting_already_started"}]} =
                 response
      end)

      assert %{"error" => %{"code" => "report_not_available"}} =
               get(build_conn(), "/api/v1/finance/daily-report?date=2026-10-04")
               |> json_response(404)
    end

    test "attributes transfers and later payment corrections to the affected property", %{
      conn: conn
    } do
      submit(conn, [
        open_group(
          "open-transfer-source",
          "transfer-source",
          "transfer-guest",
          "ams-canal",
          "flexible"
        ),
        open_group(
          "open-transfer-destination",
          "transfer-destination",
          "transfer-guest",
          "rtm-centre",
          "flexible"
        ),
        %{
          "operation_id" => "start-transfer-reporting",
          "type" => "start_finance_reporting",
          "starts_on" => "2026-10-05"
        },
        payment("transfer-payment", "transfer-source", 100, "2026-10-06"),
        %{
          "operation_id" => "move-cash-for-report",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-06",
          "source_group_id" => "transfer-source",
          "destination_group_id" => "transfer-destination",
          "amount_cents" => 40
        },
        %{
          "operation_id" => "reduce-transferred-cash",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-07",
          "payment_operation_id" => "transfer-payment",
          "amount_cents" => 10
        },
        %{
          "operation_id" => "refund-destination-cash",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-08",
          "group_id" => "transfer-destination"
        },
        %{
          "operation_id" => "charge-back-transfer-payment",
          "type" => "charge_back_payment",
          "occurred_on" => "2026-10-09",
          "payment_operation_id" => "transfer-payment"
        }
      ])
      |> json_response(200)
      |> then(fn response ->
        assert %{
                 "results" => [
                   %{},
                   %{},
                   %{"status" => "applied"},
                   %{"status" => "applied"},
                   %{"status" => "applied"},
                   %{"status" => "applied"},
                   %{"status" => "applied", "refunded_cents" => 30},
                   %{"status" => "applied", "charged_back_cents" => 90}
                 ]
               } = response
      end)

      assert %{
               "data" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 0,
                     "movements" => %{
                       "received_cents" => 100,
                       "transferred_out_cents" => 40
                     },
                     "closing_held_cents" => 60
                   },
                   %{
                     "property_id" => "rtm-centre",
                     "opening_held_cents" => 0,
                     "movements" => %{"transferred_in_cents" => 40},
                     "closing_held_cents" => 40
                   }
                 ]
               }
             } = daily_report("2026-10-06")

      assert %{
               "data" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 60,
                     "closing_held_cents" => 60
                   },
                   %{
                     "property_id" => "rtm-centre",
                     "opening_held_cents" => 40,
                     "movements" => %{"reduced_cents" => 10},
                     "closing_held_cents" => 30
                   }
                 ]
               }
             } = daily_report("2026-10-07")

      assert %{
               "data" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "opening_held_cents" => 60,
                     "movements" => %{"charged_back_cents" => 60},
                     "closing_held_cents" => 0
                   },
                   %{
                     "property_id" => "rtm-centre",
                     "opening_held_cents" => 0,
                     "movements" => %{
                       "refunded_cents" => -30,
                       "charged_back_cents" => 30
                     },
                     "closing_held_cents" => 0
                   }
                 ]
               }
             } = daily_report("2026-10-09")
    end
  end

  defp open_group(operation_id, group_id, guest_id, property_id, rate_plan) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "#{group_id}-room", "nightly_rate_cents" => 1_000}]
    }
  end

  defp payment(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp daily_report(date) do
    get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end
end
