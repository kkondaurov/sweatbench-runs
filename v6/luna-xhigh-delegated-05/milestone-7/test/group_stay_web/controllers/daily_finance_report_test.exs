defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: "open-#{group_id}",
        type: "open_group",
        occurred_on: "2026-01-01",
        group_id: group_id,
        guest_id: "guest-#{group_id}",
        property_id: "ams-canal",
        arrival_on: "2026-12-10",
        departure_on: "2026-12-11",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 5_000}]
      },
      overrides
    )
  end

  defp payment(group_id, operation_id, amount_cents, occurred_on \\ "2026-01-01") do
    %{
      operation_id: operation_id,
      type: "record_cash_payment",
      occurred_on: occurred_on,
      group_id: group_id,
      amount_cents: amount_cents
    }
  end

  defp start_reporting(operation_id, starts_on) do
    %{operation_id: operation_id, type: "start_finance_reporting", starts_on: starts_on}
  end

  test "starts from the committed position and posts later operations", %{conn: conn} do
    results =
      submit(conn, [
        open_operation("reporting-group"),
        payment("reporting-group", "pay-before-reporting", 500),
        start_reporting("reporting-start", "2026-01-05"),
        payment("reporting-group", "pay-after-reporting", 200, "2026-01-06")
      ])
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.at(results, 2) == %{
             "operation_id" => "reporting-start",
             "status" => "applied",
             "starts_on" => "2026-01-05"
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2026-01-05")
           |> json_response(200) == %{
             "data" => %{
               "date" => "2026-01-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 500,
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
                   "closing_held_cents" => 500
                 }
               ],
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               },
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
           }

    report =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-06")
      |> json_response(200)
      |> get_in(["data"])

    assert report["cash"] |> hd() |> Map.take(["opening_held_cents", "closing_held_cents"]) == %{
             "opening_held_cents" => 500,
             "closing_held_cents" => 700
           }

    assert report["cash"] |> hd() |> get_in(["movements", "received_cents"]) == 200
  end

  test "reports conversion, expiry, unavailable dates, and durable start replay", %{conn: conn} do
    submit(conn, [start_reporting("reporting-start", "2026-01-01")]) |> json_response(200)

    submit(conn, [
      open_operation("credit-source", %{guest_id: "credit-guest"}),
      payment("credit-source", "credit-payment", 1_000),
      %{
        operation_id: "credit-cancel",
        type: "cancel_group",
        occurred_on: "2026-01-02",
        group_id: "credit-source",
        refund_method: "hotel_credit"
      }
    ])
    |> json_response(200)

    report =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-02")
      |> json_response(200)
      |> get_in(["data"])

    assert get_in(report, ["cash", Access.at(0), "movements", "converted_to_credit_cents"]) ==
             1_000

    assert get_in(report, ["credit", "movements", "issued_cents"]) == 1_100
    assert get_in(report, ["credit", "closing_liability_cents"]) == 1_100

    expiry =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-03")
      |> json_response(200)
      |> get_in(["data", "credit"])

    assert expiry["movements"]["expired_cents"] == 1_100
    assert expiry["closing_liability_cents"] == 0

    following_day =
      get(conn, "/api/v1/finance/daily-report?date=2027-01-04")
      |> json_response(200)
      |> get_in(["data", "credit"])

    assert following_day["movements"]["expired_cents"] == 0
    assert following_day["opening_liability_cents"] == 0
    assert following_day["closing_liability_cents"] == 0

    assert submit(conn, [start_reporting("other-start", "2026-01-02")])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "code"]) == "reporting_already_started"

    assert get(conn, "/api/v1/finance/daily-report") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert get(conn, "/api/v1/finance/daily-report?date=2025-12-31") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert get(conn, "/api/v1/finance/daily-report?date=not-a-date") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    retry = submit(conn, [start_reporting("reporting-start", "2026-01-01")]) |> json_response(200)
    assert get_in(retry, ["results", Access.at(0), "status"]) == "applied"
  end

  test "follows transferred cash to its held and settled property through chargeback", %{
    conn: conn
  } do
    submit(conn, [
      start_reporting("reporting-start", "2026-01-01"),
      open_operation("source", %{
        guest_id: "shared-guest",
        property_id: "property-a"
      }),
      open_operation("destination", %{
        operation_id: "open-destination",
        guest_id: "shared-guest",
        property_id: "property-b"
      }),
      payment("source", "pay-transfer", 1_000),
      %{
        operation_id: "transfer-cash",
        type: "transfer_deposit",
        occurred_on: "2026-01-02",
        source_group_id: "source",
        destination_group_id: "destination",
        amount_cents: 1_000,
        expected_revision: 2,
        destination_expected_revision: 1
      },
      %{
        operation_id: "cancel-destination",
        type: "cancel_group",
        occurred_on: "2026-01-03",
        group_id: "destination",
        expected_revision: 2
      },
      %{
        operation_id: "chargeback-transfer",
        type: "charge_back_payment",
        occurred_on: "2026-01-04",
        payment_operation_id: "pay-transfer",
        expected_revision: 3
      }
    ])
    |> json_response(200)

    transfer_day =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-02")
      |> json_response(200)
      |> get_in(["data", "cash"])

    assert Enum.map(
             transfer_day,
             &{&1["property_id"], &1["opening_held_cents"], &1["closing_held_cents"]}
           ) == [
             {"property-a", 1_000, 0},
             {"property-b", 0, 1_000}
           ]

    assert get_in(Enum.find(transfer_day, &(&1["property_id"] == "property-a")), [
             "movements",
             "transferred_out_cents"
           ]) == 1_000

    cancellation_day =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-03")
      |> json_response(200)
      |> get_in(["data", "cash", Access.at(0)])

    assert cancellation_day["property_id"] == "property-b"
    assert cancellation_day["movements"]["refunded_cents"] == 1_000
    assert cancellation_day["closing_held_cents"] == 0

    chargeback_day =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-04")
      |> json_response(200)
      |> get_in(["data", "cash", Access.at(0)])

    assert chargeback_day["property_id"] == "property-b"
    assert chargeback_day["movements"]["refunded_cents"] == -1_000
    assert chargeback_day["movements"]["charged_back_cents"] == 1_000
    assert chargeback_day["closing_held_cents"] == 0
  end

  test "preserves a pre-reporting settlement property for a later chargeback", %{conn: conn} do
    submit(conn, [
      open_operation("source", %{guest_id: "shared-guest", property_id: "property-a"}),
      open_operation("destination", %{
        operation_id: "open-destination",
        guest_id: "shared-guest",
        property_id: "property-b"
      }),
      payment("source", "pay-before-start", 1_000),
      %{
        operation_id: "transfer-before-start",
        type: "transfer_deposit",
        source_group_id: "source",
        destination_group_id: "destination",
        amount_cents: 1_000
      },
      %{
        operation_id: "cancel-before-start",
        type: "cancel_group",
        occurred_on: "2026-01-02",
        group_id: "destination",
        expected_revision: 2
      },
      start_reporting("reporting-start", "2026-01-05"),
      %{
        operation_id: "chargeback-after-start",
        type: "charge_back_payment",
        occurred_on: "2026-01-06",
        payment_operation_id: "pay-before-start",
        expected_revision: 3
      }
    ])
    |> json_response(200)

    cash =
      get(conn, "/api/v1/finance/daily-report?date=2026-01-06")
      |> json_response(200)
      |> get_in(["data", "cash", Access.at(0)])

    assert cash["property_id"] == "property-b"
    assert cash["movements"]["refunded_cents"] == -1_000
    assert cash["movements"]["charged_back_cents"] == 1_000
  end
end
