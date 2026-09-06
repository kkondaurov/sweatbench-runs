defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Finance.{ClosedReport, Movement}
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

  defp open_group_op(op_id, group_id, overrides) do
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

  defp pay_op(op_id, group_id, amount_cents, overrides) do
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

  defp pay(conn, op_id, group_id, amount_cents, overrides) do
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

  defp start_reporting(conn, op_id) do
    result = single_result(conn, [start_op(op_id)])
    assert result["status"] == "applied"
    result
  end

  defp close_op(op_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "close_finance_period",
        "period_end_on" => "2026-11-10"
      },
      overrides
    )
  end

  defp close_period(conn, op_id, overrides \\ %{}) do
    result = single_result(conn, [close_op(op_id, overrides)])
    assert result["status"] == "applied"
    result
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

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp raw_report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
  end

  defp raw_report_body(conn, date) do
    conn = get(conn, "/api/v1/finance/daily-report?date=#{date}")
    assert conn.status == 200
    conn.resp_body
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp late_cash_entry(report, property_id) do
    Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))
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

  describe "close_finance_period operation" do
    test "applies and returns exactly operation_id, status, period_end_on", %{conn: conn} do
      start_reporting(conn, "op-start")
      result = single_result(conn, [close_op("op-close")])

      assert result == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-11-10"
             }
    end

    test "does not require a group and ignores revision", %{conn: conn} do
      start_reporting(conn, "op-start")
      result = single_result(conn, [close_op("op-close", %{"expected_revision" => 99})])
      assert result["status"] == "applied"
    end

    test "before reporting has started it is rejected with invalid_period", %{conn: conn} do
      result = single_result(conn, [close_op("op-close")])

      assert result == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "a cutoff before starts_on is rejected with invalid_period", %{conn: conn} do
      start_reporting(conn, "op-start")
      result = single_result(conn, [close_op("op-close", %{"period_end_on" => "2026-10-31"})])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_period"
    end

    test "a cutoff equal to starts_on applies", %{conn: conn} do
      start_reporting(conn, "op-start")
      result = single_result(conn, [close_op("op-close", %{"period_end_on" => @starts_on})])

      assert result["status"] == "applied"
      assert result["period_end_on"] == @starts_on
      assert report(conn, @starts_on)["status"] == "closed"
    end

    test "an invalid period_end_on is rejected with invalid_period", %{conn: conn} do
      start_reporting(conn, "op-start")

      for value <- ["not-a-date", "2026-13-40", 20_261_110, nil] do
        op = Map.put(close_op("op-close-#{inspect(value)}"), "period_end_on", value)
        result = single_result(conn, [op])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_period"
      end
    end

    test "a missing period_end_on is rejected with invalid_period", %{conn: conn} do
      start_reporting(conn, "op-start")

      op = %{"operation_id" => "op-close", "type" => "close_finance_period"}
      result = single_result(conn, [op])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_period"
    end

    test "a missing operation_id is rejected with invalid_operation", %{conn: conn} do
      start_reporting(conn, "op-start")

      op = %{"type" => "close_finance_period", "period_end_on" => "2026-11-10"}
      result = single_result(conn, [op])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
    end

    test "a rejected close leaves all reports open", %{conn: conn} do
      start_reporting(conn, "op-start")
      _ = single_result(conn, [close_op("op-close", %{"period_end_on" => "2026-10-31"})])

      assert report(conn, "2026-11-02")["status"] == "open"
    end
  end

  describe "durable replay and conflict" do
    test "replaying an applied close returns its exact stored result", %{conn: conn} do
      start_reporting(conn, "op-start")
      first = single_result(conn, [close_op("op-close")])
      published = Repo.aggregate(ClosedReport, :count)
      closes = Repo.aggregate(GroupStay.Finance.PeriodClose, :count)

      retry = single_result(conn, [close_op("op-close")])

      assert retry == first
      assert retry["status"] == "applied"
      assert Repo.aggregate(ClosedReport, :count) == published
      assert Repo.aggregate(GroupStay.Finance.PeriodClose, :count) == closes
    end

    test "a different operation attempting the same cutoff is rejected", %{conn: conn} do
      start_reporting(conn, "op-start")
      close_period(conn, "op-close-1")
      result = single_result(conn, [close_op("op-close-2")])

      assert result == %{
               "operation_id" => "op-close-2",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "a different operation attempting an earlier cutoff is rejected", %{conn: conn} do
      start_reporting(conn, "op-start")
      close_period(conn, "op-close-1")

      result = single_result(conn, [close_op("op-close-2", %{"period_end_on" => "2026-11-05"})])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_period"
    end

    test "a later cutoff applies", %{conn: conn} do
      start_reporting(conn, "op-start")
      close_period(conn, "op-close-1")

      result = single_result(conn, [close_op("op-close-2", %{"period_end_on" => "2026-11-15"})])

      assert result["status"] == "applied"
      assert result["period_end_on"] == "2026-11-15"
    end

    test "reusing the identifier with a different payload conflicts", %{conn: conn} do
      start_reporting(conn, "op-start")
      close_period(conn, "op-close")

      result = single_result(conn, [close_op("op-close", %{"period_end_on" => "2026-11-20"})])

      assert result["status"] == "rejected"
      assert result["code"] == "operation_id_conflict"
    end

    test "a rejected close is remembered on retry", %{conn: conn} do
      first = single_result(conn, [close_op("op-close")])
      assert first["status"] == "rejected"
      assert first["code"] == "invalid_period"

      # Reporting starts later; the stored rejection still stands.
      start_reporting(conn, "op-start")
      retry = single_result(conn, [close_op("op-close")])
      assert retry == first
    end
  end

  describe "published days" do
    setup %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      :ok
    end

    test "reports through the cutoff are closed; later reports are open", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})
      close_period(conn, "op-close")

      assert report(conn, @starts_on)["status"] == "closed"
      assert report(conn, "2026-11-05")["status"] == "closed"
      assert report(conn, "2026-11-10")["status"] == "closed"
      assert report(conn, "2026-11-11")["status"] == "open"
    end

    test "a closed day keeps its exact data across later operations", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})
      close_period(conn, "op-close")

      before = raw_report_body(conn, "2026-11-05")

      pay(conn, "op-pay-2", "group-81", 2000, %{"occurred_on" => "2026-11-05"})
      cancel(conn, "op-cancel", "group-81", "2026-11-06")

      assert raw_report_body(conn, "2026-11-05") == before

      # The old-dated payment moved to the first open day; the closed day is untouched.
      report = report(conn, "2026-11-11")
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 2000
    end

    test "a closed day keeps its exact data across later closes", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})
      close_period(conn, "op-close-1")
      before = raw_report_body(conn, "2026-11-05")

      pay(conn, "op-pay-2", "group-81", 2000, %{"occurred_on" => "2026-11-12"})
      close_period(conn, "op-close-2", %{"period_end_on" => "2026-11-15"})

      assert raw_report_body(conn, "2026-11-05") == before
      assert report(conn, "2026-11-12")["status"] == "closed"
      assert report(conn, "2026-11-16")["status"] == "open"
    end

    test "the stored report is byte-for-byte identical on repeated reads", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})
      close_period(conn, "op-close")

      first = raw_report_body(conn, "2026-11-05")
      second = raw_report_body(conn, "2026-11-05")
      assert first == second
      assert raw_report(conn, "2026-11-05")["data"]["status"] == "closed"
    end

    test "an open day still changes with later submissions", %{conn: conn} do
      close_period(conn, "op-close")

      assert report(conn, "2026-11-12")["cash"] == []

      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-12"})

      entry = cash_entry(report(conn, "2026-11-12"), "ams-canal")
      assert entry["movements"]["received_cents"] == 4000
    end

    test "closing an empty period publishes zero reports", %{conn: conn} do
      close_period(conn, "op-close")

      report = report(conn, "2026-11-03")
      assert report["status"] == "closed"
      assert report["cash"] == []
      assert report["credit"]["movements"] == zero_credit_movements()
      assert report["late_adjustments"]["cash"] == []
      assert report["late_adjustments"]["credit"] == zero_credit_movements()
    end
  end

  describe "posting after a close" do
    setup %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      close_period(conn, "op-close")
      :ok
    end

    test "an old-dated operation posts on the first open day", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      # Nothing posts into the closed period.
      assert report(conn, "2026-11-05")["cash"] == []
      assert report(conn, "2026-11-10")["cash"] == []

      report = report(conn, "2026-11-11")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 4000

      late = late_cash_entry(report, "ams-canal")
      assert late["movements"]["received_cents"] == 4000
    end

    test "an operation already in the open period keeps its date", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-15"})

      assert report(conn, "2026-11-11")["cash"] == []

      entry = cash_entry(report(conn, "2026-11-15"), "ams-canal")
      assert entry["movements"]["received_cents"] == 4000
    end

    test "an operation without occurred_on posts on the first open day", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      reduce = %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1500
      }

      assert single_result(conn, [reduce])["status"] == "applied"

      report = report(conn, "2026-11-11")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 2500

      late = late_cash_entry(report, "ams-canal")
      assert late["movements"]["received_cents"] == 4000
      assert late["movements"]["reduced_cents"] == 1500
    end

    test "an operation keeps its posting date across a later close", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      close_period(conn, "op-close-2", %{"period_end_on" => "2026-11-20"})

      # The movement stayed on the first open day of the first close; the
      # second close published it there.
      report = report(conn, "2026-11-11")
      assert report["status"] == "closed"

      entry = cash_entry(report, "ams-canal")
      assert entry["closing_held_cents"] == 4000
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 4000
    end

    test "operations earlier in the same batch are visible around a close", %{conn: conn} do
      batch = [
        pay_op("op-pay-before", "group-81", 3000, %{"occurred_on" => "2026-11-12"}),
        close_op("op-close-batch", %{"period_end_on" => "2026-11-15"}),
        pay_op("op-pay-after", "group-81", 2000, %{"occurred_on" => "2026-11-05"})
      ]

      results = conn |> submit(batch) |> results()
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The operation before the close posted into the period being closed.
      closed = report(conn, "2026-11-12")
      assert closed["status"] == "closed"
      assert cash_entry(closed, "ams-canal")["movements"]["received_cents"] == 3000

      # The old-dated operation after the close posted on the first open day.
      open_day = report(conn, "2026-11-16")
      assert open_day["status"] == "open"

      entry = cash_entry(open_day, "ams-canal")
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 5000
      assert late_cash_entry(open_day, "ams-canal")["movements"]["received_cents"] == 2000
    end

    test "the posting rule changes only finance reporting", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      # Group and ledger keep their current-state meanings.
      group =
        conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

      assert group["deposit_paid_cents"] == 4000
      assert ledger(conn)["cash_held_cents"] == 4000

      # The stored operation result is unaffected.
      stored =
        conn
        |> get("/api/v1/operations/op-pay")
        |> json_response(200)
        |> Map.fetch!("data")

      assert stored["status"] == "applied"
      assert stored["amount_cents"] == 4000
    end

    test "closing held still reconciles with the ledger after a close", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      report = report(conn, "2026-11-11")
      total_closing = report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()
      assert total_closing == ledger(conn)["cash_held_cents"]
    end
  end

  describe "late adjustments" do
    setup %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      :ok
    end

    test "every successful report carries the late_adjustments shape", %{conn: conn} do
      report = report(conn, @starts_on)
      assert report["late_adjustments"]["cash"] == []
      assert report["late_adjustments"]["credit"] == zero_credit_movements()

      close_period(conn, "op-close")

      closed = report(conn, @starts_on)
      assert closed["late_adjustments"]["cash"] == []
      assert closed["late_adjustments"]["credit"] == zero_credit_movements()

      open_day = report(conn, "2026-11-11")
      assert open_day["late_adjustments"]["cash"] == []
      assert open_day["late_adjustments"]["credit"] == zero_credit_movements()
    end

    test "a late movement is reported in late_adjustments, not in movements", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})
      close_period(conn, "op-close")
      cancel(conn, "op-cancel", "group-81", "2026-11-05")

      report = report(conn, "2026-11-11")
      entry = cash_entry(report, "ams-canal")

      assert entry["opening_held_cents"] == 4000
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 0

      late = late_cash_entry(report, "ams-canal")
      assert late["movements"] == %{zero_cash_movements() | "refunded_cents" => 4000}
    end

    test "a zero-net correction stays visible in late_adjustments", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 100, %{"occurred_on" => "2026-11-02"})
      cancel(conn, "op-cancel", "group-81", "2026-11-03")
      close_period(conn, "op-close")

      chargeback = %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => "op-pay"
      }

      assert single_result(conn, [chargeback])["status"] == "applied"

      report = report(conn, "2026-11-11")

      # The property's opening, closing, and ordinary movements are all zero,
      # so it drops out of the cash array, but the signed late adjustment
      # remains visible.
      assert cash_entry(report, "ams-canal") == nil

      late = late_cash_entry(report, "ams-canal")

      assert late["movements"] ==
               %{zero_cash_movements() | "refunded_cents" => -100, "charged_back_cents" => 100}
    end

    test "late cash entries are ordered by property_id and omit all-zero properties", %{
      conn: conn
    } do
      open_group(conn, "op-open-2", "group-92", %{"property_id" => "rot-dam"})
      open_group(conn, "op-open-3", "group-93", %{"property_id" => "ams-canal"})

      pay(conn, "op-pay-1", "group-81", 1000, %{"occurred_on" => "2026-11-02"})
      pay(conn, "op-pay-2", "group-92", 2000, %{"occurred_on" => "2026-11-02"})

      close_period(conn, "op-close")

      pay(conn, "op-pay-3", "group-92", 3000, %{"occurred_on" => "2026-11-02"})
      pay(conn, "op-pay-4", "group-81", 4000, %{"occurred_on" => "2026-11-02"})

      report = report(conn, "2026-11-11")

      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "rot-dam"]
    end

    test "the day's total movement is ordinary plus late", %{conn: conn} do
      pay(conn, "op-pay-1", "group-81", 1000, %{"occurred_on" => "2026-11-11"})
      close_period(conn, "op-close")
      pay(conn, "op-pay-2", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      report = report(conn, "2026-11-11")
      entry = cash_entry(report, "ams-canal")
      late = late_cash_entry(report, "ams-canal")

      total_received =
        entry["movements"]["received_cents"] + late["movements"]["received_cents"]

      assert total_received == 5000
      assert entry["opening_held_cents"] == 0
      assert entry["closing_held_cents"] == 5000
    end

    test "late credit movements are reported in late_adjustments", %{conn: conn} do
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})
      close_period(conn, "op-close")

      result =
        cancel(conn, "op-cancel", "group-81", "2026-11-05", %{"refund_method" => "hotel_credit"})

      issued = result["credit_issued_cents"]
      assert issued > 0

      report = report(conn, "2026-11-11")
      credit = report["credit"]

      assert credit["movements"] == zero_credit_movements()
      assert report["late_adjustments"]["credit"]["issued_cents"] == issued
      assert credit["opening_liability_cents"] == 0
      assert credit["closing_liability_cents"] == issued

      assert credit["closing_liability_cents"] == ledger(conn)["credit_liability_cents"]
    end

    test "late movements are stored marked late", %{conn: conn} do
      close_period(conn, "op-close")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      movements = Repo.all(Movement)
      assert length(movements) == 1
      assert hd(movements).late
      assert hd(movements).posting_date == ~D[2026-11-11]
    end

    test "a durable retry does not post a late movement twice", %{conn: conn} do
      close_period(conn, "op-close")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-05"})

      report = report(conn, "2026-11-11")
      late = late_cash_entry(report, "ams-canal")
      assert late["movements"]["received_cents"] == 4000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 4000
    end

    test "a late transfer stays balanced across properties", %{conn: conn} do
      open_group(conn, "op-open-2", "group-92", %{"property_id" => "rot-dam"})
      pay(conn, "op-pay", "group-81", 5000, %{"occurred_on" => "2026-11-02"})
      close_period(conn, "op-close")

      transfer = %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 2000
      }

      assert single_result(conn, [transfer])["status"] == "applied"

      report = report(conn, "2026-11-11")

      src = late_cash_entry(report, "ams-canal")
      dst = late_cash_entry(report, "rot-dam")
      assert src["movements"]["transferred_out_cents"] == 2000
      assert dst["movements"]["transferred_in_cents"] == 2000

      total_in =
        report["late_adjustments"]["cash"]
        |> Enum.map(& &1["movements"]["transferred_in_cents"])
        |> Enum.sum()

      total_out =
        report["late_adjustments"]["cash"]
        |> Enum.map(& &1["movements"]["transferred_out_cents"])
        |> Enum.sum()

      assert total_in == total_out

      # Balances include the late movements.
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 3000
      assert cash_entry(report, "rot-dam")["closing_held_cents"] == 2000
    end
  end

  describe "credit expiry across a close" do
    test "a natural expiry inside a closed period stays stable", %{conn: conn} do
      open_group(conn, "op-open", "group-81")
      start_reporting(conn, "op-start")
      pay(conn, "op-pay", "group-81", 4000, %{"occurred_on" => "2026-11-02"})

      result =
        cancel(conn, "op-cancel", "group-81", "2026-11-03", %{"refund_method" => "hotel_credit"})

      issued = result["credit_issued_cents"]

      # The lot expires on 2027-11-03; the natural expiry posts 2027-11-04.
      # Closing through that day publishes it.
      close_period(conn, "op-close", %{"period_end_on" => "2027-11-04"})

      expiry_day = report(conn, "2027-11-04")
      assert expiry_day["status"] == "closed"
      assert expiry_day["credit"]["movements"]["expired_cents"] == issued
      assert expiry_day["credit"]["closing_liability_cents"] == 0

      before = raw_report(conn, "2027-11-04")

      # A later old-dated operation cannot move the published day.
      open_group(conn, "op-open-2", "group-92")
      pay(conn, "op-pay-2", "group-92", 2000, %{"occurred_on" => "2026-11-05"})

      assert raw_report(conn, "2027-11-04") == before
    end
  end
end
