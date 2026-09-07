defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import GroupStay.FinanceHelpers

  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Finance.{Entry, ReportingPeriod}

  test "closes validate the period, ignore revision guards and retain exact receipts", %{
    conn: conn
  } do
    premature = close_period()
    assert [rejected] = submit(conn, [premature])
    assert rejected["code"] == "invalid_period"
    assert Repo.all(ReportingPeriod) == []

    submit(conn, [room_group(), payment(%{"amount_cents" => 100}), start_reporting()])
    before = {domain_snapshot(), Repo.all(Entry)}

    for value <- [nil, "", "2026-02-30", "tomorrow", 20_261_101, [], %{}, "2026-10-31"] do
      assert [%{"code" => "invalid_period"}] = submit(conn, [close_period(value)])
      assert Repo.get!(ReportingPeriod, 1).closed_through == nil
      assert {domain_snapshot(), Repo.all(Entry)} == before
    end

    assert [%{"code" => "invalid_period"}] =
             submit(conn, [Map.delete(close_period(), "period_end_on")])

    for value <- [nil, "bad", []] do
      assert [%{"code" => "invalid_operation"}] =
               submit(conn, [close_period("2026-11-01", %{"occurred_on" => value})])
    end

    close =
      close_period("2026-11-01", %{"expected_revision" => "ignored"})
      |> Map.put("group_id", "missing")

    assert [receipt] = submit(conn, [close])

    assert receipt == %{
             "operation_id" => close["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-11-01"
           }

    assert {domain_snapshot(), Repo.all(Entry)} == before
    assert Repo.get!(ReportingPeriod, 1).closed_through == ~D[2026-11-01]

    assert [
             ^receipt,
             ^rejected,
             %{"code" => "invalid_period"},
             %{"code" => "invalid_period"},
             %{"code" => "operation_id_conflict"}
           ] =
             submit(conn, [
               close,
               premature,
               close_period(),
               close_period("2026-10-31"),
               Map.put(close, "period_end_on", "2026-12-01")
             ])

    assert conn |> get("/api/v1/operations/#{close["operation_id"]}") |> json_response(200) == %{
             "data" => receipt
           }

    assert Operations.get_result(close["operation_id"]) == receipt
    assert report(conn, "2026-11-01")["status"] == "closed"
    assert report(conn, "2026-11-02")["status"] == "open"

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}
  end

  test "batch order fixes posting dates and subsequent closes preserve published bytes", %{
    conn: conn
  } do
    initial = payment(%{"amount_cents" => 10, "occurred_on" => "2026-10-01"})
    late = payment(%{"amount_cents" => 20, "occurred_on" => "2026-10-01"})
    close = close_period("2026-11-03")

    assert [_, _, initial_receipt, _, late_receipt, %{"code" => "invalid_amount"}, _] =
             submit(conn, [
               room_group("group-81", [1000]),
               start_reporting(),
               initial,
               close,
               late,
               payment(%{"amount_cents" => -1}),
               payment(%{"amount_cents" => 30, "occurred_on" => "2026-11-04"})
             ])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row("ams-canal", 0, %{"received_cents" => 10}, 10)
           ]

    assert report(conn, "2026-11-01")["late_adjustments"] == late_adjustments()
    assert report(conn, "2026-11-03")["cash"] == [cash_row("ams-canal", 10, %{}, 10)]
    day = report(conn, "2026-11-04")
    assert day["cash"] == [cash_row("ams-canal", 10, %{"received_cents" => 30}, 60)]

    assert day["late_adjustments"] ==
             late_adjustments([late_cash_row("ams-canal", %{"received_cents" => 20})])

    dates = ~w(2026-11-01 2026-11-02 2026-11-03)
    published = Enum.map(dates, &report_bytes(conn, &1))
    entries = Repo.all(Entry)

    submit(conn, [
      payment(%{"amount_cents" => 40, "occurred_on" => "2026-11-03"}),
      payment(%{"amount_cents" => 50, "occurred_on" => "2026-11-08"}),
      close_period("2026-11-04")
    ])

    assert Enum.map(dates, &report_bytes(conn, &1)) == published
    closed_fourth = report_bytes(conn, "2026-11-04")

    assert report(conn, "2026-11-04")["late_adjustments"] ==
             late_adjustments([late_cash_row("ams-canal", %{"received_cents" => 60})])

    assert report(conn, "2026-11-04")["status"] == "closed"

    # The future payment keeps its original date; an old submission uses the new first open day.
    submit(conn, [payment(%{"amount_cents" => 60}), close_period("2026-11-06")])
    assert report(conn, "2026-11-05")["cash"] == [cash_row("ams-canal", 100, %{}, 160)]

    assert report(conn, "2026-11-05")["late_adjustments"] ==
             late_adjustments([late_cash_row("ams-canal", %{"received_cents" => 60})])

    assert report(conn, "2026-11-08")["cash"] == [
             cash_row("ams-canal", 160, %{"received_cents" => 50}, 210)
           ]

    assert report(conn, "2026-11-08")["late_adjustments"] == late_adjustments()
    assert report_bytes(conn, "2026-11-04") == closed_fourth
    assert Enum.map(dates, &report_bytes(conn, &1)) == published
    assert Enum.take(Repo.all(Entry), length(entries)) == entries

    assert [^initial_receipt, ^late_receipt, %{"status" => "applied"}] =
             submit(conn, [initial, late, close])

    assert Reservations.get_group("group-81").deposit_paid_cents == 210
    assert Reservations.get_group("group-81").revision == 7
  end

  test "late corrections retain signed classifications and follow all settlement properties", %{
    conn: conn
  } do
    pay = payment(%{"group_id" => "source", "operation_id" => "p", "amount_cents" => 600})

    submit(conn, [
      room_group("source", [600], %{"property_id" => "z-source"}),
      room_group("target", [100, 100, 100, 100], %{"property_id" => "a-target"}),
      start_reporting(),
      pay,
      transfer("source", "target", 400),
      cancel_rooms(["r1"], %{"group_id" => "target"}),
      cancel_rooms(["r2"], %{"group_id" => "target", "occurred_on" => "2026-11-27"}),
      cancel_rooms(["r3"], %{"group_id" => "target", "refund_method" => "hotel_credit"}),
      close_period("2026-11-28")
    ])

    dates = Date.range(~D[2026-11-01], ~D[2026-11-28]) |> Enum.map(&Date.to_iso8601/1)
    published = Enum.map(dates, &report_bytes(conn, &1))
    receipt = Operations.get_result("p")
    corrections = [reduce_cash("p", 150), charge_back("p")]
    results = submit(conn, corrections)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    day = report(conn, "2026-11-29")

    assert day["cash"] == [cash_row("a-target", 100, %{}, 0), cash_row("z-source", 200, %{}, 0)]
    assert day["credit"] == credit_row(110, %{}, 0)

    assert day["late_adjustments"] ==
             late_adjustments(
               [
                 late_cash_row("a-target", %{
                   "refunded_cents" => -100,
                   "retained_cents" => -100,
                   "converted_to_credit_cents" => -100,
                   "reduced_cents" => 100,
                   "charged_back_cents" => 300
                 }),
                 late_cash_row("z-source", %{"reduced_cents" => 50, "charged_back_cents" => 150})
               ],
               %{"revoked_cents" => 110}
             )

    assert report(conn, "2027-11-02")["credit"] == credit_row()
    assert report(conn, "2026-11-30")["cash"] == []
    assert Enum.map(dates, &report_bytes(conn, &1)) == published
    assert Reservations.ledger(~D[2026-11-29]).cash_charged_back_cents == 450
    assert Reservations.ledger(~D[2026-11-29]).cash_reduced_cents == 150
    assert Reservations.ledger(~D[2026-11-29]).credit_liability_cents == 0
    assert submit(conn, corrections) == results
    assert submit(conn, [pay]) == [receipt]
    assert report(conn, "2026-11-29") == day
  end

  test "zero-net late refunds and transfers remain visible while zero properties are omitted", %{
    conn: conn
  } do
    submit(conn, [
      room_group("group-81", [100]),
      room_group("other", [100]),
      room_group("empty", [100], %{"property_id" => "empty"}),
      start_reporting(),
      payment(%{"operation_id" => "p", "amount_cents" => 100}),
      cancellation(),
      close_period(),
      charge_back("p")
    ])

    day = report(conn, "2026-11-02")
    assert day["cash"] == [cash_row("ams-canal", 0, %{}, 0)]

    assert day["late_adjustments"] ==
             late_adjustments([
               late_cash_row("ams-canal", %{"refunded_cents" => -100, "charged_back_cents" => 100})
             ])

    submit(conn, [
      room_group("source", [100], %{"property_id" => "z-source"}),
      payment(%{"group_id" => "source", "amount_cents" => 100, "occurred_on" => "2026-11-02"}),
      transfer("source", "other", 100),
      room_group("same-property", [100]),
      transfer("other", "same-property", 100)
    ])

    assert report(conn, "2026-11-02")["late_adjustments"] ==
             late_adjustments([
               late_cash_row("ams-canal", %{
                 "refunded_cents" => -100,
                 "charged_back_cents" => 100,
                 "transferred_in_cents" => 200,
                 "transferred_out_cents" => 100
               }),
               late_cash_row("z-source", %{"transferred_out_cents" => 100})
             ])
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

  defp report_bytes(conn, date) do
    response = get(conn, "/api/v1/finance/daily-report?date=#{date}")
    assert response.status == 200
    response.resp_body
  end
end
