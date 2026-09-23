defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_operation(group_id, property_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: group_id,
        guest_id: "daily-report-guest",
        property_id: property_id,
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-#{group_id}", nightly_rate_cents: 1000}]
      },
      overrides
    )
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "starting reporting snapshots current balances and clips later posting dates", %{
    conn: conn
  } do
    assert conn
           |> get("/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    start = %{
      operation_id: "start-reporting",
      type: "start_finance_reporting",
      starts_on: "2026-10-01"
    }

    results =
      post_batch(conn, [
        open_operation("opening-group", "hotel-a"),
        %{
          operation_id: "opening-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-03",
          group_id: "opening-group",
          amount_cents: 50
        },
        start,
        %{
          operation_id: "backdated-payment",
          type: "record_cash_payment",
          occurred_on: "2026-09-20",
          group_id: "opening-group",
          amount_cents: 25
        }
      ])

    assert Enum.at(results, 2) == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2026-10-01"
           }

    assert Enum.at(results, 3)["status"] == "applied"

    assert report(conn, "2026-10-01") == %{
             "date" => "2026-10-01",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "hotel-a",
                 "opening_held_cents" => 50,
                 "movements" => %{
                   "received_cents" => 25,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 75
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

    assert conn
           |> get("/api/v1/finance/daily-report?date=2026-09-30")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert conn
           |> get("/api/v1/finance/daily-report")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert conn
           |> get("/api/v1/finance/daily-report?date=not-a-date")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert post_batch(conn, [start]) |> hd() == Enum.at(results, 2)

    assert post_batch(conn, [%{start | operation_id: "second-start"}]) |> hd() == %{
             "operation_id" => "second-start",
             "status" => "rejected",
             "code" => "reporting_already_started"
           }

    assert post_batch(conn, [%{operation_id: "bad-start", type: "start_finance_reporting"}])
           |> hd() == %{
             "operation_id" => "bad-start",
             "status" => "rejected",
             "code" => "invalid_reporting_date"
           }
  end

  test "cash transfers, refunds, reductions, and chargebacks reconcile by property", %{conn: conn} do
    results =
      post_batch(conn, [
        open_operation("cash-source", "hotel-a"),
        open_operation("cash-destination", "hotel-b"),
        %{
          operation_id: "source-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "cash-source",
          amount_cents: 100
        },
        %{
          operation_id: "start-cash-report",
          type: "start_finance_reporting",
          starts_on: "2026-10-01"
        },
        %{
          operation_id: "cash-transfer",
          type: "transfer_deposit",
          occurred_on: "2026-10-06",
          source_group_id: "cash-source",
          destination_group_id: "cash-destination",
          amount_cents: 40
        },
        %{
          operation_id: "cancel-cash-destination",
          type: "cancel_group",
          occurred_on: "2026-10-07",
          group_id: "cash-destination"
        },
        %{
          operation_id: "reduce-source-payment",
          type: "reduce_cash_payment",
          occurred_on: "2026-10-08",
          payment_operation_id: "source-payment",
          amount_cents: 20
        },
        %{
          operation_id: "chargeback-source-payment",
          type: "charge_back_payment",
          occurred_on: "2026-10-09",
          payment_operation_id: "source-payment"
        }
      ])

    assert Enum.map(Enum.drop(results, 4), & &1["status"]) == [
             "applied",
             "applied",
             "applied",
             "applied"
           ]

    first_report = report(conn, "2026-10-09")
    second_report = report(conn, "2026-10-09")
    assert first_report == second_report

    assert first_report["cash"] == [
             %{
               "property_id" => "hotel-a",
               "opening_held_cents" => 100,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 40,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 20,
                 "charged_back_cents" => 40
               },
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "hotel-b",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 40,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 40
               },
               "closing_held_cents" => 0
             }
           ]

    assert Enum.at(first_report["cash"], 0)["movements"]["transferred_out_cents"] ==
             Enum.at(first_report["cash"], 1)["movements"]["transferred_in_cents"]
  end

  test "credit issuance expires automatically after its expiry date", %{conn: conn} do
    post_batch(conn, [
      open_operation("credit-source", "hotel-a"),
      %{
        operation_id: "credit-source-payment",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "credit-source",
        amount_cents: 100
      },
      %{
        operation_id: "start-credit-report",
        type: "start_finance_reporting",
        starts_on: "2026-10-01"
      },
      %{
        operation_id: "issue-credit",
        type: "cancel_group",
        occurred_on: "2026-10-05",
        group_id: "credit-source",
        refund_method: "hotel_credit"
      }
    ])

    issued = report(conn, "2026-10-05")
    assert issued["cash"] |> hd() |> get_in(["movements", "converted_to_credit_cents"]) == 100
    assert issued["credit"]["movements"]["issued_cents"] == 110
    assert issued["credit"]["closing_liability_cents"] == 110

    expired = report(conn, "2027-10-06")
    assert expired["credit"]["movements"]["expired_cents"] == 110
    assert expired["credit"]["closing_liability_cents"] == 0
  end

  test "reporting starts with expiry on its first day in the opening position", %{conn: conn} do
    post_batch(conn, [
      open_operation("opening-expiry-source", "hotel-a"),
      %{
        operation_id: "opening-expiry-payment",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "opening-expiry-source",
        amount_cents: 100
      },
      %{
        operation_id: "opening-expiry-credit-cancel",
        type: "cancel_group",
        occurred_on: "2026-10-05",
        group_id: "opening-expiry-source",
        refund_method: "hotel_credit"
      },
      %{
        operation_id: "start-on-credit-expiry",
        type: "start_finance_reporting",
        starts_on: "2027-10-06"
      }
    ])

    credit = report(conn, "2027-10-06")["credit"]

    assert credit == %{
             "opening_liability_cents" => 110,
             "movements" => %{
               "issued_cents" => 0,
               "expired_cents" => 110,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             },
             "closing_liability_cents" => 0
           }
  end

  test "credit held by a group stays live at expiry and expires when restored later", %{
    conn: conn
  } do
    post_batch(conn, [
      open_operation("restoration-source", "hotel-a"),
      %{
        operation_id: "restoration-payment",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "restoration-source",
        amount_cents: 100
      },
      %{
        operation_id: "start-restoration-report",
        type: "start_finance_reporting",
        starts_on: "2026-10-01"
      },
      %{
        operation_id: "restoration-credit-cancel",
        type: "cancel_group",
        occurred_on: "2026-10-05",
        group_id: "restoration-source",
        refund_method: "hotel_credit"
      },
      open_operation("restoration-target", "hotel-b", %{
        arrival_on: "2027-12-10",
        departure_on: "2027-12-11"
      }),
      %{
        operation_id: "apply-restoration-credit",
        type: "apply_hotel_credit",
        occurred_on: "2026-10-06",
        group_id: "restoration-target",
        amount_cents: 110
      }
    ])

    assert report(conn, "2027-10-06")["credit"]["movements"]["expired_cents"] == 0
    assert report(conn, "2027-10-06")["credit"]["closing_liability_cents"] == 110

    post_batch(conn, [
      %{
        operation_id: "restore-expired-credit",
        type: "cancel_group",
        occurred_on: "2027-10-07",
        group_id: "restoration-target"
      }
    ])

    restored = report(conn, "2027-10-07")
    assert restored["credit"]["movements"]["expired_cents"] == 110
    assert restored["credit"]["closing_liability_cents"] == 0
  end

  test "credit issuance, revocation, shortfall absorption, and consumption reconcile", %{
    conn: conn
  } do
    chargeback = %{
      operation_id: "report-credit-chargeback",
      type: "charge_back_payment",
      occurred_on: "2026-10-07",
      payment_operation_id: "report-credit-payment-a"
    }

    operations = [
      open_operation("report-credit-source", "hotel-a", %{
        rooms: [%{room_id: "source-room", nightly_rate_cents: 1010}]
      }),
      %{
        operation_id: "start-credit-classification-report",
        type: "start_finance_reporting",
        starts_on: "2026-10-01"
      },
      %{
        operation_id: "report-credit-payment-a",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "report-credit-source",
        amount_cents: 101
      },
      %{
        operation_id: "report-credit-payment-b",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "report-credit-source",
        amount_cents: 101
      },
      %{
        operation_id: "report-credit-source-cancel",
        type: "cancel_group",
        occurred_on: "2026-10-05",
        group_id: "report-credit-source",
        refund_method: "hotel_credit"
      },
      open_operation("report-credit-target", "hotel-b", %{
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11"
      }),
      %{
        operation_id: "report-apply-credit-target",
        type: "apply_hotel_credit",
        occurred_on: "2026-10-06",
        group_id: "report-credit-target",
        amount_cents: 200
      },
      chargeback,
      %{
        operation_id: "report-credit-target-cancel",
        type: "cancel_group",
        occurred_on: "2026-10-08",
        group_id: "report-credit-target"
      },
      open_operation("report-credit-consumer", "hotel-c", %{
        rate_plan: "advance_purchase",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11"
      }),
      %{
        operation_id: "report-consume-restored-credit",
        type: "apply_hotel_credit",
        occurred_on: "2026-10-09",
        group_id: "report-credit-consumer",
        amount_cents: 111
      },
      %{
        operation_id: "report-consume-restored-credit-cancel",
        type: "cancel_group",
        occurred_on: "2026-10-10",
        group_id: "report-credit-consumer"
      }
    ]

    results = post_batch(conn, operations)
    assert Enum.map(results, & &1["status"]) == List.duplicate("applied", length(operations))

    credit = report(conn, "2026-10-10")["credit"]

    assert credit == %{
             "opening_liability_cents" => 0,
             "movements" => %{
               "issued_cents" => 222,
               "expired_cents" => 0,
               "consumed_cents" => 111,
               "revoked_cents" => 22,
               "absorbed_cents" => 89
             },
             "closing_liability_cents" => 0
           }

    before_retry = report(conn, "2026-10-10")
    assert post_batch(conn, [chargeback]) |> hd() == Enum.at(results, 7)
    assert post_batch(conn, [Enum.at(operations, 2)]) |> hd() == Enum.at(results, 2)
    assert report(conn, "2026-10-10") == before_retry
  end

  test "chargeback after reporting starts reverses an earlier cash refund", %{conn: conn} do
    post_batch(conn, [
      open_operation("refunded-before-report", "hotel-a"),
      %{
        operation_id: "cash-refunded-before-report",
        type: "record_cash_payment",
        occurred_on: "2026-10-04",
        group_id: "refunded-before-report",
        amount_cents: 100
      },
      %{
        operation_id: "refund-before-report-start",
        type: "cancel_group",
        occurred_on: "2026-10-05",
        group_id: "refunded-before-report"
      },
      %{
        operation_id: "start-after-cash-refund",
        type: "start_finance_reporting",
        starts_on: "2026-10-06"
      }
    ])

    assert report(conn, "2026-10-06")["cash"] == []

    post_batch(conn, [
      %{
        operation_id: "reverse-old-cash-refund",
        type: "charge_back_payment",
        occurred_on: "2026-10-07",
        payment_operation_id: "cash-refunded-before-report"
      }
    ])

    cash = report(conn, "2026-10-07")["cash"] |> hd()
    assert cash["opening_held_cents"] == 0
    assert cash["movements"]["refunded_cents"] == -100
    assert cash["movements"]["charged_back_cents"] == 100
    assert cash["closing_held_cents"] == 0
  end
end
