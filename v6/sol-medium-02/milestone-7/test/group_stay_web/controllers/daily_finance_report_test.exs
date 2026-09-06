defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(id, group_id, property_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "open_group",
        "occurred_on" => "2026-10-01",
        "group_id" => group_id,
        "guest_id" => "guest",
        "property_id" => property_id,
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1_000}]
      },
      overrides
    )
  end

  defp pay(id, group_id, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp start(id, starts_on) do
    %{
      "operation_id" => id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "captures the operation-order inception point, clamps posting dates, and replays once", %{
    conn: conn
  } do
    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-10")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert get(conn, "/api/v1/finance/daily-report") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert get(conn, "/api/v1/finance/daily-report?date=nope") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    [invalid_start] =
      submit(conn, [%{"operation_id" => "invalid-start", "type" => "start_finance_reporting"}])

    assert invalid_start["code"] == "invalid_reporting_date"

    submit(conn, [open("open", "group", "ams")])

    [before, started, after_start, rejected] =
      submit(conn, [
        pay("before", "group", 100, "2026-12-01"),
        start("start", "2026-10-10"),
        pay("after", "group", 50, "2026-10-01"),
        pay("rejected", "group", 10_000, "2026-10-10")
      ])

    assert before["status"] == "applied"

    assert started == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-10-10"
           }

    assert after_start["status"] == "applied"
    assert rejected["status"] == "rejected"

    assert report(conn, "2026-10-10") == %{
             "date" => "2026-10-10",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams",
                 "opening_held_cents" => 100,
                 "movements" => %{
                   "received_cents" => 50,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 150
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

    assert submit(conn, [start("start", "2026-10-10")]) == [started]

    [duplicate_start] = submit(conn, [start("another-start", "2026-10-10")])
    assert duplicate_start["code"] == "reporting_already_started"

    # A payment retry returns its exact durable result and adds no second movement.
    assert submit(conn, [pay("after", "group", 50, "2026-10-01")]) == [after_start]
    assert hd(report(conn, "2026-10-10")["cash"])["movements"]["received_cents"] == 50

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-09")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "follows transferred cash to the property where reductions and settlement occur", %{
    conn: conn
  } do
    submit(conn, [
      start("start", "2026-10-01"),
      open("ams-open", "ams-group", "ams"),
      open("rot-open", "rot-group", "rot"),
      pay("payment", "ams-group", 200, "2026-10-02"),
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-03",
        "source_group_id" => "ams-group",
        "destination_group_id" => "rot-group",
        "amount_cents" => 150
      },
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-04",
        "payment_operation_id" => "payment",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "rot-group"
      },
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "payment"
      }
    ])

    transfer = report(conn, "2026-10-03")["cash"]
    assert Enum.map(transfer, & &1["property_id"]) == ["ams", "rot"]
    assert hd(transfer)["movements"]["transferred_out_cents"] == 150
    assert List.last(transfer)["movements"]["transferred_in_cents"] == 150

    reduced = Enum.find(report(conn, "2026-10-04")["cash"], &(&1["property_id"] == "rot"))
    assert reduced["property_id"] == "rot"
    assert reduced["opening_held_cents"] == 150
    assert reduced["movements"]["reduced_cents"] == 100
    assert reduced["closing_held_cents"] == 50

    retained = Enum.find(report(conn, "2026-10-05")["cash"], &(&1["property_id"] == "rot"))
    assert retained["property_id"] == "rot"
    assert retained["movements"]["retained_cents"] == 50
    assert retained["closing_held_cents"] == 0

    charged = report(conn, "2026-10-06")["cash"]
    assert Enum.map(charged, & &1["property_id"]) == ["ams", "rot"]

    assert Enum.at(charged, 0)["movements"]["charged_back_cents"] == 50
    assert Enum.at(charged, 0)["closing_held_cents"] == 0

    assert Enum.at(charged, 1)["movements"]["retained_cents"] == -50
    assert Enum.at(charged, 1)["movements"]["charged_back_cents"] == 50
    assert Enum.at(charged, 1)["closing_held_cents"] == 0
  end

  test "reports issuance, paused expiry, late backdated changes, and consumption", %{conn: conn} do
    flexible = %{
      "arrival_on" => "2026-04-01",
      "departure_on" => "2026-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 500}]
    }

    submit(conn, [
      start("start", "2026-01-01"),
      open("source-open", "source", "ams", flexible),
      pay("source-pay", "source", 100, "2026-01-02"),
      %{
        "operation_id" => "issue",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open("target-open", "target", "ams", %{
        "occurred_on" => "2026-02-02",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 60}]
      }),
      %{
        "operation_id" => "apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-31",
        "group_id" => "target",
        "amount_cents" => 60
      }
    ])

    issued = report(conn, "2026-02-01")["credit"]
    assert issued["movements"]["issued_cents"] == 110
    assert issued["closing_liability_cents"] == 110

    first_expiry = report(conn, "2027-02-02")["credit"]
    assert first_expiry["movements"]["expired_cents"] == 50
    assert first_expiry["closing_liability_cents"] == 60

    # A late submission with an earlier occurred_on date changes the still-open expiry report.
    submit(conn, [
      open("late-target-open", "late-target", "ams", %{
        "occurred_on" => "2027-01-30",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 50}]
      }),
      %{
        "operation_id" => "late-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-02-01",
        "group_id" => "late-target",
        "amount_cents" => 50
      }
    ])

    revised_expiry = report(conn, "2027-02-02")["credit"]
    assert revised_expiry["movements"]["expired_cents"] == 0
    assert revised_expiry["closing_liability_cents"] == 110

    submit(conn, [
      %{
        "operation_id" => "consume-target",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "target"
      },
      %{
        "operation_id" => "consume-late-target",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "late-target"
      }
    ])

    consumed = report(conn, "2027-02-03")["credit"]
    assert consumed["opening_liability_cents"] == 110
    assert consumed["movements"]["consumed_cents"] == 110
    assert consumed["closing_liability_cents"] == 0
    assert report(conn, "2027-02-03")["credit"] == consumed
  end

  test "classifies credit revocation and later shortfall absorption", %{conn: conn} do
    flexible = %{
      "arrival_on" => "2026-04-01",
      "departure_on" => "2026-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 500}]
    }

    submit(conn, [
      start("start", "2026-01-01"),
      open("source-open", "source", "ams", flexible),
      pay("source-pay", "source", 100, "2026-01-02"),
      %{
        "operation_id" => "issue",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-01",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open("target-open", "target", "ams", flexible),
      %{
        "operation_id" => "apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-02-02",
        "group_id" => "target",
        "amount_cents" => 60
      },
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-02-03",
        "payment_operation_id" => "source-pay"
      }
    ])

    chargeback = report(conn, "2026-02-03")
    assert chargeback["credit"]["opening_liability_cents"] == 110
    assert chargeback["credit"]["movements"]["revoked_cents"] == 50
    assert chargeback["credit"]["closing_liability_cents"] == 60

    [cash] = chargeback["cash"]
    assert cash["movements"]["converted_to_credit_cents"] == -100
    assert cash["movements"]["charged_back_cents"] == 100
    assert cash["closing_held_cents"] == 0

    submit(conn, [
      %{
        "operation_id" => "restore",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-04",
        "group_id" => "target"
      }
    ])

    restored = report(conn, "2026-02-04")["credit"]
    assert restored["opening_liability_cents"] == 60
    assert restored["movements"]["absorbed_cents"] == 60
    assert restored["closing_liability_cents"] == 0
  end
end
