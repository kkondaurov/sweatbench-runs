defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  test "starts once with an exact durable result and captures its same-batch inception point", %{
    conn: conn
  } do
    assert conn
           |> get("/api/v1/finance/daily-report?date=2026-10-05")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    response =
      submit(conn, [
        open("before", "hotel-z", "flexible", 1_000),
        cash("before-payment", "before", 100, "2026-10-04"),
        start("start-reporting", "2026-10-05"),
        open("after", "hotel-a", "flexible", 1_000),
        cash("after-payment", "after", 50, "2026-10-01")
      ])

    start_result = Enum.at(response["results"], 2)

    assert start_result == %{
             "operation_id" => "start-reporting",
             "status" => "applied",
             "starts_on" => "2026-10-05"
           }

    report = report(conn, "2026-10-05")

    assert report["cash"] == [
             cash_entry("hotel-a", 0, %{"received_cents" => 50}, 50),
             cash_entry("hotel-z", 100, %{}, 100)
           ]

    assert report["credit"] == credit_entry(0, %{}, 0)

    assert submit(conn, [start("start-reporting", "2026-10-05")]) |> only_result() ==
             start_result

    assert submit(conn, [start("another-start", "2026-10-06")]) |> only_result() == %{
             "operation_id" => "another-start",
             "status" => "rejected",
             "code" => "reporting_already_started"
           }

    assert report(conn, "2026-10-05") == report

    assert conn
           |> get("/api/v1/finance/daily-report?date=2026-10-04")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for path <- [
          "/api/v1/finance/daily-report",
          "/api/v1/finance/daily-report?date=nope"
        ] do
      assert conn |> get(path) |> json_response(422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end
  end

  test "rejects invalid reporting dates without enabling reporting", %{conn: conn} do
    assert submit(conn, [start("bad-start", "not-a-date")]) |> only_result() == %{
             "operation_id" => "bad-start",
             "status" => "rejected",
             "code" => "invalid_reporting_date"
           }

    assert submit(conn, [Map.delete(start("missing-start", "2026-10-05"), "starts_on")])
           |> only_result()
           |> Map.fetch!("code") == "invalid_reporting_date"

    assert submit(conn, [start("good-start", "2026-10-05")])
           |> only_result()
           |> Map.fetch!("status") == "applied"
  end

  test "reports cash movement by the property where funding is held or settled", %{conn: conn} do
    submit(conn, [
      open("source", "hotel-a", "flexible", 1_000),
      open("destination", "hotel-b", "flexible", 1_000),
      start("start", "2026-10-05"),
      cash("payment", "source", 150, "2026-10-06"),
      transfer("move", "source", "destination", 80, "2026-10-07"),
      reduce("reduce", "payment", 30, "2026-10-08"),
      cancel("refund-destination", "destination", "2026-10-09"),
      chargeback("chargeback", "payment", "2026-10-10")
    ])

    assert report(conn, "2026-10-06")["cash"] == [
             cash_entry("hotel-a", 0, %{"received_cents" => 150}, 150)
           ]

    assert report(conn, "2026-10-07")["cash"] == [
             cash_entry("hotel-a", 150, %{"transferred_out_cents" => 80}, 70),
             cash_entry("hotel-b", 0, %{"transferred_in_cents" => 80}, 80)
           ]

    assert report(conn, "2026-10-08")["cash"] == [
             cash_entry("hotel-a", 70, %{}, 70),
             cash_entry("hotel-b", 80, %{"reduced_cents" => 30}, 50)
           ]

    assert report(conn, "2026-10-09")["cash"] == [
             cash_entry("hotel-a", 70, %{}, 70),
             cash_entry("hotel-b", 50, %{"refunded_cents" => 50}, 0)
           ]

    assert report(conn, "2026-10-10")["cash"] == [
             cash_entry("hotel-a", 70, %{"charged_back_cents" => 70}, 0),
             cash_entry(
               "hotel-b",
               0,
               %{"refunded_cents" => -50, "charged_back_cents" => 50},
               0
             )
           ]
  end

  test "reports credit issuance, revocation, and shortfall absorption", %{conn: conn} do
    submit(conn, [
      open("maker", "hotel-a", "flexible", 500),
      start("start", "2026-10-01"),
      cash("payment", "maker", 100, "2026-10-01"),
      cancel("issue", "maker", "2026-10-02", "hotel_credit"),
      open("target", "hotel-b", "flexible", 500),
      apply_credit("apply", "target", 60, "2026-10-03"),
      chargeback("chargeback", "payment", "2026-10-04"),
      cancel("restore", "target", "2026-10-05")
    ])

    assert report(conn, "2026-10-02")["credit"] ==
             credit_entry(0, %{"issued_cents" => 110}, 110)

    assert report(conn, "2026-10-03")["credit"] == credit_entry(110, %{}, 110)

    assert report(conn, "2026-10-04")["credit"] ==
             credit_entry(110, %{"revoked_cents" => 50}, 60)

    assert report(conn, "2026-10-05")["credit"] ==
             credit_entry(60, %{"absorbed_cents" => 60}, 0)
  end

  test "reports consumption and expiry on a day with no submitted operation", %{conn: conn} do
    submit(conn, [
      open("maker-a", "hotel", "flexible", 500),
      open("maker-b", "hotel", "flexible", 500),
      start("start", "2026-10-01"),
      cash("pay-a", "maker-a", 100, "2026-10-01"),
      cash("pay-b", "maker-b", 100, "2026-10-01"),
      cancel("issue-a", "maker-a", "2026-10-02", "hotel_credit"),
      cancel("issue-b", "maker-b", "2026-10-02", "hotel_credit"),
      open("target", "hotel", "advance_purchase", 110),
      apply_credit("apply", "target", 110, "2026-10-03"),
      cancel("consume", "target", "2026-10-04")
    ])

    assert report(conn, "2026-10-04")["credit"] ==
             credit_entry(220, %{"consumed_cents" => 110}, 110)

    expiry_report = report(conn, "2027-10-03")

    assert expiry_report["credit"] ==
             credit_entry(110, %{"expired_cents" => 110}, 0)

    assert report(conn, "2027-10-03") == expiry_report
  end

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)

  defp only_result(%{"results" => [result]}), do: result

  defp report(conn, date),
    do:
      conn
      |> get("/api/v1/finance/daily-report?date=#{date}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp open(id, property_id, rate_plan, nightly_rate),
    do: %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2028-12-10",
      "departure_on" => "2028-12-11",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => nightly_rate}]
    }

  defp cash(id, group_id, amount, occurred_on),
    do: %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }

  defp start(id, starts_on),
    do: %{
      "operation_id" => id,
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-10-01",
      "starts_on" => starts_on
    }

  defp transfer(id, source, destination, amount, occurred_on),
    do: %{
      "operation_id" => id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }

  defp reduce(id, payment_id, amount, occurred_on),
    do: %{
      "operation_id" => id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id,
      "amount_cents" => amount
    }

  defp chargeback(id, payment_id, occurred_on),
    do: %{
      "operation_id" => id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }

  defp cancel(id, group_id, occurred_on, method \\ nil) do
    operation = %{
      "operation_id" => id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    if method, do: Map.put(operation, "refund_method", method), else: operation
  end

  defp apply_credit(id, group_id, amount, occurred_on),
    do: %{
      "operation_id" => id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }

  defp cash_entry(property_id, opening, overrides, closing) do
    movements =
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

    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => movements,
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, overrides, closing) do
    movements =
      Map.merge(
        %{
          "issued_cents" => 0,
          "expired_cents" => 0,
          "consumed_cents" => 0,
          "revoked_cents" => 0,
          "absorbed_cents" => 0
        },
        overrides
      )

    %{
      "opening_liability_cents" => opening,
      "movements" => movements,
      "closing_liability_cents" => closing
    }
  end
end
