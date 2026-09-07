defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    OperationRecord,
    Room,
    RoomAllocation
  }

  test "funding fills original room order; reductions reopen gaps without moving other funding",
       %{conn: conn} do
    issue_credit(conn, 100)
    payment = cash("pay", 150)

    [_, paid, credited, later] =
      batch(conn, [
        booking(),
        payment,
        operation("apply_hotel_credit", %{"amount_cents" => 110}),
        cash("later", 30)
      ])

    assert [paid["revision"], credited["revision"], later["revision"]] == [2, 3, 4]

    assert room_balances(conn) == [
             {"z", "active", 100, 0},
             {"a", "active", 50, 50},
             {"m", "active", 30, 60}
           ]

    reduction =
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 70, "expected_revision" => 4})

    [reduced] = batch(conn, [reduction])

    assert reduced == %{
             "operation_id" => reduction["operation_id"],
             "status" => "applied",
             "payment_operation_id" => "pay",
             "group_id" => "group-81",
             "amount_cents" => 70,
             "outstanding_deposit_cents" => 80,
             "revision" => 5
           }

    assert room_balances(conn) == [
             {"z", "active", 80, 0},
             {"a", "active", 0, 50},
             {"m", "active", 30, 60}
           ]

    batch(conn, [cash("refill", 60)])

    assert room_balances(conn) == [
             {"z", "active", 100, 0},
             {"a", "active", 40, 50},
             {"m", "active", 30, 60}
           ]

    assert batch(conn, [payment, reduction]) == [paid, reduced]
    assert statement(conn, "pay") == statement_data("pay", 150, held_cents: 80, reduced_cents: 70)
    assert ledger(conn)["cash_reduced_cents"] == 70
    assert ledger(conn)["credit_liability_cents"] == 110
  end

  test "selected cancellation settles only selected rooms, orders IDs, and rounds a combined bonus",
       %{conn: conn} do
    batch(conn, [booking([3, 100, 3]), cash("pay", 106)])

    cancel =
      operation("cancel_rooms", %{"room_ids" => ["m", "z"], "refund_method" => "hotel_credit"})

    [result] = batch(conn, [cancel])

    assert result == %{
             "operation_id" => cancel["operation_id"],
             "status" => "applied",
             "group_id" => "group-81",
             "cancelled_room_ids" => ["z", "m"],
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 7,
             "revision" => 3
           }

    saved = group(conn)
    assert saved["status"] == "active"
    assert saved["lodging_total_cents"] == 500
    assert saved["deposit_due_cents"] == 100
    assert saved["deposit_paid_cents"] == 100

    assert room_balances(conn) == [
             {"z", "cancelled", 0, 0},
             {"a", "active", 100, 0},
             {"m", "cancelled", 0, 0}
           ]

    assert statement(conn, "pay") ==
             statement_data("pay", 106, held_cents: 100, converted_to_credit_cents: 6)

    assert batch(conn, [cancel]) == [result]
    [last] = batch(conn, [operation("cancel_group")])
    assert last["refunded_cents"] == 100
    assert last["revision"] == 4
    assert group(conn)["status"] == "cancelled"
    assert group(conn)["lodging_total_cents"] == 0

    assert statement(conn, "pay") ==
             statement_data("pay", 106, refunded_cents: 100, converted_to_credit_cents: 6)
  end

  test "room validation is atomic and stale revisions precede room and refund rules", %{
    conn: conn
  } do
    batch(conn, [booking(), cash("pay", 150)])

    for ids <- [[], nil, "z", ["missing"], ["z", "z"], ["z", "missing"], [1]] do
      before = snapshot()
      [result] = batch(conn, [operation("cancel_rooms", %{"room_ids" => ids})])
      assert result["code"] == "invalid_rooms"
      assert snapshot() == before
    end

    [stale, invalid_method, unavailable, cancelled, repeated] =
      batch(conn, [
        operation("cancel_rooms", %{
          "room_ids" => [],
          "expected_revision" => 1,
          "refund_method" => "unknown"
        }),
        operation("cancel_rooms", %{"room_ids" => ["z"], "refund_method" => "unknown"}),
        operation("cancel_rooms", %{
          "room_ids" => ["z"],
          "refund_method" => "hotel_credit",
          "occurred_on" => "2026-12-09"
        }),
        operation("cancel_rooms", %{"room_ids" => ["z"]}),
        operation("cancel_rooms", %{"room_ids" => ["z", "a"]})
      ])

    assert stale["code"] == "stale_revision"
    assert stale["actual_revision"] == 2
    assert invalid_method["code"] == "invalid_operation"
    assert unavailable["code"] == "refund_method_not_available"
    assert cancelled["revision"] == 3
    assert repeated["code"] == "invalid_rooms"
    assert group(conn)["deposit_paid_cents"] == 50
  end

  test "reductions use durable applied payment targets and remember rejected attempts", %{
    conn: conn
  } do
    [opened, rejected, _] = batch(conn, [booking(), cash("rejected", 301), cash("pay", 100)])

    for {target, code} <- [
          {"missing", "operation_not_found"},
          {opened["operation_id"], "payment_not_reducible"},
          {rejected["operation_id"], "payment_not_reducible"}
        ] do
      [result] = batch(conn, [correction("reduce_cash_payment", target, %{"amount_cents" => 1})])
      assert result["code"] == code
    end

    for amount <- [0, -1, 1.0, "1", nil] do
      [result] =
        batch(conn, [correction("reduce_cash_payment", "pay", %{"amount_cents" => amount})])

      assert result["code"] == "invalid_amount"
    end

    too_large = correction("reduce_cash_payment", "pay", %{"amount_cents" => 101})
    [rejected] = batch(conn, [too_large])
    assert rejected["code"] == "reduction_exceeds_held_cash"

    [stale, first, second, exhausted] =
      batch(conn, [
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 0, "expected_revision" => 1}),
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 30, "expected_revision" => 2}),
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 70, "expected_revision" => 3}),
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 1})
      ])

    assert stale["code"] == "stale_revision"
    assert first["revision"] == 3
    assert second["revision"] == 4
    assert exhausted["code"] == "payment_not_reducible"
    assert batch(conn, [too_large]) == [rejected]
    assert statement(conn, "pay") == statement_data("pay", 100, reduced_cents: 100)

    assert [%{"code" => "payment_not_chargeable"}] =
             batch(conn, [correction("charge_back_payment", "pay")])
  end

  test "a payment statement reconciles every disposition and chargeback leaves reductions intact",
       %{conn: conn} do
    payment = cash("pay", 500)
    [_, original] = batch(conn, [booking([100, 100, 100, 100, 100]), payment])

    batch(conn, [
      operation("cancel_rooms", %{"room_ids" => ["z"]}),
      operation("cancel_rooms", %{"room_ids" => ["a"], "occurred_on" => "2026-12-09"}),
      operation("cancel_rooms", %{"room_ids" => ["m"], "refund_method" => "hotel_credit"}),
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 50})
    ])

    assert statement(conn, "pay") ==
             statement_data("pay", 500,
               held_cents: 150,
               refunded_cents: 100,
               retained_cents: 100,
               converted_to_credit_cents: 100,
               reduced_cents: 50
             )

    chargeback = correction("charge_back_payment", "pay", %{"expected_revision" => 6})
    [result] = batch(conn, [chargeback])

    assert result == %{
             "operation_id" => chargeback["operation_id"],
             "status" => "applied",
             "payment_operation_id" => "pay",
             "group_id" => "group-81",
             "charged_back_cents" => 450,
             "outstanding_deposit_cents" => 200,
             "revision" => 7
           }

    assert statement(conn, "pay") ==
             statement_data("pay", 500, reduced_cents: 50, charged_back_cents: 450)

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

    before = snapshot()
    assert batch(conn, [payment, chargeback]) == [original, result]
    assert snapshot() == before

    assert [%{"code" => "payment_not_chargeable"}] =
             batch(conn, [correction("charge_back_payment", "pay")])

    assert [%{"code" => "payment_not_reducible"}] =
             batch(conn, [correction("reduce_cash_payment", "pay", %{"amount_cents" => 1})])
  end

  test "shared-lot entitlements telescope in processing order, and spending is fungible", %{
    conn: conn
  } do
    batch(conn, [
      booking([10, 10, 10]),
      cash("z-pay", 5, "2026-11-02"),
      cash("a-pay", 5, "2026-10-01"),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      booking([100], "target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 8})
    ])

    assert credit(conn) == 3
    before = group(conn, "target")

    [result] =
      batch(conn, [correction("charge_back_payment", "z-pay", %{"expected_revision" => 4})])

    assert result["charged_back_cents"] == 5
    assert result["revision"] == 5
    assert group(conn, "target") == before
    # First five cents own six cents of entitlement; the next five own five.
    assert credit(conn) == 0
    assert ledger(conn)["credit_shortfall_cents"] == 3
    assert ledger(conn)["credit_liability_cents"] == 8
    batch(conn, [operation("cancel_group", %{"group_id" => "target"})])
    assert credit(conn) == 5
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 5
    batch(conn, [correction("charge_back_payment", "a-pay")])
    assert credit(conn) == 0
    assert ledger(conn)["cash_charged_back_cents"] == 10
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "entitlement rounding is independent for each lot and restoration absorbs before expiry",
       %{conn: conn} do
    batch(conn, [
      booking([5, 5, 10]),
      cash("pay", 10),
      operation("cancel_rooms", %{"room_ids" => ["z"], "refund_method" => "hotel_credit"}),
      operation("cancel_rooms", %{"room_ids" => ["a"], "refund_method" => "hotel_credit"}),
      booking([4, 4, 4], "target"),
      operation("reschedule_group", %{"group_id" => "target", "new_arrival_on" => "2029-01-01"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 12}),
      correction("charge_back_payment", "pay")
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 12
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 12

    batch(conn, [
      operation("cancel_rooms", %{
        "group_id" => "target",
        "room_ids" => ["z"],
        "occurred_on" => "2028-01-01"
      })
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 8
    assert ledger(conn)["credit_liability_cents"] == 8
    assert Enum.sum(Enum.map(Repo.all(CreditLot), & &1.unrecovered_clawback_cents)) == 8

    batch(conn, [
      operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2028-12-31"})
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
    # Non-refundable use extinguishes liability, not the unrecovered audit amount.
    assert Enum.sum(Enum.map(Repo.all(CreditLot), & &1.unrecovered_clawback_cents)) == 8
  end

  test "partial cancellation restores just the selected credit to original lots", %{conn: conn} do
    issue_credit(conn, 100)

    batch(conn, [
      booking(),
      operation("apply_hotel_credit", %{"amount_cents" => 110}),
      cash("pay", 100)
    ])

    assert room_balances(conn) == [
             {"z", "active", 0, 100},
             {"a", "active", 90, 10},
             {"m", "active", 10, 0}
           ]

    [result] = batch(conn, [operation("cancel_rooms", %{"room_ids" => ["a"]})])
    assert result["refunded_cents"] == 90
    assert credit(conn) == 10
    assert ledger(conn)["credit_liability_cents"] == 110

    assert room_balances(conn) == [
             {"z", "active", 0, 100},
             {"a", "cancelled", 0, 0},
             {"m", "active", 10, 0}
           ]

    batch(conn, [operation("cancel_group", %{"occurred_on" => "2026-12-09"})])
    assert ledger(conn)["credit_liability_cents"] == 10
    assert ledger(conn)["cash_retained_cents"] == 10
  end

  test "statement errors, target validation, conflicts, and reads leave accounting unchanged", %{
    conn: conn
  } do
    [opened, rejected, _] = batch(conn, [booking(), cash("bad", 999), cash("pay", 20)])

    assert conn |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    for target <- [opened["operation_id"], rejected["operation_id"]] do
      assert conn |> get("/api/v1/payments/#{target}") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert [%{"code" => "payment_not_chargeable"}] =
               batch(conn, [correction("charge_back_payment", target)])
    end

    assert [%{"code" => "operation_not_found"}] =
             batch(conn, [correction("charge_back_payment", "missing")])

    assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
             batch(conn, [correction("charge_back_payment", "pay", %{"expected_revision" => 1})])

    reduce = correction("reduce_cash_payment", "pay", %{"amount_cents" => 5})
    batch(conn, [reduce])
    before = snapshot()

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(reduce, "amount_cents", 6)])

    assert statement(conn, "pay") == statement_data("pay", 20, held_cents: 15, reduced_cents: 5)
    assert snapshot() == before
    record = Repo.get_by!(OperationRecord, operation_id: reduce["operation_id"])
    assert record.type == "reduce_cash_payment"
    assert record.payload == reduce
  end

  test "cancelling the final zero-priced and unpaid rooms ends the group", %{conn: conn} do
    batch(conn, [booking([0, 100, 100]), cash("pay", 50)])

    [partial, final, inactive] =
      batch(conn, [
        operation("cancel_rooms", %{"room_ids" => ["a"]}),
        operation("cancel_rooms", %{"room_ids" => ["m", "z"]}),
        operation("cancel_group")
      ])

    assert partial["refunded_cents"] == 50
    assert final["cancelled_room_ids"] == ["z", "m"]
    assert final["refunded_cents"] == 0
    assert final["credit_issued_cents"] == 0
    assert final["revision"] == 4
    assert inactive["code"] == "group_not_active"
    saved = group(conn)
    assert saved["status"] == "cancelled"
    assert saved["deposit_due_cents"] == 0
    assert saved["outstanding_deposit_cents"] == 0
    assert saved["lodging_total_cents"] == 0
    assert statement(conn, "pay") == statement_data("pay", 50, refunded_cents: 50)
  end

  test "reductions cannot touch settled cash and chargebacks revoke expired unspent credit", %{
    conn: conn
  } do
    batch(conn, [
      booking(),
      cash("pay", 150),
      operation("cancel_rooms", %{"room_ids" => ["z"], "refund_method" => "hotel_credit"})
    ])

    [excess, reduced] =
      batch(conn, [
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 51}),
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 50})
      ])

    assert excess["code"] == "reduction_exceeds_held_cash"
    assert reduced["outstanding_deposit_cents"] == 200
    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 0

    [charged] =
      batch(conn, [correction("charge_back_payment", "pay", %{"occurred_on" => "2028-01-01"})])

    assert charged["charged_back_cents"] == 100

    assert statement(conn, "pay") ==
             statement_data("pay", 150, reduced_cents: 50, charged_back_cents: 100)

    assert ledger(conn)["credit_liability_cents"] == 0
    assert ledger(conn)["credit_shortfall_cents"] == 0
  end

  defp booking(amounts \\ [100, 100, 100], group_id \\ "group-81") do
    rooms =
      Enum.zip(["z", "a", "m", "b", "c"], amounts)
      |> Enum.map(fn {id, due} -> %{"room_id" => id, "nightly_rate_cents" => due * 5} end)

    open_group(%{
      "group_id" => group_id,
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rooms" => rooms
    })
  end

  defp cash(id, amount, date \\ "2026-11-01"),
    do:
      operation("record_cash_payment", %{
        "operation_id" => id,
        "amount_cents" => amount,
        "occurred_on" => date
      })

  defp correction(type, target, attrs \\ %{}) do
    operation(type, Map.merge(%{"payment_operation_id" => target}, attrs))
    |> Map.delete("group_id")
  end

  defp issue_credit(conn, amount) do
    batch(conn, [
      booking([amount], "source"),
      cash("source-pay", amount) |> Map.put("group_id", "source"),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])
  end

  defp batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id \\ "group-81"),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn, on \\ "2026-11-01"),
    do: conn |> get("/api/v1/ledger", %{"on" => on}) |> json_response(200) |> Map.fetch!("data")

  defp credit(conn),
    do:
      conn
      |> get("/api/v1/guests/guest-22/credit", %{"on" => "2026-11-01"})
      |> json_response(200)
      |> get_in(["data", "available_cents"])

  defp statement(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp statement_data(id, recorded, amounts) do
    Map.merge(
      %{
        "payment_operation_id" => id,
        "original_group_id" => "group-81",
        "recorded_cents" => recorded,
        "held_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      Map.new(amounts, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp room_balances(conn) do
    Enum.map(
      group(conn)["rooms"],
      &{&1["room_id"], &1["status"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
    )
  end

  defp snapshot do
    for schema <- [Group, Room, RoomAllocation, CreditLot, CreditAllocation, CreditEntitlement],
        do: Repo.all(schema)
  end
end
