defmodule GroupStayWeb.FinancePeriodCloseCreditTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import GroupStay.FinanceHelpers

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.Entry

  test "issuance whose expiry is already closed posts both classifications on the first open day",
       %{
         conn: conn
       } do
    submit(conn, [start_reporting(), close_period("2027-11-02")])
    published = report(conn, "2027-11-02")
    issue_credit(conn)

    day = report(conn, "2027-11-03")
    assert day["credit"] == credit_row()
    assert day["cash"] == [cash_row("ams-canal", 0, %{}, 0)]

    assert day["late_adjustments"] ==
             late_adjustments(
               [
                 late_cash_row("ams-canal", %{
                   "received_cents" => 100,
                   "converted_to_credit_cents" => 100
                 })
               ],
               %{"issued_cents" => 110, "expired_cents" => 110}
             )

    assert report(conn, "2027-11-02") == published
    assert Reservations.ledger(~D[2027-11-03]).credit_liability_cents == 0
  end

  test "late issuance keeps future expiry ordinary and later redemption cannot rewrite its closed expiry",
       %{conn: conn} do
    submit(conn, [start_reporting(), close_period()])
    issue_credit(conn)

    day = report(conn, "2026-11-02")
    assert day["credit"] == credit_row(0, %{}, 110)

    assert day["late_adjustments"]["credit"] ==
             late_adjustments([], %{"issued_cents" => 110})["credit"]

    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    assert report(conn, "2027-11-02")["late_adjustments"] == late_adjustments()

    submit(conn, [close_period("2027-11-02")])
    closed = report(conn, "2027-11-02")
    closed_issuance = report(conn, "2026-11-02")

    submit(conn, [
      future_group("target", [80]),
      credit_payment(%{
        "group_id" => "target",
        "amount_cents" => 80,
        "occurred_on" => "2027-11-01"
      })
    ])

    assert report(conn, "2027-11-02") == closed
    assert report(conn, "2026-11-02") == closed_issuance
    day = report(conn, "2027-11-03")
    assert day["credit"] == credit_row(0, %{}, 80)
    assert day["late_adjustments"] == late_adjustments([], %{"expired_cents" => -80})
    assert Reservations.ledger(~D[2027-11-03]).credit_liability_cents == 80

    submit(conn, [close_period("2027-11-03")])
    closed_redemption = report(conn, "2027-11-03")
    submit(conn, [cancellation(%{"group_id" => "target", "occurred_on" => "2027-11-01"})])

    assert report(conn, "2027-11-04")["credit"] == credit_row(80, %{}, 0)

    assert report(conn, "2027-11-04")["late_adjustments"] ==
             late_adjustments([], %{"expired_cents" => 80})

    assert report(conn, "2027-11-03") == closed_redemption
    assert report(conn, "2027-11-02") == closed
    assert Reservations.ledger(~D[2027-11-04]).credit_liability_cents == 0
  end

  test "late revocation offsets published expiry without losing zero-net classifications", %{
    conn: conn
  } do
    submit(conn, [start_reporting()])
    issue_credit(conn)
    submit(conn, [close_period("2027-11-02")])
    closed = report(conn, "2027-11-02")
    before = Repo.all(Entry)

    correction = charge_back("first", %{"occurred_on" => "2027-11-01"})
    [receipt] = submit(conn, [correction])
    day = report(conn, "2027-11-03")
    assert day["credit"] == credit_row()

    assert day["late_adjustments"] ==
             late_adjustments(
               [
                 late_cash_row("ams-canal", %{
                   "converted_to_credit_cents" => -50,
                   "charged_back_cents" => 50
                 })
               ],
               %{"revoked_cents" => 55, "expired_cents" => -55}
             )

    assert report(conn, "2027-11-02") == closed
    assert Enum.take(Repo.all(Entry), length(before)) == before
    assert submit(conn, [correction]) == [receipt]
    assert report(conn, "2027-11-03") == day
    assert Reservations.ledger(~D[2027-11-03]).credit_liability_cents == 0

    # A revocation dated after expiry removes no reporting liability twice.
    submit(conn, [charge_back("second", %{"occurred_on" => "2027-11-03"})])
    assert report(conn, "2027-11-03")["credit"] == credit_row()
    assert report(conn, "2027-11-03")["late_adjustments"] == day["late_adjustments"]
  end

  test "late revocation, consumption, absorption and expired restoration reconcile after successive closes",
       %{conn: conn} do
    submit(conn, [start_reporting()])
    issue_credit(conn)

    submit(conn, [
      future_group("target", [20, 10, 50]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80}),
      close_period(),
      charge_back("first"),
      close_period("2026-11-02")
    ])

    day = report(conn, "2026-11-02")
    assert day["credit"] == credit_row(110, %{}, 80)

    assert day["late_adjustments"]["credit"] ==
             late_adjustments([], %{"revoked_cents" => 30})["credit"]

    submit(conn, [
      cancel_rooms(["r1"], %{"group_id" => "target"}),
      reschedule(%{"group_id" => "target", "new_arrival_on" => "2026-11-10"}),
      cancel_rooms(["r3"], %{"group_id" => "target"}),
      close_period("2027-11-02")
    ])

    assert report(conn, "2026-11-02") == day
    assert report(conn, "2026-11-03")["credit"] == credit_row(80, %{}, 10)

    assert report(conn, "2026-11-03")["late_adjustments"] ==
             late_adjustments([], %{"absorbed_cents" => 20, "consumed_cents" => 50})

    assert Reservations.ledger(~D[2027-11-02]).credit_shortfall_cents == 5
    closed = report(conn, "2027-11-02")

    submit(conn, [
      reschedule(%{"group_id" => "target", "new_arrival_on" => "2028-06-01"}),
      cancellation(%{"group_id" => "target", "occurred_on" => "2027-11-02"})
    ])

    assert report(conn, "2027-11-03")["credit"] == credit_row(10, %{}, 0)

    assert report(conn, "2027-11-03")["late_adjustments"] ==
             late_adjustments([], %{"absorbed_cents" => 5, "expired_cents" => 5})

    assert report(conn, "2027-11-02") == closed
    assert Reservations.ledger(~D[2027-11-03]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2027-11-03]).credit_liability_cents == 0
  end

  defp issue_credit(conn) do
    submit(conn, [
      room_group("issuer", [100]),
      payment(%{"group_id" => "issuer", "operation_id" => "first", "amount_cents" => 50}),
      payment(%{"group_id" => "issuer", "operation_id" => "second", "amount_cents" => 50}),
      cancellation(%{"group_id" => "issuer", "refund_method" => "hotel_credit"})
    ])
  end

  defp future_group(id, deposits) do
    room_group(id, deposits, %{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"})
  end

  defp submit(conn, operations) do
    results =
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
    |> assert_balanced()
  end
end
