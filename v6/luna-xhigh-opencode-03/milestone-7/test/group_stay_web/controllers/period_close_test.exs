defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "period-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 200}]
      },
      overrides
    )
  end

  defp report(conn, date), do: get(conn, "/api/v1/finance/daily-report?date=#{date}")

  test "validates closes and durably replays the result", %{conn: conn} do
    before_start = %{
      "operation_id" => "close-before-start",
      "type" => "close_finance_period",
      "period_end_on" => "2027-01-01"
    }

    assert json_response(submit(conn, [before_start]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    assert json_response(
             submit(conn, [
               %{
                 "operation_id" => "start-reporting",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2027-01-01"
               }
             ]),
             200
           )

    assert json_response(submit(conn, [before_start]), 200) == %{
             "results" => [
               %{
                 "operation_id" => "close-before-start",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ]
           }

    close = %{
      "operation_id" => "close-first",
      "type" => "close_finance_period",
      "period_end_on" => "2027-01-03"
    }

    applied = %{
      "operation_id" => "close-first",
      "status" => "applied",
      "period_end_on" => "2027-01-03"
    }

    assert json_response(submit(conn, [close]), 200) == %{"results" => [applied]}
    assert json_response(submit(conn, [close]), 200) == %{"results" => [applied]}
    assert json_response(get(conn, "/api/v1/operations/close-first"), 200) == %{"data" => applied}

    assert get_in(
             json_response(
               submit(conn, [Map.put(close, "operation_id", "close-equal")]),
               200
             ),
             ["results", Access.at(0)]
           ) == %{
             "operation_id" => "close-equal",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    earlier =
      Map.merge(close, %{"operation_id" => "close-earlier", "period_end_on" => "2027-01-02"})

    assert get_in(json_response(submit(conn, [earlier]), 200), ["results", Access.at(0)]) == %{
             "operation_id" => "close-earlier",
             "status" => "rejected",
             "code" => "invalid_period"
           }

    conflict = Map.put(close, "period_end_on", "2027-01-04")

    assert get_in(json_response(submit(conn, [conflict]), 200), ["results", Access.at(0)]) == %{
             "operation_id" => "close-first",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }
  end

  test "closes every day through the cutoff and keeps snapshots stable", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("stable"),
      %{
        "operation_id" => "payment-before-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => "stable",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "close-first",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-03"
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-01"), 200), ["data", "status"]) ==
             "closed"

    assert get_in(json_response(report(conn, "2027-01-02"), 200), ["data", "status"]) ==
             "closed"

    assert get_in(json_response(report(conn, "2027-01-03"), 200), ["data", "status"]) ==
             "closed"

    assert get_in(json_response(report(conn, "2027-01-04"), 200), ["data", "status"]) == "open"

    before_late_operation = json_response(report(conn, "2027-01-02"), 200)

    assert json_response(
             submit(conn, [
               %{
                 "operation_id" => "payment-after-close",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "stable",
                 "amount_cents" => 50
               }
             ]),
             200
           )

    assert json_response(report(conn, "2027-01-02"), 200) == before_late_operation

    jan_4 = json_response(report(conn, "2027-01-04"), 200)

    assert get_in(jan_4, ["data", "cash"]) == [
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
               "closing_held_cents" => 150
             }
           ]

    assert get_in(jan_4, ["data", "late_adjustments"]) == %{
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   "received_cents" => 50,
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
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
           }

    assert json_response(
             submit(conn, [
               %{
                 "operation_id" => "close-second",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-05"
               }
             ]),
             200
           )

    assert get_in(json_response(report(conn, "2027-01-02"), 200), ["data", "status"]) ==
             "closed"

    assert get_in(json_response(report(conn, "2027-01-02"), 200), ["data"]) ==
             get_in(before_late_operation, ["data"])

    assert get_in(json_response(report(conn, "2027-01-04"), 200), ["data"]) ==
             Map.put(jan_4["data"], "status", "closed")
  end

  test "routes same-batch operations before and after a close independently", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("ordered", %{
        "rooms" => [%{"room_id" => "room-ordered", "nightly_rate_cents" => 300}]
      }),
      %{
        "operation_id" => "payment-before-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => "ordered",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "close-period",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-03"
      },
      %{
        "operation_id" => "payment-after-close",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-02",
        "group_id" => "ordered",
        "amount_cents" => 100
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-02"), 200), [
             "data",
             "cash",
             Access.at(0),
             "movements",
             "received_cents"
           ]) ==
             100

    assert get_in(json_response(report(conn, "2027-01-04"), 200), [
             "data",
             "late_adjustments",
             "cash",
             Access.at(0),
             "movements",
             "received_cents"
           ]) ==
             100
  end

  test "posts transfer and reduction effects on the first open day", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("transfer-source", %{
        "property_id" => "property-z",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 100}]
      }),
      open_operation("transfer-destination", %{
        "property_id" => "property-a",
        "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 100}]
      }),
      %{
        "operation_id" => "transfer-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "transfer-source",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "transfer-close",
        "type" => "close_finance_period",
        "period_end_on" => "2027-01-01"
      },
      %{
        "operation_id" => "late-transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "transfer-source",
        "destination_group_id" => "transfer-destination",
        "amount_cents" => 40
      },
      %{
        "operation_id" => "late-reduction",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "transfer-payment",
        "amount_cents" => 10,
        "expected_revision" => 3
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-02"), 200), [
             "data",
             "late_adjustments",
             "cash"
           ]) == [
             %{
               "property_id" => "property-a",
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 40,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 10,
                 "charged_back_cents" => 0
               }
             },
             %{
               "property_id" => "property-z",
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 40,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               }
             }
           ]
  end

  test "keeps signed late cash reversals and late credit issuance separate", %{conn: conn} do
    assert Enum.all?(
             submit(conn, [
               %{
                 "operation_id" => "start-reporting",
                 "type" => "start_finance_reporting",
                 "starts_on" => "2027-01-01"
               },
               open_operation("signed", %{
                 "rate_plan" => "flexible",
                 "rooms" => [%{"room_id" => "signed-room", "nightly_rate_cents" => 500}]
               }),
               %{
                 "operation_id" => "signed-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "signed",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "signed-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "signed"
               },
               %{
                 "operation_id" => "close-signed",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-01"
               },
               %{
                 "operation_id" => "signed-chargeback",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2027-01-01",
                 "payment_operation_id" => "signed-payment",
                 "expected_revision" => 3
               }
             ])
             |> json_response(200)
             |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-02"), 200), [
             "data",
             "late_adjustments",
             "cash"
           ]) == [
             %{
               "property_id" => "ams-canal",
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => -100,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 100
               }
             }
           ]

    assert Enum.all?(
             submit(conn, [
               open_operation("credit", %{
                 "rate_plan" => "flexible",
                 "rooms" => [%{"room_id" => "credit-room", "nightly_rate_cents" => 500}]
               }),
               %{
                 "operation_id" => "credit-payment",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "credit",
                 "amount_cents" => 100
               },
               %{
                 "operation_id" => "credit-close",
                 "type" => "close_finance_period",
                 "period_end_on" => "2027-01-02"
               },
               %{
                 "operation_id" => "credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "credit",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)
             |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2027-01-03"), 200), [
             "data",
             "late_adjustments",
             "credit"
           ]) == %{
             "issued_cents" => 110,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }
  end

  test "expires credit issued after its original expiry on the late posting date", %{conn: conn} do
    operations = [
      %{
        "operation_id" => "start-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2027-01-01"
      },
      open_operation("expired-credit", %{
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "expired-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "expired-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "expired-credit",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "expired-close",
        "type" => "close_finance_period",
        "period_end_on" => "2028-01-03"
      },
      %{
        "operation_id" => "expired-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "expired-credit",
        "refund_method" => "hotel_credit"
      }
    ]

    assert Enum.all?(
             submit(conn, operations) |> json_response(200) |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    assert get_in(json_response(report(conn, "2028-01-04"), 200), [
             "data",
             "late_adjustments",
             "credit"
           ]) == %{
             "issued_cents" => 110,
             "expired_cents" => 110,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 0
           }

    assert get_in(json_response(report(conn, "2028-01-04"), 200), [
             "data",
             "credit",
             "closing_liability_cents"
           ]) == 0
  end
end
