defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  describe "start_finance_reporting" do
    test "applies with exactly operation_id, status, and starts_on", %{conn: conn} do
      conn = post_batch(conn, [start_reporting("fin-start", "2026-10-01")])

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "fin-start",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 }
               ]
             }
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{"operation_id" => "fin-missing", "type" => "start_finance_reporting"},
          %{
            "operation_id" => "fin-bad",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-13-40"
          },
          %{
            "operation_id" => "fin-empty",
            "type" => "start_finance_reporting",
            "starts_on" => ""
          }
        ])

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "fin-missing",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               },
               %{
                 "operation_id" => "fin-bad",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               },
               %{
                 "operation_id" => "fin-empty",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
    end

    test "rejects a second start and replays the original", %{conn: conn} do
      original = start_reporting("fin-start", "2026-10-01")

      conn =
        post_batch(conn, [
          original,
          start_reporting("fin-other", "2026-10-02")
        ])

      assert [
               %{"status" => "applied", "starts_on" => "2026-10-01"},
               %{
                 "operation_id" => "fin-other",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ] = json_response(conn, 200)["results"]

      conn = post_batch(conn, [original])

      assert json_response(conn, 200)["results"] == [
               %{
                 "operation_id" => "fin-start",
                 "status" => "applied",
                 "starts_on" => "2026-10-01"
               }
             ]

      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-11-01")
        ])

      assert [
               %{"status" => "rejected", "code" => "operation_id_conflict"}
             ] = json_response(conn, 200)["results"]
    end

    test "does not address a group or use a revision guard", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          Map.merge(start_reporting("fin-start", "2026-10-01"), %{
            "group_id" => "group-81",
            "expected_revision" => 0
          })
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "starts_on" => "2026-10-01"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end
  end

  describe "GET /api/v1/finance/daily-report" do
    test "rejects a missing or invalid date", %{conn: conn} do
      conn = get(conn, "/api/v1/finance/daily-report")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = get(conn, "/api/v1/finance/daily-report?date=not-a-date")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-13-01")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "returns report_not_available before start or before starts_on", %{conn: conn} do
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-01")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      conn = post_batch(conn, [start_reporting("fin-start", "2026-10-10")])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-09")
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "returns an empty open report on starts_on", %{conn: conn} do
      conn = post_batch(conn, [start_reporting("fin-start", "2026-10-01")])
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-01")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "date" => "2026-10-01",
                 "status" => "open",
                 "cash" => [],
                 "credit" => empty_credit(0, 0)
               }
             }
    end

    test "puts pre-start activity into the opening position", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("pay-1", "group-81", 5000, "2026-10-15"),
          start_reporting("fin-start", "2026-10-01")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-01")
      report = json_response(conn, 200)["data"]

      assert report["cash"] == [
               cash_entry("ams-canal", 5000, %{received_cents: 0}, 5000)
             ]

      assert report["credit"] == empty_credit(0, 0)
    end

    test "splits the same batch around the start operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("pay-before", "group-81", 2000, "2026-10-15"),
          start_reporting("fin-start", "2026-10-01"),
          cash_payment("pay-after", "group-81", 3000, "2026-10-01")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-01")
      report = json_response(conn, 200)["data"]

      assert report["cash"] == [
               cash_entry("ams-canal", 2000, %{received_cents: 3000}, 5000)
             ]
    end

    test "posts later operations to max(occurred_on, starts_on)", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-10"),
          example_open(),
          cash_payment("pay-1", "group-81", 1500, "2026-10-04")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-10")
      report = json_response(conn, 200)["data"]

      assert report["cash"] == [
               cash_entry("ams-canal", 0, %{received_cents: 1500}, 1500)
             ]

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-11")
      later = json_response(conn, 200)["data"]

      assert later["cash"] == [
               cash_entry("ams-canal", 1500, %{}, 1500)
             ]
    end

    test "records cash classifications and keeps the identity", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          cash_payment("pay-1", "group-81", 4000, "2026-10-04"),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "pay-1",
            "amount_cents" => 500
          },
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-81"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")

      assert hd(json_response(conn, 200)["data"]["cash"]) ==
               cash_entry("ams-canal", 0, %{received_cents: 4000}, 4000)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")

      assert hd(json_response(conn, 200)["data"]["cash"]) ==
               cash_entry("ams-canal", 4000, %{reduced_cents: 500}, 3500)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")

      assert hd(json_response(conn, 200)["data"]["cash"]) ==
               cash_entry("ams-canal", 3500, %{refunded_cents: 3500}, 0)

      assert_cash_identity(hd(json_response(conn, 200)["data"]["cash"]))
    end

    test "records retained and converted cash", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(%{
            "operation_id" => "open-ap",
            "group_id" => "g-ap",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "only", "nightly_rate_cents" => 1000}]
          }),
          cash_payment("pay-ap", "g-ap", 3000, "2026-10-04"),
          %{
            "operation_id" => "cancel-ap",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "g-ap"
          },
          example_open(%{"operation_id" => "open-flex", "group_id" => "g-flex"}),
          cash_payment("pay-flex", "g-flex", 2000, "2026-10-04"),
          %{
            "operation_id" => "cancel-flex",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "g-flex",
            "refund_method" => "hotel_credit"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      report = json_response(conn, 200)["data"]
      [cash] = report["cash"]

      assert cash ==
               cash_entry(
                 "ams-canal",
                 5000,
                 %{retained_cents: 3000, converted_to_credit_cents: 2000},
                 0
               )

      assert report["credit"]["movements"]["issued_cents"] == 2200
      assert report["credit"]["closing_liability_cents"] == 2200
    end

    test "transfers cash between properties and follows later corrections", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          example_open(%{
            "operation_id" => "open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          cash_payment("pay-1", "group-81", 4000, "2026-10-04"),
          transfer("xfer-1", "group-81", "group-92", 1500, "2026-10-05"),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "pay-1",
            "amount_cents" => 500
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      day = json_response(conn, 200)["data"]

      assert Enum.map(day["cash"], & &1["property_id"]) == ["ams-canal", "rot-harbour"]

      assert Enum.at(day["cash"], 0) ==
               cash_entry("ams-canal", 4000, %{transferred_out_cents: 1500}, 2500)

      assert Enum.at(day["cash"], 1) ==
               cash_entry("rot-harbour", 0, %{transferred_in_cents: 1500}, 1500)

      assert transfer_balanced?(day)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      later = json_response(conn, 200)["data"]

      assert Enum.at(later["cash"], 0) == cash_entry("ams-canal", 2500, %{}, 2500)

      assert Enum.at(later["cash"], 1) ==
               cash_entry("rot-harbour", 1500, %{reduced_cents: 500}, 1000)
    end

    test "reverses a refund as negative refunded plus charged_back", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          cash_payment("pay-1", "group-81", 2000, "2026-10-04"),
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
            "payment_operation_id" => "pay-1"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      [cash] = json_response(conn, 200)["data"]["cash"]

      assert cash ==
               cash_entry("ams-canal", 0, %{refunded_cents: -2000, charged_back_cents: 2000}, 0)
    end

    test "omits a property only when opening, closing, and movements are zero", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(%{
            "operation_id" => "open-other",
            "group_id" => "g-other",
            "property_id" => "brs-harbour"
          }),
          example_open(),
          cash_payment("pay-1", "group-81", 1000, "2026-10-04")
        ])

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")
      report = json_response(conn, 200)["data"]

      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal"]
    end

    test "does not move credit liability when applying or restoring credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(%{"group_id" => "g1", "operation_id" => "open-1"}),
          cash_payment("pay-1", "g1", 2000, "2026-10-04"),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-2", "group_id" => "g2"}),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 800
          },
          %{
            "operation_id" => "cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "g2"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")
      apply_day = json_response(conn, 200)["data"]["credit"]
      assert apply_day["opening_liability_cents"] == 2200
      assert apply_day["movements"] == zero_credit_movements()
      assert apply_day["closing_liability_cents"] == 2200

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      restore_day = json_response(conn, 200)["data"]["credit"]
      assert restore_day["movements"] == zero_credit_movements()
      assert restore_day["closing_liability_cents"] == 2200
    end

    test "expires unused credit on the day after expires_on without an operation", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          cash_payment("pay-1", "group-81", 1000, "2026-10-04"),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-04")
      last_live = json_response(conn, 200)["data"]["credit"]
      assert last_live["opening_liability_cents"] == 1100
      assert last_live["movements"]["expired_cents"] == 0
      assert last_live["closing_liability_cents"] == 1100

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-05")
      expired = json_response(conn, 200)["data"]["credit"]
      assert expired["opening_liability_cents"] == 1100
      assert expired["movements"]["expired_cents"] == 1100
      assert expired["closing_liability_cents"] == 0

      conn = get(conn, "/api/v1/ledger?on=2027-10-05")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 0
    end

    test "records consumed, revoked, and absorbed credit", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(%{
            "operation_id" => "open-1",
            "group_id" => "g1",
            "arrival_on" => "2026-10-20",
            "departure_on" => "2026-10-22"
          }),
          cash_payment("pay-1", "g1", 2000, "2026-10-04"),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{
            "operation_id" => "open-2",
            "group_id" => "g2",
            "arrival_on" => "2026-10-20",
            "departure_on" => "2026-10-22"
          }),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 800
          },
          %{
            "operation_id" => "cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-10",
            "group_id" => "g2"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-10")
      consumed = json_response(conn, 200)["data"]["credit"]
      assert consumed["movements"]["consumed_cents"] == 800
      assert consumed["closing_liability_cents"] == 1400

      conn =
        post_batch(conn, [
          example_open(%{"operation_id" => "open-3", "group_id" => "g3"}),
          cash_payment("pay-3", "g3", 1000, "2026-10-11"),
          %{
            "operation_id" => "cancel-3",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-11",
            "group_id" => "g3",
            "refund_method" => "hotel_credit"
          },
          %{
            "operation_id" => "cb-3",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-12",
            "payment_operation_id" => "pay-3"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-12")
      revoked = json_response(conn, 200)["data"]["credit"]
      assert revoked["movements"]["revoked_cents"] == 1100
      assert revoked["closing_liability_cents"] == 1400

      conn =
        post_batch(conn, [
          example_open(%{
            "operation_id" => "open-4",
            "group_id" => "g4",
            "guest_id" => "guest-abs"
          }),
          cash_payment("pay-4", "g4", 1000, "2026-10-13"),
          %{
            "operation_id" => "cancel-4",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-13",
            "group_id" => "g4",
            "refund_method" => "hotel_credit"
          },
          example_open(%{
            "operation_id" => "open-5",
            "group_id" => "g5",
            "guest_id" => "guest-abs"
          }),
          %{
            "operation_id" => "apply-5",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-13",
            "group_id" => "g5",
            "amount_cents" => 400
          },
          %{
            "operation_id" => "cb-4",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-14",
            "payment_operation_id" => "pay-4"
          },
          %{
            "operation_id" => "cancel-5",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-15",
            "group_id" => "g5"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-14")
      after_cb = json_response(conn, 200)["data"]["credit"]
      assert after_cb["movements"]["revoked_cents"] == 700

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-15")
      absorbed = json_response(conn, 200)["data"]["credit"]
      assert absorbed["movements"]["absorbed_cents"] == 400
    end

    test "expires restored credit immediately when the lot is already past expiry", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(%{"group_id" => "g1", "operation_id" => "open-1"}),
          cash_payment("pay-1", "g1", 2000, "2026-10-04"),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{
            "operation_id" => "open-2",
            "group_id" => "g2",
            "arrival_on" => "2028-01-01",
            "departure_on" => "2028-01-04"
          }),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 800
          },
          %{
            "operation_id" => "cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2027-10-05",
            "group_id" => "g2"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-05")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["expired_cents"] == 2200
      assert credit["closing_liability_cents"] == 0
    end

    test "rejected operations and retries do not double-count movements", %{conn: conn} do
      pay = cash_payment("pay-1", "group-81", 1000, "2026-10-04")

      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          pay,
          cash_payment("pay-bad", "missing", 100, "2026-10-04"),
          pay
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.at(results, 2)["status"] == "applied"
      assert Enum.at(results, 3)["code"] == "group_not_found"
      assert Enum.at(results, 4) == Enum.at(results, 2)

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 1000
    end

    test "keeps earlier movements when a later batch operation is rejected", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          cash_payment("pay-1", "group-81", 1000, "2026-10-04"),
          cash_payment("pay-2", "missing", 100, "2026-10-04")
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"code" => "group_not_found"}
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")
      [cash] = json_response(conn, 200)["data"]["cash"]
      assert cash["movements"]["received_cents"] == 1000
    end

    test "later submissions can change an earlier open report", %{conn: conn} do
      conn = post_batch(conn, [start_reporting("fin-start", "2026-10-01")])
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")
      assert json_response(conn, 200)["data"]["cash"] == []

      conn =
        post_batch(conn, [
          example_open(),
          cash_payment("pay-1", "group-81", 750, "2026-10-04")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")

      assert hd(json_response(conn, 200)["data"]["cash"]) ==
               cash_entry("ams-canal", 0, %{received_cents: 750}, 750)
    end

    test "reading a report never changes domain state", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          cash_payment("pay-1", "group-81", 1000, "2026-10-04")
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      conn = get(conn, "/api/v1/groups/group-81")
      group = json_response(conn, 200)["data"]

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")
      first = json_response(conn, 200)["data"]
      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-04")
      assert json_response(conn, 200)["data"] == first

      conn = get(conn, "/api/v1/ledger")
      assert json_response(conn, 200)["data"] == ledger
      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"] == group
    end

    test "reconciles report closings to the current ledger", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          example_open(%{
            "operation_id" => "open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          cash_payment("pay-1", "group-81", 5000, "2026-10-04"),
          transfer("xfer-1", "group-81", "group-92", 2000, "2026-10-05"),
          %{
            "operation_id" => "cancel-92",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-92",
            "refund_method" => "hotel_credit"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]

      held =
        Enum.reduce(report["cash"], 0, fn entry, acc -> acc + entry["closing_held_cents"] end)

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert held == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    end

    test "sequential submissions produce the same report as one batch", %{conn: conn} do
      conn = post_batch(conn, [start_reporting("fin-start", "2026-10-01")])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]
      conn = post_batch(conn, [example_open()])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]
      conn = post_batch(conn, [cash_payment("pay-1", "group-81", 2500, "2026-10-04")])
      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81"
          }
        ])

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-05")

      assert hd(json_response(conn, 200)["data"]["cash"]) ==
               cash_entry("ams-canal", 2500, %{refunded_cents: 2500}, 0)
    end

    test "does not expire credit that is still applied to a group", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(%{"group_id" => "g1", "operation_id" => "open-1"}),
          cash_payment("pay-1", "g1", 1000, "2026-10-04"),
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "g1",
            "refund_method" => "hotel_credit"
          },
          example_open(%{"operation_id" => "open-2", "group_id" => "g2"}),
          %{
            "operation_id" => "apply-1",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "g2",
            "amount_cents" => 400
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2027-10-05")
      credit = json_response(conn, 200)["data"]["credit"]
      assert credit["movements"]["expired_cents"] == 700
      assert credit["closing_liability_cents"] == 400

      conn = get(conn, "/api/v1/ledger?on=2027-10-05")
      assert json_response(conn, 200)["data"]["credit_liability_cents"] == 400
    end

    test "chargeback of held cash follows the destination property", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          example_open(%{
            "operation_id" => "open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          cash_payment("pay-1", "group-81", 4000, "2026-10-04"),
          transfer("xfer-1", "group-81", "group-92", 4000, "2026-10-05"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-06",
            "payment_operation_id" => "pay-1"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-06")
      report = json_response(conn, 200)["data"]

      refute Enum.any?(report["cash"], &(&1["property_id"] == "ams-canal"))
      dest = Enum.find(report["cash"], &(&1["property_id"] == "rot-harbour"))
      assert dest == cash_entry("rot-harbour", 4000, %{charged_back_cents: 4000}, 0)
    end

    test "chargeback of converted cash follows the settlement property", %{conn: conn} do
      conn =
        post_batch(conn, [
          start_reporting("fin-start", "2026-10-01"),
          example_open(),
          example_open(%{
            "operation_id" => "open-92",
            "group_id" => "group-92",
            "property_id" => "rot-harbour"
          }),
          cash_payment("pay-1", "group-81", 4000, "2026-10-04"),
          transfer("xfer-1", "group-81", "group-92", 4000, "2026-10-05"),
          %{
            "operation_id" => "cancel-92",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-06",
            "group_id" => "group-92",
            "refund_method" => "hotel_credit"
          },
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-07",
            "payment_operation_id" => "pay-1"
          }
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(conn, "/api/v1/finance/daily-report?date=2026-10-07")
      report = json_response(conn, 200)["data"]
      dest = Enum.find(report["cash"], &(&1["property_id"] == "rot-harbour"))

      assert dest ==
               cash_entry(
                 "rot-harbour",
                 0,
                 %{
                   converted_to_credit_cents: -4000,
                   charged_back_cents: 4000
                 },
                 0
               )

      assert report["credit"]["movements"]["revoked_cents"] == 4400
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "exposes the stored start result through the operations endpoint", %{conn: conn} do
      conn = post_batch(conn, [start_reporting("fin-start", "2026-10-01")])
      result = hd(json_response(conn, 200)["results"])

      conn = get(conn, "/api/v1/operations/fin-start")
      assert json_response(conn, 200) == %{"data" => result}
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp example_open(overrides \\ %{}) do
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

  defp cash_payment(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer(operation_id, source_group_id, destination_group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cash_entry(property_id, opening, movement_overrides, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), stringify_keys(movement_overrides)),
      "closing_held_cents" => closing
    }
  end

  defp empty_credit(opening, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => zero_credit_movements(),
      "closing_liability_cents" => closing
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

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp assert_cash_identity(entry) do
    movs = entry["movements"]

    assert entry["closing_held_cents"] ==
             entry["opening_held_cents"] + movs["received_cents"] + movs["transferred_in_cents"] -
               movs["transferred_out_cents"] - movs["refunded_cents"] - movs["retained_cents"] -
               movs["converted_to_credit_cents"] - movs["reduced_cents"] -
               movs["charged_back_cents"]
  end

  defp transfer_balanced?(report) do
    {ins, outs} =
      Enum.reduce(report["cash"], {0, 0}, fn entry, {ins, outs} ->
        {ins + entry["movements"]["transferred_in_cents"],
         outs + entry["movements"]["transferred_out_cents"]}
      end)

    ins == outs
  end
end
