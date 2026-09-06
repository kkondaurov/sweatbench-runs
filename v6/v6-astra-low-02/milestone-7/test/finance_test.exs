defmodule GroupStay.FinanceTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Finance, Reservations, Repo, Group, CreditLot}

  defp op(type, fields \\ %{}, on \\ "2026-10-01") do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "finance-#{System.unique_integer([:positive])}",
        "occurred_on" => on
      },
      fields
    )
  end

  defp open(id, property \\ nil, plan \\ "flexible") do
    op("open_group", %{
      "group_id" => id,
      "property_id" => property || id,
      "guest_id" => "guest",
      "arrival_on" => "2028-03-01",
      "departure_on" => "2028-03-02",
      "rate_plan" => plan,
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 500},
        %{"room_id" => "b", "nightly_rate_cents" => 500}
      ]
    })
  end

  defp apply!(operation) do
    [result] = Reservations.batch([operation])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp start(on \\ "2026-10-01"), do: op("start_finance_reporting", %{"starts_on" => on})

  defp pay(id, amount),
    do: op("record_cash_payment", %{"group_id" => id, "amount_cents" => amount})

  defp move(a, b, amount),
    do:
      op("transfer_deposit", %{
        "source_group_id" => a,
        "destination_group_id" => b,
        "amount_cents" => amount
      })

  defp cancel(id, method \\ "cash", on \\ "2026-10-01"),
    do: op("cancel_group", %{"group_id" => id, "refund_method" => method}, on)

  defp report(on \\ "2026-10-01") do
    {:ok, r} = Finance.daily(on)

    for c <- r.cash do
      m = c.movements

      assert c.closing_held_cents ==
               c.opening_held_cents + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] -
                 Enum.sum(
                   for k <- ~w(refunded retained converted_to_credit reduced charged_back),
                       do: m[k <> "_cents"]
                 )

      assert map_size(m) == 8
      assert map_size(c) == 4
    end

    assert Enum.sum(for c <- r.cash, do: c.movements["transferred_in_cents"]) ==
             Enum.sum(for c <- r.cash, do: c.movements["transferred_out_cents"])

    c = r.credit

    assert c.closing_liability_cents ==
             c.opening_liability_cents + c.movements["issued_cents"] -
               Enum.sum(
                 for k <- ~w(expired consumed revoked absorbed), do: c.movements[k <> "_cents"]
               )

    assert map_size(c.movements) == 5
    r
  end

  defp close(on), do: op("close_finance_period", %{"period_end_on" => on})

  test "close validation, exact durable results, and same-batch posting boundaries" do
    rejected = close("2026-10-01")
    assert [%{"code" => "invalid_period"}] = Reservations.batch([rejected])
    apply!(start())
    assert [%{"code" => "invalid_period"}] = Reservations.batch([rejected])

    for value <- [nil, 123, "bad", "2026-02-30", "2026-09-30"] do
      assert [%{"code" => "invalid_period"}] = Reservations.batch([close(value)])
    end

    assert [%{"code" => "invalid_period"}] = Reservations.batch([op("close_finance_period")])

    cutoff = close("2026-10-01")
    before = pay("a", 20)
    after_close = pay("a", 30)
    results = Reservations.batch([open("a"), before, cutoff, after_close])

    assert Enum.at(results, 2) == %{
             "operation_id" => cutoff["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-10-01"
           }

    {:ok, closed} = Finance.daily("2026-10-01")
    assert closed.status == "closed"
    assert hd(closed.cash).closing_held_cents == 20
    {:ok, next} = Finance.daily("2026-10-02")
    assert next.status == "open"
    assert hd(next.cash).opening_held_cents == 20
    assert hd(next.cash).closing_held_cents == 50
    assert hd(next.cash).movements["received_cents"] == 0
    assert hd(next.late_adjustments.cash).movements["received_cents"] == 30
    assert Reservations.batch([cutoff, after_close]) == Enum.drop(results, 2)

    assert [%{"code" => "operation_id_conflict"}] =
             Reservations.batch([Map.put(cutoff, "period_end_on", "2026-10-02")])

    assert [%{"code" => "invalid_period"}] = Reservations.batch([close("2026-10-01")])
    apply!(Map.put(pay("a", 40), "occurred_on", "2026-10-03"))
    apply!(close("2026-10-02"))
    apply!(pay("a", 10))
    assert Finance.daily("2026-10-01") == {:ok, closed}
    assert Finance.daily("2026-10-02") == {:ok, %{next | status: "closed"}}
    {:ok, latest} = Finance.daily("2026-10-03")
    assert hd(latest.cash).movements["received_cents"] == 40
    assert hd(latest.late_adjustments.cash).movements["received_cents"] == 10
    assert hd(latest.cash).closing_held_cents == Reservations.ledger().cash_held_cents
  end

  test "late zero-net reclassifications retain signed property movements" do
    payment = pay("a", 100)
    Reservations.batch([start(), open("a"), open("b"), payment, move("a", "b", 100), cancel("b")])
    apply!(close("2026-10-01"))

    published =
      build_conn() |> get("/api/v1/finance/daily-report?date=2026-10-01") |> json_response(200)

    apply!(op("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]}))
    {:ok, r} = Finance.daily("2026-10-02")
    assert [adjustment] = r.late_adjustments.cash
    assert adjustment.property_id == "b"
    assert adjustment.movements["refunded_cents"] == -100
    assert adjustment.movements["charged_back_cents"] == 100
    assert [cash] = r.cash
    assert cash.closing_held_cents == 0
    assert Enum.all?(cash.movements, fn {_, v} -> v == 0 end)
    apply!(close("2027-01-01"))

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(200) == published
  end

  test "closed automatic expiry stays fixed when old-dated credit is redeemed and restored" do
    Reservations.batch([
      start(),
      open("seed"),
      pay("seed", 100),
      cancel("seed", "hotel_credit"),
      open("a")
    ])

    apply!(close("2027-10-02"))
    {:ok, published} = Finance.daily("2027-10-02")
    assert published.credit.movements["expired_cents"] == 110
    apply!(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 60}))
    {:ok, r} = Finance.daily("2027-10-03")
    assert r.late_adjustments.credit["expired_cents"] == -60
    assert r.credit.closing_liability_cents == 60
    apply!(cancel("a"))
    {:ok, r} = Finance.daily("2027-10-03")
    assert r.credit.closing_liability_cents == 0
    assert Finance.daily("2027-10-02") == {:ok, published}
  end

  test "HTTP validation, exact start shape, inception boundary, retries and late postings" do
    for query <- ["", "?date=no", "?date=2026-02-30", "?date[]=2026-10-01"] do
      assert build_conn() |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert {:error, "report_not_available"} = Finance.daily("2026-10-01")

    for value <- [nil, "bad", 12, "2026-02-30"] do
      assert [%{"code" => "invalid_reporting_date"}] = Reservations.batch([start(value)])
    end

    assert [%{"code" => "invalid_reporting_date"}] =
             Reservations.batch([op("start_finance_reporting")])

    inception = start("2026-10-02")
    initial = Map.put(pay("a", 40), "occurred_on", "2026-12-01")
    later = pay("a", 10)
    results = Reservations.batch([open("a"), initial, inception, later])

    assert Enum.at(results, 2) == %{
             "operation_id" => inception["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-10-02"
           }

    assert report("2026-10-02").cash
           |> hd()
           |> Map.take([:opening_held_cents, :closing_held_cents]) == %{
             opening_held_cents: 40,
             closing_held_cents: 50
           }

    assert {:error, "report_not_available"} = Finance.daily("2026-10-01")
    assert Reservations.batch([inception, later]) == Enum.drop(results, 2)

    assert [%{"code" => "operation_id_conflict"}] =
             Reservations.batch([Map.put(inception, "starts_on", "2026-10-03")])

    assert [%{"code" => "reporting_already_started"}] = Reservations.batch([start()])
    apply!(Map.put(pay("a", 20), "occurred_on", "2026-10-04"))
    apply!(Map.put(pay("a", 15), "occurred_on", "2026-10-03"))
    assert hd(report("2026-10-04").cash).opening_held_cents == 65
    assert hd(report("2026-10-04").cash).closing_held_cents == 85
    state = {Repo.all(Group), Repo.all(CreditLot), Repo.all(Finance.Entry)}
    expected = report("2026-10-04")
    report("2027-01-01")
    report("2026-10-02")
    assert report("2026-10-04") == expected
    assert {Repo.all(Group), Repo.all(CreditLot), Repo.all(Finance.Entry)} == state

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-04")
           |> json_response(200) == %{"data" => Jason.decode!(Jason.encode!(expected))}
  end

  test "cash follows transferred funding through refunds, retention, conversion, reduction and chargeback" do
    payment = pay("a", 200)

    Reservations.batch([
      open("a"),
      open("b"),
      open("c", nil, "advance_purchase"),
      open("d"),
      payment
    ])

    apply!(start())
    apply!(move("a", "b", 50))
    apply!(move("a", "c", 40))
    apply!(move("a", "d", 30))
    apply!(cancel("b"))
    apply!(cancel("c"))
    apply!(cancel("d", "hotel_credit"))

    apply!(
      op("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 20
      })
    )

    before = report()
    assert Enum.map(before.cash, & &1.property_id) == ~w(a b c d)
    assert Enum.map(before.cash, & &1.closing_held_cents) == [60, 0, 0, 0]

    charge =
      op(
        "charge_back_payment",
        %{"payment_operation_id" => payment["operation_id"]},
        "2026-10-02"
      )

    apply!(charge)
    r = report("2026-10-02")
    assert Enum.map(r.cash, & &1.movements["charged_back_cents"]) == [60, 50, 40, 30]
    assert Enum.map(r.cash, & &1.movements["refunded_cents"]) == [0, -50, 0, 0]
    assert Enum.map(r.cash, & &1.movements["retained_cents"]) == [0, 0, -40, 0]
    assert Enum.map(r.cash, & &1.movements["converted_to_credit_cents"]) == [0, 0, 0, -30]
    assert r.credit.movements["revoked_cents"] == 33
    assert r.credit.closing_liability_cents == 0
    assert Reservations.ledger(~D[2026-10-02]).cash_held_cents == 0
    apply!(charge)
    assert report("2026-10-02") == r
    assert report("2027-10-02").credit.movements["expired_cents"] == 0
  end

  test "same-property transfers report gross cash, omit zero properties, and ignore credit transfers" do
    Reservations.batch([
      open("seed"),
      pay("seed", 100),
      cancel("seed", "hotel_credit"),
      open("a", "hotel"),
      open("b", "hotel"),
      open("empty")
    ])

    apply!(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 50}))
    apply!(pay("a", 30))
    apply!(start())
    apply!(move("a", "b", 60))
    r = report()
    assert [c] = r.cash
    assert c.property_id == "hotel"
    assert c.movements["transferred_in_cents"] == 30
    assert c.movements["transferred_out_cents"] == 30
    assert c.closing_held_cents == 30
    assert r.credit.opening_liability_cents == 110
    assert Enum.all?(r.credit.movements, fn {_, value} -> value == 0 end)
  end

  test "expiry is scheduled without operations and applied credit expires only on restoration" do
    Reservations.batch([
      open("seed"),
      pay("seed", 100),
      cancel("seed", "hotel_credit"),
      open("a")
    ])

    apply!(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 60}))
    apply!(start())
    assert report("2027-10-01").credit.closing_liability_cents == 110
    r = report("2027-10-02")
    assert r.credit.movements["expired_cents"] == 50
    assert r.credit.closing_liability_cents == 60
    apply!(cancel("a", "cash", "2027-10-03"))
    r = report("2027-10-03")
    assert r.credit.movements["expired_cents"] == 60
    assert r.credit.movements["consumed_cents"] == 0
    assert r.credit.closing_liability_cents == 0
    assert Reservations.ledger(~D[2027-10-03]).credit_liability_cents == 0
  end

  test "shortfall absorption precedes expiry and nonrefundable settlement consumes liability" do
    payment = pay("seed", 100)

    Reservations.batch([
      open("seed"),
      payment,
      cancel("seed", "hotel_credit"),
      open("a"),
      open("b", nil, "advance_purchase")
    ])

    apply!(start())
    apply!(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 60}))
    apply!(op("apply_hotel_credit", %{"group_id" => "b", "amount_cents" => 30}))
    apply!(op("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]}))
    assert report().credit.movements["revoked_cents"] == 20
    apply!(cancel("a", "cash", "2027-10-03"))
    r = report("2027-10-03")
    assert r.credit.movements["absorbed_cents"] == 60
    assert r.credit.movements["expired_cents"] == 0
    apply!(cancel("b", "cash", "2027-10-03"))
    r = report("2027-10-03")
    assert r.credit.movements["consumed_cents"] == 30
    assert r.credit.closing_liability_cents == 0
  end

  test "handled failures create no movements while preceding and subsequent operations commit" do
    apply!(open("a"))
    apply!(start())
    rejected = pay("a", 300)
    results = Reservations.batch([pay("a", 20), rejected, pay("a", 30)])
    assert Enum.map(results, & &1["status"]) == ~w(applied rejected applied)
    r = report()
    assert hd(r.cash).movements["received_cents"] == 50
    assert Reservations.batch([rejected]) == [Enum.at(results, 1)]
    assert report() == r
  end

  test "new issuance, partial room restoration and late redemption adjust automatic expiry" do
    apply!(start())

    Reservations.batch([
      open("seed"),
      pay("seed", 200),
      cancel("seed", "hotel_credit"),
      open("a")
    ])

    r = report()
    assert r.credit.movements["issued_cents"] == 220
    assert report("2027-10-02").credit.movements["expired_cents"] == 220
    apply!(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 150}, "2027-09-30"))
    assert report("2027-10-02").credit.movements["expired_cents"] == 70
    apply!(op("cancel_rooms", %{"group_id" => "a", "room_ids" => ["a"]}, "2027-10-01"))
    assert report("2027-10-01").credit.movements["expired_cents"] == 0
    assert report("2027-10-02").credit.movements["expired_cents"] == 170
    assert report("2027-10-02").credit.closing_liability_cents == 50
  end

  test "expired opening credit is excluded and later chargeback does not revoke liability twice" do
    payment = pay("seed", 100)
    Reservations.batch([open("seed"), payment, cancel("seed", "hotel_credit")])
    apply!(start("2027-10-02"))

    apply!(
      op(
        "charge_back_payment",
        %{"payment_operation_id" => payment["operation_id"]},
        "2027-10-03"
      )
    )

    r = report("2027-10-03")
    assert r.credit.opening_liability_cents == 0
    assert Enum.all?(r.credit.movements, fn {_, value} -> value == 0 end)
    assert hd(r.cash).movements["converted_to_credit_cents"] == -100
    assert hd(r.cash).movements["charged_back_cents"] == 100
  end

  test "batch boundaries do not affect reporting" do
    operations = [
      open("seed"),
      pay("seed", 100),
      start(),
      cancel("seed", "hotel_credit"),
      open("a"),
      op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 50}),
      cancel("a", "cash", "2027-10-03")
    ]

    Repo.query!("SAVEPOINT batch_comparison")
    results = Reservations.batch(operations)
    reports = Enum.map(~w(2026-10-01 2027-10-02 2027-10-03), &report/1)
    Repo.query!("ROLLBACK TO SAVEPOINT batch_comparison")
    Repo.query!("RELEASE SAVEPOINT batch_comparison")
    assert Enum.map(operations, &apply!/1) == results
    assert Enum.map(~w(2026-10-01 2027-10-02 2027-10-03), &report/1) == reports
  end
end
