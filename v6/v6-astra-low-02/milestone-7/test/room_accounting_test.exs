defmodule GroupStay.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  alias GroupStay.{Reservations, Repo, Group, CreditLot}

  defp op(type, fields \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "occurred_on" => "2026-10-01",
        "group_id" => "g"
      },
      fields
    )
  end

  defp open(id \\ "g", rates \\ [100, 100, 100]) do
    op("open_group", %{
      "group_id" => id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-02",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.with_index(rates, fn rate, i ->
          %{"room_id" => "r#{i}", "nightly_rate_cents" => rate}
        end)
    })
  end

  defp run(operations), do: Reservations.batch(List.wrap(operations))

  defp apply!(operation) do
    [result] = run(operation)
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp payment(id) do
    data =
      build_conn() |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

    assert Map.keys(data) |> Enum.sort() ==
             Enum.sort(
               ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
             )

    assert Enum.sum(
             for key <- ~w(held refunded retained converted_to_credit reduced charged_back),
                 do: data[key <> "_cents"]
           ) == data["recorded_cents"]

    data
  end

  defp ledger, do: Reservations.ledger(~D[2026-10-01])

  test "partial settlement, reverse reductions, replacement funding and exact retries reconcile" do
    apply!(open())
    pay = op("record_cash_payment", %{"amount_cents" => 50})
    original = apply!(pay)
    cancel = op("cancel_rooms", %{"room_ids" => ["r1"]})
    assert apply!(cancel)["refunded_cents"] == 20

    reduction =
      op("reduce_cash_payment", %{
        "payment_operation_id" => pay["operation_id"],
        "amount_cents" => 15,
        "expected_revision" => 3
      })

    reduced = apply!(reduction)
    assert reduced["outstanding_deposit_cents"] == 25
    assert reduced["revision"] == 4
    assert Enum.map(Reservations.get_group("g").rooms, & &1["cash_paid_cents"]) == [15, 0, 0]
    apply!(op("record_cash_payment", %{"amount_cents" => 10}))
    assert Enum.map(Reservations.get_group("g").rooms, & &1["cash_paid_cents"]) == [20, 0, 5]

    assert payment(pay["operation_id"]) == %{
             "payment_operation_id" => pay["operation_id"],
             "original_group_id" => "g",
             "recorded_cents" => 50,
             "held_cents" => 15,
             "refunded_cents" => 20,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 15,
             "charged_back_cents" => 0
           }

    assert run([pay, reduction]) == [original, reduced]
    assert apply!(op("cancel_group"))["refunded_cents"] == 25
    assert Reservations.get_group("g").lodging_total_cents == 0
    assert ledger().cash_refunded_cents == 45
    assert ledger().cash_reduced_cents == 15
  end

  test "invalid selections are atomic and revision checks precede domain validation" do
    apply!(open())
    apply!(op("record_cash_payment", %{"amount_cents" => 45}))
    before = Reservations.get_group("g")

    for ids <- [[], nil, "r0", ["r0", "r0"], ["r0", "missing"]] do
      assert [%{"code" => "invalid_rooms"}] = run(op("cancel_rooms", %{"room_ids" => ids}))
      assert Reservations.get_group("g") == before
    end

    assert [%{"code" => "stale_revision"}] =
             run(op("cancel_rooms", %{"room_ids" => [], "expected_revision" => 1}))

    assert apply!(
             op("cancel_rooms", %{"room_ids" => ["r2", "r0"], "refund_method" => "hotel_credit"})
           )["credit_issued_cents"] == 28

    assert Reservations.get_group("g").deposit_due_cents == 20
    assert Reservations.get_group("g").lodging_total_cents == 100
    assert [%{"code" => "invalid_rooms"}] = run(op("cancel_rooms", %{"room_ids" => ["r0"]}))
    result = apply!(op("cancel_rooms", %{"room_ids" => ["r1"]}))
    assert result["cancelled_room_ids"] == ["r1"]
    assert Reservations.get_group("g").status == "cancelled"
  end

  test "payment errors, full reduction and stored rejections" do
    apply!(open())
    pay = op("record_cash_payment", %{"amount_cents" => 10})
    apply!(pay)

    for {amount, code} <- [
          {0, "invalid_amount"},
          {-1, "invalid_amount"},
          {1.5, "invalid_amount"},
          {11, "reduction_exceeds_held_cash"}
        ] do
      assert [%{"code" => ^code}] =
               run(
                 op("reduce_cash_payment", %{
                   "payment_operation_id" => pay["operation_id"],
                   "amount_cents" => amount
                 })
               )
    end

    assert [%{"code" => "stale_revision"}] =
             run(
               op("reduce_cash_payment", %{
                 "payment_operation_id" => pay["operation_id"],
                 "amount_cents" => -1,
                 "expected_revision" => 1
               })
             )

    apply!(
      op("reduce_cash_payment", %{
        "payment_operation_id" => pay["operation_id"],
        "amount_cents" => 10
      })
    )

    assert [%{"code" => "payment_not_reducible"}] =
             run(
               op("reduce_cash_payment", %{
                 "payment_operation_id" => pay["operation_id"],
                 "amount_cents" => 1
               })
             )

    assert [%{"code" => "payment_not_chargeable"}] =
             run(op("charge_back_payment", %{"payment_operation_id" => pay["operation_id"]}))

    assert payment(pay["operation_id"])["reduced_cents"] == 10
    absent = op("reduce_cash_payment", %{"payment_operation_id" => "absent", "amount_cents" => 1})
    [rejected] = run(absent)
    assert rejected["code"] == "operation_not_found"
    apply!(op("record_cash_payment", %{"operation_id" => "absent", "amount_cents" => 1}))
    assert run(absent) == [rejected]
    nonpayment = op("reschedule_group", %{"new_arrival_on" => "2027-04-01"})
    apply!(nonpayment)
    badpay = op("record_cash_payment", %{"amount_cents" => -1})
    run(badpay)

    for id <- [nonpayment["operation_id"], badpay["operation_id"]] do
      assert build_conn() |> get("/api/v1/payments/#{id}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert [%{"code" => "payment_not_chargeable"}] =
               run(op("charge_back_payment", %{"payment_operation_id" => id}))

      assert [%{"code" => "payment_not_reducible"}] =
               run(
                 op("reduce_cash_payment", %{"payment_operation_id" => id, "amount_cents" => 1})
               )
    end

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "chargeback reclassifies every disposition without touching original result" do
    apply!(open("g", [100, 100, 100, 100]))
    pay = op("record_cash_payment", %{"amount_cents" => 80})
    original = apply!(pay)
    apply!(op("cancel_rooms", %{"room_ids" => ["r0"]}))
    apply!(op("cancel_rooms", %{"room_ids" => ["r1"], "occurred_on" => "2027-03-01"}))
    apply!(op("cancel_rooms", %{"room_ids" => ["r2"], "refund_method" => "hotel_credit"}))

    apply!(
      op("reduce_cash_payment", %{
        "payment_operation_id" => pay["operation_id"],
        "amount_cents" => 5
      })
    )

    assert payment(pay["operation_id"])["held_cents"] == 15

    charge =
      op("charge_back_payment", %{
        "payment_operation_id" => pay["operation_id"],
        "expected_revision" => 6
      })

    result = apply!(charge)
    assert result["charged_back_cents"] == 75
    assert result["outstanding_deposit_cents"] == 20
    assert payment(pay["operation_id"])["charged_back_cents"] == 75
    assert ledger().cash_refunded_cents == 0
    assert ledger().cash_retained_cents == 0
    assert ledger().cash_converted_to_credit_cents == 0
    assert ledger().cash_charged_back_cents == 75
    assert ledger().credit_liability_cents == 0
    assert run([pay, charge]) == [original, result]

    assert [%{"code" => "payment_not_chargeable"}] =
             run(op("charge_back_payment", %{"payment_operation_id" => pay["operation_id"]}))
  end

  test "fungible entitlements telescope and returned credit absorbs shortfall before expiry" do
    apply!(open("g", [100]))
    first = op("record_cash_payment", %{"amount_cents" => 5})
    second = op("record_cash_payment", %{"amount_cents" => 5})
    apply!(first)
    apply!(second)
    apply!(op("cancel_group", %{"refund_method" => "hotel_credit"}))
    [lot] = Repo.all(CreditLot)
    assert lot.entitlements == %{first["operation_id"] => 6, second["operation_id"] => 5}
    apply!(open("next", [100, 100]))
    apply!(op("apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 8}))
    before = Repo.get!(Group, "next")
    apply!(op("charge_back_payment", %{"payment_operation_id" => first["operation_id"]}))
    assert Repo.get!(Group, "next") == before
    assert ledger().credit_shortfall_cents == 3
    assert ledger().credit_liability_cents == 8
    assert Reservations.guest_credit("guest", ~D[2026-10-01]).available_cents == 0
    apply!(op("charge_back_payment", %{"payment_operation_id" => second["operation_id"]}))
    assert ledger().credit_shortfall_cents == 8
    apply!(op("reschedule_group", %{"group_id" => "next", "new_arrival_on" => "2028-03-01"}))
    apply!(op("cancel_group", %{"group_id" => "next", "occurred_on" => "2027-10-02"}))
    assert Reservations.ledger(~D[2027-10-02]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2027-10-02]).credit_liability_cents == 0
    assert Repo.get!(CreditLot, lot.id).unrecovered_clawback_cents == 0
    assert payment(first["operation_id"])["charged_back_cents"] == 5
  end

  test "nonrefundable credit consumption lowers shortfall and mixed credit allocations stay on their rooms" do
    apply!(open("source", [1000]))
    pay = op("record_cash_payment", %{"group_id" => "source", "amount_cents" => 100})
    apply!(pay)
    apply!(op("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}))
    apply!(open())
    apply!(op("apply_hotel_credit", %{"amount_cents" => 30}))
    apply!(op("record_cash_payment", %{"amount_cents" => 30}))

    assert Enum.map(
             Reservations.get_group("g").rooms,
             &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
           ) == [{0, 20}, {10, 10}, {20, 0}]

    apply!(op("charge_back_payment", %{"payment_operation_id" => pay["operation_id"]}))
    assert ledger().credit_shortfall_cents == 30

    assert apply!(op("cancel_rooms", %{"room_ids" => ["r1"], "occurred_on" => "2027-03-01"}))[
             "retained_cents"
           ] == 10

    assert ledger().credit_shortfall_cents == 20
    assert ledger().credit_liability_cents == 20
    apply!(op("cancel_rooms", %{"room_ids" => ["r0"]}))
    assert ledger().credit_shortfall_cents == 0
    assert Reservations.get_group("g").cash_paid_cents == 20
  end

  test "each conversion lot assigns independent entitlements and excess restoration becomes available" do
    apply!(open("g", [25, 25]))
    first = op("record_cash_payment", %{"amount_cents" => 7})
    second = op("record_cash_payment", %{"amount_cents" => 3})
    apply!(first)
    apply!(second)
    apply!(op("cancel_rooms", %{"room_ids" => ["r0"], "refund_method" => "hotel_credit"}))
    apply!(op("cancel_group", %{"refund_method" => "hotel_credit"}))
    lots = Repo.all(CreditLot) |> Enum.sort_by(& &1.id)
    assert Enum.map(lots, & &1.remaining_cents) == [6, 6]
    assert Enum.map(lots, & &1.entitlements[first["operation_id"]]) == [6, 2]
    assert Enum.at(lots, 1).entitlements[second["operation_id"]] == 4
    apply!(open("next"))
    apply!(op("apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 12}))
    apply!(op("charge_back_payment", %{"payment_operation_id" => first["operation_id"]}))
    assert ledger().credit_shortfall_cents == 8
    assert ledger().credit_liability_cents == 12
    apply!(op("cancel_group", %{"group_id" => "next"}))
    assert ledger().credit_shortfall_cents == 0
    assert ledger().credit_liability_cents == 4
    assert Reservations.guest_credit("guest", ~D[2026-10-01]).available_cents == 4
  end

  test "room cancellation returns original order and respects unavailable refund methods" do
    apply!(open())
    apply!(op("record_cash_payment", %{"amount_cents" => 60}))
    before = Reservations.get_group("g")

    assert [%{"code" => "refund_method_not_available"}] =
             run(
               op("cancel_rooms", %{
                 "room_ids" => ["r0"],
                 "occurred_on" => "2027-03-01",
                 "refund_method" => "hotel_credit"
               })
             )

    assert Reservations.get_group("g") == before

    assert apply!(op("cancel_rooms", %{"room_ids" => ["r2", "r0"]}))["cancelled_room_ids"] == [
             "r0",
             "r2"
           ]
  end
end
