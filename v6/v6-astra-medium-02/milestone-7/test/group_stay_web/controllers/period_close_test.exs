defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.Finance.Movement

  defp op(id, type, extra \\ %{}, on \\ "2027-02-01") do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => on}, extra)
  end

  defp open(id, property) do
    op("open-#{id}", "open_group", %{
      "group_id" => id,
      "property_id" => property,
      "guest_id" => "guest",
      "arrival_on" => "2029-06-01",
      "departure_on" => "2029-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
    })
  end

  defp pay(id, amount, group \\ "a"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp start, do: op("start", "start_finance_reporting", %{"starts_on" => "2027-02-01"})

  defp apply!(ops) do
    results = Reservations.batch(List.wrap(ops))
    assert Enum.all?(results, &(&1.status == "applied")), inspect(results)
    results
  end

  defp report(on \\ "2027-02-01") do
    build_conn()
    |> get("/api/v1/finance/daily-report", %{"date" => on})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cancel(id, group, on \\ "2027-02-01", method \\ "cash"),
    do: op(id, "cancel_group", %{"group_id" => group, "refund_method" => method}, on)

  defp close(id, on), do: op(id, "close_finance_period", %{"period_end_on" => on})

  test "close validates dates and inception, remembers rejections and replays exact results" do
    early = close("early", "2027-02-01")
    assert [%{code: "invalid_period"}] = Reservations.batch([early])
    apply!(start())

    for {value, index} <- Enum.with_index([nil, "bad", "2027-02-30", 42, [], "2027-01-31"]) do
      assert [%{code: "invalid_period"}] = Reservations.batch([close("bad-#{index}", value)])
    end

    assert [%{code: "invalid_period"}] =
             Reservations.batch([op("missing", "close_finance_period")])

    assert [%{code: "invalid_period"}] = Reservations.batch([early])
    closing = close("close", "2027-02-01") |> Map.put("expected_revision", "ignored")
    assert [original] = apply!(closing)
    assert original == %{operation_id: "close", status: "applied", period_end_on: "2027-02-01"}
    assert Reservations.get_operation("close") == Jason.decode!(Jason.encode!(original))
    assert [^original] = Reservations.batch([closing])

    assert [%{code: "operation_id_conflict"}] =
             Reservations.batch([Map.put(closing, "period_end_on", "2027-02-02")])

    assert [%{code: "invalid_period"}, %{code: "invalid_period"}] =
             Reservations.batch([close("same", "2027-02-01"), close("older", "2027-01-31")])

    assert report()["status"] == "closed"
    assert report("2027-02-02")["status"] == "open"
    assert report()["late_adjustments"]["cash"] == []
    assert map_size(report()["late_adjustments"]["credit"]) == 5
    assert Enum.all?(report()["late_adjustments"]["credit"], fn {_, n} -> n == 0 end)

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-31")
           |> json_response(404)
  end

  test "same-batch closes fix posting dates and separate ordinary from late cash" do
    apply!([
      open("a", "alpha"),
      start(),
      pay("before", 100),
      close("first", "2027-02-01"),
      pay("after", 200)
    ])

    published = Jason.encode!(report())
    assert hd(report()["cash"])["closing_held_cents"] == 100
    assert hd(report("2027-02-02")["cash"])["movements"]["received_cents"] == 0

    assert hd(report("2027-02-02")["late_adjustments"]["cash"])["movements"]["received_cents"] ==
             200

    apply!(Map.put(pay("ordinary", 300), "occurred_on", "2027-02-02"))
    day = report("2027-02-02")
    assert hd(day["cash"])["opening_held_cents"] == 100
    assert hd(day["cash"])["closing_held_cents"] == 600
    assert hd(day["cash"])["movements"]["received_cents"] == 300
    apply!(close("second", "2027-02-02"))
    second = report("2027-02-02")
    assert second == Map.put(day, "status", "closed")
    apply!(Map.put(pay("future", 400), "occurred_on", "2027-02-05"))
    apply!(pay("late-again", 50))
    assert Jason.encode!(report()) == published
    assert report("2027-02-02") == second

    assert hd(report("2027-02-03")["late_adjustments"]["cash"])["movements"]["received_cents"] ==
             50

    assert report("2027-02-05")["late_adjustments"]["cash"] == []

    assert hd(report("2027-02-05")["cash"])["closing_held_cents"] ==
             Reservations.ledger().cash_held_cents

    count = Repo.aggregate(Movement, :count)
    Reservations.batch([pay("after", 200), close("first", "2027-02-01"), pay("reject", 5000)])
    assert Repo.aggregate(Movement, :count) == count
    assert Jason.encode!(report()) == published
    assert report("2027-02-02") == second
  end

  test "late transferred settlement and chargeback preserve signed zero-net classifications" do
    apply!([open("a", "alpha"), open("b", "beta"), start(), pay("p", 500)])

    apply!(
      op("move", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 500
      })
    )

    apply!(cancel("refund", "b"))
    apply!(close("close", "2027-02-01"))
    closed = report()
    apply!(op("charge", "charge_back_payment", %{"payment_operation_id" => "p"}))
    day = report("2027-02-02")
    assert [cash] = day["cash"]
    assert cash["property_id"] == "beta"
    assert cash["opening_held_cents"] == 0
    assert cash["closing_held_cents"] == 0
    assert Enum.all?(cash["movements"], fn {_, n} -> n == 0 end)
    assert [late] = day["late_adjustments"]["cash"]
    assert late["property_id"] == "beta"
    assert late["movements"]["refunded_cents"] == -500
    assert late["movements"]["charged_back_cents"] == 500
    assert report() == closed
    assert {:ok, %{charged_back_cents: 500, refunded_cents: 0}} = Reservations.get_payment("p")
  end

  test "closed expiry is stable when old-dated redemption and restoration change liability" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      start(),
      pay("p", 1000),
      cancel("issue", "a", "2027-02-01", "hotel_credit"),
      close("close", "2028-02-02")
    ])

    expired = report("2028-02-02")
    assert expired["credit"]["movements"]["expired_cents"] == 1100
    assert expired["credit"]["closing_liability_cents"] == 0

    apply!(
      op(
        "redeem",
        "apply_hotel_credit",
        %{"group_id" => "b", "amount_cents" => 500},
        "2028-02-01"
      )
    )

    day = report("2028-02-03")
    assert day["credit"]["movements"]["expired_cents"] == 0
    assert day["late_adjustments"]["credit"]["expired_cents"] == -500
    assert day["credit"]["closing_liability_cents"] == 500
    assert report("2028-02-02") == expired
    apply!(close("next", "2028-02-03"))
    published = report("2028-02-03")
    apply!(cancel("restore", "b", "2028-02-01"))
    assert report("2028-02-04")["late_adjustments"]["credit"]["expired_cents"] == 500

    assert report("2028-02-04")["credit"]["closing_liability_cents"] ==
             Reservations.ledger(~D[2028-02-04]).credit_liability_cents

    assert report("2028-02-03") == published
    assert report("2028-02-02") == expired
  end

  test "late issuance schedules ordinary future expiry and late clawback absorbs restored credit" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      start(),
      pay("p", 1000),
      close("close", "2027-02-01"),
      cancel("issue", "a", "2027-02-01", "hotel_credit")
    ])

    assert report("2027-02-02")["late_adjustments"]["credit"]["issued_cents"] == 1100
    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 1100
    assert report("2028-02-02")["late_adjustments"]["credit"]["expired_cents"] == 0
    apply!(op("redeem", "apply_hotel_credit", %{"group_id" => "b", "amount_cents" => 800}))
    apply!(op("charge", "charge_back_payment", %{"payment_operation_id" => "p"}))
    assert report("2027-02-02")["late_adjustments"]["credit"]["revoked_cents"] == 300
    apply!(cancel("restore", "b"))
    assert report("2027-02-02")["late_adjustments"]["credit"]["absorbed_cents"] == 800
    assert report("2027-02-02")["credit"]["closing_liability_cents"] == 0
    assert report("2028-02-02")["credit"]["closing_liability_cents"] == 0
  end

  test "batch and sequential closes produce equivalent reports" do
    operations = [
      open("a", "alpha"),
      start(),
      pay("one", 100),
      close("first", "2027-02-01"),
      pay("two", 200),
      close("second", "2027-02-02"),
      pay("three", 300)
    ]

    dates = ~w(2027-02-01 2027-02-02 2027-02-03 2030-01-01)

    {:error, expected} =
      Repo.transaction(fn ->
        apply!(operations)
        Repo.rollback(Enum.map(dates, &report/1))
      end)

    Enum.each(operations, &apply!/1)
    assert Enum.map(dates, &report/1) == expected
  end

  test "late transfers, reductions and refunds retain destination property accounting" do
    apply!([
      open("a", "alpha"),
      open("b", "beta"),
      start(),
      pay("p", 1000),
      close("close", "2027-02-01")
    ])

    closed = report()

    apply!(
      op("move", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 600
      })
    )

    apply!(
      op("reduce", "reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 100})
    )

    apply!(cancel("refund", "b"))
    day = report("2027-02-02")
    [a, b] = day["late_adjustments"]["cash"]
    assert a["property_id"] == "alpha"
    assert a["movements"]["transferred_out_cents"] == 600
    assert b["property_id"] == "beta"
    assert b["movements"]["transferred_in_cents"] == 600
    assert b["movements"]["reduced_cents"] == 100
    assert b["movements"]["refunded_cents"] == 500
    assert Enum.map(day["cash"], & &1["closing_held_cents"]) == [400, 0]
    assert report() == closed

    assert {:ok, %{held_cents: 400, reduced_cents: 100, refunded_cents: 500}} =
             Reservations.get_payment("p")
  end
end
