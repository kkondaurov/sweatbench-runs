defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "starts once from the exact batch position and validates report dates", %{conn: conn} do
    assert conn |> get("/api/v1/finance/daily-report") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert conn |> get("/api/v1/finance/daily-report?date=not-a-date") |> json_response(422) ==
             %{"error" => %{"code" => "invalid_reporting_date"}}

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-01") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    submit(conn, open_group("group", "ams-canal"))
    submit(conn, cash_payment("before", "group", 1_000, "2026-10-01"))

    assert [started, after_start] =
             submit_batch(conn, [
               start_reporting("start", "2026-10-03"),
               cash_payment("after", "group", 500, "2026-09-01")
             ])

    assert started == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-10-03"
           }

    assert after_start["status"] == "applied"
    assert submit(conn, cash_payment("after", "group", 500, "2026-09-01")) == after_start
    assert submit(conn, start_reporting("start", "2026-10-03")) == started

    assert submit(conn, start_reporting("another-start", "2026-10-03")) == %{
             "operation_id" => "another-start",
             "status" => "rejected",
             "code" => "reporting_already_started"
           }

    assert submit(conn, %{
             "operation_id" => "invalid-start",
             "type" => "start_finance_reporting"
           })["code"] == "invalid_reporting_date"

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-02") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert conn |> get("/api/v1/finance/daily-report?date=2026-09-30") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert report(conn, "2026-10-03") == %{
             "date" => "2026-10-03",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_000,
                 "movements" => cash_movements(%{"received_cents" => 500}),
                 "closing_held_cents" => 1_500
               }
             ],
             "credit" => credit_report(0, %{}, 0),
             "late_adjustments" => %{
               "cash" => [],
               "credit" => credit_movements(%{})
             }
           }

    assert report(conn, "2026-10-04")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_500,
               "movements" => cash_movements(%{}),
               "closing_held_cents" => 1_500
             }
           ]
  end

  test "classifies transfers, settlement, reductions, and chargeback reversals by property", %{
    conn: conn
  } do
    submit(conn, start_reporting("start", "2026-10-01"))
    submit(conn, open_group("source", "zrh-center", guest_id: "guest"))
    submit(conn, open_group("destination", "ams-canal", guest_id: "guest"))
    submit(conn, cash_payment("payment", "source", 2_000, "2026-10-02"))
    submit(conn, transfer("move", "source", "destination", 500, "2026-10-03"))
    submit(conn, reduce_payment("reduce", "payment", 300, "2026-10-04"))
    submit(conn, cancel_group("refund", "destination", "2026-10-05"))
    submit(conn, charge_back("chargeback", "payment", "2026-10-06"))

    assert report(conn, "2026-10-03")["cash"] == [
             cash_entry("ams-canal", 0, %{"transferred_in_cents" => 500}, 500),
             cash_entry("zrh-center", 2_000, %{"transferred_out_cents" => 500}, 1_500)
           ]

    assert report(conn, "2026-10-04")["cash"] == [
             cash_entry("ams-canal", 500, %{"reduced_cents" => 300}, 200),
             cash_entry("zrh-center", 1_500, %{}, 1_500)
           ]

    assert report(conn, "2026-10-05")["cash"] == [
             cash_entry("ams-canal", 200, %{"refunded_cents" => 200}, 0),
             cash_entry("zrh-center", 1_500, %{}, 1_500)
           ]

    assert report(conn, "2026-10-06")["cash"] == [
             cash_entry(
               "ams-canal",
               0,
               %{"refunded_cents" => -200, "charged_back_cents" => 200},
               0
             ),
             cash_entry("zrh-center", 1_500, %{"charged_back_cents" => 1_500}, 0)
           ]

    assert report(conn, "2026-10-06") == report(conn, "2026-10-06")
  end

  test "reports issued liability, paused expiry, and expiry on restoration", %{conn: conn} do
    submit(conn, start_reporting("start", "2026-10-01"))
    submit(conn, open_group("original", "ams-canal", guest_id: "guest"))
    submit(conn, cash_payment("cash", "original", 1_000, "2026-10-01"))

    submit(
      conn,
      cancel_group("issue", "original", "2026-10-02", refund_method: "hotel_credit")
    )

    submit(
      conn,
      open_group("funded", "ams-canal",
        guest_id: "guest",
        arrival_on: "2028-01-01",
        departure_on: "2028-01-02"
      )
    )

    submit(conn, credit_payment("apply", "funded", 600, "2026-10-03"))

    assert report(conn, "2026-10-02")["credit"] ==
             credit_report(0, %{"issued_cents" => 1_100}, 1_100)

    # The lot is available through 2027-10-02. Its 600 applied cents stay as
    # liability while the unused 500 expires on the following date.
    assert report(conn, "2027-10-03")["credit"] ==
             credit_report(1_100, %{"expired_cents" => 500}, 600)

    submit(conn, cancel_group("restore-expired", "funded", "2027-10-04"))

    assert report(conn, "2027-10-04")["credit"] ==
             credit_report(600, %{"expired_cents" => 600}, 0)

    assert report(conn, "2027-10-04")["cash"] == []
  end

  test "reports credit revocation shortfall absorption and non-refundable consumption", %{
    conn: conn
  } do
    submit(conn, start_reporting("start", "2026-10-01"))
    submit(conn, open_group("original", "ams-canal", guest_id: "guest"))
    submit(conn, cash_payment("cash", "original", 1_000, "2026-10-01"))

    submit(
      conn,
      cancel_group("issue", "original", "2026-10-02", refund_method: "hotel_credit")
    )

    submit(conn, open_group("funded", "ams-canal", guest_id: "guest"))
    submit(conn, credit_payment("apply", "funded", 1_100, "2026-10-03"))
    submit(conn, charge_back("chargeback", "cash", "2026-10-04"))

    # All of the entitlement is in use, so the chargeback creates a shortfall
    # without immediately reducing liability.
    assert report(conn, "2026-10-04")["credit"] == credit_report(1_100, %{}, 1_100)

    assert report(conn, "2026-10-04")["cash"] == [
             cash_entry(
               "ams-canal",
               0,
               %{
                 "converted_to_credit_cents" => -1_000,
                 "charged_back_cents" => 1_000
               },
               0
             )
           ]

    submit(conn, cancel_group("absorb", "funded", "2026-10-05"))

    assert report(conn, "2026-10-05")["credit"] ==
             credit_report(1_100, %{"absorbed_cents" => 1_100}, 0)

    submit(conn, open_group("cash-two", "ber-center", guest_id: "guest-two"))
    submit(conn, cash_payment("cash-two", "cash-two", 1_000, "2026-10-06"))

    submit(
      conn,
      cancel_group("issue-two", "cash-two", "2026-10-07", refund_method: "hotel_credit")
    )

    submit(
      conn,
      open_group("nonref", "ber-center",
        guest_id: "guest-two",
        rate_plan: "advance_purchase"
      )
    )

    submit(conn, credit_payment("apply-two", "nonref", 1_100, "2026-10-08"))
    submit(conn, cancel_group("consume", "nonref", "2026-10-09"))

    assert report(conn, "2026-10-09")["credit"] ==
             credit_report(1_100, %{"consumed_cents" => 1_100}, 0)
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp submit(conn, operation), do: submit_batch(conn, [operation]) |> hd()

  defp submit_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp start_reporting(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp open_group(group_id, property_id, opts \\ []) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-09-01",
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-1"),
      "property_id" => property_id,
      "arrival_on" => Keyword.get(opts, :arrival_on, "2026-12-20"),
      "departure_on" => Keyword.get(opts, :departure_on, "2026-12-21"),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash_payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(operation_id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp reduce_payment(operation_id, payment_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id,
      "amount_cents" => amount
    }
  end

  defp charge_back(operation_id, payment_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }
  end

  defp cancel_group(operation_id, group_id, occurred_on, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_put("refund_method", opts[:refund_method])
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => cash_movements(movements),
      "closing_held_cents" => closing
    }
  end

  defp cash_movements(overrides) do
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

  defp credit_report(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => credit_movements(movements),
      "closing_liability_cents" => closing
    }
  end

  defp credit_movements(overrides) do
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
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
