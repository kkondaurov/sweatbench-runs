defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures
  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Room,
    RoomAllocation
  }

  test "mixed funding moves newest first, fills original room order, and preserves exact retries",
       %{conn: conn} do
    issue_credit(conn, 100)
    payment = cash("source", "pay", 150)

    transfer =
      transfer("source", "destination", 160, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 2
      })

    [_, _, paid, _, _, _, moved] =
      batch(conn, [
        booking("source"),
        booking("destination", [100, 100, 100], %{"property_id" => "other-property"}),
        payment,
        credit_payment("source", 110),
        cash("source", "latest", 30),
        cash("destination", "destination-pay", 20),
        transfer
      ])

    assert moved == %{
             "operation_id" => transfer["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 160,
             "source_outstanding_deposit_cents" => 170,
             "destination_outstanding_deposit_cents" => 120,
             "source_revision" => 5,
             "destination_revision" => 3
           }

    assert balances(conn, "source") == [{100, 0}, {30, 0}, {0, 0}]
    assert balances(conn, "destination") == [{50, 50}, {20, 60}, {0, 0}]
    assert held_by_group(conn, "pay") == [{"destination", 20}, {"source", 130}]
    assert held_by_group(conn, "latest") == [{"destination", 30}]
    refute Map.has_key?(statement(conn, "destination-pay"), "held_by_group")
    assert ledger(conn)["cash_held_cents"] == 200
    assert ledger(conn)["credit_liability_cents"] == 110

    before = snapshot()
    assert batch(conn, [payment, transfer]) == [paid, moved]
    assert snapshot() == before

    assert conn |> get("/api/v1/operations/#{transfer["operation_id"]}") |> json_response(200) ==
             %{"data" => moved}

    assert [%{"code" => "operation_id_conflict"}] =
             batch(conn, [Map.put(transfer, "amount_cents", 159)])

    assert snapshot() == before
  end

  test "new allocations filling earlier room gaps are drawn before older funding in later rooms",
       %{conn: conn} do
    batch(conn, [
      booking("source"),
      booking("destination"),
      cash("source", "old", 200),
      correction("reduce_cash_payment", "old", %{"amount_cents" => 20}),
      cash("source", "middle", 30),
      correction("reduce_cash_payment", "old", %{"amount_cents" => 100}),
      cash("source", "new", 40),
      transfer("source", "destination", 30)
    ])

    assert held_by_group(conn, "new") == [{"destination", 30}, {"source", 10}]
    refute Map.has_key?(statement(conn, "old"), "held_by_group")
    refute Map.has_key?(statement(conn, "middle"), "held_by_group")
    assert balances(conn, "source") == [{90, 0}, {20, 0}, {10, 0}]
  end

  test "transfers merge existing lot summaries and selected settlement restores each original lot",
       %{conn: conn} do
    batch(conn, [
      booking("issuer-two"),
      cash("issuer-two", "two", 100),
      cancel("issuer-two", %{
        "operation_id" => "second-lot",
        "occurred_on" => "2026-11-02",
        "refund_method" => "hotel_credit"
      })
    ])

    # Issue the first lot independently with its earlier expiry.
    batch(conn, [
      booking("issuer-three"),
      cash("issuer-three", "three", 50),
      cancel("issuer-three", %{"operation_id" => "earlier-lot", "refund_method" => "hotel_credit"}),
      booking("source"),
      booking("destination", [50, 50, 50]),
      credit_payment("destination", 5),
      credit_payment("source", 110)
    ])

    before = ledger(conn)
    batch(conn, [transfer("source", "destination", 80)])
    assert ledger(conn) == before
    assert balances(conn, "source") == [{0, 30}, {0, 0}, {0, 0}]
    assert balances(conn, "destination") == [{0, 50}, {0, 35}, {0, 0}]
    batch(conn, [operation("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r0"]})])
    lots = Map.new(Repo.all(CreditLot), &{&1.source_operation_id, &1.remaining_cents})
    assert lots == %{"earlier-lot" => 5, "second-lot" => 95}
    batch(conn, [cancel("source"), cancel("destination", %{"refund_method" => "hotel_credit"})])
    assert Repo.all(CreditAllocation) == []
    assert ledger(conn)["credit_liability_cents"] == 165

    assert Map.new(Repo.all(CreditLot), &{&1.source_operation_id, &1.remaining_cents}) == %{
             "earlier-lot" => 55,
             "second-lot" => 110
           }
  end

  test "successive transfers reverse newly created slices and preserve untouched source order", %{
    conn: conn
  } do
    batch(conn, [
      booking("source"),
      booking("destination"),
      booking("third"),
      cash("source", "early", 150),
      cash("source", "late", 100),
      transfer("source", "destination", 175),
      transfer("destination", "third", 100)
    ])

    assert held_by_group(conn, "early") == [{"source", 75}, {"third", 75}]
    assert held_by_group(conn, "late") == [{"destination", 75}, {"third", 25}]
    assert balances(conn, "third") == [{100, 0}, {0, 0}, {0, 0}]
    before = ledger(conn)
    batch(conn, [transfer("third", "source", 100)])
    assert ledger(conn) == before
    assert held_by_group(conn, "early") == [{"source", 150}]
    assert held_by_group(conn, "late") == [{"destination", 75}, {"source", 25}]
  end

  test "existence and both guards precede domain validation and rejections are atomic", %{
    conn: conn
  } do
    batch(conn, [booking("source"), booking("destination"), cash("source", "pay", 100)])

    cases = [
      {transfer("missing-source", "missing-destination", 1), "group_not_found",
       %{"group_id" => "missing-source"}},
      {transfer("source", "missing-destination", 1, %{"expected_revision" => 0}),
       "group_not_found", %{"group_id" => "missing-destination"}},
      {transfer("source", "destination", 0, %{
         "expected_revision" => 1,
         "destination_expected_revision" => 0
       }), "stale_revision",
       %{"group_id" => "source", "expected_revision" => 1, "actual_revision" => 2}},
      {transfer("source", "destination", 0, %{
         "expected_revision" => 2,
         "destination_expected_revision" => 0
       }), "stale_revision",
       %{"group_id" => "destination", "expected_revision" => 0, "actual_revision" => 1}},
      {transfer("source", "source", 1, %{"destination_expected_revision" => 0}), "stale_revision",
       %{"group_id" => "source", "expected_revision" => 0, "actual_revision" => 2}},
      {transfer("source", "source", 1), "invalid_transfer", %{}},
      {transfer("source", "destination", 101), "transfer_exceeds_held_funding", %{}}
    ]

    for {operation, code, details} <- cases do
      before = snapshot()
      [rejected] = batch(conn, [operation])

      assert rejected ==
               Map.merge(
                 %{
                   "operation_id" => operation["operation_id"],
                   "status" => "rejected",
                   "code" => code
                 },
                 details
               )

      assert snapshot() == before
      assert batch(conn, [operation]) == [rejected]
    end

    for amount <- [nil, "1", 1.0, 0, -1, true] do
      before = snapshot()

      assert [%{"code" => "invalid_amount"}] =
               batch(conn, [transfer("source", "destination", amount)])

      assert snapshot() == before
    end

    for field <- ["source_group_id", "destination_group_id", "amount_cents", "occurred_on"] do
      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [Map.delete(transfer("source", "destination", 1), field)])
    end

    for field <- ["source_group_id", "destination_group_id"], invalid <- [nil, "", 1] do
      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [Map.put(transfer("source", "destination", 1), field, invalid)])
    end

    assert [%{"code" => "invalid_operation"}] =
             batch(conn, [transfer("source", "destination", 1, %{"occurred_on" => "invalid"})])
  end

  test "guest, activity and outstanding rules; rejected retries stay rejected after funding", %{
    conn: conn
  } do
    batch(conn, [
      booking("source"),
      booking("destination", [20]),
      booking("other", [100], %{"guest_id" => "other-guest"})
    ])

    rejected_transfer = transfer("source", "destination", 20)

    [rejected, _, too_large, other_guest, applied, cancelled, inactive] =
      batch(conn, [
        rejected_transfer,
        cash("source", "pay", 100),
        transfer("source", "destination", 21),
        transfer("source", "other", 1),
        transfer("source", "destination", 20),
        cancel("destination"),
        transfer("source", "destination", 1)
      ])

    assert rejected["code"] == "transfer_exceeds_held_funding"
    assert too_large["code"] == "transfer_exceeds_outstanding"
    assert other_guest["code"] == "invalid_transfer"
    assert applied["destination_revision"] == 2
    assert cancelled["revision"] == 3
    assert inactive["code"] == "group_not_active"
    assert inactive["group_id"] == "destination"
    assert batch(conn, [rejected_transfer]) == [rejected]

    assert [%{"code" => "group_not_active", "group_id" => "destination"}] =
             batch(conn, [transfer("destination", "source", 1)])

    assert [%{"code" => "stale_revision", "group_id" => "destination"}] =
             batch(conn, [
               transfer("source", "destination", 1, %{"destination_expected_revision" => 2})
             ])
  end

  test "reductions follow global allocation order and advance only changed groups plus the original",
       %{conn: conn} do
    payment = cash("source", "pay", 250)

    [_, _, _, original | _] =
      batch(conn, [
        booking("source"),
        booking("destination"),
        booking("third"),
        payment,
        transfer("source", "destination", 150),
        transfer("destination", "third", 50)
      ])

    [first, second] =
      batch(conn, [
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 75, "expected_revision" => 3}),
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 25, "expected_revision" => 4})
      ])

    assert first["revision"] == 4
    assert first["outstanding_deposit_cents"] == 200
    assert second["revision"] == 5
    assert group(conn, "destination")["revision"] == 5
    assert group(conn, "third")["revision"] == 3
    assert held_by_group(conn, "pay") == [{"destination", 50}, {"source", 100}]
    assert statement(conn, "pay")["reduced_cents"] == 100

    [last] = batch(conn, [correction("reduce_cash_payment", "pay", %{"amount_cents" => 150})])
    assert last["outstanding_deposit_cents"] == 300
    assert last["revision"] == 6
    assert group(conn, "destination")["revision"] == 6
    assert group(conn, "third")["revision"] == 3
    assert held_by_group(conn, "pay") == []
    assert ledger(conn)["cash_reduced_cents"] == 250
    assert batch(conn, [payment]) == [original]
  end

  test "chargebacks reclassify destination settlements and held cash across all groups", %{
    conn: conn
  } do
    batch(conn, [
      booking("source", [100, 100, 100, 100, 100]),
      booking("destination", [100, 100, 100, 100]),
      cash("source", "pay", 500),
      transfer("source", "destination", 350),
      operation("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r0"]}),
      operation("cancel_rooms", %{
        "group_id" => "destination",
        "room_ids" => ["r1"],
        "occurred_on" => "2026-12-09"
      }),
      operation("cancel_rooms", %{
        "group_id" => "destination",
        "room_ids" => ["r2"],
        "refund_method" => "hotel_credit"
      }),
      correction("reduce_cash_payment", "pay", %{"amount_cents" => 20})
    ])

    assert statement(conn, "pay")["held_cents"] == 180
    assert held_by_group(conn, "pay") == [{"destination", 30}, {"source", 150}]

    [charged] =
      batch(conn, [correction("charge_back_payment", "pay", %{"expected_revision" => 4})])

    assert charged["charged_back_cents"] == 480
    assert charged["revision"] == 5
    assert charged["outstanding_deposit_cents"] == 500
    assert group(conn, "destination")["revision"] == 7
    assert group(conn, "destination")["outstanding_deposit_cents"] == 100
    assert held_by_group(conn, "pay") == []

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 20,
             "cash_charged_back_cents" => 480,
             "credit_liability_cents" => 0,
             "credit_shortfall_cents" => 0
           }

    assert statement(conn, "pay")["charged_back_cents"] == 480
  end

  test "transferred cash uses destination policy, including corrections addressed to a cancelled source",
       %{conn: conn} do
    batch(conn, [
      booking("source", [100], %{"rate_plan" => "advance_purchase"}),
      booking("destination", [100]),
      cash("source", "pay", 100),
      transfer("source", "destination", 100),
      cancel("source")
    ])

    [reduced, cancelled, charged] =
      batch(conn, [
        correction("reduce_cash_payment", "pay", %{"amount_cents" => 20, "expected_revision" => 4}),
        cancel("destination"),
        correction("charge_back_payment", "pay", %{"expected_revision" => 5})
      ])

    assert reduced["revision"] == 5
    assert reduced["outstanding_deposit_cents"] == 0
    assert cancelled["refunded_cents"] == 80
    assert charged["revision"] == 6
    assert charged["outstanding_deposit_cents"] == 0
    assert group(conn, "destination")["revision"] == 5
    assert statement(conn, "pay")["charged_back_cents"] == 80
    assert statement(conn, "pay")["refunded_cents"] == 0
    assert ledger(conn)["cash_refunded_cents"] == 0

    batch(conn, [
      booking("flex", [100]),
      booking("advance", [100], %{"rate_plan" => "advance_purchase"}),
      cash("flex", "second-pay", 100),
      transfer("flex", "advance", 100)
    ])

    assert [%{"code" => "refund_method_not_available"}] =
             batch(conn, [cancel("advance", %{"refund_method" => "hotel_credit"})])

    assert [%{"retained_cents" => 100}] = batch(conn, [cancel("advance")])
  end

  test "credit transfers pause expiry and restore original lots without a second bonus", %{
    conn: conn
  } do
    issue_credit(conn, 100)

    batch(conn, [
      booking("source"),
      booking("destination", [100, 100, 100], %{
        "arrival_on" => "2029-01-01",
        "departure_on" => "2029-01-02"
      }),
      credit_payment("source", 110)
    ])

    before = ledger(conn, "2028-01-01")
    batch(conn, [transfer("source", "destination", 110, %{"occurred_on" => "2028-01-01"})])
    assert ledger(conn, "2028-01-01") == before
    assert before["credit_liability_cents"] == 110

    assert [%{"credit_issued_cents" => 0}] =
             batch(conn, [
               cancel("destination", %{
                 "occurred_on" => "2028-01-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert ledger(conn, "2028-01-01")["credit_liability_cents"] == 0
    assert Repo.all(CreditAllocation) == []
    assert [%{remaining_cents: 0, expires_on: ~D[2027-11-01]}] = Repo.all(CreditLot)
  end

  test "transferred credit preserves shortfall, then restores or consumes under destination rules",
       %{conn: conn} do
    issue_credit(conn, 100)

    batch(conn, [
      booking("source"),
      booking("destination"),
      credit_payment("source", 100),
      correction("charge_back_payment", "issued-pay")
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 100
    before = ledger(conn)
    batch(conn, [transfer("source", "destination", 60)])
    assert ledger(conn) == before
    assert [%{"credit_issued_cents" => 0}] = batch(conn, [cancel("destination")])
    assert ledger(conn)["credit_shortfall_cents"] == 40
    assert ledger(conn)["credit_liability_cents"] == 40
    assert [%{unrecovered_clawback_cents: 40, remaining_cents: 0}] = Repo.all(CreditLot)
    batch(conn, [cancel("source", %{"occurred_on" => "2026-12-09"})])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "cash converted at a destination retains payment entitlement and protects credit-funded revisions",
       %{conn: conn} do
    batch(conn, [
      booking("source"),
      booking("destination"),
      booking("credit-target"),
      cash("source", "first", 5),
      cash("source", "second", 5),
      transfer("source", "destination", 10),
      cancel("destination", %{"refund_method" => "hotel_credit"}),
      credit_payment("credit-target", 8)
    ])

    # Transfer draws the second payment first, so it owns six cents of the eleven-cent lot.
    before = group(conn, "credit-target")
    [charged] = batch(conn, [correction("charge_back_payment", "second")])
    assert charged["charged_back_cents"] == 5
    assert group(conn, "credit-target") == before
    assert ledger(conn)["credit_shortfall_cents"] == 3
    assert ledger(conn)["credit_liability_cents"] == 8
    assert group(conn, "destination")["revision"] == 4
    batch(conn, [cancel("credit-target")])
    assert ledger(conn)["credit_liability_cents"] == 5
    assert ledger(conn)["credit_shortfall_cents"] == 0
  end

  defp booking(id, amounts \\ [100, 100, 100], attrs \\ %{}) do
    rooms =
      amounts
      |> Enum.with_index()
      |> Enum.map(fn {due, index} ->
        %{"room_id" => "r#{index}", "nightly_rate_cents" => due * 5}
      end)

    open_group(
      Map.merge(
        %{
          "group_id" => id,
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => rooms
        },
        attrs
      )
    )
  end

  defp transfer(source, destination, amount, attrs \\ %{}) do
    operation(
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        attrs
      )
    )
    |> Map.delete("group_id")
  end

  defp cash(group_id, id, amount),
    do:
      operation("record_cash_payment", %{
        "group_id" => group_id,
        "operation_id" => id,
        "amount_cents" => amount
      })

  defp credit_payment(group_id, amount),
    do: operation("apply_hotel_credit", %{"group_id" => group_id, "amount_cents" => amount})

  defp cancel(group_id, attrs \\ %{}),
    do: operation("cancel_group", Map.put(attrs, "group_id", group_id))

  defp correction(type, payment, attrs \\ %{}),
    do: operation(type, Map.put(attrs, "payment_operation_id", payment)) |> Map.delete("group_id")

  defp issue_credit(conn, amount) do
    batch(conn, [
      booking("issuance", [amount]),
      cash("issuance", "issued-pay", amount),
      cancel("issuance", %{"refund_method" => "hotel_credit"})
    ])
  end

  defp batch(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp statement(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn, on \\ "2026-11-01"),
    do: conn |> get("/api/v1/ledger", %{"on" => on}) |> json_response(200) |> Map.fetch!("data")

  defp balances(conn, id),
    do: Enum.map(group(conn, id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp held_by_group(conn, id),
    do: Enum.map(statement(conn, id)["held_by_group"], &{&1["group_id"], &1["amount_cents"]})

  defp snapshot,
    do:
      Enum.map(
        [Group, Room, RoomAllocation, CreditAllocation, CreditLot, CreditEntitlement],
        &Repo.all/1
      )
end
