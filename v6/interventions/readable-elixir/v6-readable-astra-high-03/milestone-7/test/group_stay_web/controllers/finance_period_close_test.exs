defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.{Entry, Reporting}

  @cash_kinds ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents
                 retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_kinds ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "validates cutoffs, remembers rejections, ignores revision guards, and replays exact results" do
    premature = close()
    assert [%{"code" => "invalid_period"} = rejected] = submit([premature])
    applied([start()])

    for value <- [nil, "bad", "2026-02-30", 123, [], %{}, "2026-10-03"] do
      assert [%{"code" => "invalid_period"}] = submit([close(value)])
    end

    assert [%{"code" => "invalid_period"}] = submit([Map.delete(close(), "period_end_on")])
    assert submit([premature]) == [rejected]

    cutoff = close() |> Map.put("expected_revision", %{"ignored" => true})
    assert [result] = applied([cutoff])

    assert result == %{
             "operation_id" => cutoff["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-10-04"
           }

    assert report("2026-10-04") == %{
             "date" => "2026-10-04",
             "status" => "closed",
             "cash" => [],
             "credit" => %{
               "opening_liability_cents" => 0,
               "movements" => zero(@credit_kinds),
               "closing_liability_cents" => 0
             },
             "late_adjustments" => %{"cash" => [], "credit" => zero(@credit_kinds)}
           }

    assert report("2026-10-05")["status"] == "open"
    assert [%{"code" => "invalid_period"}] = submit([close()])
    assert [%{"code" => "invalid_period"}] = submit([close("2026-10-03")])
    applied([close("2026-10-06")])
    assert submit([cutoff]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             submit([Map.put(cutoff, "period_end_on", "2026-10-07")])

    assert build_conn()
           |> get("/api/v1/operations/#{cutoff["operation_id"]}")
           |> json_response(200) == %{"data" => result}

    assert Repo.all(Entry) == []
    assert Repo.get!(Reporting, 1).closed_through == ~D[2026-10-06]
  end

  test "batch ordering fixes posting dates and later closes preserve published bytes" do
    payment = cash(100)
    rejected = cash(50_000)

    results =
      applied([
        open_group(),
        start(),
        payment,
        close("2026-10-05"),
        cash(200, "2026-10-05"),
        cash(30, "2026-09-01"),
        cash(40, "2026-10-06"),
        cash(50, "2026-10-09")
      ])

    closed = for day <- ["2026-10-04", "2026-10-05"], do: {day, report_bytes(day)}
    day = report("2026-10-06")
    assert [row] = day["cash"]
    assert row["opening_held_cents"] == 100
    assert row["closing_held_cents"] == 370
    assert row["movements"] == Map.put(zero(@cash_kinds), "received_cents", 40)
    assert day["late_adjustments"]["cash"] == [late_cash("ams-canal", %{"received_cents" => 230})]
    assert report("2026-10-09")["cash"] |> hd() |> get_in(["movements", "received_cents"]) == 50

    assert [%{"code" => "payment_exceeds_outstanding"}] = submit([rejected])
    assert submit([payment]) == [Enum.at(results, 2)]
    before = {Reservations.get_group("group-81"), Reservations.ledger(), Repo.all(Entry)}
    applied([close("2026-10-07")])
    assert {Reservations.get_group("group-81"), Reservations.ledger(), Repo.all(Entry)} == before
    published_adjustments = report_bytes("2026-10-06")
    assert report("2026-10-06")["status"] == "closed"

    applied([cash(60), close("2026-10-08"), cash(70)])
    assert report_bytes("2026-10-06") == published_adjustments
    assert Enum.map(closed, fn {day, _} -> {day, report_bytes(day)} end) == closed

    assert report("2026-10-08")["late_adjustments"]["cash"] ==
             [late_cash("ams-canal", %{"received_cents" => 60})]

    assert report("2026-10-09")["late_adjustments"]["cash"] ==
             [late_cash("ams-canal", %{"received_cents" => 70})]

    assert_reconciles("2026-10-09")
  end

  test "late transfers and corrections follow properties and retain zero-net signed classifications" do
    applied([
      open_group(%{"property_id" => "zurich"}),
      open_group(%{"group_id" => "refund", "property_id" => "amsterdam"}),
      open_group(%{
        "group_id" => "retain",
        "property_id" => "berlin",
        "rate_plan" => "advance_purchase"
      }),
      open_group(%{"group_id" => "convert", "property_id" => "copenhagen"}),
      start(),
      cash(1_000) |> Map.put("operation_id", "payment"),
      transfer("refund", 200),
      transfer("retain", 100),
      transfer("convert", 300),
      operation("cancel_group", %{"group_id" => "refund"}),
      operation("cancel_group", %{"group_id" => "retain"}),
      operation("cancel_group", %{"group_id" => "convert", "refund_method" => "hotel_credit"}),
      close()
    ])

    published = report_bytes("2026-10-04")
    correction = operation("charge_back_payment", %{"payment_operation_id" => "payment"})

    applied([
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 50
      }),
      correction
    ])

    day = report("2026-10-05")

    assert day["late_adjustments"]["cash"] == [
             late_cash("amsterdam", %{"refunded_cents" => -200, "charged_back_cents" => 200}),
             late_cash("berlin", %{"retained_cents" => -100, "charged_back_cents" => 100}),
             late_cash("copenhagen", %{
               "converted_to_credit_cents" => -300,
               "charged_back_cents" => 300
             }),
             late_cash("zurich", %{"reduced_cents" => 50, "charged_back_cents" => 350})
           ]

    assert Enum.map(day["cash"], & &1["property_id"]) == ~w(amsterdam berlin copenhagen zurich)
    assert Enum.all?(day["cash"], &(&1["movements"] == zero(@cash_kinds)))
    assert day["late_adjustments"]["credit"] == Map.put(zero(@credit_kinds), "revoked_cents", 330)
    assert report_bytes("2026-10-04") == published
    assert_reconciles("2026-10-05")
    entries = Repo.all(Entry)
    submit([correction])
    assert Repo.all(Entry) == entries

    applied([
      open_group(%{"group_id" => "destination", "property_id" => "oslo"}),
      cash(100),
      transfer("destination", 60)
    ])

    day = report("2026-10-05")
    assert late_for(day, "oslo")["transferred_in_cents"] == 60
    assert late_for(day, "zurich")["transferred_out_cents"] == 60
    assert_reconciles("2026-10-05")
  end

  test "late credit issuance and revocation leave natural future expiry ordinary" do
    applied([
      open_group(),
      start(),
      cash(100) |> Map.put("operation_id", "payment"),
      close(),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    day = report("2026-10-05")
    assert day["credit"]["movements"] == zero(@credit_kinds)
    assert day["late_adjustments"]["credit"] == Map.put(zero(@credit_kinds), "issued_cents", 110)
    expiry = report("2027-10-05")
    assert expiry["credit"]["movements"]["expired_cents"] == 110
    assert expiry["late_adjustments"]["credit"] == zero(@credit_kinds)

    applied([operation("charge_back_payment", %{"payment_operation_id" => "payment"})])
    assert report("2026-10-05")["late_adjustments"]["credit"]["revoked_cents"] == 110
    assert report("2027-10-05")["credit"]["movements"]["expired_cents"] == 0
    assert_reconciles("2027-10-05")
  end

  test "closed expiry is immutable when backdated redemption and restoration change liability" do
    applied([
      open_group(),
      start(),
      cash(100),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      close("2027-10-05")
    ])

    published = report_bytes("2027-10-05")
    assert report("2027-10-05")["credit"]["movements"]["expired_cents"] == 110
    applied([operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60})])
    day = report("2027-10-06")
    assert day["credit"]["opening_liability_cents"] == 0
    assert day["credit"]["closing_liability_cents"] == 60
    assert day["late_adjustments"]["credit"]["expired_cents"] == -60
    assert report_bytes("2027-10-05") == published
    assert_reconciles("2027-10-06")

    applied([close("2027-10-06")])
    redemption_day = report_bytes("2027-10-06")
    applied([operation("cancel_group", %{"group_id" => "target"})])
    assert report("2027-10-07")["late_adjustments"]["credit"]["expired_cents"] == 60
    assert report_bytes("2027-10-05") == published
    assert report_bytes("2027-10-06") == redemption_day
    assert_reconciles("2027-10-07")
  end

  test "late issuance after its expiry posts the entire credit effect on the first open day" do
    applied([
      open_group(),
      start(),
      cash(100),
      close("2027-10-05"),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    day = report("2027-10-06")

    assert day["late_adjustments"]["credit"] ==
             Map.merge(zero(@credit_kinds), %{"issued_cents" => 110, "expired_cents" => 110})

    assert day["credit"]["closing_liability_cents"] == 0
    assert_reconciles("2027-10-06")
  end

  test "late consumption and shortfall absorption settle applied credit after a close" do
    applied([
      open_group(),
      start(),
      cash(100) |> Map.put("operation_id", "payment"),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      future_group("nonrefundable", %{"rate_plan" => "advance_purchase"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60}),
      operation("apply_hotel_credit", %{"group_id" => "nonrefundable", "amount_cents" => 40}),
      close(),
      operation("charge_back_payment", %{"payment_operation_id" => "payment"}),
      operation("cancel_group", %{"group_id" => "target"}),
      operation("cancel_group", %{"group_id" => "nonrefundable"})
    ])

    day = report("2026-10-05")

    assert day["late_adjustments"]["credit"] ==
             Map.merge(zero(@credit_kinds), %{
               "revoked_cents" => 10,
               "absorbed_cents" => 60,
               "consumed_cents" => 40
             })

    assert_reconciles("2026-10-05")
  end

  test "batch and sequential submissions agree across multiple closes, expiry, and retries" do
    cutoff = close()

    operations = [
      open_group(),
      start(),
      cash(100),
      cutoff,
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      cutoff,
      close("2027-10-05"),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60})
    ]

    dates = ~w(2026-10-04 2026-10-05 2027-10-05 2027-10-06)
    Repo.query!("SAVEPOINT compare_close_submissions")
    results = applied(operations)
    reports = Enum.map(dates, &report_bytes/1)
    Repo.query!("ROLLBACK TO SAVEPOINT compare_close_submissions")
    Repo.query!("RELEASE SAVEPOINT compare_close_submissions")
    assert Enum.flat_map(operations, &submit([&1])) == results
    assert Enum.map(dates, &report_bytes/1) == reports
  end

  test "closing the last supported calendar day preserves reports and permits domain operations" do
    applied([open_group(), start(), cash(100), close("9999-12-31")])
    dates = ~w(2026-10-04 9999-12-31)
    published = Enum.map(dates, &report_bytes/1)
    applied([cash(25), operation("cancel_group", %{"refund_method" => "hotel_credit"})])
    assert Enum.map(dates, &report_bytes/1) == published
    assert Reservations.get_group("group-81").status == "cancelled"
    assert Reservations.ledger(~D[2026-10-04]).cash_converted_to_credit_cents == 125
  end

  defp start,
    do:
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
      |> Map.delete("group_id")

  defp close(date \\ "2026-10-04"),
    do: operation("close_finance_period", %{"period_end_on" => date}) |> Map.delete("group_id")

  defp cash(amount, date \\ "2026-10-04"),
    do: operation("record_cash_payment", %{"amount_cents" => amount, "occurred_on" => date})

  defp transfer(destination, amount),
    do:
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp future_group(id, extra \\ %{}),
    do:
      open_group(
        Map.merge(
          %{"group_id" => id, "arrival_on" => "2028-12-10", "departure_on" => "2028-12-13"},
          extra
        )
      )

  defp zero(kinds), do: Map.new(kinds, &{&1, 0})

  defp late_cash(property, amounts),
    do: %{"property_id" => property, "movements" => Map.merge(zero(@cash_kinds), amounts)}

  defp late_for(day, property),
    do: Enum.find(day["late_adjustments"]["cash"], &(&1["property_id"] == property))["movements"]

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp applied(operations) do
    results = submit(operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp report_bytes(date) do
    conn = build_conn() |> get("/api/v1/finance/daily-report", %{"date" => date})
    assert conn.status == 200
    conn.resp_body
  end

  defp report(date) do
    data = report_bytes(date) |> Jason.decode!() |> Map.fetch!("data")

    for row <- data["cash"] do
      late = late_for(data, row["property_id"]) || zero(@cash_kinds)
      total = Map.merge(row["movements"], late, fn _, a, b -> a + b end)

      effect =
        Enum.reduce(total, 0, fn {kind, cents}, sum ->
          sum + if(kind in ~w(received_cents transferred_in_cents), do: cents, else: -cents)
        end)

      assert row["closing_held_cents"] == row["opening_held_cents"] + effect
    end

    credit = data["credit"]

    total =
      Map.merge(credit["movements"], data["late_adjustments"]["credit"], fn _, a, b -> a + b end)

    effect =
      Enum.reduce(total, 0, fn {kind, cents}, sum ->
        sum + if(kind == "issued_cents", do: cents, else: -cents)
      end)

    assert credit["closing_liability_cents"] == credit["opening_liability_cents"] + effect
    data
  end

  defp assert_reconciles(date) do
    day = report(date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))
    assert Enum.sum(Enum.map(day["cash"], & &1["closing_held_cents"])) == ledger.cash_held_cents
    assert day["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end
end
