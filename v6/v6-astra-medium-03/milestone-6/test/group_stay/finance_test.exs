defmodule GroupStay.FinanceTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Reservations, Finance, Repo}

  defp op(type, attrs) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-01-01"
      },
      attrs
    )
  end

  defp run(op), do: hd(Reservations.batch([op]))

  defp open(id, attrs \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2028-12-01",
          "departure_on" => "2028-12-02",
          "rate_plan" => "flexible",
          "rooms" => Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp pay(id, amount),
    do: op("record_cash_payment", %{"group_id" => id, "amount_cents" => amount})

  defp start, do: op("start_finance_reporting", %{"starts_on" => "2026-01-01"})

  defp report(on \\ "2026-01-01") do
    {:ok, report} = Finance.daily(on)
    report
  end

  defp cash(report, id), do: Enum.find(report.cash, &(&1.property_id == id))
  defp cancel(id, attrs \\ %{}), do: op("cancel_group", Map.merge(%{"group_id" => id}, attrs))

  defp credit(id, amount),
    do: op("apply_hotel_credit", %{"group_id" => id, "amount_cents" => amount})

  defp move(source, destination, amount),
    do:
      op("transfer_deposit", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  test "date errors, exact start shape, durable retries and inception within a batch" do
    for date <- [nil, "bad", "2026-02-30", %{}] do
      assert {:error, "invalid_reporting_date"} = Finance.daily(date)

      assert run(op("start_finance_reporting", %{"starts_on" => date})).code ==
               "invalid_reporting_date"
    end

    assert build_conn() |> get("/api/v1/finance/daily-report") |> json_response(422) == %{
             "error" => %{"code" => "invalid_reporting_date"}
           }

    assert {:error, "report_not_available"} = Finance.daily("2026-01-01")
    inception = start()

    [_, _, result, _] =
      Reservations.batch([
        open("a"),
        Map.put(pay("a", 100), "occurred_on", "2027-01-01"),
        inception,
        Map.put(pay("a", 50), "occurred_on", "2025-12-01")
      ])

    assert result == %{
             operation_id: inception["operation_id"],
             status: "applied",
             starts_on: "2026-01-01"
           }

    assert cash(report(), "a").opening_held_cents == 100
    assert cash(report(), "a").movements["received_cents"] == 50
    assert cash(report(), "a").closing_held_cents == 150
    assert run(inception) == result
    assert run(Map.put(inception, "starts_on", "2026-01-02")).code == "operation_id_conflict"
    assert run(start()).code == "reporting_already_started"
    assert {:error, "report_not_available"} = Finance.daily("2025-12-31")

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2025-12-31")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-01-01")
           |> json_response(200) == %{"data" => Jason.decode!(Jason.encode!(report()))}
  end

  test "cash follows properties through transfers, reductions and settled chargebacks" do
    payment = pay("s", 300)

    Reservations.batch([
      start(),
      open("s"),
      open("d"),
      open("n", %{"rate_plan" => "advance_purchase"}),
      payment,
      move("s", "d", 100),
      move("s", "n", 100),
      cancel("d"),
      cancel("n")
    ])

    reduce =
      op("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 20
      })

    run(reduce)

    charge =
      op("charge_back_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "occurred_on" => "2026-01-02"
      })

    run(charge)
    first = report()
    assert Enum.map(first.cash, & &1.property_id) == ~w(d n s)
    assert cash(first, "s").closing_held_cents == 80
    assert cash(first, "s").movements["transferred_out_cents"] == 200
    assert cash(first, "s").movements["reduced_cents"] == 20
    second = report("2026-01-02")
    assert cash(second, "d").movements["refunded_cents"] == -100
    assert cash(second, "n").movements["retained_cents"] == -100
    assert cash(second, "s").movements["charged_back_cents"] == 80
    assert cash(second, "d").movements["charged_back_cents"] == 100
    assert Enum.all?(second.cash, &(&1.closing_held_cents == 0))
    run(charge)

    assert run(
             op("reduce_cash_payment", %{
               "payment_operation_id" => payment["operation_id"],
               "amount_cents" => 1
             })
           ).status == "rejected"

    assert report("2026-01-02") == second
    assert report() == first
    assert report("2026-01-03").cash == []
  end

  test "same-property mixed transfers report only cash on both sides" do
    Reservations.batch([
      open("seed"),
      pay("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      open("s", %{"property_id" => "hotel"}),
      open("d", %{"property_id" => "hotel"}),
      pay("s", 100),
      credit("s", 110),
      start(),
      move("s", "d", 150)
    ])

    row = cash(report(), "hotel")
    assert row.opening_held_cents == 100
    assert row.closing_held_cents == 100
    assert row.movements["transferred_in_cents"] == 40
    assert row.movements["transferred_out_cents"] == 40
    assert report().credit.opening_liability_cents == 110
    assert Enum.all?(report().credit.movements, fn {_, amount} -> amount == 0 end)
  end

  test "expiry is scheduled without writes on reads and later backdated funding revises it" do
    Reservations.batch([
      start(),
      open("seed"),
      pay("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      open("d")
    ])

    assert report().credit.movements["issued_cents"] == 110
    assert report("2027-01-01").credit.closing_liability_cents == 110
    assert report("2027-01-02").credit.movements["expired_cents"] == 110
    assert report("2027-01-03").credit.closing_liability_cents == 0
    run(credit("d", 60))
    assert report("2027-01-02").credit.movements["expired_cents"] == 50
    assert report("2027-01-03").credit.closing_liability_cents == 60
    run(cancel("d", %{"occurred_on" => "2027-01-03"}))
    assert report("2027-01-03").credit.movements["expired_cents"] == 60

    assert report("2027-01-03").credit.closing_liability_cents ==
             Reservations.ledger(~D[2027-01-03]).credit_liability_cents

    before = Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM finance_movements ORDER BY id").rows
    for date <- ~w(2027-01-03 2026-01-01 2027-01-02 2027-01-03), do: report(date)

    assert Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM finance_movements ORDER BY id").rows ==
             before
  end

  test "revocation, absorption before expiry, and nonrefundable consumption have separate columns" do
    payment = pay("seed", 100)

    Reservations.batch([
      start(),
      open("seed"),
      payment,
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      open("d"),
      open("n", %{"rate_plan" => "advance_purchase"}),
      credit("d", 60),
      credit("n", 20)
    ])

    run(op("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]}))
    assert report().credit.movements["revoked_cents"] == 30
    assert cash(report(), "seed").movements["converted_to_credit_cents"] == 0
    run(cancel("n"))
    assert report().credit.movements["consumed_cents"] == 20
    run(cancel("d", %{"occurred_on" => "2027-01-03"}))
    assert report("2027-01-03").credit.movements["absorbed_cents"] == 60
    assert report("2027-01-03").credit.movements["expired_cents"] == 0
    assert report("2027-01-03").credit.closing_liability_cents == 0
  end

  test "opening credit excludes expired unused lots but includes applied credit" do
    Reservations.batch([
      open("seed"),
      pay("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      open("d"),
      credit("d", 60)
    ])

    run(Map.put(start(), "starts_on", "2027-01-03"))
    assert report("2027-01-03").credit.opening_liability_cents == 60
    run(cancel("d", %{"occurred_on" => "2027-01-04"}))
    assert report("2027-01-04").credit.movements["expired_cents"] == 60
    assert report("2027-01-04").credit.closing_liability_cents == 0
  end

  test "batch and sequential submissions have equivalent reports, including late postings" do
    payment = pay("s", 200)

    operations = [
      open("s"),
      pay("s", 50),
      start(),
      open("d"),
      payment,
      move("s", "d", 100),
      cancel("d", %{"occurred_on" => "2026-01-03", "refund_method" => "hotel_credit"}),
      Map.put(pay("s", 10), "occurred_on", "2026-01-02"),
      op("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 500
      })
    ]

    dates = ~w(2026-01-01 2026-01-02 2026-01-03 2027-01-04)

    {:error, batch_reports} =
      Repo.transaction(fn ->
        Reservations.batch(operations)
        Repo.rollback(Enum.map(dates, &report/1))
      end)

    Enum.each(operations, &run/1)
    assert Enum.map(dates, &report/1) == batch_reports
    assert cash(report("2026-01-02"), "s").movements["received_cents"] == 10
    assert report("2026-01-03").credit.movements["issued_cents"] == 110

    assert Enum.sum(Enum.map(report("2027-01-04").cash, & &1.closing_held_cents)) ==
             Reservations.ledger(~D[2027-01-04]).cash_held_cents
  end

  test "restoration resumes original expiry and expired revocation does not reduce liability twice" do
    payment = pay("seed", 100)

    Reservations.batch([
      start(),
      open("seed"),
      payment,
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      open("d"),
      credit("d", 60),
      cancel("d")
    ])

    assert report().credit.closing_liability_cents == 110
    assert report().credit.movements["issued_cents"] == 110
    assert report("2027-01-02").credit.movements["expired_cents"] == 110

    run(
      op("charge_back_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "occurred_on" => "2027-01-03"
      })
    )

    assert report("2027-01-03").credit.closing_liability_cents == 0
    assert report("2027-01-03").credit.movements["revoked_cents"] == 0
    assert report("2027-01-02").credit.movements["expired_cents"] == 110
  end
end
