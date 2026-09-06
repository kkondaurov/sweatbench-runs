defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "group_id" => "g",
        "occurred_on" => "2027-02-01"
      },
      attrs
    )
  end

  defp open(id \\ "g", attrs \\ %{}) do
    op(
      "open_group",
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => "hotel",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-02",
          "rate_plan" => "flexible",
          "rooms" => Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{operations: ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp run(op), do: hd(batch([op]))

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp cash(id, amount, group \\ "g"),
    do:
      op("record_cash_payment", %{
        "operation_id" => id,
        "amount_cents" => amount,
        "group_id" => group
      })

  defp cancel(ids, attrs \\ %{}), do: op("cancel_rooms", Map.merge(%{"room_ids" => ids}, attrs))

  defp reduce(payment, amount, attrs \\ %{}),
    do:
      op(
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => payment, "amount_cents" => amount}, attrs)
      )
      |> Map.delete("group_id")

  defp charge(payment, attrs \\ %{}),
    do:
      op("charge_back_payment", Map.merge(%{"payment_operation_id" => payment}, attrs))
      |> Map.delete("group_id")

  defp ledger, do: read("ledger?on=2027-02-01")

  defp statement(id) do
    statement = read("payments/" <> id)
    assert map_size(statement) == 9

    assert Enum.sum(
             for key <- ~w(held refunded retained converted_to_credit reduced charged_back),
                 do: statement[key <> "_cents"]
           ) == statement["recorded_cents"]

    statement
  end

  test "partial cancellation and successive reductions preserve room order and original payment results" do
    payment = cash("pay", 250)
    [_, original] = batch([open(), payment])
    assert Enum.map(read("groups/g")["rooms"], & &1["cash_paid_cents"]) == [100, 100, 50]
    reduction = reduce("pay", 70, %{"expected_revision" => 2})
    result = run(reduction)
    assert result["outstanding_deposit_cents"] == 120
    assert result["revision"] == 3
    assert Enum.map(read("groups/g")["rooms"], & &1["cash_paid_cents"]) == [100, 80, 0]
    assert run(reduction) == result
    settled = run(cancel(["c", "a"]))
    assert settled["cancelled_room_ids"] == ["a", "c"]
    assert settled["refunded_cents"] == 100
    group = read("groups/g")
    assert group["status"] == "active"
    assert group["lodging_total_cents"] == 500
    assert group["deposit_due_cents"] == 100
    assert group["outstanding_deposit_cents"] == 20
    assert statement("pay")["held_cents"] == 80
    assert run(reduce("pay", 81))["code"] == "reduction_exceeds_held_cash"
    assert run(reduce("pay", 80))["amount_cents"] == 80
    assert run(reduce("pay", 1))["code"] == "payment_not_reducible"
    assert run(payment) == original
    assert read("operations/pay") == original
    assert statement("pay")["reduced_cents"] == 150
    assert ledger()["cash_reduced_cents"] == 150
    assert run(op("cancel_group"))["refunded_cents"] == 0
    assert read("groups/g")["status"] == "cancelled"
    assert read("groups/g")["lodging_total_cents"] == 0
  end

  test "room validation is atomic and revisions precede domain validation" do
    batch([open(), cash("pay", 100)])

    for ids <- [[], ["a", "a"], ["a", "missing"], nil, "a", [1]] do
      before = read("groups/g")
      assert run(cancel(ids))["code"] == "invalid_rooms"
      assert read("groups/g") == before
    end

    stale = cancel([], %{"expected_revision" => 1})
    result = run(stale)
    assert result["code"] == "stale_revision"
    run(cancel(["a"]))
    assert run(stale) == result
    assert run(Map.put(stale, "expected_revision", 3))["code"] == "operation_id_conflict"
    assert run(cancel(["a", "b"]))["code"] == "invalid_rooms"
    assert run(reduce("pay", -1, %{"expected_revision" => 2}))["code"] == "stale_revision"
    assert run(charge("pay", %{"expected_revision" => 2}))["code"] == "stale_revision"
    assert read("groups/g")["revision"] == 3
  end

  test "payment target errors, amounts, and reconciliation errors are durable" do
    missing = reduce("later", 1)
    assert run(missing)["code"] == "operation_not_found"
    opening = open()
    batch([opening, cash("later", 10)])
    assert run(missing)["code"] == "operation_not_found"
    rejected = cash("bad", 1000)
    run(rejected)

    for target <- [opening["operation_id"], "bad"] do
      assert run(reduce(target, 1))["code"] == "payment_not_reducible"
      assert run(charge(target))["code"] == "payment_not_chargeable"

      assert build_conn() |> get("/api/v1/payments/" <> target) |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    assert run(charge("missing"))["code"] == "operation_not_found"

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for amount <- [0, -1, nil, 1.0, "1", true] do
      assert run(reduce("later", amount))["code"] == "invalid_amount"
    end

    assert run(reduce("later", 10))["status"] == "applied"
    assert run(charge("later"))["code"] == "payment_not_chargeable"
    assert statement("later")["reduced_cents"] == 10
  end

  test "chargebacks reclassify held refunded retained and reduced cash exactly once" do
    payment = cash("pay", 300)
    [_, original] = batch([open(), payment])
    run(cancel(["a"]))
    run(cancel(["b"], %{"occurred_on" => "2028-05-31"}))
    run(reduce("pay", 25))
    before = statement("pay")
    assert before["held_cents"] == 75
    assert before["refunded_cents"] == 100
    assert before["retained_cents"] == 100
    operation = charge("pay", %{"expected_revision" => 5})
    result = run(operation)
    assert result["charged_back_cents"] == 275
    assert result["outstanding_deposit_cents"] == 100
    assert result["revision"] == 6
    assert run(operation) == result
    assert run(charge("pay"))["code"] == "payment_not_chargeable"
    assert run(payment) == original
    assert statement("pay")["charged_back_cents"] == 275
    assert ledger()["cash_refunded_cents"] == 0
    assert ledger()["cash_retained_cents"] == 0
    assert ledger()["cash_held_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 275
    assert ledger()["cash_reduced_cents"] == 25
  end

  test "mixed funding fills rooms in processing order and settlement does not refill other rooms" do
    batch([
      open("source"),
      cash("source-pay", 100, "source"),
      op("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      cash("first", 50),
      op("apply_hotel_credit", %{"amount_cents" => 110}),
      cash("last", 100)
    ])

    rooms = read("groups/g")["rooms"]
    assert Enum.map(rooms, & &1["cash_paid_cents"]) == [50, 40, 60]
    assert Enum.map(rooms, & &1["credit_paid_cents"]) == [50, 60, 0]
    assert run(cancel(["b"]))["refunded_cents"] == 40
    assert Enum.at(read("groups/g")["rooms"], 2) == Enum.at(rooms, 2)
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 60
    assert run(reduce("last", 60))["status"] == "applied"
    assert statement("last")["refunded_cents"] == 40
    run(op("cancel_group", %{"refund_method" => "hotel_credit"}))
    assert ledger()["credit_liability_cents"] == 165
  end

  test "combined bonus and running payment entitlements telescope in funding order" do
    # 5 + 5 cash produces 11 credit; the senior payment owns 6 and the junior owns 5.
    batch([open(), cash("z-first", 5), cash("a-second", 5)])

    assert run(cancel(["c", "a"], %{"refund_method" => "hotel_credit"}))["credit_issued_cents"] ==
             11

    assert run(charge("a-second"))["charged_back_cents"] == 5
    assert ledger()["credit_liability_cents"] == 6
    assert run(charge("z-first"))["charged_back_cents"] == 5
    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 10
  end

  test "clawback removes available credit then tracks shortfall without revising funded groups" do
    batch([
      open("source"),
      cash("pay", 100, "source"),
      op("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      op("apply_hotel_credit", %{"amount_cents" => 100})
    ])

    before = read("groups/g")
    assert run(charge("pay"))["charged_back_cents"] == 100
    assert read("groups/g") == before
    assert ledger()["credit_liability_cents"] == 100
    assert ledger()["credit_shortfall_cents"] == 100
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 0
    run(cancel(["a"]))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 0
  end

  test "restorations absorb shortfall before expiry and only excess credit returns" do
    batch([
      open("source"),
      cash("p1", 50, "source"),
      cash("p2", 50, "source"),
      op("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      op("apply_hotel_credit", %{"amount_cents" => 110})
    ])

    run(charge("p1"))
    assert ledger()["credit_shortfall_cents"] == 55
    run(cancel(["a"]))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 55
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 45
    run(cancel(["b"], %{"occurred_on" => "2028-02-02"}))
    assert read("ledger?on=2028-02-02")["credit_liability_cents"] == 0
  end

  test "nonrefundable credit consumption reduces shortfall and expired restoration absorbs clawback" do
    for {id, cancellation_date} <- [{"late", "2028-05-31"}, {"expired", "2028-02-02"}] do
      source = "source-" <> id
      payment = "pay-" <> id

      batch([
        open(source),
        cash(payment, 100, source),
        op("cancel_group", %{"group_id" => source, "refund_method" => "hotel_credit"}),
        open(id),
        op("apply_hotel_credit", %{"group_id" => id, "amount_cents" => 110})
      ])

      run(charge(payment))
      assert ledger()["credit_shortfall_cents"] == 110
      run(op("cancel_group", %{"group_id" => id, "occurred_on" => cancellation_date}))
      assert ledger()["credit_shortfall_cents"] == 0
      assert ledger()["credit_liability_cents"] == 0
    end
  end

  test "one payment contributes to multiple independently rounded lots and charges back all dispositions" do
    rooms = Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 25})
    batch([open("g", %{"rooms" => rooms}), cash("pay", 15)])
    first = cancel(["b", "a"], %{"refund_method" => "hotel_credit"})
    result = run(first)
    assert result["credit_issued_cents"] == 11
    assert run(first) == result
    assert run(cancel(["c"], %{"refund_method" => "hotel_credit"}))["credit_issued_cents"] == 6
    assert ledger()["credit_liability_cents"] == 17
    assert run(charge("pay"))["charged_back_cents"] == 15
    assert statement("pay")["charged_back_cents"] == 15
    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 0
  end

  test "shortfall is capped by still-applied credit, even after irreversible spending" do
    batch([
      open("source"),
      cash("pay", 100, "source"),
      op("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open(),
      op("apply_hotel_credit", %{"amount_cents" => 110})
    ])

    run(cancel(["a"], %{"occurred_on" => "2028-05-31"}))
    run(charge("pay"))
    assert ledger()["credit_shortfall_cents"] == 10
    assert ledger()["credit_liability_cents"] == 10
    run(cancel(["b"]))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "an unexpected clawback failure rolls back cash, credit, revisions, and the durable record" do
    batch([open(), cash("pay", 100), op("cancel_group", %{"refund_method" => "hotel_credit"})])
    before = statement("pay")
    group = read("groups/g")
    money = ledger()
    charge = charge("pay")

    GroupStay.Repo.query!(
      "CREATE TRIGGER fail_clawback BEFORE UPDATE ON credit_lots BEGIN SELECT RAISE(ABORT, 'clawback fault'); END"
    )

    assert_raise Exqlite.Error, fn -> GroupStay.Reservations.batch([charge]) end
    assert GroupStay.Reservations.get_operation(charge["operation_id"]) == nil
    assert statement("pay") == before
    assert read("groups/g") == group
    assert ledger() == money
    GroupStay.Repo.query!("DROP TRIGGER fail_clawback")
    assert run(charge)["charged_back_cents"] == 100
  end
end
