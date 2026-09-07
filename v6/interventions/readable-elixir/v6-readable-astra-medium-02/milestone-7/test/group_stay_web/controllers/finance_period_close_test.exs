defmodule GroupStayWeb.FinancePeriodCloseTest do
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

  defp close(id, date), do: op("close_finance_period", id, %{"period_end_on" => date})

  defp late_cash(report, property),
    do: Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property))

  defp reconcile(day) do
    assert Enum.sort(Map.keys(day)) == ~w(cash credit date late_adjustments status)
    assert Enum.sort(Map.keys(day["late_adjustments"])) == ~w(cash credit)

    assert Enum.sort(Map.keys(day["late_adjustments"]["credit"])) ==
             Enum.sort(Map.keys(day["credit"]["movements"]))

    for row <- day["late_adjustments"]["cash"] do
      assert Enum.sort(Map.keys(row)) == ~w(movements property_id)

      assert Enum.sort(Map.keys(row["movements"])) ==
               Enum.sort(Map.keys(cash(day, row["property_id"])["movements"]))

      assert Enum.any?(row["movements"], fn {_, value} -> value != 0 end)
    end

    for row <- day["cash"] do
      late =
        case late_cash(day, row["property_id"]) do
          nil -> %{}
          entry -> entry["movements"]
        end

      delta =
        Enum.reduce(row["movements"], 0, fn {name, amount}, total ->
          sign = if name in ~w(received_cents transferred_in_cents), do: 1, else: -1
          total + sign * (amount + Map.get(late, name, 0))
        end)

      assert row["closing_held_cents"] == row["opening_held_cents"] + delta
    end

    delta =
      Enum.reduce(day["credit"]["movements"], 0, fn {name, amount}, total ->
        sign = if name == "issued_cents", do: 1, else: -1
        total + sign * (amount + day["late_adjustments"]["credit"][name])
      end)

    assert day["credit"]["closing_liability_cents"] ==
             day["credit"]["opening_liability_cents"] + delta
  end

  test "validates cutoff and remembers both rejections and successful closes" do
    unavailable = close("unavailable", "2027-01-02")
    assert [%{"code" => "invalid_period"}] = batch([unavailable])
    batch([start()])

    for {value, i} <- Enum.with_index([nil, 123, "bad", "2027-02-29", "2027-01-01"]) do
      assert [%{"code" => "invalid_period"}] = batch([close("invalid-#{i}", value)])
    end

    assert [%{"code" => "invalid_period"}] = batch([op("close_finance_period", "missing")])
    first = Map.put(close("first", "2027-01-02"), "expected_revision", "ignored")
    assert [result] = batch([first])

    assert result == %{
             "operation_id" => "first",
             "status" => "applied",
             "period_end_on" => "2027-01-02"
           }

    assert [
             ^result,
             %{"code" => "operation_id_conflict"},
             %{"code" => "invalid_period"},
             %{"code" => "invalid_period"},
             %{"code" => "invalid_period"}
           ] =
             batch([
               first,
               Map.put(first, "period_end_on", "2027-01-03"),
               close("same", "2027-01-02"),
               close("earlier", "2027-01-01"),
               unavailable
             ])

    assert read("operations/first") == result
    assert report()["status"] == "closed"
    assert report("2027-01-03")["status"] == "open"
    assert report()["late_adjustments"]["cash"] == []
    assert Enum.all?(report()["late_adjustments"]["credit"], fn {_, n} -> n == 0 end)
    assert batch([close("next", "2027-01-03")]) |> hd() |> Map.fetch!("status") == "applied"
  end

  test "same-batch closes fix posting dates while later closes preserve every published day" do
    operations = [
      start(),
      open("a"),
      pay("before", "a", 100),
      close("first", "2027-01-02"),
      pay("after", "a", 50),
      on(pay("ordinary", "a", 25), "2027-01-03"),
      on(pay("future", "a", 10), "2027-02-01")
    ]

    results = batch(operations)
    closed = report()
    assert cash(closed, "a")["movements"]["received_cents"] == 100
    assert closed["late_adjustments"]["cash"] == []
    day = report("2027-01-03")
    assert cash(day, "a")["movements"]["received_cents"] == 25
    assert late_cash(day, "a")["movements"]["received_cents"] == 50
    assert cash(day, "a")["closing_held_cents"] == 175
    batch([close("second", "2027-01-03")])
    published = report("2027-01-03")
    assert published == Map.put(day, "status", "closed")
    batch([pay("later", "a", 15), pay("rejected", "a", 999)])
    assert batch(operations) == results
    assert report() == closed
    assert report("2027-01-03") == published
    assert late_cash(report("2027-01-04"), "a")["movements"]["received_cents"] == 15
    assert cash(report("2027-02-01"), "a")["movements"]["received_cents"] == 10
    for date <- ~w(2027-01-02 2027-01-03 2027-01-04 2027-02-01), do: reconcile(report(date))
    assert read("groups/a")["cash_paid_cents"] == 200
    assert read("ledger")["cash_held_cents"] == 200
  end

  test "late cash transfers and corrections keep property and signed zero-net classifications" do
    batch([
      start(),
      open("s"),
      open("r"),
      open("t", %{"rate_plan" => "advance_purchase"}),
      open("c"),
      pay("p", "s", 300),
      transfer("r", "s", "r", 100),
      transfer("t", "s", "t", 100),
      transfer("c", "s", "c", 50),
      cancel("refund", "r"),
      cancel("retain", "t"),
      cancel("convert", "c", %{"refund_method" => "hotel_credit"}),
      close("close", "2027-01-02")
    ])

    published = Jason.encode!(report())

    batch([
      transfer("late-transfer", "s", "r-missing", 1),
      open("d"),
      transfer("late-move", "s", "d", 20),
      op("reduce_cash_payment", "reduce", %{"payment_operation_id" => "p", "amount_cents" => 10}),
      chargeback("cb", "p")
    ])

    assert Jason.encode!(report()) == published
    day = report("2027-01-03")
    assert late_cash(day, "s")["movements"]["transferred_out_cents"] == 20
    assert late_cash(day, "d")["movements"]["transferred_in_cents"] == 20
    assert late_cash(day, "d")["movements"]["reduced_cents"] == 10

    for {property, column, amount} <- [
          {"r", "refunded_cents", 100},
          {"t", "retained_cents", 100},
          {"c", "converted_to_credit_cents", 50}
        ] do
      assert late_cash(day, property)["movements"][column] == -amount
      assert late_cash(day, property)["movements"]["charged_back_cents"] == amount
      assert cash(day, property)["closing_held_cents"] == 0
      assert Enum.all?(cash(day, property)["movements"], fn {_, n} -> n == 0 end)
    end

    assert day["late_adjustments"]["credit"]["revoked_cents"] == 55
    assert Enum.map(day["late_adjustments"]["cash"], & &1["property_id"]) == ~w(c d r s t)
    reconcile(day)
  end

  test "closed expiry remains fixed when an old-dated redemption pauses expired credit" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("use"),
      close("close", "2028-01-02")
    ])

    expired = report("2028-01-02")
    assert expired["credit"]["movements"]["expired_cents"] == 110
    batch([apply_credit("use", "use", 80)])
    assert report("2028-01-02") == expired
    day = report("2028-01-03")
    assert day["late_adjustments"]["credit"]["expired_cents"] == -80
    assert day["credit"]["closing_liability_cents"] == 80
    assert read("ledger?on=2028-01-03")["credit_liability_cents"] == 80
    batch([cancel("restore", "use")])
    assert report("2028-01-02") == expired
    assert report("2028-01-03")["credit"]["closing_liability_cents"] == 0
    reconcile(report("2028-01-03"))
  end

  test "late issuance schedules ordinary future expiry and handles already-expired new lots" do
    batch([
      start(),
      open("a"),
      open("b"),
      pay("a", "a", 100),
      pay("b", "b", 100),
      close("first", "2027-01-02"),
      cancel("issue-a", "a", %{"refund_method" => "hotel_credit"})
    ])

    day = report("2027-01-03")
    assert day["late_adjustments"]["credit"]["issued_cents"] == 110
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 110
    assert report("2028-01-02")["late_adjustments"]["credit"]["expired_cents"] == 0
    batch([close("second", "2028-01-02")])
    closed = report("2028-01-02")
    batch([cancel("issue-b", "b", %{"refund_method" => "hotel_credit"})])
    assert report("2028-01-02") == closed
    late = report("2028-01-03")["late_adjustments"]["credit"]
    assert late["issued_cents"] == 110
    assert late["expired_cents"] == 110
    assert report("2028-01-03")["credit"]["closing_liability_cents"] == 0
    reconcile(report("2028-01-03"))
  end

  test "late shortfall absorption and consumption reconcile with current liability" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("refundable"),
      open("nonrefundable", %{"rate_plan" => "advance_purchase"}),
      apply_credit("use-r", "refundable", 60),
      apply_credit("use-n", "nonrefundable", 40),
      close("close", "2027-01-02"),
      chargeback("cb", "p"),
      cancel("restore", "refundable"),
      cancel("consume", "nonrefundable")
    ])

    day = report("2027-01-03")
    late = day["late_adjustments"]["credit"]
    assert late["revoked_cents"] == 10
    assert late["absorbed_cents"] == 60
    assert late["consumed_cents"] == 40
    assert day["credit"]["closing_liability_cents"] == 0
    assert read("ledger?on=2027-01-03")["credit_liability_cents"] == 0
    reconcile(day)
  end

  test "batch and sequential submissions agree and repeated reads do not mutate the journal" do
    operations = [
      start(),
      open("a"),
      pay("p", "a", 100),
      close("first", "2027-01-02"),
      cancel("lot", "a", %{"refund_method" => "hotel_credit"}),
      close("next", "2028-01-02"),
      open("b"),
      apply_credit("use", "b", 80),
      chargeback("cb", "p")
    ]

    dates = ~w(2027-01-02 2027-01-03 2028-01-02 2028-01-03)
    Repo.query!("SAVEPOINT compare_closes")
    results = batch(operations)
    reports = Enum.map(dates, &report/1)
    Repo.query!("ROLLBACK TO compare_closes")
    Repo.query!("RELEASE compare_closes")
    assert Enum.map(operations, &(batch([&1]) |> hd())) == results
    assert Enum.map(dates, &report/1) == reports
    entries = Repo.all(Entry)
    assert Enum.map(Enum.reverse(dates), &report/1) == Enum.reverse(reports)
    assert Repo.all(Entry) == entries
    Enum.each(reports, &reconcile/1)
  end
end
