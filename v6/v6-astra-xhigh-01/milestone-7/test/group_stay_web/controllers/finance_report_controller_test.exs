defmodule GroupStayWeb.FinanceReportControllerTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerFixtures
  import Ecto.Query
  alias GroupStay.{FinanceReporting, Repo, Reservations}
  alias GroupStay.FinanceReporting.{Entry, Inception}
  alias GroupStay.Reservations.{CreditLot, Group}

  test "report dates are required and inception is validated, durable and independent of groups",
       %{conn: conn} do
    for query <- ["", "?date=", "?date=2026-02-30", "?date[]=2026-11-01", "?date=tomorrow"] do
      assert conn |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert unavailable(conn, "2026-11-01") == "report_not_available"

    for value <- [nil, "", "2026-02-30", 20_261_101, [], %{}, "10000-01-01"] do
      invalid = Map.put(start(), "starts_on", value)
      assert submit(conn, invalid)["code"] == "invalid_reporting_date"
    end

    missing = Map.delete(start(), "starts_on")
    rejection = submit(conn, missing)
    assert rejection["code"] == "invalid_reporting_date"
    refute Repo.get(Inception, 1)
    assert Repo.all(Entry) == []

    start = Map.merge(start(), %{"expected_revision" => -10, "group_id" => "missing"})

    expected = %{
      "operation_id" => start["operation_id"],
      "status" => "applied",
      "starts_on" => "2026-11-01"
    }

    assert apply!(conn, start) == expected
    assert apply!(conn, start) == expected

    assert submit(conn, Map.put(start, "starts_on", "2026-11-02"))["code"] ==
             "operation_id_conflict"

    assert submit(conn, start())["code"] == "reporting_already_started"
    assert submit(conn, missing) == rejection

    assert get(conn, "/api/v1/operations/#{start["operation_id"]}") |> json_response(200) == %{
             "data" => expected
           }

    assert unavailable(conn, "2026-10-31") == "report_not_available"
    assert report(conn, "2026-11-01") == empty_report("2026-11-01")
    assert report(conn, "2028-01-01") == empty_report("2028-01-01")
  end

  test "inception snapshots committed state and splits a batch at the start operation", %{
    conn: conn
  } do
    prior_payment = op("record_cash_payment", "source", "2026-12-01", %{"amount_cents" => 100})
    after_payment = op("record_cash_payment", "source", "2026-10-01", %{"amount_cents" => 50})

    operations = [
      opening("source", "z-property"),
      opening("empty", "a-property"),
      prior_payment,
      start(),
      after_payment,
      op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => -1})
    ]

    results = batch(conn, operations)
    assert List.last(results)["code"] == "invalid_amount"

    expected =
      cash_report("2026-11-01", [cash("z-property", 100, 150, %{"received_cents" => 50})])

    assert report(conn, "2026-11-01") == expected
    assert report(conn, "2026-12-01") == cash_report("2026-12-01", [cash("z-property", 150, 150)])
    before = snapshot()
    assert batch(conn, operations) == results
    assert report(conn, "2026-11-01") == expected
    assert snapshot() == before
    assert_reconciles(conn, "2026-12-01")
  end

  test "cash follows transfers and each held or settled property through reductions and chargeback",
       %{conn: conn} do
    apply!(conn, start())

    for {id, property} <- [
          {"source", "a"},
          {"refund", "b"},
          {"convert", "d"},
          {"held", "e"},
          {"credit-user", "z"}
        ] do
      apply!(conn, opening(id, property))
    end

    apply!(conn, opening("retain", "c", %{"rate_plan" => "advance_purchase"}))
    payment = op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 500})
    original = apply!(conn, payment)
    apply!(conn, target("reduce_cash_payment", payment, "2026-11-01", %{"amount_cents" => 50}))

    for destination <- ~w(refund retain convert held),
        do: apply!(conn, transfer("source", destination, 100))

    assert report(conn, "2026-11-01") ==
             cash_report("2026-11-01", [
               cash("a", 0, 50, %{
                 "received_cents" => 500,
                 "reduced_cents" => 50,
                 "transferred_out_cents" => 400
               }),
               cash("b", 0, 100, %{"transferred_in_cents" => 100}),
               cash("c", 0, 100, %{"transferred_in_cents" => 100}),
               cash("d", 0, 100, %{"transferred_in_cents" => 100}),
               cash("e", 0, 100, %{"transferred_in_cents" => 100})
             ])

    assert_reconciles(conn, "2026-11-01")

    for id <- ~w(refund retain), do: apply!(conn, op("cancel_group", id, "2026-11-02"))

    apply!(
      conn,
      op("cancel_group", "convert", "2026-11-02", %{"refund_method" => "hotel_credit"})
    )

    apply!(conn, op("apply_hotel_credit", "credit-user", "2026-11-02", %{"amount_cents" => 80}))

    assert report(conn, "2026-11-02") ==
             cash_report(
               "2026-11-02",
               [
                 cash("a", 50, 50),
                 cash("b", 100, 0, %{"refunded_cents" => 100}),
                 cash("c", 100, 0, %{"retained_cents" => 100}),
                 cash("d", 100, 0, %{"converted_to_credit_cents" => 100}),
                 cash("e", 100, 100)
               ],
               credit(0, 110, %{"issued_cents" => 110})
             )

    assert_reconciles(conn, "2026-11-02")

    apply!(conn, target("reduce_cash_payment", payment, "2026-11-03", %{"amount_cents" => 75}))

    assert report(conn, "2026-11-03")["cash"] == [
             cash("a", 50, 50),
             cash("e", 100, 25, %{"reduced_cents" => 75})
           ]

    chargeback = target("charge_back_payment", payment, "2026-11-04")
    assert apply!(conn, chargeback)["charged_back_cents"] == 375

    expected =
      cash_report(
        "2026-11-04",
        [
          cash("a", 50, 0, %{"charged_back_cents" => 50}),
          cash("b", 0, 0, %{"refunded_cents" => -100, "charged_back_cents" => 100}),
          cash("c", 0, 0, %{"retained_cents" => -100, "charged_back_cents" => 100}),
          cash("d", 0, 0, %{"converted_to_credit_cents" => -100, "charged_back_cents" => 100}),
          cash("e", 25, 0, %{"charged_back_cents" => 25})
        ],
        credit(110, 80, %{"revoked_cents" => 30})
      )

    assert report(conn, "2026-11-04") == expected
    assert_reconciles(conn, "2026-11-04")
    assert apply!(conn, payment) == original
    apply!(conn, chargeback)
    assert report(conn, "2026-11-04") == expected

    apply!(conn, op("cancel_group", "credit-user", "2026-11-05"))

    assert report(conn, "2026-11-05") ==
             cash_report("2026-11-05", [], credit(80, 0, %{"absorbed_cents" => 80}))

    assert_reconciles(conn, "2026-11-05")
  end

  test "unused opening credit expires without operations while applied credit stays in liability",
       %{conn: conn} do
    seed_credit(conn, "one", 100)
    seed_credit(conn, "two", 100)
    apply!(conn, opening("user", "credit-only"))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-01", %{"amount_cents" => 80}))
    apply!(conn, start("2027-11-01"))
    before = snapshot()
    assert report(conn, "2027-11-01") == cash_report("2027-11-01", [], credit(220, 220))

    assert report(conn, "2027-11-02") ==
             cash_report("2027-11-02", [], credit(220, 80, %{"expired_cents" => 140}))

    assert report(conn, "2028-01-01") == cash_report("2028-01-01", [], credit(80, 80))
    assert report(conn, "2027-11-02")["credit"]["closing_liability_cents"] == 80
    assert snapshot() == before
    assert_reconciles(conn, "2027-11-02")

    apply!(conn, op("cancel_group", "user", "2027-11-03"))

    assert report(conn, "2027-11-03") ==
             cash_report("2027-11-03", [], credit(80, 0, %{"expired_cents" => 80}))

    assert_reconciles(conn, "2027-11-03")
  end

  test "inception omits already expired available credit but retains expired applied credit", %{
    conn: conn
  } do
    seed_credit(conn, "source", 100)
    apply!(conn, opening("user", "p"))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-01", %{"amount_cents" => 40}))
    apply!(conn, start("2027-11-02"))
    assert report(conn, "2027-11-02") == cash_report("2027-11-02", [], credit(40, 40))
    assert_reconciles(conn, "2027-11-02")
    apply!(conn, op("cancel_group", "user", "2027-11-03"))
    assert report(conn, "2027-11-03")["credit"] == credit(40, 0, %{"expired_cents" => 40})
  end

  test "credit restoration adjusts future expiry and nonrefundable settlement consumes liability",
       %{conn: conn} do
    apply!(conn, start())
    seed_credit(conn, "source", 100)
    apply!(conn, opening("user", "p"))
    apply!(conn, opening("nonrefundable", "p", %{"rate_plan" => "advance_purchase"}))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-02", %{"amount_cents" => 80}))
    apply!(conn, op("cancel_rooms", "user", "2026-11-03", %{"room_ids" => ["r1"]}))
    assert report(conn, "2026-11-03")["credit"] == credit(110, 110)
    apply!(conn, op("apply_hotel_credit", "nonrefundable", "2026-11-04", %{"amount_cents" => 50}))
    apply!(conn, op("cancel_group", "nonrefundable", "2026-11-05"))
    assert report(conn, "2026-11-05")["credit"] == credit(110, 60, %{"consumed_cents" => 50})
    assert report(conn, "2027-11-02")["credit"] == credit(60, 0, %{"expired_cents" => 60})
    assert_reconciles(conn, "2027-11-02")
  end

  test "clawback absorbs restored credit before expiry and does not revoke already expired liability twice",
       %{conn: conn} do
    apply!(conn, start())
    payment = seed_credit(conn, "source", 100)
    apply!(conn, opening("user", "p"))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-02", %{"amount_cents" => 80}))
    assert report(conn, "2027-11-02")["credit"] == credit(110, 80, %{"expired_cents" => 30})
    apply!(conn, target("charge_back_payment", payment, "2027-11-03"))
    assert report(conn, "2027-11-03")["credit"] == credit(80, 80)
    apply!(conn, op("cancel_group", "user", "2027-11-04"))
    assert report(conn, "2027-11-04")["credit"] == credit(80, 0, %{"absorbed_cents" => 80})
    assert report(conn, "2027-11-02")["credit"] == credit(110, 80, %{"expired_cents" => 30})
    assert_reconciles(conn, "2027-11-04")
  end

  test "mixed transfers report only cash including transfers within the same property", %{
    conn: conn
  } do
    seed_credit(conn, "credit-source", 100)

    for {id, property} <- [{"source", "a"}, {"same", "a"}, {"destination", "b"}] do
      apply!(conn, opening(id, property))
    end

    apply!(conn, op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 100}))
    apply!(conn, op("apply_hotel_credit", "source", "2026-11-01", %{"amount_cents" => 80}))
    apply!(conn, start())
    apply!(conn, transfer("source", "destination", 100))
    apply!(conn, transfer("source", "same", 30))

    assert report(conn, "2026-11-01") ==
             cash_report(
               "2026-11-01",
               [
                 cash("a", 100, 80, %{"transferred_in_cents" => 30, "transferred_out_cents" => 50}),
                 cash("b", 0, 20, %{"transferred_in_cents" => 20})
               ],
               credit(110, 110)
             )

    apply!(conn, op("cancel_group", "destination", "2027-11-03"))
    assert report(conn, "2027-11-03")["credit"] == credit(80, 0, %{"expired_cents" => 80})
    assert_reconciles(conn, "2027-11-03")
  end

  test "late postings change earlier open reports without reads changing any state", %{conn: conn} do
    apply!(conn, opening("source", "p"))
    apply!(conn, start())
    apply!(conn, op("record_cash_payment", "source", "2026-11-03", %{"amount_cents" => 100}))
    assert report(conn, "2026-11-01") == empty_report("2026-11-01")
    assert report(conn, "2026-11-03")["cash"] == [cash("p", 0, 100, %{"received_cents" => 100})]
    apply!(conn, op("record_cash_payment", "source", "2026-11-02", %{"amount_cents" => 50}))
    assert report(conn, "2026-11-02")["cash"] == [cash("p", 0, 50, %{"received_cents" => 50})]
    assert report(conn, "2026-11-03")["cash"] == [cash("p", 50, 150, %{"received_cents" => 100})]
    before = snapshot()
    for date <- ~w(2026-11-03 2026-11-01 2026-11-02 2027-01-01 2026-11-03), do: report(conn, date)
    assert snapshot() == before
    assert_reconciles(conn, "2026-11-03")
  end

  test "clamped old credit effects and backdated applications reconcile across expiry", %{
    conn: conn
  } do
    seed_credit(conn, "source", 100)
    apply!(conn, opening("user", "p"))
    apply!(conn, start("2027-12-01"))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-01", %{"amount_cents" => 80}))
    assert report(conn, "2027-12-01")["credit"] == credit(0, 80, %{"expired_cents" => -80})
    apply!(conn, op("cancel_group", "user", "2026-11-02"))
    assert report(conn, "2027-12-01")["credit"] == credit(0, 0)
    assert_reconciles(conn, "2027-12-01")

    apply!(conn, opening("old-issue", "p"))
    apply!(conn, op("record_cash_payment", "old-issue", "2026-11-01", %{"amount_cents" => 100}))

    apply!(
      conn,
      op("cancel_group", "old-issue", "2026-11-01", %{"refund_method" => "hotel_credit"})
    )

    assert report(conn, "2027-12-01")["credit"] ==
             credit(0, 0, %{"issued_cents" => 110, "expired_cents" => 110})

    assert_reconciles(conn, "2027-12-01")
  end

  test "equivalent batches and sequential submissions produce identical reports", %{conn: conn} do
    payment = op("record_cash_payment", "source", "2026-11-03", %{"amount_cents" => 200})

    operations = [
      opening("source", "a"),
      opening("destination", "b"),
      payment,
      start(),
      transfer("source", "destination", 100),
      op("cancel_rooms", "destination", "2026-11-02", %{
        "room_ids" => ["r1"],
        "refund_method" => "hotel_credit"
      }),
      op("apply_hotel_credit", "source", "2026-11-03", %{"amount_cents" => 80}),
      target("reduce_cash_payment", payment, "2026-11-04", %{"amount_cents" => 25}),
      target("charge_back_payment", payment, "2026-11-04"),
      op("cancel_group", "source", "2026-11-05")
    ]

    dates = ~w(2026-11-01 2026-11-02 2026-11-03 2026-11-04 2026-11-05 2027-11-03)
    Repo.query!("SAVEPOINT batch_equivalence")
    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    reports = Enum.map(dates, &report(conn, &1))
    Repo.query!("ROLLBACK TO SAVEPOINT batch_equivalence")
    Repo.query!("RELEASE SAVEPOINT batch_equivalence")
    assert Enum.map(operations, &submit(conn, &1)) == results
    assert Enum.map(dates, &report(conn, &1)) == reports
    assert_reconciles(conn, "2027-11-03")
  end

  test "restoration splits partial shortfall absorption from immediately expired excess", %{
    conn: conn
  } do
    apply!(conn, start())
    apply!(conn, opening("source", "p"))
    apply!(conn, opening("user", "p"))
    first = op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 50})
    apply!(conn, first)
    apply!(conn, op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 50}))
    apply!(conn, op("cancel_group", "source", "2026-11-01", %{"refund_method" => "hotel_credit"}))
    apply!(conn, op("apply_hotel_credit", "user", "2026-11-02", %{"amount_cents" => 80}))
    apply!(conn, target("charge_back_payment", first, "2026-11-03"))
    assert report(conn, "2026-11-03")["credit"] == credit(110, 80, %{"revoked_cents" => 30})
    apply!(conn, op("cancel_group", "user", "2027-11-03"))

    assert report(conn, "2027-11-03")["credit"] ==
             credit(80, 0, %{"absorbed_cents" => 25, "expired_cents" => 55})

    assert_reconciles(conn, "2027-11-03")
  end

  test "corrections to settlements from before inception post signed classifications at their properties",
       %{conn: conn} do
    apply!(conn, opening("source", "a"))
    apply!(conn, opening("destination", "b"))
    payment = op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 100})
    apply!(conn, payment)
    apply!(conn, transfer("source", "destination", 100))
    apply!(conn, op("cancel_group", "destination", "2026-11-01"))
    apply!(conn, start("2026-11-02"))
    apply!(conn, target("charge_back_payment", payment, "2026-11-01"))

    assert report(conn, "2026-11-02") ==
             cash_report("2026-11-02", [
               cash("b", 0, 0, %{"refunded_cents" => -100, "charged_back_cents" => 100})
             ])

    assert_reconciles(conn, "2026-11-02")
  end

  test "company and property totals remain exact above the database integer range", %{conn: conn} do
    amount = 9_223_372_036_854_775_807

    for id <- ["first", "second"] do
      apply!(
        conn,
        opening(id, "p", %{
          "rate_plan" => "advance_purchase",
          "rooms" => [
            %{"room_id" => "r1", "nightly_rate_cents" => amount}
          ]
        })
      )

      apply!(conn, op("record_cash_payment", id, "2026-11-01", %{"amount_cents" => amount}))
    end

    apply!(conn, start())
    assert report(conn, "2026-11-01")["cash"] == [cash("p", amount * 2, amount * 2)]
    for id <- ["first", "second"], do: apply!(conn, op("cancel_group", id, "2026-11-02"))

    assert report(conn, "2026-11-02")["cash"] == [
             cash("p", amount * 2, 0, %{"retained_cents" => amount * 2})
           ]

    assert_reconciles(conn, "2026-11-02")
  end

  test "credit expiry beyond the last reportable date does not leak into earlier reports", %{
    conn: conn
  } do
    apply!(conn, start("9998-12-31"))

    apply!(
      conn,
      opening("source", "p", %{"arrival_on" => "9999-12-30", "departure_on" => "9999-12-31"})
    )

    apply!(conn, op("record_cash_payment", "source", "9998-12-31", %{"amount_cents" => 100}))
    apply!(conn, op("cancel_group", "source", "9998-12-31", %{"refund_method" => "hotel_credit"}))
    assert report(conn, "9999-12-31")["credit"] == credit(110, 110)
    assert_reconciles(conn, "9999-12-31")
  end

  test "partial credit rejection and audit failures roll back all finance effects", %{conn: conn} do
    apply!(conn, start())
    seed_credit(conn, "source", 100)
    apply!(conn, opening("user", "p"))
    before = snapshot()

    assert submit(conn, op("apply_hotel_credit", "user", "2026-11-02", %{"amount_cents" => 150}))[
             "code"
           ] == "insufficient_credit"

    assert snapshot() == before

    Repo.query!("""
    CREATE TRIGGER fail_finance_audit BEFORE INSERT ON operations WHEN NEW.operation_id = 'fail-finance'
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)

    failed =
      op("record_cash_payment", "user", "2026-11-02", %{
        "amount_cents" => 100,
        "operation_id" => "fail-finance"
      })

    assert_error_sent 500, fn -> batch(conn, [failed]) end
    assert snapshot() == before
    Repo.query!("DROP TRIGGER fail_finance_audit")
    apply!(conn, failed)
    assert report(conn, "2026-11-02")["cash"] == [cash("p", 0, 100, %{"received_cents" => 100})]
  end

  test "room cancellation issues one rounded bonus and apportioned revocation telescopes", %{
    conn: conn
  } do
    apply!(conn, start())

    apply!(
      conn,
      opening("source", "p", %{
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 25},
          %{"room_id" => "r2", "nightly_rate_cents" => 25}
        ]
      })
    )

    first = op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 5})
    second = op("record_cash_payment", "source", "2026-11-01", %{"amount_cents" => 5})
    apply!(conn, first)
    apply!(conn, second)

    apply!(
      conn,
      op("cancel_rooms", "source", "2026-11-02", %{
        "room_ids" => ["r2", "r1"],
        "refund_method" => "hotel_credit"
      })
    )

    assert report(conn, "2026-11-02")["credit"] == credit(0, 11, %{"issued_cents" => 11})
    apply!(conn, target("charge_back_payment", first, "2026-11-03"))
    assert report(conn, "2026-11-03")["credit"] == credit(11, 5, %{"revoked_cents" => 6})
    apply!(conn, target("charge_back_payment", second, "2026-11-04"))
    assert report(conn, "2026-11-04")["credit"] == credit(5, 0, %{"revoked_cents" => 5})
    assert report(conn, "2027-11-03")["credit"] == credit(0, 0)
    assert_reconciles(conn, "2027-11-03")
  end

  defp opening(id, property, overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{
          "group_id" => id,
          "property_id" => property,
          "arrival_on" => "2028-12-01",
          "departure_on" => "2028-12-02",
          "rooms" => for(i <- 1..5, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
        },
        overrides
      )
    )
  end

  defp op(type, group, date, overrides \\ %{}),
    do: operation(type, Map.merge(%{"group_id" => group, "occurred_on" => date}, overrides))

  defp start(date \\ "2026-11-01"),
    do: %{
      "operation_id" => unique_operation_id("start"),
      "type" => "start_finance_reporting",
      "starts_on" => date,
      "occurred_on" => "2026-11-01"
    }

  defp transfer(source, destination, amount),
    do:
      op("transfer_deposit", source, "2026-11-01", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp target(type, payment, date, overrides \\ %{}),
    do:
      op(
        type,
        "ignored",
        date,
        Map.put(overrides, "payment_operation_id", payment["operation_id"])
      )

  defp seed_credit(conn, id, amount) do
    apply!(conn, opening(id, "credit-source"))
    payment = op("record_cash_payment", id, "2026-11-01", %{"amount_cents" => amount})
    apply!(conn, payment)
    apply!(conn, op("cancel_group", id, "2026-11-01", %{"refund_method" => "hotel_credit"}))
    payment
  end

  defp report(conn, date),
    do:
      get(conn, "/api/v1/finance/daily-report", date: date)
      |> json_response(200)
      |> Map.fetch!("data")

  defp unavailable(conn, date),
    do:
      get(conn, "/api/v1/finance/daily-report", date: date)
      |> json_response(404)
      |> get_in(["error", "code"])

  defp submit(conn, operation), do: hd(batch(conn, [operation]))

  defp apply!(conn, operation) do
    result = submit(conn, operation)
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp batch(conn, operations),
    do:
      post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp cash(property, opening, closing, movements \\ %{}),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "closing_held_cents" => closing,
      "movements" =>
        Map.merge(
          Map.new(
            ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
            &{&1, 0}
          ),
          movements
        )
    }

  defp credit(opening, closing, movements \\ %{}),
    do: %{
      "opening_liability_cents" => opening,
      "closing_liability_cents" => closing,
      "movements" =>
        Map.merge(
          Map.new(
            ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
            &{&1, 0}
          ),
          movements
        )
    }

  defp cash_report(date, cash, credit \\ credit(0, 0)),
    do: %{
      "date" => date,
      "status" => "open",
      "cash" => cash,
      "credit" => credit,
      "late_adjustments" => %{"cash" => [], "credit" => credit(0, 0)["movements"]}
    }

  defp empty_report(date), do: cash_report(date, [])

  defp snapshot do
    {Repo.all(from e in Entry, order_by: e.id), Repo.all(Inception), Repo.all(Group),
     Repo.all(CreditLot), Reservations.ledger(~D[2026-11-01])}
  end

  defp assert_reconciles(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

    for row <- report["cash"] do
      m = row["movements"]

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 Enum.sum(
                   for key <-
                         ~w(transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                       do: m[key]
                 )
    end

    c = report["credit"]

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + c["movements"]["issued_cents"] -
               Enum.sum(
                 for key <- ~w(expired_cents consumed_cents revoked_cents absorbed_cents),
                     do: c["movements"][key]
               )

    assert {:ok, _} = FinanceReporting.daily_report(Date.from_iso8601!(date))
  end
end
