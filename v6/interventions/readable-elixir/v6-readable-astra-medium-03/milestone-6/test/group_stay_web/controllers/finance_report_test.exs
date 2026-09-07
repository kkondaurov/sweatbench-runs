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

    assert Map.keys(data) |> Enum.sort() == ~w(cash credit date status)
    assert data["status"] == "open"

    for cash <- data["cash"] do
      m = cash["movements"]
      assert map_size(cash) == 4
      assert map_size(m) == 8

      assert cash["closing_held_cents"] ==
               cash["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    c = data["credit"]
    m = c["movements"]
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
end
