defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{CreditLot, FinanceReporting, Repo}

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  test "report dates are required and reporting must have started" do
    for query <- ["", "?date=", "?date=2026-02-30", "?date=garbage", "?date[]=2026-11-26"] do
      assert build_conn()
             |> get("/api/v1/finance/daily-report" <> query)
             |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert unavailable("2026-11-26") == %{"error" => %{"code" => "report_not_available"}}
    batch([start()])
    assert unavailable("2026-11-25") == %{"error" => %{"code" => "report_not_available"}}

    for date <- ["2026-11-26", "2028-01-01"] do
      assert report(date) == %{
               "date" => date,
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(0, %{}, 0)
             }
    end
  end

  test "start validates its date, ignores group guards, and durably replays its exact result" do
    for value <- [nil, "", "2026-02-30", "2026-11-26T00:00:00Z", 1, true, [], %{}] do
      assert [%{"code" => "invalid_reporting_date"}] = batch([start(value)])
    end

    missing = Map.delete(start(), "starts_on")
    assert [rejected] = batch([missing])
    assert rejected["code"] == "invalid_reporting_date"
    op = Map.merge(start(), %{"group_id" => "missing", "expected_revision" => 999})
    [applied] = batch([op])

    assert applied == %{
             "operation_id" => op["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-11-26"
           }

    assert batch([op, missing]) == [applied, rejected]
    assert [%{"code" => "reporting_already_started"}] = batch([start()])

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(op, "starts_on", "2026-11-27")])

    assert read("/api/v1/operations/" <> op["operation_id"]) == applied
    assert [%{starts_on: ~D[2026-11-26]} = replay] = GroupStay.submit_operations([op])
    assert GroupStay.submit_operations([op]) == [replay]
  end

  test "the start captures committed state regardless of dates and splits a batch at its position" do
    batch([
      opening("old", "z-hotel"),
      cash("before", "old", 500, "2028-01-01"),
      opening("empty", "empty-hotel"),
      start(),
      cash("after", "old", 200, "2026-01-01"),
      cash("tomorrow", "old", 100, "2026-11-27")
    ])

    assert report()["cash"] == [cash_entry("z-hotel", 500, %{"received_cents" => 200}, 700)]

    assert report("2026-11-27")["cash"] == [
             cash_entry("z-hotel", 700, %{"received_cents" => 100}, 800)
           ]

    assert report("2028-01-01")["cash"] == [cash_entry("z-hotel", 800, %{}, 800)]
    assert_reconciles("2028-01-01")
  end

  test "opening liability includes available and paused credit but excludes already expired balances" do
    batch([
      opening("issuer", "a"),
      cash("pay", "issuer", 100),
      cancel("issuer", "2026-11-26", "hotel_credit"),
      opening("holder", "b"),
      apply_credit("holder", 60),
      start("2027-11-27")
    ])

    assert report("2027-11-27")["credit"] == credit_entry(60, %{}, 60)
    assert report("2028-01-01")["cash"] == []
    batch([cancel("holder", "2027-11-28")])
    assert report("2027-11-28")["credit"] == credit_entry(60, %{"expired_cents" => 60}, 0)
    assert_reconciles("2027-11-28")
  end

  test "cash corrections follow transferred holdings and settlements with signed reclassifications" do
    batch([
      opening("source", "z-hotel"),
      opening("refund", "a-hotel"),
      opening("retain", "b-hotel", "advance_purchase"),
      start(),
      cash("pay", "source", 1000),
      transfer("source", "refund", 400),
      transfer("source", "retain", 300),
      correction("reduce_cash_payment", "pay", "2026-11-26", 100),
      cancel("refund", "2026-11-26"),
      cancel("retain", "2026-11-26")
    ])

    day_one = report()

    assert day_one["cash"] == [
             cash_entry(
               "a-hotel",
               0,
               %{"transferred_in_cents" => 400, "refunded_cents" => 400},
               0
             ),
             cash_entry(
               "b-hotel",
               0,
               %{"transferred_in_cents" => 300, "reduced_cents" => 100, "retained_cents" => 200},
               0
             ),
             cash_entry(
               "z-hotel",
               0,
               %{"received_cents" => 1000, "transferred_out_cents" => 700},
               300
             )
           ]

    batch([correction("charge_back_payment", "pay", "2026-11-27")])

    assert report("2026-11-27")["cash"] == [
             cash_entry(
               "a-hotel",
               0,
               %{"refunded_cents" => -400, "charged_back_cents" => 400},
               0
             ),
             cash_entry(
               "b-hotel",
               0,
               %{"retained_cents" => -200, "charged_back_cents" => 200},
               0
             ),
             cash_entry("z-hotel", 300, %{"charged_back_cents" => 300}, 0)
           ]

    assert report() == day_one
    assert report("2026-11-28")["cash"] == []
    assert_reconciles("2026-11-27")
  end

  test "mixed transfers report only cash and same-property transfers retain both columns" do
    batch([
      opening("issuer", "issuer"),
      cash("issue-pay", "issuer", 100),
      cancel("issuer", "2026-11-26", "hotel_credit"),
      opening("source", "same"),
      opening("destination", "same"),
      cash("pay", "source", 100),
      apply_credit("source", 80),
      start(),
      transfer("source", "destination", 130)
    ])

    assert report()["cash"] == [
             cash_entry(
               "same",
               100,
               %{"transferred_in_cents" => 50, "transferred_out_cents" => 50},
               100
             )
           ]

    assert report()["credit"] == credit_entry(110, %{}, 110)
    assert_reconciles("2026-11-26")
  end

  for {restore_date, expired, closing} <- [
        {"2027-11-26", 0, 55},
        {"2027-11-27", 30, 25}
      ] do
    test "credit issuance, revocation, absorption and consumption reconcile on #{restore_date}" do
      batch([
        start(),
        opening("issuer", "a"),
        cash("first", "issuer", 50),
        cash("second", "issuer", 50),
        cancel("issuer", "2026-11-26", "hotel_credit"),
        opening("restore", "b"),
        opening("consume", "c", "advance_purchase"),
        apply_credit("restore", 80, "2026-11-27"),
        apply_credit("consume", 25, "2026-11-27"),
        correction("charge_back_payment", "first", "2026-11-28")
      ])

      assert report()["credit"] == credit_entry(0, %{"issued_cents" => 110}, 110)
      assert report("2026-11-27")["credit"] == credit_entry(110, %{}, 110)
      assert report("2026-11-28")["credit"] == credit_entry(110, %{"revoked_cents" => 5}, 105)

      assert report("2026-11-28")["cash"] == [
               cash_entry(
                 "a",
                 0,
                 %{"converted_to_credit_cents" => -50, "charged_back_cents" => 50},
                 0
               )
             ]

      batch([cancel("restore", unquote(restore_date))])

      assert report(unquote(restore_date))["credit"] ==
               credit_entry(
                 105,
                 %{"absorbed_cents" => 50, "expired_cents" => unquote(expired)},
                 unquote(closing)
               )

      batch([cancel("consume", "2027-11-28")])
      assert report("2027-11-27")["credit"]["movements"]["expired_cents"] == 30
      assert report("2027-11-28")["credit"] == credit_entry(25, %{"consumed_cents" => 25}, 0)
      assert_reconciles("2027-11-28")
    end
  end

  test "expiry is scheduled for unused credit, pauses while applied, and resumes on restoration" do
    batch([
      opening("issuer", "a"),
      cash("pay", "issuer", 100),
      cancel("issuer", "2026-11-26", "hotel_credit"),
      opening("holder", "b"),
      apply_credit("holder", 40),
      start()
    ])

    assert report()["credit"] == credit_entry(110, %{}, 110)
    assert report("2027-11-26")["credit"] == credit_entry(110, %{}, 110)
    assert report("2027-11-27")["credit"] == credit_entry(110, %{"expired_cents" => 70}, 40)

    # A late submission updates the earlier open report and the scheduled expiry, regardless
    # of whether either report has already been read.
    batch([cancel("holder", "2027-11-26")])
    assert report("2027-11-26")["credit"] == credit_entry(110, %{}, 110)
    assert report("2027-11-27")["credit"] == credit_entry(110, %{"expired_cents" => 110}, 0)
    before = snapshot()
    expected = Enum.map(~w(2028-01-01 2026-11-26 2027-11-27 2027-11-26), &report/1)
    assert expected == Enum.map(~w(2028-01-01 2026-11-26 2027-11-27 2027-11-26), &report/1)
    assert snapshot() == before
    assert_reconciles("2027-11-27")
  end

  test "chargeback after expiry does not retroactively reduce expiry or revoke liability twice" do
    batch([
      start(),
      opening("issuer", "a"),
      cash("pay", "issuer", 100),
      cancel("issuer", "2026-11-26", "hotel_credit")
    ])

    expired = report("2027-11-27")
    batch([correction("charge_back_payment", "pay", "2027-11-28")])
    assert report("2027-11-27") == expired
    assert expired["credit"] == credit_entry(110, %{"expired_cents" => 110}, 0)
    assert report("2027-11-28")["credit"] == credit_entry(0, %{}, 0)
    assert_reconciles("2027-11-28")
  end

  test "posting clamps all effects to inception, including already expired issued credit" do
    batch([
      opening("issuer", "a"),
      cash("pay", "issuer", 100),
      start("2028-01-01"),
      cancel("issuer", "2026-11-26", "hotel_credit")
    ])

    assert report("2028-01-01")["cash"] == [
             cash_entry("a", 100, %{"converted_to_credit_cents" => 100}, 0)
           ]

    assert report("2028-01-01")["credit"] ==
             credit_entry(0, %{"issued_cents" => 110, "expired_cents" => 110}, 0)

    assert_reconciles("2028-01-01")
  end

  test "retries and remembered rejections never duplicate movements and batches continue" do
    batch([opening("source", "a"), start()])
    payment = cash("pay", "source", 100)
    rejected = cash("too-much", "source", 2000)
    reduction = correction("reduce_cash_payment", "pay", "2026-11-27", 25)
    results = batch([payment, rejected, reduction])
    assert Enum.map(results, & &1["status"]) == ~w(applied rejected applied)
    before = snapshot()
    assert batch([payment, rejected, reduction]) == results
    assert snapshot() == before
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(payment, "amount_cents", 101)])
    assert report()["cash"] == [cash_entry("a", 0, %{"received_cents" => 100}, 100)]
    assert report("2026-11-27")["cash"] == [cash_entry("a", 100, %{"reduced_cents" => 25}, 75)]

    # Durable replay does not consult reporting or domain state.
    Repo.query!("ALTER TABLE finance_reporting RENAME TO unavailable_reporting")
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert batch([payment, rejected, reduction]) == results
  end

  test "audit failures roll back inception and finance postings together with domain changes" do
    batch([opening("source", "a")])

    for op <- [start(), cash("pay", "source", 100)] do
      Repo.query!("""
      CREATE TRIGGER fail_audit BEFORE INSERT ON operations
      BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
      """)

      before = snapshot()
      assert_error_sent 500, fn -> batch([op]) end
      assert snapshot() == before
      Repo.query!("DROP TRIGGER fail_audit")
      assert [%{"status" => "applied"}] = batch([op])
    end

    assert_reconciles("2026-11-26")
  end

  test "a posting failure aborts the operation and batch, preserving earlier commits" do
    batch([opening("source", "a"), start()])

    Repo.query!("""
    CREATE TRIGGER fail_posting BEFORE INSERT ON finance_movements
    WHEN NEW.amount_cents = 200
    BEGIN SELECT RAISE(ABORT, 'injected posting failure'); END
    """)

    failed = cash("failed", "source", 200)

    assert_error_sent 500, fn ->
      batch([cash("first", "source", 100), failed, cash("never", "source", 300)])
    end

    assert GroupStay.get_operation("failed") == nil
    assert GroupStay.get_operation("never") == nil
    assert report()["cash"] == [cash_entry("a", 0, %{"received_cents" => 100}, 100)]
    assert_reconciles("2026-11-26")
    Repo.query!("DROP TRIGGER fail_posting")
    batch([failed])
    assert report()["cash"] == [cash_entry("a", 0, %{"received_cents" => 300}, 300)]
  end

  test "partial-room conversion rounds once and transferred entitlements reverse at the destination" do
    destination =
      opening("destination", "a")
      |> Map.put("rooms", [
        %{"room_id" => "first", "nightly_rate_cents" => 25},
        %{"room_id" => "second", "nightly_rate_cents" => 25},
        %{"room_id" => "last", "nightly_rate_cents" => 25}
      ])

    batch([
      start(),
      opening("source", "z"),
      destination,
      cash("first-pay", "source", 5),
      cash("second-pay", "source", 5),
      transfer("source", "destination", 10),
      operation("cancel_rooms", %{
        "group_id" => "destination",
        "room_ids" => ["second", "first"],
        "refund_method" => "hotel_credit"
      })
    ])

    assert report()["credit"] == credit_entry(0, %{"issued_cents" => 11}, 11)

    assert report()["cash"] == [
             cash_entry(
               "a",
               0,
               %{"transferred_in_cents" => 10, "converted_to_credit_cents" => 10},
               0
             ),
             cash_entry("z", 0, %{"received_cents" => 10, "transferred_out_cents" => 10}, 0)
           ]

    batch([
      correction("charge_back_payment", "first-pay", "2026-11-27"),
      cash("last-pay", "destination", 5, "2026-11-27"),
      cancel("destination", "2026-11-27")
    ])

    assert report("2026-11-27")["cash"] == [
             cash_entry(
               "a",
               0,
               %{
                 "received_cents" => 5,
                 "refunded_cents" => 5,
                 "converted_to_credit_cents" => -5,
                 "charged_back_cents" => 5
               },
               0
             )
           ]

    assert report("2026-11-27")["credit"] == credit_entry(11, %{"revoked_cents" => 5}, 6)
    assert_reconciles("2026-11-27")
  end

  test "credit expiring on the last supported calendar date remains a liability through that date" do
    issuer =
      opening("issuer", "a")
      |> Map.merge(%{
        "arrival_on" => "9999-12-10",
        "departure_on" => "9999-12-11"
      })

    assert results =
             batch([
               issuer,
               cash("pay", "issuer", 100),
               start("9998-12-31"),
               cancel("issuer", "9998-12-31", "hotel_credit")
             ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert report("9998-12-31")["credit"] == credit_entry(0, %{"issued_cents" => 110}, 110)
    assert report("9999-12-31")["credit"] == credit_entry(110, %{}, 110)
    assert_reconciles("9999-12-31")
  end

  test "batches and sequential submissions produce equivalent reports across posting dates" do
    operations = [
      opening("issuer", "z"),
      cash("first", "issuer", 100, "2028-01-01"),
      start(),
      cash("second", "issuer", 100, "2026-11-27"),
      cancel("issuer", "2026-11-26", "hotel_credit"),
      opening("holder", "a"),
      apply_credit("holder", 100, "2026-11-28"),
      correction("charge_back_payment", "second", "2026-11-27"),
      cancel("holder", "2027-11-27")
    ]

    dates = ~w(2026-11-26 2026-11-27 2026-11-28 2027-11-26 2027-11-27 2028-01-01)
    Repo.query!("SAVEPOINT before_batch")
    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    reports = Enum.map(dates, &report/1)
    assert_reconciles("2028-01-01")
    Repo.query!("ROLLBACK TO SAVEPOINT before_batch")
    Repo.query!("RELEASE SAVEPOINT before_batch")
    assert Enum.flat_map(operations, &batch([&1])) == results
    assert Enum.map(dates, &report/1) == reports
    assert_reconciles("2028-01-01")
  end

  defp start(date \\ "2026-11-26"),
    do: %{
      "operation_id" => unique_operation_id("start"),
      "type" => "start_finance_reporting",
      "starts_on" => date
    }

  defp opening(id, property, plan \\ "flexible") do
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
  end

  defp cash(id, group, amount, date \\ "2026-11-26"),
    do:
      operation("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => date
      })

  defp cancel(group, date, method \\ "cash"),
    do:
      operation("cancel_group", %{
        "group_id" => group,
        "occurred_on" => date,
        "refund_method" => method
      })

  defp apply_credit(group, amount, date \\ "2026-11-26"),
    do:
      operation("apply_hotel_credit", %{
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

  defp correction(type, payment, date, amount \\ nil),
    do:
      operation(type, %{
        "payment_operation_id" => payment,
        "occurred_on" => date,
        "amount_cents" => amount
      })

  defp cash_entry(property, opening, movements, closing),
    do: %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => Map.merge(Map.new(@cash_fields, &{&1, 0}), movements),
      "closing_held_cents" => closing
    }

  defp credit_entry(opening, movements, closing),
    do: %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(Map.new(@credit_fields, &{&1, 0}), movements),
      "closing_liability_cents" => closing
    }

  defp batch(operations),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(path), do: build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp report(date \\ "2026-11-26"), do: read("/api/v1/finance/daily-report?date=" <> date)

  defp unavailable(date),
    do: build_conn() |> get("/api/v1/finance/daily-report?date=" <> date) |> json_response(404)

  defp snapshot do
    Enum.map(
      [
        GroupStay.Group,
        GroupStay.Room,
        GroupStay.RoomAllocation,
        CreditLot,
        GroupStay.CreditEntitlement,
        GroupStay.Operation,
        FinanceReporting,
        FinanceReporting.Movement
      ],
      fn schema -> Repo.all(schema) |> Enum.sort() end
    )
  end

  defp assert_reconciles(date) do
    report = report(date)
    ledger = read("/api/v1/ledger?on=" <> date)

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger["cash_held_cents"]

    assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]

    for row <- report["cash"] do
      m = row["movements"]

      outgoing =
        Enum.sum(Enum.map(@cash_fields -- ~w(received_cents transferred_in_cents), &m[&1]))

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 outgoing
    end

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

    credit = report["credit"]
    outgoing = Enum.sum(Enum.map(@credit_fields -- ["issued_cents"], &credit["movements"][&1]))

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + credit["movements"]["issued_cents"] - outgoing
  end
end
