defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Finance, Operations, Payments, Repo, Reservations}
  alias GroupStay.Finance.Reporting.{Entry, PeriodClose}

  @cash_keys ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_keys ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "close validates its period, ignores group guards, and durably remembers exact outcomes" do
    premature = close_finance_period("2026-10-03")
    assert [rejected] = submit([premature])
    assert rejected["code"] == "invalid_period"
    apply!([start_finance_reporting()])
    assert submit([premature]) == [rejected]

    for value <- [nil, 123, [], %{}, "", "2026-02-29", "2026-10-02"] do
      invalid = close_finance_period(value)
      assert [%{"code" => "invalid_period"} = rejection] = submit([invalid])
      assert submit([invalid]) == [rejection]
    end

    assert [%{"code" => "invalid_period"}] =
             submit([Map.delete(close_finance_period("2026-10-03"), "period_end_on")])

    for operation <- [
          close_finance_period("2026-10-03", %{"occurred_on" => "bad"}),
          Map.delete(close_finance_period("2026-10-03"), "occurred_on")
        ] do
      assert [%{"code" => "invalid_operation"}] = submit([operation])
    end

    close =
      close_finance_period("2026-10-03", %{
        "group_id" => "missing",
        "expected_revision" => -1,
        "occurred_on" => "2026-01-01"
      })

    [result] = apply!([close])

    assert result == %{
             "operation_id" => close["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-10-03"
           }

    for cutoff <- ~w(2026-10-02 2026-10-03) do
      assert [%{"code" => "invalid_period"}] = submit([close_finance_period(cutoff)])
    end

    apply!([close_finance_period("2026-10-05")])
    assert submit([close]) == [result]
    assert Operations.get_result(close["operation_id"]) == result

    assert build_conn()
           |> get("/api/v1/operations/" <> close["operation_id"])
           |> json_response(200) == %{"data" => result}

    assert [%{"code" => "operation_id_conflict"}] =
             submit([Map.put(close, "period_end_on", "2026-10-06")])

    assert Repo.aggregate(PeriodClose, :count) == 2
    assert Repo.all(Entry) == []
    assert report("2026-10-03")["status"] == "closed"
    assert report("2026-10-05")["status"] == "closed"
    assert report("2026-10-06")["status"] == "open"

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-02")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
  end

  test "batch order fixes posting dates and later closes preserve every published report" do
    before_close = payment("before", 100)
    after_close = payment("after", 40, "2026-01-01")
    rejected = payment("rejected", 100_000)

    results =
      submit([
        start_finance_reporting(),
        open_group(),
        before_close,
        close_finance_period("2026-10-05"),
        after_close,
        payment("ordinary", 20, "2026-10-06"),
        payment("future", 30, "2026-10-08"),
        rejected
      ])

    assert Enum.map(results, & &1["status"]) ==
             ~w(applied applied applied applied applied applied applied rejected)

    assert report("2026-10-03")["cash"] == [cash_row("ams-canal", 0, %{received_cents: 100}, 100)]
    assert report("2026-10-04")["cash"] == [cash_row("ams-canal", 100, %{}, 100)]
    closed = published(~w(2026-10-03 2026-10-04 2026-10-05))

    first_open = report("2026-10-06")
    assert first_open["cash"] == [cash_row("ams-canal", 100, %{received_cents: 20}, 160)]
    assert first_open["late_adjustments"] == late([{"ams-canal", %{received_cents: 40}}])
    assert report("2026-10-07")["cash"] == [cash_row("ams-canal", 160, %{}, 160)]
    assert report("2026-10-07")["late_adjustments"] == late([])

    apply!([close_finance_period("2026-10-07"), payment("next-period", 10)])
    assert report("2026-10-06") == Map.put(first_open, "status", "closed")
    assert published(Map.keys(closed)) == closed
    closed = Map.merge(closed, published(~w(2026-10-06 2026-10-07)))

    assert report("2026-10-08")["cash"] == [
             cash_row("ams-canal", 160, %{received_cents: 30}, 200)
           ]

    assert report("2026-10-08")["late_adjustments"] ==
             late([{"ams-canal", %{received_cents: 10}}])

    apply!([close_finance_period("2026-10-10"), payment("last-period", 15)])
    assert published(Map.keys(closed)) == closed
    assert report("2026-10-11")["cash"] == [cash_row("ams-canal", 200, %{}, 215)]

    assert report("2026-10-11")["late_adjustments"] ==
             late([{"ams-canal", %{received_cents: 15}}])

    entries = Repo.all(Entry)

    assert submit([before_close, after_close, rejected]) ==
             Enum.map([2, 4, 7], &Enum.at(results, &1))

    assert Repo.all(Entry) == entries
    assert Reservations.get_group("group-81").revision == 7
    assert_reconciles("2026-10-11")
  end

  test "late transfers, reductions and chargebacks follow holding and settlement properties" do
    original = payment("payment", 300)

    apply!([
      start_finance_reporting(),
      open_group(),
      open_group(%{"group_id" => "refund", "property_id" => "a-refund"}),
      open_group(%{
        "group_id" => "retain",
        "property_id" => "z-retain",
        "rate_plan" => "advance_purchase"
      }),
      original,
      close_finance_period("2026-10-03"),
      transfer_deposit("group-81", "refund", 120),
      transfer_deposit("group-81", "retain", 80),
      operation("cancel_group", %{"group_id" => "refund"}),
      operation("cancel_group", %{"group_id" => "retain"}),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 40
      })
    ])

    assert report("2026-10-04")["late_adjustments"] ==
             late([
               {"a-refund", %{transferred_in_cents: 120, refunded_cents: 120}},
               {"ams-canal", %{transferred_out_cents: 200, reduced_cents: 40}},
               {"z-retain", %{transferred_in_cents: 80, retained_cents: 80}}
             ])

    apply!([close_finance_period("2026-10-04")])
    closed = published(~w(2026-10-03 2026-10-04))
    apply!([operation("charge_back_payment", %{"payment_operation_id" => "payment"})])

    assert report("2026-10-05")["cash"] == [
             cash_row("a-refund", 0, %{}, 0),
             cash_row("ams-canal", 60, %{}, 0),
             cash_row("z-retain", 0, %{}, 0)
           ]

    assert report("2026-10-05")["late_adjustments"] ==
             late([
               {"a-refund", %{refunded_cents: -120, charged_back_cents: 120}},
               {"ams-canal", %{charged_back_cents: 60}},
               {"z-retain", %{retained_cents: -80, charged_back_cents: 80}}
             ])

    assert published(Map.keys(closed)) == closed
    assert report("2026-10-06")["cash"] == []
    assert report("2026-10-06")["late_adjustments"] == late([])
    assert submit([original]) == [Operations.get_result("payment")]
    assert {:ok, statement} = Payments.statement("payment")
    assert statement.charged_back_cents == 260
    assert statement.reduced_cents == 40
    assert statement.held_by_group == []
    assert_reconciles("2026-10-05")
  end

  test "an inception clamp alone is ordinary even after a close" do
    apply!([
      start_finance_reporting(%{"starts_on" => "2026-10-05"}),
      open_group(),
      payment("inception", 100, "2026-01-01"),
      close_finance_period("2026-10-05"),
      payment("close", 20, "2026-01-01")
    ])

    assert report("2026-10-05")["cash"] == [cash_row("ams-canal", 0, %{received_cents: 100}, 100)]
    assert report("2026-10-05")["late_adjustments"] == late([])

    assert report("2026-10-06")["late_adjustments"] ==
             late([{"ams-canal", %{received_cents: 20}}])
  end

  test "late credit applications and restorations correct a closed expiry on the first open day" do
    issue_credit()
    apply!([close_finance_period("2027-10-04")])
    closed = published(~w(2026-10-03 2027-10-03 2027-10-04))
    assert report("2027-10-04")["credit"] == credit(110, %{expired_cents: 110}, 0)

    apply!([
      operation("apply_hotel_credit", %{
        "group_id" => "recipient",
        "amount_cents" => 60,
        "occurred_on" => "2027-10-03"
      })
    ])

    assert report("2027-10-05")["credit"] == credit(0, %{}, 60)
    assert report("2027-10-05")["late_adjustments"] == late([], %{expired_cents: -60})
    assert published(Map.keys(closed)) == closed
    assert_reconciles("2027-10-05")

    apply!([
      close_finance_period("2027-10-05"),
      operation("cancel_group", %{"group_id" => "recipient", "occurred_on" => "2027-10-03"})
    ])

    assert report("2027-10-06")["credit"] == credit(60, %{}, 0)
    assert report("2027-10-06")["late_adjustments"] == late([], %{expired_cents: 60})
    assert published(Map.keys(closed)) == closed
    assert_reconciles("2027-10-06")
  end

  test "a late credit revocation preserves signed zero-net classifications after closed expiry" do
    issue_credit()
    apply!([close_finance_period("2027-10-04")])
    closed = published(~w(2026-10-03 2027-10-04))
    apply!([operation("charge_back_payment", %{"payment_operation_id" => "payment"})])

    assert report("2027-10-05")["cash"] == [cash_row("ams-canal", 0, %{}, 0)]
    assert report("2027-10-05")["credit"] == credit(0, %{}, 0)

    assert report("2027-10-05")["late_adjustments"] ==
             late(
               [{"ams-canal", %{converted_to_credit_cents: -100, charged_back_cents: 100}}],
               %{revoked_cents: 110, expired_cents: -110}
             )

    assert published(Map.keys(closed)) == closed
    assert_reconciles("2027-10-05")
  end

  test "late issuance includes expired liability immediately and leaves future expiry ordinary" do
    apply!([
      start_finance_reporting(),
      open_group(%{"arrival_on" => "2029-12-10", "departure_on" => "2029-12-11"}),
      payment("payment", 100),
      close_finance_period("2027-10-04"),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    assert report("2027-10-05")["credit"] == credit(0, %{}, 0)

    assert report("2027-10-05")["late_adjustments"] ==
             late([{"ams-canal", %{converted_to_credit_cents: 100}}], %{
               issued_cents: 110,
               expired_cents: 110
             })

    apply!([
      open_group(%{
        "group_id" => "unexpired",
        "arrival_on" => "2029-12-10",
        "departure_on" => "2029-12-11"
      }),
      payment("unexpired-pay", 100, "2027-10-03") |> Map.put("group_id", "unexpired"),
      operation("cancel_group", %{
        "group_id" => "unexpired",
        "refund_method" => "hotel_credit",
        "occurred_on" => "2027-10-03"
      })
    ])

    assert report("2027-10-05")["credit"] == credit(0, %{}, 110)
    assert report("2028-10-03")["credit"] == credit(110, %{expired_cents: 110}, 0)
    assert report("2028-10-03")["late_adjustments"] == late([])
    assert_reconciles("2028-10-03")
  end

  test "late absorption and non-refundable consumption keep their credit classifications" do
    issue_credit()

    apply!([
      operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 100}),
      open_group(%{"group_id" => "nonrefundable", "rate_plan" => "advance_purchase"}),
      transfer_deposit("recipient", "nonrefundable", 30),
      close_finance_period("2026-10-03"),
      operation("charge_back_payment", %{"payment_operation_id" => "payment"}),
      operation("cancel_group", %{"group_id" => "recipient"}),
      operation("cancel_group", %{"group_id" => "nonrefundable"})
    ])

    assert report("2026-10-04")["credit"] == credit(110, %{}, 0)

    assert report("2026-10-04")["late_adjustments"]["credit"] ==
             movements(@credit_keys, %{revoked_cents: 10, absorbed_cents: 70, consumed_cents: 30})

    assert report("2027-10-04")["credit"] == credit(0, %{}, 0)
    assert report("2027-10-04")["late_adjustments"] == late([])
    assert_reconciles("2026-10-04")
  end

  defp issue_credit do
    apply!([
      start_finance_reporting(),
      open_group(),
      payment("payment", 100),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      open_group(%{
        "group_id" => "recipient",
        "arrival_on" => "2029-12-10",
        "departure_on" => "2029-12-11"
      })
    ])
  end

  defp payment(id, amount, on \\ "2026-10-03"),
    do:
      operation("record_cash_payment", %{
        "operation_id" => id,
        "amount_cents" => amount,
        "occurred_on" => on
      })

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(operations) do
    results = submit(operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp report(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report", %{"date" => date})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Compare the encoded data, including closed days that had no movements.
  defp published(dates) do
    Map.new(dates, fn date ->
      data = report(date)
      assert data["status"] == "closed"
      {date, Jason.encode!(data)}
    end)
  end

  defp cash_row(property, opening, changes, closing),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => movements(@cash_keys, changes),
      "closing_held_cents" => closing
    }

  defp credit(opening, changes, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => movements(@credit_keys, changes),
      "closing_liability_cents" => closing
    }

  defp late(cash, credit \\ %{}),
    do: %{
      "cash" =>
        Enum.map(cash, fn {property, changes} ->
          %{"property_id" => property, "movements" => movements(@cash_keys, changes)}
        end),
      "credit" => movements(@credit_keys, credit)
    }

  defp movements(keys, changes),
    do:
      Map.merge(
        Map.new(keys, &{&1, 0}),
        Map.new(changes, fn {key, value} -> {Atom.to_string(key), value} end)
      )

  defp assert_reconciles(date) do
    data = report(date)
    totals = Finance.totals(Date.from_iso8601!(date))
    assert Enum.sum(Enum.map(data["cash"], & &1["closing_held_cents"])) == totals.cash_held_cents
    assert data["credit"]["closing_liability_cents"] == totals.credit_liability_cents
  end
end
