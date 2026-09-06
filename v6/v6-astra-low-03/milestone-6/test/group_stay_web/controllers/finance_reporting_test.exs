defmodule GroupStayWeb.FinanceReportingTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "f-#{System.unique_integer([:positive])}",
        "occurred_on" => "2027-02-01",
        "group_id" => "g"
      },
      attrs
    )
  end

  defp open(id \\ "g", property \\ "a") do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => property,
      "arrival_on" => "2029-06-01",
      "departure_on" => "2029-06-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
    })
  end

  defp run(ops) when is_list(ops),
    do: GroupStay.Reservations.batch(ops) |> Jason.encode!() |> Jason.decode!()

  defp run(operation), do: hd(run([operation]))
  defp start(on \\ "2027-02-01"), do: op("start_finance_reporting", %{"starts_on" => on})

  defp pay(id, amount, attrs \\ %{}),
    do:
      op(
        "record_cash_payment",
        Map.merge(%{"operation_id" => id, "amount_cents" => amount}, attrs)
      )

  defp report(date) do
    data =
      build_conn()
      |> get("/api/v1/finance/daily-report", %{date: date})
      |> json_response(200)
      |> Map.fetch!("data")

    for cash <- data["cash"] do
      m = cash["movements"]

      assert cash["closing_held_cents"] ==
               cash["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 Enum.sum(
                   for k <-
                         ~w(transferred_out refunded retained converted_to_credit reduced charged_back),
                       do: m[k <> "_cents"]
                 )
    end

    credit = data["credit"]

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + credit["movements"]["issued_cents"] -
               Enum.sum(
                 for k <- ~w(expired consumed revoked absorbed),
                     do: credit["movements"][k <> "_cents"]
               )

    data
  end

  test "validation, inception ordering, exact retries and backdated postings" do
    for params <- [%{}, %{date: "bad"}, %{date: "2027-02-30"}] do
      assert build_conn() |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-02-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert run(op("start_finance_reporting"))["code"] == "invalid_reporting_date"
    s = start()
    payment = pay("pay", 200, %{"occurred_on" => "2026-01-01"})

    [_, _, result, _, rejected] =
      run([
        open(),
        pay("opening", 100, %{"occurred_on" => "2030-01-01"}),
        s,
        payment,
        pay("bad", 99999)
      ])

    assert result == %{
             "operation_id" => s["operation_id"],
             "status" => "applied",
             "starts_on" => "2027-02-01"
           }

    assert rejected["status"] == "rejected"
    assert run(s) == result
    assert run(start())["code"] == "reporting_already_started"
    assert run(Map.put(s, "starts_on", "2027-03-01"))["code"] == "operation_id_conflict"
    first = report("2027-02-01")
    assert [cash] = first["cash"]
    assert cash["opening_held_cents"] == 100
    assert cash["movements"]["received_cents"] == 200
    run(payment)
    report("2030-01-01")
    assert report("2027-02-01") == first

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-31")
           |> json_response(404)

    run(pay("late", 50))
    assert hd(report("2027-02-01")["cash"])["closing_held_cents"] == 350
  end

  test "cash follows transfers and settled corrections, including same-property gross movements" do
    run([open(), open("d", "b"), open("e"), start(), pay("p", 1000)])

    run(
      op("transfer_deposit", %{
        "source_group_id" => "g",
        "destination_group_id" => "e",
        "amount_cents" => 100
      })
    )

    run(
      op("transfer_deposit", %{
        "source_group_id" => "g",
        "destination_group_id" => "d",
        "amount_cents" => 400
      })
    )

    run(op("cancel_group", %{"group_id" => "d"}))
    run(op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 50}))

    run(
      op("charge_back_payment", %{"payment_operation_id" => "p", "occurred_on" => "2027-02-02"})
    )

    [a, b] = report("2027-02-01")["cash"]
    assert a["movements"]["transferred_out_cents"] == 500
    assert a["movements"]["transferred_in_cents"] == 100
    assert b["movements"]["refunded_cents"] == 400
    [a, b] = report("2027-02-02")["cash"]
    assert a["movements"]["charged_back_cents"] == 550
    assert b["movements"]["refunded_cents"] == -400
    assert b["movements"]["charged_back_cents"] == 400
    assert Enum.all?([a, b], &(&1["closing_held_cents"] == 0))
  end

  test "issuance, paused expiry, revocation and absorption reconcile with current liability" do
    run([
      open(),
      open("d"),
      start(),
      pay("p", 1000),
      op("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    assert report("2027-02-01")["credit"]["movements"]["issued_cents"] == 1100
    run(op("apply_hotel_credit", %{"group_id" => "d", "amount_cents" => 800}))
    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 300

    run(
      op("charge_back_payment", %{"payment_operation_id" => "p", "occurred_on" => "2027-02-02"})
    )

    assert report("2027-02-02")["credit"]["movements"]["revoked_cents"] == 300
    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 0
    run(op("cancel_group", %{"group_id" => "d", "occurred_on" => "2028-02-03"}))
    credit = report("2028-02-03")["credit"]
    assert credit["movements"]["absorbed_cents"] == 800
    assert credit["movements"]["expired_cents"] == 0

    assert credit["closing_liability_cents"] ==
             GroupStay.Reservations.ledger(~D[2028-02-03]).credit_liability_cents
  end

  test "opening credit schedules expiry and expired restoration differs from consumption" do
    run([
      open(),
      open("d"),
      pay("p", 1000),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      op("apply_hotel_credit", %{"group_id" => "d", "amount_cents" => 800}),
      start()
    ])

    assert report("2027-02-01")["credit"]["opening_liability_cents"] == 1100
    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 300
    run(op("cancel_group", %{"group_id" => "d", "occurred_on" => "2028-02-03"}))
    credit = report("2028-02-03")["credit"]
    assert credit["movements"]["expired_cents"] == 800
    assert credit["movements"]["consumed_cents"] == 0
    assert credit["closing_liability_cents"] == 0
  end

  test "non-refundable credit is consumed" do
    run([
      open(),
      open("d"),
      start(),
      pay("p", 100),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      op("apply_hotel_credit", %{"group_id" => "d", "amount_cents" => 110}),
      op("cancel_group", %{"group_id" => "d", "occurred_on" => "2029-05-31"})
    ])

    assert report("2029-05-31")["credit"]["movements"]["consumed_cents"] == 110
  end

  test "mixed transfers report only cash and batches equal sequential submissions" do
    ops = [
      open("seed"),
      pay("seed-pay", 100, %{"group_id" => "seed"}),
      op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open(),
      open("d", "b"),
      start(),
      pay("p", 200),
      op("apply_hotel_credit", %{"amount_cents" => 110}),
      op("transfer_deposit", %{
        "source_group_id" => "g",
        "destination_group_id" => "d",
        "amount_cents" => 210
      })
    ]

    GroupStay.Repo.query!("SAVEPOINT compare_batch")
    run(ops)
    batched = report("2027-02-01")
    GroupStay.Repo.query!("ROLLBACK TO SAVEPOINT compare_batch")
    GroupStay.Repo.query!("RELEASE SAVEPOINT compare_batch")
    Enum.each(ops, &run/1)
    assert report("2027-02-01") == batched
    assert [a, b] = batched["cash"]
    assert a["movements"]["transferred_out_cents"] == 100
    assert b["movements"]["transferred_in_cents"] == 100
    assert batched["credit"]["opening_liability_cents"] == 110
    assert Enum.all?(batched["credit"]["movements"], fn {_, amount} -> amount == 0 end)
    assert Enum.sort(Map.keys(batched)) == ~w(cash credit date status)

    assert Enum.sort(Map.keys(a)) ==
             ~w(closing_held_cents movements opening_held_cents property_id)

    assert Enum.sort(Map.keys(batched["credit"])) ==
             ~w(closing_liability_cents movements opening_liability_cents)
  end

  test "chargeback of already expired credit does not remove liability twice" do
    run([
      open(),
      start(),
      pay("p", 100),
      op("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 110

    run(
      op("charge_back_payment", %{"payment_operation_id" => "p", "occurred_on" => "2028-02-03"})
    )

    assert report("2028-02-02")["credit"]["movements"]["expired_cents"] == 110
    credit = report("2028-02-03")["credit"]
    assert credit["closing_liability_cents"] == 0
    assert Enum.all?(credit["movements"], fn {_, amount} -> amount == 0 end)
  end
end
