defmodule GroupStayWeb.FinanceTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Reservations, Finance, Repo}

  defp op(type, attrs \\ %{}, date \\ "2026-10-01") do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "finance-#{System.unique_integer([:positive])}",
        "occurred_on" => date
      },
      attrs
    )
  end

  defp run(operation), do: hd(Reservations.batch([operation]))
  defp start, do: op("start_finance_reporting", %{"starts_on" => "2026-10-01"})

  defp open(id, property \\ nil, plan \\ "flexible") do
    run(
      op("open_group", %{
        "group_id" => id,
        "guest_id" => "guest",
        "property_id" => property || id,
        "arrival_on" => "2029-12-01",
        "departure_on" => "2029-12-02",
        "rate_plan" => plan,
        "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
      })
    )
  end

  defp pay(id, amount),
    do: op("record_cash_payment", %{"group_id" => id, "amount_cents" => amount})

  defp cancel(id, method \\ "cash", date \\ "2026-10-01"),
    do: op("cancel_group", %{"group_id" => id, "refund_method" => method}, date)

  defp report(date \\ "2026-10-01") do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp cash(report, property), do: Enum.find(report["cash"], &(&1["property_id"] == property))

  test "date validation, inception ordering, durable replay and posting clamp" do
    for query <- ["", "?date=no", "?date=2026-02-30", "?date[]=x"] do
      assert build_conn()
             |> get("/api/v1/finance/daily-report" <> query)
             |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for date <- [nil, "bad", 42] do
      assert run(op("start_finance_reporting", %{"starts_on" => date})).code ==
               "invalid_reporting_date"
    end

    assert run(op("start_finance_reporting")).code == "invalid_reporting_date"
    open("a")
    inception = start()
    payment = pay("a", 50) |> Map.put("occurred_on", "2026-09-01")

    [_, result, _, rejected] =
      Reservations.batch([
        pay("a", 100) |> Map.put("occurred_on", "2027-01-01"),
        inception,
        payment,
        pay("a", 99999)
      ])

    assert result == %{
             operation_id: inception["operation_id"],
             status: "applied",
             starts_on: "2026-10-01"
           }

    assert rejected.status == "rejected"
    assert run(inception) == result
    assert run(start()).code == "reporting_already_started"
    assert run(Map.put(inception, "starts_on", "2026-10-02")).code == "operation_id_conflict"
    row = cash(report(), "a")
    assert row["opening_held_cents"] == 100
    assert row["movements"]["received_cents"] == 50
    assert row["closing_held_cents"] == 150
    before = report()
    run(payment)
    assert report() == before
    assert cash(report("2028-01-01"), "a")["opening_held_cents"] == 150

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-09-30")
           |> json_response(404)
  end

  test "cash corrections follow transferred and settled properties with signed reclassification" do
    open("a")
    open("b")
    run(start())
    p = pay("a", 1000)
    run(p)

    run(
      op("transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 600
      })
    )

    run(cancel("b"))

    run(
      op("reduce_cash_payment", %{
        "payment_operation_id" => p["operation_id"],
        "amount_cents" => 100
      })
    )

    run(op("charge_back_payment", %{"payment_operation_id" => p["operation_id"]}, "2026-10-02"))
    first = report()
    assert cash(first, "a")["closing_held_cents"] == 300
    assert cash(first, "a")["movements"]["transferred_out_cents"] == 600
    assert cash(first, "b")["movements"]["transferred_in_cents"] == 600
    assert cash(first, "b")["movements"]["refunded_cents"] == 600
    second = report("2026-10-02")
    assert cash(second, "a")["movements"]["charged_back_cents"] == 300
    assert cash(second, "b")["movements"]["charged_back_cents"] == 600
    assert cash(second, "b")["movements"]["refunded_cents"] == -600
    assert Enum.all?(second["cash"], &(&1["closing_held_cents"] == 0))
    assert report() == first
    assert report("2026-10-03")["cash"] == []
  end

  test "late submissions update open days and batching matches sequential submissions" do
    open("a")

    operations = [
      start(),
      pay("a", 100) |> Map.put("occurred_on", "2026-10-03"),
      pay("a", 50) |> Map.put("occurred_on", "2026-10-01"),
      cancel("a", "hotel_credit", "2026-10-02")
    ]

    {:error, batched} =
      Repo.transaction(fn ->
        Reservations.batch(operations)

        Repo.rollback(
          for date <- ["2026-10-01", "2026-10-02", "2026-10-03", "2027-10-03"],
              do: report(date)
        )
      end)

    Enum.each(operations, &run/1)

    sequential =
      for date <- ["2026-10-01", "2026-10-02", "2026-10-03", "2027-10-03"],
          do: report(date)

    assert batched == sequential
    assert cash(hd(sequential), "a")["movements"]["received_cents"] == 50
    assert Enum.at(sequential, 2)["credit"]["closing_liability_cents"] == 165
    assert Enum.at(sequential, 3)["credit"]["closing_liability_cents"] == 0
  end

  test "same-property transfers expose gross cash only" do
    open("a", "hotel")
    open("b", "hotel")
    run(start())
    run(pay("a", 100))

    run(
      op("transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 50
      })
    )

    row = cash(report(), "hotel")
    assert row["movements"]["transferred_in_cents"] == 50
    assert row["movements"]["transferred_out_cents"] == 50
    assert row["closing_held_cents"] == 100
  end

  test "credit expiry is scheduled, paused while applied and restored after expiry" do
    open("issuer")
    open("user")
    run(pay("issuer", 100))
    run(cancel("issuer", "hotel_credit"))
    run(start())
    run(op("apply_hotel_credit", %{"group_id" => "user", "amount_cents" => 60}))
    assert report()["credit"]["opening_liability_cents"] == 110
    assert report()["credit"]["closing_liability_cents"] == 110
    assert report("2027-10-01")["credit"]["closing_liability_cents"] == 110
    expiry = report("2027-10-02")
    assert expiry["credit"]["movements"]["expired_cents"] == 50
    assert expiry["credit"]["closing_liability_cents"] == 60
    run(cancel("user", "cash", "2027-10-03"))
    assert report("2027-10-03")["credit"]["movements"]["expired_cents"] == 60
    assert report("2027-10-03")["credit"]["closing_liability_cents"] == 0
    assert report("2027-10-02") == expiry
    assert Reservations.ledger(~D[2027-10-03]).credit_liability_cents == 0
  end

  test "issuance, unspent revocation, shortfall absorption and consumption are distinct" do
    open("issuer")
    open("refundable")
    open("nonrefundable", nil, "advance_purchase")
    run(start())
    p = pay("issuer", 100)
    run(p)
    run(cancel("issuer", "hotel_credit"))
    run(op("apply_hotel_credit", %{"group_id" => "refundable", "amount_cents" => 60}))
    run(op("apply_hotel_credit", %{"group_id" => "nonrefundable", "amount_cents" => 30}))
    run(op("charge_back_payment", %{"payment_operation_id" => p["operation_id"]}))
    run(cancel("refundable"))
    run(cancel("nonrefundable"))
    credit = report()["credit"]

    assert credit["movements"] == %{
             "issued_cents" => 110,
             "revoked_cents" => 20,
             "absorbed_cents" => 60,
             "consumed_cents" => 30,
             "expired_cents" => 0
           }

    assert credit["closing_liability_cents"] == 0
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 0
    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 0
    snapshot = {Repo.all(Finance.Inception), Repo.all(Finance.Movement)}
    report("2028-01-01")
    report()
    assert snapshot == {Repo.all(Finance.Inception), Repo.all(Finance.Movement)}
  end
end
