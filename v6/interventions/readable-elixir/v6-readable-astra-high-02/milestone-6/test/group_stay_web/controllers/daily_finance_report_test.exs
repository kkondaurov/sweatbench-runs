defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.FinanceReporting.{Inception, Movement}
  alias GroupStay.Reservations.{CreditLot, Group, OperationRecord, RoomAllocation}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents
                  retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "date validation, availability, exact start result and durable start rejections", %{
    conn: conn
  } do
    for params <- [
          %{},
          %{"date" => "2026-02-30"},
          %{"date" => "bad"},
          %{"date" => ["2026-11-01"]}
        ] do
      assert conn |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert conn |> get("/api/v1/finance/daily-report?date=2026-11-01") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    for date <- [nil, "", "2026-02-30", 123, %{}, []] do
      assert [%{"code" => "invalid_reporting_date"}] = batch(conn, [start(date)])
    end

    assert [%{"code" => "invalid_reporting_date"}] =
             batch(conn, [Map.delete(start(), "starts_on")])

    start = start() |> Map.put("expected_revision", "ignored") |> Map.delete("group_id")
    assert [result] = batch(conn, [start])

    assert result == %{
             "operation_id" => start["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-11-01"
           }

    assert batch(conn, [start]) == [result]

    assert conn |> get("/api/v1/operations/#{start["operation_id"]}") |> json_response(200) == %{
             "data" => result
           }

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(start, "starts_on", "2026-11-02")])

    later = start("2026-12-01")
    assert [rejected = %{"code" => "reporting_already_started"}] = batch(conn, [later])
    assert batch(conn, [later]) == [rejected]

    assert conn |> get("/api/v1/finance/daily-report?date=2026-10-31") |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert report(conn, "2026-11-01") == %{
             "date" => "2026-11-01",
             "status" => "open",
             "cash" => [],
             "credit" => credit_row(0, %{}, 0)
           }
  end

  test "inception uses commit position, and late submissions revise the correct open day", %{
    conn: conn
  } do
    payment = pay("source", "before", 100, "2027-01-01")
    after_start = pay("source", "after", 50, "2026-10-01")

    batch(conn, [
      booking("source", "z-property"),
      booking("empty", "empty"),
      payment,
      start(),
      after_start,
      pay("source", "next", 20, "2026-11-02")
    ])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row("z-property", 100, %{"received_cents" => 50}, 150)
           ]

    assert report(conn, "2026-11-02")["cash"] == [
             cash_row("z-property", 150, %{"received_cents" => 20}, 170)
           ]

    batch(conn, [pay("source", "late", 30, "2026-11-01")])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row("z-property", 100, %{"received_cents" => 80}, 180)
           ]

    assert report(conn, "2026-11-02")["cash"] == [
             cash_row("z-property", 180, %{"received_cents" => 20}, 200)
           ]

    before = snapshot()
    batch(conn, [payment, after_start])
    assert snapshot() == before
    assert_reconciled(conn, "2027-01-01")
  end

  test "cash corrections follow all held and settled properties with signed reclassifications", %{
    conn: conn
  } do
    payment = pay("source", "pay", 500)

    batch(conn, [
      start(),
      booking("source", "z-source", 5),
      booking("refund", "a-refund"),
      booking("convert", "b-convert"),
      booking("retain", "c-retain", 1, "advance_purchase"),
      payment,
      transfer("source", "refund", 100),
      transfer("source", "convert", 100),
      transfer("source", "retain", 100),
      cancel("refund"),
      cancel("convert", %{"refund_method" => "hotel_credit"}),
      cancel("retain"),
      operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 50})
    ])

    day = report(conn, "2026-11-01")

    assert day["cash"] == [
             cash_row(
               "a-refund",
               0,
               %{"transferred_in_cents" => 100, "refunded_cents" => 100},
               0
             ),
             cash_row(
               "b-convert",
               0,
               %{"transferred_in_cents" => 100, "converted_to_credit_cents" => 100},
               0
             ),
             cash_row(
               "c-retain",
               0,
               %{"transferred_in_cents" => 100, "retained_cents" => 100},
               0
             ),
             cash_row(
               "z-source",
               0,
               %{"received_cents" => 500, "transferred_out_cents" => 300, "reduced_cents" => 50},
               150
             )
           ]

    assert day["credit"] == credit_row(0, %{"issued_cents" => 110}, 110)
    assert_reconciled(conn, "2026-11-01")

    charge =
      operation("charge_back_payment", %{
        "payment_operation_id" => "pay",
        "occurred_on" => "2026-11-02"
      })

    [charged] = batch(conn, [charge])
    assert charged["charged_back_cents"] == 450

    assert report(conn, "2026-11-02")["cash"] == [
             cash_row("a-refund", 0, %{"refunded_cents" => -100, "charged_back_cents" => 100}, 0),
             cash_row(
               "b-convert",
               0,
               %{"converted_to_credit_cents" => -100, "charged_back_cents" => 100},
               0
             ),
             cash_row("c-retain", 0, %{"retained_cents" => -100, "charged_back_cents" => 100}, 0),
             cash_row("z-source", 150, %{"charged_back_cents" => 150}, 0)
           ]

    assert report(conn, "2026-11-02")["credit"] == credit_row(110, %{"revoked_cents" => 110}, 0)
    assert report(conn, "2027-11-02")["credit"] == credit_row(0, %{}, 0)
    assert report(conn, "2026-11-03")["cash"] == []
    assert report(conn, "2026-11-01") == day
    before = snapshot()
    assert batch(conn, [charge]) == [charged]
    batch(conn, [payment])
    assert snapshot() == before
    assert_reconciled(conn, "2027-11-02")
  end

  test "mixed and same-property transfers report only cash and retain gross transfer columns", %{
    conn: conn
  } do
    issue_credit(conn)

    batch(conn, [
      booking("source", "same"),
      booking("destination", "same"),
      pay("source", "pay", 100),
      start(),
      apply_credit("source", 80),
      transfer("source", "destination", 120)
    ])

    assert report(conn, "2026-11-01")["cash"] == [
             cash_row(
               "same",
               100,
               %{"transferred_in_cents" => 40, "transferred_out_cents" => 40},
               100
             )
           ]

    assert report(conn, "2026-11-01")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 30}, 80)
    assert_reconciled(conn, "2027-11-02")
  end

  test "expiry happens without operations, applied credit pauses it, expired restoration leaves liability",
       %{conn: conn} do
    batch(conn, [start()])
    issue_credit(conn)
    batch(conn, [booking("target", "target"), apply_credit("target", 80)])
    assert report(conn, "2027-11-01")["credit"] == credit_row(110, %{}, 110)
    expiry = report(conn, "2027-11-02")
    assert expiry["credit"] == credit_row(110, %{"expired_cents" => 30}, 80)
    before = snapshot()

    for date <- ["2028-01-01", "2026-11-01", "2027-11-02", "2027-11-01", "2027-11-02"],
        do: report(conn, date)

    assert snapshot() == before
    batch(conn, [cancel("target", %{"occurred_on" => "2027-11-03"})])
    assert report(conn, "2027-11-03")["credit"] == credit_row(80, %{"expired_cents" => 80}, 0)
    assert report(conn, "2027-11-02") == expiry
    assert_reconciled(conn, "2027-11-03")
  end

  test "refundable restoration before expiry reschedules the original lot without issuing again",
       %{conn: conn} do
    issue_credit(conn)

    batch(conn, [
      booking("target", "target"),
      apply_credit("target", 80),
      start(),
      cancel("target", %{"occurred_on" => "2026-11-02", "refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2026-11-02")["credit"] == credit_row(110, %{}, 110)
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    assert_reconciled(conn, "2027-11-02")
  end

  test "shortfall restoration is absorbed before expiry and nonrefundable credit is consumed", %{
    conn: conn
  } do
    batch(conn, [start()])
    issue_credit(conn)

    batch(conn, [
      booking("refundable", "p"),
      booking("retained", "p", 1, "advance_purchase"),
      apply_credit("refundable", 50),
      apply_credit("retained", 30),
      operation("charge_back_payment", %{
        "payment_operation_id" => "issuer-pay",
        "occurred_on" => "2026-11-02"
      })
    ])

    assert report(conn, "2026-11-02")["credit"] == credit_row(110, %{"revoked_cents" => 30}, 80)
    assert Reservations.ledger(~D[2026-11-02]).credit_shortfall_cents == 80
    batch(conn, [cancel("retained", %{"occurred_on" => "2026-11-03"})])
    assert report(conn, "2026-11-03")["credit"] == credit_row(80, %{"consumed_cents" => 30}, 50)
    assert report(conn, "2027-11-02")["credit"] == credit_row(50, %{}, 50)
    batch(conn, [cancel("refundable", %{"occurred_on" => "2027-11-03"})])
    assert report(conn, "2027-11-03")["credit"] == credit_row(50, %{"absorbed_cents" => 50}, 0)
    assert_reconciled(conn, "2027-11-03")
  end

  test "inception excludes expired availability but includes applied expired lots", %{conn: conn} do
    issue_credit(conn)
    batch(conn, [booking("target", "p"), apply_credit("target", 80), start("2027-11-02")])
    assert report(conn, "2027-11-02")["credit"] == credit_row(80, %{}, 80)
    batch(conn, [cancel("target", %{"occurred_on" => "2027-11-03"})])
    assert report(conn, "2027-11-03")["credit"] == credit_row(80, %{"expired_cents" => 80}, 0)
    assert_reconciled(conn, "2027-11-03")
  end

  test "backdated use and issuance before inception reconcile even when their lots have expired",
       %{conn: conn} do
    issue_credit(conn)
    batch(conn, [booking("target", "p"), start("2027-11-02"), apply_credit("target", 80)])
    assert report(conn, "2027-11-02")["credit"] == credit_row(0, %{"expired_cents" => -80}, 80)
    batch(conn, [cancel("target")])
    assert report(conn, "2027-11-02")["credit"] == credit_row(0, %{}, 0)

    batch(conn, [
      booking("new", "p"),
      pay("new", "new-pay", 100),
      cancel("new", %{"refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2027-11-02")["credit"] ==
             credit_row(0, %{"issued_cents" => 110, "expired_cents" => 110}, 0)

    assert_reconciled(conn, "2027-11-02")
  end

  test "revoking already expired availability does not remove liability a second time", %{
    conn: conn
  } do
    batch(conn, [start()])
    issue_credit(conn)
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)

    batch(conn, [
      operation("charge_back_payment", %{
        "payment_operation_id" => "issuer-pay",
        "occurred_on" => "2027-11-03"
      })
    ])

    assert report(conn, "2027-11-03")["credit"] == credit_row(0, %{}, 0)
    assert_reconciled(conn, "2027-11-03")
  end

  test "handled rejections and durable retries contribute no journal entries", %{conn: conn} do
    batch(conn, [start(), booking("source", "p"), booking("destination", "q")])
    rejected = pay("source", "too-large", 1000)
    payment = pay("source", "pay", 100)

    [paid, rejected_result, _, _] =
      batch(conn, [
        payment,
        rejected,
        transfer("source", "destination", 50),
        pay("source", "last", 20)
      ])

    before = snapshot()
    assert batch(conn, [payment, rejected]) == [paid, rejected_result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(payment, "amount_cents", 50)])

    assert snapshot() == before
    count = Repo.aggregate(Movement, :count)

    for attempted <- [
          cancel("source", %{"refund_method" => "invalid"}),
          transfer("source", "destination", 1000),
          apply_credit("source", 1),
          pay("source", "stale", 20) |> Map.put("expected_revision", 1)
        ] do
      assert [%{"status" => "rejected"}] = batch(conn, [attempted])
    end

    assert Repo.aggregate(Movement, :count) == count
    assert_reconciled(conn, "2026-11-01")
  end

  test "batch and sequential processing produce identical reports", %{conn: conn} do
    operations = [
      booking("issuer", "p"),
      pay("issuer", "pay", 100),
      start(),
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      booking("target", "q"),
      apply_credit("target", 80),
      cancel("target", %{"occurred_on" => "2027-11-03"})
    ]

    dates = ["2026-11-01", "2027-11-01", "2027-11-02", "2027-11-03"]

    {:error, expected} =
      Repo.transaction(fn ->
        batch(conn, operations)
        Repo.rollback(Enum.map(dates, &report(conn, &1)))
      end)

    Enum.each(operations, &batch(conn, [&1]))
    assert Enum.map(dates, &report(conn, &1)) == expected
  end

  test "selected rooms round once and partial clawback absorbs only its entitlement", %{
    conn: conn
  } do
    source =
      booking("source", "p")
      |> Map.put(
        "rooms",
        for index <- 1..3 do
          %{"room_id" => "r#{index}", "nightly_rate_cents" => 25}
        end
      )

    results =
      batch(conn, [
        start(),
        source,
        pay("source", "early", 5),
        pay("source", "late", 5),
        operation("cancel_rooms", %{
          "group_id" => "source",
          "room_ids" => ["r2", "r1"],
          "refund_method" => "hotel_credit"
        }),
        booking("target", "q"),
        apply_credit("target", 8)
      ])

    assert Enum.at(results, 4)["credit_issued_cents"] == 11
    assert report(conn, "2026-11-01")["credit"] == credit_row(0, %{"issued_cents" => 11}, 11)

    batch(conn, [
      operation("charge_back_payment", %{
        "payment_operation_id" => "early",
        "occurred_on" => "2026-11-02"
      })
    ])

    assert report(conn, "2026-11-02")["credit"] == credit_row(11, %{"revoked_cents" => 3}, 8)
    batch(conn, [cancel("target", %{"occurred_on" => "2026-11-03"})])
    assert report(conn, "2026-11-03")["credit"] == credit_row(8, %{"absorbed_cents" => 3}, 5)
    assert_reconciled(conn, "2026-11-03")

    # A later lot has its own bonus and expires on its own date.
    batch(conn, [
      pay("source", "remaining", 5, "2026-11-02"),
      cancel("source", %{"occurred_on" => "2026-11-02", "refund_method" => "hotel_credit"})
    ])

    assert report(conn, "2027-11-02")["credit"] == credit_row(11, %{"expired_cents" => 5}, 6)
    assert report(conn, "2027-11-03")["credit"] == credit_row(6, %{"expired_cents" => 6}, 0)
    assert_reconciled(conn, "2027-11-03")
  end

  test "a late credit application revises expiry on a previously read open report", %{conn: conn} do
    batch(conn, [start()])
    issue_credit(conn)
    batch(conn, [booking("target", "q")])
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 110}, 0)
    batch(conn, [apply_credit("target", 80) |> Map.put("occurred_on", "2027-11-01")])
    assert report(conn, "2027-11-02")["credit"] == credit_row(110, %{"expired_cents" => 30}, 80)
    assert_reconciled(conn, "2027-11-02")
  end

  test "a chargeback of pre-inception settlements reports their reversal on the clamped date", %{
    conn: conn
  } do
    issue_credit(conn)

    batch(conn, [
      start("2026-12-01"),
      operation("charge_back_payment", %{"payment_operation_id" => "issuer-pay"})
    ])

    assert report(conn, "2026-12-01")["cash"] == [
             cash_row(
               "issuer",
               0,
               %{"converted_to_credit_cents" => -100, "charged_back_cents" => 100},
               0
             )
           ]

    assert report(conn, "2026-12-01")["credit"] == credit_row(110, %{"revoked_cents" => 110}, 0)
    assert_reconciled(conn, "2026-12-01")
  end

  defp start(date \\ "2026-11-01"),
    do: operation("start_finance_reporting", %{"starts_on" => date})

  defp booking(id, property, rooms \\ 3, rate_plan \\ "flexible") do
    open_group(%{
      "group_id" => id,
      "property_id" => property,
      "arrival_on" => "2029-12-10",
      "departure_on" => "2029-12-11",
      "rate_plan" => rate_plan,
      "rooms" =>
        for(
          index <- 1..rooms,
          do: %{
            "room_id" => "r#{index}",
            "nightly_rate_cents" => if(rate_plan == "flexible", do: 500, else: 100)
          }
        )
    })
  end

  defp pay(group, id, amount, date \\ "2026-11-01"),
    do:
      operation(
        "record_cash_payment",
        %{
          "group_id" => group,
          "operation_id" => id,
          "amount_cents" => amount,
          "occurred_on" => date
        }
      )

  defp transfer(source, destination, amount),
    do:
      operation(
        "transfer_deposit",
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        }
      )

  defp cancel(group, attrs \\ %{}),
    do: operation("cancel_group", Map.put(attrs, "group_id", group))

  defp apply_credit(group, amount),
    do: operation("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp issue_credit(conn) do
    results =
      batch(conn, [
        booking("issuer", "issuer"),
        pay("issuer", "issuer-pay", 100),
        cancel("issuer", %{"refund_method" => "hotel_credit"})
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  defp batch(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp report(conn, date),
    do:
      conn
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

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

  defp assert_reconciled(conn, date) do
    report = report(conn, date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))
  end

  defp snapshot do
    Map.new(
      [Inception, Movement, Group, CreditLot, RoomAllocation, OperationRecord],
      &{&1, Repo.all(&1)}
    )
  end
end
