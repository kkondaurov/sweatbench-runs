defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-10-01"
      },
      attrs
    )
  end

  defp open(id, attrs \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2029-12-01",
          "departure_on" => "2029-12-02",
          "rate_plan" => "flexible",
          "rooms" => [
            %{"room_id" => "a", "nightly_rate_cents" => 5000},
            %{"room_id" => "b", "nightly_rate_cents" => 5000}
          ]
        },
        attrs
      )
    )
  end

  defp submit(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => List.wrap(ops)})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(ops) do
    results = submit(ops)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp start(on \\ "2026-10-01"), do: op("start_finance_reporting", %{"starts_on" => on})

  defp cash(group, amount),
    do: op("record_cash_payment", %{"group_id" => group, "amount_cents" => amount})

  defp cancel(group, attrs \\ %{}), do: op("cancel_group", Map.put(attrs, "group_id", group))

  defp credit(group, amount),
    do: op("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp transfer(source, destination, amount),
    do:
      op("transfer_deposit", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp report(on \\ "2026-10-01") do
    data =
      build_conn()
      |> get("/api/v1/finance/daily-report", %{"date" => on})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Map.keys(data) |> Enum.sort() == ~w(cash credit date late_adjustments status)
    assert data["status"] in ["open", "closed"]

    assert Map.keys(data["late_adjustments"]) |> Enum.sort() == ~w(cash credit)
    assert map_size(data["late_adjustments"]["credit"]) == 5
    late_cash = data["late_adjustments"]["cash"]

    assert Enum.map(late_cash, & &1["property_id"]) ==
             Enum.sort(Enum.map(late_cash, & &1["property_id"]))

    for entry <- late_cash do
      assert Map.keys(entry) |> Enum.sort() == ~w(movements property_id)
      assert map_size(entry["movements"]) == 8
      assert Enum.any?(entry["movements"], fn {_, amount} -> amount != 0 end)
    end

    for cash <- data["cash"] do
      late =
        Enum.find(data["late_adjustments"]["cash"], &(&1["property_id"] == cash["property_id"]))

      m =
        Map.merge(cash["movements"], if(late, do: late["movements"], else: %{}), fn _, a, b ->
          a + b
        end)

      assert map_size(cash) == 4
      assert map_size(m) == 8

      assert cash["closing_held_cents"] ==
               cash["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    c = data["credit"]
    m = Map.merge(c["movements"], data["late_adjustments"]["credit"], fn _, a, b -> a + b end)
    assert map_size(c) == 3
    assert map_size(m) == 5

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    data
  end

  test "date validation, singleton inception, durable retries and exact response" do
    for params <- [%{}, %{"date" => "2026-02-30"}, %{"date" => ["2026-10-01"]}] do
      assert build_conn() |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for value <- [nil, "bad", 4, "2026-02-30"] do
      assert [%{"code" => "invalid_reporting_date"}] = submit(start(value))
    end

    assert [%{"code" => "invalid_reporting_date"}] = submit(op("start_finance_reporting"))
    operation = start()
    [result] = apply!(operation)

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-10-01"
           }

    assert submit(operation) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(Map.put(operation, "starts_on", "2026-10-02"))

    assert [%{"code" => "reporting_already_started"}] = submit(start())

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-09-30")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert report()["cash"] == []
    assert report()["credit"]["closing_liability_cents"] == 0
  end

  test "opening includes committed future-dated operations; later backdated postings and retries" do
    prior = cash("hotel", 500) |> Map.put("occurred_on", "2028-01-01")
    later = cash("hotel", 300)
    rejected = cash("hotel", 3000)
    results = submit([open("hotel"), prior, start("2027-01-01"), later, rejected])
    assert List.last(results)["code"] == "payment_exceeds_outstanding"
    [entry] = report("2027-01-01")["cash"]
    assert entry["opening_held_cents"] == 500
    assert entry["closing_held_cents"] == 800
    assert entry["movements"]["received_cents"] == 300
    before = report("2027-01-01")
    submit([later, rejected])
    assert report("2027-01-01") == before
    assert hd(report("2028-01-01")["cash"])["movements"]["received_cents"] == 0
    apply!(cash("hotel", 100) |> Map.put("occurred_on", "2027-01-02"))
    assert hd(report("2027-01-03")["cash"])["opening_held_cents"] == 900
    assert report("2027-01-01") == before
  end

  test "transferred cash corrections stay with settlement and holding properties" do
    payment = cash("source", 1000)

    apply!([
      open("source"),
      open("refund"),
      open("retained", %{"rate_plan" => "advance_purchase"}),
      start(),
      payment,
      transfer("source", "refund", 300),
      transfer("source", "retained", 200),
      cancel("refund"),
      cancel("retained")
    ])

    reduction =
      op("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 100
      })

    apply!(reduction)

    apply!(
      op("charge_back_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "occurred_on" => "2026-10-02"
      })
    )

    entries = report("2026-10-02")["cash"]
    assert Enum.map(entries, & &1["property_id"]) == ~w(refund retained source)
    [refund, retained, source] = entries
    assert refund["movements"]["refunded_cents"] == -300
    assert refund["movements"]["charged_back_cents"] == 300
    assert retained["movements"]["retained_cents"] == -200
    assert retained["movements"]["charged_back_cents"] == 200
    assert source["opening_held_cents"] == 400
    assert source["movements"]["charged_back_cents"] == 400
    assert Enum.all?(entries, &(&1["closing_held_cents"] == 0))
    assert report("2026-10-03")["cash"] == []
  end

  test "same-property mixed transfers report gross cash transfers only" do
    apply!([
      open("issuer"),
      cash("issuer", 100),
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      open("a", %{"property_id" => "hotel"}),
      open("b", %{"property_id" => "hotel"}),
      start(),
      cash("a", 100),
      credit("a", 110),
      transfer("a", "b", 160)
    ])

    [entry] = report()["cash"]
    assert entry["movements"]["transferred_in_cents"] == 50
    assert entry["movements"]["transferred_out_cents"] == 50
    assert report()["credit"]["opening_liability_cents"] == 110
    assert Enum.all?(report()["credit"]["movements"], fn {_, n} -> n == 0 end)
  end

  test "inception credit expires without operations; applied credit pauses expiry" do
    apply!([
      open("issuer"),
      cash("issuer", 100),
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      open("user"),
      start(),
      credit("user", 40)
    ])

    assert report("2027-10-01")["credit"]["closing_liability_cents"] == 110
    expiry = report("2027-10-02")
    assert expiry["credit"]["movements"]["expired_cents"] == 70
    assert expiry["credit"]["closing_liability_cents"] == 40
    apply!(cancel("user", %{"occurred_on" => "2027-10-03"}))
    assert report("2027-10-03")["credit"]["movements"]["expired_cents"] == 40
    assert report("2027-10-03")["credit"]["closing_liability_cents"] == 0
    assert report("2027-10-02") == expiry
    assert report()["credit"]["closing_liability_cents"] == 110
  end

  test "issuance, revocation, shortfall absorption and expired restoration reconcile" do
    payment = cash("issuer", 100)

    apply!([
      open("issuer"),
      open("user"),
      start(),
      payment,
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      credit("user", 60)
    ])

    assert report()["credit"]["movements"]["issued_cents"] == 110

    apply!(
      op("charge_back_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "occurred_on" => "2026-10-02"
      })
    )

    assert report("2026-10-02")["credit"]["movements"]["revoked_cents"] == 50
    assert report("2026-10-02")["credit"]["closing_liability_cents"] == 60
    apply!(cancel("user", %{"occurred_on" => "2027-10-03"}))
    restored = report("2027-10-03")["credit"]
    assert restored["movements"]["absorbed_cents"] == 60
    assert restored["movements"]["expired_cents"] == 0
    assert restored["closing_liability_cents"] == 0
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 0
    assert GroupStay.Reservations.ledger(~D[2027-10-03]).credit_liability_cents == 0
  end

  test "credit restoration before expiry reschedules expiry; nonrefundable credit is consumed" do
    apply!([
      open("issuer"),
      open("user"),
      open("nonref", %{"rate_plan" => "advance_purchase"}),
      start(),
      cash("issuer", 100),
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      credit("user", 50),
      credit("nonref", 40),
      cancel("user"),
      cancel("nonref")
    ])

    c = report()["credit"]
    assert c["movements"]["issued_cents"] == 110
    assert c["movements"]["consumed_cents"] == 40
    assert c["closing_liability_cents"] == 70
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 70
    assert report("2027-10-02")["credit"]["closing_liability_cents"] == 0
  end

  test "equivalent batches and sequential submissions yield identical reports" do
    payment = cash("source", 500)

    operations = [
      open("source"),
      open("destination"),
      start(),
      payment,
      transfer("source", "destination", 200),
      cancel("destination", %{"refund_method" => "hotel_credit"}),
      credit("source", 100),
      op("charge_back_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "occurred_on" => "2026-10-03"
      }),
      cancel("source", %{"occurred_on" => "2026-10-02"})
    ]

    dates = ~w(2026-10-01 2026-10-02 2026-10-03 2027-10-02)

    {:error, batched} =
      GroupStay.Repo.transaction(fn ->
        apply!(operations)
        GroupStay.Repo.rollback(Enum.map(dates, &report/1))
      end)

    Enum.each(operations, &apply!/1)
    assert Enum.map(dates, &report/1) == batched

    assert report("2027-10-02")["credit"]["closing_liability_cents"] ==
             GroupStay.Reservations.ledger(~D[2027-10-02]).credit_liability_cents
  end

  test "partial settlement bonuses, transferred converted cash and late revocation" do
    payment = cash("source", 1505)

    apply!([
      open("source"),
      open("destination"),
      start(),
      payment,
      transfer("source", "destination", 505),
      op("cancel_rooms", %{
        "group_id" => "destination",
        "room_ids" => ["a"],
        "refund_method" => "hotel_credit"
      })
    ])

    assert report()["credit"]["movements"]["issued_cents"] == 556
    entries = Map.new(report()["cash"], &{&1["property_id"], &1})
    assert entries["destination"]["movements"]["converted_to_credit_cents"] == 505
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 556

    apply!(
      op("charge_back_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "occurred_on" => "2027-10-03"
      })
    )

    entries = Map.new(report("2027-10-03")["cash"], &{&1["property_id"], &1})
    assert entries["destination"]["movements"]["converted_to_credit_cents"] == -505
    assert entries["destination"]["movements"]["charged_back_cents"] == 505
    assert entries["source"]["movements"]["charged_back_cents"] == 1000
    assert report("2027-10-03")["credit"]["movements"]["revoked_cents"] == 0
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 556
  end

  defp close(on),
    do: op("close_finance_period", %{"period_end_on" => on}) |> Map.delete("occurred_on")

  test "close validates the period, remembers rejections and replays exact results" do
    early = close("2026-10-01")
    assert [%{"code" => "invalid_period"} = rejected] = submit(early)
    apply!(start())
    assert submit(early) == [rejected]

    for value <- [nil, 12, %{}, "bad", "2026-02-30", "2026-09-30"] do
      assert [%{"code" => "invalid_period"}] = submit(close(value))
    end

    assert [%{"code" => "invalid_period"}] = submit(op("close_finance_period"))
    operation = close("2026-10-02") |> Map.put("expected_revision", -1)
    [result] = apply!(operation)

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-10-02"
           }

    assert submit(operation) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(Map.put(operation, "period_end_on", "2026-10-03"))

    for on <- ~w(2026-10-01 2026-10-02),
        do: assert([%{"code" => "invalid_period"}] = submit(close(on)))

    assert report()["status"] == "closed"
    assert report("2026-10-02")["status"] == "closed"
    assert report("2026-10-03")["status"] == "open"
  end

  test "same-batch close fixes posting dates and separates ordinary from late cash" do
    late = cash("hotel", 200)

    apply!([
      open("hotel"),
      start(),
      cash("hotel", 100),
      close("2026-10-01"),
      late,
      cash("hotel", 300) |> Map.put("occurred_on", "2026-10-02"),
      cash("hotel", 400) |> Map.put("occurred_on", "2026-10-04")
    ])

    published = report() |> Jason.encode!()
    assert hd(report()["cash"])["closing_held_cents"] == 100
    day = report("2026-10-02")
    assert hd(day["cash"])["movements"]["received_cents"] == 300
    assert hd(day["late_adjustments"]["cash"])["movements"]["received_cents"] == 200
    assert hd(day["cash"])["closing_held_cents"] == 600
    assert submit(late) == [GroupStay.Operations.get_result(late["operation_id"])]
    assert [%{"code" => "payment_exceeds_outstanding"}] = submit(cash("hotel", 5000))
    assert report("2026-10-02") == day
    apply!(close("2026-10-03"))
    assert report() |> Jason.encode!() == published
    assert Map.put(day, "status", "closed") == report("2026-10-02")
    assert hd(report("2026-10-04")["cash"])["movements"]["received_cents"] == 400
    assert report("2026-10-04")["late_adjustments"]["cash"] == []
  end

  test "late chargeback preserves zero-net signed classifications at settlement properties" do
    payment = cash("source", 500)

    apply!([
      open("source"),
      open("refund"),
      start(),
      payment,
      transfer("source", "refund", 200),
      cancel("refund"),
      close("2026-10-01")
    ])

    published = report()
    apply!(op("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]}))
    day = report("2026-10-02")
    assert Enum.map(day["cash"], & &1["property_id"]) == ~w(refund source)
    [refund, source] = day["late_adjustments"]["cash"]
    assert refund["movements"]["refunded_cents"] == -200
    assert refund["movements"]["charged_back_cents"] == 200
    assert source["movements"]["charged_back_cents"] == 300
    assert Enum.all?(day["cash"], fn c -> Enum.all?(c["movements"], fn {_, n} -> n == 0 end) end)
    assert report() == published
    assert GroupStay.Reservations.ledger(~D[2026-10-02]).cash_charged_back_cents == 500
  end

  test "closed expiry is stable when backdated credit is redeemed and restored" do
    apply!([
      open("issuer"),
      open("user"),
      start(),
      cash("issuer", 100),
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      close("2027-10-02")
    ])

    expired = report("2027-10-02")
    assert expired["credit"]["movements"]["expired_cents"] == 110
    apply!(credit("user", 40))
    day = report("2027-10-03")
    assert day["late_adjustments"]["credit"]["expired_cents"] == -40
    assert day["credit"]["closing_liability_cents"] == 40
    apply!(close("2027-10-03"))
    published = report("2027-10-03")
    apply!(cancel("user"))
    assert report("2027-10-04")["late_adjustments"]["credit"]["expired_cents"] == 40
    assert report("2027-10-04")["credit"]["closing_liability_cents"] == 0
    assert report("2027-10-02") == expired
    assert report("2027-10-03") == published
  end

  test "deferred issuance and revocation adjust future ordinary expiry" do
    payment = cash("issuer", 100)

    apply!([
      open("issuer"),
      open("user"),
      start(),
      payment,
      close("2026-10-01"),
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      credit("user", 60)
    ])

    assert report("2026-10-02")["late_adjustments"]["credit"]["issued_cents"] == 110
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 50
    apply!(op("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]}))
    assert report("2026-10-02")["late_adjustments"]["credit"]["revoked_cents"] == 50
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 0
    apply!(cancel("user"))
    assert report("2026-10-02")["late_adjustments"]["credit"]["absorbed_cents"] == 60
    assert report("2026-10-02")["credit"]["closing_liability_cents"] == 0
  end

  test "late transfers, reductions and consumption agree in batches and sequential submissions" do
    payment = cash("source", 500)

    operations = [
      open("source"),
      open("destination"),
      open("nonref", %{"rate_plan" => "advance_purchase"}),
      start("2026-10-02"),
      payment,
      close("2026-10-02"),
      transfer("source", "destination", 200),
      op("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 50
      }),
      cancel("destination", %{"refund_method" => "hotel_credit"}),
      credit("nonref", 100),
      cancel("nonref"),
      close("2026-10-03")
    ]

    dates = ~w(2026-10-02 2026-10-03 2027-10-02)

    {:error, batched} =
      GroupStay.Repo.transaction(fn ->
        apply!(operations)
        GroupStay.Repo.rollback(Enum.map(dates, &report/1))
      end)

    Enum.each(operations, &apply!/1)
    assert Enum.map(dates, &report/1) == batched
    day = report("2026-10-03")
    [destination, source] = day["late_adjustments"]["cash"]
    assert destination["movements"]["transferred_in_cents"] == 200
    assert source["movements"]["transferred_out_cents"] == 200
    assert destination["movements"]["reduced_cents"] == 50
    assert destination["movements"]["converted_to_credit_cents"] == 150
    assert day["late_adjustments"]["credit"]["issued_cents"] == 165
    assert day["late_adjustments"]["credit"]["consumed_cents"] == 100
    assert day["credit"]["closing_liability_cents"] == 65
    assert hd(report("2026-10-02")["cash"])["movements"]["received_cents"] == 500
    assert report("2026-10-02")["late_adjustments"]["cash"] == []
  end
end
