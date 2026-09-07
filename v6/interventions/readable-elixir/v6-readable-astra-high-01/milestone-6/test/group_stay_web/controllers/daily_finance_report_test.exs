defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.{Inception, Movement}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "validates dates, availability, singleton inception and exact durable results", %{
    conn: conn
  } do
    for query <- ["", "?date=", "?date=2026-02-30", "?date[]=2026-10-04"] do
      assert conn |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-04") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    for value <- [nil, 123, %{}, "bad", "2026-02-30"] do
      assert [%{"code" => "invalid_reporting_date"}] = batch(conn, [start(value)])
    end

    assert [%{"code" => "invalid_reporting_date"}] =
             batch(conn, [Map.delete(start(), "starts_on")])

    inception = start() |> Map.put("expected_revision", "ignored")
    assert [result] = batch(conn, [inception])

    assert result == %{
             "operation_id" => inception["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-10-04"
           }

    assert batch(conn, [inception]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(inception, "starts_on", "2026-10-05")])

    assert [%{"code" => "reporting_already_started"}] = batch(conn, [start()])
    assert Repo.aggregate(Inception, :count) == 1

    assert report(conn, "2026-10-04") == %{
             "date" => "2026-10-04",
             "status" => "open",
             "cash" => [],
             "credit" => credit_row(0, %{}, 0)
           }

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-03") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}
  end

  test "inception is a commit boundary and posting dates allow late changes", %{conn: conn} do
    payment = cash("a", 200, "2026-10-01")
    batch(conn, [opening("a"), opening("empty"), cash("a", 100, "2026-11-01"), start(), payment])

    assert report(conn, "2026-10-04")["cash"] == [
             cash_row("a", 100, %{"received_cents" => 200}, 300)
           ]

    assert report(conn, "2026-10-05")["cash"] == [cash_row("a", 300, %{}, 300)]

    batch(conn, [cash("a", 50, "2026-10-06")])
    previous = report(conn, "2026-10-06")
    batch(conn, [cash("a", 20, "2026-10-05")])

    assert report(conn, "2026-10-06")["cash"] == [
             cash_row("a", 320, %{"received_cents" => 50}, 370)
           ]

    refute report(conn, "2026-10-06") == previous

    assert report(conn, "2026-10-04")["cash"] == [
             cash_row("a", 100, %{"received_cents" => 200}, 300)
           ]

    snapshot = snapshot()
    batch(conn, [payment])
    assert snapshot() == snapshot

    assert [%{"code" => "payment_exceeds_outstanding"}, %{"status" => "applied"}] =
             batch(conn, [cash("a", 10_000), cash("a", 10, "2026-10-06")])

    assert_reconciled(conn, "2026-10-06")
  end

  test "cash movements follow transfers, settlements and corrections at each property", %{
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
      cancel("convert", %{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2026-10-04")["cash"] == [
             cash_row(
               "convert",
               0,
               %{"transferred_in_cents" => 20, "converted_to_credit_cents" => 20},
               0
             ),
             cash_row("held", 0, %{"transferred_in_cents" => 20}, 20),
             cash_row(
               "original",
               0,
               %{"received_cents" => 100, "transferred_out_cents" => 80},
               20
             ),
             cash_row("refund", 0, %{"transferred_in_cents" => 20, "refunded_cents" => 20}, 0),
             cash_row("retain", 0, %{"transferred_in_cents" => 20, "retained_cents" => 20}, 0)
           ]

    assert report(conn, "2026-10-04")["credit"] == credit_row(0, %{"issued_cents" => 22}, 22)

    reduction =
      correction("reduce_cash_payment", payment, %{
        "amount_cents" => 5,
        "occurred_on" => "2026-10-05"
      })

    chargeback = correction("charge_back_payment", payment, %{"occurred_on" => "2026-10-06"})
    batch(conn, [reduction, chargeback])

    assert report(conn, "2026-10-05")["cash"] == [
             cash_row("held", 20, %{"reduced_cents" => 5}, 15),
             cash_row("original", 20, %{}, 20)
           ]

    assert report(conn, "2026-10-06")["cash"] == [
             cash_row(
               "convert",
               0,
               %{"converted_to_credit_cents" => -20, "charged_back_cents" => 20},
               0
             ),
             cash_row("held", 15, %{"charged_back_cents" => 15}, 0),
             cash_row("original", 20, %{"charged_back_cents" => 20}, 0),
             cash_row("refund", 0, %{"refunded_cents" => -20, "charged_back_cents" => 20}, 0),
             cash_row("retain", 0, %{"retained_cents" => -20, "charged_back_cents" => 20}, 0)
           ]

    assert report(conn, "2026-10-06")["credit"] == credit_row(22, %{"revoked_cents" => 22}, 0)
    before = snapshot()
    batch(conn, [payment, reduction, chargeback])
    assert snapshot() == before
    assert_reconciled(conn, "2026-10-06")
  end

  test "same-property transfers retain both movement columns and mixed funding counts only cash",
       %{conn: conn} do
    batch(conn, [
      opening("seed"),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      opening("source", %{"property_id" => "hotel"}),
      opening("destination", %{"property_id" => "hotel"}),
      cash("source", 100),
      credit("source", 100),
      start(),
      transfer("source", "destination", 150)
    ])

    assert report(conn, "2026-10-04")["cash"] == [
             cash_row(
               "hotel",
               100,
               %{"transferred_in_cents" => 50, "transferred_out_cents" => 50},
               100
             )
           ]

    assert report(conn, "2026-10-04")["credit"] == credit_row(110, %{}, 110)
    assert_reconciled(conn, "2026-10-04")
  end

  test "pre-inception settlements are reversed without reconstructing old movements", %{
    conn: conn
  } do
    payment = cash("a", 100)

    batch(conn, [
      opening("a"),
      payment,
      cancel("a"),
      start(),
      correction("charge_back_payment", payment)
    ])

    assert report(conn, "2026-10-04")["cash"] == [
             cash_row("a", 0, %{"refunded_cents" => -100, "charged_back_cents" => 100}, 0)
           ]
  end

  test "unused credit expires on the next date without operations, while applied credit is paused",
       %{conn: conn} do
    batch(conn, [
      opening("seed"),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      opening("user"),
      credit("user", 100),
      start()
    ])

    before = snapshot()
    assert report(conn, "2027-10-04")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2027-10-05")["credit"] == credit_row(110, %{"expired_cents" => 10}, 100)
    assert report(conn, "2027-10-06")["credit"] == credit_row(100, %{}, 100)
    assert report(conn, "2027-10-05")["credit"] == credit_row(110, %{"expired_cents" => 10}, 100)
    assert snapshot() == before
    assert_reconciled(conn, "2027-10-06")
  end

  test "expiry schedules track redemptions and refundable restorations without a second bonus", %{
    conn: conn
  } do
    batch(conn, [
      opening("seed"),
      opening("user"),
      start(),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2027-10-05")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    batch(conn, [credit("user", 100)])
    assert report(conn, "2027-10-05")["credit"] == credit_row(110, %{"expired_cents" => 10}, 100)

    batch(conn, [
      cancel("user", %{"occurred_on" => "2026-10-05", "refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2026-10-05")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2027-10-05")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    assert_reconciled(conn, "2027-10-05")
  end

  test "restoration after expiry is an expiry on the operation posting date", %{conn: conn} do
    batch(conn, [
      opening("seed"),
      opening("user", %{"arrival_on" => "2028-12-10", "departure_on" => "2028-12-11"}),
      start(),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      credit("user", 100),
      cancel("user", %{"occurred_on" => "2028-01-01"})
    ])

    assert report(conn, "2027-10-05")["credit"] == credit_row(110, %{"expired_cents" => 10}, 100)
    assert report(conn, "2028-01-01")["credit"] == credit_row(100, %{"expired_cents" => 100}, 0)
    assert_reconciled(conn, "2028-01-01")
  end

  for {date, expired, closing} <- [{"2026-10-05", 0, 110}, {"2028-01-01", 10, 100}] do
    test "shortfall absorption precedes restoration expiry on #{date}", %{conn: conn} do
      p1 = cash("seed", 100)

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
        p1,
        cash("seed", 100),
        cancel("seed", %{"refund_method" => "hotel_credit"}),
        credit("user", 200),
        correction("charge_back_payment", p1),
        operation("cancel_rooms", %{
          "group_id" => "user",
          "room_ids" => ["r1"],
          "occurred_on" => unquote(date)
        })
      ])

      assert report(conn, "2026-10-04")["credit"] ==
               credit_row(0, %{"issued_cents" => 220, "revoked_cents" => 20}, 200)

      assert report(conn, unquote(date))["credit"] ==
               credit_row(
                 200,
                 %{"absorbed_cents" => 90, "expired_cents" => unquote(expired)},
                 unquote(closing)
               )

      batch(conn, [cancel("user", %{"occurred_on" => "2028-12-10"})])

      assert report(conn, "2028-12-10")["credit"] ==
               credit_row(100, %{"consumed_cents" => 100}, 0)

      assert_reconciled(conn, "2028-12-10")
    end
  end

  test "already expired unused entitlement is not revoked twice", %{conn: conn} do
    payment = cash("seed", 100)

    batch(conn, [
      opening("seed"),
      start(),
      payment,
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      correction("charge_back_payment", payment, %{"occurred_on" => "2028-01-01"})
    ])

    assert report(conn, "2027-10-05")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    assert report(conn, "2028-01-01")["credit"] == credit_row(0, %{}, 0)
    assert_reconciled(conn, "2028-01-01")
  end

  test "inception excludes expired availability but includes applied expired credit", %{
    conn: conn
  } do
    batch(conn, [
      opening("seed"),
      opening("user"),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      credit("user", 100),
      start("2028-01-01")
    ])

    assert report(conn, "2028-01-01")["credit"] == credit_row(100, %{}, 100)
    assert Repo.all(Movement) == []
    assert_reconciled(conn, "2028-01-01")
  end

  test "backdated credit operations clamped to inception reconcile expired availability", %{
    conn: conn
  } do
    batch(conn, [
      opening("seed"),
      opening("user"),
      cash("seed", 100),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      start("2028-01-01"),
      credit("user", 100)
    ])

    assert report(conn, "2028-01-01")["credit"] == credit_row(0, %{"expired_cents" => -100}, 100)
    assert_reconciled(conn, "2028-01-01")
  end

  test "batch and sequential submissions produce identical reports", %{conn: conn} do
    operations = [
      opening("seed"),
      opening("user"),
      cash("seed", 100),
      start(),
      cancel("seed", %{"refund_method" => "hotel_credit"}),
      credit("user", 100),
      transfer("user", "seed", 1),
      cancel("user", %{"occurred_on" => "2026-10-05"})
    ]

    dates = ~w(2026-10-04 2026-10-05 2027-10-05)
    Repo.query!("SAVEPOINT batch_comparison")
    results = batch(conn, operations)
    reports = Enum.map(dates, &report(conn, &1))
    Repo.query!("ROLLBACK TO SAVEPOINT batch_comparison")
    Repo.query!("RELEASE SAVEPOINT batch_comparison")
    assert Enum.flat_map(operations, &batch(conn, [&1])) == results
    assert Enum.map(dates, &report(conn, &1)) == reports
  end

  defp start(date \\ "2026-10-04"),
    do:
      operation("start_finance_reporting", %{"starts_on" => date})
      |> Map.drop(["group_id", "occurred_on"])

  defp opening(id, overrides \\ %{}),
    do:
      open_operation(
        Map.merge(
          %{
            "group_id" => id,
            "property_id" => id,
            "departure_on" => "2026-12-11",
            "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 5000}]
          },
          overrides
        )
      )

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
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => Map.merge(Map.new(@cash_fields, &{&1, 0}), movements),
      "closing_held_cents" => closing
    }

  defp credit_row(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(Map.new(@credit_fields, &{&1, 0}), movements),
      "closing_liability_cents" => closing
    }

  defp report(conn, date),
    do:
      conn
      |> get("/api/v1/finance/daily-report?date=#{date}")
      |> json_response(200)
      |> Map.fetch!("data")

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
          Inception,
          Movement,
          GroupStay.Operations.Record,
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

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))
  end
end
