defmodule GroupStayWeb.DailyFinanceReportTest do
  @moduledoc """
  The daily finance report delivered with this release: the durable
  `start_finance_reporting` inception point and its opening position, the
  per-property cash section, the company-wide credit section including the
  autonomous expiry of unused credit, the posting-date rule, and
  reconciliation with the existing current views.
  """

  use GroupStayWeb.ConnCase, async: true

  import GroupStay.TestOperations

  @cash_movement_keys ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_movement_keys ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  # group-81 defaults: flexible, booked 2026-10-03, arrival 2026-12-10 with
  # rooms room-a (15000/night) and room-b (17500/night) for 3 nights, due
  # 19500; refundable through 2026-11-26.
  #
  # group-flex: flexible, booked 2026-12-15 (still flex-14), arrival
  # 2027-03-10 with one room of 20000/night for 3 nights, due 12000;
  # refundable through 2027-02-24. Its window reaches into the reporting
  # era, so cancellations processed after reporting starts can be
  # refundable on their natural occurred_on.
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

  # group-late: flexible, booked 2027-01-02 (flex-30), arrival 2029-06-10,
  # due 12000; refundable through 2029-05-11, so a refundable cancellation
  # can occur even after a credit lot issued in early 2027 has expired.
  defp open_late_group(overrides \\ %{}) do
    open_group(%{
      "operation_id" => "open-late",
      "group_id" => "group-late",
      "property_id" => "utrecht-stad",
      "occurred_on" => "2027-01-02",
      "arrival_on" => "2029-06-10",
      "departure_on" => "2029-06-13",
      "rooms" => [%{"room_id" => "room-f", "nightly_rate_cents" => 20_000}]
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

  defp report_data(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp report_error(conn, date, status) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(status)
    |> Map.fetch!("error")
    |> Map.fetch!("code")
  end

  defp ledger_data(conn, query \\ "") do
    conn |> get("/api/v1/ledger#{query}") |> json_response(200) |> Map.fetch!("data")
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp funded_group(conn) do
    submit(conn, [open_flexible_group(), pay("group-flex", 10_000, %{"operation_id" => "pay-1"})])
    :ok
  end

  ## Starting finance reporting

  describe "start_finance_reporting" do
    test "the first applied start operation returns exactly its three fields", %{conn: conn} do
      assert [%{"operation_id" => "rep-1", "status" => "applied", "starts_on" => "2027-01-01"}] =
               submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      result = report_data(conn, "2027-01-01")
      assert %{"date" => "2027-01-01", "status" => "open"} = result
    end

    test "a different start operation is rejected once reporting has started", %{conn: conn} do
      assert [%{"status" => "applied"} = first] =
               submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      assert [%{"status" => "rejected", "code" => "reporting_already_started"}] =
               submit(conn, start_finance_reporting("2027-02-01", %{"operation_id" => "rep-2"}))

      # The original operation's exact retry replays its stored result, while
      # the same identifier with a different payload is a conflict.
      assert [replay] =
               submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      assert replay == first

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(conn, start_finance_reporting("2027-02-01", %{"operation_id" => "rep-1"}))
    end

    test "a missing or invalid starts_on is rejected with invalid_reporting_date", %{conn: conn} do
      rejections = [
        %{"type" => "start_finance_reporting", "operation_id" => "rep-1"},
        start_finance_reporting("not-a-date", %{"operation_id" => "rep-2"}),
        start_finance_reporting("2027-02-30", %{"operation_id" => "rep-3"}),
        start_finance_reporting("2027-01-01T00:00:00", %{"operation_id" => "rep-4"})
      ]

      for op <- rejections do
        assert [%{"status" => "rejected", "code" => "invalid_reporting_date"}] = submit(conn, op)
      end

      # None of them enabled reporting.
      assert report_error(conn, "2027-01-01", 404) == "report_not_available"
    end

    test "operations before the start in the same batch form the opening position; operations after it are movements",
         %{conn: conn} do
      results =
        submit(conn, [
          open_flexible_group(),
          pay("group-flex", 5000, %{"occurred_on" => "2026-12-20"}),
          start_finance_reporting("2027-01-05", %{"operation_id" => "rep-1"}),
          pay("group-flex", 3000, %{"operation_id" => "pay-2", "occurred_on" => "2026-12-20"})
        ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The later payment occurred before starts_on, so it posts on
      # starts_on; the earlier payment is already part of the opening.
      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => %{"received_cents" => 3000} = movements,
                 "closing_held_cents" => 8000
               }
             ] = report_data(conn, "2027-01-05")["cash"]

      assert Map.keys(movements) |> Enum.sort() == Enum.sort(@cash_movement_keys)
      assert movements["transferred_in_cents"] == 0
      assert movements["transferred_out_cents"] == 0
      assert movements["refunded_cents"] == 0
      assert movements["retained_cents"] == 0
      assert movements["converted_to_credit_cents"] == 0
      assert movements["reduced_cents"] == 0
      assert movements["charged_back_cents"] == 0

      credit = report_data(conn, "2027-01-05")["credit"]
      assert credit["opening_liability_cents"] == 0
      assert credit["movements"] |> Map.values() |> Enum.all?(&(&1 == 0))
      assert credit["closing_liability_cents"] == 0
    end
  end

  ## Reading one day

  describe "reading one day" do
    test "the report is unavailable before reporting started and before starts_on", %{conn: conn} do
      assert report_error(conn, "2027-01-01", 404) == "report_not_available"

      submit(conn, start_finance_reporting("2027-01-10", %{"operation_id" => "rep-1"}))

      assert report_error(conn, "2027-01-09", 404) == "report_not_available"
      assert %{"status" => "open"} = report_data(conn, "2027-01-10")
    end

    test "a missing or invalid date is rejected with invalid_reporting_date", %{conn: conn} do
      submit(conn, start_finance_reporting("2027-01-10", %{"operation_id" => "rep-1"}))

      for date <- [nil, "garbage", "2027-13-01", "2027-02-30", "2027-01-01T00:00:00"] do
        path =
          case date do
            nil -> "/api/v1/finance/daily-report"
            other -> "/api/v1/finance/daily-report?date=#{URI.encode_www_form(other)}"
          end

        assert %{"error" => %{"code" => "invalid_reporting_date"}} =
                 conn |> get(path) |> json_response(422)
      end
    end
  end

  ## Cash section

  describe "cash section" do
    test "reports the opening position per property in property order", %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        open_second_group(),
        pay("group-flex", 10_000, %{"occurred_on" => "2026-12-20"}),
        pay("group-92", 4000, %{"occurred_on" => "2026-12-21"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"})
      ])

      assert [%{"property_id" => "ams-canal"}, %{"property_id" => "rot-dijk"}] =
               report_data(conn, "2027-01-01")["cash"]

      assert cash_entry(report_data(conn, "2027-01-01"), "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 10_000,
               "movements" => zero_cash_movements(),
               "closing_held_cents" => 10_000
             }

      assert cash_entry(report_data(conn, "2027-01-01"), "rot-dijk")["closing_held_cents"] == 4000
    end

    test "payments post on the later of occurred_on and starts_on, and later submissions change an earlier open report",
         %{conn: conn} do
      submit(conn, open_flexible_group())

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        pay("group-flex", 6000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-10"})
      ])

      assert report_data(conn, "2027-01-01")["cash"] == []
      assert report_data(conn, "2027-01-03")["cash"] == []

      entry = cash_entry(report_data(conn, "2027-01-10"), "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 6000
      assert entry["closing_held_cents"] == 6000

      # A later submission can change an earlier open report.
      submit(
        conn,
        pay("group-flex", 4000, %{"operation_id" => "pay-2", "occurred_on" => "2027-01-03"})
      )

      assert report_data(conn, "2027-01-01")["cash"] == []

      entry = cash_entry(report_data(conn, "2027-01-03"), "ams-canal")
      assert entry["movements"]["received_cents"] == 4000
      assert entry["closing_held_cents"] == 4000

      entry = cash_entry(report_data(conn, "2027-01-10"), "ams-canal")
      assert entry["opening_held_cents"] == 4000
      assert entry["movements"]["received_cents"] == 6000
      assert entry["closing_held_cents"] == 10_000
    end

    test "transfers move out of the source property into the destination property", %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        open_second_group(),
        pay("group-flex", 10_000, %{"occurred_on" => "2026-12-20"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        transfer_deposit("group-flex", "group-92", 4000, %{
          "occurred_on" => "2027-01-03",
          "expected_revision" => 2
        })
      ])

      report = report_data(conn, "2027-01-03")

      canal = cash_entry(report, "ams-canal")
      assert canal["opening_held_cents"] == 10_000
      assert canal["movements"]["transferred_out_cents"] == 4000
      assert canal["closing_held_cents"] == 6000

      dijk = cash_entry(report, "rot-dijk")
      assert dijk["opening_held_cents"] == 0
      assert dijk["movements"]["transferred_in_cents"] == 4000
      assert dijk["closing_held_cents"] == 4000

      # Across all properties the two amounts are equal.
      out = Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))
      into = Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"]))
      assert out == into
    end

    test "refundable and non-refundable cancellations settle cash where the group held it", %{
      conn: conn
    } do
      submit(conn, [
        open_flexible_group(),
        open_second_group(%{"rate_plan" => "advance_purchase"}),
        pay("group-flex", 10_000, %{"occurred_on" => "2026-12-20"}),
        pay("group-92", 15_000, %{"occurred_on" => "2026-12-20"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"})
      ])

      submit(conn, [
        cancel("group-flex", "2027-01-05", %{"operation_id" => "cancel-flex"}),
        cancel("group-92", "2027-01-06", %{"operation_id" => "cancel-92"})
      ])

      canal = cash_entry(report_data(conn, "2027-01-05"), "ams-canal")
      assert canal["movements"]["refunded_cents"] == 10_000
      assert canal["closing_held_cents"] == 0

      dijk = cash_entry(report_data(conn, "2027-01-06"), "rot-dijk")
      assert dijk["movements"]["retained_cents"] == 15_000
      assert dijk["closing_held_cents"] == 0
    end

    test "a reduction follows the payment to the property where its cash is held", %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        open_second_group(),
        pay("group-flex", 10_000, %{"occurred_on" => "2026-12-20", "operation_id" => "pay-1"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        transfer_deposit("group-flex", "group-92", 4000, %{
          "occurred_on" => "2027-01-03",
          "expected_revision" => 2
        }),
        reduce_cash("pay-1", 4000, %{"occurred_on" => "2027-01-04", "expected_revision" => 3})
      ])

      report = report_data(conn, "2027-01-04")

      # The transferred 4000 were held on the destination, so the reduction
      # lands there — not back on the payment's original property. The
      # transfer itself is rot-dijk's opening on this date.
      dijk = cash_entry(report, "rot-dijk")
      assert dijk["opening_held_cents"] == 4000
      assert dijk["movements"]["reduced_cents"] == 4000
      assert dijk["closing_held_cents"] == 0

      assert cash_entry(report_data(conn, "2027-01-03"), "rot-dijk")["movements"][
               "transferred_in_cents"
             ] == 4000

      canal = cash_entry(report, "ams-canal")
      assert canal["movements"]["reduced_cents"] == 0
      assert canal["closing_held_cents"] == 6000

      assert ledger_data(conn)["cash_reduced_cents"] == 4000
    end

    test "a chargeback of held cash removes it from the property where it is held", %{conn: conn} do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        charge_back("pay-1", %{"occurred_on" => "2027-01-03"})
      ])

      entry = cash_entry(report_data(conn, "2027-01-03"), "ams-canal")
      assert entry["opening_held_cents"] == 10_000
      assert entry["movements"]["charged_back_cents"] == 10_000
      assert entry["closing_held_cents"] == 0
    end

    test "a chargeback of refunded cash reverses the refund and records charged-back cash", %{
      conn: conn
    } do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{"operation_id" => "cancel-flex"}),
        charge_back("pay-1", %{"occurred_on" => "2027-01-06"})
      ])

      report = report_data(conn, "2027-01-05")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["refunded_cents"] == 10_000
      assert entry["closing_held_cents"] == 0

      entry = cash_entry(report_data(conn, "2027-01-06"), "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["refunded_cents"] == -10_000
      assert entry["movements"]["charged_back_cents"] == 10_000
      assert entry["closing_held_cents"] == 0
    end

    test "omits a property only when its opening, closing, and every movement are zero", %{
      conn: conn
    } do
      submit(conn, [
        open_flexible_group(),
        open_second_group(),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        pay("group-flex", 4000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-02"}),
        transfer_deposit("group-flex", "group-92", 4000, %{
          "occurred_on" => "2027-01-02",
          "expected_revision" => 2
        })
      ])

      report = report_data(conn, "2027-01-02")

      # ams-canal closed back at zero, but its movements were not: it stays.
      canal = cash_entry(report, "ams-canal")
      assert canal["opening_held_cents"] == 0
      assert canal["closing_held_cents"] == 0
      assert canal["movements"]["received_cents"] == 4000
      assert canal["movements"]["transferred_out_cents"] == 4000

      # rot-dijk only enters through its movement.
      dijk = cash_entry(report, "rot-dijk")
      assert dijk["opening_held_cents"] == 0
      assert dijk["movements"]["transferred_in_cents"] == 4000
      assert dijk["closing_held_cents"] == 4000

      # A day with nothing but a fully-moved balance only lists the property
      # still holding cash.
      report = report_data(conn, "2027-01-03")

      assert [
               %{
                 "property_id" => "rot-dijk",
                 "opening_held_cents" => 4000,
                 "closing_held_cents" => 4000
               }
             ] = report["cash"]
    end
  end

  ## Credit section

  describe "credit section" do
    test "issuing credit on a cancellation enters liability; applying it moves nothing", %{
      conn: conn
    } do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        open_second_group(),
        apply_hotel_credit("group-92", 11_000, %{
          "operation_id" => "apply-1",
          "occurred_on" => "2027-01-06"
        })
      ])

      report = report_data(conn, "2027-01-05")
      credit = report["credit"]
      assert credit["opening_liability_cents"] == 0
      assert credit["movements"]["issued_cents"] == 11_000
      assert credit["closing_liability_cents"] == 11_000

      assert Map.keys(credit["movements"]) |> Enum.sort() == Enum.sort(@credit_movement_keys)

      canal = cash_entry(report, "ams-canal")
      assert canal["movements"]["converted_to_credit_cents"] == 10_000

      # Applying credit redeems it into the deposit: no movement column.
      report = report_data(conn, "2027-01-06")
      assert report["credit"]["opening_liability_cents"] == 11_000
      assert report["credit"]["movements"] |> Map.values() |> Enum.all?(&(&1 == 0))
      assert report["credit"]["closing_liability_cents"] == 11_000
      assert ledger_data(conn, "?on=2027-01-06")["credit_liability_cents"] == 11_000
    end

    test "a non-refundable settlement consumes applied credit", %{conn: conn} do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        open_second_group(),
        apply_hotel_credit("group-92", 11_000, %{
          "operation_id" => "apply-1",
          "occurred_on" => "2027-01-06"
        }),
        # group-92 is refundable only through 2026-12-06, so this settlement
        # is non-refundable and consumes the applied credit.
        cancel("group-92", "2027-01-10", %{"operation_id" => "cancel-92"})
      ])

      report = report_data(conn, "2027-01-10")
      credit = report["credit"]
      assert credit["opening_liability_cents"] == 11_000
      assert credit["movements"]["consumed_cents"] == 11_000
      assert credit["closing_liability_cents"] == 0

      assert ledger_data(conn, "?on=2027-01-10")["credit_liability_cents"] == 0
    end

    test "credit unused through expires_on expires on the following date with no operations that day",
         %{conn: conn} do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        })
      ])

      last_usable = lot_last_usable_date()
      following = lot_expiry_reporting_date()

      report = report_data(conn, last_usable)
      assert report["credit"]["closing_liability_cents"] == 11_000
      assert report["credit"]["movements"]["expired_cents"] == 0

      # No partner operation was submitted on the expiry date.
      report = report_data(conn, following)
      assert report["credit"]["opening_liability_cents"] == 11_000
      assert report["credit"]["movements"]["expired_cents"] == 11_000
      assert report["credit"]["closing_liability_cents"] == 0

      assert ledger_data(conn, "?on=#{following}")["credit_liability_cents"] == 0

      # A date before the expiry still shows the liability, in any read order.
      assert report_data(conn, "2027-06-01")["credit"]["closing_liability_cents"] == 11_000
    end

    test "applied credit pauses expiry, and restored credit expires on its original date", %{
      conn: conn
    } do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        open_second_group(%{
          "occurred_on" => "2026-12-15",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
        }),
        apply_hotel_credit("group-92", 11_000, %{
          "operation_id" => "apply-1",
          "occurred_on" => "2027-06-01"
        })
      ])

      # The applied credit is paused: no expiry on the lot's expiry date.
      report = report_data(conn, lot_expiry_reporting_date())
      assert report["credit"]["movements"]["expired_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 11_000

      # A refundable cancellation restores the credit to its lot and expiry.
      submit(conn, cancel("group-92", "2027-01-06", %{"operation_id" => "cancel-92"}))

      report = report_data(conn, lot_expiry_reporting_date())
      assert report["credit"]["opening_liability_cents"] == 11_000
      assert report["credit"]["movements"]["expired_cents"] == 11_000
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "restored credit whose lot already expired expires immediately", %{conn: conn} do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        open_late_group(),
        apply_hotel_credit("group-late", 11_000, %{
          "operation_id" => "apply-1",
          "occurred_on" => "2027-06-01"
        })
      ])

      # The lot expired on its own date while the credit funded group-late.
      assert report_data(conn, lot_expiry_reporting_date())["credit"]["closing_liability_cents"] ==
               11_000

      # The refundable cancellation occurs after the lot's expiry, so the
      # restored amount expires immediately on the settlement's posting date.
      submit(conn, cancel("group-late", "2028-06-01", %{"operation_id" => "cancel-late"}))

      report = report_data(conn, "2028-06-01")
      assert report["credit"]["opening_liability_cents"] == 11_000
      assert report["credit"]["movements"]["expired_cents"] == 11_000
      assert report["credit"]["closing_liability_cents"] == 0

      # Nothing extra expires at the lot's own date afterwards: the credit
      # was genuinely liability until the late settlement posted.
      assert report_data(conn, lot_expiry_reporting_date())["credit"]["closing_liability_cents"] ==
               11_000
    end

    test "a chargeback revokes the converted entitlement and reverses the conversion", %{
      conn: conn
    } do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        charge_back("pay-1", %{"occurred_on" => "2027-01-06"})
      ])

      report = report_data(conn, "2027-01-06")

      canal = cash_entry(report, "ams-canal")
      assert canal["movements"]["converted_to_credit_cents"] == -10_000
      assert canal["movements"]["charged_back_cents"] == 10_000
      assert canal["closing_held_cents"] == 0

      credit = report["credit"]
      assert credit["opening_liability_cents"] == 11_000
      assert credit["movements"]["revoked_cents"] == 11_000
      assert credit["closing_liability_cents"] == 0

      assert ledger_data(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger_data(conn)["cash_charged_back_cents"] == 10_000
      assert ledger_data(conn)["credit_liability_cents"] == 0
    end

    test "a restoration into a shortfalled lot is absorbed before it can become available", %{
      conn: conn
    } do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        open_second_group(%{
          "occurred_on" => "2026-12-15",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
        }),
        apply_hotel_credit("group-92", 11_000, %{
          "operation_id" => "apply-1",
          "occurred_on" => "2027-01-06"
        }),
        # The clawback claim cannot be removed from the exhausted lot, so the
        # whole entitlement becomes its unrecovered clawback and the applied
        # credit becomes shortfall. No revoked movement reports, because no
        # liability left at the chargeback itself.
        charge_back("pay-1", %{"occurred_on" => "2027-01-07"})
      ])

      assert report_data(conn, "2027-01-07")["credit"]["movements"]["revoked_cents"] == 0
      assert report_data(conn, "2027-01-07")["credit"]["closing_liability_cents"] == 11_000
      assert ledger_data(conn)["credit_shortfall_cents"] == 11_000

      # The refundable cancellation returns the credit into the shortfalled
      # lot, where it is absorbed instead of becoming available.
      submit(conn, cancel("group-92", "2027-02-01", %{"operation_id" => "cancel-92"}))

      report = report_data(conn, "2027-02-01")
      assert report["credit"]["opening_liability_cents"] == 11_000
      assert report["credit"]["movements"]["absorbed_cents"] == 11_000
      assert report["credit"]["closing_liability_cents"] == 0

      assert ledger_data(conn, "?on=2027-02-01")["credit_liability_cents"] == 0
      assert ledger_data(conn, "?on=2027-02-01")["credit_shortfall_cents"] == 0
    end
  end

  describe "opening position and selected-room settlements" do
    test "the opening position includes every operation already committed, even one whose occurred_on is on or after starts_on",
         %{conn: conn} do
      submit(conn, [
        open_flexible_group(),
        pay("group-flex", 10_000, %{"occurred_on" => "2027-03-01", "operation_id" => "pay-1"})
      ])

      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      # The payment committed before the start belongs to the opening
      # position on starts_on, wherever its occurred_on falls; no day shows a
      # received movement for it.
      entry = cash_entry(report_data(conn, "2027-01-01"), "ams-canal")
      assert entry["opening_held_cents"] == 10_000
      assert entry["movements"] == zero_cash_movements()

      entry = cash_entry(report_data(conn, "2027-03-01"), "ams-canal")
      assert entry["movements"]["received_cents"] == 0
      assert entry["closing_held_cents"] == 10_000
    end

    test "cancel_rooms journals the settlement of only the selected rooms", %{conn: conn} do
      open_two_room_group = fn ->
        open_group(%{
          "operation_id" => "open-two",
          "group_id" => "group-two",
          "occurred_on" => "2026-12-15",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13",
          "rooms" => [
            %{"room_id" => "room-e", "nightly_rate_cents" => 20_000},
            %{"room_id" => "room-f", "nightly_rate_cents" => 20_000}
          ]
        })
      end

      submit(conn, [
        open_two_room_group.(),
        pay("group-two", 12_000, %{"occurred_on" => "2026-12-20", "operation_id" => "pay-1"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"})
      ])

      submit(conn, [
        cancel_rooms("group-two", ["room-e"], "2027-01-05", %{
          "operation_id" => "shrink-1",
          "refund_method" => "hotel_credit"
        })
      ])

      report = report_data(conn, "2027-01-05")

      # Each room is due 12000 (20% of 60000), so the whole payment filled
      # room-e; cancelling it settles exactly that room's cash.
      canal = cash_entry(report, "ams-canal")
      assert canal["opening_held_cents"] == 12_000
      assert canal["movements"]["converted_to_credit_cents"] == 12_000
      assert canal["closing_held_cents"] == 0

      credit = report["credit"]
      assert credit["movements"]["issued_cents"] == 13_200
      assert credit["closing_liability_cents"] == 13_200

      assert ledger_data(conn, "?on=2027-01-05")["credit_liability_cents"] == 13_200
    end
  end

  describe "rejections, retries, and stability" do
    test "rejected operations leave no reporting movement", %{conn: conn} do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        pay("group-flex", 999_999, %{"operation_id" => "pay-bad", "occurred_on" => "2027-01-02"})
      ])

      # The rejection journals nothing: only the opening position is there.
      entry = cash_entry(report_data(conn, "2027-01-02"), "ams-canal")
      assert entry["opening_held_cents"] == 10_000
      assert entry["movements"] == zero_cash_movements()
      assert entry["closing_held_cents"] == 10_000

      # Movements from earlier applied operations remain when a later one in
      # the batch is rejected.
      results =
        submit(conn, [
          pay("group-flex", 2000, %{"operation_id" => "pay-ok", "occurred_on" => "2027-01-03"}),
          pay("group-flex", 999_999, %{
            "operation_id" => "pay-bad-2",
            "occurred_on" => "2027-01-03"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = results

      entry = cash_entry(report_data(conn, "2027-01-03"), "ams-canal")
      assert entry["movements"]["received_cents"] == 2000
    end

    test "a durable retry reports a movement exactly once", %{conn: conn} do
      submit(conn, open_flexible_group())

      op = pay("group-flex", 5000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-02"})

      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))

      assert [%{"status" => "applied"} = first] = submit(conn, op)
      assert [^first] = submit(conn, op)

      entry = cash_entry(report_data(conn, "2027-01-02"), "ams-canal")
      assert entry["movements"]["received_cents"] == 5000
      assert entry["closing_held_cents"] == 5000
    end

    test "reading reports in any order or repeatedly never changes a report or domain state", %{
      conn: conn
    } do
      funded_group(conn)

      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-flex", "2027-01-05", %{
          "operation_id" => "cancel-flex",
          "refund_method" => "hotel_credit"
        }),
        open_second_group(),
        apply_hotel_credit("group-92", 5000, %{
          "operation_id" => "apply-1",
          "occurred_on" => "2027-01-06"
        })
      ])

      ledger_before = ledger_data(conn)

      last = report_data(conn, "2027-01-06")
      middle = report_data(conn, "2027-01-05")
      assert report_data(conn, "2027-01-06") == last
      assert report_data(conn, "2027-01-05") == middle
      assert report_data(conn, "2027-01-06") == last

      assert ledger_data(conn) == ledger_before
    end

    test "an equivalent batch produces the same report as sequential submissions", %{conn: conn} do
      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        open_flexible_group(),
        pay("group-flex", 10_000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-02"}),
        cancel("group-flex", "2027-01-05", %{"operation_id" => "cancel-flex"})
      ])

      assert report_data(conn, "2027-01-05") == day_five_report()
    end

    test "sequential submissions produce the same report as the equivalent batch", %{conn: conn} do
      submit(conn, start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}))
      submit(conn, open_flexible_group())

      submit(
        conn,
        pay("group-flex", 10_000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-02"})
      )

      submit(conn, cancel("group-flex", "2027-01-05", %{"operation_id" => "cancel-flex"}))

      assert report_data(conn, "2027-01-05") == day_five_report()
    end
  end

  ## Reconciliation with the current views

  describe "reconciliation" do
    test "report movements reconcile to the ledger and group views", %{conn: conn} do
      submit(conn, [
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        open_late_group(),
        open_second_group(),
        pay("group-late", 10_000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-02"}),
        transfer_deposit("group-late", "group-92", 3000, %{
          "occurred_on" => "2027-01-03",
          "expected_revision" => 2
        }),
        pay("group-92", 2000, %{"operation_id" => "pay-2", "occurred_on" => "2027-01-04"}),
        cancel("group-late", "2027-01-05", %{"operation_id" => "cancel-late"}),
        reduce_cash("pay-2", 500, %{"occurred_on" => "2027-01-06", "expected_revision" => 3}),
        charge_back("pay-1", %{"occurred_on" => "2027-01-07"})
      ])

      last = report_data(conn, "2027-01-07")

      # utrecht-stad's opening accumulates everything posted before the day:
      # received 10000, transferred out 3000, refunded 7000.
      canal = cash_entry(last, "utrecht-stad")
      assert canal["opening_held_cents"] == 0
      assert canal["movements"]["refunded_cents"] == -7000
      assert canal["movements"]["charged_back_cents"] == 7000
      assert canal["closing_held_cents"] == 0

      # rot-dijk's opening is the transferred 3000 plus pay-2's 2000 less the
      # 500 reduction; the chargeback takes the transferred 3000 back.
      dijk = cash_entry(last, "rot-dijk")
      assert dijk["opening_held_cents"] == 4500
      assert dijk["movements"]["charged_back_cents"] == 3000
      assert dijk["closing_held_cents"] == 1500

      # Each movement lands on its own posting date.
      canal = cash_entry(report_data(conn, "2027-01-02"), "utrecht-stad")
      assert canal["movements"]["received_cents"] == 10_000

      canal = cash_entry(report_data(conn, "2027-01-05"), "utrecht-stad")
      assert canal["opening_held_cents"] == 7000
      assert canal["movements"]["refunded_cents"] == 7000
      assert canal["closing_held_cents"] == 0

      # The report's closing positions are the current views.
      held = Enum.sum(Enum.map(last["cash"], & &1["closing_held_cents"]))
      assert held == ledger_data(conn)["cash_held_cents"]

      assert last["credit"]["closing_liability_cents"] ==
               ledger_data(conn)["credit_liability_cents"]

      # Each earlier day reconciles to the held cash of its own timeline.
      assert report_data(conn, "2027-01-01")["cash"] == []

      assert Enum.sum(
               Enum.map(report_data(conn, "2027-01-03")["cash"], & &1["closing_held_cents"])
             ) ==
               10_000

      assert Enum.sum(
               Enum.map(report_data(conn, "2027-01-05")["cash"], & &1["closing_held_cents"])
             ) ==
               5000

      assert Enum.sum(
               Enum.map(report_data(conn, "2027-01-06")["cash"], & &1["closing_held_cents"])
             ) ==
               4500
    end

    test "an open report reflects a refund posted on its own date", %{conn: conn} do
      submit(conn, [
        open_late_group(),
        pay("group-late", 10_000, %{"operation_id" => "pay-1", "occurred_on" => "2027-01-02"}),
        start_finance_reporting("2027-01-01", %{"operation_id" => "rep-1"}),
        cancel("group-late", "2027-01-05", %{"operation_id" => "cancel-late"})
      ])

      entry = cash_entry(report_data(conn, "2027-01-05"), "utrecht-stad")
      assert entry["movements"]["refunded_cents"] == 10_000
      assert entry["closing_held_cents"] == 0

      assert ledger_data(conn)["cash_refunded_cents"] == 10_000
    end
  end

  defp zero_cash_movements do
    Map.new(@cash_movement_keys, fn key -> {key, 0} end)
  end

  # The hotel-credit cancellation above occurred on 2027-01-05; its lot is
  # worth 11000 (10000 of converted cash plus the 10% bonus) and expires on
  # the day after its 365th day of validity.
  @lot_issued_on ~D[2027-01-05]

  defp lot_last_usable_date do
    @lot_issued_on |> Date.add(365) |> Date.to_iso8601()
  end

  defp lot_expiry_reporting_date do
    @lot_issued_on |> Date.add(365) |> Date.add(1) |> Date.to_iso8601()
  end

  defp day_five_report do
    %{
      "date" => "2027-01-05",
      "status" => "open",
      "cash" => [
        %{
          "property_id" => "ams-canal",
          "opening_held_cents" => 10_000,
          "movements" => %{
            "received_cents" => 0,
            "transferred_in_cents" => 0,
            "transferred_out_cents" => 0,
            "refunded_cents" => 10_000,
            "retained_cents" => 0,
            "converted_to_credit_cents" => 0,
            "reduced_cents" => 0,
            "charged_back_cents" => 0
          },
          "closing_held_cents" => 0
        }
      ],
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
  end
end
