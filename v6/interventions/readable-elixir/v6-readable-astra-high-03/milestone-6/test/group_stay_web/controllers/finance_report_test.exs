defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Finance.Entry

  test "validates dates and availability, with the exact empty report shape" do
    for query <- ["", "?date=bad", "?date=2026-02-30", "?date[]=2026-10-04"] do
      assert build_conn() |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert error_on("2026-10-04") == "report_not_available"

    for value <- [nil, "bad", "2026-02-30", 123, [], %{}] do
      assert [%{"code" => "invalid_reporting_date"}] = submit([start(value)])
    end

    missing = start() |> Map.delete("starts_on")
    assert [%{"code" => "invalid_reporting_date"}] = submit([missing])
    assert error_on("2026-10-04") == "report_not_available"

    assert [%{"status" => "applied"}] = submit([start()])
    assert error_on("2026-10-03") == "report_not_available"

    assert report("2026-10-04") == %{
             "date" => "2026-10-04",
             "status" => "open",
             "cash" => [],
             "credit" => credit(0, %{}, 0)
           }
  end

  test "inception uses commit order, ignores revision guards, and is durably idempotent" do
    inception = start() |> Map.put("expected_revision", -100)

    future_cash =
      operation("record_cash_payment", %{"amount_cents" => 1_000, "occurred_on" => "2027-01-01"})

    past_cash =
      operation("record_cash_payment", %{"amount_cents" => 500, "occurred_on" => "2026-09-01"})

    results = submit([open_group(), future_cash, inception, past_cash])

    assert Enum.at(results, 2) == %{
             "operation_id" => inception["operation_id"],
             "status" => "applied",
             "starts_on" => "2026-10-04"
           }

    assert report("2026-10-04")["cash"] == [
             cash("ams-canal", 1_000, %{"received_cents" => 500}, 1_500)
           ]

    assert report("2027-01-01")["cash"] == [cash("ams-canal", 1_500, %{}, 1_500)]
    entries = Repo.all(Entry)
    assert submit([inception]) == [Enum.at(results, 2)]

    assert [%{"code" => "operation_id_conflict"}] =
             submit([Map.put(inception, "starts_on", "2026-10-05")])

    assert [%{"code" => "reporting_already_started"}] = submit([start()])
    assert Repo.all(Entry) == entries
    assert Reservations.get_group("group-81").revision == 3

    assert build_conn()
           |> get("/api/v1/operations/#{inception["operation_id"]}")
           |> json_response(200) == %{"data" => Enum.at(results, 2)}
  end

  test "backdated postings update open reports, and retries and rejections create no movements" do
    submit([open_group(), start()])

    later =
      operation("record_cash_payment", %{"amount_cents" => 600, "occurred_on" => "2026-10-06"})

    first =
      operation("record_cash_payment", %{"amount_cents" => 200, "occurred_on" => "2026-10-05"})

    rejected =
      operation("record_cash_payment", %{"amount_cents" => 50_000, "occurred_on" => "2026-10-05"})

    assert [%{"status" => "applied"}] = submit([later])
    assert report("2026-10-05")["cash"] == []

    results =
      submit([
        first,
        rejected,
        operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"})
      ])

    assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "applied"]
    assert report("2026-10-05")["cash"] == [cash("ams-canal", 0, %{"received_cents" => 200}, 200)]
    expected = [cash("ams-canal", 200, %{"received_cents" => 600}, 800)]
    assert report("2026-10-06")["cash"] == expected
    entries = Repo.all(Entry)
    assert submit([first, rejected]) == Enum.take(results, 2)
    assert [%{"code" => "operation_id_conflict"}] = submit([Map.put(first, "amount_cents", 201)])
    assert report("2026-10-06")["cash"] == expected
    assert Repo.all(Entry) == entries
  end

  test "cash transfers and corrections follow held and settled properties with signed reversals" do
    submit([
      open_group(%{"property_id" => "zurich"}),
      open_group(%{"group_id" => "refund", "property_id" => "amsterdam"}),
      open_group(%{
        "group_id" => "retain",
        "property_id" => "berlin",
        "rate_plan" => "advance_purchase"
      }),
      open_group(%{"group_id" => "convert", "property_id" => "copenhagen"}),
      open_group(%{"group_id" => "unused", "property_id" => "unused"}),
      start(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 1_000}),
      transfer("group-81", "refund", 200),
      transfer("group-81", "retain", 100),
      transfer("group-81", "convert", 300),
      operation("cancel_group", %{"group_id" => "refund"}),
      operation("cancel_group", %{"group_id" => "retain"}),
      operation("cancel_group", %{"group_id" => "convert", "refund_method" => "hotel_credit"}),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 50
      })
    ])
    |> assert_applied()

    assert report("2026-10-04")["cash"] == [
             cash("amsterdam", 0, %{"transferred_in_cents" => 200, "refunded_cents" => 200}, 0),
             cash("berlin", 0, %{"transferred_in_cents" => 100, "retained_cents" => 100}, 0),
             cash(
               "copenhagen",
               0,
               %{"transferred_in_cents" => 300, "converted_to_credit_cents" => 300},
               0
             ),
             cash(
               "zurich",
               0,
               %{
                 "received_cents" => 1_000,
                 "transferred_out_cents" => 600,
                 "reduced_cents" => 50
               },
               350
             )
           ]

    assert report("2026-10-04")["credit"] == credit(0, %{"issued_cents" => 330}, 330)

    submit([
      operation("charge_back_payment", %{
        "payment_operation_id" => "payment",
        "occurred_on" => "2026-10-05"
      })
    ])
    |> assert_applied()

    assert report("2026-10-05")["cash"] == [
             cash("amsterdam", 0, %{"refunded_cents" => -200, "charged_back_cents" => 200}, 0),
             cash("berlin", 0, %{"retained_cents" => -100, "charged_back_cents" => 100}, 0),
             cash(
               "copenhagen",
               0,
               %{"converted_to_credit_cents" => -300, "charged_back_cents" => 300},
               0
             ),
             cash("zurich", 350, %{"charged_back_cents" => 350}, 0)
           ]

    assert report("2026-10-05")["credit"] == credit(330, %{"revoked_cents" => 330}, 0)
    assert report("2027-10-05")["credit"] == credit(0, %{}, 0)
    assert report("2026-10-06")["cash"] == []
    assert_reconciles("2026-10-05")
  end

  test "same-property transfers retain both columns and cross-property reductions follow reverse allocation order" do
    submit([
      open_group(),
      open_group(%{"group_id" => "same"}),
      open_group(%{"group_id" => "other", "property_id" => "berlin"}),
      start(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 500}),
      transfer("group-81", "same", 200),
      transfer("same", "other", 100),
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 150
      })
    ])
    |> assert_applied()

    assert report("2026-10-04")["cash"] == [
             cash(
               "ams-canal",
               0,
               %{
                 "received_cents" => 500,
                 "transferred_in_cents" => 200,
                 "transferred_out_cents" => 300,
                 "reduced_cents" => 50
               },
               350
             ),
             cash("berlin", 0, %{"transferred_in_cents" => 100, "reduced_cents" => 100}, 0)
           ]

    assert_reconciles("2026-10-04")
  end

  test "unused credit expires without operations and reads neither mutate nor depend on read order" do
    submit([
      open_group(),
      start(),
      operation("record_cash_payment", %{"amount_cents" => 105}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"})
    ])
    |> assert_applied()

    assert report("2026-10-04")["credit"] == credit(0, %{"issued_cents" => 116}, 116)
    assert report("2027-10-04")["credit"] == credit(116, %{}, 116)
    before = snapshot()
    expiry = report("2027-10-05")
    assert expiry["credit"] == credit(116, %{"expired_cents" => 116}, 0)
    report("2028-01-01")
    report("2026-10-04")
    assert report("2027-10-05") == expiry
    assert snapshot() == before
    assert_reconciles("2027-10-05")
  end

  test "inception includes applied credit and schedules only unused credit" do
    submit([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60}),
      start("2027-10-04")
    ])
    |> assert_applied()

    assert report("2027-10-04")["credit"] == credit(110, %{}, 110)
    assert report("2027-10-05")["credit"] == credit(110, %{"expired_cents" => 50}, 60)

    submit([operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-10-06"})])
    |> assert_applied()

    assert report("2027-10-06")["credit"] == credit(60, %{"expired_cents" => 60}, 0)
    assert_reconciles("2027-10-06")
  end

  test "applied and transferred credit pauses expiry and nonrefundable cancellation consumes it" do
    submit([
      open_group(),
      start(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      future_group("destination", %{"rate_plan" => "advance_purchase", "property_id" => "berlin"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100}),
      transfer("target", "destination", 60)
    ])
    |> assert_applied()

    assert report("2027-10-05")["credit"] == credit(110, %{"expired_cents" => 10}, 100)

    assert report("2026-10-04")["cash"] == [
             cash(
               "ams-canal",
               0,
               %{"received_cents" => 100, "converted_to_credit_cents" => 100},
               0
             )
           ]

    submit([
      operation("cancel_group", %{"group_id" => "destination", "occurred_on" => "2027-10-06"}),
      operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-10-06"})
    ])
    |> assert_applied()

    assert report("2027-10-06")["credit"] ==
             credit(100, %{"consumed_cents" => 60, "expired_cents" => 40}, 0)

    assert_reconciles("2027-10-06")
  end

  test "refundable restoration reschedules expiry without issuing another bonus" do
    submit([
      open_group(),
      start(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60}),
      operation("cancel_group", %{
        "group_id" => "target",
        "occurred_on" => "2026-10-05",
        "refund_method" => "hotel_credit"
      })
    ])
    |> assert_applied()

    assert report("2026-10-05")["credit"] == credit(110, %{}, 110)
    assert report("2027-10-05")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
  end

  test "clawback revokes unused entitlement, and restoration absorbs shortfall before expiry" do
    submit([
      open_group(),
      start(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
      operation("charge_back_payment", %{
        "payment_operation_id" => "payment",
        "occurred_on" => "2026-10-05"
      })
    ])
    |> assert_applied()

    assert report("2026-10-05")["credit"] == credit(110, %{"revoked_cents" => 30}, 80)
    assert Reservations.ledger(~D[2026-10-05]).credit_shortfall_cents == 80
    assert report("2027-10-05")["credit"] == credit(80, %{}, 80)

    submit([operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-10-06"})])
    |> assert_applied()

    assert report("2027-10-06")["credit"] == credit(80, %{"absorbed_cents" => 80}, 0)
    assert_reconciles("2027-10-06")
  end

  test "chargeback of expired unused credit does not revoke liability a second time" do
    submit([
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      start(),
      operation("charge_back_payment", %{
        "payment_operation_id" => "payment",
        "occurred_on" => "2027-10-06"
      })
    ])
    |> assert_applied()

    assert report("2027-10-05")["credit"] == credit(110, %{"expired_cents" => 110}, 0)
    assert report("2027-10-06")["credit"] == credit(0, %{}, 0)
    assert_reconciles("2027-10-06")
  end

  test "batch and sequential submissions produce the same reports across inception and expiry" do
    operations = [
      open_group(),
      operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
      start(),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60}),
      operation("charge_back_payment", %{
        "payment_operation_id" => "payment",
        "occurred_on" => "2026-10-06"
      }),
      operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-10-06"})
    ]

    Repo.query!("SAVEPOINT compare_submissions")
    batch_results = submit(operations)
    assert_applied(batch_results)
    dates = ["2026-10-04", "2026-10-05", "2026-10-06", "2027-10-05", "2027-10-06"]
    reports = Enum.map(dates, &report/1)
    Repo.query!("ROLLBACK TO SAVEPOINT compare_submissions")
    Repo.query!("RELEASE SAVEPOINT compare_submissions")
    assert Enum.flat_map(operations, &submit([&1])) == batch_results
    assert Enum.map(dates, &report/1) == reports
  end

  test "credit already expired at inception contributes only its applied liability" do
    submit([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60}),
      start("2027-10-06")
    ])
    |> assert_applied()

    assert report("2027-10-06")["credit"] == credit(60, %{}, 60)
    assert report("2027-10-07")["credit"] == credit(60, %{}, 60)
    assert_reconciles("2027-10-07")
  end

  test "a partial clawback absorbs restored credit and expires only the excess" do
    submit([
      open_group(),
      start(),
      operation("record_cash_payment", %{"operation_id" => "first", "amount_cents" => 50}),
      operation("record_cash_payment", %{"operation_id" => "second", "amount_cents" => 50}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100}),
      operation("charge_back_payment", %{
        "payment_operation_id" => "first",
        "occurred_on" => "2026-10-05"
      }),
      operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-10-06"})
    ])
    |> assert_applied()

    assert report("2026-10-05")["credit"] == credit(110, %{"revoked_cents" => 10}, 100)

    assert report("2027-10-06")["credit"] ==
             credit(100, %{"absorbed_cents" => 45, "expired_cents" => 55}, 0)

    assert_reconciles("2027-10-06")
  end

  test "credit issuance and redemption before inception are clamped to its posting date" do
    submit([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      start("2027-10-06"),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 60})
    ])
    |> assert_applied()

    assert report("2027-10-06")["credit"] ==
             credit(0, %{"issued_cents" => 110, "expired_cents" => 50}, 60)

    assert_reconciles("2027-10-06")
  end

  test "selected rooms settle their allocated cash and credit without affecting other rooms" do
    rooms = for id <- ["one", "two", "three"], do: %{"room_id" => id, "nightly_rate_cents" => 500}

    submit([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      future_group("target", %{"rooms" => rooms, "departure_on" => "2028-12-11"}),
      start(),
      operation("record_cash_payment", %{"group_id" => "target", "amount_cents" => 155}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      operation("cancel_rooms", %{
        "group_id" => "target",
        "room_ids" => ["two", "one"],
        "refund_method" => "hotel_credit"
      })
    ])
    |> assert_applied()

    assert report("2026-10-04")["cash"] == [
             cash(
               "ams-canal",
               0,
               %{"received_cents" => 155, "converted_to_credit_cents" => 155},
               0
             )
           ]

    assert report("2026-10-04")["credit"] == credit(110, %{"issued_cents" => 171}, 281)
    assert Reservations.get_group("target").credit_paid_cents == 65
    assert_reconciles("2026-10-04")
    assert report("2027-10-05")["credit"] == credit(281, %{"expired_cents" => 216}, 65)
  end

  test "a lot expiring on the last supported calendar date remains available through that date" do
    submit([
      open_group(%{"arrival_on" => "9999-12-30", "departure_on" => "9999-12-31"}),
      start("9998-12-31"),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{
        "refund_method" => "hotel_credit",
        "occurred_on" => "9998-12-31"
      })
    ])
    |> assert_applied()

    assert report("9999-12-31")["credit"] == credit(110, %{}, 110)
    assert_reconciles("9999-12-31")
  end

  defp start(date \\ "2026-10-04") do
    operation("start_finance_reporting", %{"starts_on" => date}) |> Map.delete("group_id")
  end

  defp future_group(id, extra \\ %{}) do
    open_group(
      Map.merge(
        %{"group_id" => id, "arrival_on" => "2028-12-10", "departure_on" => "2028-12-13"},
        extra
      )
    )
  end

  defp transfer(source, destination, amount) do
    operation("transfer_deposit", %{
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    })
  end

  defp submit(operations) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp assert_applied(results),
    do: assert(Enum.all?(results, &(&1["status"] == "applied")), inspect(results))

  defp report(date) do
    data =
      build_conn()
      |> get("/api/v1/finance/daily-report", %{"date" => date})
      |> json_response(200)
      |> Map.fetch!("data")

    Enum.each(data["cash"], fn row ->
      m = row["movements"]

      assert row["closing_held_cents"] ==
               row["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] - m["refunded_cents"] - m["retained_cents"] -
                 m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
    end)

    assert Enum.sum(Enum.map(data["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(data["cash"], & &1["movements"]["transferred_out_cents"]))

    c = data["credit"]
    m = c["movements"]

    assert c["closing_liability_cents"] ==
             c["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    data
  end

  defp error_on(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report", %{"date" => date})
    |> json_response(404)
    |> get_in(["error", "code"])
  end

  defp cash(property, opening, movements, closing) do
    defaults =
      Map.new(
        ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
        &{&1, 0}
      )

    %{
      "property_id" => property,
      "opening_held_cents" => opening,
      "movements" => Map.merge(defaults, movements),
      "closing_held_cents" => closing
    }
  end

  defp credit(opening, movements, closing) do
    defaults =
      Map.new(
        ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents),
        &{&1, 0}
      )

    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(defaults, movements),
      "closing_liability_cents" => closing
    }
  end

  defp assert_reconciles(date) do
    data = report(date)
    ledger = Reservations.ledger(Date.from_iso8601!(date))
    assert Enum.sum(Enum.map(data["cash"], & &1["closing_held_cents"])) == ledger.cash_held_cents
    assert data["credit"]["closing_liability_cents"] == ledger.credit_liability_cents
  end

  defp snapshot do
    for schema <- [
          Entry,
          GroupStay.Credit.Lot,
          GroupStay.Credit.Allocation,
          GroupStay.Reservations.Group,
          GroupStay.Operations.Operation
        ],
        do: Repo.all(schema)
  end
end
