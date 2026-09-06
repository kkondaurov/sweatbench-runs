defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerFixtures
  alias GroupStay.{FinanceReporting, Repo, Reservations}
  alias GroupStay.FinanceReporting.{Entry, Inception}
  alias GroupStay.Reservations.Payments

  @cash_in ~w(received_cents transferred_in_cents)
  @cash_out ~w(transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_out ~w(expired_cents consumed_cents revoked_cents absorbed_cents)

  test "close validates periods, ignores group guards, and durably remembers applied and rejected results",
       %{conn: conn} do
    premature = close("2026-11-01")
    rejected = submit(conn, premature)
    assert rejected["code"] == "invalid_period"
    apply!(conn, start())
    assert submit(conn, premature) == rejected

    for value <- [nil, "", "2026-02-30", "2026-10-31", 20_261_101, [], %{}, "10000-01-01"] do
      assert submit(conn, close(value))["code"] == "invalid_period"
    end

    assert submit(conn, Map.delete(close(), "period_end_on"))["code"] == "invalid_period"
    assert Repo.get!(Inception, 1).closed_through_on == nil

    close = Map.merge(close(), %{"group_id" => "missing", "expected_revision" => -1})

    expected = %{
      "operation_id" => close["operation_id"],
      "status" => "applied",
      "period_end_on" => "2026-11-01"
    }

    assert apply!(conn, close) == expected
    assert apply!(conn, close) == expected

    assert submit(conn, Map.put(close, "period_end_on", "2026-11-02"))["code"] ==
             "operation_id_conflict"

    assert submit(conn, close())["code"] == "invalid_period"
    assert submit(conn, close("2026-10-31"))["code"] == "invalid_period"

    assert get(conn, "/api/v1/operations/#{close["operation_id"]}") |> json_response(200) == %{
             "data" => expected
           }

    assert report(conn, "2026-11-01") == empty_report("2026-11-01", "closed")
    assert report(conn, "2026-11-02") == empty_report("2026-11-02", "open")

    assert get(conn, "/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) == %{
             "error" => %{"code" => "report_not_available"}
           }

    assert Repo.all(Entry) == []
  end

  test "batch order fixes posting dates and later closes preserve all published bytes", %{
    conn: conn
  } do
    prior = op("record_cash_payment", "g", "2026-10-01", %{"amount_cents" => 100})
    late = op("record_cash_payment", "g", "2026-10-01", %{"amount_cents" => 50})
    ordinary = op("record_cash_payment", "g", "2026-11-05", %{"amount_cents" => 25})
    operations = [opening("g", "p"), start(), prior, close("2026-11-02"), late, ordinary]
    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    published = published_bytes(conn, ~w(2026-11-01 2026-11-02))
    assert report(conn, "2026-11-01")["cash"] == [cash("p", 0, 100, %{"received_cents" => 100})]
    third = report(conn, "2026-11-03")
    assert third["cash"] == [cash("p", 100, 150)]
    assert third["late_adjustments"] == adjustments([{"p", %{"received_cents" => 50}}])
    assert report(conn, "2026-11-05")["cash"] == [cash("p", 150, 175, %{"received_cents" => 25})]
    assert report(conn, "2026-11-05")["late_adjustments"] == adjustments()

    apply!(conn, close("2026-11-03"))
    assert report(conn, "2026-11-03") == Map.put(third, "status", "closed")
    third_bytes = published_bytes(conn, ["2026-11-03"])
    apply!(conn, op("record_cash_payment", "g", "2026-11-01", %{"amount_cents" => 20}))

    assert report(conn, "2026-11-04")["late_adjustments"] ==
             adjustments([{"p", %{"received_cents" => 20}}])

    assert report(conn, "2026-11-05")["cash"] == [cash("p", 170, 195, %{"received_cents" => 25})]
    apply!(conn, close("2026-11-06"))
    before = reporting_state()
    assert batch(conn, operations) == results
    assert reporting_state() == before
    assert published_bytes(conn, ~w(2026-11-01 2026-11-02)) == published
    assert published_bytes(conn, ["2026-11-03"]) == third_bytes
    assert_reconciles(conn, "2026-11-07")
    assert Reservations.get_group("g").revision == 5
  end

  test "late reductions and chargebacks follow every property and preserve zero-net signed classifications",
       %{conn: conn} do
    apply!(conn, start())

    for {id, property} <- [
          {"source", "a"},
          {"refund", "b"},
          {"convert", "d"},
          {"held", "e"},
          {"user", "z"}
        ],
        do: apply!(conn, opening(id, property))

    apply!(conn, opening("retain", "c", %{"rate_plan" => "advance_purchase"}))
    payment = op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 500})
    original = apply!(conn, payment)
    apply!(conn, target("reduce_cash_payment", payment, "2026-11-01", %{"amount_cents" => 50}))
    for id <- ~w(refund retain convert held), do: apply!(conn, transfer("source", id, 100))
    for id <- ~w(refund retain), do: apply!(conn, op("cancel_group", id, "2026-11-02"))

    apply!(
      conn,
      op("cancel_group", "convert", "2026-11-02", %{"refund_method" => "hotel_credit"})
    )

    apply!(conn, op("apply_hotel_credit", "user", "2026-11-02", %{"amount_cents" => 80}))
    apply!(conn, close("2026-11-02"))
    published = published_bytes(conn, ~w(2026-11-01 2026-11-02))

    apply!(conn, target("reduce_cash_payment", payment, "2026-11-01", %{"amount_cents" => 75}))
    chargeback = target("charge_back_payment", payment, "2026-11-02")
    assert apply!(conn, chargeback)["charged_back_cents"] == 375
    apply!(conn, op("record_cash_payment", "held", "2026-11-03", %{"amount_cents" => 25}))
    daily = report(conn, "2026-11-03")

    assert daily["cash"] == [
             cash("a", 50, 0),
             cash("b", 0, 0),
             cash("c", 0, 0),
             cash("d", 0, 0),
             cash("e", 100, 25, %{"received_cents" => 25})
           ]

    assert daily["credit"] == credit(110, 80)

    assert daily["late_adjustments"] ==
             adjustments(
               [
                 {"a", %{"charged_back_cents" => 50}},
                 {"b", %{"refunded_cents" => -100, "charged_back_cents" => 100}},
                 {"c", %{"retained_cents" => -100, "charged_back_cents" => 100}},
                 {"d", %{"converted_to_credit_cents" => -100, "charged_back_cents" => 100}},
                 {"e", %{"reduced_cents" => 75, "charged_back_cents" => 25}}
               ],
               %{"revoked_cents" => 30}
             )

    assert_reconciles(conn, "2026-11-03")
    assert apply!(conn, payment) == original
    apply!(conn, chargeback)
    assert report(conn, "2026-11-03") == daily

    assert {:ok, %{held_cents: 0, reduced_cents: 125, charged_back_cents: 375, held_by_group: []}} =
             Payments.statement(payment["operation_id"])

    apply!(conn, op("cancel_group", "user", "2026-11-01"))

    assert report(conn, "2026-11-03")["late_adjustments"]["credit"] ==
             credit_movements(%{"revoked_cents" => 30, "absorbed_cents" => 80})

    assert published_bytes(conn, ~w(2026-11-01 2026-11-02)) == published
    assert_reconciles(conn, "2026-11-03")
  end

  test "late mixed transfers and same-property transfers change reporting but no ledger totals",
       %{conn: conn} do
    seed_credit(conn, "seed")

    for {id, property} <- [{"source", "a"}, {"same", "a"}, {"destination", "b"}],
        do: apply!(conn, opening(id, property))

    apply!(conn, op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 100}))
    apply!(conn, op("apply_hotel_credit", "source", "2026-11-01", %{"amount_cents" => 80}))
    apply!(conn, start())
    apply!(conn, close())
    before = Reservations.ledger(~D[2026-11-02])
    apply!(conn, transfer("source", "destination", 100))
    apply!(conn, transfer("source", "same", 30))
    daily = report(conn, "2026-11-02")
    assert daily["cash"] == [cash("a", 100, 80), cash("b", 0, 20)]
    assert daily["credit"] == credit(110, 110)

    assert daily["late_adjustments"] ==
             adjustments([
               {"a", %{"transferred_in_cents" => 30, "transferred_out_cents" => 50}},
               {"b", %{"transferred_in_cents" => 20}}
             ])

    assert Reservations.ledger(~D[2026-11-02]) == before
    assert_reconciles(conn, "2026-11-02")
  end

  test "closed natural expiry is corrected only in the open period by backdated credit use and restoration",
       %{conn: conn} do
    seed_credit(conn, "seed")
    apply!(conn, opening("user", "p"))
    apply!(conn, start("2027-11-01"))
    apply!(conn, close("2027-11-02"))
    published = published_bytes(conn, ~w(2027-11-01 2027-11-02))
    assert report(conn, "2027-11-02")["credit"] == credit(110, 0, %{"expired_cents" => 110})
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-01", %{"amount_cents" => 80}))
    assert report(conn, "2027-11-03")["credit"] == credit(0, 80)

    assert report(conn, "2027-11-03")["late_adjustments"] ==
             adjustments([], %{"expired_cents" => -80})

    assert_reconciles(conn, "2027-11-03")
    apply!(conn, close("2027-11-03"))
    applied_bytes = published_bytes(conn, ["2027-11-03"])
    apply!(conn, op("cancel_group", "user", "2026-11-02"))
    assert report(conn, "2027-11-04")["credit"] == credit(80, 0)

    assert report(conn, "2027-11-04")["late_adjustments"] ==
             adjustments([], %{"expired_cents" => 80})

    assert published_bytes(conn, ~w(2027-11-01 2027-11-02)) == published
    assert published_bytes(conn, ["2027-11-03"]) == applied_bytes
    assert_reconciles(conn, "2027-11-04")
  end

  test "late issuance is separate from unchanged future natural expiry, including expiry on the first open day",
       %{conn: conn} do
    apply!(conn, start())
    apply!(conn, close())
    seed_credit(conn, "seed")

    assert report(conn, "2026-11-02")["late_adjustments"] ==
             adjustments(
               [
                 {"seed-property", %{"received_cents" => 100, "converted_to_credit_cents" => 100}}
               ],
               %{"issued_cents" => 110}
             )

    assert report(conn, "2027-11-02")["credit"] == credit(110, 0, %{"expired_cents" => 110})
    assert report(conn, "2027-11-02")["late_adjustments"] == adjustments()
    apply!(conn, opening("user", "p"))
    apply!(conn, close("2027-11-01"))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-01", %{"amount_cents" => 80}))
    assert report(conn, "2027-11-02")["credit"] == credit(110, 80, %{"expired_cents" => 30})
    assert report(conn, "2027-11-02")["late_adjustments"] == adjustments()
    assert_reconciles(conn, "2027-11-02")
  end

  test "late already-expired issuance reports both issue and expiry and never changes a closed day",
       %{conn: conn} do
    apply!(conn, start())
    apply!(conn, close("2027-11-02"))
    before = published_bytes(conn, ~w(2026-11-01 2027-11-02))
    seed_credit(conn, "seed")
    assert report(conn, "2027-11-03")["credit"] == credit(0, 0)

    assert report(conn, "2027-11-03")["late_adjustments"]["credit"] ==
             credit_movements(%{"issued_cents" => 110, "expired_cents" => 110})

    assert published_bytes(conn, ~w(2026-11-01 2027-11-02)) == before
    assert_reconciles(conn, "2027-11-03")
  end

  test "late restoration splits shortfall absorption and expired excess", %{conn: conn} do
    apply!(conn, start())
    apply!(conn, opening("seed", "p"))
    apply!(conn, opening("user", "p"))
    first = op("record_cash_payment", "seed", "2026-11-01", %{"amount_cents" => 50})
    apply!(conn, first)
    apply!(conn, op("record_cash_payment", "seed", "2026-11-01", %{"amount_cents" => 50}))
    apply!(conn, op("cancel_group", "seed", "2026-11-01", %{"refund_method" => "hotel_credit"}))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-02", %{"amount_cents" => 80}))
    apply!(conn, target("charge_back_payment", first, "2026-11-03"))
    apply!(conn, close("2027-11-03"))
    before = published_bytes(conn, ~w(2026-11-03 2027-11-02 2027-11-03))
    apply!(conn, op("cancel_group", "user", "2027-11-03"))
    assert report(conn, "2027-11-04")["credit"] == credit(80, 0)

    assert report(conn, "2027-11-04")["late_adjustments"] ==
             adjustments([], %{"absorbed_cents" => 25, "expired_cents" => 55})

    assert published_bytes(conn, ~w(2026-11-03 2027-11-02 2027-11-03)) == before
    assert_reconciles(conn, "2027-11-04")
  end

  test "late nonrefundable consumption and expired chargebacks preserve expiry and current liability",
       %{conn: conn} do
    apply!(conn, start())
    payment = seed_credit(conn, "seed")
    apply!(conn, opening("user", "p", %{"rate_plan" => "advance_purchase"}))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-01", %{"amount_cents" => 80}))
    apply!(conn, close("2027-11-02"))
    before = published_bytes(conn, ["2027-11-02"])
    apply!(conn, target("charge_back_payment", payment, "2026-11-01"))
    assert report(conn, "2027-11-03")["late_adjustments"]["credit"] == credit_movements()
    apply!(conn, op("cancel_group", "user", "2026-11-02"))

    assert report(conn, "2027-11-03")["late_adjustments"]["credit"] ==
             credit_movements(%{"consumed_cents" => 80})

    assert report(conn, "2027-11-03")["credit"] == credit(80, 0)
    assert published_bytes(conn, ["2027-11-02"]) == before
    assert_reconciles(conn, "2027-11-03")
  end

  test "handled rejections leave no late movement and report reads never write state", %{
    conn: conn
  } do
    seed_credit(conn, "seed")
    apply!(conn, opening("user", "p"))
    apply!(conn, start())
    apply!(conn, close())
    failed = op("apply_hotel_credit", "user", "2026-11-01", %{"amount_cents" => 150})
    before = reporting_state()
    assert submit(conn, failed)["code"] == "insufficient_credit"
    assert reporting_state() == before
    applied = op("record_cash_payment", "user", "2026-11-01", %{"amount_cents" => 50})

    assert [
             %{"status" => "applied"},
             %{"code" => "invalid_period"},
             %{"code" => "insufficient_credit"}
           ] = batch(conn, [applied, close(), failed])

    assert report(conn, "2026-11-02")["late_adjustments"] ==
             adjustments([{"p", %{"received_cents" => 50}}])

    before = reporting_state()
    for date <- ~w(2027-11-02 2026-11-01 2026-11-02 2028-01-01 2026-11-01), do: report(conn, date)
    assert reporting_state() == before
    assert_reconciles(conn, "2027-11-02")
  end

  test "closing the final calendar date preserves reports and still allows current-state operations",
       %{conn: conn} do
    apply!(conn, opening("g", "p"))
    apply!(conn, start())
    apply!(conn, close("9999-12-31"))
    before = published_bytes(conn, ~w(2026-11-01 9999-12-31))
    apply!(conn, op("record_cash_payment", "g", "2026-11-01", %{"amount_cents" => 100}))
    apply!(conn, op("cancel_group", "g", "2026-11-01", %{"refund_method" => "hotel_credit"}))
    assert published_bytes(conn, ~w(2026-11-01 9999-12-31)) == before
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
  end

  defp opening(id, property, overrides \\ %{}),
    do:
      open_operation(
        Map.merge(
          %{
            "group_id" => id,
            "property_id" => property,
            "arrival_on" => "2028-12-01",
            "departure_on" => "2028-12-02",
            "rooms" => for(i <- 1..5, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
          },
          overrides
        )
      )

  defp op(type, group, date, overrides \\ %{}),
    do: operation(type, Map.merge(%{"group_id" => group, "occurred_on" => date}, overrides))

  defp start(date \\ "2026-11-01"),
    do: %{
      "operation_id" => unique_operation_id(),
      "type" => "start_finance_reporting",
      "starts_on" => date
    }

  defp close(date \\ "2026-11-01"),
    do: %{
      "operation_id" => unique_operation_id(),
      "type" => "close_finance_period",
      "period_end_on" => date
    }

  defp transfer(source, destination, amount),
    do:
      op("transfer_deposit", source, "2026-11-01", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp target(type, payment, date, overrides \\ %{}),
    do:
      op(
        type,
        "ignored",
        date,
        Map.put(overrides, "payment_operation_id", payment["operation_id"])
      )

  defp seed_credit(conn, id) do
    apply!(conn, opening(id, "seed-property"))
    payment = op("record_cash_payment", id, "2026-11-01", %{"amount_cents" => 100})
    apply!(conn, payment)
    apply!(conn, op("cancel_group", id, "2026-11-01", %{"refund_method" => "hotel_credit"}))
    payment
  end

  defp report(conn, date),
    do:
      get(conn, "/api/v1/finance/daily-report", date: date)
      |> json_response(200)
      |> Map.fetch!("data")

  defp published_bytes(conn, dates),
    do:
      Enum.map(dates, fn date ->
        response = get(conn, "/api/v1/finance/daily-report", date: date)
        assert json_response(response, 200)["data"]["status"] == "closed"
        response.resp_body
      end)

  defp submit(conn, operation), do: hd(batch(conn, [operation]))

  defp batch(conn, operations),
    do:
      post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp apply!(conn, operation) do
    result = submit(conn, operation)
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp cash_movements(values \\ %{}),
    do: Map.merge(Map.new(@cash_in ++ @cash_out, &{&1, 0}), values)

  defp credit_movements(values \\ %{}),
    do: Map.merge(Map.new(["issued_cents" | @credit_out], &{&1, 0}), values)

  defp cash(property, opening, closing, movements \\ %{}),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "closing_held_cents" => closing,
      "movements" => cash_movements(movements)
    }

  defp credit(opening, closing, movements \\ %{}),
    do: %{
      "opening_liability_cents" => opening,
      "closing_liability_cents" => closing,
      "movements" => credit_movements(movements)
    }

  defp adjustments(cash \\ [], credit \\ %{}),
    do: %{
      "cash" =>
        Enum.map(cash, fn {property, m} ->
          %{"property_id" => property, "movements" => cash_movements(m)}
        end),
      "credit" => credit_movements(credit)
    }

  defp empty_report(date, status),
    do: %{
      "date" => date,
      "status" => status,
      "cash" => [],
      "credit" => credit(0, 0),
      "late_adjustments" => adjustments()
    }

  defp reporting_state,
    do: {Repo.all(Inception), Repo.all(Entry), Reservations.ledger(~D[2026-11-02])}

  defp assert_reconciles(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents

    totals =
      Enum.map(report["cash"], fn row ->
        late =
          Enum.find(
            report["late_adjustments"]["cash"],
            &(&1["property_id"] == row["property_id"])
          )

        movements =
          Map.merge(
            row["movements"],
            if(late, do: late["movements"], else: cash_movements()),
            fn _, a, b -> a + b end
          )

        assert row["closing_held_cents"] ==
                 row["opening_held_cents"] + Enum.sum(Enum.map(@cash_in, &movements[&1])) -
                   Enum.sum(Enum.map(@cash_out, &movements[&1]))

        movements
      end)

    assert Enum.sum(Enum.map(totals, & &1["transferred_in_cents"])) ==
             Enum.sum(Enum.map(totals, & &1["transferred_out_cents"]))

    credit = report["credit"]

    movements =
      Map.merge(credit["movements"], report["late_adjustments"]["credit"], fn _, a, b -> a + b end)

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + movements["issued_cents"] -
               Enum.sum(Enum.map(@credit_out, &movements[&1]))

    assert {:ok, _} = FinanceReporting.daily_report(Date.from_iso8601!(date))
  end
end
