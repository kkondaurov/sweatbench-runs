defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    FinanceEntry,
    FinanceReporting,
    Group,
    Operation,
    Repo,
    Reservations
  }

  defp op(id, type, fields \\ %{}, on \\ "2027-01-01") do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => on}, fields)
  end

  defp opening(id, fields \\ %{}) do
    op(
      "open-#{id}",
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2030-06-01",
          "departure_on" => "2030-06-02",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "r0", "nightly_rate_cents" => 10000}]
        },
        fields
      )
    )
  end

  defp start(on \\ "2027-01-01"), do: op("start", "start_finance_reporting", %{"starts_on" => on})

  defp pay(id, group, amount, on \\ "2027-01-01"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount}, on)

  defp cancel(id, group, fields \\ %{}, on \\ "2027-01-01"),
    do: op(id, "cancel_group", Map.put(fields, "group_id", group), on)

  defp redeem(id, group, amount, on \\ "2027-01-01"),
    do: op(id, "apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount}, on)

  defp move(id, source, destination, amount, on \\ "2027-01-01"),
    do:
      op(
        id,
        "transfer_deposit",
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        on
      )

  defp charge(id, payment, on),
    do: op(id, "charge_back_payment", %{"payment_operation_id" => payment}, on)

  defp batch(conn, ops) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(conn, ops) do
    results = batch(conn, ops)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp report(conn, on) do
    data =
      conn
      |> get("/api/v1/finance/daily-report", %{"date" => on})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(data)) == ~w(cash credit date status)
    assert data["date"] == on
    assert data["status"] == "open"

    assert Enum.map(data["cash"], & &1["property_id"]) ==
             Enum.sort(Enum.map(data["cash"], & &1["property_id"]))

    for row <- data["cash"] do
      assert Enum.sort(Map.keys(row)) ==
               ~w(closing_held_cents movements opening_held_cents property_id)

      m = row["movements"]

      assert Enum.sort(Map.keys(m)) ==
               ~w(charged_back_cents converted_to_credit_cents received_cents reduced_cents refunded_cents retained_cents transferred_in_cents transferred_out_cents)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    assert Enum.sum(for row <- data["cash"], do: row["movements"]["transferred_in_cents"]) ==
             Enum.sum(for row <- data["cash"], do: row["movements"]["transferred_out_cents"])

    credit = data["credit"]

    assert Enum.sort(Map.keys(credit)) ==
             ~w(closing_liability_cents movements opening_liability_cents)

    m = credit["movements"]

    assert Enum.sort(Map.keys(m)) ==
             ~w(absorbed_cents consumed_cents expired_cents issued_cents revoked_cents)

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    data
  end

  defp cash(report, property), do: Enum.find(report["cash"], &(&1["property_id"] == property))

  defp zero_credit,
    do:
      Map.new(
        ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
        &{&1, 0}
      )

  defp reconcile(data, on) do
    ledger = Reservations.ledger(Date.from_iso8601!(on))

    assert Enum.sum(for row <- data["cash"], do: row["closing_held_cents"]) ==
             ledger.cash_held_cents

    assert data["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  test "equivalent batches and sequential submissions produce identical reports", %{conn: conn} do
    operations = [
      opening("issuer"),
      pay("p0", "issuer", 100),
      cancel("lot0", "issuer", %{"refund_method" => "hotel_credit"}),
      opening("a"),
      opening("b"),
      pay("p1", "a", 200, "2028-01-01"),
      start(),
      redeem("credit", "a", 110),
      move("transfer", "a", "b", 160),
      cancel("lot1", "b", %{"refund_method" => "hotel_credit"}),
      pay("rejected", "a", 99999),
      charge("charge", "p1", "2027-01-02")
    ]

    dates = ~w(2027-01-01 2027-01-02 2028-01-02 2029-01-01)

    {:error, expected} =
      Repo.transaction(fn ->
        results = batch(conn, operations)
        reports = Enum.map(dates, &report(conn, &1))
        Repo.rollback({results, reports})
      end)

    results = Enum.flat_map(operations, &batch(conn, [&1]))
    assert {results, Enum.map(dates, &report(conn, &1))} == expected
  end

  test "date validation, availability, exact start shape, durable rejection and retry", %{
    conn: conn
  } do
    for params <- [
          %{},
          %{"date" => "bad"},
          %{"date" => "2027-02-29"},
          %{"date" => ["2027-01-01"]}
        ] do
      assert conn |> get("/api/v1/finance/daily-report", params) |> json_response(422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end

    assert conn |> get("/api/v1/finance/daily-report?date=2027-01-01") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    for {value, index} <- Enum.with_index([nil, 1, true, [], %{}, "", "2027-02-29"]) do
      request = op("bad-#{index}", "start_finance_reporting", %{"starts_on" => value})
      assert [%{"code" => "invalid_reporting_date"} = result] = batch(conn, [request])
      assert batch(conn, [request]) == [result]
    end

    assert [%{"code" => "invalid_reporting_date"}] =
             batch(conn, [op("missing", "start_finance_reporting")])

    request = Map.put(start(), "expected_revision", "ignored")
    assert [result] = apply!(conn, [request])

    assert result == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-01"
           }

    assert batch(conn, [request]) == [result]
    assert conn |> get("/api/v1/operations/start") |> json_response(200) == %{"data" => result}
    assert [%{"code" => "operation_id_conflict"}] = batch(conn, [start("2027-01-02")])

    assert [%{"code" => "reporting_already_started"}] =
             batch(conn, [Map.put(start(), "operation_id", "second")])

    assert conn |> get("/api/v1/finance/daily-report?date=2026-12-31") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert report(conn, "2027-01-01")["cash"] == []
    assert report(conn, "2027-01-01")["credit"]["movements"] == zero_credit()
  end

  test "inception includes all earlier commits, even future dates, and clamps later postings", %{
    conn: conn
  } do
    apply!(conn, [opening("a"), pay("legacy", "a", 100, "2028-01-01")])
    Repo.delete_all(Operation)
    ops = [pay("before", "a", 200, "2028-01-01"), start(), pay("after", "a", 50, "2026-01-01")]
    results = apply!(conn, ops)
    first = report(conn, "2027-01-01")

    assert %{
             "opening_held_cents" => 300,
             "closing_held_cents" => 350,
             "movements" => %{"received_cents" => 50}
           } = cash(first, "a")

    reconcile(first, "2027-01-01")
    assert cash(report(conn, "2028-01-01"), "a")["movements"]["received_cents"] == 0
    assert batch(conn, ops) == results
    assert report(conn, "2027-01-01") == first
    apply!(conn, [pay("late", "a", 25, "2027-01-02"), pay("earlier", "a", 10, "2027-01-01")])
    assert cash(report(conn, "2027-01-01"), "a")["closing_held_cents"] == 360

    assert %{"opening_held_cents" => 360, "closing_held_cents" => 385} =
             cash(report(conn, "2027-01-02"), "a")
  end

  test "cash settlements, transfers and signed chargebacks follow each affected property", %{
    conn: conn
  } do
    apply!(conn, [
      start(),
      opening("s"),
      opening("refund"),
      opening("retain", %{"rate_plan" => "advance_purchase"}),
      opening("convert"),
      opening("unused"),
      pay("pay", "s", 500),
      move("t1", "s", "refund", 100),
      move("t2", "s", "retain", 100),
      move("t3", "s", "convert", 100),
      cancel("refund-c", "refund"),
      cancel("retain-c", "retain"),
      cancel("lot", "convert", %{"refund_method" => "hotel_credit"})
    ])

    first = report(conn, "2027-01-01")
    assert Enum.map(first["cash"], & &1["property_id"]) == ~w(convert refund retain s)
    assert cash(first, "s")["closing_held_cents"] == 200
    assert cash(first, "convert")["movements"]["converted_to_credit_cents"] == 100
    assert first["credit"]["movements"]["issued_cents"] == 110
    reconcile(first, "2027-01-01")

    apply!(conn, [
      op(
        "reduce",
        "reduce_cash_payment",
        %{"payment_operation_id" => "pay", "amount_cents" => 50},
        "2027-01-02"
      ),
      charge("charge", "pay", "2027-01-02")
    ])

    second = report(conn, "2027-01-02")

    for {property, field} <- [
          {"refund", "refunded_cents"},
          {"retain", "retained_cents"},
          {"convert", "converted_to_credit_cents"}
        ] do
      row = cash(second, property)
      assert row["movements"][field] == -100
      assert row["movements"]["charged_back_cents"] == 100
      assert row["closing_held_cents"] == 0
    end

    assert cash(second, "s")["movements"]["reduced_cents"] == 50
    assert cash(second, "s")["movements"]["charged_back_cents"] == 150
    assert second["credit"]["movements"]["revoked_cents"] == 110
    reconcile(second, "2027-01-02")
    assert report(conn, "2027-01-01") == first
    assert report(conn, "2027-01-03")["cash"] == []
  end

  test "corrections follow transferred held and settled cash from before inception", %{conn: conn} do
    rooms = for id <- ~w(r0 r1), do: %{"room_id" => id, "nightly_rate_cents" => 500}

    apply!(conn, [
      opening("s"),
      opening("d", %{"rooms" => rooms}),
      pay("pay", "s", 300),
      move("transfer", "s", "d", 200),
      op("refund", "cancel_rooms", %{"group_id" => "d", "room_ids" => ["r0"]}),
      start(),
      op("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 150
      })
    ])

    first = report(conn, "2027-01-01")

    assert %{
             "opening_held_cents" => 100,
             "closing_held_cents" => 0,
             "movements" => %{"reduced_cents" => 100, "transferred_in_cents" => 0}
           } = cash(first, "d")

    assert %{
             "opening_held_cents" => 100,
             "closing_held_cents" => 50,
             "movements" => %{"reduced_cents" => 50}
           } = cash(first, "s")

    reconcile(first, "2027-01-01")

    apply!(conn, [charge("charge", "pay", "2027-01-02")])
    second = report(conn, "2027-01-02")

    assert %{
             "opening_held_cents" => 0,
             "closing_held_cents" => 0,
             "movements" => %{"refunded_cents" => -100, "charged_back_cents" => 100}
           } = cash(second, "d")

    assert cash(second, "s")["movements"]["charged_back_cents"] == 50
    reconcile(second, "2027-01-02")
    assert report(conn, "2027-01-01") == first
  end

  test "same-property transfers retain both movement columns and credit transfers have none", %{
    conn: conn
  } do
    apply!(conn, [
      opening("issuer"),
      pay("issue-pay", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      opening("s", %{"property_id" => "hotel"}),
      opening("d", %{"property_id" => "hotel"}),
      pay("pay", "s", 100),
      redeem("credit", "s", 110),
      start(),
      move("credit-transfer", "s", "d", 110)
    ])

    first = report(conn, "2027-01-01")
    assert cash(first, "hotel")["movements"]["transferred_in_cents"] == 0
    apply!(conn, [move("cash-transfer", "s", "d", 100)])
    row = cash(report(conn, "2027-01-01"), "hotel")
    assert row["opening_held_cents"] == 100
    assert row["closing_held_cents"] == 100
    assert row["movements"]["transferred_in_cents"] == 100
    assert row["movements"]["transferred_out_cents"] == 100
    assert report(conn, "2027-01-01")["credit"]["movements"] == zero_credit()
  end

  test "expiry occurs on the next day, pauses while applied, and changes with late submissions",
       %{conn: conn} do
    apply!(conn, [
      start(),
      opening("issuer"),
      pay("pay", "issuer", 1000),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      opening("a"),
      opening("b"),
      opening("late"),
      redeem("a-credit", "a", 300),
      redeem("b-credit", "b", 100),
      cancel("restore", "b", %{}, "2027-12-31")
    ])

    assert report(conn, "2028-01-01")["credit"]["closing_liability_cents"] == 1100
    expiry = report(conn, "2028-01-02")

    assert expiry["credit"] == %{
             "opening_liability_cents" => 1100,
             "movements" => Map.put(zero_credit(), "expired_cents", 800),
             "closing_liability_cents" => 300
           }

    reconcile(expiry, "2028-01-02")
    apply!(conn, [redeem("late-credit", "late", 100, "2027-12-31")])
    assert report(conn, "2028-01-02")["credit"]["movements"]["expired_cents"] == 700
    apply!(conn, [cancel("expired-return", "a", %{}, "2028-01-03")])
    assert report(conn, "2028-01-03")["credit"]["movements"]["expired_cents"] == 300
    reconcile(report(conn, "2028-01-03"), "2028-01-03")

    snapshot =
      Enum.map(
        [Group, CreditLot, CreditAllocation, Operation, FinanceReporting, FinanceEntry],
        &Repo.all/1
      )

    reports = for day <- ~w(2028-01-03 2027-01-01 2028-01-02 2028-01-01), do: report(conn, day)

    assert Enum.reverse(
             for day <- ~w(2028-01-01 2028-01-02 2027-01-01 2028-01-03), do: report(conn, day)
           ) == reports

    assert Enum.map(
             [Group, CreditLot, CreditAllocation, Operation, FinanceReporting, FinanceEntry],
             &Repo.all/1
           ) == snapshot
  end

  test "inception includes applied expired credit and schedules only unexpired unused balances",
       %{conn: conn} do
    apply!(conn, [
      opening("issuer"),
      pay("pay", "issuer", 1000),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      opening("target"),
      redeem("applied", "target", 400),
      start("2028-01-02")
    ])

    data = report(conn, "2028-01-02")

    assert data["credit"] == %{
             "opening_liability_cents" => 400,
             "movements" => zero_credit(),
             "closing_liability_cents" => 400
           }

    apply!(conn, [cancel("return", "target", %{}, "2028-01-03")])
    assert report(conn, "2028-01-03")["credit"]["movements"]["expired_cents"] == 400
    reconcile(report(conn, "2028-01-03"), "2028-01-03")
  end

  test "shortfall absorption precedes expiry and consumption is reported independently", %{
    conn: conn
  } do
    rooms = [
      %{"room_id" => "r0", "nightly_rate_cents" => 4000},
      %{"room_id" => "r1", "nightly_rate_cents" => 4500}
    ]

    apply!(conn, [
      start(),
      opening("issuer"),
      pay("p1", "issuer", 1000),
      pay("p2", "issuer", 1000),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      opening("target", %{"rooms" => rooms}),
      redeem("redeem", "target", 1700),
      charge("charge", "p1", "2027-01-02")
    ])

    assert report(conn, "2027-01-02")["credit"]["movements"]["revoked_cents"] == 500
    assert Reservations.ledger(~D[2027-01-02]).credit_shortfall_cents == 600
    assert report(conn, "2028-01-02")["credit"]["movements"]["expired_cents"] == 0

    apply!(conn, [
      op("return", "cancel_rooms", %{"group_id" => "target", "room_ids" => ["r0"]}, "2028-01-03")
    ])

    data = report(conn, "2028-01-03")

    assert data["credit"]["movements"] ==
             Map.merge(zero_credit(), %{"absorbed_cents" => 600, "expired_cents" => 200})

    assert data["credit"]["closing_liability_cents"] == 900
    reconcile(data, "2028-01-03")
    apply!(conn, [cancel("consume", "target", %{}, "2030-05-31")])
    assert report(conn, "2030-05-31")["credit"]["movements"]["consumed_cents"] == 900
    reconcile(report(conn, "2030-05-31"), "2030-05-31")
  end

  test "revoking already expired unused credit does not remove liability twice", %{conn: conn} do
    apply!(conn, [
      start(),
      opening("issuer"),
      pay("pay", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"})
    ])

    expiry = report(conn, "2028-01-02")
    apply!(conn, [charge("charge", "pay", "2028-02-01")])
    assert report(conn, "2028-02-01")["credit"]["movements"] == zero_credit()
    assert report(conn, "2028-01-02") == expiry
    reconcile(report(conn, "2028-02-01"), "2028-02-01")
  end

  test "rejections and retries add no movements, and audit faults roll back reporting with domain state",
       %{conn: conn} do
    apply!(conn, [opening("s"), start()])
    payment = pay("pay", "s", 100)
    rejected = pay("rejected", "s", 5000)

    assert [result, %{"status" => "rejected"}, %{"status" => "applied"}] =
             batch(conn, [payment, rejected, pay("next", "s", 50)])

    before = report(conn, "2027-01-01")
    assert [^result, %{"status" => "rejected"}] = batch(conn, [payment, rejected])
    assert report(conn, "2027-01-01") == before

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(payment, "amount_cents", 1)])

    Repo.query!(
      "CREATE TRIGGER fail_finance BEFORE INSERT ON operations WHEN NEW.operation_id = 'fault' BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
    )

    fault = cancel("fault", "s", %{"refund_method" => "hotel_credit"})
    assert_raise Exqlite.Error, fn -> Reservations.apply_batch([fault]) end
    assert Reservations.get_operation("fault") == nil
    assert Repo.all(CreditLot) == []
    assert report(conn, "2027-01-01") == before
    Repo.query!("DROP TRIGGER fail_finance")
    apply!(conn, [fault])
    assert report(conn, "2027-01-01")["credit"]["movements"]["issued_cents"] == 165
  end
end
