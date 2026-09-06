defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{FinanceEntry, FinanceReporting, Repo, Reservations}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  defp op(id, type, fields \\ %{}, on \\ "2027-01-01"),
    do: Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => on}, fields)

  defp start, do: op("start", "start_finance_reporting", %{"starts_on" => "2027-01-01"})

  defp close(id, on), do: op(id, "close_finance_period", %{"period_end_on" => on})

  defp opening(id, plan \\ "flexible") do
    op("open-#{id}", "open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => id,
      "arrival_on" => "2030-06-01",
      "departure_on" => "2030-06-02",
      "rate_plan" => plan,
      "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
    })
  end

  defp pay(id, group, amount, on \\ "2027-01-01"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount}, on)

  defp cancel(id, group, method \\ "cash", on \\ "2027-01-01"),
    do: op(id, "cancel_group", %{"group_id" => group, "refund_method" => method}, on)

  defp redeem(id, group, amount, on \\ "2027-01-01"),
    do: op(id, "apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount}, on)

  defp move(id, destination, amount),
    do:
      op(id, "transfer_deposit", %{
        "source_group_id" => "source",
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp batch(conn, ops),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp apply!(conn, ops) do
    results = batch(conn, ops)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp zeroes(fields), do: Map.new(fields, &{&1, 0})
  defp cash(data, property), do: Enum.find(data["cash"], &(&1["property_id"] == property))

  defp late_cash(data, property),
    do: cash(data["late_adjustments"], property)["movements"] || zeroes(@cash_fields)

  defp sum(a, b), do: Map.merge(a, b, fn _, x, y -> x + y end)

  defp report(conn, on, status \\ "open") do
    data =
      conn
      |> get("/api/v1/finance/daily-report", %{"date" => on})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(data)) == ~w(cash credit date late_adjustments status)
    assert data["status"] == status
    assert data["date"] == on
    assert Enum.sort(Map.keys(data["late_adjustments"])) == ~w(cash credit)
    assert Enum.sort(Map.keys(data["late_adjustments"]["credit"])) == Enum.sort(@credit_fields)

    for rows <- [data["cash"], data["late_adjustments"]["cash"]] do
      ids = Enum.map(rows, & &1["property_id"])
      assert ids == Enum.sort(Enum.uniq(ids))

      for row <- rows,
          do: assert(Enum.sort(Map.keys(row["movements"])) == Enum.sort(@cash_fields))
    end

    for row <- data["late_adjustments"]["cash"] do
      assert Enum.sort(Map.keys(row)) == ~w(movements property_id)
      assert Enum.any?(row["movements"], fn {_, amount} -> amount != 0 end)
    end

    for row <- data["cash"] do
      m = sum(row["movements"], late_cash(data, row["property_id"]))

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    credit = data["credit"]
    m = sum(credit["movements"], data["late_adjustments"]["credit"])

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    data
  end

  defp reconcile(data) do
    ledger = Reservations.ledger(Date.from_iso8601!(data["date"]))
    assert Enum.sum(Enum.map(data["cash"], & &1["closing_held_cents"])) == ledger.cash_held_cents
    assert data["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  test "close validates the period, ignores revisions, and durably replays applied and rejected results",
       %{conn: conn} do
    request = close("early", "2027-01-01")
    assert [rejection = %{"code" => "invalid_period"}] = batch(conn, [request])
    apply!(conn, [start()])
    assert batch(conn, [request]) == [rejection]

    for {value, i} <- Enum.with_index([nil, true, 1, [], %{}, "", "2027-02-29", "2026-12-31"]) do
      assert [%{"code" => "invalid_period"}] = batch(conn, [close("bad-#{i}", value)])
    end

    assert [%{"code" => "invalid_period"}] = batch(conn, [op("missing", "close_finance_period")])

    request =
      close("close", "2027-01-01")
      |> Map.delete("occurred_on")
      |> Map.put("expected_revision", "ignored")

    assert [result] = apply!(conn, [request])

    assert result == %{
             "operation_id" => "close",
             "status" => "applied",
             "period_end_on" => "2027-01-01"
           }

    assert conn |> get("/api/v1/operations/close") |> json_response(200) == %{"data" => result}

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(request, "period_end_on", "2027-01-02")])

    for date <- ~w(2026-12-31 2027-01-01) do
      assert [%{"code" => "invalid_period"}] = batch(conn, [close("again-#{date}", date)])
    end

    apply!(conn, [close("next", "2027-01-03")])
    assert batch(conn, [request]) == [result]
    for date <- ~w(2027-01-01 2027-01-02 2027-01-03), do: report(conn, date, "closed")

    assert report(conn, "2027-01-04")["late_adjustments"] == %{
             "cash" => [],
             "credit" => zeroes(@credit_fields)
           }

    assert conn |> get("/api/v1/finance/daily-report?date=2026-12-31") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }
  end

  test "same-batch cutoffs separate ordinary and late movements and never move committed postings again",
       %{conn: conn} do
    ops = [
      start(),
      opening("a"),
      pay("before", "a", 100, "2026-12-01"),
      close("c1", "2027-01-02"),
      pay("late", "a", 50),
      pay("ordinary", "a", 30, "2027-01-03"),
      pay("future", "a", 20, "2027-01-05")
    ]

    results = apply!(conn, ops)
    first = report(conn, "2027-01-01", "closed")
    assert cash(first, "a")["movements"]["received_cents"] == 100
    second = report(conn, "2027-01-02", "closed")
    third = report(conn, "2027-01-03")
    assert cash(third, "a")["opening_held_cents"] == 100
    assert cash(third, "a")["closing_held_cents"] == 180
    assert cash(third, "a")["movements"]["received_cents"] == 30
    assert late_cash(third, "a")["received_cents"] == 50
    assert cash(report(conn, "2027-01-05"), "a")["movements"]["received_cents"] == 20
    entries = Repo.all(FinanceEntry)
    apply!(conn, [close("c2", "2027-01-04")])
    assert Repo.all(FinanceEntry) == entries
    assert report(conn, "2027-01-03", "closed") == Map.put(third, "status", "closed")
    apply!(conn, [pay("later", "a", 10, "2027-01-02")])
    assert report(conn, "2027-01-01", "closed") == first
    assert report(conn, "2027-01-02", "closed") == second
    assert batch(conn, ops) == results
    fifth = report(conn, "2027-01-05")
    assert cash(fifth, "a")["opening_held_cents"] == 180
    assert cash(fifth, "a")["movements"]["received_cents"] == 20
    assert late_cash(fifth, "a")["received_cents"] == 10
    reconcile(fifth)
  end

  test "late transfers, reductions and signed settlement reversals follow the cash's property", %{
    conn: conn
  } do
    apply!(conn, [
      start(),
      opening("source"),
      opening("refund"),
      opening("retain", "advance_purchase"),
      opening("convert"),
      pay("pay", "source", 500),
      move("t1", "refund", 100),
      move("t2", "retain", 100),
      move("t3", "convert", 100),
      cancel("refund", "refund"),
      cancel("retain", "retain"),
      cancel("lot", "convert", "hotel_credit"),
      close("close", "2027-01-01")
    ])

    published = report(conn, "2027-01-01", "closed") |> Jason.encode!()

    apply!(conn, [
      opening("destination"),
      move("late-transfer", "destination", 100),
      op("reduce", "reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 50}),
      op("charge", "charge_back_payment", %{"payment_operation_id" => "pay"})
    ])

    data = report(conn, "2027-01-02")

    for {property, field} <- [
          {"refund", "refunded_cents"},
          {"retain", "retained_cents"},
          {"convert", "converted_to_credit_cents"}
        ] do
      assert late_cash(data, property)[field] == -100
      assert late_cash(data, property)["charged_back_cents"] == 100
      assert cash(data, property)["movements"] == zeroes(@cash_fields)
      assert cash(data, property)["closing_held_cents"] == 0
    end

    assert late_cash(data, "source")["transferred_out_cents"] == 100
    assert late_cash(data, "destination")["transferred_in_cents"] == 100
    assert late_cash(data, "destination")["reduced_cents"] == 50
    assert late_cash(data, "destination")["charged_back_cents"] == 50
    assert data["credit"]["movements"] == zeroes(@credit_fields)
    assert data["late_adjustments"]["credit"]["revoked_cents"] == 110
    assert report(conn, "2027-01-01", "closed") |> Jason.encode!() == published
    reconcile(data)

    assert {:ok, %{charged_back_cents: 450, reduced_cents: 50, held_by_group: []}} =
             Reservations.get_payment("pay")
  end

  test "closed expiry is stable when backdated credit is redeemed and restored", %{conn: conn} do
    apply!(conn, [
      start(),
      opening("issuer"),
      opening("target"),
      pay("pay", "issuer", 1000),
      cancel("lot", "issuer", "hotel_credit"),
      close("close", "2028-01-02")
    ])

    expiry = report(conn, "2028-01-02", "closed")
    assert expiry["credit"]["movements"]["expired_cents"] == 1100
    apply!(conn, [redeem("redeem", "target", 400, "2027-12-31")])
    data = report(conn, "2028-01-03")
    assert data["credit"]["movements"] == zeroes(@credit_fields)
    assert data["late_adjustments"]["credit"]["expired_cents"] == -400
    assert data["credit"]["closing_liability_cents"] == 400
    reconcile(data)
    apply!(conn, [close("next", "2028-01-03"), cancel("restore", "target", "cash", "2027-12-31")])
    restored = report(conn, "2028-01-04")
    assert restored["late_adjustments"]["credit"]["expired_cents"] == 400
    reconcile(restored)
    assert report(conn, "2028-01-02", "closed") == expiry
    assert report(conn, "2028-01-03", "closed") == Map.put(data, "status", "closed")
  end

  test "late credit issuance and redemption leave future automatic expiry ordinary", %{conn: conn} do
    apply!(conn, [
      start(),
      opening("issuer"),
      opening("target"),
      pay("pay", "issuer", 1000),
      close("close", "2027-01-01"),
      cancel("lot", "issuer", "hotel_credit"),
      redeem("redeem", "target", 400)
    ])

    data = report(conn, "2027-01-02")
    assert data["late_adjustments"]["credit"]["issued_cents"] == 1100
    assert data["late_adjustments"]["credit"]["expired_cents"] == 0
    reconcile(data)
    expiry = report(conn, "2028-01-02")
    assert expiry["credit"]["movements"]["expired_cents"] == 700
    assert expiry["late_adjustments"]["credit"] == zeroes(@credit_fields)
    reconcile(expiry)
    apply!(conn, [close("next", "2028-01-02")])
    assert report(conn, "2028-01-02", "closed") == Map.put(expiry, "status", "closed")
  end

  test "issuance already expired in the open period retains both late classifications", %{
    conn: conn
  } do
    apply!(conn, [
      start(),
      opening("issuer"),
      pay("pay", "issuer", 100),
      close("close", "2028-02-01"),
      cancel("lot", "issuer", "hotel_credit")
    ])

    data = report(conn, "2028-02-02")

    assert data["late_adjustments"]["credit"] ==
             Map.merge(zeroes(@credit_fields), %{"issued_cents" => 110, "expired_cents" => 110})

    reconcile(data)
    apply!(conn, [op("charge", "charge_back_payment", %{"payment_operation_id" => "pay"})])

    assert report(conn, "2028-02-02")["late_adjustments"]["credit"] ==
             data["late_adjustments"]["credit"]

    reconcile(report(conn, "2028-02-02"))
  end

  test "late shortfall absorption and nonrefundable consumption keep their classifications", %{
    conn: conn
  } do
    apply!(conn, [
      start(),
      opening("issuer"),
      opening("return"),
      opening("consume", "advance_purchase"),
      pay("pay", "issuer", 1000),
      cancel("lot", "issuer", "hotel_credit"),
      redeem("r1", "return", 600),
      redeem("r2", "consume", 400),
      close("close", "2027-01-01"),
      op("charge", "charge_back_payment", %{"payment_operation_id" => "pay"}),
      cancel("return", "return"),
      cancel("consume", "consume")
    ])

    data = report(conn, "2027-01-02")

    assert data["late_adjustments"]["credit"] ==
             Map.merge(zeroes(@credit_fields), %{
               "revoked_cents" => 100,
               "absorbed_cents" => 600,
               "consumed_cents" => 400
             })

    reconcile(data)
    assert report(conn, "2028-01-02")["credit"]["movements"]["expired_cents"] == 0
  end

  test "failed close audit rolls back cutoff; rejected operations and retries add no entries", %{
    conn: conn
  } do
    apply!(conn, [start(), opening("a"), pay("pay", "a", 100)])
    before = report(conn, "2027-01-01")

    Repo.query!(
      "CREATE TRIGGER fail_close BEFORE INSERT ON operations WHEN NEW.operation_id = 'close' BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
    )

    assert_raise Exqlite.Error, fn -> Reservations.apply_batch([close("close", "2027-01-01")]) end
    assert Repo.get!(FinanceReporting, 1).closed_through == nil
    assert Reservations.get_operation("close") == nil
    assert report(conn, "2027-01-01") == before
    Repo.query!("DROP TRIGGER fail_close")
    apply!(conn, [close("close", "2027-01-01")])
    ops = [pay("late", "a", 50), pay("bad", "a", 9000), pay("next", "a", 25)]

    assert [%{"status" => "applied"}, %{"status" => "rejected"}, %{"status" => "applied"}] =
             results = batch(conn, ops)

    data = report(conn, "2027-01-02")
    entries = Repo.all(FinanceEntry)
    assert late_cash(data, "a")["received_cents"] == 75
    assert batch(conn, ops) == results
    assert Repo.all(FinanceEntry) == entries
    assert report(conn, "2027-01-02") == data
    assert report(conn, "2027-01-01", "closed") == Map.put(before, "status", "closed")
  end

  test "batches and sequential operations agree, and reading closed and open reports is pure", %{
    conn: conn
  } do
    operations = [
      start(),
      opening("issuer"),
      opening("target"),
      pay("pay", "issuer", 100),
      cancel("lot", "issuer", "hotel_credit"),
      close("first", "2027-01-01"),
      redeem("redeem", "target", 40),
      close("second", "2028-01-02"),
      cancel("restore", "target"),
      pay("rejected", "target", 1)
    ]

    dates = [
      {"2027-01-01", "closed"},
      {"2027-01-02", "closed"},
      {"2028-01-02", "closed"},
      {"2028-01-03", "open"}
    ]

    read = fn -> Enum.map(dates, fn {on, status} -> report(conn, on, status) end) end

    {:error, expected} =
      Repo.transaction(fn ->
        results = batch(conn, operations)
        Repo.rollback({results, read.()})
      end)

    results = Enum.flat_map(operations, &batch(conn, [&1]))
    assert {results, read.()} == expected

    snapshot = fn ->
      Enum.map(
        [
          GroupStay.Group,
          GroupStay.CashAllocation,
          GroupStay.CreditAllocation,
          GroupStay.CreditLot,
          GroupStay.CreditEntitlement,
          GroupStay.Operation,
          FinanceReporting,
          FinanceEntry
        ],
        &Repo.all/1
      )
    end

    before = snapshot.()
    reports = read.()

    assert Enum.map(Enum.reverse(dates), fn {on, status} -> report(conn, on, status) end) ==
             Enum.reverse(reports)

    assert read.() == reports
    assert snapshot.() == before
    reconcile(List.last(reports))
  end
end
