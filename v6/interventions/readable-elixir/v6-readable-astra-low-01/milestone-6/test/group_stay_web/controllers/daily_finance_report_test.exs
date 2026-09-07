defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp op(type, fields) do
    Map.merge(
      %{
        "operation_id" => "finance-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2027-02-01",
        "group_id" => "source"
      },
      fields
    )
  end

  defp open(id \\ "source", property \\ "ams") do
    op("open_group", %{
      "group_id" => id,
      "property_id" => property,
      "guest_id" => "guest",
      "arrival_on" => "2029-06-01",
      "departure_on" => "2029-06-02",
      "rate_plan" => "flexible",
      "rooms" => Enum.map(1..3, &%{"room_id" => "r#{&1}", "nightly_rate_cents" => 5000})
    })
  end

  defp start(date \\ "2027-02-01"),
    do: op("start_finance_reporting", %{"starts_on" => date}) |> Map.delete("group_id")

  defp pay(id, amount, fields \\ %{}),
    do:
      op(
        "record_cash_payment",
        Map.merge(%{"operation_id" => id, "amount_cents" => amount}, fields)
      )

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{operations: ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp report(date \\ "2027-02-01") do
    data =
      build_conn()
      |> get("/api/v1/finance/daily-report", %{date: date})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Map.keys(data) |> Enum.sort() == ~w(cash credit date status)
    assert data["status"] == "open"

    for cash <- data["cash"] do
      assert Enum.sort(Map.keys(cash)) ==
               ~w(closing_held_cents movements opening_held_cents property_id)

      m = cash["movements"]

      assert Map.keys(m) |> Enum.sort() ==
               Enum.sort(
                 ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
               )

      assert cash["closing_held_cents"] ==
               cash["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    assert Enum.sum(Enum.map(data["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(data["cash"], & &1["movements"]["transferred_out_cents"]))

    c = data["credit"]
    assert Enum.sort(Map.keys(c)) == ~w(closing_liability_cents movements opening_liability_cents)
    m = c["movements"]

    assert Map.keys(m) |> Enum.sort() ==
             Enum.sort(~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents))

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    data
  end

  defp cash(data, property), do: Enum.find(data["cash"], &(&1["property_id"] == property))
  defp credit(data), do: data["credit"]["movements"]

  test "date validation, availability, exact start result and durable start rejections" do
    for params <- [%{}, %{date: "bad"}, %{date: "2027-02-30"}] do
      assert build_conn() |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-02-01")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for value <- [nil, "bad", 42, "2027-02-30"] do
      assert [%{"code" => "invalid_reporting_date"}] = batch([start(value)])
    end

    assert [%{"code" => "invalid_reporting_date"}] = batch([Map.delete(start(), "starts_on")])
    first = start() |> Map.put("expected_revision", -1)
    assert [result] = batch([first])

    assert result == %{
             "operation_id" => first["operation_id"],
             "status" => "applied",
             "starts_on" => "2027-02-01"
           }

    assert batch([first]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(first, "starts_on", "2027-02-02")])

    later = start("2027-02-02")
    assert [%{"code" => "reporting_already_started"} = rejected] = batch([later])
    assert batch([later]) == [rejected]

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-31")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    assert report()["cash"] == []
  end

  test "inception is commit order, dates clamp, late submissions amend reports and reads are pure" do
    batch([
      open(),
      pay("opening", 1000, %{"occurred_on" => "2028-01-01"}),
      start(),
      pay("today", 200, %{"occurred_on" => "2026-12-01"}),
      pay("tomorrow", 300, %{"occurred_on" => "2027-02-02"})
    ])

    assert cash(report(), "ams")["opening_held_cents"] == 1000
    assert cash(report(), "ams")["closing_held_cents"] == 1200
    assert cash(report("2027-02-02"), "ams")["closing_held_cents"] == 1500
    payment = pay("late", 50)
    batch([payment, pay("bad", 9000)])
    assert cash(report(), "ams")["movements"]["received_cents"] == 250
    before = report()
    future = report("2029-01-01")
    batch([payment])
    assert report() == before
    assert report("2029-01-01") == future

    assert cash(future, "ams")["closing_held_cents"] ==
             GroupStay.Reservations.ledger().cash_held_cents
  end

  test "cash transfers and corrections follow held and settled properties" do
    batch([
      open(),
      open("destination", "ber"),
      start(),
      pay("payment", 2000),
      op("transfer_deposit", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 1200
      }),
      op("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r1"]}),
      op("reduce_cash_payment", %{"payment_operation_id" => "payment", "amount_cents" => 300}),
      op("charge_back_payment", %{"payment_operation_id" => "payment"})
    ])

    data = report()
    assert Enum.map(data["cash"], & &1["property_id"]) == ["ams", "ber"]
    a = cash(data, "ams")
    b = cash(data, "ber")
    assert a["movements"]["received_cents"] == 2000
    assert a["movements"]["transferred_out_cents"] == 1200
    assert a["movements"]["reduced_cents"] == 100
    assert a["movements"]["charged_back_cents"] == 700
    assert b["movements"]["transferred_in_cents"] == 1200
    assert b["movements"]["refunded_cents"] == 0
    assert b["movements"]["reduced_cents"] == 200
    assert b["movements"]["charged_back_cents"] == 1000
    assert a["closing_held_cents"] == 0
    assert b["closing_held_cents"] == 0
    batch([op("charge_back_payment", %{"payment_operation_id" => "payment"})])
    assert report() == data
  end

  test "a later chargeback reverses refund, retention and conversion on its posting day" do
    batch([
      open(),
      start(),
      pay("p", 3000),
      op("cancel_rooms", %{"room_ids" => ["r1"]}),
      op("cancel_rooms", %{"room_ids" => ["r2"], "refund_method" => "hotel_credit"}),
      op("cancel_rooms", %{"room_ids" => ["r3"], "occurred_on" => "2029-05-31"}),
      op("charge_back_payment", %{"payment_operation_id" => "p", "occurred_on" => "2029-06-01"})
    ])

    movements = cash(report("2029-06-01"), "ams")["movements"]
    assert movements["refunded_cents"] == -1000
    assert movements["retained_cents"] == -1000
    assert movements["converted_to_credit_cents"] == -1000
    assert movements["charged_back_cents"] == 3000
    assert report("2029-06-01")["credit"]["closing_liability_cents"] == 0
  end

  test "same-property transfers show both sides and credit transfers have no movement" do
    batch([
      open(),
      open("destination"),
      start(),
      pay("p", 100),
      op("transfer_deposit", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 100
      }),
      op("cancel_group", %{"group_id" => "destination", "refund_method" => "hotel_credit"}),
      open("third"),
      op("apply_hotel_credit", %{"amount_cents" => 110})
    ])

    before = report()

    batch([
      op("transfer_deposit", %{
        "source_group_id" => "source",
        "destination_group_id" => "third",
        "amount_cents" => 110
      })
    ])

    assert report() == before
    assert cash(before, "ams")["movements"]["transferred_in_cents"] == 100
    assert cash(before, "ams")["movements"]["transferred_out_cents"] == 100
  end

  test "inception includes available and applied credit and schedules only unused expiry" do
    batch([
      open(),
      pay("p", 1000),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      open("target"),
      op("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 600}),
      start()
    ])

    assert report()["credit"]["opening_liability_cents"] == 1100
    assert credit(report())["issued_cents"] == 0
    assert report("2028-02-01")["credit"]["closing_liability_cents"] == 1100
    assert credit(report("2028-02-02"))["expired_cents"] == 500
    assert report("2028-02-02")["credit"]["closing_liability_cents"] == 600
    batch([op("cancel_group", %{"group_id" => "target", "occurred_on" => "2028-03-01"})])
    assert credit(report("2028-03-01"))["expired_cents"] == 600
    assert report("2028-03-01")["credit"]["closing_liability_cents"] == 0
  end

  test "revocation, shortfall absorption, consumption and restored expiry reconcile" do
    batch([
      open(),
      open("target"),
      start(),
      pay("p", 1000),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      op("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 800}),
      op("charge_back_payment", %{"payment_operation_id" => "p"})
    ])

    assert credit(report())["issued_cents"] == 1100
    assert credit(report())["revoked_cents"] == 300
    assert report()["credit"]["closing_liability_cents"] == 800
    batch([op("cancel_group", %{"group_id" => "target", "occurred_on" => "2028-03-01"})])
    assert credit(report("2028-03-01"))["absorbed_cents"] == 800
    assert credit(report("2028-03-01"))["expired_cents"] == 0
    assert report("2028-03-01")["credit"]["closing_liability_cents"] == 0
    assert credit(report("2028-02-02"))["expired_cents"] == 0
  end

  test "refundable restoration reschedules expiry and nonrefundable credit is consumed" do
    batch([
      open(),
      open("target"),
      start(),
      pay("p", 1000),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      op("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 1100}),
      op("cancel_rooms", %{"group_id" => "target", "room_ids" => ["r1"]}),
      op("cancel_group", %{"group_id" => "target", "occurred_on" => "2029-05-31"})
    ])

    assert credit(report("2028-02-02"))["expired_cents"] == 1000
    assert credit(report("2029-05-31"))["consumed_cents"] == 100

    assert report("2029-05-31")["credit"]["closing_liability_cents"] ==
             GroupStay.Reservations.ledger(~D[2029-05-31]).credit_liability_cents
  end

  test "equivalent batches and sequential submissions produce the same reports" do
    operations = [
      open(),
      pay("opening", 1000),
      start(),
      open("target", "ber"),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      op("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 700}),
      op("charge_back_payment", %{
        "payment_operation_id" => "opening",
        "occurred_on" => "2027-02-02"
      }),
      op("cancel_group", %{"group_id" => "target", "occurred_on" => "2028-03-01"})
    ]

    dates = ~w(2027-02-01 2027-02-02 2028-02-02 2028-03-01)

    {:error, {results, reports}} =
      GroupStay.Repo.transaction(fn ->
        results = batch(operations)
        reports = Enum.map(dates, &report/1)
        GroupStay.Repo.rollback({results, reports})
      end)

    assert Enum.flat_map(operations, &batch([&1])) == results
    assert Enum.map(dates, &report/1) == reports
    assert Enum.map(Enum.reverse(dates), &report/1) == Enum.reverse(reports)
  end

  test "already expired credit is excluded at inception and is not revoked twice" do
    batch([
      open(),
      pay("p", 1000),
      op("cancel_group", %{"refund_method" => "hotel_credit"}),
      start("2028-03-01")
    ])

    assert report("2028-03-01")["credit"]["opening_liability_cents"] == 0

    batch([
      op("charge_back_payment", %{"payment_operation_id" => "p", "occurred_on" => "2028-03-02"})
    ])

    assert report("2028-03-02")["credit"]["closing_liability_cents"] == 0
    assert Enum.all?(credit(report("2028-03-02")), fn {_, amount} -> amount == 0 end)
    assert report("2028-03-03")["cash"] == []
  end

  test "credit issuance before inception's date posts and expires at inception when already expired" do
    batch([
      open(),
      pay("p", 1000),
      start("2028-03-01"),
      op("cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    assert credit(report("2028-03-01"))["issued_cents"] == 1100
    assert credit(report("2028-03-01"))["expired_cents"] == 1100
    assert report("2028-03-01")["credit"]["closing_liability_cents"] == 0
  end
end
