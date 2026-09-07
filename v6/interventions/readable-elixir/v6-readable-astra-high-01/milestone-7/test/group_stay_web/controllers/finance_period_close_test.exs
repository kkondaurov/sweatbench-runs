defmodule GroupStayWeb.FinancePeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.{Movement, PeriodClose}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "close validation, exact results, durable rejections and replay", %{conn: conn} do
    premature = close("2026-10-04")
    assert [rejected] = batch(conn, [premature])
    assert rejected["code"] == "invalid_period"
    batch(conn, [start()])
    assert batch(conn, [premature]) == [rejected]

    for value <- [nil, 123, [], %{}, "bad", "2026-02-30", "2026-10-03"] do
      assert [%{"code" => "invalid_period"}] = batch(conn, [close(value)])
    end

    assert [%{"code" => "invalid_period"}] =
             batch(conn, [Map.delete(close("2026-10-04"), "period_end_on")])

    cutoff = close("2026-10-04") |> Map.put("expected_revision", "ignored")
    assert [result] = batch(conn, [cutoff])

    assert result == %{
             "operation_id" => cutoff["operation_id"],
             "status" => "applied",
             "period_end_on" => "2026-10-04"
           }

    assert data(conn, "/api/v1/operations/#{cutoff["operation_id"]}") == result

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(cutoff, "period_end_on", "2026-10-05")])

    assert [%{"code" => "invalid_period"}, %{"code" => "invalid_period"}] =
             batch(conn, [close("2026-10-04"), close("2026-10-03")])

    published = report(conn, "2026-10-04")

    assert published == %{
             "date" => "2026-10-04",
             "status" => "closed",
             "cash" => [],
             "credit" => credit_row(0, %{}, 0),
             "late_adjustments" => late([], %{})
           }

    assert [%{"status" => "applied"}] = batch(conn, [close("2026-10-07")])
    assert batch(conn, [cutoff]) == [result]
    assert Repo.aggregate(PeriodClose, :count) == 2
    assert report(conn, "2026-10-04") == published
    assert report(conn, "2026-10-07")["status"] == "closed"
    assert report(conn, "2026-10-08")["status"] == "open"

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-03") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}
  end

  test "same-batch boundaries freeze posting dates and split ordinary and late receipts", %{
    conn: conn
  } do
    payment = cash("a", 20, "2026-10-01")

    operations = [
      opening("a"),
      start(),
      cash("a", 100, "2026-10-01"),
      cash("a", 30, "2026-10-07"),
      close("2026-10-04"),
      payment,
      cash("a", 10, "2026-10-05")
    ]

    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    published = report(conn, "2026-10-04")
    assert published["cash"] == [cash_row("a", 0, %{"received_cents" => 100}, 100)]
    assert published["late_adjustments"] == late([], %{})

    assert report(conn, "2026-10-05")["cash"] == [
             cash_row("a", 100, %{"received_cents" => 10}, 130)
           ]

    assert report(conn, "2026-10-05")["late_adjustments"] ==
             late([late_cash("a", %{"received_cents" => 20})], %{})

    batch(conn, [close("2026-10-06")])
    second = report(conn, "2026-10-05")
    assert second["status"] == "closed"
    batch(conn, [cash("a", 5, "2026-10-01"), close("2026-10-07")])

    assert report(conn, "2026-10-07")["cash"] == [
             cash_row("a", 130, %{"received_cents" => 30}, 165)
           ]

    assert report(conn, "2026-10-07")["late_adjustments"] ==
             late([late_cash("a", %{"received_cents" => 5})], %{})

    assert batch(conn, operations) == results
    before = snapshot()
    assert [%{"code" => "payment_exceeds_outstanding"}] = batch(conn, [cash("a", 100_000)])
    assert snapshot() == before

    for _ <- 1..2 do
      assert report(conn, "2026-10-05") == second
      assert report(conn, "2026-10-04") |> Jason.encode!() == Jason.encode!(published)
    end

    assert snapshot() == before
    assert_reconciled(conn, "2026-10-07")
  end

  test "an operation already dated in the open period keeps its date and ordinary classification",
       %{conn: conn} do
    batch(conn, [opening("a"), start(), close("2026-10-04"), cash("a", 100, "2026-10-08")])
    assert report(conn, "2026-10-05")["cash"] == []

    assert report(conn, "2026-10-08")["cash"] == [
             cash_row("a", 0, %{"received_cents" => 100}, 100)
           ]

    assert report(conn, "2026-10-08")["late_adjustments"] == late([], %{})
    batch(conn, [close("2026-10-10")])
    published = report(conn, "2026-10-08")
    batch(conn, [cash("a", 50, "2026-10-08")])
    assert report(conn, "2026-10-08") == published

    assert report(conn, "2026-10-11")["late_adjustments"] ==
             late([late_cash("a", %{"received_cents" => 50})], %{})

    assert_reconciled(conn, "2026-10-11")
  end

  test "late corrections preserve signed dispositions at transferred settlement properties", %{
    conn: conn
  } do
    payment = cash("original", 100)

    batch(conn, [
      opening("original"),
      opening("refund"),
      opening("retain", %{"rate_plan" => "advance_purchase"}),
      opening("convert"),
      opening("held"),
      start(),
      payment,
      transfer("original", "refund", 20),
      transfer("original", "retain", 20),
      transfer("original", "convert", 20),
      transfer("original", "held", 20),
      cancel("refund"),
      cancel("retain"),
      cancel("convert", %{"refund_method" => "hotel_credit"}),
      close("2026-10-04")
    ])

    published = report(conn, "2026-10-04")
    original_result = data(conn, "/api/v1/operations/#{payment["operation_id"]}")

    batch(conn, [
      correction("reduce_cash_payment", payment, %{"amount_cents" => 5}),
      correction("charge_back_payment", payment)
    ])

    report = report(conn, "2026-10-05")

    assert report["late_adjustments"] ==
             late(
               [
                 late_cash("convert", %{
                   "converted_to_credit_cents" => -20,
                   "charged_back_cents" => 20
                 }),
                 late_cash("held", %{"reduced_cents" => 5, "charged_back_cents" => 15}),
                 late_cash("original", %{"charged_back_cents" => 20}),
                 late_cash("refund", %{"refunded_cents" => -20, "charged_back_cents" => 20}),
                 late_cash("retain", %{"retained_cents" => -20, "charged_back_cents" => 20})
               ],
               %{"revoked_cents" => 22}
             )

    assert report["cash"] == [
             cash_row("convert", 0, %{}, 0),
             cash_row("held", 20, %{}, 0),
             cash_row("original", 20, %{}, 0),
             cash_row("refund", 0, %{}, 0),
             cash_row("retain", 0, %{}, 0)
           ]

    assert report["credit"] == credit_row(22, %{}, 0)
    assert report(conn, "2026-10-04") == published
    assert data(conn, "/api/v1/operations/#{payment["operation_id"]}") == original_result

    assert %{
             "recorded_cents" => 100,
             "reduced_cents" => 5,
             "charged_back_cents" => 95,
             "held_by_group" => []
           } = data(conn, "/api/v1/payments/#{payment["operation_id"]}")

    assert_reconciled(conn, "2026-10-05")
  end

  test "late mixed transfers and settlement leave credit expiry on its natural day", %{conn: conn} do
    batch(conn, [
      opening("seed"),
      opening("source"),
      opening("destination"),
      start(),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      cash("source", 100),
      credit("source", 100),
      close("2026-10-04")
    ])

    published = report(conn, "2026-10-04")

    batch(conn, [
      transfer("source", "destination", 150),
      cancel("destination", %{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2026-10-05")["late_adjustments"] ==
             late(
               [
                 late_cash("destination", %{
                   "transferred_in_cents" => 50,
                   "converted_to_credit_cents" => 50
                 }),
                 late_cash("source", %{"transferred_out_cents" => 50})
               ],
               %{"issued_cents" => 55}
             )

    assert report(conn, "2026-10-05")["credit"] == credit_row(110, %{}, 165)
    assert report(conn, "2026-10-04") == published
    batch(conn, [close("2027-10-05")])
    expiry = report(conn, "2027-10-05")
    assert expiry["credit"] == credit_row(165, %{"expired_cents" => 165}, 0)
    assert expiry["late_adjustments"] == late([], %{})
    assert expiry["status"] == "closed"
    assert_reconciled(conn, "2027-10-05")
  end

  test "backdated redemption and restoration correct a closed expiry on the first open day", %{
    conn: conn
  } do
    batch(conn, [
      opening("seed"),
      opening("user"),
      start(),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      close("2027-10-05")
    ])

    expiry = report(conn, "2027-10-05")
    assert expiry["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    batch(conn, [credit("user", 100)])
    assert report(conn, "2027-10-06")["credit"] == credit_row(0, %{}, 100)
    assert report(conn, "2027-10-06")["late_adjustments"] == late([], %{"expired_cents" => -100})
    assert_reconciled(conn, "2027-10-06")
    batch(conn, [close("2027-10-06")])
    redemption = report(conn, "2027-10-06")
    batch(conn, [cancel("user")])
    assert report(conn, "2027-10-07")["credit"] == credit_row(100, %{}, 0)
    assert report(conn, "2027-10-07")["late_adjustments"] == late([], %{"expired_cents" => 100})
    assert report(conn, "2027-10-05") == expiry
    assert report(conn, "2027-10-06") == redemption
    assert_reconciled(conn, "2027-10-07")
  end

  test "late credit shortfall absorption precedes expiry and nonrefundable consumption", %{
    conn: conn
  } do
    payment = cash("seed", 100)

    batch(conn, [
      opening("seed"),
      opening("user", %{
        "arrival_on" => "2028-12-10",
        "departure_on" => "2028-12-11",
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 500},
          %{"room_id" => "r2", "nightly_rate_cents" => 500}
        ]
      }),
      start(),
      payment,
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      credit("user", 200),
      close("2026-10-04"),
      correction("charge_back_payment", payment),
      close("2027-10-05")
    ])

    published = report(conn, "2027-10-05")
    batch(conn, [operation("cancel_rooms", %{"group_id" => "user", "room_ids" => ["r1"]})])

    assert report(conn, "2027-10-06")["late_adjustments"] ==
             late([], %{"absorbed_cents" => 90, "expired_cents" => 10})

    assert report(conn, "2027-10-06")["credit"] == credit_row(200, %{}, 100)
    assert_reconciled(conn, "2027-10-06")
    batch(conn, [close("2028-12-10"), cancel("user", %{"occurred_on" => "2028-12-10"})])
    assert report(conn, "2028-12-11")["late_adjustments"] == late([], %{"consumed_cents" => 100})
    assert report(conn, "2027-10-05") == published
    assert_reconciled(conn, "2028-12-11")
  end

  test "a late lot issued after its expiry keeps both issue and expiry classifications", %{
    conn: conn
  } do
    batch(conn, [opening("seed"), start(), cash("seed", 100), close("2027-10-05")])
    published = report(conn, "2027-10-05")
    batch(conn, [cancel("seed", %{"refund_method" => "hotel_credit"})])
    assert report(conn, "2027-10-06")["credit"] == credit_row(0, %{}, 0)

    assert report(conn, "2027-10-06")["late_adjustments"] ==
             late(
               [
                 late_cash("seed", %{"converted_to_credit_cents" => 100})
               ],
               %{"issued_cents" => 110, "expired_cents" => 110}
             )

    assert report(conn, "2027-10-05") == published
    assert_reconciled(conn, "2027-10-06")
  end

  test "batch and sequential commits produce equivalent closed reports and adjustments", %{
    conn: conn
  } do
    operations = [
      opening("a"),
      start(),
      cash("a", 100),
      close("2026-10-04"),
      cash("a", 50),
      close("2026-10-05"),
      cancel("a")
    ]

    dates = ~w(2026-10-04 2026-10-05 2026-10-06)
    Repo.query!("SAVEPOINT compare_closes")
    results = batch(conn, operations)
    reports = Enum.map(dates, &report(conn, &1))
    Repo.query!("ROLLBACK TO SAVEPOINT compare_closes")
    Repo.query!("RELEASE SAVEPOINT compare_closes")
    assert Enum.flat_map(operations, &batch(conn, [&1])) == results
    assert Enum.map(dates, &report(conn, &1)) == reports
  end

  defp start,
    do:
      operation("start_finance_reporting", %{"starts_on" => "2026-10-04"})
      |> Map.drop(["group_id", "occurred_on"])

  defp close(date),
    do:
      operation("close_finance_period", %{"period_end_on" => date})
      |> Map.drop(["group_id", "occurred_on"])

  defp opening(id, overrides \\ %{}),
    do: open_operation(Map.merge(%{"group_id" => id, "property_id" => id}, overrides))

  defp cash(group, amount, date \\ "2026-10-04"),
    do:
      operation("record_cash_payment", %{
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => date
      })

  defp credit(group, amount),
    do: operation("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp cancel(group, overrides \\ %{}),
    do: operation("cancel_group", Map.merge(%{"group_id" => group}, overrides))

  defp transfer(source, destination, amount),
    do:
      operation("transfer_deposit", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })
      |> Map.delete("group_id")

  defp correction(type, payment, overrides \\ %{}),
    do:
      operation(type, Map.merge(%{"payment_operation_id" => payment["operation_id"]}, overrides))
      |> Map.delete("group_id")

  defp cash_row(property, opening, movements, closing),
    do:
      Map.merge(late_cash(property, movements), %{
        "opening_held_cents" => opening,
        "closing_held_cents" => closing
      })

  defp late_cash(property, movements),
    do: %{
      "property_id" => property,
      "movements" => Map.merge(Map.new(@cash_fields, &{&1, 0}), movements)
    }

  defp credit_row(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(Map.new(@credit_fields, &{&1, 0}), movements),
      "closing_liability_cents" => closing
    }

  defp late(cash, credit),
    do: %{"cash" => cash, "credit" => Map.merge(Map.new(@credit_fields, &{&1, 0}), credit)}

  defp report(conn, date), do: data(conn, "/api/v1/finance/daily-report?date=#{date}")
  defp data(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("data")

  defp batch(conn, operations),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
      |> json_response(200)
      |> Map.fetch!("results")

  defp snapshot,
    do:
      Enum.map(
        [
          Movement,
          PeriodClose,
          GroupStay.Reservations.Group,
          GroupStay.Credits.Lot,
          GroupStay.Credits.Allocation,
          GroupStay.Accounting.CashAllocation
        ],
        &Repo.all/1
      )

  defp assert_reconciled(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents

    for row <- report["cash"] do
      late_row =
        Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == row["property_id"]))

      total =
        Map.merge(row["movements"], if(late_row, do: late_row["movements"], else: %{}), fn _,
                                                                                           ordinary,
                                                                                           late ->
          ordinary + late
        end)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + total["received_cents"] + total["transferred_in_cents"] -
                 total["transferred_out_cents"] - total["refunded_cents"] -
                 total["retained_cents"] - total["converted_to_credit_cents"] -
                 total["reduced_cents"] - total["charged_back_cents"]
    end

    credit = report["credit"]

    total =
      Map.merge(credit["movements"], report["late_adjustments"]["credit"], fn _, ordinary, late ->
        ordinary + late
      end)

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + total["issued_cents"] - total["expired_cents"] -
               total["consumed_cents"] - total["revoked_cents"] - total["absorbed_cents"]
  end
end
