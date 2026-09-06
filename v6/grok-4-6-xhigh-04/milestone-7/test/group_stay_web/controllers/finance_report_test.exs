defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  describe "start_finance_reporting" do
    test "applies with starts_on and no extra result fields", %{conn: conn} do
      conn = post_batch(conn, [start_op()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "fin-start",
                   "status" => "applied",
                   "starts_on" => "2026-10-05"
                 }
               ]
             }
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      conn = post_batch(conn, [start_op(%{"starts_on" => nil})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_reporting_date"}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [start_op(%{"operation_id" => "fin-bad", "starts_on" => "10/05/2026"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_reporting_date"}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "fin-missing",
            "type" => "start_finance_reporting"
          }
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_reporting_date"}]} =
               json_response(conn, 200)
    end

    test "rejects a second start and retries the original", %{conn: conn} do
      start = start_op()
      conn = post_batch(conn, [start])
      first = json_response(conn, 200)["results"] |> hd()

      conn = post_batch(conn, [start_op(%{"operation_id" => "fin-start-2"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "reporting_already_started"}]} =
               json_response(conn, 200)

      conn = post_batch(conn, [start])
      assert json_response(conn, 200) == %{"results" => [first]}

      conn = post_batch(conn, [start_op(%{"starts_on" => "2026-10-06"})])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/operations/fin-start")
      assert json_response(conn, 200) == %{"data" => first}
    end

    test "ignores expected_revision", %{conn: conn} do
      conn = post_batch(conn, [start_op(%{"expected_revision" => 99})])

      assert %{"results" => [%{"status" => "applied", "starts_on" => "2026-10-05"}]} =
               json_response(conn, 200)
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "rejects a missing or invalid date", %{conn: conn} do
      conn = get(conn, "/api/v1/finance/daily-report")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = get(conn, "/api/v1/finance/daily-report?date=not-a-date")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = get(conn, "/api/v1/finance/daily-report?date=")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "returns report_not_available before start or before starts_on", %{conn: conn} do
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      conn = post_batch(conn, [start_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "opening includes committed operations even when occurred_on is after starts_on", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000, "2026-10-10"),
          start_op(%{"starts_on" => "2026-10-05"})
        ])

      assert %{"results" => [_, %{"status" => "applied"}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      report = json_response(conn, 200)["data"]
      assert report["date"] == "2026-10-05"
      assert report["status"] == "open"
      [cash] = report["cash"]
      assert cash["property_id"] == "ams-canal"
      assert cash["opening_held_cents"] == 1000
      assert cash["closing_held_cents"] == 1000
      assert cash["movements"]["received_cents"] == 0
      assert_cash_formula(cash)
      assert_credit_formula(report["credit"])
      assert report["credit"]["opening_liability_cents"] == 0
      assert report["late_adjustments"]["cash"] == []
      assert report["late_adjustments"]["credit"] == empty_late_credit()
    end

    test "same-batch operations before start open and after start move", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000, "2026-10-04"),
          start_op(),
          %{
            "operation_id" => "pay-after",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "amount_cents" => 500
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.at(results, 2)["status"] == "applied"
      assert Enum.at(results, 3)["status"] == "applied"

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["opening_held_cents"] == 1000
      assert cash["movements"]["received_cents"] == 0
      assert cash["closing_held_cents"] == 1000

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["opening_held_cents"] == 1000
      assert cash["movements"]["received_cents"] == 500
      assert cash["closing_held_cents"] == 1500
      assert_cash_formula(cash)
    end

    test "posts late operations to starts_on", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_op(), pay_op(500, "2026-10-01")])
      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["opening_held_cents"] == 0
      assert cash["movements"]["received_cents"] == 500
      assert cash["closing_held_cents"] == 500

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-01")
      assert json_response(conn, 404)["error"]["code"] == "report_not_available"
    end

    test "records transfers by source and destination property", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      report = json_response(conn, 200)["data"]
      cash = report["cash"]
      assert Enum.map(cash, & &1["property_id"]) == ["ams-canal", "rot-centre"]

      ams = Enum.find(cash, &(&1["property_id"] == "ams-canal"))
      rot = Enum.find(cash, &(&1["property_id"] == "rot-centre"))
      assert ams["movements"]["received_cents"] == 10000
      assert ams["movements"]["transferred_out_cents"] == 1000
      assert ams["closing_held_cents"] == 9000
      assert rot["movements"]["transferred_in_cents"] == 1000
      assert rot["closing_held_cents"] == 1000
      assert_cash_formula(ams)
      assert_cash_formula(rot)

      transferred_in =
        Enum.reduce(cash, 0, fn e, acc -> acc + e["movements"]["transferred_in_cents"] end)

      transferred_out =
        Enum.reduce(cash, 0, fn e, acc -> acc + e["movements"]["transferred_out_cents"] end)

      assert transferred_in == transferred_out
    end

    test "refunds, retains, and converts on the group's property", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(),
          pay_op(5000),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["refunded_cents"] == 5000

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 0
      assert cash["movements"]["refunded_cents"] == 5000
      assert cash["opening_held_cents"] == 5000
      assert cash["closing_held_cents"] == 0
      assert_cash_formula(cash)

      conn =
        post_batch(conn, [
          open_op(%{
            "operation_id" => "o2",
            "group_id" => "g-ap",
            "rate_plan" => "advance_purchase"
          }),
          %{
            "operation_id" => "p2",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "g-ap",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "cancel-ap",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-07",
            "group_id" => "g-ap"
          }
        ])

      assert %{"results" => [_, _, %{"retained_cents" => 2000}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-07")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["retained_cents"] == 2000
      assert_cash_formula(cash)
    end

    test "hotel-credit cancellation issues credit and converts cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(%{"arrival_on" => "2027-06-10", "departure_on" => "2027-06-13"}),
          pay_op(5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => [_, _, _, %{"credit_issued_cents" => 5500}]} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      data = json_response(conn, 200)["data"]
      [cash] = data["cash"]
      assert cash["movements"]["converted_to_credit_cents"] == 5000
      assert cash["closing_held_cents"] == 0
      assert data["credit"]["movements"]["issued_cents"] == 5500
      assert data["credit"]["closing_liability_cents"] == 5500
      assert_cash_formula(cash)
      assert_credit_formula(data["credit"])
    end

    test "chargeback reverses a refund with signed movements", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(),
          pay_op(5000),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["charged_back_cents"] == 5000

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      data = json_response(conn, 200)["data"]
      [cash] = data["cash"]
      assert cash["movements"]["refunded_cents"] == -5000
      assert cash["movements"]["charged_back_cents"] == 5000
      assert cash["closing_held_cents"] == 0
      assert_cash_formula(cash)
    end

    test "reductions and chargebacks follow cash to the property that holds it", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op(),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      cash = json_response(conn, 200)["data"]["cash"]
      rot = Enum.find(cash, &(&1["property_id"] == "rot-centre"))
      ams = Enum.find(cash, &(&1["property_id"] == "ams-canal"))
      assert rot["movements"]["reduced_cents"] == 1000
      assert rot["closing_held_cents"] == 0
      assert ams["movements"]["reduced_cents"] == 0
      assert ams["closing_held_cents"] == 9000
      Enum.each(cash, &assert_cash_formula/1)
    end

    test "omits properties whose opening, closing, and movements are zero", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_op()])
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      data = json_response(conn, 200)["data"]
      assert data["cash"] == []
      assert data["credit"]["opening_liability_cents"] == 0
      assert data["credit"]["closing_liability_cents"] == 0
    end

    test "expires unused credit on the day after expires_on without an operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(%{"arrival_on" => "2027-06-10", "departure_on" => "2027-06-13"}),
          pay_op(5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => [_, _, _, %{"credit_issued_cents" => 5500}]} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-05")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["expired_cents"] == 0
      assert credit["closing_liability_cents"] == 5500

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-06")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["expired_cents"] == 5500
      assert credit["closing_liability_cents"] == 0
      assert_credit_formula(credit)

      conn = get(conn, "/api/v1/ledger?on=2027-10-06")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0
    end

    test "applying credit does not create a credit movement", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(%{
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13",
            "operation_id" => "o1"
          }),
          pay_op(5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "operation_id" => "o2",
            "group_id" => "dest",
            "arrival_on" => "2027-08-10",
            "departure_on" => "2027-08-13"
          }),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-06",
            "group_id" => "dest",
            "amount_cents" => 2000
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["issued_cents"] == 0
      assert credit["movements"]["consumed_cents"] == 0
      assert credit["closing_liability_cents"] == 5500
      assert_credit_formula(credit)
    end

    test "non-refundable settlement consumes applied credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(%{
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13",
            "operation_id" => "o1"
          }),
          pay_op(5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "operation_id" => "o2",
            "group_id" => "dest",
            "rate_plan" => "advance_purchase",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-06",
            "group_id" => "dest",
            "amount_cents" => 2000
          },
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-07",
            "group_id" => "dest"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-07")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["consumed_cents"] == 2000
      assert credit["closing_liability_cents"] == 3500
      assert_credit_formula(credit)
    end

    test "chargeback revokes unspent credit and absorbs a shortfall restoration", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(%{
            "group_id" => "source",
            "operation_id" => "o1",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-13"
          }),
          %{
            "operation_id" => "p1",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "source",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "source",
            "refund_method" => "hotel_credit"
          },
          open_op(%{
            "group_id" => "dest",
            "operation_id" => "o2",
            "arrival_on" => "2027-08-10",
            "departure_on" => "2027-08-13"
          }),
          %{
            "operation_id" => "credit-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-06",
            "group_id" => "dest",
            "amount_cents" => 4000
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-07",
            "payment_operation_id" => "p1"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["status"] == "applied"

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-07")
      data = json_response(conn, 200)["data"]
      assert data["credit"]["movements"]["revoked_cents"] == 1500
      assert data["credit"]["closing_liability_cents"] == 4000
      assert_credit_formula(data["credit"])

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-dest",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-08",
            "group_id" => "dest"
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-08")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["absorbed_cents"] == 4000
      assert credit["closing_liability_cents"] == 0
      assert_credit_formula(credit)
    end

    test "rejected operations and retries do not double-count movements", %{conn: conn} do
      pay = pay_op(500)
      conn = post_batch(conn, [start_op(), open_op(), pay])
      assert %{"results" => [_, _, applied]} = json_response(conn, 200)
      assert applied["status"] == "applied"

      conn = post_batch(conn, [pay])
      assert json_response(conn, 200) == %{"results" => [applied]}

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "pay-bad",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "amount_cents" => 99_999
          },
          %{
            "operation_id" => "pay-ok",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "amount_cents" => 100
          }
        ])

      assert %{
               "results" => [
                 %{"status" => "rejected"},
                 %{"status" => "applied"}
               ]
             } = json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 500

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 100
      assert cash["closing_held_cents"] == 600
    end

    test "reading a report does not change domain state", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_op(), pay_op(1000)])
      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      first = json_response(conn, 200)
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-07")
      _ = json_response(conn, 200)
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      assert json_response(conn, 200) == first

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200) == ledger
      assert ledger["data"]["cash_held_cents"] == 1000
    end

    test "closing held cash reconciles to the ledger", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(),
          pay_op(10000),
          open_dest(),
          transfer_op(),
          %{
            "operation_id" => "cancel-src",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "room_ids" => ["room-b"]
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]
      held = Enum.reduce(report["cash"], 0, fn e, acc -> acc + e["closing_held_cents"] end)
      assert held == ledger["cash_held_cents"]
      Enum.each(report["cash"], &assert_cash_formula/1)
      assert_credit_formula(report["credit"])
    end

    test "credit issued before start expires from the opening snapshot", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(%{"arrival_on" => "2027-06-10", "departure_on" => "2027-06-13"}),
          pay_op(5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          start_op(%{"starts_on" => "2026-10-05"})
        ])

      assert %{"results" => [_, _, %{"credit_issued_cents" => 5500}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["issued_cents"] == 0
      assert credit["closing_liability_cents"] == 5500

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-06")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["expired_cents"] == 5500
      assert credit["closing_liability_cents"] == 0
      assert_credit_formula(credit)
    end
  end

  describe "close_finance_period" do
    test "applies with period_end_on and no extra result fields", %{conn: conn} do
      conn = post_batch(conn, [start_op(), close_op()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "fin-start",
                   "status" => "applied",
                   "starts_on" => "2026-10-05"
                 },
                 %{
                   "operation_id" => "fin-close",
                   "status" => "applied",
                   "period_end_on" => "2026-10-10"
                 }
               ]
             }
    end

    test "rejects before reporting has started", %{conn: conn} do
      conn = post_batch(conn, [close_op()])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)
    end

    test "rejects a missing or invalid period_end_on", %{conn: conn} do
      conn = post_batch(conn, [start_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [close_op(%{"operation_id" => "c-nil", "period_end_on" => nil})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [close_op(%{"operation_id" => "c-bad", "period_end_on" => "10/10/2026"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{"operation_id" => "c-missing", "type" => "close_finance_period"}
        ])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)
    end

    test "rejects a cutoff before starts_on", %{conn: conn} do
      conn = post_batch(conn, [start_op(), close_op(%{"period_end_on" => "2026-10-04"})])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "invalid_period"}
               ]
             } = json_response(conn, 200)
    end

    test "allows closing on starts_on and rejects the same or an earlier cutoff", %{conn: conn} do
      conn = post_batch(conn, [start_op(), close_op(%{"period_end_on" => "2026-10-05"})])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "period_end_on" => "2026-10-05"}
               ]
             } = json_response(conn, 200)

      conn =
        post_batch(conn, [close_op(%{"operation_id" => "c2", "period_end_on" => "2026-10-05"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [close_op(%{"operation_id" => "c3", "period_end_on" => "2026-10-04"})])

      assert %{"results" => [%{"status" => "rejected", "code" => "invalid_period"}]} =
               json_response(conn, 200)

      conn =
        post_batch(conn, [close_op(%{"operation_id" => "c4", "period_end_on" => "2026-10-06"})])

      assert %{"results" => [%{"status" => "applied", "period_end_on" => "2026-10-06"}]} =
               json_response(conn, 200)
    end

    test "retries the original close and conflicts on a different payload", %{conn: conn} do
      close = close_op()
      conn = post_batch(conn, [start_op(), close])
      first = json_response(conn, 200)["results"] |> List.last()

      conn = post_batch(conn, [close])
      assert json_response(conn, 200) == %{"results" => [first]}

      conn = post_batch(conn, [close_op(%{"period_end_on" => "2026-10-11"})])

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)

      conn = get(conn, "/api/v1/operations/fin-close")
      assert json_response(conn, 200) == %{"data" => first}
    end

    test "ignores expected_revision", %{conn: conn} do
      conn = post_batch(conn, [start_op(), close_op(%{"expected_revision" => 99})])

      assert %{"results" => [_, %{"status" => "applied", "period_end_on" => "2026-10-10"}]} =
               json_response(conn, 200)
    end
  end

  describe "closed reports and late adjustments" do
    test "reports through the cutoff are closed and later reports stay open", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_op(), pay_op(1000), close_op()])
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      assert closed["late_adjustments"]["cash"] == []
      assert closed["late_adjustments"]["credit"] == empty_late_credit()

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-10")
      assert json_response(conn, 200)["data"]["status"] == "closed"

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-11")
      assert json_response(conn, 200)["data"]["status"] == "open"
    end

    test "closed report data stays stable after later operations and closes", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_op(), pay_op(1000), close_op()])
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      frozen = json_response(conn, 200)

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "pay-late",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 500
          },
          close_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-15"})
        ])

      assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
               json_response(conn, 200)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      assert json_response(conn, 200) == frozen
    end

    test "an operation before a close can post into the period being closed", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_op(),
          pay_op(1000, "2026-10-08"),
          close_op()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-08")
      report = json_response(conn, 200)["data"]
      assert report["status"] == "closed"
      [cash] = report["cash"]
      assert cash["movements"]["received_cents"] == 1000
      assert report["late_adjustments"]["cash"] == []
    end

    test "an old-dated operation after a close posts on the first open day as late", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          start_op(),
          open_op(),
          pay_op(1000, "2026-10-05"),
          close_op(%{"period_end_on" => "2026-10-05"}),
          %{
            "operation_id" => "pay-late",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      [cash] = closed["cash"]
      assert cash["movements"]["received_cents"] == 1000
      assert cash["closing_held_cents"] == 1000
      assert closed["late_adjustments"]["cash"] == []

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      open = json_response(conn, 200)["data"]
      assert open["status"] == "open"
      [cash] = open["cash"]
      assert cash["opening_held_cents"] == 1000
      assert cash["movements"]["received_cents"] == 0
      assert cash["closing_held_cents"] == 1500
      [late] = open["late_adjustments"]["cash"]
      assert late["property_id"] == "ams-canal"
      assert Map.keys(late) |> Enum.sort() == ["movements", "property_id"]
      assert late["movements"]["received_cents"] == 500
      assert late["movements"]["transferred_in_cents"] == 0
      assert late["movements"]["transferred_out_cents"] == 0
      assert late["movements"]["refunded_cents"] == 0
      assert late["movements"]["retained_cents"] == 0
      assert late["movements"]["converted_to_credit_cents"] == 0
      assert late["movements"]["reduced_cents"] == 0
      assert late["movements"]["charged_back_cents"] == 0
      assert_cash_with_late(cash, late["movements"])
    end

    test "keeps occurred_on when it is already in the open period", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_op(),
          close_op(%{"period_end_on" => "2026-10-05"}),
          %{
            "operation_id" => "pay-open",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-08",
            "group_id" => "group-81",
            "amount_cents" => 700
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]
      assert report["cash"] == []
      assert report["late_adjustments"]["cash"] == []

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-08")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["movements"]["received_cents"] == 700
      assert report["late_adjustments"]["cash"] == []
      assert_cash_formula(cash)
    end

    test "keeps signed late classifications when they net to zero", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(),
          pay_op(100),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          },
          close_op(%{"period_end_on" => "2026-10-05"}),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["charged_back_cents"] == 100

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      [cash] = closed["cash"]
      assert cash["movements"]["refunded_cents"] == 100
      assert cash["closing_held_cents"] == 0

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["opening_held_cents"] == 0
      assert cash["movements"]["refunded_cents"] == 0
      assert cash["movements"]["charged_back_cents"] == 0
      assert cash["closing_held_cents"] == 0
      [late] = report["late_adjustments"]["cash"]
      assert late["property_id"] == "ams-canal"
      assert late["movements"]["refunded_cents"] == -100
      assert late["movements"]["charged_back_cents"] == 100
      assert_cash_with_late(cash, late["movements"])
    end

    test "omits all-zero late cash properties and always includes late credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_op(),
          pay_op(1000),
          open_dest(),
          close_op(%{"period_end_on" => "2026-10-05"}),
          %{
            "operation_id" => "pay-late",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 200
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]
      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) == ["ams-canal"]
      assert report["late_adjustments"]["credit"] == empty_late_credit()
    end

    test "late hotel-credit issue posts on the first open day", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(%{"arrival_on" => "2027-06-10", "departure_on" => "2027-06-13"}),
          pay_op(5000),
          close_op(%{"period_end_on" => "2026-10-05"}),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["credit_issued_cents"] == 5500

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      closed = json_response(conn, 200)["data"]
      [cash] = closed["cash"]
      assert cash["movements"]["converted_to_credit_cents"] == 0
      assert cash["closing_held_cents"] == 5000
      assert closed["credit"]["closing_liability_cents"] == 0

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["movements"]["converted_to_credit_cents"] == 0
      [late] = report["late_adjustments"]["cash"]
      assert late["movements"]["converted_to_credit_cents"] == 5000
      assert cash["closing_held_cents"] == 0
      assert report["credit"]["movements"]["issued_cents"] == 0
      assert report["late_adjustments"]["credit"]["issued_cents"] == 5500
      assert report["credit"]["closing_liability_cents"] == 5500
      assert_cash_with_late(cash, late["movements"])
      assert_credit_with_late(report["credit"], report["late_adjustments"]["credit"])
    end

    test "does not change group, ledger, or payment current-state views", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_op(),
          pay_op(1000),
          close_op(%{"period_end_on" => "2026-10-05"}),
          %{
            "operation_id" => "pay-late",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 500
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/groups/group-81")
      group = json_response(conn, 200)["data"]
      assert group["deposit_paid_cents"] == 1500
      assert group["revision"] == 3

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200)["data"]["cash_held_cents"] == 1500

      conn = get(conn, "/api/v1/payments/pay-late")
      payment = json_response(conn, 200)["data"]
      assert payment["held_cents"] == 500
      assert payment["recorded_cents"] == 500
    end

    test "a later close never moves an earlier posting date", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_op(),
          close_op(%{"period_end_on" => "2026-10-05"}),
          %{
            "operation_id" => "pay-open",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81",
            "amount_cents" => 400
          },
          close_op(%{"operation_id" => "close-2", "period_end_on" => "2026-10-20"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]
      assert report["status"] == "closed"
      [cash] = report["cash"]
      assert cash["movements"]["received_cents"] == 400
      assert report["late_adjustments"]["cash"] == []

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-21")
      later = json_response(conn, 200)["data"]
      assert later["status"] == "open"
      [cash] = later["cash"]
      assert cash["opening_held_cents"] == 400
      assert cash["movements"]["received_cents"] == 0
    end

    test "credit issued after a close past its expiry expires as a late adjustment", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"starts_on" => "2026-10-03"}),
          open_op(%{"arrival_on" => "2027-06-10", "departure_on" => "2027-06-13"}),
          pay_op(5000),
          close_op(%{"period_end_on" => "2028-01-01"}),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert List.last(results)["credit_issued_cents"] == 5500

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-06")
      closed = json_response(conn, 200)["data"]
      assert closed["status"] == "closed"
      assert closed["credit"]["movements"]["issued_cents"] == 0
      assert closed["credit"]["movements"]["expired_cents"] == 0
      assert closed["late_adjustments"]["credit"]["issued_cents"] == 0
      assert closed["late_adjustments"]["credit"]["expired_cents"] == 0

      conn = get(conn, "/api/v1/finance/daily-report?date=2028-01-02")
      report = json_response(conn, 200)["data"]
      assert report["status"] == "open"
      assert report["credit"]["movements"]["issued_cents"] == 0
      assert report["credit"]["movements"]["expired_cents"] == 0
      assert report["late_adjustments"]["credit"]["issued_cents"] == 5500
      assert report["late_adjustments"]["credit"]["expired_cents"] == 5500
      assert report["credit"]["closing_liability_cents"] == 0
      assert_credit_with_late(report["credit"], report["late_adjustments"]["credit"])
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp close_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "fin-close",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-10"
      },
      overrides
    )
  end

  defp start_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "fin-start",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-05"
      },
      overrides
    )
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1001",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp pay_op(amount_cents, occurred_on \\ "2026-10-04") do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp open_dest(overrides \\ %{}) do
    open_op(
      Map.merge(
        %{
          "operation_id" => "op-1002",
          "group_id" => "group-92",
          "property_id" => "rot-centre"
        },
        overrides
      )
    )
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "xfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  defp empty_late_credit do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp cash_net(movements) do
    movements["received_cents"] + movements["transferred_in_cents"] -
      movements["transferred_out_cents"] - movements["refunded_cents"] -
      movements["retained_cents"] - movements["converted_to_credit_cents"] -
      movements["reduced_cents"] - movements["charged_back_cents"]
  end

  defp credit_net(movements) do
    movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
      movements["revoked_cents"] - movements["absorbed_cents"]
  end

  defp assert_cash_formula(entry) do
    assert entry["closing_held_cents"] ==
             entry["opening_held_cents"] + cash_net(entry["movements"])
  end

  defp assert_cash_with_late(entry, late_movements) do
    assert entry["closing_held_cents"] ==
             entry["opening_held_cents"] + cash_net(entry["movements"]) + cash_net(late_movements)
  end

  defp assert_credit_formula(credit) do
    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + credit_net(credit["movements"])
  end

  defp assert_credit_with_late(credit, late_movements) do
    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + credit_net(credit["movements"]) +
               credit_net(late_movements)
  end
end
