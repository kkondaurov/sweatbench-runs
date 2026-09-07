defmodule GroupStay.FinanceTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Finance, Operations, Repo, Reservations}

  defp op(type, id, attrs \\ %{}, on \\ "2027-01-01"),
    do: Map.merge(%{"type" => type, "operation_id" => id, "occurred_on" => on}, attrs)

  defp apply!(operation) do
    [result] = Reservations.submit([operation])
    assert result.status == "applied"
    result
  end

  defp open(id, property \\ nil) do
    op("open_group", "open-" <> id, %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => property || id,
      "arrival_on" => "2030-06-01",
      "departure_on" => "2030-06-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "one", "nightly_rate_cents" => 5000},
        %{"room_id" => "two", "nightly_rate_cents" => 5000}
      ]
    })
  end

  defp pay(id, group, amount, on \\ "2027-01-01"),
    do: op("record_cash_payment", id, %{"group_id" => group, "amount_cents" => amount}, on)

  defp start, do: op("start_finance_reporting", "start", %{"starts_on" => "2027-01-01"})

  defp report(on \\ "2027-01-01") do
    assert {:ok, report} = Finance.daily_report(on)

    for cash <- report.cash do
      m = cash.movements

      assert cash.closing_held_cents ==
               cash.opening_held_cents + m.received_cents +
                 m.transferred_in_cents - m.transferred_out_cents - m.refunded_cents -
                 m.retained_cents - m.converted_to_credit_cents - m.reduced_cents -
                 m.charged_back_cents
    end

    c = report.credit
    m = c.movements

    assert c.closing_liability_cents ==
             c.opening_liability_cents + m.issued_cents -
               m.expired_cents - m.consumed_cents - m.revoked_cents - m.absorbed_cents

    report
  end

  test "HTTP validation, durable start, same-batch inception and backdated movements", %{
    conn: conn
  } do
    for date <- ["", "?date=no", "?date[]=2027-01-01"] do
      assert get(conn, "/api/v1/finance/daily-report" <> date) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-01") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    for value <- [nil, 12, "2027-02-30"] do
      [result] =
        Reservations.submit([
          op("start_finance_reporting", "bad-#{inspect(value)}", %{"starts_on" => value})
        ])

      assert result.code == "invalid_reporting_date"
    end

    operations = [
      open("a"),
      pay("before", "a", 100, "2028-01-01"),
      start(),
      pay("after", "a", 200, "2026-12-01")
    ]

    results = Reservations.submit(operations)
    assert Enum.all?(results, &(&1.status == "applied"))

    assert Enum.at(results, 2) == %{
             operation_id: "start",
             status: "applied",
             starts_on: "2027-01-01"
           }

    assert Reservations.submit(operations) == results
    assert Operations.get_result("start") == Enum.at(results, 2)

    assert [%{code: "reporting_already_started"}] =
             Reservations.submit([
               op("start_finance_reporting", "another", %{"starts_on" => "2028-01-01"})
             ])

    assert [%{code: "operation_id_conflict"}] =
             Reservations.submit([Map.put(start(), "starts_on", "2028-01-01")])

    assert {:error, "report_not_available"} = Finance.daily_report("2026-12-31")

    day = report()
    assert [cash] = day.cash
    assert cash.opening_held_cents == 100
    assert cash.movements.received_cents == 200
    assert cash.closing_held_cents == 300
    assert report("2027-01-02").cash |> hd() |> Map.fetch!(:opening_held_cents) == 300
    assert report() == day

    assert get(conn, "/api/v1/finance/daily-report?date=2027-01-01") |> json_response(200) ==
             %{"data" => Jason.decode!(Jason.encode!(day))}
  end

  test "transfers and later corrections follow settlement properties, including same-property transfers" do
    Enum.each([open("a"), open("b"), open("c", "b"), start(), pay("p", "a", 1000)], &apply!/1)

    apply!(
      op("transfer_deposit", "transfer", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 600
      })
    )

    apply!(
      op("transfer_deposit", "local", %{
        "source_group_id" => "b",
        "destination_group_id" => "c",
        "amount_cents" => 100
      })
    )

    apply!(op("cancel_group", "cancel", %{"group_id" => "b"}))

    apply!(
      op("reduce_cash_payment", "reduce", %{"payment_operation_id" => "p", "amount_cents" => 50})
    )

    apply!(op("charge_back_payment", "back", %{"payment_operation_id" => "p"}, "2027-01-02"))

    [a, b] = report().cash
    assert a.movements.transferred_out_cents == 600
    assert b.movements.transferred_in_cents == 700
    assert b.movements.transferred_out_cents == 100
    assert b.movements.refunded_cents == 500
    assert b.movements.reduced_cents == 50
    [a, b] = report("2027-01-02").cash
    assert a.movements.charged_back_cents == 400
    assert b.movements.refunded_cents == -500
    assert b.movements.charged_back_cents == 550
    assert a.closing_held_cents == 0
    assert b.closing_held_cents == 0
    assert report("2027-01-03").cash == []
  end

  test "credit issuance, paused expiry, revocation and shortfall absorption reconcile" do
    Enum.each([open("a"), open("b"), start(), pay("p", "a", 1000)], &apply!/1)
    apply!(op("cancel_group", "issue", %{"group_id" => "a", "refund_method" => "hotel_credit"}))
    apply!(op("apply_hotel_credit", "use", %{"group_id" => "b", "amount_cents" => 800}))
    assert report().credit.movements.issued_cents == 1100
    assert report("2028-01-02").credit.movements.expired_cents == 300
    assert report("2028-01-02").credit.closing_liability_cents == 800

    apply!(op("charge_back_payment", "back", %{"payment_operation_id" => "p"}, "2027-01-02"))
    day = report("2027-01-02")
    assert day.credit.movements.revoked_cents == 300
    assert day.credit.closing_liability_cents == 800
    apply!(op("cancel_group", "restore", %{"group_id" => "b"}, "2028-01-03"))
    day = report("2028-01-03")
    assert day.credit.movements.absorbed_cents == 800
    assert day.credit.movements.expired_cents == 0
    assert day.credit.closing_liability_cents == 0
    assert Reservations.ledger(~D[2028-01-03]).credit_liability_cents == 0
  end

  test "opening credit schedules expiry and expired restoration is a posting-day movement" do
    Enum.each(
      [
        open("a"),
        open("b"),
        pay("p", "a", 1000),
        op("cancel_group", "issue", %{"group_id" => "a", "refund_method" => "hotel_credit"}),
        op("apply_hotel_credit", "use", %{"group_id" => "b", "amount_cents" => 800}),
        start()
      ],
      &apply!/1
    )

    assert report().credit.opening_liability_cents == 1100
    assert report().credit.movements.issued_cents == 0
    assert report("2028-01-01").credit.closing_liability_cents == 1100
    assert report("2028-01-02").credit.movements.expired_cents == 300
    apply!(op("cancel_group", "restore", %{"group_id" => "b"}, "2028-01-03"))
    assert report("2028-01-03").credit.movements.expired_cents == 800
    assert report("2028-01-03").credit.closing_liability_cents == 0
  end

  test "expired revocation does not reclassify expiry, and nonrefundable credit is consumed" do
    Enum.each([open("a"), open("b"), start(), pay("p", "a", 1000)], &apply!/1)
    apply!(op("cancel_group", "issue", %{"group_id" => "a", "refund_method" => "hotel_credit"}))
    apply!(op("apply_hotel_credit", "use", %{"group_id" => "b", "amount_cents" => 800}))
    apply!(op("charge_back_payment", "back", %{"payment_operation_id" => "p"}, "2028-02-01"))
    assert report("2028-01-02").credit.movements.expired_cents == 300
    assert report("2028-02-01").credit.movements.revoked_cents == 0
    assert report("2028-02-01").credit.movements.expired_cents == 0
    apply!(op("cancel_group", "consume", %{"group_id" => "b"}, "2030-05-31"))
    assert report("2030-05-31").credit.movements.consumed_cents == 800
    assert report("2030-05-31").credit.closing_liability_cents == 0
    assert Reservations.ledger(~D[2030-05-31]).credit_liability_cents == 0
  end

  test "batch and sequential submission agree, including later backdated changes to open reports" do
    operations = [
      open("a"),
      start(),
      pay("p", "a", 1000, "2027-01-03"),
      op(
        "cancel_group",
        "issue",
        %{"group_id" => "a", "refund_method" => "hotel_credit"},
        "2027-01-02"
      )
    ]

    Repo.query!("SAVEPOINT equivalent_submissions")
    Reservations.submit(operations)
    batched = Enum.map(["2027-01-01", "2027-01-02", "2027-01-03", "2028-01-03"], &report/1)
    Repo.query!("ROLLBACK TO SAVEPOINT equivalent_submissions")
    Repo.query!("RELEASE SAVEPOINT equivalent_submissions")
    Enum.each(operations, &apply!/1)

    assert Enum.map(["2027-01-01", "2027-01-02", "2027-01-03", "2028-01-03"], &report/1) ==
             batched
  end

  test "rejections and exceptions roll back movements; replay and reads never add rows" do
    Enum.each([open("a"), start()], &apply!/1)
    operations = [pay("p", "a", 100), pay("bad", "a", 5000), pay("q", "a", 200)]
    results = Reservations.submit(operations)
    assert Enum.map(results, & &1.status) == ["applied", "rejected", "applied"]
    before = Repo.query!("SELECT * FROM finance_movements").rows
    assert Reservations.submit(operations) == results
    report("2029-01-01")
    report()
    assert Repo.query!("SELECT * FROM finance_movements").rows == before

    assert_raise RuntimeError, fn ->
      Operations.execute(op("fault", "fault"), fn ->
        Finance.credit(~D[2027-01-01], "issued", 999)
        raise "fault"
      end)
    end

    assert Operations.get_result("fault") == nil
    assert Repo.query!("SELECT * FROM finance_movements").rows == before
  end
end
