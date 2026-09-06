defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp open(id, group, property, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group,
        "guest_id" => "guest",
        "property_id" => property,
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp pay(id, group, amount, occurred_on) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp start(id \\ "start", starts_on \\ "2027-02-01") do
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

  defp report(conn, date),
    do: get(conn, "/api/v1/finance/daily-report?date=#{date}") |> json_response(200)

  test "validates inception and report dates and durably replays the first start", %{conn: conn} do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(conn, "/api/v1/finance/daily-report?date=nope") |> json_response(422)

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-02-01") |> json_response(404)

    assert [%{"code" => "invalid_reporting_date"}] =
             submit(conn, [%{"operation_id" => "bad", "type" => "start_finance_reporting"}])

    operation = start()

    assert [
             result = %{
               "operation_id" => "start",
               "status" => "applied",
               "starts_on" => "2027-02-01"
             }
           ] =
             submit(conn, [operation])

    assert map_size(result) == 3
    assert [^result] = submit(conn, [operation])
    assert [%{"code" => "operation_id_conflict"}] = submit(conn, [start("start", "2027-03-01")])
    assert [%{"code" => "reporting_already_started"}] = submit(conn, [start("other")])

    assert %{"error" => %{"code" => "report_not_available"}} =
             get(conn, "/api/v1/finance/daily-report?date=2027-01-31") |> json_response(404)
  end

  test "same-batch ordering fixes the opening and clamps later movements to starts_on", %{
    conn: conn
  } do
    assert [_, _, _, _] =
             submit(conn, [
               open("open", "group", "ams-canal"),
               pay("opening-payment", "group", 1_000, "2027-03-01"),
               start(),
               pay("day-payment", "group", 500, "2027-01-15")
             ])

    assert %{
             "data" => %{
               "date" => "2027-02-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1_000,
                   "closing_held_cents" => 1_500,
                   "movements" => %{
                     "received_cents" => 500,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   }
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "closing_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
           } = report(conn, "2027-02-01")
  end

  test "late cash activity, transfers, reductions, refunds, and chargebacks reconcile by property",
       %{
         conn: conn
       } do
    submit(conn, [
      start(),
      open("open-a", "a", "ams-canal"),
      open("open-b", "b", "berlin-mitte"),
      pay("pay", "a", 1_000, "2027-02-03"),
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2027-02-04",
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 400
      },
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2027-02-05",
        "payment_operation_id" => "pay",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "cancel-b",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-06",
        "group_id" => "b"
      }
    ])

    assert %{"data" => %{"cash" => cash}} = report(conn, "2027-02-06")
    assert Enum.map(cash, & &1["property_id"]) == ["ams-canal", "berlin-mitte"]

    berlin = Enum.find(cash, &(&1["property_id"] == "berlin-mitte"))
    assert berlin["opening_held_cents"] == 300
    assert berlin["movements"]["refunded_cents"] == 300
    assert berlin["closing_held_cents"] == 0

    submit(conn, [
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2027-02-07",
        "payment_operation_id" => "pay"
      }
    ])

    assert %{"data" => %{"cash" => cash}} = report(conn, "2027-02-07")
    ams = Enum.find(cash, &(&1["property_id"] == "ams-canal"))
    berlin = Enum.find(cash, &(&1["property_id"] == "berlin-mitte"))
    assert ams["movements"]["charged_back_cents"] == 600
    assert ams["closing_held_cents"] == 0
    assert berlin["movements"]["refunded_cents"] == -300
    assert berlin["movements"]["charged_back_cents"] == 300
    assert berlin["closing_held_cents"] == 0

    # A late submission revises its earlier open day and not the submission day.
    submit(conn, [pay("late", "a", 50, "2027-02-02")])

    assert %{"data" => %{"cash" => [%{"movements" => %{"received_cents" => 50}}]}} =
             report(conn, "2027-02-02")
  end

  test "credit issuance and unused expiry are reported without mutating reads", %{conn: conn} do
    submit(conn, [
      start(),
      open("open", "source", "ams-canal", %{
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
      }),
      pay("pay", "source", 20, "2027-02-02"),
      %{
        "operation_id" => "credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }
    ])

    assert %{
             "data" => %{
               "cash" => [
                 %{
                   "movements" => %{"converted_to_credit_cents" => 20},
                   "closing_held_cents" => 0
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{"issued_cents" => 22},
                 "closing_liability_cents" => 22
               }
             }
           } = report(conn, "2027-02-03")

    expiry = report(conn, "2028-02-04")

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 22,
                 "movements" => %{"expired_cents" => 22},
                 "closing_liability_cents" => 0
               }
             }
           } = expiry

    assert ^expiry = report(conn, "2028-02-04")

    assert %{"data" => %{"credit_liability_cents" => 0}} =
             get(conn, "/api/v1/ledger?on=2028-02-04") |> json_response(200)
  end

  test "credit expiring on the inception date leaves through that day's movement", %{conn: conn} do
    submit(conn, [
      open("open", "source", "ams-canal", %{
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
      }),
      pay("pay", "source", 20, "2027-02-02"),
      %{
        "operation_id" => "credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      start("start", "2028-02-04")
    ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 22,
                 "movements" => %{"expired_cents" => 22},
                 "closing_liability_cents" => 0
               }
             }
           } = report(conn, "2028-02-04")
  end

  test "applied credit pauses expiry and an expired restoration posts on its operation date", %{
    conn: conn
  } do
    submit(conn, [
      start(),
      open("source-open", "source", "ams-canal", %{
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
      }),
      pay("source-pay", "source", 20, "2027-02-02"),
      %{
        "operation_id" => "make-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      },
      open("destination-open", "destination", "ams-canal", %{
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-02"
      }),
      %{
        "operation_id" => "apply-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-02-04",
        "group_id" => "destination",
        "amount_cents" => 22
      }
    ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 22,
                 "movements" => %{"expired_cents" => 0},
                 "closing_liability_cents" => 22
               }
             }
           } = report(conn, "2028-02-04")

    submit(conn, [
      %{
        "operation_id" => "restore-expired",
        "type" => "cancel_group",
        "occurred_on" => "2028-02-05",
        "group_id" => "destination"
      }
    ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 22,
                 "movements" => %{"expired_cents" => 22},
                 "closing_liability_cents" => 0
               }
             }
           } = report(conn, "2028-02-05")
  end

  test "a post-expiry chargeback cannot rewrite the already posted expiry", %{conn: conn} do
    submit(conn, [
      start(),
      open("source-open", "source", "ams-canal", %{
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 100}]
      }),
      pay("source-pay", "source", 20, "2027-02-02"),
      %{
        "operation_id" => "make-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-03",
        "group_id" => "source",
        "refund_method" => "hotel_credit"
      }
    ])

    submit(conn, [
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2028-02-05",
        "payment_operation_id" => "source-pay"
      },
      open("unrelated", "unrelated", "ams-canal", %{"occurred_on" => "2027-03-01"})
    ])

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 22,
                 "movements" => %{"expired_cents" => 22},
                 "closing_liability_cents" => 0
               }
             }
           } = report(conn, "2028-02-04")

    assert %{
             "data" => %{
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{"revoked_cents" => 0},
                 "closing_liability_cents" => 0
               }
             }
           } = report(conn, "2028-02-05")
  end
end
