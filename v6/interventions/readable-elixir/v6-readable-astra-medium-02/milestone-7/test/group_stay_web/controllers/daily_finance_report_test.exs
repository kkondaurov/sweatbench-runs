defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false
  alias GroupStay.{Repo, Finance.Entry}

  defp op(type, id, fields \\ %{}),
    do: Map.merge(%{"type" => type, "operation_id" => id, "occurred_on" => "2027-01-01"}, fields)

  defp open(id, fields \\ %{}) do
    op(
      "open_group",
      "open-" <> id,
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2029-06-01",
          "departure_on" => "2029-06-02",
          "rate_plan" => "flexible",
          "rooms" => for(room <- ~w(a b c), do: %{"room_id" => room, "nightly_rate_cents" => 500})
        },
        fields
      )
    )
  end

  defp start, do: op("start_finance_reporting", "start", %{"starts_on" => "2027-01-02"})

  defp pay(id, group, amount),
    do: op("record_cash_payment", id, %{"group_id" => group, "amount_cents" => amount})

  defp cancel(id, group, fields \\ %{}),
    do: op("cancel_group", id, Map.put(fields, "group_id", group))

  defp transfer(id, source, destination, amount),
    do:
      op("transfer_deposit", id, %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp apply_credit(id, group, amount),
    do: op("apply_hotel_credit", id, %{"group_id" => group, "amount_cents" => amount})

  defp chargeback(id, payment),
    do: op("charge_back_payment", id, %{"payment_operation_id" => payment})

  defp on(operation, date), do: Map.put(operation, "occurred_on", date)

  defp batch(operations),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp report(date \\ "2027-01-02"), do: read("finance/daily-report?date=" <> date)
  defp cash(report, property), do: Enum.find(report["cash"], &(&1["property_id"] == property))

  defp reconcile(report) do
    for row <- report["cash"] do
      m = row["movements"]

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]

      assert map_size(row) == 4
      assert map_size(m) == 8
    end

    credit = report["credit"]
    m = credit["movements"]

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    assert map_size(credit) == 3
    assert map_size(m) == 5
  end

  test "batch and sequential submissions produce identical reports" do
    operations = [
      open("issuer"),
      pay("seed", "issuer", 100),
      start(),
      cancel("issue", "issuer", %{"refund_method" => "hotel_credit"}),
      open("a"),
      open("b"),
      apply_credit("use", "a", 80),
      pay("cash", "a", 50),
      transfer("move", "a", "b", 100),
      cancel("settle", "b"),
      on(chargeback("clawback", "seed"), "2027-02-01")
    ]

    dates = ~w(2027-01-02 2027-02-01 2028-01-02)
    Repo.query!("SAVEPOINT compare_batches")
    batch(operations)
    batched = Enum.map(dates, &report/1)
    Repo.query!("ROLLBACK TO compare_batches")
    Repo.query!("RELEASE compare_batches")
    Enum.each(operations, &batch([&1]))
    assert Enum.map(dates, &report/1) == batched
    Enum.each(batched, &reconcile/1)

    for day <- batched do
      assert Enum.map(day["cash"], & &1["property_id"]) ==
               Enum.sort(Enum.map(day["cash"], & &1["property_id"]))

      assert Enum.sum(Enum.map(day["cash"], & &1["movements"]["transferred_in_cents"])) ==
               Enum.sum(Enum.map(day["cash"], & &1["movements"]["transferred_out_cents"]))
    end
  end

  test "inception excludes expired unused credit but includes applied credit with paused expiry" do
    batch([
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("issue", "issuer", %{"refund_method" => "hotel_credit"}),
      open("use"),
      apply_credit("use", "use", 80),
      Map.merge(start(), %{"starts_on" => "2028-01-02", "expected_revision" => "ignored"})
    ])

    day = report("2028-01-02")
    assert day["credit"]["opening_liability_cents"] == 80
    assert day["credit"]["movements"]["expired_cents"] == 0
    batch([on(cancel("restore", "use"), "2028-01-03")])
    assert report("2028-01-03")["credit"]["movements"]["expired_cents"] == 80
    assert report("2028-01-03")["credit"]["closing_liability_cents"] == 0
    reconcile(report("2028-01-03"))
  end

  test "validates dates, persists inception, and preserves durable replay and rejection" do
    for query <- ["", "?date=bad", "?date=2027-02-29"] do
      assert build_conn() |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-02")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for {value, index} <- Enum.with_index([nil, "bad", 123, "2027-02-29"]) do
      assert [%{"code" => "invalid_reporting_date"}] =
               batch([op("start_finance_reporting", "invalid-#{index}", %{"starts_on" => value})])
    end

    assert [%{"code" => "invalid_reporting_date"}] =
             batch([op("start_finance_reporting", "missing")])

    [_, _, original, _] =
      batch([open("a"), on(pay("p", "a", 100), "2028-01-01"), start(), pay("later", "a", 50)])

    assert original == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-02"
           }

    assert [
             ^original,
             %{"code" => "reporting_already_started"},
             %{"code" => "operation_id_conflict"}
           ] =
             batch([
               start(),
               op("start_finance_reporting", "another", %{"starts_on" => "2027-01-03"}),
               Map.put(start(), "starts_on", "2027-01-03")
             ])

    assert cash(report(), "a")["opening_held_cents"] == 100
    assert cash(report(), "a")["movements"]["received_cents"] == 50
    assert cash(report("2028-01-01"), "a")["closing_held_cents"] == 150
    assert read("operations/start") == original

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-01")
           |> json_response(404)

    reconcile(report())
  end

  test "cash corrections follow held and settled properties with signed reversals" do
    batch([
      start(),
      open("s"),
      open("refund"),
      open("retain", %{"rate_plan" => "advance_purchase"}),
      open("convert"),
      pay("p", "s", 300),
      transfer("t1", "s", "refund", 100),
      transfer("t2", "s", "retain", 100),
      transfer("t3", "s", "convert", 50),
      cancel("refund", "refund"),
      cancel("retain", "retain"),
      cancel("convert", "convert", %{"refund_method" => "hotel_credit"})
    ])

    reduction =
      on(
        op("reduce_cash_payment", "reduce", %{"payment_operation_id" => "p", "amount_cents" => 20}),
        "2027-01-03"
      )

    cb = on(chargeback("cb", "p"), "2027-01-03")
    results = batch([reduction, cb, pay("rejected", "s", 999)])
    assert List.last(results)["status"] == "rejected"
    day = report("2027-01-03")
    assert cash(day, "s")["movements"]["reduced_cents"] == 20
    assert cash(day, "s")["movements"]["charged_back_cents"] == 30

    for {property, column, amount} <- [
          {"refund", "refunded_cents", 100},
          {"retain", "retained_cents", 100},
          {"convert", "converted_to_credit_cents", 50}
        ] do
      assert cash(day, property)["movements"][column] == -amount
      assert cash(day, property)["movements"]["charged_back_cents"] == amount
      assert cash(day, property)["closing_held_cents"] == 0
    end

    assert day["credit"]["movements"]["revoked_cents"] == 55
    entries = Repo.all(Entry)
    assert batch([reduction, cb, pay("rejected", "s", 999)]) == results
    assert Repo.all(Entry) == entries
    assert report("2027-01-03") == day
    assert report("2027-01-04")["cash"] == []
    reconcile(day)
    reconcile(report())
  end

  test "mixed transfers report only cash including transfers within one property" do
    batch([
      open("issuer"),
      pay("seed", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      start(),
      open("s"),
      open("d", %{"property_id" => "s"}),
      pay("p", "s", 100),
      apply_credit("use", "s", 100),
      transfer("t", "s", "d", 150)
    ])

    row = cash(report(), "s")
    assert row["movements"]["transferred_in_cents"] == 50
    assert row["movements"]["transferred_out_cents"] == 50
    assert report()["credit"]["opening_liability_cents"] == 110
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 10
    assert report("2028-01-02")["credit"]["closing_liability_cents"] == 100
    reconcile(report())
  end

  test "expiry, paused credit, restoration and shortfall absorption reconcile without read effects" do
    batch([
      start(),
      open("issuer"),
      pay("p1", "issuer", 50),
      pay("p2", "issuer", 50),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("use"),
      apply_credit("use", "use", 100),
      chargeback("cb", "p1")
    ])

    assert report()["credit"]["movements"] == %{
             "issued_cents" => 110,
             "expired_cents" => 0,
             "consumed_cents" => 0,
             "revoked_cents" => 10,
             "absorbed_cents" => 0
           }

    batch([on(cancel("restore", "use"), "2028-01-02")])
    day = report("2028-01-02")
    assert day["credit"]["movements"]["absorbed_cents"] == 45
    assert day["credit"]["movements"]["expired_cents"] == 55
    assert day["credit"]["closing_liability_cents"] == 0
    before = Repo.all(Entry)

    for date <- ["2030-01-01", "2027-01-02", "2028-01-02", "2028-01-01"] do
      reconcile(report(date))
    end

    assert Repo.all(Entry) == before
    assert read("ledger?on=2028-01-02")["credit_liability_cents"] == 0
  end

  test "unused expiry is scheduled, backdated submissions revise open days, and restoration reschedules expiry" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("use")
    ])

    assert report("2028-01-01")["credit"]["closing_liability_cents"] == 110
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 110
    batch([on(apply_credit("use", "use", 100), "2027-02-01")])
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 10
    batch([on(cancel("restore", "use"), "2027-03-01")])
    assert report("2027-03-01")["credit"]["closing_liability_cents"] == 110
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 110
    reconcile(report("2028-01-02"))
  end

  test "nonrefundable credit consumption and expired revocation do not double count liability" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("use", %{"rate_plan" => "advance_purchase"}),
      apply_credit("use", "use", 80)
    ])

    batch([on(cancel("consume", "use"), "2027-02-01"), on(chargeback("cb", "p"), "2028-01-03")])
    assert report("2027-02-01")["credit"]["movements"]["consumed_cents"] == 80
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 30
    assert report("2028-01-03")["credit"]["movements"]["revoked_cents"] == 0
    assert report("2028-01-03")["credit"]["closing_liability_cents"] == 0
  end
end
