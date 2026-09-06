defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Groups

  describe "start_finance_reporting" do
    test "enables reporting and returns exactly the applied start fields", %{conn: conn} do
      conn = post_batch(conn, [start_reporting_op()])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "start-fin",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 }
               ]
             }
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "start-missing",
            "type" => "start_finance_reporting"
          },
          %{
            "operation_id" => "start-bad",
            "type" => "start_finance_reporting",
            "starts_on" => "10/05/2026"
          }
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
      start = start_reporting_op()

      conn = post_batch(conn, [start])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn =
        post_batch(conn, [
          start,
          start_reporting_op(%{"operation_id" => "start-other", "starts_on" => "2026-11-01"})
        ])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "start-fin",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 },
                 %{
                   "operation_id" => "start-other",
                   "status" => "rejected",
                   "code" => "reporting_already_started"
                 }
               ]
             } = json_response(conn, 200)
    end

    test "conflicts when the start identifier is reused with a different payload", %{conn: conn} do
      conn = post_batch(conn, [start_reporting_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = post_batch(conn, [start_reporting_op(%{"starts_on" => "2026-10-06"})])

      assert %{
               "results" => [
                 %{
                   "operation_id" => "start-fin",
                   "status" => "rejected",
                   "code" => "operation_id_conflict"
                 }
               ]
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "rejects a missing or invalid date", %{conn: conn} do
      conn = get_json(conn, ~p"/api/v1/finance/daily-report")
      assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(conn, 422)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=not-a-date")
      assert %{"error" => %{"code" => "invalid_reporting_date"}} = json_response(conn, 422)
    end

    test "is unavailable before reporting starts or before starts_on", %{conn: conn} do
      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)

      conn = post_batch(conn, [start_reporting_op()])
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-09-30")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-01")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "date" => "2026-10-01",
                 "status" => "open",
                 "cash" => [],
                 "credit" => zero_credit()
               }
             }
    end

    test "puts pre-start activity into the opening position", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_group_op(),
          cash_payment_op("pay-pre", 5000, "group-81", "2026-10-20"),
          start_reporting_op(%{"starts_on" => "2026-10-05"}),
          cash_payment_op("pay-post", 1000, "group-81", "2026-10-01")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05")
      report = json_response(conn, 200)["data"]

      assert report["date"] == "2026-10-05"
      assert report["status"] == "open"

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => zero_cash_movements(%{"received_cents" => 1000}),
                 "closing_held_cents" => 6000
               }
             ]

      assert report["credit"] == zero_credit()
      assert_cash_identity(report)
      assert_credit_identity(report)
    end

    test "records cash, transfers, and later corrections by current property", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{
            "operation_id" => "op-open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          transfer_op("xfer-1", 2000, "2026-10-06"),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-07",
            "payment_operation_id" => "pay-17",
            "amount_cents" => 500
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      day_pay = json_response(conn, 200)["data"]

      assert hd(day_pay["cash"])["movements"]["received_cents"] == 5000
      assert hd(day_pay["cash"])["closing_held_cents"] == 5000

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-06")
      day_xfer = json_response(conn, 200)["data"]

      assert Enum.map(day_xfer["cash"], & &1["property_id"]) == ["ams-canal", "rot-harbour"]

      [canal, harbour] = day_xfer["cash"]
      assert canal["opening_held_cents"] == 5000
      assert canal["movements"]["transferred_out_cents"] == 2000
      assert canal["closing_held_cents"] == 3000
      assert harbour["opening_held_cents"] == 0
      assert harbour["movements"]["transferred_in_cents"] == 2000
      assert harbour["closing_held_cents"] == 2000

      transferred_in =
        Enum.reduce(day_xfer["cash"], 0, &(&1["movements"]["transferred_in_cents"] + &2))

      transferred_out =
        Enum.reduce(day_xfer["cash"], 0, &(&1["movements"]["transferred_out_cents"] + &2))

      assert transferred_in == transferred_out

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-07")
      day_reduce = json_response(conn, 200)["data"]
      harbour = Enum.find(day_reduce["cash"], &(&1["property_id"] == "rot-harbour"))
      canal = Enum.find(day_reduce["cash"], &(&1["property_id"] == "ams-canal"))

      assert harbour["movements"]["reduced_cents"] == 500
      assert harbour["closing_held_cents"] == 1500
      assert canal["movements"]["reduced_cents"] == 0
      assert canal["closing_held_cents"] == 3000

      Enum.each([day_pay, day_xfer, day_reduce], fn report ->
        assert_cash_identity(report)
        assert_credit_identity(report)
      end)

      assert_held_reconciles(conn, day_reduce)
    end

    test "reverses a refund as negative refunded plus charged back", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-17"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-11-01")
      cancel_day = json_response(conn, 200)["data"]
      assert hd(cancel_day["cash"])["movements"]["refunded_cents"] == 5000
      assert hd(cancel_day["cash"])["closing_held_cents"] == 0

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-11-02")
      cb_day = json_response(conn, 200)["data"]

      assert hd(cb_day["cash"])["movements"]["refunded_cents"] == -5000
      assert hd(cb_day["cash"])["movements"]["charged_back_cents"] == 5000
      assert hd(cb_day["cash"])["closing_held_cents"] == 0
      assert_cash_identity(cb_day)
    end

    test "issues, consumes, revokes, absorbs, and expires credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-11-01")
      issued_day = json_response(conn, 200)["data"]

      assert issued_day["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => zero_cash_movements(%{"converted_to_credit_cents" => 5000}),
                 "closing_held_cents" => 0
               }
             ]

      assert issued_day["credit"]["movements"]["issued_cents"] == 5500
      assert issued_day["credit"]["closing_liability_cents"] == 5500

      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          apply_credit_op("op-credit", 2000, "group-82", "2026-11-02")
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-11-02")
      apply_day = json_response(conn, 200)["data"]
      assert apply_day["credit"]["opening_liability_cents"] == 5500
      assert apply_day["credit"]["closing_liability_cents"] == 5500
      assert apply_day["credit"]["movements"] == zero_credit_movements()

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2027-11-02")
      expiry_day = json_response(conn, 200)["data"]
      assert expiry_day["credit"]["movements"]["expired_cents"] == 3500
      assert expiry_day["credit"]["closing_liability_cents"] == 2000

      conn = get_json(conn, ~p"/api/v1/ledger?on=2027-11-02")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 2000

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-03",
            "payment_operation_id" => "pay-1"
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-11-03")
      revoke_day = json_response(conn, 200)["data"]
      assert revoke_day["credit"]["movements"]["revoked_cents"] == 3500
      assert revoke_day["credit"]["closing_liability_cents"] == 2000
      assert hd(revoke_day["cash"])["movements"]["converted_to_credit_cents"] == -5000
      assert hd(revoke_day["cash"])["movements"]["charged_back_cents"] == 5000

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2027-11-03",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2027-11-03")
      absorb_day = json_response(conn, 200)["data"]
      assert absorb_day["credit"]["movements"]["absorbed_cents"] == 2000
      assert absorb_day["credit"]["closing_liability_cents"] == 0
      assert_credit_identity(absorb_day)
    end

    test "consumes applied credit on a non-refundable cancellation", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{"operation_id" => "op-open-2", "group_id" => "group-82"}),
          apply_credit_op("op-credit", 2000, "group-82", "2026-11-02"),
          %{
            "operation_id" => "cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2026-12-09",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-12-09")
      report = json_response(conn, 200)["data"]
      assert report["credit"]["movements"]["consumed_cents"] == 2000
      assert report["credit"]["closing_liability_cents"] == 3500
      assert_credit_identity(report)
    end

    test "does not move or change state when a report is read", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000)
        ])

      assert %{"results" => [_, _, %{"revision" => 2}]} = json_response(conn, 200)

      first = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      first_body = json_response(first, 200)
      second = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      assert json_response(second, 200) == first_body

      conn = get_json(conn, ~p"/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 5000}} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/ledger")
      assert %{"data" => %{"cash_held_cents" => 5000}} = json_response(conn, 200)
    end

    test "does not record rejected or retried operations twice", %{conn: conn} do
      payment = cash_payment_op("pay-17", 5000)

      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          payment,
          %{
            "operation_id" => "pay-too-much",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 20000
          }
        ])

      assert %{
               "results" => [
                 _,
                 _,
                 %{"status" => "applied"},
                 %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
               ]
             } = json_response(conn, 200)

      conn = post_batch(conn, [payment])

      assert %{"results" => [%{"status" => "applied", "amount_cents" => 5000}]} =
               json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      report = json_response(conn, 200)["data"]
      assert hd(report["cash"])["movements"]["received_cents"] == 5000
      assert hd(report["cash"])["closing_held_cents"] == 5000
    end

    test "posts late submissions to the later of occurred_on and starts_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(%{"starts_on" => "2026-10-10"}),
          open_group_op(),
          cash_payment_op("pay-late", 4000, "group-81", "2026-10-04")
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      assert %{"error" => %{"code" => "report_not_available"}} = json_response(conn, 404)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-10")
      report = json_response(conn, 200)["data"]
      assert hd(report["cash"])["movements"]["received_cents"] == 4000
      assert hd(report["cash"])["closing_held_cents"] == 4000
    end

    test "follows settled cash to the destination property on chargeback", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-17", 5000),
          open_group_op(%{
            "operation_id" => "op-open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          transfer_op("xfer-1", 2000, "2026-10-06"),
          %{
            "operation_id" => "cancel-92",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-92"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-02",
            "payment_operation_id" => "pay-17"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-11-02")
      report = json_response(conn, 200)["data"]
      canal = Enum.find(report["cash"], &(&1["property_id"] == "ams-canal"))
      harbour = Enum.find(report["cash"], &(&1["property_id"] == "rot-harbour"))

      assert canal["movements"]["charged_back_cents"] == 3000
      assert canal["movements"]["refunded_cents"] == 0
      assert harbour["movements"]["charged_back_cents"] == 2000
      assert harbour["movements"]["refunded_cents"] == -2000
      assert_cash_identity(report)
    end

    test "retains cash and lets a later backdated payment change an earlier report", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(%{"rate_plan" => "advance_purchase"}),
          cash_payment_op("pay-17", 5000),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-08",
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-08")
      before = json_response(conn, 200)["data"]
      assert hd(before["cash"])["movements"]["retained_cents"] == 5000

      conn =
        post_batch(conn, [
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "property_id" => "rot-harbour"
          }),
          cash_payment_op("pay-back", 1000, "group-82", "2026-10-08")
        ])

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-08")
      after_report = json_response(conn, 200)["data"]
      canal = Enum.find(after_report["cash"], &(&1["property_id"] == "ams-canal"))
      harbour = Enum.find(after_report["cash"], &(&1["property_id"] == "rot-harbour"))

      assert canal["movements"]["retained_cents"] == 5000
      assert harbour["movements"]["received_cents"] == 1000
      refute after_report == before
      assert_cash_identity(after_report)
    end

    test "expires restored credit immediately when the lot is already past", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          cash_payment_op("pay-1", 5000),
          %{
            "operation_id" => "cancel-17",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          },
          open_group_op(%{
            "operation_id" => "op-open-2",
            "group_id" => "group-82",
            "arrival_on" => "2028-01-10",
            "departure_on" => "2028-01-13"
          }),
          apply_credit_op("op-credit", 5500, "group-82", "2026-11-02"),
          %{
            "operation_id" => "cancel-82",
            "type" => "cancel_group",
            "occurred_on" => "2027-11-03",
            "group_id" => "group-82"
          }
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2027-11-02")
      expiry_day = json_response(conn, 200)["data"]
      assert expiry_day["credit"]["movements"]["expired_cents"] == 0
      assert expiry_day["credit"]["closing_liability_cents"] == 5500

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2027-11-03")
      restore_day = json_response(conn, 200)["data"]
      assert restore_day["credit"]["movements"]["expired_cents"] == 5500
      assert restore_day["credit"]["closing_liability_cents"] == 0
      assert_credit_identity(restore_day)
    end

    test "omits properties whose balances and movements are all zero", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting_op(),
          open_group_op(),
          open_group_op(%{
            "operation_id" => "op-open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          cash_payment_op("pay-17", 1000)
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04")
      report = json_response(conn, 200)["data"]
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal"]
    end

    test "equivalent sequential submissions produce a complete report", %{conn: conn} do
      conn = post_batch(conn, [start_reporting_op()])
      conn = post_batch(conn, [open_group_op()])
      conn = post_batch(conn, [cash_payment_op("pay-17", 5000)])

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81"
          }
        ])

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      conn = get_json(conn, ~p"/api/v1/finance/daily-report?date=2026-11-01")
      report = json_response(conn, 200)["data"]
      assert hd(report["cash"])["movements"]["refunded_cents"] == 5000
      assert hd(report["cash"])["closing_held_cents"] == 0
      assert_cash_identity(report)
      assert_held_reconciles(conn, report)
    end
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

  defp assert_credit_identity(report) do
    c = report["credit"]
    m = c["movements"]

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]
  end

  defp assert_held_reconciles(conn, report) do
    held =
      Enum.reduce(report["cash"], 0, fn entry, acc -> acc + entry["closing_held_cents"] end)

    ledger = json_response(get_json(conn, ~p"/api/v1/ledger"), 200)["data"]
    assert held == ledger["cash_held_cents"]
    assert Groups.ledger()[:cash_held_cents] == held
  end

  defp zero_cash_movements(overrides) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp zero_credit do
    %{
      "opening_liability_cents" => 0,
      "movements" => zero_credit_movements(),
      "closing_liability_cents" => 0
    }
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp get_json(conn, path) do
    conn
    |> recycle()
    |> get(path)
  end

  defp start_reporting_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "start-fin",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-01"
      },
      overrides
    )
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp cash_payment_op(
         operation_id,
         amount_cents,
         group_id \\ "group-81",
         occurred_on \\ "2026-10-04"
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit_op(operation_id, amount_cents, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(operation_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => "group-81",
      "destination_group_id" => "group-92",
      "amount_cents" => amount_cents
    }
  end
end
