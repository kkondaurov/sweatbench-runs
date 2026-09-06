defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{FinanceEntry, Repo}

  @cash ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  defp op(type, fields \\ %{}, date \\ "2026-11-01") do
    Map.merge(
      %{
        "operation_id" => "close-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => date
      },
      fields
    )
  end

  defp open(id, property \\ "hotel", plan \\ "flexible") do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => property,
      "arrival_on" => "2030-03-01",
      "departure_on" => "2030-03-02",
      "rate_plan" => plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5000}]
    })
  end

  defp pay(id, amount, date \\ "2026-11-01"),
    do: op("record_cash_payment", %{"group_id" => id, "amount_cents" => amount}, date)

  defp start, do: op("start_finance_reporting", %{"starts_on" => "2026-11-01"})
  defp close(date), do: op("close_finance_period", %{"period_end_on" => date})

  defp charge(payment),
    do: op("charge_back_payment", %{"payment_operation_id" => payment["operation_id"]})

  defp cancel(id, method \\ "cash", date \\ "2026-11-01"),
    do: op("cancel_group", %{"group_id" => id, "refund_method" => method}, date)

  defp credit(id, amount, date \\ "2026-11-01"),
    do: op("apply_hotel_credit", %{"group_id" => id, "amount_cents" => amount}, date)

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

  defp report(date) do
    report = read("finance/daily-report?date=#{date}")
    assert Enum.sort(Map.keys(report)) == ~w(cash credit date late_adjustments status)
    late = report["late_adjustments"]
    assert Enum.sort(Map.keys(late)) == ~w(cash credit)
    assert Enum.sort(Map.keys(late["credit"])) == Enum.sort(@credit)

    for rows <- [report["cash"], late["cash"]] do
      assert Enum.map(rows, & &1["property_id"]) == Enum.sort(Enum.map(rows, & &1["property_id"]))
      for row <- rows, do: assert(Enum.sort(Map.keys(row["movements"])) == Enum.sort(@cash))
    end

    for row <- late["cash"] do
      assert Enum.sort(Map.keys(row)) == ~w(movements property_id)
      assert Enum.any?(row["movements"], fn {_, value} -> value != 0 end)
    end

    late_cash = Map.new(late["cash"], &{&1["property_id"], &1["movements"]})

    for row <- report["cash"] do
      movements =
        Map.merge(row["movements"], Map.get(late_cash, row["property_id"], %{}), fn _, a, b ->
          a + b
        end)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] +
                 effect(movements, ~w(received_cents transferred_in_cents))
    end

    [transferred_in, transferred_out] =
      for direction <- ~w(transferred_in_cents transferred_out_cents) do
        Enum.sum(for row <- report["cash"] ++ late["cash"], do: row["movements"][direction])
      end

    assert transferred_in == transferred_out

    c = report["credit"]

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] +
               effect(c["movements"], ~w(issued_cents)) + effect(late["credit"], ~w(issued_cents))

    report
  end

  defp effect(movements, incoming),
    do: Enum.sum(for {key, value} <- movements, do: if(key in incoming, do: value, else: -value))

  defp wire_report(date) do
    build_conn() |> get("/api/v1/finance/daily-report?date=#{date}") |> response(200)
  end

  defp frozen(dates), do: Map.new(dates, &{&1, wire_report(&1)})

  defp assert_frozen(reports),
    do: Enum.each(reports, fn {date, data} -> assert wire_report(date) == data end)

  test "validates cutoffs and durably remembers successful and rejected closes" do
    rejected = close("2026-11-01")
    assert [%{"code" => "invalid_period"}] = submit(rejected)
    apply!(start())
    assert [%{"code" => "invalid_period"}] = submit(rejected)

    for value <- [nil, 1, %{}, [], "bad", "2026-02-30", "2026-10-31"] do
      assert [%{"code" => "invalid_period"}] = submit(close(value))
    end

    assert [%{"code" => "invalid_period"}] = submit(op("close_finance_period"))

    operation =
      close("2026-11-01") |> Map.delete("occurred_on") |> Map.put("expected_revision", "ignored")

    [result] = apply!(operation)

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-11-01"
           }

    assert report("2026-11-01")["status"] == "closed"
    assert report("2026-11-02")["status"] == "open"

    assert report("2026-11-01")["late_adjustments"] == %{
             "cash" => [],
             "credit" => Map.new(@credit, &{&1, 0})
           }

    apply!(close("2026-11-03"))
    assert submit(operation) == [result]
    assert read("operations/#{operation["operation_id"]}") == result

    assert [%{"code" => "operation_id_conflict"}] =
             submit(Map.put(operation, "period_end_on", "2026-11-04"))

    for date <- ~w(2026-11-01 2026-11-02 2026-11-03),
        do: assert([%{"code" => "invalid_period"}] = submit(close(date)))

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-31")
           |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}
  end

  test "batch order fixes posting dates, separates ordinary and late cash, and freezes every closed day" do
    first = pay("group", 100)
    late = pay("group", 20, "2026-10-01")
    ordinary = pay("group", 30, "2026-11-03")
    apply!([open("group"), start(), first, close("2026-11-02"), late, ordinary])
    closed = frozen(~w(2026-11-01 2026-11-02))
    day = report("2026-11-03")

    assert [
             %{
               "opening_held_cents" => 100,
               "closing_held_cents" => 150,
               "movements" => %{"received_cents" => 30}
             }
           ] = day["cash"]

    assert [%{"movements" => %{"received_cents" => 20}}] = day["late_adjustments"]["cash"]
    apply!([close("2026-11-03"), pay("group", 40), pay("group", 50, "2026-11-06")])
    assert_frozen(closed)
    assert report("2026-11-03") == Map.put(day, "status", "closed")
    third = frozen(["2026-11-03"])
    fourth = report("2026-11-04")
    assert hd(fourth["cash"])["closing_held_cents"] == 190
    assert hd(fourth["late_adjustments"]["cash"])["movements"]["received_cents"] == 40
    assert report("2026-11-06")["late_adjustments"]["cash"] == []
    entries = Repo.all(FinanceEntry)
    assert apply!([first, late, ordinary]) |> length() == 3
    assert Repo.all(FinanceEntry) == entries
    assert_frozen(third)
    assert read("groups/group")["cash_paid_cents"] == 240
    assert read("ledger")["cash_held_cents"] == 240
    assert hd(report("2026-11-06")["cash"])["closing_held_cents"] == 240
  end

  test "late transfers and reductions follow properties and zero-net refund reversals remain visible" do
    payment = pay("source", 200)

    apply!([
      open("source", "z-hotel"),
      open("destination", "a-hotel"),
      start(),
      payment,
      op("transfer_deposit", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 100
      }),
      cancel("destination"),
      close("2026-11-01")
    ])

    closed = frozen(["2026-11-01"])

    apply!(
      op("reduce_cash_payment", %{
        "payment_operation_id" => payment["operation_id"],
        "amount_cents" => 20
      })
    )

    apply!(charge(payment))
    day = report("2026-11-02")

    assert [
             %{
               "property_id" => "a-hotel",
               "movements" => %{"refunded_cents" => -100, "charged_back_cents" => 100}
             },
             %{
               "property_id" => "z-hotel",
               "movements" => %{"reduced_cents" => 20, "charged_back_cents" => 80}
             }
           ] = day["late_adjustments"]["cash"]

    assert hd(day["cash"])["closing_held_cents"] == 0
    assert Enum.all?(hd(day["cash"])["movements"], fn {_, amount} -> amount == 0 end)
    assert_frozen(closed)
    assert read("payments/#{payment["operation_id"]}")["charged_back_cents"] == 180

    apply!([
      open("new-source", "z-hotel"),
      open("new-destination", "a-hotel"),
      pay("new-source", 50),
      op("transfer_deposit", %{
        "source_group_id" => "new-source",
        "destination_group_id" => "new-destination",
        "amount_cents" => 30
      })
    ])

    assert [
             %{"movements" => %{"transferred_in_cents" => 30}},
             %{"movements" => %{"transferred_out_cents" => 30}}
           ] =
             report("2026-11-02")["late_adjustments"]["cash"]
  end

  test "late credit issuance and revocation schedule ordinary expiry without rewriting a closed expiry" do
    payment = pay("source", 100)

    apply!([
      open("source"),
      start(),
      payment,
      close("2026-11-01"),
      cancel("source", "hotel_credit")
    ])

    assert report("2026-11-02")["late_adjustments"]["credit"]["issued_cents"] == 110
    expiry = report("2027-11-02")
    assert expiry["credit"]["movements"]["expired_cents"] == 110
    assert expiry["late_adjustments"]["credit"]["expired_cents"] == 0
    apply!(close("2027-11-02"))
    closed = frozen(~w(2026-11-01 2026-11-02 2027-11-01 2027-11-02))
    apply!(charge(payment))
    assert_frozen(closed)
    day = report("2027-11-03")
    assert day["credit"]["closing_liability_cents"] == 0
    assert day["late_adjustments"]["credit"]["revoked_cents"] == 0
    assert hd(day["late_adjustments"]["cash"])["movements"]["converted_to_credit_cents"] == -100
  end

  test "backdated application after closed expiry restores reported liability on the first open day" do
    apply!([
      open("source"),
      open("target"),
      pay("source", 100),
      cancel("source", "hotel_credit"),
      start(),
      close("2027-11-02")
    ])

    closed = frozen(~w(2026-11-01 2027-11-01 2027-11-02))
    apply!(credit("target", 60))
    day = report("2027-11-03")
    assert day["late_adjustments"]["credit"]["expired_cents"] == -60
    assert day["credit"]["closing_liability_cents"] == 60
    assert read("ledger?on=2027-11-03")["credit_liability_cents"] == 60
    apply!(cancel("target", "cash", "2027-11-03"))
    day = report("2027-11-03")
    assert day["credit"]["movements"]["expired_cents"] == 60
    assert day["credit"]["closing_liability_cents"] == 0
    assert_frozen(closed)
  end

  test "late shortfall absorption, consumption and revocation retain their classifications" do
    payment = pay("source", 100)

    apply!([
      open("source"),
      open("restore"),
      open("consume", "hotel", "advance_purchase"),
      start(),
      payment,
      cancel("source", "hotel_credit"),
      credit("restore", 60),
      credit("consume", 20),
      close("2026-11-01")
    ])

    closed = frozen(["2026-11-01"])
    apply!([charge(payment), cancel("restore"), cancel("consume")])
    day = report("2026-11-02")

    assert day["late_adjustments"]["credit"] == %{
             "issued_cents" => 0,
             "expired_cents" => 0,
             "consumed_cents" => 20,
             "revoked_cents" => 30,
             "absorbed_cents" => 60
           }

    assert day["credit"]["closing_liability_cents"] == 0
    assert report("2027-11-02")["credit"]["movements"]["expired_cents"] == 0
    assert read("ledger?on=2026-11-02")["credit_liability_cents"] == 0
    assert_frozen(closed)
  end

  test "rejections and conflicts add no entries while later batch operations continue" do
    payment = pay("group", 100)
    operation = close("2026-11-01")
    apply!([open("group"), start(), payment, operation])
    entries = Repo.all(FinanceEntry)

    assert [
             %{"code" => "invalid_period"},
             %{"code" => "stale_revision"},
             %{"code" => "operation_id_conflict"},
             %{"status" => "applied"}
           ] =
             submit([
               close("2026-11-01"),
               pay("group", 10) |> Map.put("expected_revision", 1),
               Map.put(operation, "period_end_on", "2026-11-02"),
               pay("group", 20)
             ])

    assert length(Repo.all(FinanceEntry)) == length(entries) + 1

    assert hd(report("2026-11-02")["late_adjustments"]["cash"])["movements"]["received_cents"] ==
             20
  end

  test "late issuance whose lot has already expired reports issue and expiry together" do
    apply!([open("source"), start(), pay("source", 100), close("2028-01-01")])
    closed = frozen(~w(2026-11-01 2027-11-02 2028-01-01))
    apply!(cancel("source", "hotel_credit"))
    day = report("2028-01-02")
    assert day["late_adjustments"]["credit"]["issued_cents"] == 110
    assert day["late_adjustments"]["credit"]["expired_cents"] == 110
    assert day["credit"]["closing_liability_cents"] == 0
    assert_frozen(closed)
  end

  test "equivalent batches and sequential submissions preserve posting dates across multiple closes" do
    payment = pay("source", 100)

    operations = [
      open("source"),
      open("target"),
      start(),
      payment,
      cancel("source", "hotel_credit"),
      close("2026-11-01"),
      credit("target", 80),
      close("2026-11-02"),
      charge(payment),
      cancel("target"),
      close("2027-11-02")
    ]

    dates = ~w(2026-11-01 2026-11-02 2026-11-03 2027-11-02 2027-11-03)

    {:error, {results, reports}} =
      Repo.transaction(fn ->
        results = apply!(operations)
        reports = frozen(dates)
        Repo.rollback({results, reports})
      end)

    assert Enum.flat_map(operations, &apply!/1) == results
    assert_frozen(reports)
    entries = Repo.all(FinanceEntry)
    assert Enum.map(Enum.reverse(dates), &report/1) |> length() == length(dates)
    assert_frozen(reports)
    assert Repo.all(FinanceEntry) == entries
  end
end
