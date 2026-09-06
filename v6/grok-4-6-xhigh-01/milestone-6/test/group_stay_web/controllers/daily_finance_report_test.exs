defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  describe "start_finance_reporting" do
    test "enables reporting and returns exactly the applied fields", %{conn: conn} do
      conn = post_batch(conn, [start_op("2026-10-01")])

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-start",
                 "status" => "applied",
                 "starts_on" => "2026-10-01"
               }
             ]

      conn = get_report(conn, "2026-10-01")
      data = json_response(conn, 200)["data"]

      assert data == %{
               "date" => "2026-10-01",
               "status" => "open",
               "cash" => [],
               "credit" => zero_credit()
             }

      assert Map.keys(data) |> Enum.sort() == ["cash", "credit", "date", "status"]

      assert Map.keys(data["credit"]) |> Enum.sort() == [
               "closing_liability_cents",
               "movements",
               "opening_liability_cents"
             ]
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "no-date", "type" => "start_finance_reporting"},
          start_op("2026-13-40", "bad-date")
        ])

      assert [
               %{
                 "operation_id" => "no-date",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               },
               %{
                 "operation_id" => "bad-date",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects a later start once reporting has begun", %{conn: conn} do
      conn = post_batch(conn, [start_op("2026-10-01"), start_op("2026-10-02", "op-start-2")])

      assert [
               %{"operation_id" => "op-start", "status" => "applied"},
               %{
                 "operation_id" => "op-start-2",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "replays the original start and conflicts on a different payload", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [start_op("2026-10-01")])

      conn = post_batch(conn, [start_op("2026-10-01")])

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "op-start",
                 "status" => "applied",
                 "starts_on" => "2026-10-01"
               }
             ]

      conn = post_batch(conn, [start_op("2026-10-03")])

      assert [
               %{
                 "operation_id" => "op-start",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "allows a valid start after a rejected one and exposes the stored result", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_op("not-a-date"),
          start_op("2026-10-01", "op-start-ok")
        ])

      assert [
               %{"code" => "invalid_reporting_date"},
               %{
                 "operation_id" => "op-start-ok",
                 "status" => "applied",
                 "starts_on" => "2026-10-01"
               }
             ] = json_response(conn, 200)["results"]

      conn = get(recycle(conn), "/api/v1/operations/op-start-ok")

      assert json_response(conn, 200)["data"] == %{
               "operation_id" => "op-start-ok",
               "status" => "applied",
               "starts_on" => "2026-10-01"
             }
    end

    test "does not address a group or consume a revision", %{conn: conn} do
      conn = post_batch(conn, [open_op(), start_op("2026-10-01"), pay_op(1000)])

      assert [
               %{"revision" => 1},
               %{"status" => "applied", "starts_on" => "2026-10-01"},
               %{"revision" => 2}
             ] = json_response(conn, 200)["results"]

      refute Map.has_key?(Enum.at(json_response(conn, 200)["results"], 1), "revision")
      refute Map.has_key?(Enum.at(json_response(conn, 200)["results"], 1), "group_id")
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "rejects a missing or invalid date", %{conn: conn} do
      conn = get(conn, "/api/v1/finance/daily-report")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = get(recycle(conn), "/api/v1/finance/daily-report?date=2026-13-01")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "is unavailable before reporting starts or before starts_on", %{conn: conn} do
      conn = get_report(conn, "2026-10-01")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      {:ok, conn} = open_and_return(conn, [start_op("2026-10-05")])

      conn = get_report(conn, "2026-10-04")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "puts committed operations before the start into the opening position", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          Map.merge(pay_op(1500), %{"operation_id" => "pay-after"})
        ])

      assert Enum.map(json_response(conn, 200)["results"], & &1["status"]) == [
               "applied",
               "applied",
               "applied",
               "applied"
             ]

      conn = get_report(conn, "2026-10-01")
      opening = json_response(conn, 200)["data"]

      assert opening["cash"] == [
               cash_entry("ams-canal", 5000, %{}, 5000)
             ]

      conn = get_report(conn, "2026-10-04")
      report = json_response(conn, 200)["data"]

      assert report["cash"] == [
               cash_entry("ams-canal", 5000, %{"received_cents" => 1500}, 6500)
             ]

      assert_cash_identity(report)
    end

    test "includes already-committed later occurred_on amounts in the opening", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          Map.merge(pay_op(4000), %{"occurred_on" => "2026-10-20"}),
          start_op("2026-10-01")
        ])

      conn = get_report(conn, "2026-10-01")
      report = json_response(conn, 200)["data"]

      assert hd(report["cash"])["opening_held_cents"] == 4000
      assert hd(report["cash"])["movements"]["received_cents"] == 0
      assert hd(report["cash"])["closing_held_cents"] == 4000
    end

    test "posts later operations to the later of occurred_on and starts_on", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(), start_op("2026-10-10")])

      conn =
        post_batch(conn, [
          Map.merge(pay_op(2000), %{"occurred_on" => "2026-10-04", "operation_id" => "pay-early"}),
          Map.merge(pay_op(3000), %{"occurred_on" => "2026-10-20", "operation_id" => "pay-late"})
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get_report(conn, "2026-10-10")
      early = json_response(conn, 200)["data"]
      assert hd(early["cash"])["movements"]["received_cents"] == 2000
      assert hd(early["cash"])["closing_held_cents"] == 2000

      conn = get_report(conn, "2026-10-20")
      late = json_response(conn, 200)["data"]
      assert hd(late["cash"])["opening_held_cents"] == 2000
      assert hd(late["cash"])["movements"]["received_cents"] == 3000
      assert hd(late["cash"])["closing_held_cents"] == 5000
    end

    test "lets a later submission change an earlier open report", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(), start_op("2026-10-01")])

      conn = get_report(conn, "2026-10-04")
      assert json_response(conn, 200)["data"]["cash"] == []

      {:ok, conn} =
        open_and_return(conn, [
          Map.merge(pay_op(2500), %{"occurred_on" => "2026-10-04"})
        ])

      conn = get_report(conn, "2026-10-04")
      report = json_response(conn, 200)["data"]
      assert hd(report["cash"])["movements"]["received_cents"] == 2500
      assert hd(report["cash"])["closing_held_cents"] == 2500
    end

    test "does not record movements for rejected operations or durable retries", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          start_op("2026-10-01"),
          pay_op(1000),
          Map.merge(pay_op(50_000), %{"operation_id" => "pay-too-much"}),
          pay_op(1000)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "payment_exceeds_outstanding"},
               %{"status" => "applied", "amount_cents" => 1000}
             ] = json_response(conn, 200)["results"]

      conn = get_report(conn, "2026-10-04")
      report = json_response(conn, 200)["data"]
      assert hd(report["cash"])["movements"]["received_cents"] == 1000
      assert hd(report["cash"])["closing_held_cents"] == 1000

      conn = get_report(recycle(conn), "2026-10-04")
      assert json_response(conn, 200)["data"] == report
    end

    test "omits a property only when opening, closing, and movements are zero", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          start_op("2026-10-01"),
          open_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-rot",
            "property_id" => "rot-harbor"
          }),
          Map.merge(pay_op(1000), %{
            "operation_id" => "pay-rot",
            "group_id" => "group-rot",
            "occurred_on" => "2026-10-04"
          })
        ])

      conn = get_report(conn, "2026-10-01")
      assert json_response(conn, 200)["data"]["cash"] == []

      conn = get_report(conn, "2026-10-04")
      cash = json_response(conn, 200)["data"]["cash"]
      assert Enum.map(cash, & &1["property_id"]) == ["rot-harbor"]
    end
  end

  describe "cash movements" do
    test "records refunds, retentions, and conversions on the group's property", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(3000),
          start_op("2026-10-01"),
          cancel_op("cancel-flex", "2026-11-01")
        ])

      conn = get_report(conn, "2026-11-01")
      report = json_response(conn, 200)["data"]
      entry = hd(report["cash"])
      assert entry["opening_held_cents"] == 3000
      assert entry["movements"]["refunded_cents"] == 3000
      assert entry["closing_held_cents"] == 0
      assert_cash_identity(report)

      {:ok, conn} =
        open_and_return(recycle(conn), [
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          Map.merge(pay_op(2000), %{"operation_id" => "pay-2", "group_id" => "group-82"}),
          Map.merge(cancel_op("late-82", "2026-12-01"), %{"group_id" => "group-82"})
        ])

      conn = get_report(conn, "2026-12-01")
      late = hd(json_response(conn, 200)["data"]["cash"])
      assert late["movements"]["retained_cents"] == 2000
      assert late["closing_held_cents"] == 0

      {:ok, conn} =
        open_and_return(recycle(conn), [
          open_op(%{"operation_id" => "open-3", "group_id" => "group-83"}),
          Map.merge(pay_op(1000), %{"operation_id" => "pay-3", "group_id" => "group-83"}),
          Map.merge(cancel_op("credit-83", "2026-11-01", "hotel_credit"), %{
            "group_id" => "group-83"
          })
        ])

      conn = get_report(conn, "2026-11-01")
      converted = json_response(conn, 200)["data"]
      ams = Enum.find(converted["cash"], &(&1["property_id"] == "ams-canal"))
      assert ams["movements"]["converted_to_credit_cents"] == 1000
      assert converted["credit"]["movements"]["issued_cents"] == 1100
    end

    test "balances transfers across properties and follows later corrections", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(8000),
          start_op("2026-10-01"),
          open_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-92",
            "property_id" => "rot-harbor"
          }),
          %{
            "operation_id" => "op-xfer",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-06",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 8000
          },
          %{
            "operation_id" => "reduce-rot",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-07",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          }
        ])

      conn = get_report(conn, "2026-10-06")
      xfer = json_response(conn, 200)["data"]
      assert Enum.map(xfer["cash"], & &1["property_id"]) == ["ams-canal", "rot-harbor"]

      ams = Enum.at(xfer["cash"], 0)
      rot = Enum.at(xfer["cash"], 1)
      assert ams["opening_held_cents"] == 8000
      assert ams["movements"]["transferred_out_cents"] == 8000
      assert ams["closing_held_cents"] == 0
      assert rot["opening_held_cents"] == 0
      assert rot["movements"]["transferred_in_cents"] == 8000
      assert rot["closing_held_cents"] == 8000
      assert ams["movements"]["transferred_out_cents"] == rot["movements"]["transferred_in_cents"]
      assert_cash_identity(xfer)

      conn = get_report(conn, "2026-10-07")
      reduced = json_response(conn, 200)["data"]
      ams = Enum.find(reduced["cash"], &(&1["property_id"] == "ams-canal"))
      rot = Enum.find(reduced["cash"], &(&1["property_id"] == "rot-harbor"))
      assert is_nil(ams) or ams["movements"]["reduced_cents"] == 0
      assert rot["opening_held_cents"] == 8000
      assert rot["movements"]["reduced_cents"] == 1000
      assert rot["closing_held_cents"] == 7000
      assert_cash_identity(reduced)
    end

    test "reverses a refund as negative refunded plus charged back", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(4000),
          start_op("2026-10-01"),
          cancel_op("cancel-1", "2026-11-01"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "op-pay"
          }
        ])

      conn = get_report(conn, "2026-11-02")
      report = json_response(conn, 200)["data"]
      entry = hd(report["cash"])
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["refunded_cents"] == -4000
      assert entry["movements"]["charged_back_cents"] == 4000
      assert entry["closing_held_cents"] == 0
      assert_cash_identity(report)
    end

    test "keeps same-property transfers balanced", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(4000),
          start_op("2026-10-01"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-92"}),
          %{
            "operation_id" => "op-xfer",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-06",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 1500
          }
        ])

      conn = get_report(conn, "2026-10-06")
      report = json_response(conn, 200)["data"]
      assert length(report["cash"]) == 1
      entry = hd(report["cash"])
      assert entry["movements"]["transferred_in_cents"] == 1500
      assert entry["movements"]["transferred_out_cents"] == 1500
      assert entry["closing_held_cents"] == 4000
      assert_cash_identity(report)
    end

    test "reverses retained cash on chargeback", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(%{"rate_plan" => "advance_purchase"}),
          pay_op(4000),
          start_op("2026-10-01"),
          cancel_op("cancel-ap", "2026-10-05"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "op-pay"
          }
        ])

      conn = get_report(conn, "2026-10-06")
      report = json_response(conn, 200)["data"]
      entry = hd(report["cash"])
      assert entry["movements"]["retained_cents"] == -4000
      assert entry["movements"]["charged_back_cents"] == 4000
      assert entry["closing_held_cents"] == 0
      assert_cash_identity(report)
    end

    test "charges back held cash on the property that currently holds it", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          open_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-92",
            "property_id" => "rot-harbor"
          }),
          %{
            "operation_id" => "op-xfer",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-06",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 5000
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-08",
            "payment_operation_id" => "op-pay"
          }
        ])

      conn = get_report(conn, "2026-10-08")
      report = json_response(conn, 200)["data"]
      assert Enum.map(report["cash"], & &1["property_id"]) == ["rot-harbor"]
      rot = hd(report["cash"])
      assert rot["movements"]["charged_back_cents"] == 5000
      assert rot["closing_held_cents"] == 0
      assert_cash_identity(report)
    end
  end

  describe "credit movements" do
    test "does not treat apply or restore as liability movements", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("apply-1", "group-82", 3000, "2026-11-02"),
          Map.merge(cancel_op("cancel-82", "2026-11-03"), %{"group_id" => "group-82"})
        ])

      conn = get_report(conn, "2026-11-01")
      issued = json_response(conn, 200)["data"]["credit"]
      assert issued["opening_liability_cents"] == 0
      assert issued["movements"]["issued_cents"] == 5500
      assert issued["closing_liability_cents"] == 5500

      conn = get_report(conn, "2026-11-02")
      applied = json_response(conn, 200)["data"]["credit"]
      assert applied["opening_liability_cents"] == 5500
      assert applied["movements"] == zero_credit()["movements"]
      assert applied["closing_liability_cents"] == 5500

      conn = get_report(conn, "2026-11-03")
      restored = json_response(conn, 200)["data"]["credit"]
      assert restored["movements"] == zero_credit()["movements"]
      assert restored["closing_liability_cents"] == 5500
    end

    test "expires unused credit the day after expires_on even with no operation", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit")
        ])

      conn = get_report(conn, "2027-11-01")
      still_open = json_response(conn, 200)["data"]["credit"]
      assert still_open["opening_liability_cents"] == 5500
      assert still_open["movements"]["expired_cents"] == 0
      assert still_open["closing_liability_cents"] == 5500

      conn = get_report(conn, "2027-11-02")
      expired = json_response(conn, 200)["data"]["credit"]
      assert expired["opening_liability_cents"] == 5500
      assert expired["movements"]["expired_cents"] == 5500
      assert expired["closing_liability_cents"] == 0

      conn = get(conn, "/api/v1/ledger?on=2027-11-02")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0
    end

    test "records consumption, revocation, and absorption", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-2", "group_id" => "group-82"}),
          credit_op("apply-1", "group-82", 4000, "2026-11-02"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-04",
            "payment_operation_id" => "op-pay"
          }
        ])

      conn = get_report(conn, "2026-11-04")
      revoked = json_response(conn, 200)["data"]["credit"]
      assert revoked["opening_liability_cents"] == 5500
      assert revoked["movements"]["revoked_cents"] == 1500
      assert revoked["closing_liability_cents"] == 4000

      {:ok, conn} =
        open_and_return(recycle(conn), [
          Map.merge(cancel_op("cancel-82", "2026-11-05"), %{"group_id" => "group-82"})
        ])

      conn = get_report(conn, "2026-11-05")
      absorbed = json_response(conn, 200)["data"]["credit"]
      assert absorbed["opening_liability_cents"] == 4000
      assert absorbed["movements"]["absorbed_cents"] == 4000
      assert absorbed["closing_liability_cents"] == 0

      {:ok, conn} =
        open_and_return(recycle(conn), [
          open_op(%{"operation_id" => "open-3", "group_id" => "group-83"}),
          Map.merge(pay_op(2000), %{"operation_id" => "pay-3", "group_id" => "group-83"}),
          Map.merge(cancel_op("credit-83", "2026-11-01", "hotel_credit"), %{
            "group_id" => "group-83"
          }),
          open_op(%{"operation_id" => "open-4", "group_id" => "group-84"}),
          credit_op("apply-4", "group-84", 1000, "2026-11-02"),
          Map.merge(cancel_op("late-84", "2026-12-01"), %{"group_id" => "group-84"})
        ])

      conn = get_report(conn, "2026-12-01")
      consumed = json_response(conn, 200)["data"]["credit"]
      assert consumed["movements"]["consumed_cents"] == 1000
    end

    test "expires unused remainder and immediately-expired restorations on the same date", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          start_op("2026-10-01"),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{
            "operation_id" => "open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          credit_op("apply-1", "group-82", 3000, "2026-11-02"),
          Map.merge(cancel_op("cancel-82", "2027-11-02"), %{"group_id" => "group-82"})
        ])

      conn = get_report(conn, "2027-11-02")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["opening_liability_cents"] == 5500
      assert credit["movements"]["expired_cents"] == 5500
      assert credit["closing_liability_cents"] == 0
    end

    test "keeps pre-start credit in the opening and expires it later", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          start_op("2026-11-15")
        ])

      conn = get_report(conn, "2026-11-15")
      opening = json_response(conn, 200)["data"]["credit"]
      assert opening["opening_liability_cents"] == 5500
      assert opening["movements"]["issued_cents"] == 0
      assert opening["closing_liability_cents"] == 5500

      conn = get_report(conn, "2027-11-02")
      expired = json_response(conn, 200)["data"]["credit"]
      assert expired["movements"]["expired_cents"] == 5500
      assert expired["closing_liability_cents"] == 0
    end
  end

  describe "reconciliation and stability" do
    test "reading a report does not change ledger or group state", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(2500),
          start_op("2026-10-01")
        ])

      conn = get(conn, "/api/v1/groups/group-81")
      before_group = json_response(conn, 200)["data"]
      conn = get(conn, "/api/v1/ledger?on=2026-10-04")
      before_ledger = json_response(conn, 200)["data"]

      conn = get_report(conn, "2026-10-04")
      assert conn.status == 200
      conn = get_report(conn, "2026-10-01")
      assert conn.status == 200

      conn = get(recycle(conn), "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"] == before_group
      conn = get(conn, "/api/v1/ledger?on=2026-10-04")
      assert json_response(conn, 200)["data"] == before_ledger
    end

    test "matches current ledger cash and as-of credit after activity", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(6000),
          start_op("2026-10-01"),
          open_op(%{
            "operation_id" => "open-rot",
            "group_id" => "group-92",
            "property_id" => "rot-harbor"
          }),
          %{
            "operation_id" => "op-xfer",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-06",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 2000
          },
          cancel_op("cancel-ams", "2026-11-01")
        ])

      conn = get_report(conn, "2026-11-01")
      report = json_response(conn, 200)["data"]

      held =
        Enum.reduce(report["cash"], 0, fn entry, acc -> acc + entry["closing_held_cents"] end)

      conn = get(conn, "/api/v1/ledger?on=2026-11-01")
      ledger = json_response(conn, 200)["data"]
      assert held == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    end

    test "equivalent sequential submissions produce the same reports", %{conn: conn} do
      conn = post_batch(conn, [open_op()])
      conn = post_batch(conn, [start_op("2026-10-01")])
      conn = post_batch(conn, [pay_op(2000)])
      conn = post_batch(conn, [Map.merge(pay_op(1000), %{"operation_id" => "pay-2"})])

      conn = get_report(conn, "2026-10-04")
      report = json_response(conn, 200)["data"]

      assert report["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 3000}, 3000)
             ]
    end
  end

  defp start_op(starts_on, operation_id \\ "op-start") do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp get_report(conn, date) do
    get(recycle(conn), "/api/v1/finance/daily-report?date=#{date}")
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), movements),
      "closing_held_cents" => closing
    }
  end

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit do
    %{
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
  end

  defp assert_cash_identity(report) do
    Enum.each(report["cash"], fn entry ->
      m = entry["movements"]

      assert entry["closing_held_cents"] ==
               entry["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end)
  end

  defp open_and_return(conn, operations) do
    conn = post_batch(conn, operations)
    assert conn.status == 200
    {:ok, conn}
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp pay_op(amount_cents) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, occurred_on, refund_method \\ nil) do
    op = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-81"
    }

    if refund_method, do: Map.put(op, "refund_method", refund_method), else: op
  end

  defp credit_op(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
