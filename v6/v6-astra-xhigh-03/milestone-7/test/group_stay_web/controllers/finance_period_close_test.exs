defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{FinanceReporting, Repo}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "close validates the cutoff, ignores group guards, and remembers successes and rejections" do
    premature = close()
    assert [rejected] = batch([premature])
    assert rejected["code"] == "invalid_period"
    applied([start()])
    assert batch([premature]) == [rejected]

    for date <- [nil, "", "2026-02-30", "2026-11-26T00:00:00Z", 1, true, [], %{}, "2026-11-25"] do
      assert [%{"code" => "invalid_period"}] = batch([close(date)])
    end

    assert [%{"code" => "invalid_period"}] = batch([Map.delete(close(), "period_end_on")])
    op = Map.merge(close(), %{"group_id" => "missing", "expected_revision" => 999})
    assert [result] = applied([op])

    assert result == %{
             "operation_id" => op["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-11-26"
           }

    assert [%{"code" => "invalid_period"}, %{"code" => "invalid_period"}] =
             batch([close(), close("2026-11-25")])

    applied([close("2026-11-28")])
    assert batch([op]) == [result]
    assert read("/api/v1/operations/" <> op["operation_id"]) == result

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(op, "period_end_on", "2026-11-29")])

    assert [%{period_end_on: ~D[2026-11-26]}] = GroupStay.submit_operations([op])

    # A replay must not read reporting state, even when that state is unavailable.
    Repo.query!("ALTER TABLE finance_reporting RENAME TO unavailable_reporting")
    assert batch([op, premature]) == [result, rejected]
  end

  test "batch position selects posting dates permanently while current views and revisions still change" do
    operations = [
      opening("source", "z"),
      opening("destination", "a"),
      start(),
      cash("before", "source", 100, "2026-11-25"),
      close(),
      cash("late", "source", 50, "2026-11-25"),
      cash("ordinary", "source", 25, "2026-11-27"),
      transfer("source", "destination", 60),
      cash("future", "source", 10, "2026-12-01")
    ]

    results = applied(operations)
    assert report()["cash"] == [cash_entry("z", 0, %{"received_cents" => 100}, 100)]
    assert report()["status"] == "closed"
    assert report()["late_adjustments"] == late([], %{})

    assert report("2026-11-27")["cash"] == [
             cash_entry("a", 0, %{}, 60),
             cash_entry("z", 100, %{"received_cents" => 25}, 115)
           ]

    assert report("2026-11-27")["late_adjustments"] ==
             late(
               [
                 late_cash("a", %{"transferred_in_cents" => 60}),
                 late_cash("z", %{"received_cents" => 50, "transferred_out_cents" => 60})
               ],
               %{}
             )

    closed_day = raw_report("2026-11-26")
    day_two = report("2026-11-27") |> Map.put("status", "closed")
    applied([close("2026-11-28"), correction("reduce_cash_payment", "late", 5)])
    assert raw_report("2026-11-26") == closed_day
    assert report("2026-11-27") == day_two

    assert report("2026-11-29")["late_adjustments"] ==
             late([late_cash("a", %{"reduced_cents" => 5})], %{})

    assert report("2026-12-01")["cash"] == [
             cash_entry("a", 55, %{}, 55),
             cash_entry("z", 115, %{"received_cents" => 10}, 125)
           ]

    assert read("/api/v1/groups/source")["revision"] == 7
    assert read("/api/v1/groups/destination")["revision"] == 3

    assert read("/api/v1/payments/late")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 30},
             %{"group_id" => "source", "amount_cents" => 15}
           ]

    assert batch(operations) == results
    assert_reconciles("2026-12-01")
  end

  test "late chargebacks keep every signed settlement classification at its property's location" do
    applied([
      opening("source", "z"),
      opening("refund", "a"),
      opening("retain", "b", "advance_purchase"),
      opening("convert", "c"),
      start(),
      cash("pay", "source", 400),
      transfer("source", "refund", 100),
      transfer("source", "retain", 100),
      transfer("source", "convert", 100),
      cancel("refund"),
      cancel("retain"),
      cancel("convert", "hotel_credit"),
      close()
    ])

    published = raw_report("2026-11-26")

    applied([
      correction("reduce_cash_payment", "pay", 25),
      correction("charge_back_payment", "pay")
    ])

    assert raw_report("2026-11-26") == published

    assert report("2026-11-27")["late_adjustments"] ==
             late(
               [
                 late_cash("a", %{"refunded_cents" => -100, "charged_back_cents" => 100}),
                 late_cash("b", %{"retained_cents" => -100, "charged_back_cents" => 100}),
                 late_cash("c", %{
                   "converted_to_credit_cents" => -100,
                   "charged_back_cents" => 100
                 }),
                 late_cash("z", %{"reduced_cents" => 25, "charged_back_cents" => 75})
               ],
               %{"revoked_cents" => 110}
             )

    # Zero-net reclassifications must also keep the ordinary cash entries, with zero columns.
    assert report("2026-11-27")["cash"] ==
             Enum.map(~w(a b c), &cash_entry(&1, 0, %{}, 0)) ++ [cash_entry("z", 100, %{}, 0)]

    assert report("2026-11-28")["cash"] == []
    assert report("2027-11-27")["credit"]["movements"]["expired_cents"] == 0
    assert_reconciles("2027-11-27")
  end

  test "late issuance preserves future ordinary expiry and closes protect unread expiry reports" do
    applied([
      opening("issuer", "a"),
      cash("pay", "issuer", 100),
      start(),
      close(),
      cancel("issuer", "hotel_credit")
    ])

    assert report("2026-11-27")["late_adjustments"] ==
             late([late_cash("a", %{"converted_to_credit_cents" => 100})], %{
               "issued_cents" => 110
             })

    applied([close("2027-11-27")])
    # This report was never read before the close.
    expiry = raw_report("2027-11-27")
    assert report("2027-11-27")["credit"] == credit_entry(110, %{"expired_cents" => 110}, 0)
    assert report("2027-11-27")["late_adjustments"] == late([], %{})

    applied([correction("charge_back_payment", "pay")])
    assert raw_report("2027-11-27") == expiry
    assert report("2027-11-28")["credit"] == credit_entry(0, %{}, 0)

    assert report("2027-11-28")["late_adjustments"] ==
             late(
               [
                 late_cash("a", %{
                   "converted_to_credit_cents" => -100,
                   "charged_back_cents" => 100
                 })
               ],
               %{"revoked_cents" => 110, "expired_cents" => -110}
             )

    assert_reconciles("2027-11-28")
  end

  test "credit applied after its reported expiry restores liability in the first open day" do
    applied([
      start(),
      opening("issuer", "a"),
      cash("pay", "issuer", 100),
      cancel("issuer", "hotel_credit"),
      opening("holder", "b"),
      close("2027-11-27")
    ])

    published = raw_report("2027-11-27")
    applied([credit("holder", 80)])
    assert raw_report("2027-11-27") == published
    assert report("2027-11-28")["credit"] == credit_entry(0, %{}, 80)
    assert report("2027-11-28")["late_adjustments"] == late([], %{"expired_cents" => -80})
    assert_reconciles("2027-11-28")

    applied([cancel("holder")])
    assert report("2027-11-28")["late_adjustments"] == late([], %{})
    assert report("2027-11-28")["credit"] == credit_entry(0, %{}, 0)
    assert raw_report("2027-11-27") == published
    assert_reconciles("2027-11-28")
  end

  test "late credit restoration absorbs shortfall before expiry and consumption reduces liability" do
    applied([
      start(),
      opening("issuer", "a"),
      cash("first", "issuer", 50),
      cash("second", "issuer", 50),
      cancel("issuer", "hotel_credit"),
      opening("restore", "b"),
      opening("consume", "c", "advance_purchase"),
      credit("restore", 80),
      credit("consume", 25),
      close(),
      correction("charge_back_payment", "first"),
      close("2027-11-27")
    ])

    published = raw_report("2027-11-27")
    applied([cancel("restore"), cancel("consume")])
    assert raw_report("2027-11-27") == published
    assert report("2027-11-28")["credit"] == credit_entry(105, %{}, 0)

    assert report("2027-11-28")["late_adjustments"] ==
             late([], %{"absorbed_cents" => 50, "expired_cents" => 30, "consumed_cents" => 25})

    assert_reconciles("2027-11-28")
  end

  test "inception clamping alone is ordinary and already expired late issuance keeps both columns" do
    applied([
      opening("issuer", "a"),
      start("2028-01-01"),
      cash("pay", "issuer", 100),
      close("2028-01-01"),
      cancel("issuer", "hotel_credit")
    ])

    assert report("2028-01-01")["cash"] == [cash_entry("a", 0, %{"received_cents" => 100}, 100)]
    assert report("2028-01-01")["late_adjustments"] == late([], %{})

    assert report("2028-01-02")["late_adjustments"] ==
             late([late_cash("a", %{"converted_to_credit_cents" => 100})], %{
               "issued_cents" => 110,
               "expired_cents" => 110
             })

    assert_reconciles("2028-01-02")
  end

  test "audit failure rolls back a close and rejections do not move the cutoff or report movements" do
    applied([opening("source", "a"), start()])
    op = close()

    Repo.query!("""
    CREATE TRIGGER fail_close_audit BEFORE INSERT ON operations
    WHEN NEW.type = 'close_finance_period'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    assert_error_sent 500, fn ->
      batch([cash("before", "source", 100), op, cash("never", "source", 200)])
    end

    assert report()["status"] == "open"
    assert GroupStay.get_operation(op["operation_id"]) == nil
    assert GroupStay.get_operation("never") == nil
    Repo.query!("DROP TRIGGER fail_close_audit")
    applied([cash("still-open", "source", 10), op])
    published = raw_report("2026-11-26")

    bad = cash("invalid", "source", 2000)

    assert [
             %{"code" => "invalid_period"},
             %{"code" => "payment_exceeds_outstanding"},
             %{"status" => "applied"}
           ] = batch([close("2026-11-25"), bad, cash("after", "source", 20)])

    assert raw_report("2026-11-26") == published

    assert report("2026-11-27")["late_adjustments"] ==
             late([late_cash("a", %{"received_cents" => 20})], %{})
  end

  test "closing the final supported date never leaks future postings into published reports" do
    applied([opening("source", "a"), start("9999-12-31"), close("9999-12-31")])
    published = raw_report("9999-12-31")
    applied([cash("pay", "source", 100)])
    assert raw_report("9999-12-31") == published
    assert read("/api/v1/groups/source")["cash_paid_cents"] == 100

    assert [%{posting_on: "10000-01-01", late_adjustment: true}] =
             Repo.all(FinanceReporting.Movement)
  end

  test "signed ISO years keep chronological posting order across a closed year boundary" do
    applied([
      opening("source", "a"),
      start("-0002-12-30"),
      cash("before", "source", 100, "-0002-12-30"),
      close("-0002-12-31")
    ])

    published = raw_report("-0002-12-31")
    applied([cash("after", "source", 50, "-0002-12-30")])
    assert raw_report("-0002-12-31") == published
    assert report("-0001-01-01")["cash"] == [cash_entry("a", 100, %{}, 150)]

    assert report("-0001-01-01")["late_adjustments"] ==
             late([late_cash("a", %{"received_cents" => 50})], %{})

    assert_reconciles("-0001-01-01")
  end

  test "batches and sequential operations agree and reports are read-only in any order" do
    operations = [
      opening("source", "a"),
      start(),
      cash("before", "source", 100),
      close(),
      cash("after", "source", 50),
      close("2026-11-27"),
      cancel("source", "hotel_credit"),
      close("2027-11-27"),
      correction("charge_back_payment", "before")
    ]

    dates = ~w(2026-11-26 2026-11-27 2026-11-28 2027-11-27 2027-11-28)
    Repo.query!("SAVEPOINT before_batch")
    results = applied(operations)
    reports = Enum.map(dates, &raw_report/1)
    Repo.query!("ROLLBACK TO SAVEPOINT before_batch")
    Repo.query!("RELEASE SAVEPOINT before_batch")
    assert Enum.flat_map(operations, &applied([&1])) == results

    snapshot =
      {Repo.all(FinanceReporting), Repo.all(FinanceReporting.Movement), GroupStay.ledger()}

    assert Enum.map(Enum.reverse(dates), &raw_report/1) == Enum.reverse(reports)
    assert Enum.map(dates, &raw_report/1) == reports

    assert {Repo.all(FinanceReporting), Repo.all(FinanceReporting.Movement), GroupStay.ledger()} ==
             snapshot

    assert_reconciles("2027-11-28")
  end

  defp start(date \\ "2026-11-26"),
    do: %{
      "operation_id" => unique_operation_id("start"),
      "type" => "start_finance_reporting",
      "starts_on" => date
    }

  defp close(date \\ "2026-11-26"),
    do: %{
      "operation_id" => unique_operation_id("close"),
      "type" => "close_finance_period",
      "period_end_on" => date
    }

  defp opening(id, property, plan \\ "flexible"),
    do:
      open_operation(%{
        "group_id" => id,
        "property_id" => property,
        "rate_plan" => plan,
        "arrival_on" => "2029-12-10",
        "departure_on" => "2029-12-11",
        "rooms" => [
          %{
            "room_id" => "room",
            "nightly_rate_cents" => if(plan == "flexible", do: 5000, else: 1000)
          }
        ]
      })

  defp cash(id, group, amount, date \\ "2026-11-26"),
    do:
      operation("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => date
      })

  defp transfer(source, destination, amount),
    do:
      operation("transfer_deposit", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp cancel(group, method \\ "cash"),
    do: operation("cancel_group", %{"group_id" => group, "refund_method" => method})

  defp credit(group, amount),
    do: operation("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp correction(type, payment, amount \\ nil),
    do: operation(type, %{"payment_operation_id" => payment, "amount_cents" => amount})

  defp cash_entry(property, opening, movements, closing),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => columns(@cash_fields, movements),
      "closing_held_cents" => closing
    }

  defp credit_entry(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => columns(@credit_fields, movements),
      "closing_liability_cents" => closing
    }

  defp late_cash(property, movements),
    do: %{"property_id" => property, "movements" => columns(@cash_fields, movements)}

  defp late(cash, credit), do: %{"cash" => cash, "credit" => columns(@credit_fields, credit)}
  defp columns(fields, values), do: Map.merge(Map.new(fields, &{&1, 0}), values)

  defp batch(operations),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
      |> json_response(200)
      |> Map.fetch!("results")

  defp applied(operations) do
    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp read(path), do: build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp report(date \\ "2026-11-26"), do: read("/api/v1/finance/daily-report?date=" <> date)

  defp raw_report(date),
    do: build_conn() |> get("/api/v1/finance/daily-report?date=" <> date) |> response(200)

  defp assert_reconciles(date) do
    report = report(date)
    ledger = read("/api/v1/ledger?on=" <> date)

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger["cash_held_cents"]

    assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]
    late = Map.new(report["late_adjustments"]["cash"], &{&1["property_id"], &1["movements"]})

    for row <- report["cash"] do
      movements =
        Map.merge(row["movements"], Map.get(late, row["property_id"], %{}), fn _key,
                                                                               ordinary,
                                                                               late ->
          ordinary + late
        end)

      outgoing =
        Enum.sum(
          Enum.map(@cash_fields -- ~w(received_cents transferred_in_cents), &movements[&1])
        )

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + movements["received_cents"] +
                 movements["transferred_in_cents"] - outgoing
    end

    credit = report["credit"]

    movements =
      Map.merge(credit["movements"], report["late_adjustments"]["credit"], fn _key,
                                                                              ordinary,
                                                                              late ->
        ordinary + late
      end)

    outgoing = Enum.sum(Enum.map(@credit_fields -- ["issued_cents"], &movements[&1]))

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + movements["issued_cents"] - outgoing
  end
end
