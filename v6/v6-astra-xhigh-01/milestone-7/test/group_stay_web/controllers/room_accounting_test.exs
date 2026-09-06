defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  import GroupStay.PartnerFixtures
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditLot, Payments}

  test "mixed funding fills rooms in processing order and reductions remove only the target's reverse fill",
       %{conn: conn} do
    seed_credit(conn, 100)
    apply!(conn, opening("group-81", 3))
    payment = operation("record_cash_payment", %{"amount_cents" => 150})
    original = apply!(conn, payment)
    apply!(conn, operation("apply_hotel_credit", %{"amount_cents" => 80}))
    other = operation("record_cash_payment", %{"amount_cents" => 50})
    apply!(conn, other)
    assert balances(conn) == [{100, 0}, {50, 50}, {50, 30}]

    reduction =
      target("reduce_cash_payment", payment, %{"amount_cents" => 70, "expected_revision" => 4})

    assert %{"revision" => 5, "outstanding_deposit_cents" => 90} = apply!(conn, reduction)
    assert balances(conn) == [{80, 0}, {0, 50}, {50, 30}]
    assert statement(conn, payment)["held_cents"] == 80
    assert statement(conn, other)["held_cents"] == 50
    assert apply!(conn, payment) == original

    cancellation =
      operation("cancel_rooms", %{"room_ids" => ["r3", "r1"], "expected_revision" => 5})

    assert %{"cancelled_room_ids" => ["r1", "r3"], "refunded_cents" => 130, "revision" => 6} =
             apply!(conn, cancellation)

    assert balances(conn) == [{0, 0}, {0, 50}, {0, 0}]

    assert %{
             "status" => "active",
             "lodging_total_cents" => 500,
             "deposit_due_cents" => 100,
             "deposit_paid_cents" => 50,
             "outstanding_deposit_cents" => 50
           } = group(conn)

    assert statement(conn, payment)["refunded_cents"] == 80
    assert credit(conn)["available_cents"] == 60
    assert ledger(conn)["cash_reduced_cents"] == 70
    assert ledger(conn)["credit_liability_cents"] == 110
    assert apply!(conn, cancellation)["revision"] == 6
    assert apply!(conn, reduction)["revision"] == 5

    apply!(conn, operation("cancel_group"))

    assert %{"status" => "cancelled", "lodging_total_cents" => 0, "deposit_paid_cents" => 0} =
             group(conn)

    assert credit(conn)["available_cents"] == 110
    assert ledger(conn)["cash_refunded_cents"] == 130
  end

  test "new funding fills reopened earlier rooms without redistributing surviving allocations", %{
    conn: conn
  } do
    apply!(conn, opening("group-81", 3))
    first = operation("record_cash_payment", %{"amount_cents" => 150})
    later = operation("record_cash_payment", %{"amount_cents" => 100})
    apply!(conn, first)
    apply!(conn, later)
    apply!(conn, target("reduce_cash_payment", first, %{"amount_cents" => 120}))
    assert balances(conn) == [{30, 0}, {50, 0}, {50, 0}]
    refill = operation("record_cash_payment", %{"amount_cents" => 100})
    apply!(conn, refill)
    assert balances(conn) == [{100, 0}, {80, 0}, {50, 0}]
    apply!(conn, target("reduce_cash_payment", later, %{"amount_cents" => 70}))
    assert balances(conn) == [{100, 0}, {60, 0}, {0, 0}]
    assert statement(conn, refill)["held_cents"] == 100
    apply!(conn, target("reduce_cash_payment", first, %{"amount_cents" => 30}))
    assert statement(conn, first)["held_cents"] == 0

    assert %{"code" => "payment_not_reducible"} =
             submit(conn, target("reduce_cash_payment", first, %{"amount_cents" => 1}))
  end

  test "partial settlement rounds one bonus over combined cash and entitlement follows funding order",
       %{conn: conn} do
    apply!(conn, opening("group-81", 2, 25))

    payments =
      for amount <- [4, 1, 5] do
        payment = operation("record_cash_payment", %{"amount_cents" => amount})
        apply!(conn, payment)
        payment
      end

    assert %{"credit_issued_cents" => 11, "cancelled_room_ids" => ["r1", "r2"]} =
             apply!(
               conn,
               operation("cancel_rooms", %{
                 "room_ids" => ["r2", "r1"],
                 "refund_method" => "hotel_credit"
               })
             )

    assert group(conn)["status"] == "cancelled"
    assert credit(conn)["available_cents"] == 11
    apply!(conn, target("charge_back_payment", Enum.at(payments, 1)))
    assert credit(conn)["available_cents"] == 9
    apply!(conn, target("charge_back_payment", Enum.at(payments, 0)))
    assert credit(conn)["available_cents"] == 5
    apply!(conn, target("charge_back_payment", Enum.at(payments, 2)))
    assert credit(conn)["available_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == 10
  end

  test "one chargeback reclassifies held, refunded, retained and converted cash but excludes reductions",
       %{conn: conn} do
    apply!(conn, opening("group-81", 5))
    payment = operation("record_cash_payment", %{"amount_cents" => 500})
    original = apply!(conn, payment)
    apply!(conn, target("reduce_cash_payment", payment, %{"amount_cents" => 50}))
    apply!(conn, operation("cancel_rooms", %{"room_ids" => ["r1"]}))

    apply!(
      conn,
      operation("cancel_rooms", %{"room_ids" => ["r2"], "occurred_on" => "2026-12-01"})
    )

    apply!(
      conn,
      operation("cancel_rooms", %{"room_ids" => ["r3"], "refund_method" => "hotel_credit"})
    )

    assert statement(conn, payment) == %{
             "payment_operation_id" => payment["operation_id"],
             "original_group_id" => "group-81",
             "recorded_cents" => 500,
             "held_cents" => 150,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 50,
             "charged_back_cents" => 0
           }

    chargeback = target("charge_back_payment", payment, %{"expected_revision" => 6})

    assert %{"charged_back_cents" => 450, "outstanding_deposit_cents" => 200, "revision" => 7} =
             apply!(conn, chargeback)

    assert statement(conn, payment) == %{
             "payment_operation_id" => payment["operation_id"],
             "original_group_id" => "group-81",
             "recorded_cents" => 500,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 50,
             "charged_back_cents" => 450
           }

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 450,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert apply!(conn, payment) == original
    assert apply!(conn, chargeback)["revision"] == 7

    assert %{"code" => "payment_not_chargeable"} =
             submit(conn, target("charge_back_payment", payment))

    assert %{"code" => "stale_revision", "actual_revision" => 7} =
             submit(conn, target("charge_back_payment", payment, %{"expected_revision" => 1}))

    assert %{"code" => "payment_not_reducible"} =
             submit(conn, target("reduce_cash_payment", payment, %{"amount_cents" => 1}))
  end

  test "fungible credit clawbacks absorb restorations and track only current applied shortfall",
       %{conn: conn} do
    apply!(conn, opening("source", 2))

    payments =
      for _ <- 1..2 do
        payment =
          operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 100})

        apply!(conn, payment)
        payment
      end

    apply!(
      conn,
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    )

    apply!(conn, opening("group-81", 3))
    apply!(conn, operation("apply_hotel_credit", %{"amount_cents" => 180}))
    receiver = group(conn)
    apply!(conn, target("charge_back_payment", Enum.at(payments, 1)))
    assert group(conn) == receiver
    assert ledger(conn)["credit_shortfall_cents"] == 70
    assert ledger(conn)["credit_liability_cents"] == 180
    assert credit(conn)["available_cents"] == 0

    apply!(conn, operation("cancel_rooms", %{"room_ids" => ["r1"]}))
    assert credit(conn)["available_cents"] == 30
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 110
    apply!(conn, target("charge_back_payment", Enum.at(payments, 0)))
    assert ledger(conn)["credit_shortfall_cents"] == 80
    assert ledger(conn)["credit_liability_cents"] == 80
    apply!(conn, operation("cancel_group", %{"occurred_on" => "2026-12-01"}))
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "shortfall absorption precedes expiry and entitlement is computed independently per issued lot",
       %{conn: conn} do
    apply!(conn, opening("source", 2, 25))
    payment = operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 10})
    apply!(conn, payment)

    for room <- ["r1", "r2"] do
      apply!(
        conn,
        operation("cancel_rooms", %{
          "group_id" => "source",
          "room_ids" => [room],
          "refund_method" => "hotel_credit"
        })
      )
    end

    assert credit(conn)["available_cents"] == 12
    apply!(conn, opening("group-81", 2, 30))
    apply!(conn, operation("apply_hotel_credit", %{"amount_cents" => 12}))
    apply!(conn, target("charge_back_payment", payment))
    assert ledger(conn)["credit_shortfall_cents"] == 12
    assert ledger(conn)["credit_liability_cents"] == 12
    apply!(conn, operation("reschedule_group", %{"new_arrival_on" => "2029-01-01"}))

    apply!(
      conn,
      operation("cancel_rooms", %{"room_ids" => ["r1"], "occurred_on" => "2028-01-01"})
    )

    assert ledger(conn, "2028-01-01")["credit_shortfall_cents"] == 6
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 6
    assert Enum.sort(Enum.map(Repo.all(CreditLot), & &1.unrecovered_clawback_cents)) == [0, 6]
    apply!(conn, operation("cancel_group", %{"occurred_on" => "2028-01-01"}))
    assert Enum.all?(Repo.all(CreditLot), &(&1.unrecovered_clawback_cents == 0))
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 0
  end

  test "invalid room selections and payment targets reject atomically, revision first, and stay idempotent",
       %{conn: conn} do
    opening = opening("group-81", 2)
    apply!(conn, opening)
    rejected_payment = operation("record_cash_payment", %{"amount_cents" => 201})
    assert %{"code" => "payment_exceeds_outstanding"} = submit(conn, rejected_payment)
    payment = operation("record_cash_payment", %{"amount_cents" => 100})
    apply!(conn, payment)
    before = {group(conn), ledger(conn)}

    for ids <- [[], nil, "r1", ["r1", "r1"], ["r1", "missing"], [1], [%{}]] do
      assert %{"code" => "invalid_rooms"} =
               submit(conn, operation("cancel_rooms", %{"room_ids" => ids}))
    end

    for type <- ["reduce_cash_payment", "charge_back_payment"] do
      code =
        if type == "reduce_cash_payment",
          do: "payment_not_reducible",
          else: "payment_not_chargeable"

      for invalid <- [opening, rejected_payment] do
        assert %{"code" => ^code} = submit(conn, target(type, invalid, %{"amount_cents" => 1}))
      end

      assert %{"code" => "operation_not_found"} =
               submit(conn, target(type, %{"operation_id" => "legacy"}, %{"amount_cents" => 1}))
    end

    for amount <- [0, -1, nil, "1", 1.5, true] do
      assert %{"code" => "invalid_amount"} =
               submit(conn, target("reduce_cash_payment", payment, %{"amount_cents" => amount}))
    end

    assert %{"code" => "reduction_exceeds_held_cash"} =
             submit(conn, target("reduce_cash_payment", payment, %{"amount_cents" => 101}))

    assert %{"code" => "stale_revision", "actual_revision" => 2} =
             submit(
               conn,
               target("reduce_cash_payment", payment, %{
                 "expected_revision" => 0,
                 "amount_cents" => -1
               })
             )

    assert %{"code" => "stale_revision"} =
             submit(
               conn,
               operation("cancel_rooms", %{"expected_revision" => 1, "room_ids" => nil})
             )

    assert {group(conn), ledger(conn)} == before

    missing = target("reduce_cash_payment", %{"operation_id" => "future"}, %{"amount_cents" => 1})
    result = submit(conn, missing)

    apply!(
      conn,
      operation("record_cash_payment", %{"operation_id" => "future", "amount_cents" => 1})
    )

    assert submit(conn, missing) == result

    assert %{"code" => "operation_id_conflict"} =
             submit(conn, Map.put(missing, "amount_cents", 2))

    apply!(conn, target("reduce_cash_payment", payment, %{"amount_cents" => 100}))

    assert %{"code" => "payment_not_chargeable"} =
             submit(conn, target("charge_back_payment", payment))

    assert get(conn, "/api/v1/payments/legacy") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for invalid <- [opening, rejected_payment] do
      assert get(conn, "/api/v1/payments/#{invalid["operation_id"]}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    state = {group(conn), ledger(conn)}
    assert {:ok, _} = Payments.statement(payment["operation_id"])
    assert {group(conn), ledger(conn)} == state
  end

  test "room validation covers cancelled rooms and full cancellation retains its prior inactive-group behavior",
       %{conn: conn} do
    apply!(conn, opening("group-81", 2))
    apply!(conn, operation("cancel_rooms", %{"room_ids" => ["r1"]}))

    assert %{"code" => "invalid_rooms"} =
             submit(conn, operation("cancel_rooms", %{"room_ids" => ["r1", "r2"]}))

    assert group(conn)["deposit_due_cents"] == 100

    assert %{"code" => "refund_method_not_available"} =
             submit(
               conn,
               operation("cancel_rooms", %{
                 "room_ids" => ["r2"],
                 "refund_method" => "hotel_credit",
                 "occurred_on" => "2026-12-01"
               })
             )

    apply!(conn, operation("cancel_rooms", %{"room_ids" => ["r2"]}))

    assert %{"code" => "invalid_rooms"} =
             submit(conn, operation("cancel_rooms", %{"room_ids" => ["r2"]}))

    assert %{"code" => "group_not_active"} = submit(conn, operation("cancel_group"))

    assert Enum.all?(
             group(conn)["rooms"],
             &(&1["status"] == "cancelled" and &1["deposit_due_cents"] == 0)
           )
  end

  test "large reductions, chargebacks and statement sums retain exact integer cents", %{
    conn: conn
  } do
    maximum = 9_223_372_036_854_775_807
    half = div(maximum, 2)

    for i <- 1..3 do
      id = "large-#{i}"
      apply!(conn, opening(id, 1, maximum) |> Map.put("rate_plan", "advance_purchase"))
      payment = operation("record_cash_payment", %{"group_id" => id, "amount_cents" => maximum})
      apply!(conn, payment)
      apply!(conn, target("reduce_cash_payment", payment, %{"amount_cents" => half}))

      assert %{"charged_back_cents" => amount} =
               apply!(conn, target("charge_back_payment", payment))

      assert amount == maximum - half
      assert statement(conn, payment)["charged_back_cents"] == amount
    end

    assert ledger(conn)["cash_reduced_cents"] == half * 3
    assert ledger(conn)["cash_charged_back_cents"] == (maximum - half) * 3
    assert ledger(conn)["cash_held_cents"] == 0
  end

  test "consumed and expired entitlements never create shortfall beyond credit still applied", %{
    conn: conn
  } do
    apply!(conn, opening("source", 2))
    payment = operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 200})
    apply!(conn, payment)

    apply!(
      conn,
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    )

    apply!(conn, opening("group-81", 2))
    apply!(conn, operation("apply_hotel_credit", %{"amount_cents" => 180}))

    apply!(
      conn,
      operation("cancel_rooms", %{"room_ids" => ["r1"], "occurred_on" => "2026-12-01"})
    )

    assert ledger(conn)["credit_liability_cents"] == 120
    apply!(conn, target("charge_back_payment", payment, %{"occurred_on" => "2028-01-01"}))
    assert ledger(conn, "2028-01-01")["credit_shortfall_cents"] == 80
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 80
    apply!(conn, operation("cancel_group"))
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
    assert credit(conn)["available_cents"] == 0
    assert [%{unrecovered_clawback_cents: 100}] = Repo.all(CreditLot)
  end

  defp opening(id, count, rate \\ 500) do
    open_operation(%{
      "group_id" => id,
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rooms" => for(i <- 1..count, do: %{"room_id" => "r#{i}", "nightly_rate_cents" => rate})
    })
  end

  defp seed_credit(conn, amount) do
    apply!(conn, opening("credit-source", 1, amount * 5))

    apply!(
      conn,
      operation("record_cash_payment", %{"group_id" => "credit-source", "amount_cents" => amount})
    )

    apply!(
      conn,
      operation("cancel_group", %{
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      })
    )
  end

  defp target(type, payment, fields \\ %{}) do
    operation(type, Map.merge(%{"payment_operation_id" => payment["operation_id"]}, fields))
    |> Map.delete("group_id")
  end

  defp submit(conn, op) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => [op]})
    |> json_response(200)
    |> Map.fetch!("results")
    |> hd()
  end

  defp apply!(conn, op) do
    result = submit(conn, op)
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp group(conn),
    do: get(conn, "/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

  defp balances(conn),
    do: Enum.map(group(conn)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp ledger(conn, on \\ "2026-11-01"),
    do: get(conn, "/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")

  defp credit(conn),
    do:
      get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")
      |> json_response(200)
      |> Map.fetch!("data")

  defp statement(conn, payment) do
    data =
      get(conn, "/api/v1/payments/#{payment["operation_id"]}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["recorded_cents"] ==
             Enum.sum(
               for key <-
                     ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents),
                   do: data[key]
             )

    data
  end
end
