defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Finance.Movement
  alias GroupStay.Repo

  @starts_on "2026-11-01"

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp results(conn), do: json_response(conn, 200)["results"]

  defp single_result(conn, operations) do
    [result] = conn |> submit(operations) |> results()
    result
  end

  defp open_group_op(op_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
      },
      overrides
    )
  end

  defp open_group(conn, op_id, group_id, overrides \\ %{}) do
    result = single_result(conn, [open_group_op(op_id, group_id, overrides)])
    assert result["status"] == "applied"
    result
  end

  defp pay_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp pay(conn, op_id, group_id, amount_cents, overrides \\ %{}) do
    result = single_result(conn, [pay_op(op_id, group_id, amount_cents, overrides)])
    assert result["status"] == "applied"
    result
  end

  defp start_op(op_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "start_finance_reporting",
        "starts_on" => @starts_on
      },
      overrides
    )
  end

  defp start_reporting(conn, op_id, overrides \\ %{}) do
    result = single_result(conn, [start_op(op_id, overrides)])
    assert result["status"] == "applied"
    result
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp report_status(conn, date) do
    conn |> get("/api/v1/finance/daily-report?date=#{date}") |> json_response(422)
  end

  defp report_status_404(conn, date) do
    conn |> get("/api/v1/finance/daily-report?date=#{date}") |> json_response(404)
  end

  defp ledger(conn, on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"
    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  defp cancel(conn, op_id, group_id, occurred_on, overrides \\ %{}) do
    op =
      Map.merge(
        %{
          "operation_id" => op_id,
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id
        },
        overrides
      )

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp apply_credit(conn, op_id, group_id, amount_cents, occurred_on) do
    op = %{
      "operation_id" => op_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  # Opens a group, pays it, and cancels it as hotel credit so the guest holds
  # a credit lot. Returns the cancellation result.
  defp issue_credit(conn) do
    open_group(conn, "op-open-a", "group-a")
    pay(conn, "op-pay-a", "group-a", 4000)

    cancel(conn, "op-cancel-a", "group-a", "2026-11-02", %{
      "refund_method" => "hotel_credit"
    })
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  describe "start_finance_reporting operation" do
    test "applies and returns exactly operation_id, status, starts_on", %{conn: conn} do
      result = single_result(conn, [start_op("op-start")])

      assert result == %{
               "operation_id" => "op-start",
               "status" => "applied",
               "starts_on" => @starts_on
             }
    end

    test "a second different start is rejected with reporting_already_started", %{conn: conn} do
      start_reporting(conn, "op-start-1")
      result = single_result(conn, [start_op("op-start-2")])

      assert result == %{
               "operation_id" => "op-start-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }
    end

    test "retry of the original start returns the stored applied result", %{conn: conn} do
      first = single_result(conn, [start_op("op-start")])
      retry = single_result(conn, [start_op("op-start")])
      assert retry == first
      assert retry["status"] == "applied"
    end

    test "reusing the identifier with a different payload conflicts", %{conn: conn} do
      start_reporting(conn, "op-start")

      result = single_result(conn, [start_op("op-start", %{"starts_on" => "2026-12-01"})])

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"
    end

    test "invalid starts_on is rejected with invalid_reporting_date", %{conn: conn} do
      result = single_result(conn, [start_op("op-start", %{"starts_on" => "not-a-date"})])

      assert result == %{
               "operation_id" => "op-start",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }
    end

    test "missing starts_on is rejected with invalid_reporting_date", %{conn: conn} do
      op = %{"operation_id" => "op-start", "type" => "start_finance_reporting"}
      result = single_result(conn, [op])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_reporting_date"
    end

    test "a rejected start does not enable reporting", %{conn: conn} do
      single_result(conn, [start_op("op-start", %{"starts_on" => "bad"})])
      assert report_status_404(conn, @starts_on)["error"]["code"] == "report_not_available"
    end

    test "does not require a group and ignores revision", %{conn: conn} do
      # No group_id, no expected_revision needed.
      result = single_result(conn, [start_op("op-start", %{"expected_revision" => 99})])
      assert result["status"] == "applied"
    end
  end

  describe "reading one day - error handling" do
    test "missing date returns 422 invalid_reporting_date", %{conn: conn} do
      body = conn |> get("/api/v1/finance/daily-report") |> json_response(422)
      assert body == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "invalid date returns 422 invalid_reporting_date", %{conn: conn} do
      assert report_status(conn, "nonsense") == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end

    test "before reporting starts returns 404 report_not_available", %{conn: conn} do
      assert report_status_404(conn, @starts_on) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "a date before starts_on returns 404 report_not_available", %{conn: conn} do
      start_reporting(conn, "op-start")

      assert report_status_404(conn, "2026-10-31") == %{
               "error" => %{"code" => "report_not_available"}
             }
    end
  end

  describe "opening position" do
    test "cash held before the start is the opening, even with a later occurred_on", %{
      conn: conn
    } do
      open_group(conn, "op-open", "group-81")
      # Committed before the start but occurred after starts_on: still opening.
      pay(conn, "op-pay", "group-81", 5000, %{"occurred_on" => "2026-11-05"})
      start_reporting(conn, "op-start")

      report = report(conn, @starts_on)

      assert report["date"] == @starts_on
      assert report["status"] == "open"

      [entry] = report["cash"]
      assert entry["property_id"] == "ams-canal"
      assert entry["opening_held_cents"] == 5000
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 5000
    end

    test "credit liability before the start is the opening liability", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      pay(conn, "op-pay", "group-81", 5000)
      # Refundable cancellation as hotel credit issues a credit lot before start.
      cancel(conn, "op-cancel", "group-81", "2026-10-04", %{"refund_method" => "hotel_credit"})

      expected_liability = ledger(conn, @starts_on)["credit_liability_cents"]
      assert expected_liability > 0

      start_reporting(conn, "op-start")
      report = report(conn, @starts_on)

      assert report["credit"]["opening_liability_cents"] == expected_liability
      assert report["credit"]["movements"] == zero_credit_movements()
      assert report["credit"]["closing_liability_cents"] == expected_liability
    end

    test "operations before the start in the same batch are opening; after are movements", %{
      conn: conn
    } do
      batch = [
        open_group_op("op-open", "group-81"),
        pay_op("op-pay-before", "group-81", 3000),
        start_op("op-start"),
        pay_op("op-pay-after", "group-81", 2000, %{"occurred_on" => "2026-11-02"})
      ]

      results = conn |> submit(batch) |> results()
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # On starts_on: opening holds the before payment only.
      report = report(conn, @starts_on)
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 3000
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 3000

      # On the next day the after payment is a received movement.
      report2 = report(conn, "2026-11-02")
      [entry2] = report2["cash"]
      assert entry2["opening_held_cents"] == 3000
      assert entry2["movements"]["received_cents"] == 2000
      assert entry2["closing_held_cents"] == 5000
    end
  end

  describe "cash movements" do
    setup %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      :ok
    end

    test "received cash posts to the group property", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-03"})

      entry = cash_entry(report(conn, "2026-11-03"), "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 4000
      assert entry["closing_held_cents"] == 4000
    end

    test "refundable cancellation posts refunded", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000)
      cancel(conn, "op-cancel", "group-81", "2026-11-05")

      entry = cash_entry(report(conn, "2026-11-05"), "ams-canal")
      assert entry["movements"]["refunded_cents"] == 4000
      assert entry["closing_held_cents"] == 0
    end

    test "non-refundable cancellation posts retained", %{conn: conn} do
      open_group(conn, "op-open-ap", "group-ap", %{"rate_plan" => "advance_purchase"})
      pay(conn, "op-pay-ap", "group-ap", 4000)
      cancel(conn, "op-cancel-ap", "group-ap", "2026-11-05")

      entry = cash_entry(report(conn, "2026-11-05"), "ams-canal")
      assert entry["movements"]["retained_cents"] == 4000
    end

    test "hotel-credit cancellation posts converted_to_credit and issued", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000)

      result =
        cancel(conn, "op-cancel", "group-81", "2026-11-05", %{"refund_method" => "hotel_credit"})

      entry = cash_entry(report(conn, "2026-11-05"), "ams-canal")
      assert entry["movements"]["converted_to_credit_cents"] == 4000
      assert entry["closing_held_cents"] == 0

      assert report(conn, "2026-11-05")["credit"]["movements"]["issued_cents"] ==
               result["credit_issued_cents"]
    end

    test "omits a property whose opening, closing, and movements are all zero", %{conn: conn} do
      open_group(conn, "op-open-2", "group-92", %{"property_id" => "rot-dam"})
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-03"})

      report = report(conn, "2026-11-03")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal"]
    end

    test "cash entries are ordered by property_id", %{conn: conn} do
      open_group(conn, "op-open-2", "group-92", %{"property_id" => "rot-dam"})
      pay(conn, "op-pay-1", "group-81", 1000, %{"occurred_on" => "2026-11-03"})
      pay(conn, "op-pay-2", "group-92", 2000, %{"occurred_on" => "2026-11-03"})

      report = report(conn, "2026-11-03")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "rot-dam"]
    end
  end

  describe "posting dates" do
    setup %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      :ok
    end

    test "an operation before starts_on posts at starts_on", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-10-15"})

      entry = cash_entry(report(conn, @starts_on), "ams-canal")
      assert entry["movements"]["received_cents"] == 4000

      # Nothing on the actual occurred_on date (before start).
      assert report_status_404(conn, "2026-10-15")["error"]["code"] == "report_not_available"
    end

    test "an operation after starts_on posts at its occurred_on", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-07"})

      # Nothing on starts_on, so the all-zero property is omitted.
      assert report(conn, @starts_on)["cash"] == []

      entry = cash_entry(report(conn, "2026-11-07"), "ams-canal")
      assert entry["movements"]["received_cents"] == 4000
    end

    test "a later submission can change an earlier open report", %{conn: conn} do
      pay(conn, "op-pay-late", "group-81", 4000, %{"occurred_on" => "2026-11-02"})

      assert cash_entry(report(conn, "2026-11-02"), "ams-canal")["movements"]["received_cents"] ==
               4000
    end
  end

  describe "reconciliation and read safety" do
    test "closing held reconciles with the ledger cash held", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      open_group(conn, "op-open-2", "group-92", %{"property_id" => "rot-dam"})
      start_reporting(conn, "op-start")

      pay(conn, "op-pay-1", "group-81", 3000, %{"occurred_on" => "2026-11-02"})
      pay(conn, "op-pay-2", "group-92", 2000, %{"occurred_on" => "2026-11-03"})
      cancel(conn, "op-cancel", "group-81", "2026-11-04")

      report = report(conn, "2026-11-04")
      total_closing = report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()
      assert total_closing == ledger(conn, "2026-11-04")["cash_held_cents"]
    end

    test "closing liability reconciles with the ledger credit liability", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000)
      cancel(conn, "op-cancel", "group-81", "2026-11-05", %{"refund_method" => "hotel_credit"})

      report = report(conn, "2026-11-05")

      assert report["credit"]["closing_liability_cents"] ==
               ledger(conn, "2026-11-05")["credit_liability_cents"]
    end

    test "reading a report repeatedly never changes it or the domain", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})

      first = report(conn, "2026-11-02")
      second = report(conn, "2026-11-02")
      third = report(conn, @starts_on)

      assert second == first
      assert ledger(conn)["cash_held_cents"] == 4000
      assert third["date"] == @starts_on
    end

    test "rejected operations leave no movement", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")

      # A payment exceeding outstanding is rejected.
      result = single_result(conn, [pay_op("op-pay", "group-81", 999_999)])
      assert result["status"] == "rejected"

      assert Repo.all(Movement) == []
    end

    test "a durable retry does not post a movement twice", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")

      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})
      # Retry the same payment.
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})

      entry = cash_entry(report(conn, "2026-11-02"), "ams-canal")
      assert entry["movements"]["received_cents"] == 4000
      assert entry["closing_held_cents"] == 4000
    end

    test "a rejected later operation keeps earlier applied movements", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")

      batch = [
        pay_op("op-pay", "group-81", 3000, %{"occurred_on" => "2026-11-02"}),
        pay_op("op-pay-bad", "group-81", 999_999, %{"occurred_on" => "2026-11-02"})
      ]

      results = conn |> submit(batch) |> results()
      assert Enum.at(results, 0)["status"] == "applied"
      assert Enum.at(results, 1)["status"] == "rejected"

      entry = cash_entry(report(conn, "2026-11-02"), "ams-canal")
      assert entry["movements"]["received_cents"] == 3000
    end
  end

  describe "deposit transfers" do
    test "transfer posts out of the source and into the destination property", %{conn: conn} do
      open_group(conn, "op-open-src", "group-src", %{"property_id" => "ams-canal"})
      open_group(conn, "op-open-dst", "group-dst", %{"property_id" => "rot-dam"})
      start_reporting(conn, "op-start")

      pay(conn, "op-pay", "group-src", 5000, %{"occurred_on" => "2026-11-02"})

      transfer = %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-03",
        "source_group_id" => "group-src",
        "destination_group_id" => "group-dst",
        "amount_cents" => 2000
      }

      assert single_result(conn, [transfer])["status"] == "applied"

      report = report(conn, "2026-11-03")
      src = cash_entry(report, "ams-canal")
      dst = cash_entry(report, "rot-dam")

      assert src["opening_held_cents"] == 5000
      assert src["movements"]["transferred_out_cents"] == 2000
      assert src["closing_held_cents"] == 3000

      assert dst["opening_held_cents"] == 0
      assert dst["movements"]["transferred_in_cents"] == 2000
      assert dst["closing_held_cents"] == 2000

      # Transferred-in equals transferred-out across all properties on the date.
      total_in =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_in_cents"]) |> Enum.sum()

      total_out =
        report["cash"] |> Enum.map(& &1["movements"]["transferred_out_cents"]) |> Enum.sum()

      assert total_in == total_out
    end

    test "a later reduction follows transferred cash to the destination property", %{conn: conn} do
      open_group(conn, "op-open-src", "group-src", %{"property_id" => "ams-canal"})
      open_group(conn, "op-open-dst", "group-dst", %{"property_id" => "rot-dam"})
      start_reporting(conn, "op-start")

      pay(conn, "op-pay", "group-src", 5000, %{"occurred_on" => "2026-11-02"})

      transfer = %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-03",
        "source_group_id" => "group-src",
        "destination_group_id" => "group-dst",
        "amount_cents" => 3000
      }

      assert single_result(conn, [transfer])["status"] == "applied"

      reduce = %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1000
      }

      assert single_result(conn, [reduce])["status"] == "applied"

      report = report(conn, "2026-11-04")
      dst = cash_entry(report, "rot-dam")
      assert dst["movements"]["reduced_cents"] == 1000
    end
  end

  describe "payment reductions" do
    test "reduction posts reduced where the cash is held", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})

      reduce = %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-03",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1500
      }

      assert single_result(conn, [reduce])["status"] == "applied"

      entry = cash_entry(report(conn, "2026-11-03"), "ams-canal")
      assert entry["opening_held_cents"] == 4000
      assert entry["movements"]["reduced_cents"] == 1500
      assert entry["closing_held_cents"] == 2500
    end
  end

  describe "chargebacks" do
    test "chargeback of held cash posts charged_back", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})

      chargeback = %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-03",
        "payment_operation_id" => "op-pay"
      }

      assert single_result(conn, [chargeback])["status"] == "applied"

      entry = cash_entry(report(conn, "2026-11-03"), "ams-canal")
      assert entry["opening_held_cents"] == 4000
      assert entry["movements"]["charged_back_cents"] == 4000
      assert entry["closing_held_cents"] == 0
    end

    test "reversing an earlier refund reports negative refunded and positive charged_back", %{
      conn: conn
    } do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})
      cancel(conn, "op-cancel", "group-81", "2026-11-05")

      chargeback = %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-06",
        "payment_operation_id" => "op-pay"
      }

      assert single_result(conn, [chargeback])["status"] == "applied"

      entry = cash_entry(report(conn, "2026-11-06"), "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["refunded_cents"] == -4000
      assert entry["movements"]["charged_back_cents"] == 4000
      assert entry["closing_held_cents"] == 0
    end
  end

  describe "credit expiry" do
    test "unused credit expires the day after expires_on with no operation that day", %{
      conn: conn
    } do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000)

      result =
        cancel(conn, "op-cancel", "group-81", "2026-11-02", %{"refund_method" => "hotel_credit"})

      issued = result["credit_issued_cents"]
      assert issued > 0

      # The lot is available through 2027-11-02 and expires on 2027-11-03.
      on_expiry_day = report(conn, "2027-11-03")
      assert on_expiry_day["credit"]["movements"]["expired_cents"] == issued
      assert on_expiry_day["credit"]["closing_liability_cents"] == 0

      # The day before, the liability is still outstanding.
      before_expiry = report(conn, "2027-11-02")
      assert before_expiry["credit"]["movements"]["expired_cents"] == 0
      assert before_expiry["credit"]["closing_liability_cents"] == issued
    end
  end

  describe "credit movements" do
    test "applying credit does not change the liability", %{conn: conn} do
      start_reporting(conn, "op-start")
      result = issue_credit(conn)
      issued = result["credit_issued_cents"]

      open_group(conn, "op-open-b", "group-b", %{"rate_plan" => "advance_purchase"})
      apply_credit(conn, "op-apply", "group-b", 3000, "2026-11-03")

      report = report(conn, "2026-11-03")
      assert report["credit"]["movements"] == zero_credit_movements()
      assert report["credit"]["closing_liability_cents"] == issued
    end

    test "non-refundable settlement of applied credit posts consumed", %{conn: conn} do
      start_reporting(conn, "op-start")
      result = issue_credit(conn)
      issued = result["credit_issued_cents"]

      open_group(conn, "op-open-b", "group-b", %{"rate_plan" => "advance_purchase"})
      apply_credit(conn, "op-apply", "group-b", 3000, "2026-11-03")
      cancel(conn, "op-cancel-b", "group-b", "2026-11-04")

      report = report(conn, "2026-11-04")
      assert report["credit"]["movements"]["consumed_cents"] == 3000
      assert report["credit"]["closing_liability_cents"] == issued - 3000

      assert report["credit"]["closing_liability_cents"] ==
               ledger(conn, "2026-11-04")["credit_liability_cents"]
    end

    test "chargeback of a converted payment posts revoked", %{conn: conn} do
      start_reporting(conn, "op-start")
      open_group(conn, "op-open-a", "group-a")
      pay(conn, "op-pay-a", "group-a", 4000)

      cancel(conn, "op-cancel-a", "group-a", "2026-11-02", %{"refund_method" => "hotel_credit"})

      chargeback = %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-03",
        "payment_operation_id" => "op-pay-a"
      }

      assert single_result(conn, [chargeback])["status"] == "applied"

      report = report(conn, "2026-11-03")
      assert report["credit"]["movements"]["revoked_cents"] > 0
      assert report["credit"]["closing_liability_cents"] == 0

      assert report["credit"]["closing_liability_cents"] ==
               ledger(conn, "2026-11-03")["credit_liability_cents"]
    end

    test "restoration absorbed by a shortfall posts absorbed", %{conn: conn} do
      start_reporting(conn, "op-start")
      open_group(conn, "op-open-a", "group-a")
      pay(conn, "op-pay-a", "group-a", 4000)

      cancel(conn, "op-cancel-a", "group-a", "2026-11-02", %{"refund_method" => "hotel_credit"})

      # Spend part of the lot so the clawback cannot be fully recovered.
      open_group(conn, "op-open-b", "group-b")
      apply_credit(conn, "op-apply", "group-b", 3000, "2026-11-03")

      chargeback = %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => "op-pay-a"
      }

      assert single_result(conn, [chargeback])["status"] == "applied"

      # Refundable cancellation returns the applied credit, which extinguishes
      # the unrecovered clawback.
      cancel(conn, "op-cancel-b", "group-b", "2026-11-05")

      report = report(conn, "2026-11-05")
      assert report["credit"]["movements"]["absorbed_cents"] == 3000
      assert report["credit"]["closing_liability_cents"] == 0

      assert report["credit"]["closing_liability_cents"] ==
               ledger(conn, "2026-11-05")["credit_liability_cents"]
    end
  end

  describe "equivalence and read order" do
    defp equivalence_scenario(submit_fun) do
      submit_fun.(open_group_op("op-open", "group-81"))
      submit_fun.(start_op("op-start"))
      submit_fun.(pay_op("op-pay-1", "group-81", 3000, %{"occurred_on" => "2026-11-02"}))
      submit_fun.(pay_op("op-pay-2", "group-81", 2000, %{"occurred_on" => "2026-11-03"}))

      submit_fun.(%{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-04",
        "group_id" => "group-81"
      })
    end

    test "a single batch produces the same report as sequential submissions", %{conn: conn} do
      equivalence_scenario(fn op ->
        assert single_result(conn, [op])["status"] == "applied"
      end)

      report = report(conn, "2026-11-04")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 5000
      assert entry["movements"]["refunded_cents"] == 5000
      assert entry["closing_held_cents"] == 0
    end

    test "the same operations in one batch produce the same report", %{conn: conn} do
      batch = [
        open_group_op("op-open", "group-81"),
        start_op("op-start"),
        pay_op("op-pay-1", "group-81", 3000, %{"occurred_on" => "2026-11-02"}),
        pay_op("op-pay-2", "group-81", 2000, %{"occurred_on" => "2026-11-03"}),
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-04",
          "group_id" => "group-81"
        }
      ]

      assert Enum.all?(conn |> submit(batch) |> results(), &(&1["status"] == "applied"))

      report = report(conn, "2026-11-04")
      [entry] = report["cash"]
      assert entry["opening_held_cents"] == 5000
      assert entry["movements"]["refunded_cents"] == 5000
      assert entry["closing_held_cents"] == 0
    end

    test "reading reports in any order returns consistent results", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})
      cancel(conn, "op-cancel", "group-81", "2026-11-03")

      later = report(conn, "2026-11-03")
      earlier = report(conn, "2026-11-02")
      later_again = report(conn, "2026-11-03")

      assert later_again == later
      assert cash_entry(earlier, "ams-canal")["closing_held_cents"] == 4000
      assert cash_entry(later, "ams-canal")["closing_held_cents"] == 0
    end
  end
end
