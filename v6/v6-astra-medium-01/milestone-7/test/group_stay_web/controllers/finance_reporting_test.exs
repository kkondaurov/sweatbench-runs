defmodule GroupStayWeb.FinanceReportingTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixture
  require Ecto.Query
  alias GroupStay.{Repo, Reservations}

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{operations: ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp start(on \\ "2027-05-02"),
    do:
      operation("start", "start_finance_reporting", %{"starts_on" => on})
      |> Map.delete("group_id")

  defp pay(id, amount, attrs \\ %{}),
    do: operation(id, "record_cash_payment", Map.merge(%{"amount_cents" => amount}, attrs))

  defp report(on) do
    data =
      build_conn()
      |> get("/api/v1/finance/daily-report?date=" <> on)
      |> json_response(200)
      |> Map.fetch!("data")

    for c <- data["cash"] do
      m = c["movements"]

      assert c["closing_held_cents"] ==
               c["opening_held_cents"] + m["received_cents"] + m["transferred_in_cents"] -
                 m["transferred_out_cents"] -
                 Enum.sum(
                   for k <-
                         ~w(refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                       do: m[k]
                 )

      assert map_size(c) == 4
      assert map_size(m) == 8
    end

    credit = data["credit"]
    m = credit["movements"]

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + m["issued_cents"] - m["expired_cents"] -
               m["consumed_cents"] - m["revoked_cents"] - m["absorbed_cents"]

    assert map_size(credit) == 3
    assert map_size(m) == 5
    data
  end

  test "validates dates, freezes inception in batch order, and replays starts and rejections" do
    for query <- ["", "?date=bad", "?date=2027-02-29", "?date[]=2027-05-02"] do
      assert build_conn() |> get("/api/v1/finance/daily-report" <> query) |> json_response(422) ==
               %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-05-02")
           |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

    for {value, id} <- [{nil, "nil"}, {"bad", "bad"}, {20, "integer"}] do
      assert [%{"code" => "invalid_reporting_date"}] =
               batch([start(value) |> Map.put("operation_id", id)])
    end

    assert [%{"code" => "invalid_reporting_date"}] = batch([start() |> Map.delete("starts_on")])

    initial =
      start() |> Map.put("operation_id", "valid-start") |> Map.put("expected_revision", -1)

    results =
      batch([
        opening(),
        pay("before", 1000, %{"occurred_on" => "2030-01-01"}),
        initial,
        pay("after", 500, %{"occurred_on" => "2026-01-01"})
      ])

    assert Enum.at(results, 2) == %{
             "operation_id" => "valid-start",
             "status" => "applied",
             "starts_on" => "2027-05-02"
           }

    assert batch([initial]) == [Enum.at(results, 2)]

    assert [%{"code" => "reporting_already_started"}] =
             batch([start() |> Map.put("operation_id", "second")])

    assert [%{"code" => "operation_id_conflict"}] =
             batch([Map.put(initial, "starts_on", "2027-05-03")])

    assert [%{"code" => "invalid_reporting_date"}] = batch([start() |> Map.delete("starts_on")])

    assert [
             %{
               "opening_held_cents" => 1000,
               "closing_held_cents" => 1500,
               "movements" => %{"received_cents" => 500}
             }
           ] = report("2027-05-02")["cash"]

    assert [%{"opening_held_cents" => 1500, "closing_held_cents" => 1500}] =
             report("2027-05-03")["cash"]

    assert build_conn()
           |> get("/api/v1/finance/daily-report?date=2027-05-01")
           |> json_response(404)
  end

  test "transfers and corrections follow the holding and settlement properties" do
    batch([
      opening(),
      Map.put(opening("other", "other"), "property_id", "another"),
      start(),
      pay("p", 1000)
    ])

    transfer =
      operation("t", "transfer_deposit", %{
        "source_group_id" => "group",
        "destination_group_id" => "other",
        "amount_cents" => 600
      })

    batch([
      transfer,
      operation("refund", "cancel_group", %{"group_id" => "other", "occurred_on" => "2027-05-01"})
    ])

    correction =
      operation("cb", "charge_back_payment", %{
        "payment_operation_id" => "p",
        "occurred_on" => "2027-05-03"
      })

    batch([correction])
    [other, original] = report("2027-05-02")["cash"]
    assert other["property_id"] == "another"
    assert other["movements"]["transferred_in_cents"] == 600
    assert other["movements"]["refunded_cents"] == 600
    assert original["movements"]["transferred_out_cents"] == 600
    [other, original] = report("2027-05-03")["cash"]
    assert other["movements"]["refunded_cents"] == -600
    assert other["movements"]["charged_back_cents"] == 600
    assert original["movements"]["charged_back_cents"] == 400
    assert original["closing_held_cents"] == 0
    before = report("2027-05-03")
    batch([correction, transfer, pay("bad", 10000)])
    assert report("2027-05-03") == before
    assert report("2027-05-04")["cash"] == []
  end

  test "credit expiry is scheduled without writes and application pauses expiry" do
    batch([
      opening(),
      start(),
      pay("p", 1000),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("other", "other"),
      operation("apply", "apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 500})
    ])

    assert report("2027-05-02")["credit"]["movements"]["issued_cents"] == 1100
    assert report("2028-05-01")["credit"]["closing_liability_cents"] == 1100
    assert report("2028-05-02")["credit"]["movements"]["expired_cents"] == 600
    assert report("2028-05-02")["credit"]["closing_liability_cents"] == 500

    batch([
      operation("move", "reschedule_group", %{
        "group_id" => "other",
        "new_arrival_on" => "2028-08-01"
      }),
      operation("restore", "cancel_group", %{"group_id" => "other", "occurred_on" => "2028-05-03"})
    ])

    assert report("2028-05-03")["credit"]["movements"]["expired_cents"] == 500

    assert report("2028-05-03")["credit"]["closing_liability_cents"] ==
             Reservations.ledger(~D[2028-05-03]).credit_liability_cents

    count = Repo.one(Ecto.Query.from(m in "finance_movements", select: count(m.id)))
    expected = report("2028-05-03")
    report("2027-05-02")
    report("2030-01-01")
    assert report("2028-05-03") == expected
    assert Repo.one(Ecto.Query.from(m in "finance_movements", select: count(m.id))) == count
  end

  test "clawback revokes available credit and restoration absorbs shortfall before expiry" do
    batch([
      opening(),
      pay("p", 1000),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("other", "other"),
      operation("apply", "apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 1000}),
      start(),
      operation("cb", "charge_back_payment", %{"payment_operation_id" => "p"})
    ])

    credit = report("2027-05-02")["credit"]
    assert credit["opening_liability_cents"] == 1100
    assert credit["movements"]["revoked_cents"] == 100
    assert credit["closing_liability_cents"] == 1000

    batch([
      operation("move", "reschedule_group", %{
        "group_id" => "other",
        "new_arrival_on" => "2028-08-01"
      }),
      operation("restore", "cancel_group", %{"group_id" => "other", "occurred_on" => "2028-05-03"})
    ])

    assert report("2028-05-02")["credit"]["movements"]["expired_cents"] == 0
    credit = report("2028-05-03")["credit"]
    assert credit["movements"]["absorbed_cents"] == 1000
    assert credit["movements"]["expired_cents"] == 0
    assert credit["closing_liability_cents"] == 0
  end

  test "same-property transfers, reductions and nonrefundable consumption reconcile" do
    batch([
      opening(),
      pay("seed", 1000),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("a", "a"),
      opening("b", "b"),
      start(),
      pay("p", 1000, %{"group_id" => "a"}),
      operation("use", "apply_hotel_credit", %{"group_id" => "a", "amount_cents" => 1100}),
      operation("t", "transfer_deposit", %{
        "source_group_id" => "a",
        "destination_group_id" => "b",
        "amount_cents" => 1500
      }),
      operation("reduce", "reduce_cash_payment", %{
        "payment_operation_id" => "p",
        "amount_cents" => 500
      }),
      operation("cancel", "cancel_group", %{"group_id" => "b", "occurred_on" => "2027-05-03"})
    ])

    [cash] = report("2027-05-02")["cash"]
    assert cash["movements"]["transferred_in_cents"] == 400
    assert cash["movements"]["transferred_out_cents"] == 400
    assert cash["movements"]["reduced_cents"] == 500
    credit = report("2027-05-03")["credit"]
    assert credit["movements"]["consumed_cents"] == 1100
    assert credit["closing_liability_cents"] == 0
    [cash] = report("2027-05-03")["cash"]
    assert cash["closing_held_cents"] == Reservations.ledger(~D[2027-05-03]).cash_held_cents
    assert report("2028-05-02")["credit"]["movements"]["expired_cents"] == 0
  end

  test "late backdated submissions revise open reports and expired credit is not revoked twice" do
    batch([
      opening(),
      start(),
      pay("p", 1000),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"})
    ])

    assert report("2028-05-02")["credit"]["movements"]["expired_cents"] == 1100

    batch([
      operation("cb", "charge_back_payment", %{
        "payment_operation_id" => "p",
        "occurred_on" => "2028-05-03"
      })
    ])

    assert report("2028-05-03")["credit"]["movements"]["revoked_cents"] == 0
    assert report("2028-05-02")["credit"]["movements"]["expired_cents"] == 1100

    batch([
      opening("new", "new"),
      pay("future", 100, %{"group_id" => "new", "occurred_on" => "2027-06-01"})
    ])

    assert report("2027-05-03")["cash"] == []
    batch([pay("late", 200, %{"group_id" => "new", "occurred_on" => "2027-05-03"})])
    assert [%{"closing_held_cents" => 200}] = report("2027-05-03")["cash"]

    assert [%{"opening_held_cents" => 200, "closing_held_cents" => 300}] =
             report("2027-06-01")["cash"]
  end

  test "batch and sequential submissions yield identical reports" do
    ops = [
      opening(),
      pay("p", 1000),
      start(),
      operation("issue", "cancel_group", %{"refund_method" => "hotel_credit"}),
      opening("other", "other"),
      operation("use", "apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 200}),
      operation("bad", "record_cash_payment", %{"amount_cents" => 9000})
    ]

    dates = ~w(2027-05-02 2027-05-03 2028-05-02)

    {:error, expected} =
      Repo.transaction(fn ->
        batch(ops)
        Repo.rollback(Enum.map(dates, &report/1))
      end)

    Enum.each(ops, &batch([&1]))
    assert Enum.map(dates, &report/1) == expected
  end
end
