defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp operation(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2026-10-01"
      },
      attrs
    )
  end

  defp open(group \\ "group", rates \\ [1000, 1000, 1000]) do
    operation("open_group", %{
      "group_id" => group,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2028-12-01",
      "departure_on" => "2028-12-02",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.with_index(rates, fn rate, index ->
          %{"room_id" => "r#{index}", "nightly_rate_cents" => rate}
        end)
    })
  end

  defp submit(ops) do
    build_conn()
    |> post("/api/v1/partner-batches", %{"operations" => List.wrap(ops)})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp apply!(op) do
    [result] = submit(op)
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp read(path, status \\ 200),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(status)

  defp group(id \\ "group"), do: read("groups/#{id}")["data"]
  defp ledger(on \\ "2026-10-01"), do: read("ledger?on=#{on}")["data"]
  defp credit(on \\ "2026-10-01"), do: read("guests/guest/credit?on=#{on}")["data"]

  defp payment(id) do
    statement = read("payments/#{id}")["data"]

    assert Map.keys(statement) |> Enum.sort() ==
             Enum.sort(
               ~w(payment_operation_id original_group_id recorded_cents held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
             )

    assert Enum.sum(
             for key <-
                   ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                 do: statement[key]
           ) == statement["recorded_cents"]

    statement
  end

  test "selected rooms settle only their funding, reductions reverse fill, and retries stay exact" do
    apply!(open())
    pay = operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 450})
    original = apply!(pay)

    reduction =
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "pay",
        "amount_cents" => 100,
        "expected_revision" => 2
      })

    reduced = apply!(reduction)
    assert reduced["outstanding_deposit_cents"] == 250
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [200, 150, 0]
    apply!(operation("record_cash_payment", %{"operation_id" => "second", "amount_cents" => 150}))
    assert Enum.map(group()["rooms"], & &1["cash_paid_cents"]) == [200, 200, 100]
    cancel = operation("cancel_rooms", %{"room_ids" => ["r2", "r0"]})
    cancelled = apply!(cancel)
    assert cancelled["cancelled_room_ids"] == ["r0", "r2"]
    assert cancelled["refunded_cents"] == 300
    assert group()["deposit_due_cents"] == 200
    assert group()["lodging_total_cents"] == 1000
    assert group()["cash_paid_cents"] == 200
    assert payment("pay")["refunded_cents"] == 200
    assert payment("pay")["held_cents"] == 150
    assert payment("pay")["reduced_cents"] == 100

    apply!(
      operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 150})
    )

    assert group()["outstanding_deposit_cents"] == 150
    assert apply!(operation("cancel_group"))["refunded_cents"] == 50
    assert group()["status"] == "cancelled"
    assert group()["lodging_total_cents"] == 0
    assert ledger()["cash_refunded_cents"] == 350
    assert ledger()["cash_reduced_cents"] == 250
    before = ledger()
    assert submit([pay, reduction, cancel]) == [original, reduced, cancelled]
    assert ledger() == before
    assert read("operations/pay")["data"] == original
  end

  test "room and payment errors are atomic, durable, and check derived revision first" do
    apply!(open())
    apply!(operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100}))

    for ids <- [nil, [], ["r0", "r0"], ["missing"], ["r0", "missing"], "r0"] do
      assert [%{"code" => "invalid_rooms"}] =
               submit(operation("cancel_rooms", %{"room_ids" => ids}))
    end

    for {type, attrs, code} <- [
          {"reduce_cash_payment", %{"payment_operation_id" => "missing", "amount_cents" => 1},
           "operation_not_found"},
          {"charge_back_payment", %{"payment_operation_id" => "missing"}, "operation_not_found"},
          {"reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 101},
           "reduction_exceeds_held_cash"},
          {"reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 0},
           "invalid_amount"},
          {"reduce_cash_payment",
           %{"payment_operation_id" => "pay", "amount_cents" => -1, "expected_revision" => 1},
           "stale_revision"},
          {"charge_back_payment", %{"payment_operation_id" => "pay", "expected_revision" => 1},
           "stale_revision"}
        ] do
      before = {group(), ledger(), payment("pay")}
      op = operation(type, attrs)
      assert [%{"code" => ^code}] = submit(op)
      assert {group(), ledger(), payment("pay")} == before
      assert submit(op) == submit(op)
    end

    assert [%{"code" => "invalid_amount"}] =
             submit(
               operation("record_cash_payment", %{
                 "operation_id" => "bad-pay",
                 "amount_cents" => 0
               })
             )

    for id <- ["bad-pay", group()["group_id"]] do
      # The second identity is made durable as an unrelated operation.
      if id == "group",
        do:
          apply!(
            operation("reschedule_group", %{
              "operation_id" => id,
              "new_arrival_on" => "2029-01-01"
            })
          )

      assert read("payments/#{id}", 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      assert [%{"code" => "payment_not_reducible"}] =
               submit(
                 operation("reduce_cash_payment", %{
                   "payment_operation_id" => id,
                   "amount_cents" => 1
                 })
               )

      assert [%{"code" => "payment_not_chargeable"}] =
               submit(operation("charge_back_payment", %{"payment_operation_id" => id}))
    end

    assert read("payments/missing", 404) == %{"error" => %{"code" => "operation_not_found"}}

    apply!(
      operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 100})
    )

    assert [%{"code" => "payment_not_reducible"}] =
             submit(
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => "pay",
                 "amount_cents" => 1
               })
             )

    assert [%{"code" => "payment_not_chargeable"}] =
             submit(operation("charge_back_payment", %{"payment_operation_id" => "pay"}))
  end

  test "chargeback reclassifies refunded, retained, converted and held cash, excluding reductions" do
    apply!(open("group", [500, 500, 500, 500, 500]))
    pay = operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 500})
    original = apply!(pay)
    apply!(operation("cancel_rooms", %{"room_ids" => ["r0"]}))
    apply!(operation("cancel_rooms", %{"room_ids" => ["r1"], "occurred_on" => "2028-11-30"}))
    apply!(operation("cancel_rooms", %{"room_ids" => ["r2"], "refund_method" => "hotel_credit"}))

    apply!(
      operation("reduce_cash_payment", %{"payment_operation_id" => "pay", "amount_cents" => 50})
    )

    assert payment("pay")["held_cents"] == 150

    chargeback =
      operation("charge_back_payment", %{
        "payment_operation_id" => "pay",
        "expected_revision" => 6
      })

    result = apply!(chargeback)
    assert result["charged_back_cents"] == 450
    assert result["revision"] == 7
    assert result["outstanding_deposit_cents"] == 200
    assert payment("pay")["charged_back_cents"] == 450
    assert payment("pay")["reduced_cents"] == 50

    for field <-
          ~w(cash_held_cents cash_refunded_cents cash_retained_cents cash_converted_to_credit_cents credit_liability_cents credit_shortfall_cents),
        do: assert(ledger()[field] == 0)

    assert ledger()["cash_charged_back_cents"] == 450
    assert credit()["available_cents"] == 0
    assert submit([pay, chargeback]) == [original, result]

    assert [%{"code" => "payment_not_chargeable"}] =
             submit(operation("charge_back_payment", %{"payment_operation_id" => "pay"}))

    assert [%{"code" => "payment_not_reducible"}] =
             submit(
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => "pay",
                 "amount_cents" => 1
               })
             )
  end

  test "combined bonus telescopes in funding order and clawback absorbs restored credit" do
    apply!(open("group", [25, 25]))
    # Both payments are five cents; one combined bonus is a cent. The earlier
    # committed payment receives it even though its business date is later.
    apply!(
      operation("record_cash_payment", %{
        "operation_id" => "z-pay",
        "amount_cents" => 5,
        "occurred_on" => "2026-10-02"
      })
    )

    apply!(operation("record_cash_payment", %{"operation_id" => "a-pay", "amount_cents" => 5}))

    assert apply!(
             operation("cancel_rooms", %{
               "room_ids" => ["r1", "r0"],
               "refund_method" => "hotel_credit"
             })
           )["credit_issued_cents"] == 11

    apply!(open("destination", [25, 25, 25]))
    apply!(operation("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 9}))
    destination = group("destination")
    apply!(operation("charge_back_payment", %{"payment_operation_id" => "z-pay"}))
    assert group("destination") == destination
    assert credit()["available_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 4
    assert ledger()["credit_liability_cents"] == 9
    apply!(operation("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r1"]}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 5
    assert credit()["available_cents"] == 0
    apply!(operation("cancel_group", %{"group_id" => "destination"}))
    assert credit()["available_cents"] == 5
    apply!(operation("charge_back_payment", %{"payment_operation_id" => "a-pay"}))
    assert credit()["available_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 10
  end

  for settlement <- [:expired_refund, :nonrefundable] do
    test "shortfall follows applied credit through #{settlement}" do
      apply!(open("group", [1000]))
      apply!(operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 100}))
      apply!(operation("cancel_group", %{"refund_method" => "hotel_credit"}))
      apply!(open("destination", [250, 300]))

      apply!(
        operation("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 110})
      )

      apply!(operation("charge_back_payment", %{"payment_operation_id" => "pay"}))
      assert ledger()["credit_shortfall_cents"] == 110
      on = if unquote(settlement) == :expired_refund, do: "2027-10-02", else: "2028-11-30"

      apply!(
        operation("cancel_rooms", %{
          "group_id" => "destination",
          "room_ids" => ["r0"],
          "occurred_on" => on
        })
      )

      assert ledger(on)["credit_shortfall_cents"] == 60
      assert ledger(on)["credit_liability_cents"] == 60
      assert credit(on)["available_cents"] == 0
      apply!(operation("cancel_group", %{"group_id" => "destination", "occurred_on" => on}))
      assert ledger(on)["credit_shortfall_cents"] == 0
      assert ledger(on)["credit_liability_cents"] == 0
    end
  end

  test "each converted lot rounds independently and restores only excess above its clawback" do
    apply!(open("group", [25, 25]))
    apply!(operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 10}))

    for room <- ["r0", "r1"] do
      assert apply!(
               operation("cancel_rooms", %{
                 "operation_id" => "lot-" <> room,
                 "room_ids" => [room],
                 "refund_method" => "hotel_credit"
               })
             )["credit_issued_cents"] == 6
    end

    assert credit()["available_cents"] == 12
    apply!(open("destination", [100]))
    apply!(operation("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 7}))
    apply!(operation("charge_back_payment", %{"payment_operation_id" => "pay"}))
    assert credit()["available_cents"] == 0
    assert ledger()["credit_shortfall_cents"] == 7
    assert ledger()["credit_liability_cents"] == 7
    apply!(operation("cancel_group", %{"group_id" => "destination"}))
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0

    apply!(open("another", [1000]))

    apply!(
      operation("record_cash_payment", %{
        "group_id" => "another",
        "operation_id" => "p1",
        "amount_cents" => 50
      })
    )

    apply!(
      operation("record_cash_payment", %{
        "group_id" => "another",
        "operation_id" => "p2",
        "amount_cents" => 50
      })
    )

    apply!(
      operation("cancel_group", %{"group_id" => "another", "refund_method" => "hotel_credit"})
    )

    apply!(open("last", [1000]))
    apply!(operation("apply_hotel_credit", %{"group_id" => "last", "amount_cents" => 100}))
    apply!(operation("charge_back_payment", %{"payment_operation_id" => "p1"}))
    assert ledger()["credit_shortfall_cents"] == 45
    apply!(operation("cancel_group", %{"group_id" => "last"}))
    assert credit()["available_cents"] == 55
    assert ledger()["credit_liability_cents"] == 55
    assert ledger()["credit_shortfall_cents"] == 0
  end
end
