defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.Movement

  defp op(id, type, attrs \\ %{}, on \\ "2027-01-02") do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => on}, attrs)
  end

  defp open(id, attrs \\ %{}) do
    op(
      "open-#{id}",
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2029-06-01",
          "departure_on" => "2029-06-02",
          "rate_plan" => "flexible",
          "rooms" => for(i <- 1..3, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp start(date \\ "2027-01-02"),
    do: op("start", "start_finance_reporting", %{"starts_on" => date})

  defp pay(id, group, amount, on \\ "2027-01-02"),
    do: op(id, "record_cash_payment", %{"group_id" => group, "amount_cents" => amount}, on)

  defp credit(id, group, amount, on \\ "2027-01-02"),
    do: op(id, "apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount}, on)

  defp cancel(id, group, attrs \\ %{}, on \\ "2027-01-02"),
    do: op(id, "cancel_group", Map.put(attrs, "group_id", group), on)

  defp transfer(id, source, destination, amount),
    do:
      op(id, "transfer_deposit", %{
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      })

  defp correction(id, type, payment, attrs \\ %{}, on \\ "2027-01-02"),
    do: op(id, type, Map.put(attrs, "payment_operation_id", payment), on)

  defp batch(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => ops})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp report(date \\ "2027-01-02") do
    result =
      build_conn()
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Map.keys(result) |> Enum.sort() == ~w(cash credit date late_adjustments status)
    assert result["date"] == date
    assert result["status"] == "open"

    for row <- result["cash"] do
      assert Map.keys(row) |> Enum.sort() ==
               ~w(closing_held_cents movements opening_held_cents property_id)

      m = row["movements"]

      assert Map.keys(m) |> Enum.sort() ==
               ~w(charged_back_cents converted_to_credit_cents received_cents reduced_cents refunded_cents retained_cents transferred_in_cents transferred_out_cents)

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end

    assert Enum.sum(Enum.map(result["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(result["cash"], & &1["movements"]["transferred_out_cents"]))

    c = result["credit"]

    assert Map.keys(c) |> Enum.sort() ==
             ~w(closing_liability_cents movements opening_liability_cents)

    m = c["movements"]

    assert Map.keys(m) |> Enum.sort() ==
             ~w(absorbed_cents consumed_cents expired_cents issued_cents revoked_cents)

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    result
  end

  defp cash(report, property), do: Enum.find(report["cash"], &(&1["property_id"] == property))

  defp reconciles(date) do
    report = report(date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))

    assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
             ledger.cash_held_cents

    assert report["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  test "date validation, availability, exact start shape and durable start rejections" do
    for params <- [%{}, %{"date" => "no"}, %{"date" => "2027-02-29"}, %{"date" => ["2027-01-02"]}] do
      assert build_conn() |> get("/api/v1/finance/daily-report", params) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-02")
           |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    for {value, index} <- Enum.with_index([nil, "", "2027-02-29", 123, []]) do
      operation = op("invalid-#{index}", "start_finance_reporting", %{"starts_on" => value})
      assert [%{"code" => "invalid_reporting_date"} = result] = batch([operation])
      assert batch([operation]) == [result]
    end

    assert [%{"code" => "invalid_reporting_date"}] =
             batch([op("missing", "start_finance_reporting")])

    assert [result] = batch([start()])

    assert result == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2027-01-02"
           }

    assert batch([start()]) == [result]
    assert [%{"code" => "operation_id_conflict"}] = batch([start("2027-01-03")])
    another = Map.put(start(), "operation_id", "another")
    assert [%{"code" => "reporting_already_started"} = rejected] = batch([another])
    assert batch([another]) == [rejected]

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-01-01")
           |> json_response(404) ==
             %{"error" => %{"code" => "report_not_available"}}

    assert report()["cash"] == []
    assert report()["credit"]["closing_liability_cents"] == 0
  end

  test "opening is a commit boundary, combines properties and clamps subsequent posting dates" do
    batch([
      open("a", %{"property_id" => "hotel"}),
      open("b", %{"property_id" => "hotel"}),
      open("empty"),
      pay("prior-future", "a", 100, "2028-01-01"),
      pay("prior", "b", 50),
      start("2027-02-01"),
      pay("backdated", "a", 25),
      pay("later", "b", 40, "2027-02-03")
    ])

    day = report("2027-02-01")
    assert length(day["cash"]) == 1
    assert cash(day, "hotel")["opening_held_cents"] == 150
    assert cash(day, "hotel")["movements"]["received_cents"] == 25
    assert cash(day, "hotel")["closing_held_cents"] == 175
    assert cash(report("2027-02-02"), "hotel")["opening_held_cents"] == 175
    assert cash(report("2027-02-03"), "hotel")["movements"]["received_cents"] == 40
    batch([pay("late-submission", "a", 10, "2027-02-01")])
    assert cash(report("2027-02-01"), "hotel")["closing_held_cents"] == 185
    assert cash(report("2027-02-03"), "hotel")["opening_held_cents"] == 185
    reconciles("2027-02-03")
  end

  test "mixed transfers report cash only, including transfers within a property and remote reductions" do
    batch([
      open("issuer"),
      pay("issued", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("a"),
      open("b"),
      open("c", %{"property_id" => "b"}),
      start(),
      pay("p", "a", 100),
      credit("redeem", "a", 110),
      transfer("ab", "a", "b", 160),
      transfer("bc", "b", "c", 30),
      correction("reduce", "reduce_cash_payment", "p", %{"amount_cents" => 40})
    ])

    day = report()
    assert Enum.map(day["cash"], & &1["property_id"]) == ["a", "b"]
    assert cash(day, "a")["movements"]["transferred_out_cents"] == 50
    assert cash(day, "b")["movements"]["transferred_in_cents"] == 80
    assert cash(day, "b")["movements"]["transferred_out_cents"] == 30
    assert cash(day, "b")["movements"]["reduced_cents"] == 40
    assert cash(day, "b")["closing_held_cents"] == 10
    assert day["credit"]["opening_liability_cents"] == 110
    assert Enum.all?(day["credit"]["movements"], fn {_, amount} -> amount == 0 end)
    reconciles("2027-01-02")
  end

  test "chargebacks reverse settled classifications at the settlement property, including opening history" do
    batch([
      open("a"),
      open("b", %{"rate_plan" => "advance_purchase"}),
      open("c"),
      pay("p", "a", 250),
      transfer("ab", "a", "b", 50),
      transfer("ac", "a", "c", 100),
      cancel("retain", "b"),
      cancel("convert", "c", %{"refund_method" => "hotel_credit"}),
      cancel("refund", "a"),
      start(),
      correction("cb", "charge_back_payment", "p")
    ])

    day = report()

    for {property, classification, amount} <- [
          {"a", "refunded_cents", 100},
          {"b", "retained_cents", 50},
          {"c", "converted_to_credit_cents", 100}
        ] do
      row = cash(day, property)
      assert row["opening_held_cents"] == 0
      assert row["closing_held_cents"] == 0
      assert row["movements"][classification] == -amount
      assert row["movements"]["charged_back_cents"] == amount
    end

    assert day["credit"]["movements"]["revoked_cents"] == 110
    reconciles("2027-01-02")
    assert report("2027-01-03")["cash"] == []
    assert report("2028-01-03")["credit"]["movements"]["expired_cents"] == 0
  end

  test "partial settlement issues a single rounded bonus and expiry occurs without an operation" do
    batch([
      start(),
      open("a"),
      open("redeemer"),
      pay("p", "a", 105),
      op("partial", "cancel_rooms", %{
        "group_id" => "a",
        "room_ids" => ["r2", "r1"],
        "refund_method" => "hotel_credit"
      }),
      credit("redeem", "redeemer", 40)
    ])

    day = report()
    assert cash(day, "a")["movements"]["received_cents"] == 105
    assert cash(day, "a")["movements"]["converted_to_credit_cents"] == 105
    assert day["credit"]["movements"]["issued_cents"] == 116
    assert report("2028-01-02")["credit"]["closing_liability_cents"] == 116
    expiry = report("2028-01-03")["credit"]
    assert expiry["opening_liability_cents"] == 116
    assert expiry["movements"]["expired_cents"] == 76
    assert expiry["closing_liability_cents"] == 40
    batch([cancel("restore-expired", "redeemer", %{}, "2028-02-01")])
    assert report("2028-02-01")["credit"]["movements"]["expired_cents"] == 40
    reconciles("2028-02-01")
  end

  test "opening includes applied expired credit, schedules available lots, and omits already expired availability" do
    batch([
      open("old"),
      pay("p-old", "old", 100),
      cancel("old-lot", "old", %{"refund_method" => "hotel_credit"}),
      open("active"),
      credit("apply-old", "active", 40),
      open("new"),
      pay("p-new", "new", 100),
      cancel("new-lot", "new", %{"refund_method" => "hotel_credit"}, "2028-01-01"),
      start("2028-02-01")
    ])

    assert report("2028-02-01")["credit"]["opening_liability_cents"] == 150
    assert report("2028-12-31")["credit"]["closing_liability_cents"] == 150
    assert report("2029-01-01")["credit"]["movements"]["expired_cents"] == 110
    reconciles("2029-01-01")
  end

  test "restored credit reschedules its original expiry and consumption removes applied liability" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("refundable"),
      open("nonrefundable", %{"rate_plan" => "advance_purchase"}),
      credit("a", "refundable", 70),
      credit("b", "nonrefundable", 40),
      cancel("restore", "refundable", %{}, "2027-01-03"),
      cancel("consume", "nonrefundable", %{}, "2027-01-03")
    ])

    assert report("2027-01-03")["credit"]["movements"]["consumed_cents"] == 40
    assert report("2027-01-03")["credit"]["closing_liability_cents"] == 70
    assert report("2028-01-03")["credit"]["movements"]["expired_cents"] == 70
    reconciles("2028-01-03")
  end

  test "shortfall restoration is absorbed before expiry and does not revoke applied liability" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("a"),
      open("b"),
      credit("apply", "a", 100),
      transfer("move", "a", "b", 100),
      correction("cb", "charge_back_payment", "p", %{}, "2027-01-03")
    ])

    day = report("2027-01-03")
    assert day["credit"]["movements"]["revoked_cents"] == 10
    assert day["credit"]["closing_liability_cents"] == 100
    batch([cancel("absorb", "b", %{}, "2028-02-01")])
    day = report("2028-02-01")
    assert day["credit"]["movements"]["absorbed_cents"] == 100
    assert day["credit"]["movements"]["expired_cents"] == 0
    reconciles("2028-02-01")
  end

  test "partial shortfall absorbs its entitlement and only the excess restoration expires" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 50),
      pay("q", "issuer", 50),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("a"),
      credit("redeem", "a", 110),
      correction("cb", "charge_back_payment", "p", %{}, "2027-01-03"),
      cancel("restore", "a", %{}, "2028-02-01")
    ])

    movements = report("2028-02-01")["credit"]["movements"]
    assert movements["absorbed_cents"] == 55
    assert movements["expired_cents"] == 55
    assert movements["revoked_cents"] == 0
    reconciles("2028-02-01")
  end

  test "posting clamped beyond expiry reconciles backdated issuance, redemption and restoration" do
    batch([
      open("issuer"),
      pay("p", "issuer", 100),
      start("2028-02-01"),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("a"),
      credit("redeem", "a", 40)
    ])

    credit = report("2028-02-01")["credit"]
    assert credit["movements"]["issued_cents"] == 110
    assert credit["movements"]["expired_cents"] == 70
    assert credit["closing_liability_cents"] == 40
    reconciles("2028-02-01")
    batch([cancel("restore", "a")])
    assert report("2028-02-01")["credit"]["movements"]["expired_cents"] == 110
    reconciles("2028-02-01")
  end

  test "expired unspent entitlement is not revoked twice" do
    batch([
      start(),
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      correction("cb", "charge_back_payment", "p", %{}, "2028-02-01")
    ])

    assert report("2028-01-03")["credit"]["movements"]["expired_cents"] == 110
    assert report("2028-02-01")["credit"]["movements"]["revoked_cents"] == 0
    reconciles("2028-02-01")
  end

  test "retries, conflicts, rejections and report read order leave movements unchanged" do
    operations = [
      start(),
      open("a"),
      pay("p", "a", 200),
      pay("rejected", "a", 200),
      pay("q", "a", 50)
    ]

    results = batch(operations)
    assert Enum.at(results, 3)["code"] == "payment_exceeds_outstanding"
    before = Repo.all(Movement)
    daily = report()
    future = report("2029-01-01")
    assert batch(operations) == results
    assert [%{"code" => "operation_id_conflict"}] = batch([pay("p", "a", 1)])
    assert report() == daily
    assert report("2029-01-01") == future
    assert Repo.all(Movement) == before
    reconciles("2027-01-02")
  end

  @tag :capture_log
  test "failed inception leaves no opening position or scheduled expiry" do
    batch([
      open("issuer"),
      pay("p", "issuer", 100),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"})
    ])

    Repo.query!("""
    CREATE TRIGGER fail_start_journal BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'start'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    assert_error_sent 500, fn -> batch([start()]) end
    assert Repo.get(GroupStay.Finance.Opening, 1) == nil
    assert Repo.all(Movement) == []
    assert GroupStay.Operations.get_result("start") == nil
    Repo.query!("DROP TRIGGER fail_start_journal")
    assert [%{"status" => "applied"}] = batch([start()])
    assert report()["credit"]["opening_liability_cents"] == 110
    assert report("2028-01-03")["credit"]["movements"]["expired_cents"] == 110
  end

  @tag :capture_log
  test "a journal fault rolls back reporting with the operation while retaining prior batch movements" do
    batch([start(), open("a")])

    Repo.query!("""
    CREATE TRIGGER fail_finance_journal BEFORE INSERT ON operations
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)

    operations = [pay("first", "a", 50), pay("fault", "a", 100), pay("last", "a", 10)]
    assert_error_sent 500, fn -> batch(operations) end
    assert cash(report(), "a")["closing_held_cents"] == 50
    assert GroupStay.Operations.get_result("fault") == nil
    assert GroupStay.Operations.get_result("last") == nil
    Repo.query!("DROP TRIGGER fail_finance_journal")
    assert Enum.all?(batch(operations), &(&1["status"] == "applied"))
    assert cash(report(), "a")["movements"]["received_cents"] == 160
    reconciles("2027-01-02")
  end
end
