defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import GroupStay.FinanceHelpers

  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Finance.{Entry, ReportingPeriod}

  test "report dates are required and validated before report availability", %{conn: conn} do
    for query <- ["", "?date=", "?date=2026-02-30", "?date=bad", "?date[]=2026-11-01"] do
      assert conn |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert conn |> get("/api/v1/finance/daily-report?date=2026-11-01") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    submit(conn, [start_reporting()])

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert report(conn, "2026-11-01") == %{
             "date" => "2026-11-01",
             "status" => "open",
             "cash" => [],
             "credit" => credit_row()
           }
  end

  test "start validates dates, ignores revision guards and preserves exact durable results", %{
    conn: conn
  } do
    for value <- [nil, "", "2026-02-30", "tomorrow", 20_261_101, [], %{}] do
      invalid = start_reporting(value)
      assert [%{"code" => "invalid_reporting_date"}] = submit(conn, [invalid])
      assert Repo.all(ReportingPeriod) == []
      assert Repo.all(Entry) == []
    end

    missing = start_reporting() |> Map.delete("starts_on")
    assert [%{"code" => "invalid_reporting_date"}] = submit(conn, [missing])

    start = start_reporting("2026-11-01", %{"expected_revision" => "ignored"})
    assert [result] = submit(conn, [start])

    assert result == %{
             "operation_id" => start["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-11-01"
           }

    assert Operations.get_result(start["operation_id"]) == result

    assert [
             ^result,
             %{"code" => "reporting_already_started"},
             %{"code" => "operation_id_conflict"}
           ] =
             submit(conn, [start, start_reporting(), Map.put(start, "starts_on", "2026-12-01")])

    assert [%{"code" => "invalid_reporting_date"}] = submit(conn, [missing])
    assert Repo.aggregate(ReportingPeriod, :count) == 1
  end

  test "inception uses commit order including future dates and separates operations in one batch",
       %{conn: conn} do
    submit(conn, [
      room_group("source", [1000]),
      payment(%{"group_id" => "source", "amount_cents" => 400, "occurred_on" => "2027-01-01"}),
      start_reporting(),
      payment(%{"group_id" => "source", "amount_cents" => 100, "occurred_on" => "2026-10-31"}),
      payment(%{"group_id" => "source", "amount_cents" => 200, "occurred_on" => "2026-11-03"})
    ])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row("ams-canal", 400, %{"received_cents" => 100}, 500)
           ]

    assert report(conn, "2026-11-02")["cash"] == [cash_row("ams-canal", 500, %{}, 500)]

    assert report(conn, "2026-11-03")["cash"] == [
             cash_row("ams-canal", 500, %{"received_cents" => 200}, 700)
           ]

    assert report(conn, "2027-01-01")["cash"] == [cash_row("ams-canal", 700, %{}, 700)]
  end

  test "late operations update open days while reads, retries and rejections have no effects", %{
    conn: conn
  } do
    pay = payment(%{"operation_id" => "p", "amount_cents" => 100, "occurred_on" => "2026-11-03"})
    failed = payment(%{"amount_cents" => 9999, "occurred_on" => "2026-11-02"})
    [_, _, receipt, rejection] = submit(conn, [room_group(), start_reporting(), pay, failed])
    assert rejection["status"] == "rejected"
    assert report(conn, "2026-11-02")["cash"] == []

    submit(conn, [payment(%{"amount_cents" => 50, "occurred_on" => "2026-11-02"})])

    assert report(conn, "2026-11-02")["cash"] == [
             cash_row("ams-canal", 0, %{"received_cents" => 50}, 50)
           ]

    assert report(conn, "2026-11-03")["cash"] == [
             cash_row("ams-canal", 50, %{"received_cents" => 100}, 150)
           ]

    before = {domain_snapshot(), Repo.all(Entry)}
    dates = ~w(2026-11-04 2026-11-01 2026-11-03 2026-11-02)
    reports = Enum.map(dates, &report(conn, &1))
    assert submit(conn, [pay, failed]) == [receipt, rejection]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(pay, "amount_cents", 99)])

    assert Enum.map(Enum.reverse(dates), &report(conn, &1)) == Enum.reverse(reports)
    assert {domain_snapshot(), Repo.all(Entry)} == before
    assert_reconciles(conn, "2026-11-04")
  end

  test "cash corrections follow transferred allocations and every settled disposition", %{
    conn: conn
  } do
    submit(conn, [
      room_group("source", [600], %{"property_id" => "z-source"}),
      room_group("target", [100, 100, 100, 100], %{"property_id" => "a-target"}),
      start_reporting(),
      payment(%{"group_id" => "source", "operation_id" => "p", "amount_cents" => 600}),
      transfer("source", "target", 400),
      cancel_rooms(["r1"], %{"group_id" => "target"}),
      cancel_rooms(["r2"], %{"group_id" => "target", "occurred_on" => "2026-11-27"}),
      cancel_rooms(["r3"], %{"group_id" => "target", "refund_method" => "hotel_credit"}),
      reduce_cash("p", 150, %{"occurred_on" => "2026-11-28"})
    ])

    assert report(conn, "2026-11-28")["cash"] == [
             cash_row("a-target", 100, %{"reduced_cents" => 100}, 0),
             cash_row("z-source", 200, %{"reduced_cents" => 50}, 150)
           ]

    submit(conn, [charge_back("p", %{"occurred_on" => "2026-11-29"})])
    day = report(conn, "2026-11-29")

    assert day["cash"] == [
             cash_row(
               "a-target",
               0,
               %{
                 "refunded_cents" => -100,
                 "retained_cents" => -100,
                 "converted_to_credit_cents" => -100,
                 "charged_back_cents" => 300
               },
               0
             ),
             cash_row("z-source", 150, %{"charged_back_cents" => 150}, 0)
           ]

    assert day["credit"] == credit_row(110, %{"revoked_cents" => 110}, 0)
    assert report(conn, "2026-11-30")["cash"] == []
    assert report(conn, "2027-11-02")["credit"] == credit_row()
    assert_reconciles(conn, "2026-11-29")
  end

  test "same-property transfers report both directions and cashless properties are omitted", %{
    conn: conn
  } do
    submit(conn, [
      room_group("source"),
      room_group("destination"),
      room_group("empty", [100], %{"property_id" => "empty-property"}),
      payment(%{"group_id" => "source", "amount_cents" => 100}),
      start_reporting(),
      transfer("source", "destination", 100)
    ])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row(
               "ams-canal",
               100,
               %{"transferred_in_cents" => 100, "transferred_out_cents" => 100},
               100
             )
           ]

    assert_reconciles(conn, "2026-11-01")
  end

  test "property totals remain exact beyond SQLite's signed integer aggregate range", %{
    conn: conn
  } do
    amount = 9_000_000_000_000_000_000

    for id <- ["first", "second"] do
      submit(conn, [
        open_group(%{
          "group_id" => id,
          "rate_plan" => "advance_purchase",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => amount}]
        }),
        payment(%{"group_id" => id, "amount_cents" => amount})
      ])
    end

    submit(conn, [start_reporting()])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row("ams-canal", amount * 2, %{}, amount * 2)
           ]

    submit(conn, [cancellation(%{"group_id" => "first"}), cancellation(%{"group_id" => "second"})])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row("ams-canal", amount * 2, %{"retained_cents" => amount * 2}, 0)
           ]

    assert_reconciles(conn, "2026-11-01")
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
    |> assert_balanced()
  end

  defp assert_reconciles(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end
end
