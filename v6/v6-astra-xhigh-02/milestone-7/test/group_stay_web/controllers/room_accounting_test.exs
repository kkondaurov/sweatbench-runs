defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.ReservationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.PartnerOperations.Operation

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    RoomAllocation
  }

  test "cash and credit fill rooms in processing order and selected rooms settle independently",
       %{conn: conn} do
    issue(conn, "source", "source-pay", 100)
    batch(conn, [opening([100, 100, 100]), pay("p1", 60), credit(100), pay("p2", 90)])

    assert balances(conn) == [
             {"r1", "active", 100, 60, 40},
             {"r2", "active", 100, 40, 60},
             {"r3", "active", 100, 50, 0}
           ]

    [result] = batch(conn, [cancel_rooms(["r3", "r1"])])
    assert result["cancelled_room_ids"] == ["r1", "r3"]
    assert result["refunded_cents"] == 110
    assert result["revision"] == 5

    assert balances(conn) == [
             {"r1", "cancelled", 0, 0, 0},
             {"r2", "active", 100, 40, 60},
             {"r3", "cancelled", 0, 0, 0}
           ]

    assert group(conn)["lodging_total_cents"] == 500
    assert group(conn)["deposit_paid_cents"] == 100
    assert group(conn)["outstanding_deposit_cents"] == 0
    assert statement(conn, "p1")["refunded_cents"] == 60
    assert statement(conn, "p2")["held_cents"] == 40
    assert statement(conn, "p2")["refunded_cents"] == 50
    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents == 50

    [result] = batch(conn, [operation("cancel_group")])
    assert result["refunded_cents"] == 40
    assert result["revision"] == 6
    refute Map.has_key?(result, "cancelled_room_ids")
    assert group(conn)["status"] == "cancelled"
    assert group(conn)["lodging_total_cents"] == 0
    assert ledger(conn)["cash_refunded_cents"] == 150
    assert ledger(conn)["credit_liability_cents"] == 110
  end

  test "selected cash receives one rounded bonus, with entitlement telescoping in funding order",
       %{conn: conn} do
    batch(conn, [opening([5, 5]), pay("z-first", 5), pay("a-second", 5)])
    [cancelled] = batch(conn, [cancel_rooms(["r2", "r1"], %{"refund_method" => "hotel_credit"})])
    assert cancelled["credit_issued_cents"] == 11
    assert group(conn)["status"] == "cancelled"
    assert ledger(conn)["credit_liability_cents"] == 11

    [charged] = batch(conn, [chargeback("a-second", %{"expected_revision" => 4})])
    assert charged["charged_back_cents"] == 5
    assert charged["revision"] == 5
    assert ledger(conn)["credit_liability_cents"] == 6
    assert ledger(conn)["cash_converted_to_credit_cents"] == 5
    batch(conn, [chargeback("z-first")])
    assert ledger(conn)["credit_liability_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == 10
  end

  test "room validation is atomic, checks revision first, and remembers rejected results", %{
    conn: conn
  } do
    batch(conn, [opening([100, 100]), pay("paid", 150)])

    for ids <- [[], nil, "r1", ["r1", "r1"], ["r1", "missing"], [nil], [1], [%{}]] do
      rejected(conn, cancel_rooms(ids), "invalid_rooms")
    end

    rejected(conn, operation("cancel_rooms"), "invalid_operation")
    rejected(conn, cancel_rooms(["r1"], %{"refund_method" => "wire"}), "invalid_operation")

    rejected(
      conn,
      cancel_rooms(["r1"], %{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"}),
      "refund_method_not_available"
    )

    stale = cancel_rooms(["missing"], %{"expected_revision" => 1})
    original = rejected(conn, stale, "stale_revision")
    batch(conn, [cancel_rooms(["r1"])])
    rejected(conn, cancel_rooms(["r1", "r2"]), "invalid_rooms")
    assert batch(conn, [stale]) == [original]
    rejected(conn, Map.put(stale, "expected_revision", 3), "operation_id_conflict")
    batch(conn, [cancel_rooms(["r2"])])
    rejected(conn, cancel_rooms(["r2"], %{"expected_revision" => 3}), "stale_revision")
    rejected(conn, cancel_rooms(["r2"]), "group_not_active")

    rejected(
      conn,
      cancel_rooms(["r1"], %{"group_id" => "missing", "expected_revision" => 0}),
      "group_not_found"
    )
  end

  test "zero priced rooms can be cancelled and rate plan deposits remain per room", %{conn: conn} do
    batch(conn, [
      opening([0, 1], %{
        "rooms" => [
          %{"room_id" => "r1", "nightly_rate_cents" => 0},
          %{"room_id" => "r2", "nightly_rate_cents" => 3}
        ]
      })
    ])

    assert balances(conn) == [{"r1", "active", 0, 0, 0}, {"r2", "active", 1, 0, 0}]
    batch(conn, [cancel_rooms(["r1"]), pay("p", 1), cancel_rooms(["r2"])])
    assert ledger(conn)["cash_refunded_cents"] == 1

    batch(conn, [opening([5], %{"group_id" => "advance", "rate_plan" => "advance_purchase"})])
    assert group(conn, "advance")["deposit_due_cents"] == 25
  end

  test "successive reductions remove only the target's latest held fills and new funding fills gaps",
       %{conn: conn} do
    payment = pay("original", 250)
    [_, original] = batch(conn, [opening([100, 100, 100]), payment])
    reduction = reduce_payment("original", 75, %{"expected_revision" => 2})
    [result] = batch(conn, [reduction])

    assert result == %{
             "operation_id" => reduction["operation_id"],
             "status" => "applied",
             "payment_operation_id" => "original",
             "group_id" => "group-81",
             "amount_cents" => 75,
             "outstanding_deposit_cents" => 125,
             "revision" => 3
           }

    assert balances(conn) == [
             {"r1", "active", 100, 100, 0},
             {"r2", "active", 100, 75, 0},
             {"r3", "active", 100, 0, 0}
           ]

    batch(conn, [pay("new", 80), reduce_payment("original", 100)])

    assert balances(conn) == [
             {"r1", "active", 100, 75, 0},
             {"r2", "active", 100, 25, 0},
             {"r3", "active", 100, 55, 0}
           ]

    batch(conn, [reduce_payment("original", 75)])
    assert statement(conn, "original")["reduced_cents"] == 250
    assert statement(conn, "new")["held_cents"] == 80
    assert ledger(conn)["cash_reduced_cents"] == 250
    assert ledger(conn)["cash_held_cents"] == 80
    before = snapshot()
    assert batch(conn, [payment, reduction]) == [original, result]
    assert snapshot() == before
    rejected(conn, reduce_payment("original", 1), "payment_not_reducible")
    rejected(conn, chargeback("original"), "payment_not_chargeable")
  end

  test "reductions preserve settled history and chargebacks reclassify every remaining disposition",
       %{conn: conn} do
    payment = pay("payment", 400)
    [_, original] = batch(conn, [opening([100, 100, 100, 100]), payment])

    batch(conn, [
      reduce_payment("payment", 50),
      cancel_rooms(["r1"]),
      cancel_rooms(["r2"], %{"occurred_on" => "2026-11-27"}),
      cancel_rooms(["r3"], %{"refund_method" => "hotel_credit"})
    ])

    assert statement(conn, "payment") ==
             payment_statement("payment", 400,
               held_cents: 50,
               refunded_cents: 100,
               retained_cents: 100,
               converted_to_credit_cents: 100,
               reduced_cents: 50
             )

    rejected(conn, reduce_payment("payment", 51), "reduction_exceeds_held_cash")
    chargeback = chargeback("payment", %{"expected_revision" => 6})
    [charged] = batch(conn, [chargeback])
    assert charged["charged_back_cents"] == 350
    assert charged["revision"] == 7
    assert charged["outstanding_deposit_cents"] == 100

    assert statement(conn, "payment") ==
             payment_statement("payment", 400, reduced_cents: 50, charged_back_cents: 350)

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 350,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    before = snapshot()
    assert batch(conn, [payment, chargeback]) == [original, charged]
    assert snapshot() == before
    rejected(conn, chargeback("payment"), "payment_not_chargeable")
    rejected(conn, reduce_payment("payment", 1), "payment_not_reducible")
    batch(conn, [pay("replacement", 100), operation("cancel_group")])
    assert ledger(conn)["cash_refunded_cents"] == 100
  end

  test "payment target validation, derived revisions and HTTP statement errors", %{conn: conn} do
    opening = opening([100])
    failed_payment = pay("rejected-payment", 101)
    batch(conn, [opening, failed_payment, pay("valid", 50)])

    for {target, code} <- [
          {"missing", "operation_not_found"},
          {opening["operation_id"], "payment_not_reducible"},
          {"rejected-payment", "payment_not_reducible"}
        ] do
      rejected(conn, reduce_payment(target, 1), code)
    end

    for target <- [opening["operation_id"], "rejected-payment"] do
      rejected(conn, chargeback(target), "payment_not_chargeable")

      assert conn |> get("/api/v1/payments/#{target}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    assert conn |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    rejected(conn, chargeback("missing"), "operation_not_found")

    for amount <- [0, -1, 1.0, "1", nil, true, [], %{}] do
      rejected(conn, reduce_payment("valid", amount), "invalid_amount")
    end

    rejected(conn, reduce_payment("valid", 51), "reduction_exceeds_held_cash")
    rejected(conn, reduce_payment("valid", 1) |> Map.delete("amount_cents"), "invalid_operation")

    for type <- ["reduce_cash_payment", "charge_back_payment"] do
      rejected(conn, operation(type), "invalid_operation")

      stale =
        operation(type, %{
          "payment_operation_id" => "valid",
          "group_id" => "missing",
          "expected_revision" => 1,
          "amount_cents" => -1,
          "occurred_on" => "bad"
        })

      result = rejected(conn, stale, "stale_revision")
      assert result["group_id"] == "group-81"
      assert result["actual_revision"] == 2
    end

    batch(conn, [operation("cancel_group")])
    rejected(conn, reduce_payment("valid", 1, %{"expected_revision" => 2}), "stale_revision")
    rejected(conn, reduce_payment("valid", 1), "payment_not_reducible")
    [result] = batch(conn, [chargeback("valid", %{"expected_revision" => 3})])
    assert result["revision"] == 4
    assert result["charged_back_cents"] == 50
    assert result["outstanding_deposit_cents"] == 0
  end

  test "fungible spent credit becomes shortfall without changing funded groups, and returns absorb it",
       %{conn: conn} do
    issue(conn, "source", "source-pay", 100)
    batch(conn, [opening([40, 40]), credit(80)])
    target = group(conn)
    batch(conn, [chargeback("source-pay")])
    assert group(conn) == target
    assert ledger(conn)["credit_liability_cents"] == 80
    assert ledger(conn)["credit_shortfall_cents"] == 80
    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents == 0
    batch(conn, [cancel_rooms(["r1"])])
    assert ledger(conn)["credit_liability_cents"] == 40
    assert ledger(conn)["credit_shortfall_cents"] == 40
    batch(conn, [cancel_rooms(["r2"], %{"occurred_on" => "2026-11-27"})])
    assert ledger(conn)["credit_liability_cents"] == 0
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert Repo.one(CreditLot).unrecovered_clawback_cents == 40
  end

  test "partial entitlement clawback is fungible across payments and restores excess without another bonus",
       %{conn: conn} do
    batch(conn, [
      opening([200], %{"group_id" => "source"}),
      pay("a", 100, "source"),
      pay("b", 100, "source"),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])

    batch(conn, [opening([190]), credit(190), chargeback("a")])
    assert ledger(conn)["credit_shortfall_cents"] == 80
    assert ledger(conn)["credit_liability_cents"] == 190
    batch(conn, [operation("cancel_group", %{"refund_method" => "hotel_credit"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 110
    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents == 110
    batch(conn, [chargeback("b")])
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "multiple chargebacks compose on a lot and shortfall absorption precedes expiry", %{
    conn: conn
  } do
    batch(conn, [
      opening([200], %{"group_id" => "source"}),
      pay("a", 100, "source"),
      pay("b", 100, "source"),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])

    batch(conn, [
      opening([160, 30], %{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-02"}),
      credit(190),
      chargeback("a"),
      chargeback("b")
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 190
    batch(conn, [cancel_rooms(["r1"], %{"occurred_on" => "2027-10-05"})])
    assert ledger(conn)["credit_shortfall_cents"] == 30
    assert ledger(conn)["credit_liability_cents"] == 30
    assert Repo.one(CreditLot).unrecovered_clawback_cents == 30
    batch(conn, [operation("cancel_group", %{"occurred_on" => "2027-10-05"})])
    assert Repo.one(CreditLot).unrecovered_clawback_cents == 0
    assert Repo.one(CreditLot).remaining_cents == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "one payment's entitlements are rounded independently in multiple cancellation lots", %{
    conn: conn
  } do
    batch(conn, [
      opening([5, 5]),
      pay("p", 10),
      cancel_rooms(["r1"], %{"refund_method" => "hotel_credit"}),
      cancel_rooms(["r2"], %{"refund_method" => "hotel_credit"})
    ])

    assert ledger(conn)["credit_liability_cents"] == 12
    batch(conn, [opening([7], %{"group_id" => "target"}), credit(7, "target"), chargeback("p")])
    assert ledger(conn)["credit_shortfall_cents"] == 7
    assert ledger(conn)["credit_liability_cents"] == 7
    assert statement(conn, "p")["charged_back_cents"] == 10
  end

  test "statement reads preserve identifiers and never mutate audit or domain state", %{
    conn: conn
  } do
    id = " Payment-Å 17 "
    batch(conn, [opening([100]), pay(id, 50)])
    before = snapshot(true)
    assert statement(conn, id) == payment_statement(id, 50, held_cents: 50)
    assert statement(conn, id) == payment_statement(id, 50, held_cents: 50)
    assert snapshot(true) == before
  end

  test "cumulative corrections stay exact beyond SQLite's integer range within one group", %{
    conn: conn
  } do
    amount = 9_223_372_036_854_775_807

    batch(conn, [
      opening([0], %{
        "rate_plan" => "advance_purchase",
        "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => amount}]
      })
    ])

    for i <- 1..2 do
      results =
        batch(conn, [
          pay("reduce-#{i}", amount),
          reduce_payment("reduce-#{i}", amount),
          pay("charge-#{i}", amount),
          chargeback("charge-#{i}")
        ])

      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert statement(conn, "reduce-#{i}")["reduced_cents"] == amount
      assert statement(conn, "charge-#{i}")["charged_back_cents"] == amount
    end

    assert ledger(conn)["cash_reduced_cents"] == amount * 2
    assert ledger(conn)["cash_charged_back_cents"] == amount * 2
    assert ledger(conn)["cash_held_cents"] == 0
    assert group(conn)["outstanding_deposit_cents"] == amount
    assert group(conn)["revision"] == 9
  end

  defp opening(deposits, attrs \\ %{}) do
    rooms =
      deposits
      |> Enum.with_index(1)
      |> Enum.map(fn {due, i} -> %{"room_id" => "r#{i}", "nightly_rate_cents" => due * 5} end)

    open_operation(Map.merge(%{"departure_on" => "2026-12-11", "rooms" => rooms}, attrs))
  end

  defp pay(id, amount, group \\ "group-81"),
    do:
      operation("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount
      })

  defp credit(amount, group \\ "group-81"),
    do: operation("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp cancel_rooms(ids, attrs \\ %{}),
    do: operation("cancel_rooms", Map.merge(%{"room_ids" => ids}, attrs))

  defp reduce_payment(id, amount, attrs \\ %{}),
    do:
      operation(
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => id, "amount_cents" => amount}, attrs)
      )
      |> Map.delete("group_id")

  defp chargeback(id, attrs \\ %{}),
    do:
      operation("charge_back_payment", Map.merge(%{"payment_operation_id" => id}, attrs))
      |> Map.delete("group_id")

  defp issue(conn, group, payment, cash) do
    batch(conn, [
      opening([cash], %{"group_id" => group}),
      pay(payment, cash, group),
      operation("cancel_group", %{"group_id" => group, "refund_method" => "hotel_credit"})
    ])
  end

  defp batch(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(conn, id \\ "group-81"),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn),
    do: conn |> get("/api/v1/ledger?on=2026-10-04") |> json_response(200) |> Map.fetch!("data")

  defp balances(conn),
    do:
      for(
        r <- group(conn)["rooms"],
        do:
          {r["room_id"], r["status"], r["deposit_due_cents"], r["cash_paid_cents"],
           r["credit_paid_cents"]}
      )

  defp statement(conn, id) do
    data =
      conn
      |> get("/api/v1/payments/#{URI.encode(id, &URI.char_unreserved?/1)}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.sum(
             for {key, amount} <- data,
                 String.ends_with?(key, "_cents") and key != "recorded_cents",
                 do: amount
           ) == data["recorded_cents"]

    data
  end

  defp payment_statement(id, recorded, amounts) do
    defaults = %{
      payment_operation_id: id,
      original_group_id: "group-81",
      recorded_cents: recorded,
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    }

    defaults |> Map.merge(Map.new(amounts)) |> Jason.encode!() |> Jason.decode!()
  end

  defp rejected(conn, operation, code) do
    before = snapshot()
    assert [%{"status" => "rejected", "code" => ^code} = result] = batch(conn, [operation])
    assert snapshot() == before
    result
  end

  defp snapshot(audit \\ false) do
    for schema <-
          [Group, CreditLot, CreditAllocation, RoomAllocation, CreditEntitlement] ++
            if(audit, do: [Operation], else: []),
        do: Repo.all(schema)
  end
end
