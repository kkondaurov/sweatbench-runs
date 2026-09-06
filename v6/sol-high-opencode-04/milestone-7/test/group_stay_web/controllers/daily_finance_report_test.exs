defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "validates availability and starts reporting durably at its batch position", %{conn: conn} do
    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-03")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for path <- ["/api/v1/finance/daily-report", "/api/v1/finance/daily-report?date=nope"] do
      assert get(build_conn(), path) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    operations = [
      open_operation(%{"operation_id" => "open"}),
      operation("pay-before", "record_cash_payment", %{
        "group_id" => "group-1",
        "amount_cents" => 1_000,
        "occurred_on" => "2026-10-10"
      }),
      start_operation(),
      operation("pay-after", "record_cash_payment", %{
        "group_id" => "group-1",
        "amount_cents" => 500,
        "occurred_on" => "2026-09-01"
      })
    ]

    assert %{"results" => [_, _, start_result, _]} =
             post(build_conn(), "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)

    assert start_result == %{
             "operation_id" => "start-reporting",
             "starts_on" => "2026-10-03",
             "status" => "applied"
           }

    assert daily_report("2026-10-02") == {:error, 404, "report_not_available"}

    assert %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => %{"received_cents" => 500},
                 "closing_held_cents" => 1_500
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 0,
               "closing_liability_cents" => 0
             }
           } = daily_report("2026-10-03")

    assert %{"results" => [replayed]} =
             post(build_conn(), "/api/v1/partner-batches", %{operations: [start_operation()]})
             |> json_response(200)

    assert replayed == start_result

    second = start_operation(%{"operation_id" => "start-again", "starts_on" => "2026-10-04"})

    assert %{"results" => [%{"code" => "reporting_already_started"}]} =
             post(build_conn(), "/api/v1/partner-batches", %{operations: [second]})
             |> json_response(200)

    assert %{"cash" => [%{"movements" => %{"received_cents" => 500}}]} =
             daily_report("2026-10-03")
  end

  test "rejects invalid reporting starts with the specific code", %{conn: conn} do
    operations = [
      start_operation(%{"operation_id" => "missing-date"}) |> Map.delete("starts_on"),
      start_operation(%{"operation_id" => "bad-date", "starts_on" => "2026-02-30"})
    ]

    assert %{
             "results" => [
               %{"operation_id" => "missing-date", "code" => "invalid_reporting_date"},
               %{"operation_id" => "bad-date", "code" => "invalid_reporting_date"}
             ]
           } =
             post(conn, "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)
  end

  test "reports transfers and reductions where cash is currently held", %{conn: conn} do
    operations = [
      start_operation(),
      open_operation(%{
        "operation_id" => "open-a",
        "group_id" => "a",
        "property_id" => "a-hotel"
      }),
      open_operation(%{
        "operation_id" => "open-b",
        "group_id" => "b",
        "property_id" => "b-hotel"
      }),
      operation("pay", "record_cash_payment", %{
        "group_id" => "a",
        "amount_cents" => 1_000,
        "occurred_on" => "2026-10-04"
      }),
      operation("transfer", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 600,
        "occurred_on" => "2026-10-05"
      }),
      operation("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 500,
        "occurred_on" => "2026-10-06"
      })
    ]

    assert %{"results" => results} =
             post(conn, "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "cash" => [
               %{
                 "property_id" => "a-hotel",
                 "opening_held_cents" => 1_000,
                 "movements" => %{"transferred_out_cents" => 600},
                 "closing_held_cents" => 400
               },
               %{
                 "property_id" => "b-hotel",
                 "opening_held_cents" => 0,
                 "movements" => %{"transferred_in_cents" => 600},
                 "closing_held_cents" => 600
               }
             ]
           } = daily_report("2026-10-05")

    assert %{
             "cash" => [
               %{"property_id" => "a-hotel", "opening_held_cents" => 400},
               %{
                 "property_id" => "b-hotel",
                 "opening_held_cents" => 600,
                 "movements" => %{"reduced_cents" => 500},
                 "closing_held_cents" => 100
               }
             ]
           } = daily_report("2026-10-06")
  end

  test "reports chargebacks as signed reclassifications at the settlement property", %{conn: conn} do
    operations = [
      start_operation(),
      open_operation(%{"operation_id" => "open"}),
      operation("pay", "record_cash_payment", %{
        "group_id" => "group-1",
        "amount_cents" => 1_000,
        "occurred_on" => "2026-10-04"
      }),
      operation("cancel", "cancel_group", %{
        "group_id" => "group-1",
        "occurred_on" => "2026-10-05"
      }),
      operation("chargeback", "charge_back_payment", %{
        "payment_operation_id" => "pay",
        "occurred_on" => "2026-10-06"
      })
    ]

    assert %{"results" => results} =
             post(conn, "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "cash" => [
               %{
                 "opening_held_cents" => 0,
                 "movements" => %{
                   "refunded_cents" => -1_000,
                   "charged_back_cents" => 1_000
                 },
                 "closing_held_cents" => 0
               }
             ]
           } = daily_report("2026-10-06")
  end

  test "tracks credit issuance without apply movements and expires only unused credit", %{
    conn: conn
  } do
    operations = [
      start_operation(),
      open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
      operation("pay-source", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      operation("issue", "cancel_group", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2028-12-10",
        "departure_on" => "2028-12-13"
      }),
      operation("apply", "apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 400
      })
    ]

    assert %{"results" => results} =
             post(conn, "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => %{"issued_cents" => 1_100},
               "closing_liability_cents" => 1_100
             }
           } = daily_report("2026-10-03")

    expiry_report = daily_report("2027-10-04")

    assert %{
             "credit" => %{
               "opening_liability_cents" => 1_100,
               "movements" => %{"expired_cents" => 700},
               "closing_liability_cents" => 400
             }
           } = expiry_report

    assert daily_report("2027-10-04") == expiry_report
    assert daily_report("2026-10-03")["credit"]["closing_liability_cents"] == 1_100

    cancel =
      operation("consume", "cancel_group", %{
        "group_id" => "target",
        "occurred_on" => "2027-10-05"
      })

    assert %{"results" => [%{"status" => "applied"}]} =
             post(build_conn(), "/api/v1/partner-batches", %{operations: [cancel]})
             |> json_response(200)

    assert %{
             "credit" => %{
               "opening_liability_cents" => 400,
               "movements" => %{"consumed_cents" => 400},
               "closing_liability_cents" => 0
             }
           } = daily_report("2027-10-05")
  end

  test "reports credit revocation and later shortfall absorption", %{conn: conn} do
    operations = [
      start_operation(),
      open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
      operation("pay", "record_cash_payment", %{"group_id" => "source", "amount_cents" => 1_000}),
      operation("issue", "cancel_group", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      open_operation(%{"operation_id" => "open-target", "group_id" => "target"}),
      operation("apply", "apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 1_100}),
      operation("chargeback", "charge_back_payment", %{
        "payment_operation_id" => "pay",
        "occurred_on" => "2026-10-04"
      }),
      operation("cancel-target", "cancel_group", %{
        "group_id" => "target",
        "occurred_on" => "2026-10-05"
      })
    ]

    assert %{"results" => results} =
             post(conn, "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "cash" => [
               %{
                 "movements" => %{
                   "converted_to_credit_cents" => -1_000,
                   "charged_back_cents" => 1_000
                 }
               }
             ],
             "credit" => %{
               "opening_liability_cents" => 1_100,
               "movements" => %{"revoked_cents" => 0},
               "closing_liability_cents" => 1_100
             }
           } = daily_report("2026-10-04")

    assert %{
             "credit" => %{
               "opening_liability_cents" => 1_100,
               "movements" => %{"absorbed_cents" => 1_100},
               "closing_liability_cents" => 0
             }
           } = daily_report("2026-10-05")
  end

  test "backdated application revives pre-reporting expired credit as negative expiry", %{
    conn: conn
  } do
    before_start = [
      open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
      operation("pay-source", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      operation("issue", "cancel_group", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      start_operation(%{"starts_on" => "2028-01-01"}),
      open_operation(%{
        "operation_id" => "open-target",
        "group_id" => "target",
        "rate_plan" => "advance_purchase",
        "arrival_on" => "2028-12-10",
        "departure_on" => "2028-12-13"
      }),
      operation("apply-backdated", "apply_hotel_credit", %{
        "group_id" => "target",
        "amount_cents" => 400,
        "occurred_on" => "2027-10-03"
      })
    ]

    assert %{"results" => results} =
             post(conn, "/api/v1/partner-batches", %{operations: before_start})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => %{"expired_cents" => -400},
               "closing_liability_cents" => 400
             }
           } = daily_report("2028-01-01")

    assert %{"data" => %{"credit_liability_cents" => 400}} =
             get(build_conn(), "/api/v1/ledger?on=2028-01-01") |> json_response(200)
  end

  test "opening property balances remain exact above SQLite's integer limit", %{conn: conn} do
    max = 9_223_372_036_854_775_807

    operations =
      Enum.flat_map(1..2, fn number ->
        [
          open_operation(%{
            "operation_id" => "open-#{number}",
            "group_id" => "group-#{number}",
            "rate_plan" => "advance_purchase",
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "room-#{number}", "nightly_rate_cents" => max}]
          }),
          operation("pay-#{number}", "record_cash_payment", %{
            "group_id" => "group-#{number}",
            "amount_cents" => max
          })
        ]
      end) ++ [start_operation()]

    assert %{"results" => results} =
             post(conn, "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 18_446_744_073_709_551_614,
                 "closing_held_cents" => 18_446_744_073_709_551_614
               }
             ]
           } = daily_report("2026-10-03")
  end

  test "does not expire a pre-reporting lot twice at the inception boundary", %{conn: conn} do
    operations = [
      open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
      operation("pay-source", "record_cash_payment", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      operation("issue", "cancel_group", %{
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }),
      start_operation(%{"starts_on" => "2027-10-04"})
    ]

    assert %{"results" => results} =
             post(conn, "/api/v1/partner-batches", %{operations: operations})
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => %{"expired_cents" => 0},
               "closing_liability_cents" => 0
             }
           } = daily_report("2027-10-04")
  end

  defp daily_report(date) do
    conn = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")

    case json_response(conn, conn.status) do
      %{"data" => report} -> report
      %{"error" => %{"code" => code}} = body -> {:error, body_status(body), code}
    end
  end

  defp body_status(%{"error" => %{"code" => "report_not_available"}}), do: 404

  defp start_operation(overrides \\ %{}) do
    operation("start-reporting", "start_finance_reporting", %{"starts_on" => "2026-10-03"})
    |> Map.merge(overrides)
  end

  defp open_operation(overrides) do
    operation("open-default", "open_group", %{
      "group_id" => "group-1",
      "guest_id" => "guest-1",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    })
    |> Map.merge(overrides)
  end

  defp operation(operation_id, type, fields) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => "2026-10-03"
      },
      fields
    )
  end
end
