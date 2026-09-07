defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixtures
  alias GroupStay.{Credits, Operations, Repo, Reservations}

  test "funding fills rooms in processing order and reductions reopen only the target payment", %{
    conn: conn
  } do
    batch(conn, [
      opening("source", [100]),
      cash("source", "source-pay", 100),
      cancel("source", "source-credit", %{"refund_method" => "hotel_credit"}),
      opening("target", [100, 100, 100]),
      cash("target", "first", 150),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
      cash("target", "second", 40)
    ])

    assert room_funding("target") == [{100, 0}, {50, 50}, {40, 30}]
    original = Operations.get_result("first")

    reduction =
      correction("reduce_cash_payment", "first", %{"amount_cents" => 60, "expected_revision" => 4})

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 90}] = batch(conn, [reduction])
    assert room_funding("target") == [{90, 0}, {0, 50}, {40, 30}]
    batch(conn, [cash("target", "third", 15)])
    assert room_funding("target") == [{100, 0}, {5, 50}, {40, 30}]

    assert [%{"cancelled_room_ids" => ["r2"], "refunded_cents" => 5, "revision" => 7}] =
             batch(conn, [cancel_rooms("target", ["r2"])])

    assert room_funding("target") == [{100, 0}, {0, 0}, {40, 30}]
    group = Reservations.get_group("target")

    assert {group.deposit_due_cents, group.deposit_paid_cents, group.lodging_total_cents} ==
             {200, 170, 1000}

    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 80

    assert statement(conn, "first") == %{
             "payment_operation_id" => "first",
             "original_group_id" => "target",
             "recorded_cents" => 150,
             "held_cents" => 90,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 60,
             "charged_back_cents" => 0
           }

    assert Operations.get_result("first") == original
    assert batch(conn, [reduction]) |> hd() |> Map.fetch!("revision") == 5

    assert [%{"revision" => 8, "refunded_cents" => 140}] =
             batch(conn, [cancel("target", "finish")])

    assert Reservations.get_group("target").status == "cancelled"
    assert Reservations.get_group("target").lodging_total_cents == 0
    assert Reservations.ledger(~D[2026-10-04]).cash_reduced_cents == 60
    assert_conserved(conn, ["source-pay", "first", "second", "third"])
  end

  test "selected rooms use one combined bonus and return original room order", %{conn: conn} do
    batch(conn, [opening("g", [5, 5]), cash("g", "p", 10)])
    cancellation = cancel_rooms("g", ["r2", "r1"], %{"refund_method" => "hotel_credit"})

    assert [result = %{"cancelled_room_ids" => ["r1", "r2"], "credit_issued_cents" => 11}] =
             batch(conn, [cancellation])

    assert batch(conn, [cancellation]) == [result]
    assert Reservations.get_group("g").status == "cancelled"
    assert statement(conn, "p")["converted_to_credit_cents"] == 10
  end

  test "invalid room selections are atomic and revision checks take precedence", %{conn: conn} do
    batch(conn, [opening("g", [100, 100]), cash("g", "p", 150)])
    before = snapshot()

    for ids <- [[], nil, "r1", ["r1", "r1"], ["r1", "missing"], [nil]] do
      assert [%{"code" => "invalid_rooms"}] = batch(conn, [cancel_rooms("g", ids)])
      assert snapshot() == before
    end

    assert [%{"code" => "stale_revision", "actual_revision" => 2}] =
             batch(conn, [cancel_rooms("g", [], %{"expected_revision" => 0})])

    assert [%{"code" => "refund_method_not_available"}] =
             batch(conn, [
               cancel_rooms("g", ["r1"], %{
                 "occurred_on" => "2026-12-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert snapshot() == before
    batch(conn, [cancel_rooms("g", ["r1"])])
    assert [%{"code" => "invalid_rooms"}] = batch(conn, [cancel_rooms("g", ["r1", "r2"])])
    assert Reservations.get_group("g").revision == 3
  end

  test "reductions compose to the exact remaining held amount and preserve settled history", %{
    conn: conn
  } do
    batch(conn, [opening("g", [100, 100]), cash("g", "p", 180), cancel_rooms("g", ["r1"])])

    assert [%{"code" => "reduction_exceeds_held_cash"}] =
             batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 81})])

    for amount <- [0, -1, 1.5, "1", nil] do
      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => amount})])
    end

    batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 30})])

    assert [%{"amount_cents" => 50, "outstanding_deposit_cents" => 100}] =
             batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 50})])

    assert [%{"code" => "payment_not_reducible"}] =
             batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 1})])

    assert statement(conn, "p")["refunded_cents"] == 100
    assert statement(conn, "p")["reduced_cents"] == 80
    assert_conserved(conn, ["p"])
  end

  test "chargeback reclassifies all dispositions except reductions and only revises the source group",
       %{conn: conn} do
    batch(conn, [
      opening("g", [100, 100, 100, 100, 100]),
      cash("g", "p", 500),
      correction("reduce_cash_payment", "p", %{"amount_cents" => 50}),
      cancel_rooms("g", ["r1"]),
      cancel_rooms("g", ["r2"], %{"occurred_on" => "2026-12-01"}),
      cancel_rooms("g", ["r3"], %{"refund_method" => "hotel_credit"}),
      opening("target", [100]),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    assert Map.take(
             statement(conn, "p"),
             ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents)
           ) ==
             %{
               "held_cents" => 150,
               "refunded_cents" => 100,
               "retained_cents" => 100,
               "converted_to_credit_cents" => 100,
               "reduced_cents" => 50
             }

    target = Reservations.get_group("target")
    chargeback = correction("charge_back_payment", "p", %{"expected_revision" => 6})

    assert [
             result = %{
               "revision" => 7,
               "charged_back_cents" => 450,
               "outstanding_deposit_cents" => 200
             }
           ] = batch(conn, [chargeback])

    assert Reservations.get_group("target") == target
    ledger = Reservations.ledger(~D[2026-10-04])

    assert {ledger.cash_refunded_cents, ledger.cash_retained_cents,
            ledger.cash_converted_to_credit_cents} == {0, 0, 0}

    assert {ledger.cash_charged_back_cents, ledger.credit_liability_cents,
            ledger.credit_shortfall_cents} == {450, 80, 80}

    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 0
    assert batch(conn, [chargeback]) == [result]

    assert [%{"code" => "payment_not_chargeable"}] =
             batch(conn, [correction("charge_back_payment", "p")])

    assert [%{"code" => "payment_not_reducible"}] =
             batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 1})])

    batch(conn, [cancel("target", "restore")])
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 0
    assert_conserved(conn, ["p"])
  end

  test "lot entitlements telescope in funding order at rounding boundaries", %{conn: conn} do
    batch(conn, [
      opening("g", [5, 5]),
      cash("g", "z-first", 4),
      cash("g", "a-second", 1),
      cash("g", "m-third", 5),
      cancel("g", "lot", %{"refund_method" => "hotel_credit"})
    ])

    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 11
    batch(conn, [correction("charge_back_payment", "a-second")])
    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 9
    batch(conn, [correction("charge_back_payment", "z-first")])
    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 5
    batch(conn, [correction("charge_back_payment", "m-third")])
    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 0
    assert_conserved(conn, ["z-first", "a-second", "m-third"])
  end

  test "one payment's entitlement is calculated separately for each issued lot", %{conn: conn} do
    batch(conn, [
      opening("g", [5, 5]),
      cash("g", "p", 10),
      cancel_rooms("g", ["r1"], %{"refund_method" => "hotel_credit"}),
      cancel_rooms("g", ["r2"], %{"refund_method" => "hotel_credit"})
    ])

    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 12
    batch(conn, [correction("charge_back_payment", "p")])
    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 0
    assert Reservations.ledger(~D[2026-10-04]).cash_charged_back_cents == 10
  end

  for {name, date, refundable} <- [
        {"unexpired", "2026-10-04", true},
        {"expired", "2028-01-01", true},
        {"consumed", "2028-11-30", false}
      ] do
    test "shortfalls handle #{name} restorations or settlement", %{conn: conn} do
      batch(conn, [
        opening("g", [100]),
        cash("g", "first", 50),
        cash("g", "second", 50),
        cancel("g", "lot", %{"refund_method" => "hotel_credit"}),
        opening("target", [40, 40], %{
          "arrival_on" => "2028-12-10",
          "departure_on" => "2028-12-11"
        }),
        operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
        correction("charge_back_payment", "first")
      ])

      # 55 entitlement, 30 available revoked, 25 unrecovered; spending is fungible.
      assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 25
      batch(conn, [cancel_rooms("target", ["r1"], %{"occurred_on" => unquote(date)})])
      ledger = Reservations.ledger(Date.from_iso8601!(unquote(date)))
      assert ledger.credit_shortfall_cents == if(unquote(refundable), do: 0, else: 25)
      assert ledger.credit_liability_cents == if(unquote(name) == "unexpired", do: 55, else: 40)

      assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents ==
               if(unquote(name) == "unexpired", do: 15, else: 0)

      batch(conn, [cancel_rooms("target", ["r2"], %{"occurred_on" => unquote(date)})])
      assert Reservations.ledger(~D[2028-11-30]).credit_shortfall_cents == 0
    end
  end

  test "shortfall is capped by active credit per lot and cannot absorb another lot's returns", %{
    conn: conn
  } do
    batch(conn, [
      opening("source", [100]),
      cash("source", "p", 100),
      cancel("source", "first-lot", %{"refund_method" => "hotel_credit"}),
      opening("target", [60, 40]),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 100}),
      cancel_rooms("target", ["r1"], %{"occurred_on" => "2026-12-01"}),
      opening("source2", [100]),
      cash("source2", "p2", 100),
      cancel("source2", "second-lot", %{"refund_method" => "hotel_credit"}),
      correction("charge_back_payment", "p")
    ])

    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 40
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 150

    batch(conn, [
      opening("other", [20]),
      operation("apply_hotel_credit", %{"group_id" => "other", "amount_cents" => 20}),
      cancel("other", "return-other-lot")
    ])

    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 110
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 40
    batch(conn, [cancel_rooms("target", ["r2"])])
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 110
    assert_conserved(conn, ["p", "p2"])
  end

  test "new operations require identifying data and stale revisions precede exhausted-payment rules",
       %{conn: conn} do
    batch(conn, [opening("g", [100]), cash("g", "p", 100)])

    for invalid <- [
          operation("cancel_rooms", %{"group_id" => "g"}),
          operation("reduce_cash_payment", %{"amount_cents" => 1}),
          correction("reduce_cash_payment", "p"),
          correction("charge_back_payment", "p") |> Map.delete("occurred_on")
        ] do
      assert [%{"code" => "invalid_operation"}] = batch(conn, [invalid])
    end

    batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 100})])

    for type <- ["charge_back_payment", "reduce_cash_payment"] do
      assert [%{"code" => "stale_revision", "actual_revision" => 3}] =
               batch(conn, [
                 correction(type, "p", %{"expected_revision" => 2, "amount_cents" => -1})
               ])
    end
  end

  test "payment lookups distinguish missing and ineligible receipts and never mutate state", %{
    conn: conn
  } do
    opening = opening("g", [100])
    rejected = cash("g", "bad", 101)
    batch(conn, [opening, rejected, cash("g", "p", 100)])

    for {id, status, code} <- [
          {"missing", 404, "operation_not_found"},
          {opening["operation_id"], 422, "payment_not_reconcilable"},
          {"bad", 422, "payment_not_reconcilable"}
        ] do
      assert conn |> get("/api/v1/payments/#{id}") |> json_response(status) == %{
               "error" => %{"code" => code}
             }
    end

    before = snapshot()
    assert statement(conn, "p") == statement(conn, "p")
    assert snapshot() == before

    for {type, code} <- [
          {"reduce_cash_payment", "payment_not_reducible"},
          {"charge_back_payment", "payment_not_chargeable"}
        ] do
      assert [%{"code" => "operation_not_found"}] =
               batch(conn, [correction(type, "missing", %{"amount_cents" => 1})])

      for id <- ["bad", opening["operation_id"]] do
        assert [%{"code" => ^code}] = batch(conn, [correction(type, id, %{"amount_cents" => 1})])
      end
    end

    batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 100})])

    assert [%{"code" => "payment_not_chargeable"}] =
             batch(conn, [correction("charge_back_payment", "p")])
  end

  test "new operation rejections and successes are immutable under retries and conflicts", %{
    conn: conn
  } do
    payment = cash("g", "p", 100)
    missing = correction("reduce_cash_payment", "p", %{"amount_cents" => 10})
    [rejected] = batch(conn, [missing])
    batch(conn, [opening("g", [100]), payment])
    assert batch(conn, [missing]) == [rejected]
    stale = correction("charge_back_payment", "p", %{"expected_revision" => 1})
    assert [result = %{"code" => "stale_revision", "actual_revision" => 2}] = batch(conn, [stale])
    batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 20})])
    assert batch(conn, [stale]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(stale, "expected_revision", 3)])

    before = snapshot()
    assert [%{"revision" => 2, "outstanding_deposit_cents" => 0}] = batch(conn, [payment])
    assert snapshot() == before
  end

  defp opening(id, deposits, overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{
          "group_id" => id,
          "departure_on" => "2026-12-11",
          "rooms" =>
            Enum.with_index(deposits, 1)
            |> Enum.map(fn {due, index} ->
              %{"room_id" => "r#{index}", "nightly_rate_cents" => due * 5}
            end)
        },
        overrides
      )
    )
  end

  defp cash(group, id, amount),
    do:
      operation("record_cash_payment", %{
        "group_id" => group,
        "operation_id" => id,
        "amount_cents" => amount
      })

  defp cancel(group, id, overrides \\ %{}),
    do:
      operation(
        "cancel_group",
        Map.merge(%{"group_id" => group, "operation_id" => id}, overrides)
      )

  defp cancel_rooms(group, ids, overrides \\ %{}),
    do: operation("cancel_rooms", Map.merge(%{"group_id" => group, "room_ids" => ids}, overrides))

  defp correction(type, id, overrides \\ %{}),
    do:
      operation(type, Map.merge(%{"payment_operation_id" => id}, overrides))
      |> Map.delete("group_id")

  defp room_funding(id),
    do: Reservations.get_group(id).rooms |> Enum.map(&{&1.cash_paid_cents, &1.credit_paid_cents})

  defp batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp statement(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp snapshot do
    Enum.map(
      [
        GroupStay.Reservations.Group,
        GroupStay.Credits.Lot,
        GroupStay.Credits.Allocation,
        GroupStay.Accounting.CashAllocation,
        GroupStay.Accounting.CreditEntitlement
      ],
      &Repo.all/1
    )
  end

  defp assert_conserved(conn, ids) do
    statements = Enum.map(ids, &statement(conn, &1))

    fields =
      ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)

    for statement <- statements do
      assert Enum.sum(Enum.map(fields, &statement[&1])) == statement["recorded_cents"]
      assert Enum.all?(fields, &(statement[&1] >= 0))
    end

    ledger = Reservations.ledger(~D[2026-10-04]) |> Jason.encode!() |> Jason.decode!()

    for field <- fields do
      assert Enum.sum(Enum.map(statements, & &1[field])) == ledger["cash_" <> field]
    end
  end
end
