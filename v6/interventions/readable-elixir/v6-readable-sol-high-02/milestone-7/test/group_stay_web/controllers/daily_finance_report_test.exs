defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  describe "starting finance reporting" do
    test "captures the exact in-batch opening boundary and follows durable replay rules", %{
      conn: conn
    } do
      start = start_operation("start", "2027-01-05")

      [_, _, started, paid_after_start] =
        post_batch(conn, [
          open_operation("open", "group", "property-b"),
          cash_operation("opening-cash", "group", 400, "2027-01-10"),
          start,
          cash_operation("movement-cash", "group", 200, "2027-01-01")
        ])

      assert started == %{
               "operation_id" => "start",
               "starts_on" => "2027-01-05",
               "status" => "applied"
             }

      assert paid_after_start["status"] == "applied"

      assert get_report("2027-01-05") == %{
               "date" => "2027-01-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "property-b",
                   "opening_held_cents" => 400,
                   "movements" => cash_movements(%{"received_cents" => 200}),
                   "closing_held_cents" => 600
                 }
               ],
               "credit" => empty_credit(),
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => credit_movements(%{})
               }
             }

      [replay, conflict, already_started] =
        post_batch(build_conn(), [
          start,
          start_operation("start", "2027-01-06"),
          start_operation("another-start", "2027-01-05")
        ])

      assert replay == started
      assert conflict["code"] == "operation_id_conflict"
      assert already_started["code"] == "reporting_already_started"
      assert get_report("2027-01-05")["cash"] |> hd() |> Map.fetch!("closing_held_cents") == 600
    end

    test "validates start and report dates and availability", %{conn: conn} do
      assert_error(get(conn, "/api/v1/finance/daily-report"), 422, "invalid_reporting_date")

      assert_error(
        get(build_conn(), "/api/v1/finance/daily-report?date=not-a-date"),
        422,
        "invalid_reporting_date"
      )

      assert_error(
        get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-01"),
        404,
        "report_not_available"
      )

      [missing, invalid, started] =
        post_batch(build_conn(), [
          %{"operation_id" => "missing", "type" => "start_finance_reporting"},
          start_operation("invalid", "2027-99-01"),
          start_operation("valid", "2027-01-05")
        ])

      assert missing["code"] == "invalid_reporting_date"
      assert invalid["code"] == "invalid_reporting_date"
      assert started["status"] == "applied"

      assert_error(
        get(build_conn(), "/api/v1/finance/daily-report?date=2027-01-04"),
        404,
        "report_not_available"
      )
    end
  end

  test "classifies transfers, reductions, refunds, and chargeback reversals by property", %{
    conn: conn
  } do
    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open-source", "source", "property-b"),
      open_operation("open-destination", "destination", "property-a"),
      cash_operation("cash", "source", 1_000, "2027-01-01"),
      transfer_operation("transfer", "source", "destination", 400, "2027-01-02"),
      reduce_operation("reduce", "cash", 100, "2027-01-03"),
      cancel_operation("refund", "destination", "2027-01-04"),
      chargeback_operation("chargeback", "cash", "2027-01-05")
    ])

    assert get_report("2027-01-02")["cash"] == [
             cash_entry("property-a", 0, %{"transferred_in_cents" => 400}, 400),
             cash_entry("property-b", 1_000, %{"transferred_out_cents" => 400}, 600)
           ]

    assert get_report("2027-01-03")["cash"] == [
             cash_entry("property-a", 400, %{"reduced_cents" => 100}, 300),
             cash_entry("property-b", 600, %{}, 600)
           ]

    assert get_report("2027-01-04")["cash"] == [
             cash_entry("property-a", 300, %{"refunded_cents" => 300}, 0),
             cash_entry("property-b", 600, %{}, 600)
           ]

    assert get_report("2027-01-05")["cash"] == [
             cash_entry(
               "property-a",
               0,
               %{"refunded_cents" => -300, "charged_back_cents" => 300},
               0
             ),
             cash_entry("property-b", 600, %{"charged_back_cents" => 600}, 0)
           ]
  end

  test "reports issued liability and computes unused-credit expiry without mutating state", %{
    conn: conn
  } do
    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open", "group", "property-a"),
      cash_operation("cash", "group", 100, "2027-01-02"),
      cancel_operation("credit", "group", "2027-01-02", %{"refund_method" => "hotel_credit"})
    ])

    issued = get_report("2027-01-02")

    assert issued["cash"] == [
             cash_entry(
               "property-a",
               0,
               %{"received_cents" => 100, "converted_to_credit_cents" => 100},
               0
             )
           ]

    assert issued["credit"] == %{
             "opening_liability_cents" => 0,
             "movements" => credit_movements(%{"issued_cents" => 110}),
             "closing_liability_cents" => 110
           }

    expected_expiry = %{
      "opening_liability_cents" => 110,
      "movements" => credit_movements(%{"expired_cents" => 110}),
      "closing_liability_cents" => 0
    }

    assert get_report("2028-01-03")["credit"] == expected_expiry
    assert get_report("2028-01-03")["credit"] == expected_expiry

    ledger =
      build_conn()
      |> get("/api/v1/ledger?on=2028-01-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
  end

  test "reports revocation and later shortfall absorption for converted credit", %{conn: conn} do
    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open-seed", "seed", "property-a"),
      cash_operation("cash", "seed", 100, "2027-01-02"),
      cancel_operation("credit", "seed", "2027-01-02", %{
        "refund_method" => "hotel_credit"
      }),
      open_operation("open-use", "use", "property-b"),
      credit_operation("apply-credit", "use", 100, "2027-01-03"),
      chargeback_operation("chargeback", "cash", "2027-01-04"),
      cancel_operation("restore", "use", "2027-01-05")
    ])

    assert get_report("2027-01-04")["credit"] == %{
             "opening_liability_cents" => 110,
             "movements" => credit_movements(%{"revoked_cents" => 10}),
             "closing_liability_cents" => 100
           }

    assert get_report("2027-01-05")["credit"] == %{
             "opening_liability_cents" => 100,
             "movements" => credit_movements(%{"absorbed_cents" => 100}),
             "closing_liability_cents" => 0
           }
  end

  test "reports retained cash and consumed credit on non-refundable settlement", %{conn: conn} do
    nonrefundable_group =
      "open-use"
      |> open_operation("use", "property-b")
      |> Map.put("rate_plan", "advance_purchase")

    post_batch(conn, [
      start_operation("start", "2027-01-01"),
      open_operation("open-seed", "seed", "property-a"),
      cash_operation("seed-cash", "seed", 100, "2027-01-02"),
      cancel_operation("credit", "seed", "2027-01-02", %{
        "refund_method" => "hotel_credit"
      }),
      nonrefundable_group,
      cash_operation("cash-use", "use", 50, "2027-01-03"),
      credit_operation("apply-credit", "use", 100, "2027-01-03"),
      cancel_operation("consume", "use", "2027-01-03")
    ])

    report = get_report("2027-01-03")

    assert report["cash"] == [
             cash_entry(
               "property-b",
               0,
               %{"received_cents" => 50, "retained_cents" => 50},
               0
             )
           ]

    assert report["credit"] == %{
             "opening_liability_cents" => 110,
             "movements" => credit_movements(%{"consumed_cents" => 100}),
             "closing_liability_cents" => 10
           }
  end

  defp start_operation(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
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

  defp credit_operation(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp reduce_operation(operation_id, payment_operation_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
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

  defp assert_error(conn, status, code) do
    assert json_response(conn, status) == %{"error" => %{"code" => code}}
  end
end
