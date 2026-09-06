defmodule GroupStayWeb.FinanceReportingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{
    CreditAllocation,
    CreditLot,
    FinanceEntry,
    FundingAllocation,
    Group,
    Operation,
    Repo
  }

  defp op(type, fields \\ %{}, date \\ "2026-11-01") do
    Map.merge(
      %{
        "operation_id" => "finance-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => date
      },
      fields
    )
  end

  defp open(id, property \\ "hotel", fields \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "property_id" => property,
          "guest_id" => "guest",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-02",
          "rate_plan" => "flexible",
          "rooms" => for(i <- 1..4, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
        },
        fields
      )
    )
  end

  defp pay(group, amount, date \\ "2026-11-01"),
    do: op("record_cash_payment", %{"group_id" => group, "amount_cents" => amount}, date)

  defp cancel(group, method \\ "cash", date \\ "2026-11-01"),
    do: op("cancel_group", %{"group_id" => group, "refund_method" => method}, date)

  defp credit(group, amount, date \\ "2026-11-01"),
    do: op("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount}, date)

  defp transfer(source, destination, amount),
    do:
      op("transfer_deposit", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp charge(payment, date \\ "2026-11-01"),
    do: op("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]}, date)

  defp start(date \\ "2026-11-01"), do: op("start_finance_reporting", %{"starts_on" => date})

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => List.wrap(operations)})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(operations) do
    results = submit(operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp read(path),
    do: build_conn() |> get("/api/v1/#{path}") |> json_response(200) |> Map.fetch!("data")

  defp report(date \\ "2026-11-01") do
    report = read("finance/daily-report?date=#{date}")
    assert Enum.sort(Map.keys(report)) == ~w(cash credit date late_adjustments status)
    assert report["date"] == date
    assert report["status"] == "open"

    assert report["late_adjustments"] == %{
             "cash" => [],
             "credit" =>
               Map.new(
                 ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
                 &{&1, 0}
               )
           }

    for row <- report["cash"] do
      assert Enum.sort(Map.keys(row)) ==
               ~w(closing_held_cents movements opening_held_cents property_id)

      m = row["movements"]

      assert Enum.sort(Map.keys(m)) ==
               ~w(charged_back_cents converted_to_credit_cents received_cents reduced_cents refunded_cents retained_cents transferred_in_cents transferred_out_cents)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    assert Enum.map(report["cash"], & &1["property_id"]) ==
             Enum.sort(Enum.map(report["cash"], & &1["property_id"]))

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

    c = report["credit"]
    assert Enum.sort(Map.keys(c)) == ~w(closing_liability_cents movements opening_liability_cents)
    m = c["movements"]

    assert Enum.sort(Map.keys(m)) ==
             ~w(absorbed_cents consumed_cents expired_cents issued_cents revoked_cents)

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    report
  end

  defp reconcile(date \\ "2026-11-01") do
    report = report(date)
    ledger = read("ledger?on=#{date}")

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger["cash_held_cents"]

    assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    report
  end

  defp snapshot,
    do:
      Enum.map(
        [Group, CreditLot, CreditAllocation, FundingAllocation, Operation, FinanceEntry],
        &Repo.all/1
      )

  test "validates dates, availability and singleton start, including exact replay and conflicts" do
    for query <- ["", "?date=bad", "?date=2026-02-30", "?date[]=2026-11-01"] do
      assert build_conn() |> get("/api/v1/finance/daily-report#{query}") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-11-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for value <- [nil, "bad", "2026-02-30", 1, %{}, []] do
      assert [%{"code" => "invalid_reporting_date"}] =
               submit(op("start_finance_reporting", %{"starts_on" => value}))
    end

    assert [%{"code" => "invalid_reporting_date"}] = submit(op("start_finance_reporting"))
    operation = start() |> Map.put("expected_revision", "ignored") |> Map.delete("occurred_on")
    [result] = apply!(operation)

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-11-01"
           }

    before = snapshot()
    assert submit(operation) == [result]
    assert snapshot() == before

    assert [%{"code" => "operation_id_conflict"}] =
             submit(Map.put(operation, "starts_on", "2026-11-02"))

    assert [%{"code" => "reporting_already_started"}] = submit(start())

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-31")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert reconcile()["cash"] == []
    assert reconcile()["credit"]["closing_liability_cents"] == 0
  end

  test "inception uses committed state, posting clamps old dates, and late submissions update open days" do
    first = pay("g", 50, "2028-01-01")
    next = pay("g", 25, "2026-01-01")
    [_, original, _, _, _] = apply!([open("g"), first, open("empty"), start(), next])
    assert [row] = reconcile()["cash"]
    assert row["opening_held_cents"] == 50
    assert row["movements"]["received_cents"] == 25
    assert row["closing_held_cents"] == 75
    apply!(pay("g", 10, "2026-11-03"))
    assert hd(report("2026-11-03")["cash"])["opening_held_cents"] == 75
    later = pay("g", 15, "2026-11-02")
    apply!(later)
    assert hd(report("2026-11-02")["cash"])["closing_held_cents"] == 90
    assert hd(reconcile("2026-11-03")["cash"])["opening_held_cents"] == 90
    before = snapshot()
    assert submit(first) == [original]
    assert snapshot() == before
    future = report("2030-01-01")
    old = report()
    assert report("2030-01-01") == future
    assert report() == old
    assert snapshot() == before
  end

  test "cash transfers and corrections follow held and settled property, with signed reversals" do
    payment = pay("source", 400)

    apply!([
      start(),
      open("source", "origin"),
      payment,
      open("refund", "a"),
      open("retain", "b", %{"rate_plan" => "advance_purchase"}),
      open("convert", "c"),
      open("held", "d")
    ])

    for id <- ~w(refund retain convert held), do: apply!(transfer("source", id, 100))

    apply!([
      cancel("refund"),
      cancel("retain"),
      cancel("convert", "hotel_credit"),
      op("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 10
      })
    ])

    first = reconcile()
    assert first["credit"]["movements"]["issued_cents"] == 110
    correction = charge(payment, "2026-11-02")
    apply!(correction)
    rows = Map.new(reconcile("2026-11-02")["cash"], &{&1["property_id"], &1})
    refute Map.has_key?(rows, "origin")

    for {property, classification} <- [
          {"a", "refunded_cents"},
          {"b", "retained_cents"},
          {"c", "converted_to_credit_cents"}
        ] do
      assert rows[property]["movements"][classification] == -100
      assert rows[property]["movements"]["charged_back_cents"] == 100
      assert rows[property]["closing_held_cents"] == 0
    end

    assert rows["d"]["opening_held_cents"] == 90
    assert rows["d"]["movements"]["charged_back_cents"] == 90
    assert reconcile("2026-11-02")["credit"]["movements"]["revoked_cents"] == 110
    before = snapshot()
    apply!(correction)
    assert snapshot() == before
    assert report() == first
    assert reconcile("2026-11-03")["cash"] == []
  end

  test "same-property transfers report both directions and mixed funding reports only cash" do
    apply!([
      open("issuer"),
      pay("issuer", 100),
      cancel("issuer", "hotel_credit"),
      open("source"),
      open("destination"),
      pay("source", 100),
      credit("source", 100),
      start()
    ])

    apply!(transfer("source", "destination", 150))
    assert [row] = reconcile()["cash"]
    assert row["opening_held_cents"] == 100
    assert row["movements"]["transferred_in_cents"] == 50
    assert row["movements"]["transferred_out_cents"] == 50
    assert reconcile()["credit"]["opening_liability_cents"] == 110
    assert Enum.all?(reconcile()["credit"]["movements"], fn {_, n} -> n == 0 end)
  end

  test "expiry runs on the following day without writes and applied credit stays a liability" do
    apply!([
      open("issuer"),
      pay("issuer", 100),
      cancel("issuer", "hotel_credit"),
      open("user"),
      credit("user", 80),
      start()
    ])

    assert reconcile("2027-11-01")["credit"]["closing_liability_cents"] == 110
    before = snapshot()
    c = reconcile("2027-11-02")["credit"]
    assert c["opening_liability_cents"] == 110
    assert c["movements"]["expired_cents"] == 30
    assert c["closing_liability_cents"] == 80
    assert reconcile("2027-11-03")["credit"]["movements"]["expired_cents"] == 0
    assert snapshot() == before
    apply!(cancel("user", "cash", "2027-11-04"))
    assert reconcile("2027-11-04")["credit"]["movements"]["expired_cents"] == 80
    assert reconcile("2027-11-04")["credit"]["closing_liability_cents"] == 0
  end

  test "issuance, restoration, consumption, revocation and absorption classify liability separately" do
    payment = pay("issuer", 100)

    apply!([
      start(),
      open("issuer"),
      payment,
      cancel("issuer", "hotel_credit"),
      open("user"),
      credit("user", 80),
      open("consumer", "hotel", %{"rate_plan" => "advance_purchase"}),
      credit("consumer", 20),
      cancel("consumer"),
      charge(payment)
    ])

    c = reconcile()["credit"]

    assert c["movements"] == %{
             "issued_cents" => 110,
             "consumed_cents" => 20,
             "revoked_cents" => 10,
             "absorbed_cents" => 0,
             "expired_cents" => 0
           }

    assert c["closing_liability_cents"] == 80
    apply!(cancel("user", "cash", "2027-11-02"))
    c = reconcile("2027-11-02")["credit"]
    assert c["movements"]["absorbed_cents"] == 80
    assert c["movements"]["expired_cents"] == 0
    assert c["closing_liability_cents"] == 0
  end

  test "restoration schedules only unabsorbed excess and backdated application adjusts future expiry" do
    first = pay("issuer", 50)
    second = pay("issuer", 50)

    apply!([
      start(),
      open("issuer"),
      first,
      second,
      cancel("issuer", "hotel_credit"),
      open("user"),
      credit("user", 80),
      charge(first)
    ])

    assert reconcile()["credit"]["movements"]["revoked_cents"] == 30
    assert reconcile("2027-11-02")["credit"]["movements"]["expired_cents"] == 0
    apply!(cancel("user", "cash", "2026-11-02"))
    assert reconcile("2026-11-02")["credit"]["movements"]["absorbed_cents"] == 25
    assert reconcile("2027-11-02")["credit"]["movements"]["expired_cents"] == 55
    apply!([open("late-user"), credit("late-user", 20, "2026-11-03")])
    assert reconcile("2027-11-02")["credit"]["movements"]["expired_cents"] == 35
    assert reconcile("2027-11-02")["credit"]["closing_liability_cents"] == 20
  end

  test "inception excludes expired unused credit and preserves preexisting shortfalls" do
    payment = pay("issuer", 100)

    apply!([
      open("issuer"),
      payment,
      cancel("issuer", "hotel_credit"),
      open("user"),
      credit("user", 80),
      charge(payment),
      start("2027-11-02")
    ])

    c = reconcile("2027-11-02")["credit"]
    assert c["opening_liability_cents"] == 80
    assert Enum.all?(c["movements"], fn {_, amount} -> amount == 0 end)
    apply!(cancel("user", "cash", "2027-11-03"))
    assert reconcile("2027-11-03")["credit"]["movements"]["absorbed_cents"] == 80
  end

  test "failed operations have no movements and later rejected batch entries preserve earlier effects" do
    apply!([start(), open("g")])
    rejected = pay("g", 500)
    before = Repo.all(FinanceEntry)
    assert [%{"code" => "payment_exceeds_outstanding"}] = submit(rejected)
    assert Repo.all(FinanceEntry) == before

    assert [
             %{"status" => "applied"},
             %{"code" => "payment_exceeds_outstanding"},
             %{"status" => "applied"}
           ] = submit([pay("g", 50), rejected, pay("g", 25)])

    assert hd(reconcile()["cash"])["movements"]["received_cents"] == 75
    before = snapshot()
    assert [%{"code" => "payment_exceeds_outstanding"}] = submit(rejected)
    assert snapshot() == before
  end

  test "batch and sequential submissions produce the same reports and results" do
    payment = pay("issuer", 100)

    operations = [
      open("issuer"),
      payment,
      start(),
      cancel("issuer", "hotel_credit"),
      open("user"),
      credit("user", 80),
      open("destination"),
      transfer("user", "destination", 40),
      charge(payment),
      cancel("destination"),
      cancel("user", "cash", "2027-11-03"),
      pay("user", 1)
    ]

    dates = ~w(2026-11-01 2027-11-02 2027-11-03)

    {:error, {results, reports}} =
      Repo.transaction(fn ->
        results = submit(operations)
        reports = Enum.map(dates, &report/1)
        Repo.rollback({results, reports})
      end)

    assert Enum.flat_map(operations, &submit/1) == results
    assert Enum.map(dates, &report/1) == reports
    reconcile("2027-11-03")
  end

  test "expired unused credit is excluded at inception and late issuance expires at posting" do
    apply!([
      open("issuer"),
      pay("issuer", 100),
      cancel("issuer", "hotel_credit"),
      open("user"),
      credit("user", 80),
      start("2027-11-02")
    ])

    assert reconcile("2027-11-02")["credit"]["opening_liability_cents"] == 80
    assert reconcile("2027-11-02")["credit"]["movements"]["expired_cents"] == 0
    apply!([open("late"), pay("late", 5), cancel("late", "hotel_credit")])
    c = reconcile("2027-11-02")["credit"]
    assert c["movements"]["issued_cents"] == 6
    assert c["movements"]["expired_cents"] == 6
    assert c["closing_liability_cents"] == 80
  end

  test "chargeback after unused credit has expired does not remove liability twice" do
    payment = pay("issuer", 100)
    apply!([start(), open("issuer"), payment, cancel("issuer", "hotel_credit")])
    assert reconcile("2027-11-02")["credit"]["movements"]["expired_cents"] == 110
    apply!(charge(payment, "2027-11-03"))
    c = reconcile("2027-11-03")["credit"]
    assert c["closing_liability_cents"] == 0
    assert Enum.all?(c["movements"], fn {_, amount} -> amount == 0 end)
    assert report("2027-11-02")["credit"]["movements"]["expired_cents"] == 110
  end

  test "selected-room settlement reports one rounded bonus and leaves other funding held" do
    apply!([start(), open("g"), pay("g", 105)])

    apply!(
      op("cancel_rooms", %{
        "group_id" => "g",
        "room_ids" => ["r2"],
        "refund_method" => "hotel_credit"
      })
    )

    assert hd(reconcile()["cash"])["movements"]["converted_to_credit_cents"] == 5
    assert hd(reconcile()["cash"])["closing_held_cents"] == 100
    assert reconcile()["credit"]["movements"]["issued_cents"] == 6
    apply!(cancel("g"))
    assert hd(reconcile()["cash"])["movements"]["refunded_cents"] == 100
    assert hd(reconcile()["cash"])["closing_held_cents"] == 0
  end
end
