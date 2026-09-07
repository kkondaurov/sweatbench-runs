defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs \\ %{}, on \\ "2026-10-01") do
    Map.merge(
      %{
        "operation_id" => "finance-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => on
      },
      attrs
    )
  end

  defp open(id, property \\ nil) do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => property || id,
      "arrival_on" => "2028-12-01",
      "departure_on" => "2028-12-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "r", "nightly_rate_cents" => 10000}]
    })
  end

  defp cash(group, id, amount),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount
      })

  defp start, do: op("start_finance_reporting", %{"starts_on" => "2026-10-01"})

  defp submit(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => List.wrap(ops)})
      |> json_response(200)
      |> Map.fetch!("results")

  defp report(date \\ "2026-10-01"),
    do:
      build_conn()
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

  defp cancel(id, on \\ "2026-10-01"),
    do: op("cancel_group", %{"group_id" => id, "refund_method" => "hotel_credit"}, on)

  test "date validation, durable start and replay, and inception within a batch" do
    for params <- [%{}, %{"date" => "bad"}, %{"date" => "2026-02-30"}, %{"date" => []}] do
      assert build_conn() |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-10-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert [%{"code" => "invalid_reporting_date"}] = submit(op("start_finance_reporting"))
    beginning = start()
    payment = cash("a", "p", 200)

    [_, _, started, original] =
      submit([
        open("a"),
        cash("a", "legacy", 100) |> Map.put("occurred_on", "2027-01-01"),
        beginning,
        payment
      ])

    assert started == %{
             "operation_id" => beginning["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-10-01"
           }

    assert [started] == submit(beginning)
    assert [original] == submit(payment)
    assert [%{"code" => "reporting_already_started"}] = submit(start())

    assert [%{"code" => "operation_id_conflict"}] =
             submit(Map.put(beginning, "starts_on", "2026-10-02"))

    assert [
             %{
               "opening_held_cents" => 100,
               "closing_held_cents" => 300,
               "movements" => %{"received_cents" => 200}
             }
           ] = report()["cash"]

    assert report("2026-10-02")["cash"] |> hd() |> Map.fetch!("opening_held_cents") == 300

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2026-09-30")
           |> json_response(404)
  end

  test "transfers and corrections follow held and settled properties including signed reversals" do
    move =
      op("transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 150
      })

    submit([
      open("a"),
      open("b"),
      start(),
      cash("a", "p", 200),
      move,
      op("cancel_group", %{"group_id" => "b"}),
      op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 20}),
      op("charge_back_payment", %{"payment_operation_id" => "p"}, "2026-10-02")
    ])

    [a, b] = report()["cash"]
    assert a["movements"]["transferred_out_cents"] == 150
    assert a["movements"]["reduced_cents"] == 20
    assert a["closing_held_cents"] == 30
    assert b["movements"]["transferred_in_cents"] == 150
    assert b["movements"]["refunded_cents"] == 150
    [a, b] = report("2026-10-02")["cash"]
    assert a["movements"]["charged_back_cents"] == 30
    assert b["movements"]["refunded_cents"] == -150
    assert b["movements"]["charged_back_cents"] == 150
    assert a["closing_held_cents"] == 0
    assert b["closing_held_cents"] == 0
    assert report("2026-10-03")["cash"] == []
  end

  test "expiry without operations, paused applied credit and expired restoration" do
    submit([
      open("seed"),
      cash("seed", "p", 100),
      cancel("seed"),
      open("a"),
      start(),
      op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 60})
    ])

    assert report()["credit"]["opening_liability_cents"] == 110
    assert report("2027-10-01")["credit"]["closing_liability_cents"] == 110
    expiry = report("2027-10-02")
    assert expiry["credit"]["movements"]["expired_cents"] == 50
    assert expiry["credit"]["closing_liability_cents"] == 60
    submit(cancel("a", "2027-10-03"))
    assert report("2027-10-03")["credit"]["movements"]["expired_cents"] == 60
    assert report("2027-10-03")["credit"]["closing_liability_cents"] == 0
    assert report("2027-10-02") == expiry
    assert report()["credit"]["closing_liability_cents"] == 110
  end

  test "credit issue revocation and shortfall absorption reconcile without duplicate movements" do
    submit([
      open("seed"),
      open("a"),
      start(),
      cash("seed", "p", 100),
      cancel("seed"),
      op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 80}),
      op("charge_back_payment", %{"payment_operation_id" => "p"})
    ])

    credit = report()["credit"]
    assert credit["movements"]["issued_cents"] == 110
    assert credit["movements"]["revoked_cents"] == 30
    assert credit["closing_liability_cents"] == 80
    cancellation = cancel("a", "2027-10-03")
    [result] = submit(cancellation)
    assert [result] == submit(cancellation)
    assert report("2027-10-03")["credit"]["movements"]["absorbed_cents"] == 80
    assert report("2027-10-03")["credit"]["movements"]["expired_cents"] == 0
    assert report("2027-10-03")["credit"]["closing_liability_cents"] == 0
  end

  test "same property transfers show both cash columns, and rejected operations leave no entries" do
    submit([
      open("a", "hotel"),
      open("b", "hotel"),
      start(),
      cash("a", "p", 100),
      op("transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 70
      })
    ])

    [row] = report()["cash"]
    assert row["movements"]["transferred_in_cents"] == 70
    assert row["movements"]["transferred_out_cents"] == 70
    before = report()
    submit([cash("a", "bad", 10000), op("cancel_group", %{"group_id" => "missing"})])
    assert report() == before
  end

  test "late postings are clamped to inception and nonrefundable credit is consumed" do
    submit([
      open("seed"),
      open("a"),
      start(),
      cash("seed", "p", 100),
      cancel("seed"),
      op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 80}),
      op("cancel_group", %{"group_id" => "a"}, "2028-11-30")
    ])

    assert report("2028-11-30")["credit"]["movements"]["consumed_cents"] == 80
    assert report("2028-11-30")["credit"]["closing_liability_cents"] == 0

    submit([
      open("b"),
      op("record_cash_payment", %{"group_id" => "b", "amount_cents" => 50}, "2025-01-01")
    ])

    assert Enum.find(report()["cash"], &(&1["property_id"] == "b"))["movements"]["received_cents"] ==
             50

    ledger = GroupStay.Reservations.ledger(~D[2028-11-30])
    latest = report("2028-11-30")

    assert Enum.sum(Enum.map(latest["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert latest["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  test "backdated application adjusts expiry and repeated reads are pure" do
    submit([open("seed"), cash("seed", "p", 100), cancel("seed"), open("a"), start()])
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 110
    submit(op("apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 40}, "2027-09-01"))
    assert report("2027-10-02")["credit"]["movements"]["expired_cents"] == 70
    assert report("2027-10-02")["credit"]["closing_liability_cents"] == 40
    before = GroupStay.Repo.query!("SELECT * FROM finance_movements").rows
    for day <- ["2028-01-01", "2026-10-01", "2027-10-02", "2028-01-01"], do: report(day)
    assert GroupStay.Repo.query!("SELECT * FROM finance_movements").rows == before
  end
end
