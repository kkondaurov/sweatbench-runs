defmodule GroupStayWeb.FinanceCreditReportTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers
  import GroupStay.FinanceHelpers

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.Entry

  test "issuance, redemption and restoration schedule expiry without read-side effects", %{
    conn: conn
  } do
    submit(conn, [start_reporting()])
    issue_credit(conn)

    submit(conn, [
      future_group("target", [20, 60]),
      credit_payment(%{
        "group_id" => "target",
        "amount_cents" => 80,
        "occurred_on" => "2026-11-02"
      }),
      cancel_rooms(["r1"], %{"group_id" => "target", "occurred_on" => "2026-11-03"})
    ])

    assert report(conn, "2026-11-01")["credit"] == credit_row(0, %{"issued_cents" => 110}, 110)
    assert report(conn, "2026-11-02")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2026-11-03")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2027-11-01")["credit"] == credit_row(110, %{}, 110)

    before = {domain_snapshot(), Repo.all(Entry)}
    expiry = report(conn, "2027-11-02")
    assert expiry["credit"] == credit_row(110, %{"expired_cents" => 50}, 60)
    assert report(conn, "2027-11-03")["credit"] == credit_row(60, %{}, 60)
    assert report(conn, "2027-11-02") == expiry
    assert {domain_snapshot(), Repo.all(Entry)} == before
    assert_reconciles(conn, "2027-11-03")

    submit(conn, [cancellation(%{"group_id" => "target", "occurred_on" => "2027-11-03"})])
    assert report(conn, "2027-11-03")["credit"] == credit_row(60, %{"expired_cents" => 60}, 0)
    assert report(conn, "2027-11-02") == expiry
    assert_reconciles(conn, "2027-11-03")
  end

  test "revocation, non-refundable consumption and shortfall absorption have distinct movements",
       %{conn: conn} do
    submit(conn, [start_reporting()])
    issue_credit(conn)

    submit(conn, [
      future_group("target", [20, 10, 50]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80}),
      charge_back("first", %{"occurred_on" => "2026-11-02"}),
      cancel_rooms(["r1"], %{"group_id" => "target", "occurred_on" => "2026-11-03"}),
      reschedule(%{
        "group_id" => "target",
        "occurred_on" => "2026-11-03",
        "new_arrival_on" => "2026-11-10"
      }),
      cancel_rooms(["r3"], %{"group_id" => "target", "occurred_on" => "2026-11-04"})
    ])

    assert report(conn, "2026-11-02")["credit"] == credit_row(110, %{"revoked_cents" => 30}, 80)
    assert report(conn, "2026-11-03")["credit"] == credit_row(80, %{"absorbed_cents" => 20}, 60)
    assert report(conn, "2026-11-04")["credit"] == credit_row(60, %{"consumed_cents" => 50}, 10)
    assert Reservations.ledger(~D[2026-11-04]).credit_shortfall_cents == 5

    submit(conn, [
      reschedule(%{
        "group_id" => "target",
        "new_arrival_on" => "2028-06-01",
        "occurred_on" => "2026-11-05"
      }),
      cancellation(%{"group_id" => "target", "occurred_on" => "2027-11-02"})
    ])

    assert report(conn, "2027-11-02")["credit"] ==
             credit_row(10, %{"absorbed_cents" => 5, "expired_cents" => 5}, 0)

    assert_reconciles(conn, "2027-11-02")
  end

  test "restoration extinguishes shortfall before scheduling any available excess", %{conn: conn} do
    submit(conn, [start_reporting()])
    issue_credit(conn)

    submit(conn, [
      future_group("target", [80]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80}),
      charge_back("first"),
      cancellation(%{"group_id" => "target", "occurred_on" => "2026-11-02"})
    ])

    assert report(conn, "2026-11-02")["credit"] == credit_row(80, %{"absorbed_cents" => 25}, 55)
    assert report(conn, "2027-11-02")["credit"] == credit_row(55, %{"expired_cents" => 55}, 0)
    assert_reconciles(conn, "2027-11-02")
  end

  test "inception excludes expired unused credit and includes credit with paused expiry and shortfall",
       %{conn: conn} do
    issue_credit(conn)

    submit(conn, [
      future_group("target", [80]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80}),
      start_reporting("2027-11-02")
    ])

    assert report(conn, "2027-11-02")["credit"] == credit_row(80, %{}, 80)

    # Removing already expired unspent credit does not revoke liability again.
    submit(conn, [charge_back("first", %{"occurred_on" => "2027-11-02"})])
    assert report(conn, "2027-11-02")["credit"] == credit_row(80, %{}, 80)
    assert Reservations.ledger(~D[2027-11-02]).credit_shortfall_cents == 25

    submit(conn, [cancellation(%{"group_id" => "target", "occurred_on" => "2027-11-02"})])

    assert report(conn, "2027-11-02")["credit"] ==
             credit_row(80, %{"absorbed_cents" => 25, "expired_cents" => 55}, 0)

    assert_reconciles(conn, "2027-11-02")
  end

  test "opening unused credit expires on its original date and leap days follow calendar days", %{
    conn: conn
  } do
    submit(conn, [
      future_group("source", [100]),
      payment(%{"group_id" => "source", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "source",
        "refund_method" => "hotel_credit",
        "occurred_on" => "2027-03-01"
      }),
      start_reporting("2027-04-01")
    ])

    assert report(conn, "2027-04-01")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2028-02-29")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2028-03-01")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    assert_reconciles(conn, "2028-03-01")
  end

  test "mixed transfers report only cash and transferred credit keeps its original expiry", %{
    conn: conn
  } do
    issue_credit(conn)

    submit(conn, [
      future_group("source", [100]),
      future_group("target", [100], %{"property_id" => "berlin"}),
      payment(%{"group_id" => "source", "operation_id" => "cash", "amount_cents" => 40}),
      credit_payment(%{"group_id" => "source", "amount_cents" => 60}),
      start_reporting(),
      transfer("source", "target", 80)
    ])

    day = report(conn, "2026-11-01")

    assert day["cash"] == [
             cash_row("ams-canal", 40, %{"transferred_out_cents" => 20}, 20),
             cash_row("berlin", 0, %{"transferred_in_cents" => 20}, 20)
           ]

    assert day["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 50}, 60)

    submit(conn, [
      cancellation(%{
        "group_id" => "target",
        "occurred_on" => "2027-11-03",
        "refund_method" => "hotel_credit"
      })
    ])

    assert report(conn, "2027-11-03")["credit"] ==
             credit_row(60, %{"issued_cents" => 22, "expired_cents" => 60}, 22)

    assert_reconciles(conn, "2027-11-03")
  end

  test "backdated issuance and redemption clamp expiry effects to inception", %{conn: conn} do
    submit(conn, [start_reporting("2027-11-03")])
    issue_credit(conn)

    assert report(conn, "2027-11-03")["credit"] ==
             credit_row(0, %{"issued_cents" => 110, "expired_cents" => 110}, 0)

    submit(conn, [
      future_group("target", [80]),
      credit_payment(%{"group_id" => "target", "amount_cents" => 80})
    ])

    assert report(conn, "2027-11-03")["credit"] ==
             credit_row(0, %{"issued_cents" => 110, "expired_cents" => 30}, 80)

    assert_reconciles(conn, "2027-11-03")

    submit(conn, [cancellation(%{"group_id" => "target"})])

    assert report(conn, "2027-11-03")["credit"] ==
             credit_row(0, %{"issued_cents" => 110, "expired_cents" => 110}, 0)

    assert_reconciles(conn, "2027-11-03")
  end

  test "a backdated redemption updates an already read expiry day without double expiry", %{
    conn: conn
  } do
    submit(conn, [start_reporting()])
    issue_credit(conn)
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)

    submit(conn, [
      future_group("target", [80]),
      credit_payment(%{
        "group_id" => "target",
        "amount_cents" => 80,
        "occurred_on" => "2027-11-01"
      })
    ])

    assert report(conn, "2027-11-01")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 30}, 80)

    submit(conn, [charge_back("first", %{"occurred_on" => "2027-11-03"})])
    assert report(conn, "2027-11-03")["credit"] == credit_row(80, %{}, 80)
    assert_reconciles(conn, "2027-11-03")
  end

  defp issue_credit(conn) do
    submit(conn, [
      room_group("issuer", [100]),
      payment(%{"group_id" => "issuer", "operation_id" => "first", "amount_cents" => 50}),
      payment(%{"group_id" => "issuer", "operation_id" => "second", "amount_cents" => 50}),
      cancellation(%{"group_id" => "issuer", "refund_method" => "hotel_credit"})
    ])
  end

  defp future_group(id, deposits, attributes \\ %{}) do
    room_group(
      id,
      deposits,
      Map.merge(%{"arrival_on" => "2028-06-01", "departure_on" => "2028-06-02"}, attributes)
    )
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

  defp assert_reconciles(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end
end
