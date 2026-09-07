defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixtures

  alias GroupStay.{Credit, Payments, Repo, Reservations}
  alias GroupStay.Credit.{Allocation, Entitlement, Lot}
  alias GroupStay.Operations.Operation
  alias GroupStay.Payments.Payment
  alias GroupStay.Reservations.{Group, RoomFunding}

  test "cash and credit fill in processing order; selected rooms settle without moving other funding",
       %{conn: conn} do
    issue_credit(conn, "source", 100)
    first = cash("first", 120, %{"occurred_on" => "2026-10-10"})
    second = cash("second", 60, %{"occurred_on" => "2026-10-05"})

    batch(conn, [
      booking(),
      first,
      operation("apply_hotel_credit", %{"amount_cents" => 100}),
      second
    ])

    assert room_balances(conn) == [
             {"b", "active", 100, 0},
             {"a", "active", 20, 80},
             {"c", "active", 60, 20}
           ]

    assert [%{"cancelled_room_ids" => ["b", "c"], "refunded_cents" => 160, "revision" => 5}] =
             batch(conn, [
               operation("cancel_rooms", %{"room_ids" => ["c", "b"], "expected_revision" => 4})
             ])

    assert room_balances(conn) == [
             {"b", "cancelled", 0, 0},
             {"a", "active", 20, 80},
             {"c", "cancelled", 0, 0}
           ]

    assert %{
             "lodging_total_cents" => 500,
             "deposit_due_cents" => 100,
             "deposit_paid_cents" => 100,
             "outstanding_deposit_cents" => 0,
             "cash_paid_cents" => 20,
             "credit_paid_cents" => 80
           } = group(conn)

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 30
    assert %{"held_cents" => 20, "refunded_cents" => 100} = statement(conn, "first")
    assert %{"held_cents" => 0, "refunded_cents" => 60} = statement(conn, "second")

    assert [%{"refunded_cents" => 20, "revision" => 6}] = batch(conn, [operation("cancel_group")])
    assert group(conn)["status"] == "cancelled"
    assert group(conn)["lodging_total_cents"] == 0
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 110
    assert_invariants(conn)
  end

  test "partial hotel credit settlement rounds its combined cash once and preserves room order",
       %{conn: conn} do
    batch(conn, [booking(15), cash("pay", 5)])

    cancel =
      operation("cancel_rooms", %{
        "operation_id" => "convert",
        "room_ids" => ["a", "b"],
        "refund_method" => "hotel_credit"
      })

    assert [result] = batch(conn, [cancel])

    assert %{
             "cancelled_room_ids" => ["b", "a"],
             "credit_issued_cents" => 6,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "revision" => 3
           } = result

    assert [^result] = batch(conn, [cancel])
    assert %{"held_cents" => 0, "converted_to_credit_cents" => 5} = statement(conn, "pay")
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 6
    assert group(conn)["deposit_due_cents"] == 3
    assert_invariants(conn)
  end

  test "reductions remove only their payment in reverse fill order and compose with settlements",
       %{conn: conn} do
    payment = cash("pay", 220)
    [_, original, _] = batch(conn, [booking(), payment, cash("other", 50)])

    reduction =
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 50, "expected_revision" => 3})

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 80}] = batch(conn, [reduction])

    assert room_balances(conn) == [
             {"b", "active", 100, 0},
             {"a", "active", 70, 0},
             {"c", "active", 50, 0}
           ]

    assert [%{"refunded_cents" => 70}, %{"revision" => 6, "outstanding_deposit_cents" => 150}] =
             batch(conn, [
               operation("cancel_rooms", %{"room_ids" => ["a"]}),
               correction("reduce_cash_payment", "pay", %{"amount_cents" => 100})
             ])

    assert %{
             "recorded_cents" => 220,
             "held_cents" => 0,
             "refunded_cents" => 70,
             "reduced_cents" => 150
           } = statement(conn, "pay")

    assert [^original] = batch(conn, [payment])

    assert [%{"code" => "payment_not_reducible"}] =
             batch(conn, [correction("reduce_cash_payment", "pay", %{"amount_cents" => 1})])

    assert [%{"charged_back_cents" => 70, "revision" => 7}] =
             batch(conn, [correction("charge_back_payment", "pay")])

    assert %{"refunded_cents" => 0, "charged_back_cents" => 70, "reduced_cents" => 150} =
             statement(conn, "pay")

    batch(conn, [cash("refill", 110)])

    assert room_balances(conn) == [
             {"b", "active", 100, 0},
             {"a", "cancelled", 0, 0},
             {"c", "active", 60, 0}
           ]

    assert_invariants(conn)
  end

  test "chargeback reclassifies held, refunded, retained and converted cash while preserving reductions",
       %{conn: conn} do
    payment = cash("pay", 400)
    [_, original] = batch(conn, [booking(500, ["b", "a", "c", "d"]), payment])

    batch(conn, [
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 25}),
      operation("cancel_rooms", %{"room_ids" => ["b"]}),
      operation("cancel_rooms", %{"room_ids" => ["a"], "refund_method" => "hotel_credit"}),
      operation("cancel_rooms", %{"room_ids" => ["c"], "occurred_on" => "2026-12-01"})
    ])

    assert %{
             "held_cents" => 75,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 25
           } = statement(conn, "pay")

    chargeback = correction("charge_back_payment", "pay", %{"expected_revision" => 6})
    assert [result] = batch(conn, [chargeback])

    assert %{"charged_back_cents" => 375, "revision" => 7, "outstanding_deposit_cents" => 100} =
             result

    assert [^result, ^original] = batch(conn, [chargeback, payment])

    assert %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 25,
             "cash_charged_back_cents" => 375,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           } = ledger(conn)

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 0

    assert [%{"code" => "payment_not_chargeable"}] =
             batch(conn, [correction("charge_back_payment", "pay")])

    assert_invariants(conn)
  end

  test "entitlements telescope in funding order independently for each lot", %{conn: conn} do
    batch(conn, [
      booking(25, ["b", "a"]),
      cash("first", 4),
      cash("second", 6),
      operation("cancel_rooms", %{
        "operation_id" => "lot-one",
        "room_ids" => ["b"],
        "refund_method" => "hotel_credit"
      }),
      operation("cancel_rooms", %{
        "operation_id" => "lot-two",
        "room_ids" => ["a"],
        "refund_method" => "hotel_credit"
      })
    ])

    assert Enum.map(Repo.all(Entitlement), &{&1.payment_operation_id, &1.amount_cents}) == [
             {"first", 4},
             {"second", 2},
             {"second", 6}
           ]

    assert [%{"charged_back_cents" => 6, "revision" => 6}] =
             batch(conn, [correction("charge_back_payment", "second")])

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 4
    assert %{"status" => "cancelled", "revision" => 6} = group(conn)

    assert %{"converted_to_credit_cents" => 4, "charged_back_cents" => 0} =
             statement(conn, "first")

    assert_invariants(conn)
  end

  test "fungible credit is clawed from available balance first, then absorbed on restoration", %{
    conn: conn
  } do
    batch(conn, [
      booking(),
      cash("first", 50),
      cash("second", 50),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      booking(250, ["x", "y"], "target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100})
    ])

    target_before = Reservations.get_group("target")

    assert [%{"charged_back_cents" => 50, "revision" => 5}] =
             batch(conn, [correction("charge_back_payment", "first")])

    assert Reservations.get_group("target") == target_before
    assert %{"credit_liability_cents" => 100, "credit_shortfall_cents" => 45} = ledger(conn)
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 0

    assert [%{"revision" => 3}] =
             batch(conn, [
               operation("cancel_rooms", %{"group_id" => "target", "room_ids" => ["x"]})
             ])

    assert %{"credit_liability_cents" => 55, "credit_shortfall_cents" => 0} = ledger(conn)
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 5
    batch(conn, [operation("cancel_group", %{"group_id" => "target"})])
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 55
    assert_invariants(conn)
  end

  test "unrecovered clawback survives nonrefundable consumption and absorbs restoration before expiry",
       %{conn: conn} do
    issue_credit(conn, "source", 100, "source-pay")

    batch(conn, [
      booking(250, ["x", "y"], "target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100}),
      correction("charge_back_payment", "source-pay")
    ])

    assert %{"credit_liability_cents" => 100, "credit_shortfall_cents" => 100} = ledger(conn)

    batch(conn, [
      operation("cancel_rooms", %{
        "group_id" => "target",
        "room_ids" => ["x"],
        "occurred_on" => "2026-12-01"
      })
    ])

    assert %{"credit_liability_cents" => 50, "credit_shortfall_cents" => 50} = ledger(conn)
    assert Repo.one!(Lot).unrecovered_clawback_cents == 100

    batch(conn, [
      operation("reschedule_group", %{"group_id" => "target", "new_arrival_on" => "2028-01-01"}),
      operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-11-01"})
    ])

    assert Repo.one!(Lot).unrecovered_clawback_cents == 50
    assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} = ledger(conn)
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 0
    assert_invariants(conn)
  end

  test "credit restored beyond a shortfall expires instead of becoming available", %{conn: conn} do
    batch(conn, [
      booking(),
      cash("first", 50),
      cash("second", 50),
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      booking(550, ["x"], "target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      correction("charge_back_payment", "first"),
      operation("reschedule_group", %{"group_id" => "target", "new_arrival_on" => "2028-01-01"}),
      operation("cancel_group", %{"group_id" => "target", "occurred_on" => "2027-11-01"})
    ])

    assert Repo.one!(Lot).unrecovered_clawback_cents == 0
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 0
    assert %{"credit_liability_cents" => 0, "credit_shortfall_cents" => 0} = ledger(conn)
    assert_invariants(conn)
  end

  test "shortfall is local to its lot and multiple chargebacks accumulate without attributing spending",
       %{conn: conn} do
    issue_credit(conn, "unrelated", 100)

    batch(conn, [
      booking(),
      cash("first", 50),
      cash("second", 50),
      operation("cancel_group", %{"operation_id" => "a-lot", "refund_method" => "hotel_credit"}),
      booking(550, ["x"], "target"),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 110}),
      correction("charge_back_payment", "first"),
      correction("charge_back_payment", "second")
    ])

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 110
    assert %{"credit_liability_cents" => 220, "credit_shortfall_cents" => 110} = ledger(conn)
    batch(conn, [operation("cancel_group", %{"group_id" => "target"})])
    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 110
    assert %{"credit_liability_cents" => 110, "credit_shortfall_cents" => 0} = ledger(conn)
    assert_invariants(conn)
  end

  test "new operation rejections leave domain state unchanged, are remembered, and honor derived revisions",
       %{conn: conn} do
    batch(conn, [booking(), cash("pay", 100)])

    invalid =
      [
        {operation("cancel_rooms", %{"room_ids" => []}), "invalid_rooms"},
        {operation("cancel_rooms", %{"room_ids" => ["b", "b"]}), "invalid_rooms"},
        {operation("cancel_rooms", %{"room_ids" => ["b", "missing"]}), "invalid_rooms"},
        {operation("cancel_rooms", %{"room_ids" => "b"}), "invalid_rooms"},
        {operation("cancel_rooms", %{"room_ids" => ["b"], "refund_method" => "invalid"}),
         "invalid_operation"},
        {operation("cancel_rooms", %{
           "room_ids" => ["b"],
           "refund_method" => "hotel_credit",
           "occurred_on" => "2026-12-01"
         }), "refund_method_not_available"},
        {correction("reduce_cash_payment", "missing", %{"amount_cents" => 1}),
         "operation_not_found"},
        {correction("charge_back_payment", "missing"), "operation_not_found"},
        {correction("reduce_cash_payment", "pay", %{"amount_cents" => 101}),
         "reduction_exceeds_held_cash"}
      ] ++
        for amount <- [0, -1, nil, 1.5, "1", true],
            do:
              {correction("reduce_cash_payment", "pay", %{"amount_cents" => amount}),
               "invalid_amount"}

    for {op, code} <- invalid do
      before = snapshot()
      assert [result] = batch(conn, [op])
      assert result["code"] == code
      assert snapshot() == before
      assert [^result] = batch(conn, [op])
    end

    for op <- [
          operation("cancel_rooms", %{"room_ids" => nil}),
          correction("reduce_cash_payment", "pay", %{"amount_cents" => -1}),
          correction("charge_back_payment", "pay")
        ] do
      assert [%{"code" => "stale_revision", "group_id" => "group-81", "actual_revision" => 2}] =
               batch(conn, [Map.put(op, "expected_revision", 1)])
    end

    stale =
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 1, "expected_revision" => 1})

    [stored] = batch(conn, [stale])
    batch(conn, [operation("cancel_rooms", %{"room_ids" => ["b"]})])

    assert [^stored, %{"code" => "operation_id_conflict"}] =
             batch(conn, [stale, Map.put(stale, "expected_revision", 3)])

    assert [
             %{"code" => "stale_revision"},
             %{"code" => "payment_not_reducible"},
             %{"code" => "invalid_rooms"}
           ] =
             batch(conn, [
               correction("reduce_cash_payment", "pay", %{
                 "amount_cents" => 1,
                 "expected_revision" => 2
               }),
               correction("reduce_cash_payment", "pay", %{"amount_cents" => 0}),
               operation("cancel_rooms", %{"room_ids" => ["b"]})
             ])

    assert_invariants(conn)
  end

  test "payment statements reject missing, rejected and nonpayment records and never change state",
       %{conn: conn} do
    rejected = cash("rejected", 1)
    opening = booking()
    batch(conn, [rejected, opening, cash("pay", 10)])

    for {id, status, code} <- [
          {"missing", 404, "operation_not_found"},
          {"rejected", 422, "payment_not_reconcilable"},
          {opening["operation_id"], 422, "payment_not_reconcilable"}
        ] do
      assert conn |> get("/api/v1/payments/#{id}") |> json_response(status) == %{
               "error" => %{"code" => code}
             }
    end

    for id <- ["rejected", opening["operation_id"]] do
      assert [%{"code" => "payment_not_reducible"}, %{"code" => "payment_not_chargeable"}] =
               batch(conn, [
                 correction("reduce_cash_payment", id, %{"amount_cents" => 1}),
                 correction("charge_back_payment", id)
               ])
    end

    before = snapshot()

    assert statement(conn, "pay") == %{
             "payment_operation_id" => "pay",
             "original_group_id" => "group-81",
             "recorded_cents" => 10,
             "held_cents" => 10,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert snapshot() == before
    batch(conn, [correction("reduce_cash_payment", "pay", %{"amount_cents" => 10})])

    assert [%{"code" => "payment_not_chargeable"}] =
             batch(conn, [correction("charge_back_payment", "pay")])

    assert_invariants(conn)
  end

  for type <- ~w(cancel_rooms reduce_cash_payment charge_back_payment) do
    test "#{type} rolls back every accounting change when its audit insert fails", %{conn: conn} do
      batch(conn, [
        booking(),
        cash("pay", 300),
        operation("cancel_rooms", %{"room_ids" => ["b"], "refund_method" => "hotel_credit"}),
        booking(500, ["x"], "target"),
        operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100})
      ])

      fault =
        case unquote(type) do
          "cancel_rooms" ->
            operation("cancel_rooms", %{
              "operation_id" => "fault",
              "room_ids" => ["a"],
              "refund_method" => "hotel_credit"
            })

          type ->
            correction(type, "pay", %{"operation_id" => "fault", "amount_cents" => 10})
        end

      before = snapshot()
      audit_before = Repo.all(Operation)

      Repo.query!("""
      CREATE TRIGGER fail_room_audit BEFORE INSERT ON operations
      WHEN NEW.operation_id = 'fault'
      BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
      """)

      assert_raise Exqlite.Error, fn ->
        Reservations.process_batch([fault, booking(500, ["x"], "later")])
      end

      assert snapshot() == before
      assert Repo.all(Operation) == audit_before
      assert Reservations.get_group("later") == nil
      Repo.query!("DROP TRIGGER fail_room_audit")
      assert [result] = batch(conn, [fault])
      assert result["status"] == "applied"
      assert [^result] = batch(conn, [fault])
      assert_invariants(conn)
    end
  end

  test "new operation shapes require an identifier, operation date and operation-specific fields",
       %{conn: conn} do
    batch(conn, [booking(), cash("pay", 100)])

    examples = [
      {operation("cancel_rooms", %{"room_ids" => ["b"]}),
       ~w(operation_id group_id occurred_on room_ids)},
      {correction("reduce_cash_payment", "pay", %{"amount_cents" => 1}),
       ~w(operation_id payment_operation_id occurred_on amount_cents)},
      {correction("charge_back_payment", "pay"),
       ~w(operation_id payment_operation_id occurred_on)}
    ]

    for {example, fields} <- examples, field <- fields do
      before = snapshot()

      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [
                 example
                 |> Map.put("operation_id", "missing-#{field}-#{example["operation_id"]}")
                 |> Map.delete(field)
               ])

      assert snapshot() == before
    end
  end

  defp booking(rate \\ 500, ids \\ ["b", "a", "c"], group_id \\ "group-81") do
    open_group(%{
      "group_id" => group_id,
      "departure_on" => "2026-12-11",
      "rooms" => Enum.map(ids, &%{"room_id" => &1, "nightly_rate_cents" => rate})
    })
  end

  defp cash(id, amount, extra \\ %{}),
    do:
      operation(
        "record_cash_payment",
        Map.merge(%{"operation_id" => id, "amount_cents" => amount}, extra)
      )

  defp correction(type, payment_id, extra \\ %{}),
    do:
      operation(type, Map.put(extra, "payment_operation_id", payment_id))
      |> Map.delete("group_id")

  defp issue_credit(conn, group_id, amount, payment_id \\ nil) do
    batch(conn, [
      booking(500, ["source"], group_id),
      cash(payment_id || "#{group_id}-pay", amount, %{"group_id" => group_id}),
      operation("cancel_group", %{"group_id" => group_id, "refund_method" => "hotel_credit"})
    ])
  end

  defp batch(conn, operations),
    do:
      conn
      |> recycle()
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(conn),
    do: conn |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn),
    do: conn |> get("/api/v1/ledger?on=2026-10-04") |> json_response(200) |> Map.fetch!("data")

  defp statement(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp room_balances(conn),
    do:
      Enum.map(
        group(conn)["rooms"],
        &{&1["room_id"], &1["status"], &1["cash_paid_cents"], &1["credit_paid_cents"]}
      )

  defp snapshot,
    do: Enum.map([Group, Payment, RoomFunding, Lot, Allocation, Entitlement], &Repo.all/1)

  defp assert_invariants(conn) do
    statements =
      Enum.map(Repo.all(Payment), fn p ->
        {:ok, statement} = Payments.statement(p.payment_operation_id)

        assert Enum.sum(
                 Map.values(
                   Map.drop(statement, [
                     :recorded_cents,
                     :payment_operation_id,
                     :original_group_id
                   ])
                 )
               ) == statement.recorded_cents

        statement
      end)

    totals = ledger(conn)

    for field <- ~w(held refunded retained converted_to_credit reduced charged_back) do
      assert totals["cash_#{field}_cents"] ==
               Enum.sum(
                 Enum.map(statements, &Map.fetch!(&1, String.to_existing_atom("#{field}_cents")))
               )
    end

    for group <- Repo.all(Group) do
      active = Enum.filter(group.rooms, &(&1.status == "active"))
      assert group.deposit_due_cents == Enum.sum(Enum.map(active, & &1.deposit_due_cents))

      assert group.deposit_paid_cents ==
               Enum.sum(Enum.map(active, &(&1.cash_paid_cents + &1.credit_paid_cents)))

      assert group.lodging_total_cents == Enum.sum(Enum.map(active, & &1.lodging_total_cents))
    end

    assert Enum.all?(Repo.all(Operation), &is_map(&1.result))
  end
end
