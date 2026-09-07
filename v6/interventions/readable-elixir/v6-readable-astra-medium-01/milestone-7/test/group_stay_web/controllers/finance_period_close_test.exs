defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.{Movement, Opening}

  defp op(id, type, attrs \\ %{}, on \\ "2027-01-02") do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => on}, attrs)
  end

  defp start, do: op("start", "start_finance_reporting", %{"starts_on" => "2027-01-02"})

  defp close(id, date),
    do: op(id, "close_finance_period", %{"period_end_on" => date, "expected_revision" => -1})

  defp open(id, plan \\ "flexible") do
    op("open-#{id}", "open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => id,
      "arrival_on" => "2029-06-01",
      "departure_on" => "2029-06-02",
      "rate_plan" => plan,
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 5000}]
    })
  end

  defp pay(id, group, amount, on \\ "2027-01-02"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount}, on)

  defp cancel(id, group, method \\ "cash", on \\ "2027-01-02"),
    do: op(id, "cancel_group", %{"group_id" => group, "refund_method" => method}, on)

  defp credit(id, group, amount),
    do: op(id, "apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp chargeback(id, payment),
    do: op(id, "charge_back_payment", %{"payment_operation_id" => payment})

  defp batch(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date) do
    report =
      build_conn()
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sort(Map.keys(report)) == ~w(cash credit date late_adjustments status)
    assert Enum.sort(Map.keys(report["late_adjustments"])) == ~w(cash credit)

    for adjustment <- report["late_adjustments"]["cash"] do
      assert Enum.sort(Map.keys(adjustment)) == ~w(movements property_id)
      refute zero?(adjustment["movements"])
    end

    for row <- report["cash"] do
      late =
        late_cash(report, row["property_id"]) ||
          Map.new(row["movements"], fn {k, _} -> {k, 0} end)

      assert Enum.sort(Map.keys(late)) == Enum.sort(Map.keys(row["movements"]))
      total = Map.merge(row["movements"], late, fn _, ordinary, late -> ordinary + late end)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] +
                 total["received_cents"] + total["transferred_in_cents"] -
                 total["transferred_out_cents"] -
                 total["refunded_cents"] - total["retained_cents"] -
                 total["converted_to_credit_cents"] -
                 total["reduced_cents"] - total["charged_back_cents"]
    end

    credit = report["credit"]
    late_credit = report["late_adjustments"]["credit"]

    assert Enum.sort(Map.keys(late_credit)) ==
             ~w(absorbed_cents consumed_cents expired_cents issued_cents revoked_cents)

    total =
      Map.merge(credit["movements"], late_credit, fn _, ordinary, late -> ordinary + late end)

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + total["issued_cents"] -
               total["expired_cents"] - total["consumed_cents"] - total["revoked_cents"] -
               total["absorbed_cents"]

    report
  end

  defp cash(report, property), do: Enum.find(report["cash"], &(&1["property_id"] == property))

  defp late_cash(report, property),
    do:
      Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property))["movements"]

  defp zero?(values), do: Enum.all?(values, fn {_, amount} -> amount == 0 end)

  test "close validation, exact durable results and increasing cutoffs" do
    early = close("before-start", "2027-01-02")
    assert [%{"code" => "invalid_period"} = rejected] = batch([early])
    batch([start()])
    assert batch([early]) == [rejected]

    for {value, index} <- Enum.with_index([nil, "", "no", "2027-02-29", 123, [], "2027-01-01"]) do
      operation = close("bad-#{index}", value)
      assert [%{"code" => "invalid_period"} = result] = batch([operation])
      assert batch([operation]) == [result]
    end

    assert [%{"code" => "invalid_period"}] = batch([op("missing", "close_finance_period")])
    operation = close("close", "2027-01-02")
    assert [result] = batch([operation])

    assert result == %{
             "operation_id" => "close",
             "status" => "applied",
             "period_end_on" => "2027-01-02"
           }

    assert batch([operation]) == [result]

    assert build_conn() |> get("/api/v1/operations/close") |> json_response(200) == %{
             "data" => result
           }

    assert [%{"code" => "operation_id_conflict"}] = batch([close("close", "2027-01-03")])
    assert [%{"code" => "invalid_period"}] = batch([close("same", "2027-01-02")])
    assert report("2027-01-02")["status"] == "closed"
    assert report("2027-01-03")["status"] == "open"
    assert [%{"status" => "applied"}] = batch([close("next", "2027-01-04")])
    assert [%{"code" => "invalid_period"}] = batch([close("earlier", "2027-01-03")])
  end

  test "same-batch cutoffs fix posting dates while future-dated and rejected operations keep their behavior" do
    operations = [
      open("a"),
      start(),
      pay("before", "a", 100),
      close("first", "2027-01-02"),
      pay("late", "a", 50, "2026-12-01"),
      pay("future", "a", 20, "2027-01-05"),
      pay("rejected", "a", 2000),
      pay("ordinary", "a", 10, "2027-01-03")
    ]

    results = batch(operations)
    assert Enum.at(results, 6)["code"] == "payment_exceeds_outstanding"
    published = report("2027-01-02")
    assert cash(published, "a")["closing_held_cents"] == 100
    assert published["late_adjustments"]["cash"] == []
    assert zero?(published["late_adjustments"]["credit"])
    day = report("2027-01-03")
    assert cash(day, "a")["opening_held_cents"] == 100
    assert cash(day, "a")["movements"]["received_cents"] == 10
    assert late_cash(day, "a")["received_cents"] == 50
    assert cash(day, "a")["closing_held_cents"] == 160
    assert late_cash(report("2027-01-05"), "a") == nil
    assert cash(report("2027-01-05"), "a")["movements"]["received_cents"] == 20

    batch([close("second", "2027-01-04"), pay("later", "a", 30)])
    assert report("2027-01-02") == published
    assert report("2027-01-03") == Map.put(day, "status", "closed")
    assert late_cash(report("2027-01-05"), "a")["received_cents"] == 30
    assert cash(report("2027-01-05"), "a")["closing_held_cents"] == 210
    before = Repo.all(Movement)
    assert batch(operations) == results
    assert Repo.all(Movement) == before
    assert Reservations.get_group("a").revision == 6
    assert Reservations.ledger().cash_held_cents == 210
  end

  test "late transfers and corrections retain properties and signed zero-net settlements" do
    batch([
      start(),
      open("a"),
      open("b"),
      open("c", "advance_purchase"),
      pay("p", "a", 300),
      close("close", "2027-01-02")
    ])

    published = report("2027-01-02")

    batch([
      op("transfer", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 100
      }),
      op("transfer-c", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "c",
        "amount_cents" => 100
      }),
      op("reduce", "reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 20}),
      cancel("refund", "b"),
      cancel("retain", "c"),
      chargeback("cb", "p")
    ])

    day = report("2027-01-03")
    assert Enum.map(day["late_adjustments"]["cash"], & &1["property_id"]) == ~w(a b c)
    assert late_cash(day, "a")["transferred_out_cents"] == 200
    assert late_cash(day, "b")["transferred_in_cents"] == 100
    assert late_cash(day, "c")["reduced_cents"] == 20
    assert late_cash(day, "b")["charged_back_cents"] == 100
    assert late_cash(day, "c")["charged_back_cents"] == 80
    assert Enum.all?(day["cash"], &zero?(&1["movements"]))
    assert Enum.all?(day["cash"], &(&1["closing_held_cents"] == 0))
    assert report("2027-01-02") == published

    # A reversal of a refund published on an earlier day is significant even
    # though both the opening and closing held balance are zero.
    batch([
      open("d"),
      pay("q", "d", 100),
      cancel("refund-q", "d"),
      close("next", "2027-01-03"),
      chargeback("cb-q", "q")
    ])

    adjustment = report("2027-01-04")
    assert late_cash(adjustment, "d")["refunded_cents"] == -100
    assert late_cash(adjustment, "d")["charged_back_cents"] == 100
    assert cash(adjustment, "d")["closing_held_cents"] == 0
  end

  test "closed expiry survives backdated redemption, restoration and expired issuance" do
    batch([
      start(),
      open("issuer"),
      open("redeemer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", "hotel_credit"),
      close("expiry", "2028-01-03")
    ])

    expiry = report("2028-01-03")
    assert expiry["credit"]["movements"]["expired_cents"] == 110
    assert expiry["credit"]["closing_liability_cents"] == 0
    batch([credit("redeem", "redeemer", 40)])
    day = report("2028-01-04")
    assert day["late_adjustments"]["credit"]["expired_cents"] == -40
    assert day["credit"]["closing_liability_cents"] == 40
    assert zero?(day["credit"]["movements"])
    batch([close("next", "2028-01-04"), cancel("restore", "redeemer")])
    restored = report("2028-01-05")
    assert restored["late_adjustments"]["credit"]["expired_cents"] == 40
    assert restored["credit"]["closing_liability_cents"] == 0
    assert report("2028-01-03") == expiry
    assert report("2028-01-04") == Map.put(day, "status", "closed")

    batch([open("old"), pay("old-p", "old", 100), cancel("old-lot", "old", "hotel_credit")])
    late = report("2028-01-05")["late_adjustments"]["credit"]
    assert late["issued_cents"] == 110
    assert late["expired_cents"] == 150
    assert Reservations.ledger(~D[2028-01-05]).credit_liability_cents == 0
  end

  test "late credit revocation, absorption and consumption leave future scheduled expiry ordinary" do
    batch([
      start(),
      open("issuer"),
      open("a"),
      open("b", "advance_purchase"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", "hotel_credit"),
      credit("apply-a", "a", 60),
      credit("apply-b", "b", 40),
      close("close", "2027-01-02")
    ])

    published = report("2027-01-02")
    batch([chargeback("cb", "p"), cancel("absorb", "a"), cancel("consume", "b")])
    day = report("2027-01-03")
    assert day["late_adjustments"]["credit"]["revoked_cents"] == 10
    assert day["late_adjustments"]["credit"]["absorbed_cents"] == 60
    assert day["late_adjustments"]["credit"]["consumed_cents"] == 40
    assert day["credit"]["closing_liability_cents"] == 0
    assert late_cash(day, "issuer")["converted_to_credit_cents"] == -100
    assert report("2027-01-02") == published

    batch([open("new"), pay("new-p", "new", 100), cancel("new-lot", "new", "hotel_credit")])
    assert report("2027-01-03")["late_adjustments"]["credit"]["issued_cents"] == 110
    expiry = report("2028-01-03")
    assert expiry["credit"]["movements"]["expired_cents"] == 110
    assert zero?(expiry["late_adjustments"]["credit"])
  end

  @tag :capture_log
  test "journal failure rolls back the cutoff and a retried batch publishes prior movements once" do
    batch([start(), open("a")])

    Repo.query!("""
    CREATE TRIGGER fail_close BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'close'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    operations = [pay("before", "a", 100), close("close", "2027-01-02"), pay("after", "a", 50)]
    assert_error_sent 500, fn -> batch(operations) end
    assert Repo.get!(Opening, 1).closed_through == nil
    assert GroupStay.Operations.get_result("close") == nil
    assert GroupStay.Operations.get_result("after") == nil
    assert cash(report("2027-01-02"), "a")["closing_held_cents"] == 100
    Repo.query!("DROP TRIGGER fail_close")
    assert Enum.all?(batch(operations), &(&1["status"] == "applied"))
    assert cash(report("2027-01-02"), "a")["closing_held_cents"] == 100
    assert late_cash(report("2027-01-03"), "a")["received_cents"] == 50
  end
end
