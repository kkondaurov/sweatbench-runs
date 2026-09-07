defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  test "validates closes and preserves durable replay semantics", %{conn: conn} do
    rejected_before_start = close_operation("too-early", "2027-01-05")

    [before_start, started, missing, before_inception, closed] =
      post_batch(conn, [
        rejected_before_start,
        start_operation("start", "2027-01-05"),
        %{"operation_id" => "missing", "type" => "close_finance_period"},
        close_operation("before-inception", "2027-01-04"),
        close_operation("close", "2027-01-05")
      ])

    assert before_start["code"] == "invalid_period"
    assert started["status"] == "applied"
    assert missing["code"] == "invalid_period"
    assert before_inception["code"] == "invalid_period"

    assert closed == %{
             "operation_id" => "close",
             "period_end_on" => "2027-01-05",
             "status" => "applied"
           }

    [replayed_rejection, replayed_close, conflict, same_cutoff, earlier_cutoff] =
      post_batch(build_conn(), [
        rejected_before_start,
        close_operation("close", "2027-01-05"),
        close_operation("close", "2027-01-06"),
        close_operation("same", "2027-01-05"),
        close_operation("earlier", "2027-01-04")
      ])

    assert replayed_rejection == before_start
    assert replayed_close == closed
    assert conflict["code"] == "operation_id_conflict"
    assert same_cutoff["code"] == "invalid_period"
    assert earlier_cutoff["code"] == "invalid_period"

    assert get_report("2027-01-05")["status"] == "closed"
    assert get_report("2027-01-06")["status"] == "open"
  end

  test "keeps closed data stable and separates ordinary and late postings", %{conn: conn} do
    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open", "group", "property-a"),
      cash_operation("before-close", "group", 100, "2026-12-20"),
      close_operation("close-two", "2027-01-02"),
      cash_operation("late-three", "group", 200, "2027-01-01"),
      cash_operation("ordinary-four", "group", 300, "2027-01-04")
    ])

    closed_data = get_report("2027-01-01")

    assert closed_data == %{
             "date" => "2027-01-01",
             "status" => "closed",
             "cash" => [cash_entry("property-a", 0, %{"received_cents" => 100}, 100)],
             "credit" => empty_credit(),
             "late_adjustments" => empty_late_adjustments()
           }

    assert get_report("2027-01-03") == %{
             "date" => "2027-01-03",
             "status" => "open",
             "cash" => [cash_entry("property-a", 100, %{}, 300)],
             "credit" => empty_credit(),
             "late_adjustments" => %{
               "cash" => [
                 %{
                   "property_id" => "property-a",
                   "movements" => cash_movements(%{"received_cents" => 200})
                 }
               ],
               "credit" => credit_movements(%{})
             }
           }

    assert get_report("2027-01-04")["cash"] == [
             cash_entry("property-a", 300, %{"received_cents" => 300}, 600)
           ]

    post_batch(build_conn(), [
      cash_operation("before-next-close", "group", 100, "2027-01-04"),
      close_operation("close-four", "2027-01-04"),
      cash_operation("after-next-close", "group", 100, "2027-01-01")
    ])

    assert get_report("2027-01-01") == closed_data
    assert get_report("2027-01-04")["status"] == "closed"

    day_five = get_report("2027-01-05")
    assert day_five["cash"] == [cash_entry("property-a", 700, %{}, 800)]

    assert day_five["late_adjustments"]["cash"] == [
             %{
               "property_id" => "property-a",
               "movements" => cash_movements(%{"received_cents" => 100})
             }
           ]
  end

  test "retains signed late classifications even when their net balance effect is zero", %{
    conn: conn
  } do
    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open", "group", "property-a"),
      cash_operation("cash", "group", 100, "2027-01-01"),
      cancel_operation("refund", "group", "2027-01-02"),
      close_operation("close", "2027-01-02"),
      chargeback_operation("chargeback", "cash", "2027-01-01")
    ])

    report = get_report("2027-01-03")

    assert report["cash"] == [cash_entry("property-a", 0, %{}, 0)]

    assert report["late_adjustments"]["cash"] == [
             %{
               "property_id" => "property-a",
               "movements" =>
                 cash_movements(%{
                   "refunded_cents" => -100,
                   "charged_back_cents" => 100
                 })
             }
           ]
  end

  test "reports late credit and cash effects together on the first open day", %{conn: conn} do
    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open", "group", "property-a"),
      cash_operation("cash", "group", 100, "2027-01-01"),
      close_operation("close", "2027-01-02"),
      cancel_operation("credit", "group", "2027-01-01", %{
        "refund_method" => "hotel_credit"
      })
    ])

    report = get_report("2027-01-03")

    assert report["cash"] == [cash_entry("property-a", 100, %{}, 0)]

    assert report["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(%{}),
             "closing_liability_cents" => 110
           }

    assert report["late_adjustments"] == %{
             "cash" => [
               %{
                 "property_id" => "property-a",
                 "movements" => cash_movements(%{"converted_to_credit_cents" => 100})
               }
             ],
             "credit" => credit_movements(%{"issued_cents" => 110})
           }
  end

  test "reactivates liability when an old-dated application uses credit expired in a close", %{
    conn: conn
  } do
    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open-seed", "seed", "property-a"),
      cash_operation("cash", "seed", 100, "2027-01-01"),
      cancel_operation("issue", "seed", "2027-01-01", %{
        "refund_method" => "hotel_credit"
      }),
      open_operation("open-use", "use", "property-b"),
      close_operation("close", "2028-01-02"),
      credit_operation("apply", "use", 100, "2028-01-01")
    ])

    assert get_report("2028-01-02")["credit"] == %{
             "opening_liability_cents" => 110,
             "movements" => credit_movements(%{"expired_cents" => 110}),
             "closing_liability_cents" => 0
           }

    report = get_report("2028-01-03")

    assert report["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(%{}),
             "closing_liability_cents" => 100
           }

    assert report["late_adjustments"]["credit"] ==
             credit_movements(%{"expired_cents" => -100})
  end

  defp start_operation(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp close_operation(operation_id, period_end_on) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    }
  end

  defp open_operation(operation_id, group_id, property_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => property_id,
      "arrival_on" => "2027-03-15",
      "departure_on" => "2027-03-16",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
    }
  end

  defp cash_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extra
    )
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

  defp chargeback_operation(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
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

  defp empty_credit do
    %{
      "opening_liability_cents" => 0,
      "movements" => credit_movements(%{}),
      "closing_liability_cents" => 0
    }
  end

  defp empty_late_adjustments do
    %{"cash" => [], "credit" => credit_movements(%{})}
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
end
