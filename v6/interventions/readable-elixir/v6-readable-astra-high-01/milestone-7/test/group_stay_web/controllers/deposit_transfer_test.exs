defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase
  import GroupStay.OperationFixtures
  alias GroupStay.{Credits, Operations, Repo, Reservations}

  test "mixed funding moves newest slices first and fills destination rooms in draw order", %{
    conn: conn
  } do
    batch(conn, [
      opening("credit-source", [100]),
      cash("credit-source", "seed", 100),
      cancel("credit-source", %{"operation_id" => "lot", "refund_method" => "hotel_credit"}),
      opening("source", [100, 100, 100]),
      opening("destination", [60, 80, 100]),
      cash("source", "first", 150),
      credit("source", 80),
      cash("source", "last", 40),
      cash("destination", "unmoved", 10)
    ])

    before = Reservations.ledger(~D[2026-10-04])
    original_payment = Operations.get_result("first")

    transfer =
      transfer("source", "destination", 150, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 2
      })

    assert [result] = batch(conn, [transfer])

    assert result == %{
             "operation_id" => transfer["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 150,
             "source_outstanding_deposit_cents" => 180,
             "destination_outstanding_deposit_cents" => 80,
             "source_revision" => 5,
             "destination_revision" => 3
           }

    assert room_funding("source") == [{100, 0}, {20, 0}, {0, 0}]
    assert room_funding("destination") == [{50, 10}, {10, 70}, {20, 0}]
    assert Reservations.ledger(~D[2026-10-04]) == before

    assert held_by_group(conn, "first") == [
             %{"group_id" => "destination", "amount_cents" => 30},
             %{"group_id" => "source", "amount_cents" => 120}
           ]

    refute Map.has_key?(statement(conn, "unmoved"), "held_by_group")
    assert Operations.get_result("first") == original_payment
    snapshot = snapshot()
    assert batch(conn, [transfer]) == [result]

    assert conn |> get("/api/v1/operations/#{transfer["operation_id"]}") |> json_response(200) ==
             %{"data" => result}

    assert snapshot() == snapshot

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(transfer, "amount_cents", 1)])

    # A second transfer draws the new destination allocations in reverse order.
    batch(conn, [transfer("destination", "source", 50)])
    assert room_funding("source") == [{100, 0}, {50, 20}, {0, 0}]
    assert room_funding("destination") == [{50, 10}, {0, 50}, {0, 0}]
    assert Reservations.ledger(~D[2026-10-04]) == before
    assert_conserved(conn, ["seed", "first", "last", "unmoved"])
  end

  test "existence and both revision guards precede transfer rules and rejections are durable", %{
    conn: conn
  } do
    batch(conn, [opening("source", [100]), opening("destination", [100]), cash("source", "p", 70)])

    missing = transfer("absent-source", "absent-destination", 1)

    assert [%{"code" => "group_not_found", "group_id" => "absent-source"}] =
             batch(conn, [missing])

    batch(conn, [opening("absent-source", [100])])
    assert [%{"group_id" => "absent-source"}] = batch(conn, [missing])

    assert [%{"code" => "group_not_found", "group_id" => "absent-destination"}] =
             batch(conn, [
               transfer("source", "absent-destination", 1, %{"expected_revision" => 0})
             ])

    before = snapshot()

    assert [
             %{
               "code" => "stale_revision",
               "group_id" => "source",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
           ] =
             batch(conn, [
               transfer("source", "destination", -1, %{
                 "expected_revision" => 1,
                 "destination_expected_revision" => 0
               })
             ])

    stale =
      transfer("source", "destination", -1, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 0
      })

    assert [
             result = %{
               "code" => "stale_revision",
               "group_id" => "destination",
               "expected_revision" => 0,
               "actual_revision" => 1
             }
           ] = batch(conn, [stale])

    assert snapshot() == before
    batch(conn, [transfer("source", "destination", 10)])
    assert batch(conn, [stale]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(stale, "destination_expected_revision", 2)])

    for value <- [nil, "2", 2.0, %{"revision" => 2}] do
      assert [%{"code" => "stale_revision", "expected_revision" => ^value}] =
               batch(conn, [
                 transfer("source", "destination", 1, %{"destination_expected_revision" => value})
               ])
    end
  end

  test "invalid transfers are atomic and batches continue", %{conn: conn} do
    batch(conn, [
      opening("source", [100]),
      opening("destination", [40]),
      opening("other-guest", [100], %{"guest_id" => "other"}),
      opening("cancelled", [100]),
      cancel("cancelled"),
      cash("source", "p", 70)
    ])

    before = snapshot()

    for {attempt, code, group_id} <- [
          {transfer("source", "source", 1), "invalid_transfer", nil},
          {transfer("source", "other-guest", 1), "invalid_transfer", nil},
          {transfer("cancelled", "source", 1), "group_not_active", "cancelled"},
          {transfer("source", "cancelled", 1), "group_not_active", "cancelled"},
          {transfer("source", "destination", 71), "transfer_exceeds_held_funding", nil},
          {transfer("source", "destination", 41), "transfer_exceeds_outstanding", nil}
        ] do
      assert [result = %{"code" => ^code}] = batch(conn, [attempt])
      if group_id, do: assert(result["group_id"] == group_id)
      assert snapshot() == before
    end

    for amount <- [0, -1, 1.5, "1", nil, true] do
      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [transfer("source", "destination", amount)])

      assert snapshot() == before
    end

    for field <- ~w(source_group_id destination_group_id amount_cents occurred_on) do
      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [transfer("source", "destination", 1) |> Map.delete(field)])

      assert snapshot() == before
    end

    assert [
             %{"code" => "transfer_exceeds_outstanding"},
             %{"status" => "applied"},
             %{"code" => "stale_revision", "actual_revision" => 2}
           ] =
             batch(conn, [
               transfer("source", "destination", 41),
               transfer("source", "destination", 40),
               cash("destination", "stale", 1, %{"expected_revision" => 1})
             ])
  end

  test "reductions follow the payment across groups in reverse allocation order", %{conn: conn} do
    payment = cash("original", "p", 200)

    batch(conn, [
      opening("original", [100, 100]),
      opening("z", [50, 50]),
      opening("a", [50, 50]),
      payment,
      transfer("original", "z", 100),
      transfer("z", "a", 60)
    ])

    assert room_funding("z") == [{40, 0}, {0, 0}]
    originals = Map.new(~w(original z a), &{&1, Reservations.get_group(&1).revision})

    reduction =
      correction("reduce_cash_payment", "p", %{
        "amount_cents" => 70,
        "expected_revision" => originals["original"]
      })

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 100}] = batch(conn, [reduction])
    assert room_funding("original") == [{100, 0}, {0, 0}]
    assert room_funding("z") == [{30, 0}, {0, 0}]
    assert room_funding("a") == [{0, 0}, {0, 0}]

    for id <- ~w(original z a),
        do: assert(Reservations.get_group(id).revision == originals[id] + 1)

    assert held_by_group(conn, "p") == [
             %{"group_id" => "original", "amount_cents" => 100},
             %{"group_id" => "z", "amount_cents" => 30}
           ]

    a = Reservations.get_group("a")
    batch(conn, [correction("reduce_cash_payment", "p", %{"amount_cents" => 130})])
    assert Reservations.get_group("a") == a
    assert held_by_group(conn, "p") == []
    before = snapshot()
    assert [%{"revision" => 2, "outstanding_deposit_cents" => 0}] = batch(conn, [payment])
    assert [%{"revision" => 4}] = batch(conn, [reduction])
    assert snapshot() == before
    assert_conserved(conn, ["p"])
  end

  test "destination policies settle transferred cash and chargebacks revise every cash disposition group",
       %{conn: conn} do
    batch(conn, [
      opening("original", [100]),
      opening("refunded", [20]),
      opening("retained", [20], %{"rate_plan" => "advance_purchase"}),
      opening("converted", [20]),
      opening("held", [20]),
      opening("credit-user", [20]),
      cash("original", "p", 100),
      transfer("original", "refunded", 20),
      transfer("original", "retained", 20),
      transfer("original", "converted", 20),
      transfer("original", "held", 20),
      cancel("refunded"),
      cancel("retained"),
      cancel("converted", %{"refund_method" => "hotel_credit"}),
      credit("credit-user", 20),
      correction("reduce_cash_payment", "p", %{"amount_cents" => 5}),
      cancel("original")
    ])

    original = Reservations.get_group("original")

    revisions =
      Map.new(
        ~w(original refunded retained converted held),
        &{&1, Reservations.get_group(&1).revision}
      )

    credit_user = Reservations.get_group("credit-user")
    assert statement(conn, "p")["reduced_cents"] == 5

    chargeback =
      correction("charge_back_payment", "p", %{"expected_revision" => original.revision})

    assert [%{"charged_back_cents" => 95, "outstanding_deposit_cents" => 0}] =
             batch(conn, [chargeback])

    for {id, revision} <- revisions,
        do: assert(Reservations.get_group(id).revision == revision + 1)

    assert Reservations.get_group("credit-user") == credit_user
    assert held_by_group(conn, "p") == []
    ledger = Reservations.ledger(~D[2026-10-04])
    assert ledger.credit_shortfall_cents == 20
    assert ledger.credit_liability_cents == 20
    assert ledger.cash_charged_back_cents == 95
    assert ledger.cash_held_cents == 0
    assert_conserved(conn, ["p"])
  end

  test "a cancelled original group still guards corrections to transferred held cash", %{
    conn: conn
  } do
    batch(conn, [
      opening("original", [100]),
      opening("destination", [100]),
      cash("original", "p", 100),
      transfer("original", "destination", 100),
      cancel("original")
    ])

    before = snapshot()

    assert [%{"code" => "stale_revision", "group_id" => "original", "actual_revision" => 4}] =
             batch(conn, [
               correction("reduce_cash_payment", "p", %{
                 "amount_cents" => 100,
                 "expected_revision" => 3
               })
             ])

    assert snapshot() == before

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             batch(conn, [
               correction("reduce_cash_payment", "p", %{
                 "amount_cents" => 100,
                 "expected_revision" => 4
               })
             ])

    assert Reservations.get_group("destination").revision == 3
    assert Reservations.get_group("destination").deposit_paid_cents == 0
    assert held_by_group(conn, "p") == []
  end

  for {name, date, available, liability} <- [
        {"refundable", "2026-10-04", 55, 55},
        {"expired", "2028-01-01", 0, 0},
        {"nonrefundable", "2028-12-01", 0, 0}
      ] do
    test "transferred credit remains paused and follows #{name} settlement rules", %{conn: conn} do
      batch(conn, [
        opening("seed", [100]),
        cash("seed", "p1", 50),
        cash("seed", "p2", 50),
        cancel("seed", %{"refund_method" => "hotel_credit"}),
        opening("source", [100]),
        opening("destination", [100], %{
          "arrival_on" => "2028-12-10",
          "departure_on" => "2028-12-11"
        }),
        credit("source", 100),
        correction("charge_back_payment", "p1")
      ])

      before = Reservations.ledger(~D[2028-01-01])
      batch(conn, [transfer("source", "destination", 100, %{"occurred_on" => "2028-01-01"})])
      assert Reservations.ledger(~D[2028-01-01]) == before
      assert before.credit_liability_cents == 100
      assert before.credit_shortfall_cents == 45
      assert room_funding("destination") == [{0, 100}]

      assert [%{"credit_issued_cents" => 0}] =
               batch(conn, [
                 cancel("destination", %{
                   "occurred_on" => unquote(date),
                   "refund_method" =>
                     if(unquote(name) == "nonrefundable", do: "cash", else: "hotel_credit")
                 })
               ])

      refute Map.has_key?(statement(conn, "p1"), "held_by_group")
      refute Map.has_key?(statement(conn, "p2"), "held_by_group")

      ledger = Reservations.ledger(Date.from_iso8601!(unquote(date)))
      assert ledger.credit_shortfall_cents == 0
      assert ledger.credit_liability_cents == unquote(liability)

      assert Credits.for_guest("guest-22", Date.from_iso8601!(unquote(date))).available_cents ==
               unquote(available)
    end
  end

  test "destination conversion assigns the rounded bonus in transferred funding order", %{
    conn: conn
  } do
    batch(conn, [
      opening("source", [5]),
      opening("destination", [2, 3]),
      cash("source", "first", 4),
      cash("source", "last", 1),
      transfer("source", "destination", 5)
    ])

    assert [%{"credit_issued_cents" => 6}] =
             batch(conn, [cancel("destination", %{"refund_method" => "hotel_credit"})])

    batch(conn, [correction("charge_back_payment", "last")])
    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 5
    batch(conn, [correction("charge_back_payment", "first")])
    assert Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 0
    assert_conserved(conn, ["first", "last"])
  end

  defp opening(id, deposits, overrides \\ %{}) do
    plan = Map.get(overrides, "rate_plan", "flexible")

    open_operation(
      Map.merge(
        %{
          "group_id" => id,
          "property_id" => "property-#{id}",
          "departure_on" => "2026-12-11",
          "rooms" =>
            Enum.with_index(deposits, 1)
            |> Enum.map(fn {due, index} ->
              %{
                "room_id" => "r#{index}",
                "nightly_rate_cents" => due * if(plan == "flexible", do: 5, else: 1)
              }
            end)
        },
        overrides
      )
    )
  end

  defp cash(group, id, amount, overrides \\ %{}),
    do:
      operation(
        "record_cash_payment",
        Map.merge(
          %{"group_id" => group, "operation_id" => id, "amount_cents" => amount},
          overrides
        )
      )

  defp credit(group, amount),
    do: operation("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp cancel(group, overrides \\ %{}),
    do: operation("cancel_group", Map.merge(%{"group_id" => group}, overrides))

  defp correction(type, payment, overrides),
    do:
      operation(type, Map.merge(%{"payment_operation_id" => payment}, overrides))
      |> Map.delete("group_id")

  defp correction(type, payment), do: correction(type, payment, %{})

  defp transfer(source, destination, amount, overrides \\ %{}),
    do:
      operation(
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => destination,
            "amount_cents" => amount
          },
          overrides
        )
      )
      |> Map.delete("group_id")

  defp room_funding(id),
    do: Reservations.get_group(id).rooms |> Enum.map(&{&1.cash_paid_cents, &1.credit_paid_cents})

  defp held_by_group(conn, id), do: statement(conn, id)["held_by_group"]

  defp statement(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp batch(conn, operations),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
      |> json_response(200)
      |> Map.fetch!("results")

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
    ) ++
      [
        Repo.query!("SELECT * FROM transferred_payments ORDER BY payment_operation_id").rows,
        Repo.query!("SELECT * FROM allocation_sequence").rows
      ]
  end

  defp assert_conserved(conn, ids) do
    statements = Enum.map(ids, &statement(conn, &1))

    fields =
      ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)

    ledger = Reservations.ledger(~D[2026-10-04]) |> Jason.encode!() |> Jason.decode!()

    for statement <- statements do
      assert Enum.sum(Enum.map(fields, &statement[&1])) == statement["recorded_cents"]

      if Map.has_key?(statement, "held_by_group"),
        do:
          assert(
            Enum.sum(Enum.map(statement["held_by_group"], & &1["amount_cents"])) ==
              statement["held_cents"]
          )
    end

    for field <- fields,
        do: assert(Enum.sum(Enum.map(statements, & &1[field])) == ledger["cash_" <> field])
  end
end
