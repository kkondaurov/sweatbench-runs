defmodule GroupStayWeb.PeriodCloseTest do
  @moduledoc """
  The finance period close delivered with this release: the durable
  `close_finance_period` operation and its validation rules, publishing of
  every report through the cutoff, the posting-date rule for operations
  processed after a close, and the `late_adjustments` block of every
  successful daily report.
  """

  use GroupStayWeb.ConnCase, async: true

  import GroupStay.TestOperations

  @cash_movement_keys ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_movement_keys ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  # group-flex: flexible, booked 2026-12-15 (flex-14), arrival 2027-03-10,
  # one room of 20000/night for 3 nights, due 12000; refundable through
  # 2027-02-24.
  defp open_flexible_group(overrides \\ %{}) do
    open_group(%{
      "operation_id" => "open-flex",
      "group_id" => "group-flex",
      "occurred_on" => "2026-12-15",
      "arrival_on" => "2027-03-10",
      "departure_on" => "2027-03-13",
      "rooms" => [%{"room_id" => "room-e", "nightly_rate_cents" => 20_000}]
    })
    |> Map.merge(overrides)
  end

  defp open_second_group(overrides \\ %{}) do
    open_group(%{
      "operation_id" => "open-92",
      "group_id" => "group-92",
      "property_id" => "rot-dijk",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-23",
      "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
    })
    |> Map.merge(overrides)
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", batch(List.wrap(operations)))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> response(200)
  end

  defp report_data(conn, date), do: report(conn, date) |> Jason.decode!() |> Map.fetch!("data")

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp zero_cash_movements do
    Map.new(@cash_movement_keys, fn key -> {key, 0} end)
  end

  defp zero_credit_movements do
    Map.new(@credit_movement_keys, fn key -> {key, 0} end)
  end

  defp no_late_adjustments do
    %{"cash" => [], "credit" => zero_credit_movements()}
  end

  ## Closing through a date

  describe "close_finance_period" do
    test "the applied result contains exactly operation_id, status, and period_end_on", %{
      conn: conn
    } do
      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      assert [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => "2027-01-10"
               } =
                 result
             ] =
               submit(conn, close_finance_period("2027-01-10", %{"operation_id" => "close-1"}))

      assert Map.keys(result) |> Enum.sort() == ["operation_id", "period_end_on", "status"]
    end

    test "a close before reporting started is rejected with invalid_period", %{conn: conn} do
      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               submit(conn, close_finance_period("2027-01-10", %{"operation_id" => "close-1"}))

      # The rejection did not create a close: once reporting starts, the
      # first close through that same date still applies.
      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      assert [%{"status" => "applied"}] =
               submit(conn, close_finance_period("2027-01-10", %{"operation_id" => "close-2"}))
    end

    test "a missing or invalid period_end_on is rejected with invalid_period", %{conn: conn} do
      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      rejections = [
        %{"type" => "close_finance_period", "operation_id" => "close-1"},
        close_finance_period("not-a-date", %{"operation_id" => "close-2"}),
        close_finance_period("2027-02-30", %{"operation_id" => "close-3"}),
        close_finance_period("2027-01-01T00:00:00", %{"operation_id" => "close-4"})
      ]

      for op <- rejections do
        assert [%{"status" => "rejected", "code" => "invalid_period"}] = submit(conn, op)
      end

      # No close committed, so the day after starts_on is still open.
      assert report_data(conn, "2027-01-02")["status"] == "open"
    end

    test "period_end_on must be on or after starts_on; closing starts_on itself applies", %{
      conn: conn
    } do
      submit(conn, start_finance_reporting("2027-01-05", %{"operation_id" => "rep-1"}))

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               submit(conn, close_finance_period("2027-01-04", %{"operation_id" => "close-1"}))

      assert [%{"status" => "applied", "period_end_on" => "2027-01-05"}] =
               submit(conn, close_finance_period("2027-01-05", %{"operation_id" => "close-2"}))
    end

    test "a close must be strictly later than the latest successful close", %{conn: conn} do
      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      assert [%{"status" => "applied"}] =
               submit(conn, close_finance_period("2027-01-10", %{"operation_id" => "close-1"}))

      for {period_end_on, id} <-
            Enum.with_index(["2027-01-10", "2027-01-09", "2027-01-01"]) do
        assert [%{"status" => "rejected", "code" => "invalid_period"}] =
                 submit(
                   conn,
                   close_finance_period(period_end_on, %{
                     "operation_id" => "close-again-#{id}"
                   })
                 )
      end

      assert [%{"status" => "applied", "period_end_on" => "2027-01-11"}] =
               submit(conn, close_finance_period("2027-01-11", %{"operation_id" => "close-2"}))
    end

    test "replaying an applied close returns its exact stored result and conflicts otherwise", %{
      conn: conn
    } do
      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      applied = close_finance_period("2027-01-10", %{"operation_id" => "close-1"})

      assert [%{"status" => "applied"} = first] = submit(conn, applied)
      assert [^first] = submit(conn, applied)

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(
                 conn,
                 close_finance_period("2027-01-15", %{"operation_id" => "close-1"})
               )

      # A rejected close is remembered just like an applied one.
      rejected = close_finance_period("2027-01-05", %{"operation_id" => "close-2"})

      assert [%{"status" => "rejected", "code" => "invalid_period"} = rejection] =
               submit(conn, rejected)

      assert [^rejection] = submit(conn, rejected)
    end
  end

  ## Published reports

  describe "published reports" do
    test "reports through period_end_on return status closed and later reports open", %{
      conn: conn
    } do
      submit(conn, [
        open_flexible_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-03"}),
        close_finance_period("2027-01-05", %{"operation_id" => "close-1"})
      ])

      for date <- ["2027-01-01", "2027-01-03", "2027-01-05"] do
        assert report_data(conn, date)["status"] == "closed"
      end

      assert report_data(conn, "2027-01-06")["status"] == "open"

      # The published figures are the ones the day had at the close.
      entry = cash_entry(report_data(conn, "2027-01-03"), "ams-canal")
      assert entry["movements"]["received_cents"] == 6000
      assert entry["closing_held_cents"] == 6000
    end

    test "a closed report is byte-for-byte stable across later operations and later closes", %{
      conn: conn
    } do
      submit(conn, [
        open_flexible_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-03"}),
        close_finance_period("2027-01-05", %{"operation_id" => "close-1"})
      ])

      closed_before = report(conn, "2027-01-03")

      # Later operations — one late, one in the open period — and a later
      # close never move a published report.
      submit(conn, [
        open_second_group(),
        pay("group-flex", 1000, %{"operation_id" => "pay-late", "occurred_on" => "2026-12-01"}),
        pay("group-92", 2000, %{"operation_id" => "pay-open", "occurred_on" => "2027-01-07"}),
        close_finance_period("2027-01-08", %{"operation_id" => "close-2"})
      ])

      assert report(conn, "2027-01-03") == closed_before

      # Reading it repeatedly returns the same bytes.
      assert report(conn, "2027-01-03") == closed_before
      assert report(conn, "2027-01-01") == report(conn, "2027-01-01")
    end

    test "closing a period changes no group, ledger, or stored-operation result", %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-03"})
      ])

      ledger_before =
        conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

      group_before =
        conn |> get("/api/v1/groups/group-flex") |> json_response(200) |> Map.fetch!("data")

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        close_finance_period("2027-01-10", %{"operation_id" => "close-1"})
      ])

      ledger_after =
        conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

      group_after =
        conn |> get("/api/v1/groups/group-flex") |> json_response(200) |> Map.fetch!("data")

      assert ledger_after == ledger_before
      assert group_after == group_before

      assert %{"data" => %{"status" => "applied"}} =
               conn
               |> get("/api/v1/operations/pay-1")
               |> json_response(200)

      assert conn
             |> get("/api/v1/groups/group-flex")
             |> json_response(200)
             |> Map.fetch!("data")
             |> Map.fetch!("revision") == 2
    end
  end

  ## Posting after a close

  describe "posting after a close" do
    test "an operation immediately before a close posts into the closed period; an old-dated operation immediately after posts on the first open day",
         %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"})
      ])

      results =
        submit(conn, [
          pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-15"}),
          close_finance_period("2027-01-20", %{"operation_id" => "close-1"}),
          pay("group-flex", 4000, %{"operation_id" => "pay-2", "occurred_on" => "2026-12-01"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
               results

      # pay-1 committed before the close, so it posted into the period being
      # closed and its report is published with an ordinary movement.
      closed = report_data(conn, "2027-01-15")
      assert closed["status"] == "closed"

      entry = cash_entry(closed, "ams-canal")
      assert entry["movements"]["received_cents"] == 6000
      assert closed["late_adjustments"] == no_late_adjustments()

      # pay-2 committed after the close with an old date, so its complete
      # effect posted on the first open day as a late adjustment.
      first_open = report_data(conn, "2027-01-21")
      assert first_open["status"] == "open"

      entry = cash_entry(first_open, "ams-canal")
      assert entry["opening_held_cents"] == 6000
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 10_000

      assert first_open["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => zero_cash_movements() |> Map.put("received_cents", 4000)
               }
             ]

      assert first_open["late_adjustments"]["credit"] == zero_credit_movements()

      # The posting date chosen at commit time is permanent: the report keeps
      # showing the late adjustment where it posted.
      assert cash_entry(report_data(conn, "2027-01-21"), "ams-canal")["closing_held_cents"] ==
               10_000
    end

    test "an operation in the open period keeps its occurred_on and is not a late adjustment", %{
      conn: conn
    } do
      submit(conn, [
        open_flexible_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        close_finance_period("2027-01-10", %{"operation_id" => "close-1"}),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-15"})
      ])

      report = report_data(conn, "2027-01-15")
      assert report["status"] == "open"

      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 6000
      assert entry["closing_held_cents"] == 6000
      assert report["late_adjustments"] == no_late_adjustments()
    end

    test "an operation dated before starts_on, processed after a close, posts on the first open day",
         %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        close_finance_period("2027-01-10", %{"operation_id" => "close-1"}),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2026-06-01"})
      ])

      # Even before starts_on, the posting lands on the first open day.
      report = report_data(conn, "2027-01-11")
      assert report["late_adjustments"]["cash"] |> Enum.map(& &1["property_id"]) == ["ams-canal"]
      assert cash_entry(report, "ams-canal")["movements"] == zero_cash_movements()
    end

    test "a close does not move operations that already committed into the closed period", %{
      conn: conn
    } do
      # pay-1 occurs before starts_on and commits before any close: it posts
      # on starts_on like any operation before a close, and stays there.
      submit(conn, [
        open_flexible_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2026-12-01"}),
        close_finance_period("2027-01-10", %{"operation_id" => "close-1"})
      ])

      report = report_data(conn, "2027-01-01")
      assert report["status"] == "closed"
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 6000
      assert report["late_adjustments"] == no_late_adjustments()
    end
  end

  ## Late adjustments

  describe "late_adjustments" do
    test "keeps signed classifications even when their net balance effect is zero", %{
      conn: conn
    } do
      submit(conn, [
        open_flexible_group(),
        pay("group-flex", 10_000, %{"operation_id" => "pay-1", "occurred_on" => "2026-12-20"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{"operation_id" => "cancel-flex"}),
        close_finance_period("2027-01-06", %{"operation_id" => "close-1"}),
        # The chargeback is old-dated, so its complete effect — reversing the
        # earlier refund and recording charged-back cash — posts on the first
        # open day.
        charge_back("pay-1", %{"operation_id" => "cb-1", "occurred_on" => "2026-12-01"})
      ])

      report = report_data(conn, "2027-01-07")
      assert report["status"] == "open"

      entry = cash_entry(report, "ams-canal")
      assert entry["movements"] == zero_cash_movements()
      assert entry["opening_held_cents"] == 0
      assert entry["closing_held_cents"] == 0

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" =>
                   zero_cash_movements()
                   |> Map.put("refunded_cents", -10_000)
                   |> Map.put("charged_back_cents", 10_000)
               }
             ]
    end

    test "carries credit movements, ordered by property_id, omitting all-zero properties", %{
      conn: conn
    } do
      submit(conn, [
        open_flexible_group(),
        open_second_group(),
        pay("group-flex", 12_000, %{"operation_id" => "pay-1", "occurred_on" => "2026-12-20"}),
        pay("group-92", 12_000, %{"operation_id" => "pay-2", "occurred_on" => "2026-12-20"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        close_finance_period("2027-01-10", %{"operation_id" => "close-1"}),
        # Both cancellations are old-dated and refundable with hotel credit,
        # so both post their conversion and issuance on the first open day.
        cancel("group-flex", "2026-12-01", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        cancel("group-92", "2026-12-01", %{
          "operation_id" => "cancel-92",
          "refund_method" => "hotel_credit"
        })
      ])

      report = report_data(conn, "2027-01-11")
      assert report["status"] == "open"

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" =>
                   zero_cash_movements() |> Map.put("converted_to_credit_cents", 12_000)
               },
               %{
                 "property_id" => "rot-dijk",
                 "movements" =>
                   zero_cash_movements() |> Map.put("converted_to_credit_cents", 12_000)
               }
             ]

      assert report["late_adjustments"]["credit"] ==
               zero_credit_movements() |> Map.put("issued_cents", 26_400)

      # Opening and closing balances use both kinds of movements.
      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["movements"] == zero_credit_movements()
      assert report["credit"]["closing_liability_cents"] == 26_400

      # The ordinary cash movements stay empty.
      assert cash_entry(report, "ams-canal")["movements"] == zero_cash_movements()
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 0
    end

    test "opening balances include earlier late adjustments", %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        close_finance_period("2027-01-10", %{"operation_id" => "close-1"}),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2026-12-01"})
      ])

      entry = cash_entry(report_data(conn, "2027-01-12"), "ams-canal")
      assert entry["opening_held_cents"] == 6000
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 6000
    end

    test "late adjustments reconcile with the ledger", %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        pay("group-flex", 10_000, %{"operation_id" => "pay-1", "occurred_on" => "2026-12-20"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{"operation_id" => "cancel-flex"}),
        close_finance_period("2027-01-06", %{"operation_id" => "close-1"}),
        charge_back("pay-1", %{"operation_id" => "cb-1", "occurred_on" => "2026-12-01"})
      ])

      ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 10_000

      report = report_data(conn, "2027-01-05")
      assert report["status"] == "closed"
      assert cash_entry(report, "ams-canal")["movements"]["refunded_cents"] == 10_000
    end
  end
end
