defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{FinanceReporting, Repo, Reservations}
  alias GroupStay.FinanceReporting.{Entry, Opening}

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

  defp cancel(group, method \\ "cash", on \\ "2027-01-01"),
    do: op("cancel_group", %{"group_id" => group, "refund_method" => method}, on)

  defp apply_credit(group, amount, on \\ "2027-01-01"),
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

  defp correction(type, payment, on, attrs \\ %{}),
    do: op(type, Map.put(attrs, "payment_operation_id", payment), on)

  defp start(on \\ "2027-01-01"),
    do: %{"operation_id" => "start", "type" => "start_finance_reporting", "starts_on" => on}

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(on),
    do:
      build_conn()
      |> get("/api/v1/finance/daily-report?date=#{on}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp cash(report, property), do: Enum.find(report["cash"], &(&1["property_id"] == property))
  defp entries, do: {Repo.all(Opening), Repo.all(Entry)}

  defp assert_balanced(report) do
    assert Map.keys(report) |> Enum.sort() == ~w(cash credit date status)
    assert report["status"] == "open"
    assert report["cash"] == Enum.sort_by(report["cash"], & &1["property_id"])

    for row <- report["cash"] do
      assert Map.keys(row) |> Enum.sort() ==
               ~w(closing_held_cents movements opening_held_cents property_id)

      m = row["movements"]

      assert Map.keys(m) |> Enum.sort() ==
               ~w(charged_back_cents converted_to_credit_cents received_cents reduced_cents refunded_cents retained_cents transferred_in_cents transferred_out_cents)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] +
                 m["received_cents"] + m["transferred_in_cents"] - m["transferred_out_cents"] -
                 m["refunded_cents"] - m["retained_cents"] - m["converted_to_credit_cents"] -
                 m["reduced_cents"] - m["charged_back_cents"]
    end

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

    credit = report["credit"]

    assert Map.keys(credit) |> Enum.sort() ==
             ~w(closing_liability_cents movements opening_liability_cents)

    m = credit["movements"]

    assert Map.keys(m) |> Enum.sort() ==
             ~w(absorbed_cents consumed_cents expired_cents issued_cents revoked_cents)

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

  test "validates dates, starts exactly once without a group guard, and durably replays outcomes" do
    for query <- ["", "?date=bad", "?date=2027-02-29", "?date[]=2027-01-01"] do
      assert build_conn() |> get("/api/v1/finance/daily-report#{query}") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-01")
           |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    for value <- [nil, "bad", "2027-02-29", 20_270_101, [], %{}] do
      bad = op("start_finance_reporting", %{"starts_on" => value})
      assert [%{"code" => "invalid_reporting_date"}] = result = batch([bad])
      assert batch([bad]) == result
      assert entries() == {[], []}
    end

    assert [%{"code" => "invalid_reporting_date"}] = batch([op("start_finance_reporting")])
    operation = Map.put(start(), "expected_revision", "ignored")

    assert batch([operation]) == [
             %{"operation_id" => "start", "status" => "applied", "starts_on" => "2027-01-01"}
           ]

    assert batch([operation]) == [Reservations.get_operation("start")]
    assert [%{"code" => "operation_id_conflict"}] = batch([start("2027-01-02")])

    assert [%{"code" => "reporting_already_started"}] =
             batch([op("start_finance_reporting", %{"starts_on" => "2028-01-01"})])

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-12-31")
           |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    empty = report("2027-01-01")
    assert empty["cash"] == []
    assert_current(empty)
  end

  test "inception captures commit order and later submissions update the clamped posting date only" do
    late = pay("later", "a", 25, "2026-12-31")

    operations = [
      open("a"),
      open("zero"),
      pay("future", "a", 100, "2029-01-01"),
      start(),
      late,
      pay("tomorrow", "a", 50, "2027-01-02")
    ]

    assert Enum.all?(batch(operations), &(&1["status"] == "applied"))
    first = report("2027-01-01")

    assert [
             %{
               "property_id" => "a",
               "opening_held_cents" => 100,
               "closing_held_cents" => 125,
               "movements" => %{"received_cents" => 25}
             }
           ] = first["cash"]

    assert_balanced(first)
    assert_current(report("2027-01-02"))
    before = entries()
    assert Enum.all?(batch(operations), &(&1["status"] == "applied"))
    assert report("2027-01-01") == first
    assert entries() == before
    batch([pay("backdated", "a", 10, "2027-01-01")])
    assert cash(report("2027-01-01"), "a")["closing_held_cents"] == 135
    assert cash(report("2027-01-02"), "a")["opening_held_cents"] == 135
    assert_current(report("2029-01-01"))
  end

  test "cash follows properties through mixed transfers, settlements, reductions and chargeback reclassification" do
    batch([
      start(),
      open("z-source"),
      pay("p", "z-source", 500),
      open("refund"),
      open("retain", %{"rate_plan" => "advance_purchase"}),
      open("convert"),
      open("consumer"),
      transfer("z-source", "refund", 100),
      transfer("z-source", "retain", 100),
      transfer("z-source", "convert", 100),
      cancel("refund"),
      cancel("retain"),
      cancel("convert", "hotel_credit"),
      apply_credit("consumer", 80),
      correction("reduce_cash_payment", "p", "2027-01-01", %{"amount_cents" => 50})
    ])

    first = report("2027-01-01")
    assert_current(first)
    assert cash(first, "z-source")["movements"]["received_cents"] == 500
    assert cash(first, "z-source")["movements"]["transferred_out_cents"] == 300
    assert cash(first, "refund")["movements"]["refunded_cents"] == 100
    assert cash(first, "retain")["movements"]["retained_cents"] == 100
    assert cash(first, "convert")["movements"]["converted_to_credit_cents"] == 100
    assert cash(first, "consumer") == nil
    chargeback = correction("charge_back_payment", "p", "2027-01-02")
    batch([chargeback])
    second = report("2027-01-02")
    assert_current(second)
    assert cash(second, "z-source")["movements"]["charged_back_cents"] == 150

    for {property, disposition} <- [
          {"refund", "refunded_cents"},
          {"retain", "retained_cents"},
          {"convert", "converted_to_credit_cents"}
        ] do
      row = cash(second, property)
      assert row["opening_held_cents"] == 0
      assert row["closing_held_cents"] == 0
      assert row["movements"][disposition] == -100
      assert row["movements"]["charged_back_cents"] == 100
    end

    assert second["credit"]["movements"]["revoked_cents"] == 30
    assert second["credit"]["closing_liability_cents"] == 80
    assert report("2027-01-01") == first
    before = entries()
    batch([chargeback, Map.put(chargeback, "occurred_on", "2027-01-03")])
    assert entries() == before
    assert report("2027-01-03")["cash"] == []
  end

  test "same-property mixed transfers show gross cash transfers and credit transfers have no liability movement" do
    batch([
      open("seed"),
      pay("seed-pay", "seed", 100),
      cancel("seed", "hotel_credit"),
      open("a", %{"property_id" => "hotel"}),
      open("b", %{"property_id" => "hotel"}),
      pay("p", "a", 100),
      apply_credit("a", 100),
      start(),
      transfer("a", "b", 150)
    ])

    result = report("2027-01-01")

    assert [
             %{
               "opening_held_cents" => 100,
               "closing_held_cents" => 100,
               "movements" => %{"transferred_in_cents" => 50, "transferred_out_cents" => 50}
             }
           ] = result["cash"]

    assert Enum.all?(result["credit"]["movements"], fn {_, amount} -> amount == 0 end)
    assert_current(result)
  end

  test "expiry runs without operations, includes inception lots, and pauses while applied across transfers" do
    batch([
      open("seed"),
      pay("p", "seed", 100),
      cancel("seed", "hotel_credit"),
      open("a"),
      open("b"),
      apply_credit("a", 80),
      start(),
      transfer("a", "b", 80, "2028-01-02")
    ])

    before = entries()
    expiry = report("2028-01-02")
    assert expiry["credit"]["opening_liability_cents"] == 110
    assert expiry["credit"]["movements"]["expired_cents"] == 30
    assert expiry["credit"]["closing_liability_cents"] == 80
    assert report("2028-01-01")["credit"]["closing_liability_cents"] == 110
    assert report("2028-01-02") == expiry
    assert entries() == before
    assert_current(expiry)
    batch([cancel("b", "hotel_credit", "2028-01-03")])
    restored = report("2028-01-03")
    assert restored["credit"]["movements"]["expired_cents"] == 80
    assert restored["credit"]["movements"]["issued_cents"] == 0
    assert_current(restored)
  end

  test "backdated redemption and restoration adjust scheduled expiry without read side effects" do
    batch([
      start(),
      open("seed"),
      pay("p", "seed", 100),
      cancel("seed", "hotel_credit"),
      open("consumer")
    ])

    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 110
    batch([apply_credit("consumer", 80, "2027-12-01")])
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 30
    batch([cancel("consumer", "cash", "2027-12-02")])
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 110

    assert Enum.all?(report("2027-12-02")["credit"]["movements"], fn {_, amount} ->
             amount == 0
           end)

    assert_current(report("2028-01-02"))
  end

  test "shortfall absorption precedes expiry and consumption independently reduces liability" do
    batch([
      start(),
      open("seed"),
      pay("p1", "seed", 40),
      pay("p2", "seed", 60),
      cancel("seed", "hotel_credit"),
      open("consumer"),
      apply_credit("consumer", 110),
      correction("charge_back_payment", "p1", "2027-01-02")
    ])

    assert report("2027-01-02")["credit"]["movements"]["revoked_cents"] == 0
    batch([cancel("consumer", "cash", "2028-01-02")])
    result = report("2028-01-02")

    assert result["credit"]["movements"] == %{
             "issued_cents" => 0,
             "expired_cents" => 66,
             "consumed_cents" => 0,
             "revoked_cents" => 0,
             "absorbed_cents" => 44
           }

    assert_current(result)

    batch([
      open("other"),
      pay("other-pay", "other", 100, "2028-02-01"),
      cancel("other", "hotel_credit", "2028-02-01"),
      open("nonref", %{"rate_plan" => "advance_purchase"}),
      apply_credit("nonref", 100, "2028-02-01"),
      correction("charge_back_payment", "other-pay", "2028-02-02"),
      cancel("nonref", "cash", "2028-02-03")
    ])

    assert report("2028-02-02")["credit"]["movements"]["revoked_cents"] == 10
    assert report("2028-02-03")["credit"]["movements"]["consumed_cents"] == 100
    assert_current(report("2029-02-02"))
  end

  test "chargeback of already expired available credit does not revoke liability twice" do
    batch([start(), open("seed"), pay("p", "seed", 100), cancel("seed", "hotel_credit")])
    expiry = report("2028-01-02")
    batch([correction("charge_back_payment", "p", "2028-01-03")])
    result = report("2028-01-03")
    assert result["credit"]["movements"]["revoked_cents"] == 0
    assert result["credit"]["movements"]["expired_cents"] == 0
    assert report("2028-01-02") == expiry
    assert_current(result)
  end

  test "batch and sequential submissions agree, rejections add nothing, and failed commits roll back reporting" do
    operations = [
      open("a"),
      pay("p", "a", 100),
      start(),
      pay("p2", "a", 50),
      pay("too-much", "a", 500),
      open("b"),
      transfer("a", "b", 80),
      cancel("b", "hotel_credit")
    ]

    Repo.query!("SAVEPOINT batch_equivalence")
    results = batch(operations)
    expected = for on <- ~w(2027-01-01 2028-01-02), do: report(on)
    Repo.query!("ROLLBACK TO SAVEPOINT batch_equivalence")
    Repo.query!("RELEASE SAVEPOINT batch_equivalence")
    assert Enum.map(operations, &(batch([&1]) |> hd())) == results
    assert Enum.map(~w(2027-01-01 2028-01-02), &report/1) == expected
    before = entries()
    assert batch(operations) == results
    assert entries() == before

    Repo.query!("""
    CREATE TRIGGER fail_finance BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    failed = pay("fault", "a", 10)
    assert_error_sent 500, fn -> batch([failed, open("never")]) end
    assert entries() == before
    assert Reservations.get_operation("fault") == nil
    assert Reservations.get_group("never") == nil
    Repo.query!("DROP TRIGGER fail_finance")
    assert [%{"status" => "applied"}] = batch([failed])
    assert_current(report("2027-01-01"))
  end

  test "a failed inception leaves reporting unavailable and can be retried" do
    Repo.query!("""
    CREATE TRIGGER fail_start BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'start'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    assert_error_sent 500, fn -> batch([start()]) end
    assert entries() == {[], []}
    assert FinanceReporting.daily_report("2027-01-01") == {:error, "report_not_available"}
    Repo.query!("DROP TRIGGER fail_start")
    assert [%{"status" => "applied"}] = batch([start()])
  end

  test "partial room settlement reports the combined bonus and reductions follow held cash across properties" do
    batch([
      start(),
      open("source"),
      pay("p", "source", 200),
      open("dest"),
      transfer("source", "dest", 150),
      correction("reduce_cash_payment", "p", "2027-01-02", %{"amount_cents" => 175})
    ])

    second = report("2027-01-02")
    assert cash(second, "dest")["movements"]["reduced_cents"] == 150
    assert cash(second, "source")["movements"]["reduced_cents"] == 25
    assert_current(second)

    rooms = for i <- 0..2, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 15}

    batch([
      open("tiny", %{"rooms" => rooms}),
      pay("tiny-pay", "tiny", 6, "2027-01-03"),
      op(
        "cancel_rooms",
        %{"group_id" => "tiny", "room_ids" => ["r1", "r0"], "refund_method" => "hotel_credit"},
        "2027-01-03"
      )
    ])

    third = report("2027-01-03")
    assert cash(third, "tiny")["movements"]["converted_to_credit_cents"] == 6
    assert third["credit"]["movements"]["issued_cents"] == 7
    assert_current(third)
    before = entries()

    batch([
      op("reschedule_group", %{"group_id" => "source", "new_arrival_on" => "2031-06-01"}),
      op("cancel_group", %{"group_id" => "source", "expected_revision" => 1}),
      op("unknown")
    ])

    assert entries() == before
  end

  test "returning shortfalled credit before expiry absorbs first and schedules only the excess" do
    batch([
      start(),
      open("seed"),
      pay("p1", "seed", 40),
      pay("p2", "seed", 60),
      cancel("seed", "hotel_credit"),
      open("consumer"),
      apply_credit("consumer", 110),
      correction("charge_back_payment", "p1", "2027-01-02"),
      cancel("consumer", "cash", "2027-01-03")
    ])

    result = report("2027-01-03")
    assert result["credit"]["movements"]["absorbed_cents"] == 44
    assert result["credit"]["movements"]["expired_cents"] == 0
    assert result["credit"]["closing_liability_cents"] == 66
    assert_current(result)
    assert report("2028-01-02")["credit"]["movements"]["expired_cents"] == 66

    snapshot = fn ->
      Enum.map(
        [
          GroupStay.Group,
          GroupStay.CreditLot,
          GroupStay.CreditAllocation,
          GroupStay.CreditClawback,
          GroupStay.CreditEntitlement,
          GroupStay.RoomAllocation,
          GroupStay.Operation,
          Opening,
          Entry
        ],
        &Repo.all/1
      )
    end

    before = snapshot.()
    for on <- ~w(2028-01-02 2027-01-01 2028-01-03 2027-01-03 2028-01-02), do: report(on)
    assert snapshot.() == before
  end

  test "a reporting write failure rolls back the operation but preserves earlier batch commits" do
    batch([open("a"), start()])

    Repo.query!("""
    CREATE TRIGGER fail_entry BEFORE INSERT ON finance_entries
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    failed = pay("fault", "a", 10)

    assert_error_sent 500, fn ->
      batch([pay("earlier", "a", 20), failed, pay("never", "a", 30)])
    end

    assert Reservations.get_group("a").cash_paid_cents == 20
    assert Reservations.get_operation("fault") == nil
    assert Reservations.get_operation("never") == nil
    assert cash(report("2027-01-01"), "a")["movements"]["received_cents"] == 20
    Repo.query!("DROP TRIGGER fail_entry")
    assert [%{"status" => "applied"}] = batch([failed])
    assert_current(report("2027-01-01"))
  end
end
