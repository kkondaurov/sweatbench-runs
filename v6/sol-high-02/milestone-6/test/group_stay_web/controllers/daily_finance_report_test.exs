defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  test "validates report dates and starts reporting durably", %{conn: conn} do
    assert conn
           |> get("/api/v1/finance/daily-report")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=not-a-date")
           |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    invalid_start = start_operation("invalid-start", "bad-date")
    %{"results" => [invalid]} = post_batch(build_conn(), [invalid_start])
    assert invalid["code"] == "invalid_reporting_date"

    start = start_operation("start", "2026-10-05")
    %{"results" => [applied, replay]} = post_batch(build_conn(), [start, start])

    assert applied == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-10-05"
           }

    assert replay == applied

    %{"results" => [second, conflict]} =
      post_batch(build_conn(), [
        start_operation("another-start", "2026-10-06"),
        %{start | "starts_on" => "2026-10-06"}
      ])

    assert second["code"] == "reporting_already_started"
    assert conflict["code"] == "operation_id_conflict"

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-04")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "captures processing-order opening and floors later posting dates", %{conn: conn} do
    operations = [
      open_operation("group", "ams-canal", "guest"),
      payment_operation("opening-payment", "group", 400, "2026-12-01"),
      start_operation("start", "2026-10-05"),
      payment_operation("day-payment", "group", 200, "2026-10-01")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    report = get_report("2026-10-05")

    assert report == %{
             "date" => "2026-10-05",
             "status" => "open",
             "cash" => [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 400,
                 "movements" => cash_movements(%{"received_cents" => 200}),
                 "closing_held_cents" => 600
               }
             ],
             "credit" => credit(0, %{}, 0)
           }

    assert get_report("2026-10-05") == report

    assert get_report("2026-10-06")["cash"] == [
             %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 600,
               "movements" => cash_movements(),
               "closing_held_cents" => 600
             }
           ]
  end

  test "reports transfers and reductions at the properties where cash is held", %{conn: conn} do
    operations = [
      open_operation("source", "zurich", "guest"),
      open_operation("destination", "amsterdam", "guest"),
      start_operation("start", "2026-10-01"),
      payment_operation("pay", "source", 600, "2026-10-02"),
      transfer_operation("transfer", "source", "destination", 200, "2026-10-02"),
      reduce_operation("reduce", "pay", 100, "2026-10-02")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2026-10-02")["cash"] == [
             %{
               "property_id" => "amsterdam",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{"transferred_in_cents" => 200, "reduced_cents" => 100}),
               "closing_held_cents" => 100
             },
             %{
               "property_id" => "zurich",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{"received_cents" => 600, "transferred_out_cents" => 200}),
               "closing_held_cents" => 400
             }
           ]
  end

  test "a chargeback reverses settlement classification at its settlement property", %{conn: conn} do
    operations = [
      open_operation("source", "zurich", "guest"),
      open_operation("destination", "amsterdam", "guest"),
      start_operation("start", "2026-10-01"),
      payment_operation("pay", "source", 500, "2026-10-02"),
      transfer_operation("transfer", "source", "destination", 200, "2026-10-02"),
      cancel_operation("cancel", "destination", "2026-10-03"),
      chargeback_operation("chargeback", "pay", "2026-10-04")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2026-10-03")["cash"] |> hd() == %{
             "property_id" => "amsterdam",
             "opening_held_cents" => 200,
             "movements" => cash_movements(%{"refunded_cents" => 200}),
             "closing_held_cents" => 0
           }

    assert get_report("2026-10-04")["cash"] == [
             %{
               "property_id" => "amsterdam",
               "opening_held_cents" => 0,
               "movements" =>
                 cash_movements(%{"refunded_cents" => -200, "charged_back_cents" => 200}),
               "closing_held_cents" => 0
             },
             %{
               "property_id" => "zurich",
               "opening_held_cents" => 300,
               "movements" => cash_movements(%{"charged_back_cents" => 300}),
               "closing_held_cents" => 0
             }
           ]
  end

  test "reports credit issue, paused expiry, restoration, and automatic expiry", %{conn: conn} do
    operations = [
      start_operation("start", "2026-01-01"),
      open_operation("source", "amsterdam", "guest", "2026-12-31"),
      payment_operation("pay", "source", 100, "2026-01-02"),
      cancel_operation("issue", "source", "2026-01-02", "hotel_credit"),
      open_operation("target", "amsterdam", "guest", "2027-02-01"),
      credit_operation("apply-credit", "target", 50, "2026-01-03"),
      cancel_operation("restore-credit", "target", "2026-01-04")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2026-01-02")["credit"] ==
             credit(0, %{"issued_cents" => 110}, 110)

    assert get_report("2026-01-02")["cash"] |> hd() |> Map.fetch!("movements") ==
             cash_movements(%{
               "received_cents" => 100,
               "converted_to_credit_cents" => 100
             })

    # The lot is available through 2027-01-02 and expires the next day.
    assert get_report("2027-01-02")["credit"] == credit(110, %{}, 110)
    assert get_report("2027-01-03")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
  end

  test "reports credit consumption, revocation shortfall absorption, and expired restoration", %{
    conn: conn
  } do
    operations = [
      start_operation("start", "2026-01-01"),
      open_operation("source", "amsterdam", "guest", "2026-12-31"),
      payment_operation("pay", "source", 100, "2026-01-02"),
      cancel_operation("issue", "source", "2026-01-02", "hotel_credit"),
      open_operation("absorbed-target", "amsterdam", "guest", "2027-02-01"),
      credit_operation("apply-absorbed", "absorbed-target", 50, "2026-01-03"),
      chargeback_operation("chargeback", "pay", "2026-01-04"),
      cancel_operation("absorb", "absorbed-target", "2026-01-05")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2026-01-04")["credit"] ==
             credit(110, %{"revoked_cents" => 60}, 50)

    assert get_report("2026-01-05")["credit"] ==
             credit(50, %{"absorbed_cents" => 50}, 0)

    # A separate lot is kept applied past its expiry, then expires immediately when restored.
    second = [
      open_operation("source-two", "amsterdam", "guest-two", "2026-12-31"),
      payment_operation("pay-two", "source-two", 100, "2026-01-02"),
      cancel_operation("issue-two", "source-two", "2026-01-02", "hotel_credit"),
      open_operation("expired-target", "amsterdam", "guest-two", "2027-02-01"),
      credit_operation("apply-expired", "expired-target", 110, "2026-01-03"),
      cancel_operation("expire-restored", "expired-target", "2027-01-03")
    ]

    %{"results" => second_results} = post_batch(build_conn(), second)
    assert Enum.all?(second_results, &(&1["status"] == "applied"))

    assert get_report("2027-01-03")["credit"] ==
             credit(110, %{"expired_cents" => 110}, 0)
  end

  test "reports non-refundable settlement as consumed credit", %{conn: conn} do
    advance_target =
      open_operation("advance-target", "amsterdam", "guest", "2026-12-31")
      |> Map.put("rate_plan", "advance_purchase")

    operations = [
      start_operation("start", "2026-01-01"),
      open_operation("source", "amsterdam", "guest", "2026-12-31"),
      payment_operation("pay", "source", 100, "2026-01-02"),
      cancel_operation("issue", "source", "2026-01-02", "hotel_credit"),
      advance_target,
      credit_operation("apply", "advance-target", 50, "2026-01-03"),
      cancel_operation("consume", "advance-target", "2026-01-04")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2026-01-04")["credit"] ==
             credit(110, %{"consumed_cents" => 50}, 60)
  end

  test "floors already-expired issuance and restoration without overstating liability", %{
    conn: conn
  } do
    operations = [
      start_operation("start", "2027-02-01"),
      open_operation("source", "amsterdam", "guest", "2028-01-01"),
      payment_operation("pay", "source", 100, "2026-01-02"),
      cancel_operation("issue", "source", "2026-01-02", "hotel_credit"),
      chargeback_operation("chargeback", "pay", "2026-01-03")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2027-02-01")["credit"] ==
             credit(0, %{"issued_cents" => 110, "expired_cents" => 110}, 0)
  end

  test "floored restoration expires applied opening credit on the posting date", %{conn: conn} do
    operations = [
      open_operation("source", "amsterdam", "guest", "2028-01-01"),
      payment_operation("pay", "source", 100, "2026-01-02"),
      cancel_operation("issue", "source", "2026-01-02", "hotel_credit"),
      open_operation("target", "amsterdam", "guest", "2028-01-01"),
      credit_operation("apply", "target", 110, "2026-01-03"),
      start_operation("start", "2027-02-01"),
      cancel_operation("restore", "target", "2026-01-04")
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert get_report("2027-02-01")["credit"] ==
             credit(110, %{"expired_cents" => 110}, 0)
  end

  test "retries and rejected operations never duplicate movements", %{conn: conn} do
    start = start_operation("start", "2026-10-01")
    open = open_operation("group", "amsterdam", "guest")
    payment = payment_operation("pay", "group", 300, "2026-10-02")
    excessive = payment_operation("too-much", "group", 10_000, "2026-10-02")

    %{"results" => results} = post_batch(conn, [start, open, payment, payment, excessive])
    assert Enum.at(results, 2) == Enum.at(results, 3)
    assert List.last(results)["code"] == "payment_exceeds_outstanding"

    assert get_report("2026-10-02")["cash"] |> hd() |> Map.fetch!("movements") ==
             cash_movements(%{"received_cents" => 300})
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp get_report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp start_operation(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "occurred_on" => "2026-10-01",
      "starts_on" => starts_on
    }
  end

  defp open_operation(group_id, property_id, guest_id, arrival_on \\ "2026-12-20") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => arrival_on,
      "departure_on" => Date.to_iso8601(Date.add(Date.from_iso8601!(arrival_on), 1)),
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5_000}]
    }
  end

  defp payment_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer_operation(operation_id, source, destination, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp reduce_operation(operation_id, payment_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id,
      "amount_cents" => amount
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, refund_method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp chargeback_operation(operation_id, payment_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_id
    }
  end

  defp cash_movements(overrides \\ %{}) do
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

  defp credit(opening, movement_overrides, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" =>
        Map.merge(
          %{
            "issued_cents" => 0,
            "expired_cents" => 0,
            "consumed_cents" => 0,
            "revoked_cents" => 0,
            "absorbed_cents" => 0
          },
          movement_overrides
        ),
      "closing_liability_cents" => closing
    }
  end
end
