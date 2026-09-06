defmodule GroupStay.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  import Ecto.Query
  alias GroupStay.{Reservations, Repo, Operation}

  defp op(type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-#{System.unique_integer([:positive])}",
        "type" => type,
        "occurred_on" => "2026-01-01",
        "group_id" => "g"
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
          "arrival_on" => "2026-12-01",
          "departure_on" => "2026-12-02",
          "rate_plan" => "flexible",
          "rooms" => Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 500})
        },
        attrs
      )
    )
  end

  defp run(op), do: Reservations.batch([op]) |> hd()

  defp pay(id, amount),
    do: op("record_cash_payment", %{"operation_id" => id, "amount_cents" => amount})

  defp statement(id) do
    build_conn() |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp amounts(id),
    do:
      Reservations.get_group(id).rooms
      |> Enum.map(&{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp ledger, do: Reservations.ledger(~D[2026-06-01])

  test "ordered room funding, partial settlement, reverse reduction and original result replay" do
    run(open())
    payment = pay("p", 250)
    original = run(payment)
    assert amounts("g") == [{100, 0}, {100, 0}, {50, 0}]
    cancel = op("cancel_rooms", %{"room_ids" => ["c", "a"]})
    assert %{cancelled_room_ids: ["a", "c"], refunded_cents: 150, revision: 3} = run(cancel)
    assert run(cancel).revision == 3
    assert statement("p")["held_cents"] == 100
    assert statement("p")["refunded_cents"] == 150

    reduce =
      op("reduce_cash_payment", %{
        "payment_operation_id" => "p",
        "amount_cents" => 40,
        "expected_revision" => 3
      })
      |> Map.delete("group_id")

    assert %{amount_cents: 40, revision: 4, outstanding_deposit_cents: 40} = run(reduce)
    assert amounts("g") == [{0, 0}, {60, 0}, {0, 0}]
    assert run(payment) == original
    assert run(reduce).revision == 4
    assert ledger().cash_reduced_cents == 40

    assert statement("p") == %{
             "payment_operation_id" => "p",
             "original_group_id" => "g",
             "recorded_cents" => 250,
             "held_cents" => 60,
             "refunded_cents" => 150,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 40,
             "charged_back_cents" => 0
           }

    assert run(op("cancel_group")).refunded_cents == 60
    group = Reservations.get_group("g")
    assert group.status == "cancelled"

    assert {group.lodging_total_cents, group.deposit_due_cents, group.deposit_paid_cents} ==
             {0, 0, 0}

    assert ledger().cash_refunded_cents == 210
  end

  test "reductions remove only target payment in reverse fill order and compose" do
    run(open())
    run(pay("first", 80))
    run(pay("second", 170))

    assert run(
             op("reduce_cash_payment", %{"payment_operation_id" => "second", "amount_cents" => 70})
           ).outstanding_deposit_cents == 120

    assert amounts("g") == [{100, 0}, {80, 0}, {0, 0}]

    assert run(
             op("reduce_cash_payment", %{
               "payment_operation_id" => "second",
               "amount_cents" => 100
             })
           ).status == "applied"

    assert amounts("g") == [{80, 0}, {0, 0}, {0, 0}]
    assert statement("first")["held_cents"] == 80

    assert run(
             op("reduce_cash_payment", %{"payment_operation_id" => "second", "amount_cents" => 1})
           ).code == "payment_not_reducible"
  end

  test "chargeback reclassifies held, refunded, retained and reduced cash without replaying settlement" do
    run(open())
    original = run(pay("p", 300))
    run(op("cancel_rooms", %{"room_ids" => ["a"]}))
    run(op("cancel_rooms", %{"room_ids" => ["b"], "occurred_on" => "2026-11-30"}))
    run(op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 25}))
    charge = op("charge_back_payment", %{"payment_operation_id" => "p"}) |> Map.delete("group_id")
    assert %{charged_back_cents: 275, outstanding_deposit_cents: 100, revision: 6} = run(charge)
    assert run(charge).revision == 6
    assert run(pay("p", 300)) == original
    assert ledger().cash_refunded_cents == 0
    assert ledger().cash_retained_cents == 0
    assert ledger().cash_charged_back_cents == 275
    assert ledger().cash_reduced_cents == 25
    assert statement("p")["charged_back_cents"] == 275

    assert run(op("charge_back_payment", %{"payment_operation_id" => "p"})).code ==
             "payment_not_chargeable"
  end

  test "combined bonus, telescoping entitlement, fungible spending and restoration absorption" do
    run(open())
    run(pay("first", 5))
    run(pay("second", 5))
    assert run(op("cancel_group", %{"refund_method" => "hotel_credit"})).credit_issued_cents == 11
    run(open("destination"))
    run(op("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 8}))
    destination = Reservations.get_group("destination")

    assert run(op("charge_back_payment", %{"payment_operation_id" => "first"})).charged_back_cents ==
             5

    assert ledger().cash_converted_to_credit_cents == 5
    assert ledger().credit_liability_cents == 8
    assert ledger().credit_shortfall_cents == 3
    assert Reservations.get_group("destination") == destination
    assert Reservations.guest_credit("guest", ~D[2026-06-01]).available_cents == 0
    run(op("cancel_group", %{"group_id" => "destination"}))
    assert ledger().credit_shortfall_cents == 0
    assert ledger().credit_liability_cents == 5
    assert Reservations.guest_credit("guest", ~D[2026-06-01]).available_cents == 5
    run(op("charge_back_payment", %{"payment_operation_id" => "second"}))
    assert ledger().credit_liability_cents == 0
    assert ledger().cash_converted_to_credit_cents == 0
    assert ledger().cash_charged_back_cents == 10
  end

  test "expired restoration absorbs clawback before expiry and nonrefundable consumption clears current shortfall" do
    for {id, date, plan} <- [
          {"expired", "2027-02-01", "flexible"},
          {"consumed", "2026-01-01", "advance_purchase"}
        ] do
      run(open(id))

      run(
        op("record_cash_payment", %{
          "operation_id" => id <> "-pay",
          "group_id" => id,
          "amount_cents" => 100
        })
      )

      run(op("cancel_group", %{"group_id" => id, "refund_method" => "hotel_credit"}))

      run(
        open(id <> "-dest", %{
          "rate_plan" => plan,
          "arrival_on" => "2028-01-01",
          "departure_on" => "2028-01-02"
        })
      )

      run(op("apply_hotel_credit", %{"group_id" => id <> "-dest", "amount_cents" => 110}))
      run(op("charge_back_payment", %{"payment_operation_id" => id <> "-pay"}))
      assert ledger().credit_shortfall_cents == 110
      assert ledger().credit_liability_cents == 110
      run(op("cancel_group", %{"group_id" => id <> "-dest", "occurred_on" => date}))
      assert ledger().credit_shortfall_cents == 0
      assert ledger().credit_liability_cents == 0
    end
  end

  test "a room selection earns one combined bonus and one payment can create several lots" do
    run(
      open("g", %{"rooms" => Enum.map(~w(a b c), &%{"room_id" => &1, "nightly_rate_cents" => 25})})
    )

    run(pay("p", 15))

    assert run(op("cancel_rooms", %{"room_ids" => ["b", "a"], "refund_method" => "hotel_credit"})).credit_issued_cents ==
             11

    assert run(op("cancel_group", %{"refund_method" => "hotel_credit"})).credit_issued_cents == 6
    assert ledger().credit_liability_cents == 17

    assert run(op("charge_back_payment", %{"payment_operation_id" => "p"})).charged_back_cents ==
             15

    assert ledger().credit_liability_cents == 0
    assert ledger().cash_converted_to_credit_cents == 0
    assert statement("p")["charged_back_cents"] == 15
  end

  test "partial restorations absorb clawback while other rooms remain funded" do
    run(open())
    run(pay("p", 100))
    run(op("cancel_group", %{"refund_method" => "hotel_credit"}))
    run(open("destination"))
    run(op("apply_hotel_credit", %{"group_id" => "destination", "amount_cents" => 110}))
    run(op("charge_back_payment", %{"payment_operation_id" => "p"}))
    assert ledger().credit_shortfall_cents == 110

    assert run(op("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["b"]})).status ==
             "applied"

    assert ledger().credit_shortfall_cents == 100
    assert ledger().credit_liability_cents == 100
    assert amounts("destination") == [{0, 100}, {0, 0}, {0, 0}]
    assert Reservations.guest_credit("guest", ~D[2026-06-01]).available_cents == 0
    run(op("cancel_group", %{"group_id" => "destination"}))
    assert ledger().credit_shortfall_cents == 0
    assert ledger().credit_liability_cents == 0
  end

  test "selection and payment validation, stale precedence and durable rejections" do
    run(open())

    for ids <- [[], nil, ["a", "a"], ["a", "missing"]] do
      assert run(op("cancel_rooms", %{"room_ids" => ids})).code == "invalid_rooms"
    end

    run(pay("p", 10))

    for {amount, code} <- [
          {0, "invalid_amount"},
          {-1, "invalid_amount"},
          {1.0, "invalid_amount"},
          {11, "reduction_exceeds_held_cash"}
        ] do
      assert run(
               op("reduce_cash_payment", %{
                 "payment_operation_id" => "p",
                 "amount_cents" => amount
               })
             ).code == code
    end

    for type <- ~w(reduce_cash_payment charge_back_payment) do
      assert run(op(type, %{"payment_operation_id" => "missing"})).code == "operation_not_found"

      assert run(op(type, %{"payment_operation_id" => "p", "expected_revision" => 0})).code ==
               "stale_revision"
    end

    rejected =
      op("reduce_cash_payment", %{"payment_operation_id" => "future", "amount_cents" => 1})

    assert run(rejected).code == "operation_not_found"
    run(pay("future", 10))
    assert run(rejected).code == "operation_not_found"
    assert run(Map.put(rejected, "amount_cents", 2)).code == "operation_id_conflict"
    run(op("cancel_rooms", %{"room_ids" => ["a"]}))
    assert run(op("cancel_rooms", %{"room_ids" => ["a", "b"]})).code == "invalid_rooms"

    assert run(
             op("reduce_cash_payment", %{"payment_operation_id" => "p", "expected_revision" => 0})
           ).code == "stale_revision"

    assert run(op("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 0})).code ==
             "payment_not_reducible"

    assert Reservations.get_group("g").revision == 4

    assert build_conn() |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    rejected_payment = pay("bad", 1000)
    run(rejected_payment)

    for record <- [
          Repo.one!(from o in Operation, where: o.type == "open_group"),
          Repo.get_by!(Operation, operation_id: "bad")
        ] do
      assert build_conn() |> get("/api/v1/payments/#{record.operation_id}") |> json_response(422) ==
               %{"error" => %{"code" => "payment_not_reconcilable"}}

      assert run(op("charge_back_payment", %{"payment_operation_id" => record.operation_id})).code ==
               "payment_not_chargeable"

      assert run(
               op("reduce_cash_payment", %{
                 "payment_operation_id" => record.operation_id,
                 "amount_cents" => 1
               })
             ).code == "payment_not_reducible"
    end
  end
end
