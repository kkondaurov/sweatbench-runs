defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(payload))
  end

  defp submit(conn, operations) do
    conn
    |> post_batch(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    [result] = submit(conn, [operation])
    result
  end

  # Two flexible rooms, 3 nights: room-a due 9000 (15000/night), room-b due
  # 10500 (17500/night); the deposit due is 19500. Booked 2026-10-03, so the
  # flex-14 policy leaves cancellations refundable through 2026-11-26.
  defp open_operation(group_id, guest_id, property_id) do
    %{
      "operation_id" => unique_id("open"),
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  @doc false
  def unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp open_group!(conn, group_id, guest_id \\ "guest-22", property_id \\ "ams-canal") do
    result = submit_one(conn, open_operation(group_id, guest_id, property_id))
    assert result["status"] == "applied"
    result
  end

  defp pay_operation(group_id, amount_cents, occurred_on, operation_id \\ nil) do
    %{
      "operation_id" => operation_id || unique_id("pay"),
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp pay!(conn, group_id, amount_cents, occurred_on) do
    result = submit_one(conn, pay_operation(group_id, amount_cents, occurred_on))
    assert result["status"] == "applied"
    result
  end

  # Pays with a fixed operation identifier so chargebacks can address it;
  # returns the operation id.
  defp pay_named!(conn, operation_id, group_id, amount_cents, occurred_on) do
    result = submit_one(conn, pay_operation(group_id, amount_cents, occurred_on, operation_id))
    assert result["status"] == "applied"
    operation_id
  end

  defp cancel_operation(group_id, occurred_on, refund_method) do
    %{
      "operation_id" => unique_id("cancel"),
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => refund_method
    }
  end

  defp cancel!(conn, group_id, occurred_on, refund_method \\ "cash") do
    result = submit_one(conn, cancel_operation(group_id, occurred_on, refund_method))
    assert result["status"] == "applied"
    result
  end

  defp start_reporting(conn, starts_on, operation_id \\ unique_id("start")) do
    submit_one(conn, %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    })
  end

  defp start_reporting!(conn, starts_on) do
    result = start_reporting(conn, starts_on)
    assert result["status"] == "applied"
    result
  end

  defp close_period(conn, period_end_on, operation_id \\ unique_id("close")) do
    submit_one(conn, %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "period_end_on" => period_end_on
    })
  end

  defp close_period!(conn, period_end_on) do
    result = close_period(conn, period_end_on)
    assert result["status"] == "applied"
    result
  end

  defp report!(conn, date) do
    conn
    |> get(~p"/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp report_body!(conn, date) do
    conn |> get(~p"/api/v1/finance/daily-report?date=#{date}") |> response(200)
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp late_entry(report, property_id) do
    Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))
  end

  defp zero_movements(fields) do
    Map.new(fields, &{&1, 0})
  end

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  describe "close_finance_period" do
    test "the applied result contains exactly operation_id, status, and period_end_on", %{
      conn: conn
    } do
      start_reporting!(conn, "2026-12-01")

      result = close_period(conn, "2026-12-31", "close-1")

      assert result == %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => "2026-12-31"
             }
    end

    test "rejected with invalid_period before finance reporting has started", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "invalid_period"} =
               close_period(conn, "2026-12-31")
    end

    test "a missing or malformed period_end_on is invalid_period", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               submit_one(conn, %{
                 "operation_id" => "close-missing",
                 "type" => "close_finance_period"
               })

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               close_period(conn, "not-a-date")
    end

    test "period_end_on must be on or after starts_on", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               close_period(conn, "2026-11-30")

      assert close_period(conn, "2026-12-01")["status"] == "applied"
    end

    test "a different operation attempting the same or an earlier cutoff is rejected", %{
      conn: conn
    } do
      start_reporting!(conn, "2026-12-01")
      close_period!(conn, "2026-12-31")

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               close_period(conn, "2026-12-31")

      assert %{"status" => "rejected", "code" => "invalid_period"} =
               close_period(conn, "2026-12-15")

      assert close_period(conn, "2027-01-15")["status"] == "applied"
    end

    test "replaying an applied close returns its exact stored result", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")
      first = close_period(conn, "2026-12-31", "close-original")
      assert first["status"] == "applied"

      assert close_period(conn, "2026-12-31", "close-original") == first

      # The same identifier with a different cutoff is a different payload.
      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               close_period(conn, "2027-01-31", "close-original")
    end

    test "a rejected close is remembered and replays its rejection", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")
      first = close_period(conn, "2026-11-30", "close-rejected")
      assert first["status"] == "rejected"

      assert close_period(conn, "2026-11-30", "close-rejected") == first
    end

    test "operations earlier in the same batch are visible to the close", %{conn: conn} do
      [start_result, close_result] =
        submit(conn, [
          %{
            "operation_id" => "start-1",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-12-01"
          },
          %{
            "operation_id" => "close-1",
            "type" => "close_finance_period",
            "period_end_on" => "2026-12-31"
          }
        ])

      assert start_result["status"] == "applied"
      assert close_result["status"] == "applied"

      # A close ordered before the start in the same batch is rejected.
      [close_result, start_result] =
        submit(conn, [
          %{
            "operation_id" => "close-early",
            "type" => "close_finance_period",
            "period_end_on" => "2026-12-31"
          },
          %{
            "operation_id" => "start-2",
            "type" => "start_finance_reporting",
            "starts_on" => "2026-12-02"
          }
        ])

      assert close_result["status"] == "rejected"
      assert close_result["code"] == "invalid_period"
      assert start_result["status"] == "rejected"
    end
  end

  describe "closed reports" do
    test "reports through the cutoff return closed; later reports return open", %{conn: conn} do
      start_reporting!(conn, "2026-12-01")
      close_period!(conn, "2026-12-31")

      assert report!(conn, "2026-12-01")["status"] == "closed"
      assert report!(conn, "2026-12-31")["status"] == "closed"
      assert report!(conn, "2027-01-01")["status"] == "open"
    end

    test "a closed report is byte-for-byte stable across later operations and later closes", %{
      conn: conn
    } do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")
      pay!(conn, "group-81", 10000, "2026-12-05")
      close_period!(conn, "2026-12-31")

      before_close_body = report_body!(conn, "2026-12-05")
      before_open_body = report_body!(conn, "2027-01-01")

      # Later operations, one of them old-dated, and a later close.
      pay!(conn, "group-81", 4000, "2026-12-10")
      pay!(conn, "group-81", 1000, "2027-01-02")
      close_period!(conn, "2027-01-31")

      assert report_body!(conn, "2026-12-05") == before_close_body

      # The old-dated payment posted on the first open day after the close,
      # so the once-open report changed until it was closed in turn.
      refute report_body!(conn, "2027-01-01") == before_open_body

      closed_twice_body = report_body!(conn, "2027-01-01")
      pay!(conn, "group-81", 500, "2027-01-03")
      assert report_body!(conn, "2027-01-01") == closed_twice_body
    end

    test "in one batch, an operation before the close posts into the period and one after it posts on the first open day",
         %{conn: conn} do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")

      pay!(conn, "group-81", 3000, "2026-12-05")

      [in_pay_result, close_result, old_pay_result] =
        submit(conn, [
          pay_operation("group-81", 2000, "2026-12-20", "pay-in-period"),
          %{
            "operation_id" => "close-1",
            "type" => "close_finance_period",
            "period_end_on" => "2026-12-31"
          },
          pay_operation("group-81", 1000, "2026-12-21", "pay-after-close")
        ])

      assert in_pay_result["status"] == "applied"
      assert close_result["status"] == "applied"
      assert old_pay_result["status"] == "applied"

      # The first payment posts into the period being closed.
      closed = report!(conn, "2026-12-20")
      assert closed["status"] == "closed"
      assert cash_entry(closed, "ams-canal")["movements"]["received_cents"] == 2000
      assert closed["late_adjustments"]["cash"] == []

      # The old-dated operation after the close posts on the first open day.
      open_report = report!(conn, "2027-01-01")
      assert open_report["status"] == "open"
      assert cash_entry(open_report, "ams-canal")["movements"]["received_cents"] == 0
      assert late_entry(open_report, "ams-canal")["movements"]["received_cents"] == 1000
    end

    test "an operation whose occurred_on already lies in the open period keeps that date", %{
      conn: conn
    } do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")
      close_period!(conn, "2026-12-31")

      pay!(conn, "group-81", 1000, "2027-01-01")

      report = report!(conn, "2027-01-01")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 1000
      assert report["late_adjustments"]["cash"] == []
      assert report["late_adjustments"]["credit"] == zero_movements(@credit_fields)
    end

    test "a durable retry of an operation posted into a closed period changes nothing", %{
      conn: conn
    } do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")

      operation = pay_operation("group-81", 3000, "2026-12-05", "pay-original")
      first = submit_one(conn, operation)
      assert first["status"] == "applied"

      close_period!(conn, "2026-12-31")
      body = report_body!(conn, "2026-12-05")

      # The exact retry returns the stored result without re-reading state,
      # and the closed report does not gain a second movement.
      assert submit_one(conn, operation) == first
      assert report_body!(conn, "2026-12-05") == body
    end
  end

  describe "late adjustments" do
    test "an old-dated payment posts on the first open day as a late adjustment only", %{
      conn: conn
    } do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")
      pay!(conn, "group-81", 2000, "2026-12-05")
      close_period!(conn, "2026-12-31")

      pay!(conn, "group-81", 4000, "2026-12-10")

      report = report!(conn, "2027-01-01")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"] == zero_movements(@cash_fields)
      assert entry["opening_held_cents"] == 2000
      assert entry["closing_held_cents"] == 6000

      late = late_entry(report, "ams-canal")
      assert late["movements"]["received_cents"] == 4000

      # The closed day the payment occurred on shows nothing.
      closed = report!(conn, "2026-12-10")
      assert cash_entry(closed, "ams-canal")["movements"] == zero_movements(@cash_fields)
      assert closed["late_adjustments"]["cash"] == []
    end

    test "signed classifications survive a zero-net late adjustment", %{conn: conn} do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")
      pay1 = pay_named!(conn, "pay-1", "group-81", 10000, "2026-12-05")
      cancel!(conn, "group-81", "2026-11-26")
      close_period!(conn, "2026-12-31")

      submit_one(conn, %{
        "operation_id" => "chargeback-1",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-12-10",
        "payment_operation_id" => pay1
      })

      report = report!(conn, "2027-01-01")
      late = late_entry(report, "ams-canal")
      assert late["movements"]["refunded_cents"] == -10000
      assert late["movements"]["charged_back_cents"] == 10000

      # A zero-net late adjustment still lists the property.
      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"] == zero_movements(@cash_fields)
      assert entry["closing_held_cents"] == 0
    end

    test "late credit movements report in the credit object", %{conn: conn} do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")
      pay!(conn, "group-81", 10000, "2026-12-05")
      close_period!(conn, "2026-12-31")

      cancel!(conn, "group-81", "2026-11-26", "hotel_credit")

      report = report!(conn, "2027-01-01")
      assert report["credit"]["movements"] == zero_movements(@credit_fields)
      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 11000

      assert late_entry(report, "ams-canal")["movements"]["converted_to_credit_cents"] == 10000
      assert report["late_adjustments"]["credit"]["issued_cents"] == 11000
    end

    test "the late cash array is ordered by property and omits all-zero properties", %{conn: conn} do
      open_group!(conn, "group-b", "guest-22", "aaa-first")
      open_group!(conn, "group-a", "guest-22", "zzz-last")
      start_reporting!(conn, "2026-12-01")
      pay!(conn, "group-b", 1000, "2026-12-05")
      pay!(conn, "group-a", 1000, "2026-12-05")
      close_period!(conn, "2026-12-31")

      # An ordinary payment into group-b and a late adjustment into group-a.
      pay!(conn, "group-b", 500, "2027-01-01")
      pay!(conn, "group-a", 700, "2026-12-10")

      report = report!(conn, "2027-01-01")
      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) == ["zzz-last"]
      assert late_entry(report, "zzz-last")["movements"]["received_cents"] == 700
      assert Enum.map(report["cash"], & &1["property_id"]) == ["aaa-first", "zzz-last"]
    end

    test "late balances reconcile to the ledger view", %{conn: conn} do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")
      close_period!(conn, "2026-12-31")
      pay!(conn, "group-81", 4000, "2026-12-10")

      report = report!(conn, "2027-01-01")

      ledger =
        conn
        |> get(~p"/api/v1/ledger?on=2027-01-01")
        |> json_response(200)
        |> Map.fetch!("data")

      closing_held = Enum.sum(for entry <- report["cash"], do: entry["closing_held_cents"])
      assert closing_held == ledger["cash_held_cents"]
      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    end
  end

  describe "existing views" do
    test "a close changes no group, ledger, or payment-statement values", %{conn: conn} do
      open_group!(conn, "group-81")
      pay1 = pay_named!(conn, "pay-1", "group-81", 10000, "2026-11-15")
      start_reporting!(conn, "2026-12-01")

      group_before =
        conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

      ledger_before =
        conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

      payment_before =
        conn |> get(~p"/api/v1/payments/#{pay1}") |> json_response(200) |> Map.fetch!("data")

      close_period!(conn, "2026-12-31")

      assert conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data") ==
               group_before

      assert conn |> get(~p"/api/v1/ledger") |> json_response(200) |> Map.fetch!("data") ==
               ledger_before

      assert conn |> get(~p"/api/v1/payments/#{pay1}") |> json_response(200) |> Map.fetch!("data") ==
               payment_before
    end

    test "a close does not address a group and leaves group revisions untouched", %{conn: conn} do
      open_group!(conn, "group-81")
      start_reporting!(conn, "2026-12-01")

      group_before =
        conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

      assert close_period(conn, "2026-12-31")["status"] == "applied"

      assert conn |> get(~p"/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data") ==
               group_before

      assert group_before["revision"] == 1
    end
  end
end
