defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.{Credit, Payments, Repo, Reservations}
  alias GroupStay.Credit.{Allocation, Entitlement, Lot}
  alias GroupStay.Operations.Operation
  alias GroupStay.Payments.{Payment, Settlement}
  alias GroupStay.Reservations.{Group, RoomFunding}

  test "mixed funding moves newest slices first and fills active destination rooms in order", %{
    conn: conn
  } do
    issue_credit(conn, 100)

    batch(conn, [
      booking("source", [100, 100, 100]),
      booking("destination", [60, 100, 100]),
      cash("first", "source", 100),
      op("apply_hotel_credit", "source", %{"amount_cents" => 60}),
      cash("last", "source", 40),
      op("cancel_rooms", "destination", %{"room_ids" => ["r2"]})
    ])

    before = ledger(conn)

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
             "source_outstanding_deposit_cents" => 250,
             "destination_outstanding_deposit_cents" => 10,
             "source_revision" => 5,
             "destination_revision" => 3
           }

    assert ledger(conn) == before
    assert slices("source") == [{"r0", "first", nil, 50}]
    lot = Repo.one!(Lot).id

    assert slices("destination") == [
             {"r0", "last", nil, 40},
             {"r0", nil, lot, 20},
             {"r1", nil, lot, 40},
             {"r1", "first", nil, 50}
           ]

    before_reads = snapshot()

    assert statement(conn, "first")["held_by_group"] == [
             %{"group_id" => "destination", "amount_cents" => 50},
             %{"group_id" => "source", "amount_cents" => 50}
           ]

    refute Map.has_key?(statement(conn, "credit-payment"), "held_by_group")
    assert snapshot() == before_reads
    assert [^result] = batch(conn, [transfer])

    assert conn |> get("/api/v1/operations/#{transfer["operation_id"]}") |> json_response(200) ==
             %{"data" => result}

    assert ledger(conn) == before
    assert_invariants(conn)
  end

  test "reductions follow new allocation order across repeated transfers and guard only the origin",
       %{conn: conn} do
    payment = cash("pay", "origin", 300)
    [_, _, _, original] = batch(conn, [booking("origin"), booking("z"), booking("a"), payment])
    batch(conn, [transfer("origin", "z", 150), transfer("z", "a", 100)])
    # These 20 cents are now the newest allocation, despite returning to the origin.
    batch(conn, [transfer("a", "origin", 20)])

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 150}] =
             batch(conn, [
               correction("reduce_cash_payment", "pay", %{
                 "amount_cents" => 110,
                 "expected_revision" => 4
               })
             ])

    assert statement(conn, "pay")["held_by_group"] == [
             %{"group_id" => "origin", "amount_cents" => 150},
             %{"group_id" => "z", "amount_cents" => 40}
           ]

    assert group(conn, "a")["revision"] == 4
    assert group(conn, "z")["revision"] == 4

    assert [%{"code" => "stale_revision", "group_id" => "z"}] =
             batch(conn, [
               op("record_cash_payment", "z", %{"amount_cents" => 1, "expected_revision" => 3})
             ])

    assert [^original] = batch(conn, [payment])

    assert [%{"revision" => 6, "charged_back_cents" => 190}] =
             batch(conn, [correction("charge_back_payment", "pay")])

    assert statement(conn, "pay")["held_by_group"] == []
    assert group(conn, "z")["revision"] == 5
    assert group(conn, "a")["revision"] == 4
    assert_invariants(conn)
  end

  test "corrections advance an empty cancelled origin and only destinations whose funding changes",
       %{conn: conn} do
    batch(conn, [
      booking("origin"),
      booking("destination"),
      booking("unrelated"),
      cash("pay", "origin", 100),
      transfer("origin", "destination", 100),
      op("cancel_group", "origin")
    ])

    destination = group(conn, "destination")

    assert [%{"code" => "stale_revision", "actual_revision" => 4}] =
             batch(conn, [
               correction("reduce_cash_payment", "pay", %{
                 "amount_cents" => 25,
                 "expected_revision" => 3
               })
             ])

    assert group(conn, "destination") == destination

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             batch(conn, [
               correction("reduce_cash_payment", "pay", %{
                 "amount_cents" => 25,
                 "expected_revision" => 4
               })
             ])

    assert group(conn, "destination")["revision"] == 3

    assert [%{"revision" => 6, "charged_back_cents" => 75}] =
             batch(conn, [correction("charge_back_payment", "pay")])

    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "unrelated")["revision"] == 1
    assert_invariants(conn)
  end

  test "transferred cash settles under each destination policy and chargeback reclassifies every group",
       %{conn: conn} do
    batch(conn, [
      booking("origin", [500], %{"rate_plan" => "advance_purchase"}),
      booking("refund"),
      booking("retain", [100], %{"rate_plan" => "advance_purchase"}),
      booking("convert"),
      cash("pay", "origin", 400),
      transfer("origin", "refund", 100),
      transfer("origin", "retain", 100),
      transfer("origin", "convert", 100),
      op("cancel_group", "refund"),
      op("cancel_group", "retain"),
      op("cancel_group", "convert", %{"refund_method" => "hotel_credit"})
    ])

    assert %{
             "held_cents" => 100,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100
           } = statement(conn, "pay")

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 110
    before = Map.new(~w(origin refund retain convert), &{&1, group(conn, &1)["revision"]})

    assert [%{"charged_back_cents" => 400}] =
             batch(conn, [correction("charge_back_payment", "pay")])

    for {id, revision} <- before, do: assert(group(conn, id)["revision"] == revision + 1)

    assert %{
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_charged_back_cents" => 400,
             "credit_liability_cents" => 0
           } = ledger(conn)

    assert_invariants(conn)
  end

  test "transferred cash shares one rounded bonus with other payments in original funding order",
       %{conn: conn} do
    batch(conn, [
      booking("source"),
      booking("destination", [5, 5]),
      cash("first", "source", 4),
      cash("second", "source", 6),
      transfer("source", "destination", 10),
      op("cancel_group", "destination", %{"refund_method" => "hotel_credit"})
    ])

    assert Enum.map(Repo.all(Entitlement), &{&1.payment_operation_id, &1.amount_cents}) == [
             {"first", 4},
             {"second", 7}
           ]

    assert [%{"charged_back_cents" => 6}] =
             batch(conn, [correction("charge_back_payment", "second")])

    assert Credit.balance("guest-22", ~D[2026-10-04]).available_cents == 4
    assert_invariants(conn)
  end

  test "transferred credit keeps original lots, merges existing allocations, and expires only on restoration",
       %{conn: conn} do
    issue_credit(conn, 100)

    batch(conn, [
      booking("source"),
      booking("destination"),
      op("apply_hotel_credit", "source", %{"amount_cents" => 80}),
      op("apply_hotel_credit", "destination", %{"amount_cents" => 30}),
      op("reschedule_group", "destination", %{"new_arrival_on" => "2028-03-01"})
    ])

    before = ledger(conn, "2027-11-01")
    batch(conn, [transfer("source", "destination", 80, %{"occurred_on" => "2027-11-01"})])
    assert ledger(conn, "2027-11-01") == before
    assert [%Allocation{group_id: "destination", amount_cents: 110}] = Repo.all(Allocation)

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             batch(conn, [
               op("cancel_group", "destination", %{
                 "occurred_on" => "2027-11-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert Repo.all(Allocation) == []
    assert Credit.balance("guest-22", ~D[2027-11-01]).available_cents == 0
    assert ledger(conn, "2027-11-01")["credit_liability_cents"] == 0
    assert_invariants(conn)
  end

  test "credit shortfall follows transferred allocations and restoration absorbs before expiry",
       %{conn: conn} do
    issue_credit(conn, 100)

    batch(conn, [
      booking("source"),
      booking("destination", [50, 50]),
      op("apply_hotel_credit", "source", %{"amount_cents" => 100}),
      correction("charge_back_payment", "credit-payment")
    ])

    before = ledger(conn)
    batch(conn, [transfer("source", "destination", 100)])
    assert ledger(conn) == before
    assert %{"credit_shortfall_cents" => 100, "credit_liability_cents" => 100} = before

    batch(conn, [
      op("cancel_rooms", "destination", %{"room_ids" => ["r0"], "occurred_on" => "2026-12-01"})
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 50
    assert Repo.one!(Lot).unrecovered_clawback_cents == 100

    batch(conn, [
      op("reschedule_group", "destination", %{"new_arrival_on" => "2028-03-01"}),
      op("cancel_group", "destination", %{"occurred_on" => "2027-11-01"})
    ])

    assert Repo.one!(Lot).unrecovered_clawback_cents == 50
    assert %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0} = ledger(conn)
    assert_invariants(conn)
  end

  test "refund restores several transferred lots without a second bonus", %{conn: conn} do
    issue_credit(conn, 100)

    batch(conn, [
      booking("issuer-two"),
      cash("pay-two", "issuer-two", 100),
      op("cancel_group", "issuer-two", %{
        "occurred_on" => "2026-10-05",
        "refund_method" => "hotel_credit",
        "operation_id" => "lot-two"
      }),
      booking("source"),
      booking("destination"),
      op("apply_hotel_credit", "source", %{"amount_cents" => 150, "occurred_on" => "2026-10-06"}),
      transfer("source", "destination", 100)
    ])

    lots = Repo.all(from l in Lot, order_by: l.expires_on)
    [first, second] = lots
    assert slices("destination") == [{"r0", nil, second.id, 40}, {"r0", nil, first.id, 60}]
    batch(conn, [op("cancel_group", "destination", %{"refund_method" => "hotel_credit"})])
    assert Credit.balance("guest-22", ~D[2026-10-06]).available_cents == 170

    assert Enum.map(Repo.all(from l in Lot, order_by: l.expires_on), & &1.expires_on) ==
             Enum.map(lots, & &1.expires_on)

    assert ledger(conn)["credit_liability_cents"] == 220
    assert_invariants(conn)
  end

  test "existence and source then destination revisions precede transfer rules", %{conn: conn} do
    batch(conn, [booking("source"), booking("destination"), cash("pay", "source", 100)])

    cases = [
      {transfer("missing-source", "missing-destination", 0, %{"expected_revision" => 99}),
       %{"code" => "group_not_found", "group_id" => "missing-source"}},
      {transfer("source", "missing-destination", 0, %{"expected_revision" => 99}),
       %{"code" => "group_not_found", "group_id" => "missing-destination"}},
      {transfer("source", "destination", 0, %{
         "expected_revision" => 1,
         "destination_expected_revision" => 99
       }),
       %{
         "code" => "stale_revision",
         "group_id" => "source",
         "expected_revision" => 1,
         "actual_revision" => 2
       }},
      {transfer("source", "destination", 0, %{
         "expected_revision" => 2,
         "destination_expected_revision" => 99
       }),
       %{
         "code" => "stale_revision",
         "group_id" => "destination",
         "expected_revision" => 99,
         "actual_revision" => 1
       }},
      {transfer("source", "source", 10, %{"destination_expected_revision" => 1}),
       %{
         "code" => "stale_revision",
         "group_id" => "source",
         "expected_revision" => 1,
         "actual_revision" => 2
       }}
    ]

    for {request, expected} <- cases do
      before = snapshot()
      [result] = batch(conn, [request])
      assert Map.take(result, Map.keys(expected)) == expected
      assert result["status"] == "rejected"
      assert snapshot() == before
    end

    stale = transfer("source", "destination", 10, %{"destination_expected_revision" => 99})
    [original] = batch(conn, [stale])
    batch(conn, [transfer("source", "destination", 10)])

    assert [^original, %{"code" => "operation_id_conflict"}] =
             batch(conn, [stale, Map.put(stale, "destination_expected_revision", 2)])

    assert_invariants(conn)
  end

  test "invalid transfers are atomic and remembered while later batch operations continue", %{
    conn: conn
  } do
    batch(conn, [
      booking("source"),
      booking("destination", [50]),
      booking("other", [100], %{"guest_id" => "other-guest"}),
      booking("cancelled"),
      op("cancel_group", "cancelled"),
      cash("pay", "source", 100)
    ])

    cases =
      [
        {transfer("source", "source", 1), "invalid_transfer", nil},
        {transfer("source", "other", 1), "invalid_transfer", nil},
        {transfer("cancelled", "source", 1), "group_not_active", "cancelled"},
        {transfer("source", "cancelled", 1), "group_not_active", "cancelled"},
        {transfer("source", "destination", 101), "transfer_exceeds_held_funding", nil},
        {transfer("source", "destination", 51), "transfer_exceeds_outstanding", nil}
      ] ++
        for amount <- [0, -1, 1.5, "1", nil, true],
            do: {transfer("source", "destination", amount), "invalid_amount", nil}

    for {request, code, id} <- cases do
      before = snapshot()
      [result] = batch(conn, [request])
      assert result["code"] == code
      if id, do: assert(result["group_id"] == id)
      assert snapshot() == before
      assert [^result] = batch(conn, [request])
    end

    batch(conn, [booking("roomy")])
    rejected = transfer("source", "roomy", 101)
    [remembered] = batch(conn, [rejected])
    assert remembered["code"] == "transfer_exceeds_held_funding"
    batch(conn, [op("record_cash_payment", "source", %{"amount_cents" => 50})])

    assert [^remembered, %{"status" => "applied"}] =
             batch(conn, [rejected, transfer("source", "roomy", 101)])

    assert_invariants(conn)
  end

  test "transfer shape requires both identifiers, an amount, and a valid operation date", %{
    conn: conn
  } do
    batch(conn, [booking("source"), booking("destination"), cash("pay", "source", 100)])

    for field <- ~w(operation_id source_group_id destination_group_id amount_cents occurred_on) do
      request = transfer("source", "destination", 10) |> Map.delete(field)
      before = snapshot()
      assert [%{"code" => "invalid_operation"}] = batch(conn, [request])
      assert snapshot() == before
    end

    for field <- ~w(source_group_id destination_group_id), value <- [nil, "", 12] do
      assert [%{"code" => "invalid_operation"}] =
               batch(conn, [Map.put(transfer("source", "destination", 10), field, value)])
    end

    assert [%{"code" => "invalid_operation"}] =
             batch(conn, [transfer("source", "destination", 10, %{"occurred_on" => "bad"})])
  end

  for type <- ~w(transfer_deposit reduce_cash_payment charge_back_payment) do
    test "#{type} rolls back changes to all groups if audit persistence fails", %{conn: conn} do
      issue_credit(conn, 100)

      batch(conn, [
        booking("source"),
        booking("destination"),
        cash("pay", "source", 100),
        op("apply_hotel_credit", "source", %{"amount_cents" => 100}),
        transfer("source", "destination", 150)
      ])

      request =
        case unquote(type) do
          "transfer_deposit" ->
            transfer("destination", "source", 150, %{"operation_id" => "fault"})

          type ->
            correction(type, "pay", %{"operation_id" => "fault", "amount_cents" => 75})
        end

      before = snapshot()
      audit = Repo.all(Operation)

      Repo.query!("""
      CREATE TRIGGER fail_transfer_audit BEFORE INSERT ON operations
      WHEN NEW.operation_id = 'fault'
      BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
      """)

      assert_raise Exqlite.Error, fn ->
        Reservations.process_batch([request, booking("later")])
      end

      assert snapshot() == before
      assert Repo.all(Operation) == audit
      Repo.query!("DROP TRIGGER fail_transfer_audit")
      assert [%{"status" => "applied"} = result] = batch(conn, [request])
      assert [^result] = batch(conn, [request])
      assert_invariants(conn)
    end
  end

  defp booking(id, deposits \\ [300], extra \\ %{}) do
    open_group(
      Map.merge(
        %{
          "group_id" => id,
          "departure_on" => "2026-12-11",
          "rooms" =>
            Enum.with_index(deposits, fn due, i ->
              %{"room_id" => "r#{i}", "nightly_rate_cents" => due * 5}
            end)
        },
        extra
      )
    )
  end

  defp op(type, group, extra \\ %{}), do: operation(type, Map.put(extra, "group_id", group))

  defp cash(id, group, amount),
    do: op("record_cash_payment", group, %{"operation_id" => id, "amount_cents" => amount})

  defp correction(type, payment, extra \\ %{}),
    do: operation(type, Map.put(extra, "payment_operation_id", payment)) |> Map.delete("group_id")

  defp transfer(source, destination, amount, extra \\ %{}),
    do:
      operation(
        "transfer_deposit",
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => destination,
            "amount_cents" => amount
          },
          extra
        )
      )
      |> Map.delete("group_id")

  defp issue_credit(conn, amount),
    do:
      batch(conn, [
        booking("issuer"),
        cash("credit-payment", "issuer", amount),
        op("cancel_group", "issuer", %{"refund_method" => "hotel_credit"})
      ])

  defp batch(conn, ops),
    do:
      conn
      |> recycle()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp statement(conn, id),
    do: conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn, on \\ "2026-10-06"),
    do: conn |> get("/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")

  defp slices(id),
    do:
      Repo.all(from f in RoomFunding, where: f.group_id == ^id, order_by: f.id)
      |> Enum.map(&{&1.room_id, &1.payment_operation_id, &1.credit_lot_id, &1.amount_cents})

  defp snapshot,
    do:
      Enum.map(
        [Group, Payment, Settlement, RoomFunding, Lot, Allocation, Entitlement],
        &Repo.all/1
      )

  defp assert_invariants(conn) do
    statements =
      Enum.map(Repo.all(Payment), fn payment ->
        {:ok, statement} = Payments.statement(payment.payment_operation_id)

        dispositions =
          ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

        assert Enum.sum(Map.values(Map.take(statement, dispositions))) == statement.recorded_cents

        if Map.has_key?(statement, :held_by_group),
          do:
            assert(
              Enum.sum(Enum.map(statement.held_by_group, & &1.amount_cents)) ==
                statement.held_cents
            )

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
      funding = Repo.all(from f in RoomFunding, where: f.group_id == ^group.group_id)
      assert group.deposit_paid_cents == Enum.sum(Enum.map(funding, & &1.amount_cents))

      for room <- group.rooms do
        slices = Enum.filter(funding, &(&1.room_id == room.room_id))

        assert room.cash_paid_cents ==
                 Enum.sum(for f <- slices, is_nil(f.credit_lot_id), do: f.amount_cents)

        assert room.credit_paid_cents ==
                 Enum.sum(for f <- slices, not is_nil(f.credit_lot_id), do: f.amount_cents)

        assert room.cash_paid_cents + room.credit_paid_cents <= room.deposit_due_cents
      end
    end

    applied =
      Repo.all(
        from f in RoomFunding,
          where: not is_nil(f.credit_lot_id),
          group_by: [f.group_id, f.credit_lot_id],
          select: {f.group_id, f.credit_lot_id, sum(f.amount_cents)}
      )
      |> Enum.sort()

    assert applied ==
             Repo.all(Allocation)
             |> Enum.map(&{&1.group_id, &1.credit_lot_id, &1.amount_cents})
             |> Enum.sort()
  end
end
