defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{FinanceReporting, Repo, Reservations}
  alias GroupStay.FinanceReporting.Entry

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  defp op(type, attrs \\ %{}, on \\ "2027-01-01") do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => on
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
          "arrival_on" => "2030-06-01",
          "departure_on" => "2030-06-02",
          "rate_plan" => "flexible",
          "rooms" => for(i <- 0..4, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp pay(id, group, amount, on \\ "2027-01-01"),
    do:
      op(
        "record_cash_payment",
        %{"operation_id" => id, "group_id" => group, "amount_cents" => amount},
        on
      )

  defp start,
    do: %{
      "operation_id" => "start",
      "type" => "start_finance_reporting",
      "starts_on" => "2027-01-01"
    }

  defp close(on),
    do: Map.delete(op("close_finance_period", %{"period_end_on" => on}), "occurred_on")

  defp cancel(group, method \\ "cash", on \\ "2027-01-01"),
    do: op("cancel_group", %{"group_id" => group, "refund_method" => method}, on)

  defp credit(group, amount, on \\ "2027-01-01"),
    do: op("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount}, on)

  defp transfer(source, destination, amount, on \\ "2027-01-01"),
    do:
      op(
        "transfer_deposit",
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        on
      )

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp applied(operations) do
    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp report_body(on),
    do: build_conn() |> get("/api/v1/finance/daily-report?date=#{on}") |> Map.fetch!(:resp_body)

  defp report(on), do: report_body(on) |> Jason.decode!() |> Map.fetch!("data")
  defp cash(report, property), do: Enum.find(report["cash"], &(&1["property_id"] == property))

  defp late_cash(report, property),
    do:
      Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property))["movements"]

  defp zeros(fields), do: Map.new(fields, &{&1, 0})
  defp all_zero?(m), do: Enum.all?(m, fn {_, n} -> n == 0 end)

  defp assert_balanced(report) do
    late = report["late_adjustments"]
    assert Enum.sort(Map.keys(report)) == ~w(cash credit date late_adjustments status)
    assert Enum.sort(Map.keys(late)) == ~w(cash credit)
    assert Enum.sort(Map.keys(late["credit"])) == Enum.sort(@credit_fields)
    assert late["cash"] == Enum.sort_by(late["cash"], & &1["property_id"])

    for row <- late["cash"] do
      assert Enum.sort(Map.keys(row)) == ~w(movements property_id)
      assert Enum.sort(Map.keys(row["movements"])) == Enum.sort(@cash_fields)
      refute all_zero?(row["movements"])
    end

    totals =
      for row <- report["cash"] do
        m =
          Map.merge(
            row["movements"],
            late_cash(report, row["property_id"]) || zeros(@cash_fields),
            fn _, a, b -> a + b end
          )

        assert row["closing_held_cents"] ==
                 row["opening_held_cents"] +
                   m["received_cents"] + m["transferred_in_cents"] - m["transferred_out_cents"] -
                   m["refunded_cents"] - m["retained_cents"] - m["converted_to_credit_cents"] -
                   m["reduced_cents"] - m["charged_back_cents"]

        m
      end

    assert Enum.sum(Enum.map(totals, & &1["transferred_in_cents"])) ==
             Enum.sum(Enum.map(totals, & &1["transferred_out_cents"]))

    credit = report["credit"]
    m = Map.merge(credit["movements"], late["credit"], fn _, a, b -> a + b end)

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] +
               m["issued_cents"] - m["expired_cents"] - m["consumed_cents"] - m["revoked_cents"] -
               m["absorbed_cents"]
  end

  defp assert_current(report) do
    assert_balanced(report)
    ledger = Reservations.ledger(Date.from_iso8601!(report["date"]))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  test "close validates the reporting period and durably replays applied, rejected, and conflicting attempts" do
    early = close("2027-01-01")
    assert [%{"code" => "invalid_period"}] = rejected = batch([early])
    assert FinanceReporting.latest_cutoff() == nil
    applied([start()])
    assert batch([early]) == rejected

    for value <- [nil, "bad", "2027-02-29", 20_270_101, [], %{}, "2026-12-31"] do
      operation = close(value)
      assert [%{"code" => "invalid_period"}] = result = batch([operation])
      assert batch([operation]) == result
    end

    assert [%{"code" => "invalid_period"}] = batch([op("close_finance_period")])

    operation = Map.put(close("2027-01-01"), "expected_revision", "ignored")

    assert applied([operation]) == [
             %{
               "operation_id" => operation["operation_id"],
               "status" => "applied",
               "period_end_on" => "2027-01-01"
             }
           ]

    assert batch([operation]) == [Reservations.get_operation(operation["operation_id"])]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(operation, "period_end_on", "2027-01-02")])

    assert [%{"code" => "invalid_period"}, %{"code" => "invalid_period"}] =
             batch([close("2027-01-01"), close("2026-12-31")])

    applied([close("2027-01-02")])
    assert batch([operation]) == [Reservations.get_operation(operation["operation_id"])]
    assert report("2027-01-01")["status"] == "closed"
    assert report("2027-01-02")["status"] == "closed"
    assert report("2027-01-03")["status"] == "open"

    assert report("2027-01-01")["late_adjustments"] == %{
             "cash" => [],
             "credit" => zeros(@credit_fields)
           }

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-12-31")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "same-batch cutoff fixes posting dates, keeps open dates, and never moves earlier commitments again" do
    future = pay("future", "a", 40, "2027-01-05")
    before_close = pay("before", "a", 100)
    after_close = pay("after", "a", 50, "2026-12-01")

    operations = [
      open("a"),
      start(),
      before_close,
      future,
      close("2027-01-02"),
      after_close,
      pay("ordinary", "a", 25, "2027-01-03"),
      pay("later", "a", 10, "2027-01-04")
    ]

    applied(operations)
    closed = for on <- ~w(2027-01-01 2027-01-02), do: report_body(on)
    assert cash(report("2027-01-01"), "a")["movements"]["received_cents"] == 100
    third = report("2027-01-03")
    assert cash(third, "a")["opening_held_cents"] == 100
    assert cash(third, "a")["movements"]["received_cents"] == 25
    assert late_cash(third, "a")["received_cents"] == 50
    assert cash(third, "a")["closing_held_cents"] == 175
    assert_balanced(third)
    assert late_cash(report("2027-01-04"), "a") == nil
    assert cash(report("2027-01-05"), "a")["movements"]["received_cents"] == 40
    applied([close("2027-01-04")])
    assert report("2027-01-03") == Map.put(third, "status", "closed")

    applied([
      pay("new", "a", 15),
      open("new-property"),
      pay("new-property-pay", "new-property", 5)
    ])

    assert for(on <- ~w(2027-01-01 2027-01-02), do: report_body(on)) == closed
    assert late_cash(report("2027-01-05"), "a")["received_cents"] == 15
    assert_current(report("2027-01-05"))
    entries = Repo.all(Entry)
    applied([before_close, after_close, future])
    assert Repo.all(Entry) == entries
    assert cash(report("2027-01-05"), "a")["closing_held_cents"] == 240
  end

  test "late transfers, reductions and chargebacks follow each property's signed dispositions" do
    applied([
      start(),
      open("source"),
      pay("p", "source", 500),
      open("refund"),
      open("retain", %{"rate_plan" => "advance_purchase"}),
      open("convert"),
      open("dest"),
      transfer("source", "refund", 100),
      transfer("source", "retain", 100),
      transfer("source", "convert", 100),
      cancel("refund"),
      cancel("retain"),
      cancel("convert", "hotel_credit"),
      close("2027-01-01")
    ])

    closed = report_body("2027-01-01")

    applied([
      transfer("source", "dest", 100),
      op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 25}),
      op("charge_back_payment", %{"payment_operation_id" => "p"})
    ])

    result = report("2027-01-02")
    assert late_cash(result, "source")["transferred_out_cents"] == 100
    assert late_cash(result, "source")["charged_back_cents"] == 100
    assert late_cash(result, "dest")["transferred_in_cents"] == 100
    assert late_cash(result, "dest")["reduced_cents"] == 25
    assert late_cash(result, "dest")["charged_back_cents"] == 75

    for {property, field} <- [
          {"refund", "refunded_cents"},
          {"retain", "retained_cents"},
          {"convert", "converted_to_credit_cents"}
        ] do
      assert late_cash(result, property)[field] == -100
      assert late_cash(result, property)["charged_back_cents"] == 100
      assert cash(result, property)["opening_held_cents"] == 0
      assert cash(result, property)["closing_held_cents"] == 0
    end

    assert Enum.all?(result["cash"], &all_zero?(&1["movements"]))
    assert result["late_adjustments"]["credit"]["revoked_cents"] == 110
    assert_current(result)
    assert report_body("2027-01-01") == closed

    assert {:ok, %{held_cents: 0, reduced_cents: 25, charged_back_cents: 475, held_by_group: []}} =
             Reservations.get_payment("p")

    assert Reservations.get_operation("p")["revision"] == 2
  end

  test "expiry on closed days stays published when late redemption and restoration change current liability" do
    applied([
      start(),
      open("seed"),
      pay("p", "seed", 100),
      cancel("seed", "hotel_credit"),
      open("consumer"),
      close("2028-01-02")
    ])

    closed = report_body("2028-01-02")
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 110
    applied([credit("consumer", 80, "2027-12-01")])
    result = report("2028-01-03")
    assert result["credit"]["opening_liability_cents"] == 0
    assert result["credit"]["movements"]["expired_cents"] == 0
    assert result["late_adjustments"]["credit"]["expired_cents"] == -80
    assert_current(result)
    assert report_body("2028-01-02") == closed
    applied([close("2028-01-03"), cancel("consumer", "cash", "2027-12-02")])
    assert report("2028-01-03") == Map.put(result, "status", "closed")
    restored = report("2028-01-04")
    assert restored["late_adjustments"]["credit"]["expired_cents"] == 80
    assert_current(restored)
    assert report_body("2028-01-02") == closed
  end

  test "late credit issuance leaves future expiry ordinary and closing without operations still publishes expiry" do
    applied([
      start(),
      open("seed"),
      pay("p", "seed", 100),
      close("2027-01-01"),
      cancel("seed", "hotel_credit")
    ])

    result = report("2027-01-02")
    assert result["credit"]["movements"]["issued_cents"] == 0
    assert result["late_adjustments"]["credit"]["issued_cents"] == 110
    assert late_cash(result, "seed")["converted_to_credit_cents"] == 100
    assert_current(result)
    future = report("2028-01-02")
    assert future["credit"]["movements"]["expired_cents"] == 110
    assert future["late_adjustments"]["credit"] == zeros(@credit_fields)
    applied([close("2028-01-02")])
    assert report("2028-01-02") == Map.put(future, "status", "closed")
    assert_current(report("2028-01-02"))
  end

  test "late credit revocation preserves signed reversal of a published expiry even at zero net liability" do
    applied([
      start(),
      open("seed"),
      pay("p", "seed", 100),
      cancel("seed", "hotel_credit"),
      close("2028-01-02")
    ])

    closed = report_body("2028-01-02")
    applied([op("charge_back_payment", %{"payment_operation_id" => "p"})])
    result = report("2028-01-03")
    assert result["late_adjustments"]["credit"]["revoked_cents"] == 110
    assert result["late_adjustments"]["credit"]["expired_cents"] == -110
    assert result["credit"]["closing_liability_cents"] == 0
    assert_current(result)
    assert report_body("2028-01-02") == closed
  end

  test "shortfall absorption, expired restoration and nonrefundable consumption post in the open period" do
    applied([
      start(),
      open("seed"),
      pay("p1", "seed", 40),
      pay("p2", "seed", 60),
      cancel("seed", "hotel_credit"),
      open("consumer"),
      credit("consumer", 110),
      op("charge_back_payment", %{"payment_operation_id" => "p1"}),
      close("2028-01-02"),
      cancel("consumer", "cash", "2028-01-02")
    ])

    result = report("2028-01-03")

    assert result["late_adjustments"]["credit"] ==
             Map.merge(zeros(@credit_fields), %{"absorbed_cents" => 44, "expired_cents" => 66})

    assert_current(result)

    applied([
      open("other"),
      pay("other-pay", "other", 100, "2028-02-01"),
      cancel("other", "hotel_credit", "2028-02-01"),
      open("nonref", %{"rate_plan" => "advance_purchase"}),
      credit("nonref", 100, "2028-02-01"),
      close("2028-02-01"),
      cancel("nonref", "cash", "2028-02-01")
    ])

    assert report("2028-02-02")["late_adjustments"]["credit"]["consumed_cents"] == 100
    assert_current(report("2028-02-02"))
  end

  test "batch and sequential commits agree, rejections add nothing, and failed closes roll back" do
    operations = [
      start(),
      open("a"),
      pay("p", "a", 100),
      close("2027-01-01"),
      pay("p2", "a", 50),
      close("2027-01-02"),
      pay("too-much", "a", 500),
      pay("p3", "a", 25)
    ]

    Repo.query!("SAVEPOINT equivalence")
    results = batch(operations)
    expected = Enum.map(~w(2027-01-01 2027-01-02 2027-01-03), &report_body/1)
    Repo.query!("ROLLBACK TO SAVEPOINT equivalence")
    Repo.query!("RELEASE SAVEPOINT equivalence")
    assert Enum.map(operations, &(batch([&1]) |> hd())) == results
    assert Enum.map(~w(2027-01-01 2027-01-02 2027-01-03), &report_body/1) == expected
    entries = Repo.all(Entry)
    assert batch(operations) == results
    assert Repo.all(Entry) == entries
    assert_current(report("2027-01-03"))

    Repo.query!("""
    CREATE TRIGGER fail_close BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    failed = Map.put(close("2027-01-03"), "operation_id", "fault")

    assert_error_sent 500, fn ->
      batch([pay("before-fault", "a", 10), failed, pay("never", "a", 10)])
    end

    assert FinanceReporting.latest_cutoff() == ~D[2027-01-02]
    assert Reservations.get_operation("fault") == nil
    assert Reservations.get_operation("never") == nil
    assert late_cash(report("2027-01-03"), "a")["received_cents"] == 35
    Repo.query!("DROP TRIGGER fail_close")
    applied([failed, pay("after-fault", "a", 10)])
    assert report("2027-01-03")["status"] == "closed"
    assert late_cash(report("2027-01-04"), "a")["received_cents"] == 10
    assert_current(report("2027-01-04"))
  end
end
