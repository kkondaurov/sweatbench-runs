defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "start_finance_reporting" do
    test "applies with exactly operation_id, status, and starts_on", %{conn: conn} do
      conn = post_batch(conn, [start_op()])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "start-1",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 }
               ]
             } = json_response(conn, 200)

      [result] = json_response(conn, 200)["results"]
      assert Map.keys(result) |> Enum.sort() == ["operation_id", "starts_on", "status"]
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(%{"operation_id" => "start-missing", "starts_on" => nil}),
          start_op(%{"operation_id" => "start-bad", "starts_on" => "10-01-2026"})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "start-missing",
                   "status" => "rejected",
                   "code" => "invalid_reporting_date"
                 },
                 %{
                   "operation_id" => "start-bad",
                   "status" => "rejected",
                   "code" => "invalid_reporting_date"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "rejects a second start and replays the original", %{conn: conn} do
      conn = post_batch(conn, [start_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [start_op(%{"operation_id" => "start-2"})])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "start-2",
                   "status" => "rejected",
                   "code" => "reporting_already_started"
                 }
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [start_op()])
      original = hd(json_response(conn, 200)["results"])
      assert original["status"] == "applied"
      assert original["starts_on"] == "2026-10-01"

      conn = post_batch(conn, [start_op(%{"starts_on" => "2026-11-01"})])

      assert %{
               "results" => [%{"status" => "rejected", "code" => "operation_id_conflict"}]
             } = json_response(conn, 200)
    end

    test "does not use a revision guard", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          start_op(%{"expected_revision" => 99})
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied", "starts_on" => "2026-10-01"}
               ]
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "rejects a missing or invalid date", %{conn: conn} do
      conn = post_batch(conn, [start_op()])

      conn = get(conn, "/api/v1/finance/daily-report")
      assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(conn, 422)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-13-01")
      assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(conn, 422)
    end

    test "returns report_not_available before start or before starts_on", %{conn: conn} do
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-01")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)

      conn = post_batch(conn, [start_op()])

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-09-30")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)
    end

    test "returns an empty open report on starts_on with no activity", %{conn: conn} do
      conn = post_batch(conn, [start_op()])
      conn = get_report(conn, "2026-10-01")

      assert %{
               "data" => %{
                 "date" => "2026-10-01",
                 "status" => "open",
                 "cash" => [],
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
                 },
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
    end
  end

  describe "opening position" do
    test "includes already committed operations even when occurred_on is on or after starts_on",
         %{
           conn: conn
         } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000, "group-81", "2026-10-15")
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [start_op()])
      conn = get_report(conn, "2026-10-01")
      report = json_response(conn, 200)["data"]

      assert hd(report["cash"])["property_id"] == "ams-canal"
      assert hd(report["cash"])["opening_held_cents"] == 5000
      assert hd(report["cash"])["movements"]["received_cents"] == 0
      assert hd(report["cash"])["closing_held_cents"] == 5000
      assert_cash_identity(hd(report["cash"]))
    end

    test "same-batch operations before start go to opening and later ones are movements", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(4000, "group-81", "2026-10-04"),
          start_op(),
          payment_op(1000, "group-81", "2026-10-04") |> Map.put("operation_id", "pay-after")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]

      conn = get_report(conn, "2026-10-04")
      [cash] = json_response(conn, 200)["data"]["cash"]

      assert cash["opening_held_cents"] == 4000
      assert cash["movements"]["received_cents"] == 1000
      assert cash["closing_held_cents"] == 5000
      assert_cash_identity(cash)

      conn = get_report(conn, "2026-10-01")
      [opening_day] = json_response(conn, 200)["data"]["cash"]
      assert opening_day["opening_held_cents"] == 4000
      assert opening_day["movements"]["received_cents"] == 0
      assert opening_day["closing_held_cents"] == 4000
    end

    test "includes already issued credit in the opening liability", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          start_op()
        ])

      conn = get_report(conn, "2026-10-01")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["issued_cents"] == 0
      assert credit["closing_liability_cents"] == 5500

      conn = get_report(conn, "2027-11-27")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["expired_cents"] == 5500
      assert credit["closing_liability_cents"] == 0
      assert_credit_identity(credit)
    end
  end

  describe "cash movements" do
    test "posts received cash and omits untouched properties", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          open_group_op(%{
            "operation_id" => "open-b",
            "group_id" => "group-rot",
            "property_id" => "rot-harbor"
          }),
          payment_op(5000, "group-81", "2026-10-04")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-04")
      report = json_response(conn, 200)["data"]

      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal"]
      [cash] = report["cash"]
      assert cash["opening_held_cents"] == 0
      assert cash["movements"]["received_cents"] == 5000
      assert cash["closing_held_cents"] == 5000

      assert Map.keys(cash) |> Enum.sort() ==
               ["closing_held_cents", "movements", "opening_held_cents", "property_id"]

      assert Map.keys(cash["movements"]) |> Enum.sort() ==
               [
                 "charged_back_cents",
                 "converted_to_credit_cents",
                 "received_cents",
                 "reduced_cents",
                 "refunded_cents",
                 "retained_cents",
                 "transferred_in_cents",
                 "transferred_out_cents"
               ]
    end

    test "posts refunds, retentions, and conversions on the settling property", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26")
        ])

      conn = get_report(conn, "2026-11-26")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["refunded_cents"] == 5000
      assert cash["closing_held_cents"] == 0
      assert_cash_identity(cash)

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          payment_op(3000, "group-82"),
          cancel_op("group-82", "2026-11-27", %{"operation_id" => "cancel-retain"})
        ])

      conn = get_report(conn, "2026-11-27")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["retained_cents"] == 3000
      assert_cash_identity(cash)

      conn =
        post_batch(conn, [
          open_group_op(%{"operation_id" => "open-3", "group_id" => "group-83"}),
          payment_op(2000, "group-83"),
          cancel_op("group-83", "2026-11-26", %{
            "operation_id" => "cancel-credit",
            "refund_method" => "hotel_credit"
          })
        ])

      conn = get_report(conn, "2026-11-26")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]
      assert cash["movements"]["converted_to_credit_cents"] == 2000
      assert report["credit"]["movements"]["issued_cents"] == 2200
      assert_cash_identity(cash)
      assert_credit_identity(report["credit"])
    end

    test "transfers use source and destination properties and net to equal in/out", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          open_group_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-rot",
            "property_id" => "rot-harbor"
          }),
          payment_op(5000),
          transfer_op(5000, "group-81", "group-rot", "2026-10-06")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-06")
      report = json_response(conn, 200)["data"]
      cash = report["cash"]
      assert Enum.map(cash, & &1["property_id"]) == ["ams-canal", "rot-harbor"]

      [ams, rot] = cash
      assert ams["movements"]["transferred_out_cents"] == 5000
      assert ams["closing_held_cents"] == 0
      assert rot["movements"]["transferred_in_cents"] == 5000
      assert rot["closing_held_cents"] == 5000

      transferred_in =
        Enum.reduce(cash, 0, fn e, acc -> acc + e["movements"]["transferred_in_cents"] end)

      transferred_out =
        Enum.reduce(cash, 0, fn e, acc -> acc + e["movements"]["transferred_out_cents"] end)

      assert transferred_in == transferred_out
      Enum.each(cash, &assert_cash_identity/1)
    end

    test "later corrections follow cash to where it is held or settled", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          open_group_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-rot",
            "property_id" => "rot-harbor"
          }),
          payment_op(5000),
          transfer_op(5000, "group-81", "group-rot", "2026-10-06"),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-07",
            "payment_operation_id" => "op-pay-5000-group-81",
            "amount_cents" => 1000
          }
        ])

      conn = get_report(conn, "2026-10-07")
      cash = json_response(conn, 200)["data"]["cash"]
      rot = Enum.find(cash, &(&1["property_id"] == "rot-harbor"))
      ams = Enum.find(cash, &(&1["property_id"] == "ams-canal"))
      assert ams == nil or ams["movements"]["reduced_cents"] == 0
      assert rot["movements"]["reduced_cents"] == 1000
      assert rot["closing_held_cents"] == 4000

      conn =
        post_batch(conn, [
          cancel_op("group-rot", "2026-11-26", %{"operation_id" => "cancel-rot"})
        ])

      conn = get_report(conn, "2026-11-26")
      cash = json_response(conn, 200)["data"]["cash"]
      rot = Enum.find(cash, &(&1["property_id"] == "rot-harbor"))
      assert rot["movements"]["refunded_cents"] == 4000
      assert rot["closing_held_cents"] == 0

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-28",
            "payment_operation_id" => "op-pay-5000-group-81"
          }
        ])

      conn = get_report(conn, "2026-11-28")

      rot =
        json_response(conn, 200)["data"]["cash"]
        |> Enum.find(&(&1["property_id"] == "rot-harbor"))

      ams =
        json_response(conn, 200)["data"]["cash"] |> Enum.find(&(&1["property_id"] == "ams-canal"))

      assert rot["movements"]["refunded_cents"] == -4000
      assert rot["movements"]["charged_back_cents"] == 4000
      assert ams == nil or ams["movements"]["charged_back_cents"] == 0
      assert_cash_identity(rot)
    end

    test "charges back held cash on the property where it currently sits", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          open_group_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-rot",
            "property_id" => "rot-harbor"
          }),
          payment_op(5000),
          transfer_op(5000, "group-81", "group-rot", "2026-10-06"),
          %{
            "operation_id" => "cb-held",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-08",
            "payment_operation_id" => "op-pay-5000-group-81"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-08")
      cash = json_response(conn, 200)["data"]["cash"]
      rot = Enum.find(cash, &(&1["property_id"] == "rot-harbor"))
      ams = Enum.find(cash, &(&1["property_id"] == "ams-canal"))
      assert rot["movements"]["charged_back_cents"] == 5000
      assert rot["closing_held_cents"] == 0
      assert ams == nil or ams["movements"]["charged_back_cents"] == 0
      assert_cash_identity(rot)
    end

    test "posts a payment with occurred_on before starts_on onto starts_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000, "group-81", "2026-09-15")
        ])

      conn = get_report(conn, "2026-10-01")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 5000
      assert cash["closing_held_cents"] == 5000

      conn = get_report(conn, "2026-09-15")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)
    end

    test "later submissions change an earlier open report", %{conn: conn} do
      conn = post_batch(conn, [start_op(), open_group_op()])
      conn = get_report(conn, "2026-10-04")
      assert json_response(conn, 200)["data"]["cash"] == []

      conn = post_batch(conn, [payment_op(5000, "group-81", "2026-10-04")])
      conn = get_report(conn, "2026-10-04")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 5000
    end
  end

  describe "credit movements" do
    test "applying credit does not change liability", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(2000, "group-82", "2026-11-27")
        ])

      conn = get_report(conn, "2026-11-27")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["issued_cents"] == 0
      assert credit["closing_liability_cents"] == 5500
      assert_credit_identity(credit)
    end

    test "expires unused credit on the day after expires_on without an operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          })
        ])

      conn = get_report(conn, "2027-11-26")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["closing_liability_cents"] == 5500
      assert credit["movements"]["expired_cents"] == 0

      conn = get_report(conn, "2027-11-27")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["expired_cents"] == 5500
      assert credit["closing_liability_cents"] == 0
      assert_credit_identity(credit)

      conn = get(conn, ~p"/api/v1/ledger?on=2027-11-27")
      assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(conn, 200)
    end

    test "does not expire credit applied to an active group", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(5500, "group-82", "2026-11-27")
        ])

      conn = get_report(conn, "2027-11-27")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["expired_cents"] == 0
      assert credit["closing_liability_cents"] == 5500
    end

    test "consumes credit on non-refundable cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(5500, "group-82", "2026-11-27"),
          cancel_op("group-82", "2026-11-28", %{"operation_id" => "cancel-consume"})
        ])

      conn = get_report(conn, "2026-11-28")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["consumed_cents"] == 5500
      assert credit["closing_liability_cents"] == 0
      assert_credit_identity(credit)
    end

    test "revokes unspent credit and absorbs restored shortfall", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000),
          cancel_op("group-81", "2026-11-26", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          apply_credit_op(2000, "group-82", "2026-11-26"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-26",
            "payment_operation_id" => "op-pay-5000-group-81"
          },
          cancel_op("group-82", "2026-11-26", %{"operation_id" => "cancel-restore"})
        ])

      conn = get_report(conn, "2026-11-26")
      report = json_response(conn, 200)["data"]
      credit = report["credit"]
      assert credit["movements"]["issued_cents"] == 5500
      assert credit["movements"]["revoked_cents"] == 3500
      assert credit["movements"]["absorbed_cents"] == 2000
      assert credit["closing_liability_cents"] == 0
      assert_credit_identity(credit)

      cash = hd(report["cash"])
      assert cash["movements"]["converted_to_credit_cents"] == 0
      assert cash["movements"]["charged_back_cents"] == 5000
    end
  end

  describe "durability and reads" do
    test "rejected operations leave no movement and earlier applied movements remain", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000),
          payment_op(50_000, "group-81", "2026-10-04") |> Map.put("operation_id", "pay-too-much"),
          payment_op(1000, "group-81", "2026-10-05") |> Map.put("operation_id", "pay-ok")
        ])

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
                 %{"status" => "applied"}
               ]
             } = json_response(conn, 200)

      conn = get_report(conn, "2026-10-04")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 5000

      conn = get_report(conn, "2026-10-05")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 1000
      assert cash["closing_held_cents"] == 6000
    end

    test "a durable retry does not report a movement twice", %{conn: conn} do
      pay = payment_op(5000)

      conn = post_batch(conn, [start_op(), open_group_op(), pay])
      conn = post_batch(conn, [pay])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_report(conn, "2026-10-04")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 5000
      assert cash["closing_held_cents"] == 5000
    end

    test "reading reports does not change reports or domain state", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(5000)
        ])

      conn = get(conn, ~p"/api/v1/groups/group-81")
      before_group = json_response(conn, 200)["data"]
      conn = get(conn, ~p"/api/v1/ledger")
      before_ledger = json_response(conn, 200)["data"]

      conn = get_report(conn, "2026-10-04")
      first = json_response(conn, 200)["data"]
      conn = get_report(conn, "2026-10-01")
      _other = json_response(conn, 200)["data"]
      conn = get_report(conn, "2026-10-04")
      second = json_response(conn, 200)["data"]
      assert first == second

      conn = get(conn, ~p"/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"] == before_group
      conn = get(conn, ~p"/api/v1/ledger")
      assert json_response(conn, 200)["data"] == before_ledger
    end

    test "closing cash on the posting date reconciles to the ledger", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op(),
          open_group_op(),
          payment_op(8000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "op-pay-8000-group-81",
            "amount_cents" => 2000
          }
        ])

      conn = get_report(conn, "2026-10-05")
      [cash] = json_response(conn, 200)["data"]["cash"]
      conn = get(conn, ~p"/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert cash["closing_held_cents"] == ledger["cash_held_cents"]
      assert cash["movements"]["reduced_cents"] == ledger["cash_reduced_cents"]
    end

    test "equivalent sequential submissions produce the same report as one batch would", %{
      conn: conn
    } do
      conn = post_batch(conn, [start_op()])
      conn = post_batch(conn, [open_group_op()])
      conn = post_batch(conn, [payment_op(5000)])
      conn = post_batch(conn, [cancel_op("group-81", "2026-11-26")])

      conn = get_report(conn, "2026-11-26")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 0
      assert cash["movements"]["refunded_cents"] == 5000
      assert cash["closing_held_cents"] == 0
      assert_cash_identity(cash)
    end
  end

  defp start_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "start-1",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-01",
        "starts_on" => "2026-10-01"
      },
      overrides
    )
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp open_group_op(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_op(amount_cents, group_id \\ "group-81", occurred_on \\ "2026-10-04") do
    %{
      "operation_id" => "op-pay-#{amount_cents}-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(group_id, occurred_on, extras \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extras
    )
  end

  defp apply_credit_op(amount_cents, group_id, occurred_on) do
    %{
      "operation_id" => "op-credit-#{amount_cents}-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(amount_cents, source, dest, occurred_on) do
    %{
      "operation_id" => "xfer-#{source}-#{dest}",
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => dest,
      "amount_cents" => amount_cents
    }
  end

  defp get_report(conn, date) do
    get(conn, "/api/v1/finance/daily-report?date=#{date}")
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp assert_cash_identity(entry) do
    m = entry["movements"]

    expected =
      entry["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
        m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
        m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]

    assert entry["closing_held_cents"] == expected
  end

  defp assert_credit_identity(credit) do
    m = credit["movements"]

    expected =
      credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
        m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    assert credit["closing_liability_cents"] == expected
  end
end
