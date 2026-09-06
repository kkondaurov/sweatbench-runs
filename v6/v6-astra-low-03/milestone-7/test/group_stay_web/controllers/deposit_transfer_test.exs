defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  defp op(type, attrs) do
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

    assert Enum.sum(
             for key <- ~w(held refunded retained converted_to_credit reduced charged_back),
                 do: statement[key <> "_cents"]
           ) == statement["recorded_cents"]

    statement
  end

  defp transfer(amount, attrs \\ %{}),
    do:
      op(
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => "g",
            "destination_group_id" => "d",
            "amount_cents" => amount
          },
          attrs
        )
      )

  test "mixed funding moves newest first, fills destination in draw order, and retries exactly" do
    batch([
      open("seed"),
      cash("seed-pay", 100, "seed"),
      op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open(),
      open("d"),
      cash("first", 50),
      op("apply_hotel_credit", %{"amount_cents" => 110}),
      cash("last", 100)
    ])

    money = ledger()

    operation =
      transfer(180, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 1,
        "occurred_on" => "2028-02-02"
      })

    result = run(operation)
    assert result["source_revision"] == 5
    assert result["destination_revision"] == 2
    assert result["source_outstanding_deposit_cents"] == 220
    assert result["destination_outstanding_deposit_cents"] == 120
    assert Enum.map(read("groups/g")["rooms"], & &1["cash_paid_cents"]) == [50, 0, 0]
    assert Enum.map(read("groups/g")["rooms"], & &1["credit_paid_cents"]) == [30, 0, 0]
    assert Enum.map(read("groups/d")["rooms"], & &1["cash_paid_cents"]) == [100, 0, 0]
    assert Enum.map(read("groups/d")["rooms"], & &1["credit_paid_cents"]) == [0, 80, 0]
    assert ledger() == money
    assert run(operation) == result
    assert read("operations/" <> operation["operation_id"]) == result
    assert run(Map.put(operation, "amount_cents", 1))["code"] == "operation_id_conflict"
    assert statement("last")["held_by_group"] == [%{"group_id" => "d", "amount_cents" => 100}]
    refute Map.has_key?(statement("first"), "held_by_group")

    assert run(op("cancel_group", %{"group_id" => "d", "occurred_on" => "2028-02-02"}))[
             "refunded_cents"
           ] == 100

    assert statement("last")["held_by_group"] == []
    assert read("ledger?on=2028-02-02")["credit_liability_cents"] == 30
  end

  test "reductions follow reverse allocation order across groups and guard original revision" do
    payment = cash("pay", 250)
    [_, _, original] = batch([open(), open("d"), payment])
    run(transfer(120))

    assert statement("pay")["held_by_group"] == [
             %{"group_id" => "d", "amount_cents" => 120},
             %{"group_id" => "g", "amount_cents" => 130}
           ]

    assert run(reduce("pay", 1, %{"expected_revision" => 2}))["code"] == "stale_revision"
    result = run(reduce("pay", 110, %{"expected_revision" => 3}))
    assert result["revision"] == 4
    assert read("groups/d")["revision"] == 3
    assert Enum.map(read("groups/d")["rooms"], & &1["cash_paid_cents"]) == [10, 0, 0]
    run(reduce("pay", 30))
    assert read("groups/g")["cash_paid_cents"] == 110
    assert read("groups/d")["revision"] == 4
    run(reduce("pay", 10))
    assert read("groups/d")["revision"] == 4
    assert run(payment) == original
    assert run(charge("pay"))["charged_back_cents"] == 100
    assert statement("pay")["held_by_group"] == []
    assert ledger()["cash_reduced_cents"] == 150
  end

  test "chargeback reclassifies destination settlements and revokes their credit" do
    batch([open(), open("d"), cash("pay", 300)])
    run(transfer(200))
    run(cancel(["a"]))

    run(
      op("cancel_rooms", %{
        "group_id" => "d",
        "room_ids" => ["a"],
        "refund_method" => "hotel_credit"
      })
    )

    run(
      op("cancel_rooms", %{"group_id" => "d", "room_ids" => ["b"], "occurred_on" => "2028-05-31"})
    )

    assert ledger()["cash_refunded_cents"] == 100
    assert ledger()["cash_retained_cents"] == 100
    assert ledger()["credit_liability_cents"] == 110
    revision = read("groups/d")["revision"]
    operation = charge("pay")
    result = run(operation)
    assert result["charged_back_cents"] == 300
    assert read("groups/d")["revision"] == revision + 1
    assert ledger()["cash_refunded_cents"] == 0
    assert ledger()["cash_retained_cents"] == 0
    assert ledger()["cash_converted_to_credit_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert run(operation) == result
    assert run(charge("pay"))["code"] == "payment_not_chargeable"
  end

  test "existence and revision checks precede transfer rules and failures are atomic" do
    batch([open(), open("d"), open("other", %{"guest_id" => "other"}), cash("pay", 100)])
    before = {read("groups/g"), read("groups/d"), ledger()}

    for {attrs, code, group} <- [
          {%{"source_group_id" => "missing", "destination_group_id" => "absent"},
           "group_not_found", "missing"},
          {%{"destination_group_id" => "absent", "expected_revision" => 0}, "group_not_found",
           "absent"},
          {%{"expected_revision" => 0, "destination_expected_revision" => 0}, "stale_revision",
           "g"},
          {%{"destination_expected_revision" => 0, "amount_cents" => -1}, "stale_revision", "d"},
          {%{"destination_group_id" => "g"}, "invalid_transfer", nil},
          {%{"destination_group_id" => "other"}, "invalid_transfer", nil},
          {%{"amount_cents" => 101}, "transfer_exceeds_held_funding", nil}
        ] do
      operation = transfer(1, attrs)
      result = run(operation)
      assert result["code"] == code
      if group, do: assert(result["group_id"] == group)
      assert run(operation) == result
      assert {read("groups/g"), read("groups/d"), ledger()} == before
    end

    for amount <- [0, -1, nil, 1.0, "1", true],
        do: assert(run(transfer(amount))["code"] == "invalid_amount")

    run(cash("dest", 300, "d"))
    assert run(transfer(1))["code"] == "transfer_exceeds_outstanding"
    run(op("cancel_group", %{"group_id" => "d"}))
    assert run(transfer(1))["group_id"] == "d"
    assert run(transfer(1))["code"] == "group_not_active"
  end

  test "transfer back creates new ordering, marks participation permanently, and failures roll back" do
    batch([open(), open("d"), cash("pay", 100)])
    operation = transfer(50)
    before = {read("groups/g"), read("groups/d"), statement("pay"), ledger()}

    GroupStay.Repo.query!(
      "CREATE TRIGGER fail_transfer BEFORE UPDATE ON groups WHEN NEW.group_id = 'd' BEGIN SELECT RAISE(ABORT, 'transfer fault'); END"
    )

    assert_raise Exqlite.Error, fn -> GroupStay.Reservations.batch([operation]) end
    assert GroupStay.Reservations.get_operation(operation["operation_id"]) == nil
    assert {read("groups/g"), read("groups/d"), statement("pay"), ledger()} == before
    GroupStay.Repo.query!("DROP TRIGGER fail_transfer")
    assert run(operation)["status"] == "applied"
    run(transfer(50, %{"source_group_id" => "d", "destination_group_id" => "g"}))
    assert statement("pay")["held_by_group"] == [%{"group_id" => "g", "amount_cents" => 100}]
    run(reduce("pay", 100))
    assert statement("pay")["held_by_group"] == []
  end

  test "transferred credit retains shortfall and destination policy controls settlement" do
    batch([
      open("seed"),
      cash("seed-pay", 100, "seed"),
      op("cancel_group", %{"group_id" => "seed", "refund_method" => "hotel_credit"}),
      open(),
      open("d", %{"rate_plan" => "advance_purchase"}),
      op("apply_hotel_credit", %{"amount_cents" => 110})
    ])

    run(charge("seed-pay"))
    before = ledger()
    run(transfer(60))
    assert ledger() == before
    assert ledger()["credit_shortfall_cents"] == 110
    assert run(op("cancel_group", %{"group_id" => "d"}))["credit_issued_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 50
    assert ledger()["credit_liability_cents"] == 50
    run(op("cancel_group", %{}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert read("guests/guest/credit?on=2027-02-01")["available_cents"] == 0
  end
end
