defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerFixtures

  alias GroupStay.{Operations, Repo}
  alias GroupStay.Credits.{Allocation, Entitlement, Lot}
  alias GroupStay.Finance.{CashAllocation, CashEntry}
  alias GroupStay.Reservations.{Group, Room}

  test "mixed funding moves newest portions first and fills destination rooms in original order",
       %{conn: conn} do
    apply_all(conn, [
      booking("credit-source", [100]),
      cash("credit-source", "lot-payment", 100),
      cancel("credit-source", %{"refund_method" => "hotel_credit"}),
      booking("source", [100, 100, 100]),
      cash("source", "first", 80, %{"occurred_on" => "2026-11-01"}),
      credit_application("source", 90),
      cash("source", "second", 100, %{"occurred_on" => "2026-09-01"}),
      booking("destination", [60, 80, 100], %{"property_id" => "another-property"}),
      cash("destination", "existing", 10),
      booking("third", [100])
    ])

    before_ledger = ledger(conn)
    before_lots = Repo.all(Lot)

    transfer =
      transfer_deposit("source", "destination", 180, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 2
      })

    assert [result] = apply_all(conn, [transfer])

    assert result == %{
             "operation_id" => transfer["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 180,
             "source_outstanding_deposit_cents" => 210,
             "destination_outstanding_deposit_cents" => 50,
             "source_revision" => 5,
             "destination_revision" => 3
           }

    assert room_balances(conn, "source") == [{80, 10}, {0, 0}, {0, 0}]
    assert room_balances(conn, "destination") == [{60, 0}, {50, 30}, {0, 50}]
    assert statement(conn, "second")["held_by_group"] == held_groups([{"destination", 100}])
    refute Map.has_key?(statement(conn, "first"), "held_by_group")
    refute Map.has_key?(statement(conn, "lot-payment"), "held_by_group")

    # A second transfer draws the credit that arrived last, keeping the lot and
    # application identity even after two moves and partial allocation splits.
    apply_all(conn, [transfer_deposit("destination", "third", 80)])
    assert room_balances(conn, "destination") == [{60, 0}, {50, 0}, {0, 0}]
    assert room_balances(conn, "third") == [{0, 80}]
    assert ledger(conn) == before_ledger
    assert Repo.all(Lot) == before_lots

    original = Repo.all(Allocation) |> Enum.find(&(&1.group_id == "source"))

    assert Enum.all?(Repo.all(Allocation), fn allocation ->
             allocation.credit_lot_id == original.credit_lot_id and
               allocation.operation_id == original.operation_id
           end)

    # Returning every moved cent still leaves the statement evolution permanent.
    apply_all(conn, [
      transfer_deposit("third", "source", 80),
      transfer_deposit("destination", "source", 100)
    ])

    assert statement(conn, "second")["held_by_group"] == held_groups([{"source", 100}])
    assert ledger(conn) == before_ledger
  end

  test "reductions follow global allocation order and advance only groups whose funding changes",
       %{conn: conn} do
    payment = cash("original", "payment", 180)

    [_, original_result | _] =
      apply_all(conn, [
        booking("original", [100, 100]),
        payment,
        booking("z", [30, 100]),
        booking("a", [100]),
        transfer_deposit("original", "z", 80),
        transfer_deposit("original", "a", 40)
      ])

    assert statement(conn, "payment")["held_by_group"] ==
             held_groups([{"a", 40}, {"original", 60}, {"z", 80}])

    assert [%{"group_id" => "original", "revision" => 5, "outstanding_deposit_cents" => 140}] =
             apply_all(conn, [
               correction("reduce_cash_payment", "payment", %{
                 "amount_cents" => 70,
                 "expected_revision" => 4
               })
             ])

    assert room_balances(conn, "z") == [{30, 0}, {20, 0}]
    assert room_balances(conn, "a") == [{0, 0}]
    assert revisions(conn, ["original", "z", "a"]) == [5, 3, 3]

    apply_all(conn, [correction("reduce_cash_payment", "payment", %{"amount_cents" => 20})])
    assert revisions(conn, ["original", "z", "a"]) == [6, 4, 3]
    assert room_balances(conn, "z") == [{30, 0}, {0, 0}]

    assert [%{"revision" => 7, "charged_back_cents" => 90}] =
             apply_all(conn, [
               correction("charge_back_payment", "payment", %{"expected_revision" => 6})
             ])

    assert revisions(conn, ["original", "z", "a"]) == [7, 5, 3]
    assert statement(conn, "payment")["held_by_group"] == []
    assert statement(conn, "payment")["reduced_cents"] == 90
    assert statement(conn, "payment")["charged_back_cents"] == 90
    assert ledger(conn)["cash_held_cents"] == 0
    assert submit(conn, [payment]) == [original_result]
    assert Operations.get_result("payment") == original_result
  end

  test "corrections guard the cancelled original group even when all cash has moved",
       %{conn: conn} do
    apply_all(conn, [
      booking("source", [100]),
      cash("source", "payment", 100),
      booking("destination", [100]),
      transfer_deposit("source", "destination", 100),
      cancel("source")
    ])

    before = snapshot()

    assert [%{"code" => "stale_revision", "group_id" => "source", "actual_revision" => 4}] =
             submit(conn, [
               correction("reduce_cash_payment", "payment", %{
                 "amount_cents" => 10,
                 "expected_revision" => 2
               })
             ])

    assert snapshot() == before

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             apply_all(conn, [
               correction("reduce_cash_payment", "payment", %{
                 "amount_cents" => 10,
                 "expected_revision" => 4
               })
             ])

    assert group(conn, "destination")["outstanding_deposit_cents"] == 10
    assert revisions(conn, ["source", "destination"]) == [5, 3]

    apply_all(conn, [correction("charge_back_payment", "payment", %{"expected_revision" => 5})])
    assert revisions(conn, ["source", "destination"]) == [6, 4]
    assert statement(conn, "payment")["held_by_group"] == []
  end

  test "transferred cash settles under the destination policy and chargeback follows every disposition",
       %{conn: conn} do
    apply_all(conn, [
      booking("original", [100], %{"rate_plan" => "advance_purchase"}),
      cash("original", "payment", 500),
      booking("destination", [100, 100, 100]),
      transfer_deposit("original", "destination", 300),
      cancel("original"),
      operation("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r-0"]}),
      operation("cancel_rooms", %{
        "group_id" => "destination",
        "room_ids" => ["r-1"],
        "refund_method" => "hotel_credit"
      }),
      booking("credit-holder", [110]),
      credit_application("credit-holder", 110),
      booking("credit-destination", [110]),
      transfer_deposit("credit-holder", "credit-destination", 110)
    ])

    assert Map.take(
             statement(conn, "payment"),
             ~w(held_cents refunded_cents retained_cents converted_to_credit_cents)
           ) ==
             %{
               "held_cents" => 100,
               "refunded_cents" => 100,
               "retained_cents" => 200,
               "converted_to_credit_cents" => 100
             }

    assert ledger(conn)["credit_liability_cents"] == 110

    assert revisions(conn, ["original", "destination", "credit-holder", "credit-destination"]) ==
             [4, 4, 3, 2]

    apply_all(conn, [correction("charge_back_payment", "payment")])

    assert revisions(conn, ["original", "destination", "credit-holder", "credit-destination"]) ==
             [5, 5, 3, 2]

    assert statement(conn, "payment")["charged_back_cents"] == 500
    assert statement(conn, "payment")["held_by_group"] == []
    assert ledger(conn)["credit_shortfall_cents"] == 110
    assert ledger(conn)["credit_liability_cents"] == 110
    assert ledger(conn)["cash_refunded_cents"] == 0
    assert ledger(conn)["cash_retained_cents"] == 0
    assert ledger(conn)["cash_converted_to_credit_cents"] == 0

    # Restoration on an expired lot absorbs the clawback first, with no bonus.
    apply_all(conn, [
      operation("reschedule_group", %{
        "group_id" => "credit-destination",
        "new_arrival_on" => "2028-01-01"
      }),
      cancel("credit-destination", %{
        "occurred_on" => "2027-10-04",
        "refund_method" => "hotel_credit"
      })
    ])

    assert ledger(conn, "2027-10-04")["credit_liability_cents"] == 0
    assert ledger(conn, "2027-10-04")["credit_shortfall_cents"] == 0
    assert [%Lot{unrecovered_clawback_cents: 0, remaining_cents: 0}] = Repo.all(Lot)
  end

  for {on, available, liability} <- [{"2027-10-03", 110, 110}, {"2027-10-04", 0, 0}] do
    test "transferred applied credit restores to its original expiry on #{on}", %{conn: conn} do
      apply_all(conn, [
        booking("issuer", [100]),
        cash("issuer", "payment", 100),
        cancel("issuer", %{"refund_method" => "hotel_credit"}),
        booking("source", [110]),
        credit_application("source", 110),
        booking("destination", [110], %{
          "arrival_on" => "2028-01-01",
          "departure_on" => "2028-01-02"
        })
      ])

      before = ledger(conn, unquote(on))

      apply_all(conn, [
        transfer_deposit("source", "destination", 110, %{"occurred_on" => unquote(on)})
      ])

      assert ledger(conn, unquote(on)) == before

      assert [%{"credit_issued_cents" => 0}] =
               apply_all(conn, [
                 cancel("destination", %{
                   "occurred_on" => unquote(on),
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert credit(conn, unquote(on))["available_cents"] == unquote(available)
      assert ledger(conn, unquote(on))["credit_liability_cents"] == unquote(liability)
      refute Map.has_key?(statement(conn, "payment"), "held_by_group")
    end
  end

  test "non-refundable settlement consumes transferred shortfalled credit", %{conn: conn} do
    apply_all(conn, [
      booking("issuer", [100]),
      cash("issuer", "payment", 100),
      cancel("issuer", %{"refund_method" => "hotel_credit"}),
      booking("source", [110]),
      credit_application("source", 110),
      booking("destination", [110], %{"rate_plan" => "advance_purchase"}),
      correction("charge_back_payment", "payment"),
      transfer_deposit("source", "destination", 110)
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 110

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0, "retained_cents" => 0}] =
             apply_all(conn, [cancel("destination")])

    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "transferred cash earns one combined bonus with entitlements in destination funding order",
       %{conn: conn} do
    apply_all(conn, [
      booking("source", [5, 5]),
      cash("source", "first", 5),
      cash("source", "second", 5),
      booking("destination", [3, 7]),
      transfer_deposit("source", "destination", 10)
    ])

    assert [%{"credit_issued_cents" => 11}] =
             apply_all(conn, [
               cancel("destination", %{
                 "refund_method" => "hotel_credit"
               })
             ])

    # The second payment arrived first at the destination: its five cents earn
    # six cents of entitlement, and the next five earn the remaining five.
    apply_all(conn, [correction("charge_back_payment", "first")])
    assert credit(conn, "2026-10-03")["available_cents"] == 6
    assert revisions(conn, ["source", "destination"]) == [5, 3]
    assert statement(conn, "first")["held_by_group"] == []
    apply_all(conn, [correction("charge_back_payment", "second")])
    assert credit(conn, "2026-10-03")["available_cents"] == 0
    assert ledger(conn)["cash_charged_back_cents"] == 10
    assert revisions(conn, ["source", "destination"]) == [6, 3]
  end

  test "transfers skip cancelled rooms and preserve separate credit lots", %{conn: conn} do
    apply_all(conn, [
      booking("issuer-a", [10]),
      cash("issuer-a", "payment-a", 10),
      cancel("issuer-a", %{"operation_id" => "lot-a", "refund_method" => "hotel_credit"}),
      booking("issuer-b", [10]),
      cash("issuer-b", "payment-b", 10),
      cancel("issuer-b", %{
        "operation_id" => "lot-b",
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-10-04"
      }),
      booking("source", [10, 20]),
      operation("cancel_rooms", %{"group_id" => "source", "room_ids" => ["r-0"]}),
      credit_application("source", 20),
      booking("destination", [5, 10, 10]),
      operation("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r-0"]}),
      transfer_deposit("source", "destination", 20)
    ])

    assert room_balances(conn, "source") == [{0, 0}, {0, 0}]
    assert room_balances(conn, "destination") == [{0, 0}, {0, 10}, {0, 10}]
    # The later lot leaves first. Cancelling the first active destination room
    # restores nine cents to B and one to A, preserving both original expiries.
    apply_all(conn, [
      operation("cancel_rooms", %{"group_id" => "destination", "room_ids" => ["r-1"]})
    ])

    assert credit(conn, "2026-10-04")["lots"] == [
             %{
               "source_operation_id" => "lot-a",
               "remaining_cents" => 1,
               "expires_on" => "2027-10-03"
             },
             %{
               "source_operation_id" => "lot-b",
               "remaining_cents" => 11,
               "expires_on" => "2027-10-04"
             }
           ]

    assert ledger(conn)["credit_liability_cents"] == 22
  end

  test "existence and revision preconditions precede transfer rules and rejected attempts are atomic",
       %{conn: conn} do
    apply_all(conn, [
      booking("source", [100]),
      cash("source", "payment", 50),
      booking("destination", [100]),
      cash("destination", "other-payment", 60),
      booking("other-guest", [100], %{"guest_id" => "other"}),
      booking("cancelled", [100]),
      cancel("cancelled")
    ])

    cases = [
      {transfer_deposit("missing-source", "missing-destination", 0), "group_not_found",
       "missing-source"},
      {transfer_deposit("source", "missing-destination", 0, %{"expected_revision" => 0}),
       "group_not_found", "missing-destination"},
      {transfer_deposit("source", "other-guest", 0, %{
         "expected_revision" => 1,
         "destination_expected_revision" => 0
       }), "stale_revision", "source"},
      {transfer_deposit("source", "other-guest", 0, %{
         "expected_revision" => 2,
         "destination_expected_revision" => 0
       }), "stale_revision", "other-guest"},
      {transfer_deposit("source", "source", 1, %{"destination_expected_revision" => 1}),
       "stale_revision", "source"},
      {transfer_deposit("source", "cancelled", 0, %{"destination_expected_revision" => 1}),
       "stale_revision", "cancelled"},
      {transfer_deposit("source", "source", 1), "invalid_transfer", nil},
      {transfer_deposit("source", "other-guest", 1), "invalid_transfer", nil},
      {transfer_deposit("cancelled", "source", 1), "group_not_active", "cancelled"},
      {transfer_deposit("source", "cancelled", 1), "group_not_active", "cancelled"},
      {transfer_deposit("source", "destination", 51), "transfer_exceeds_held_funding", nil},
      {transfer_deposit("source", "destination", 41), "transfer_exceeds_outstanding", nil}
    ]

    before = snapshot()

    for {operation, code, group_id} <- cases do
      assert [result] = submit(conn, [operation])
      assert result["status"] == "rejected"
      assert result["code"] == code
      assert result["group_id"] == group_id
      assert snapshot() == before
      assert Operations.get_result(operation["operation_id"]) == result
      assert submit(conn, [operation]) == [result]
    end

    refute Map.has_key?(statement(conn, "payment"), "held_by_group")
  end

  test "unusable amounts and missing routing data are handled rejections", %{conn: conn} do
    apply_all(conn, [
      booking("source", [100]),
      cash("source", "payment", 50),
      booking("destination", [100])
    ])

    before = snapshot()

    for amount <- [0, -1, nil, true, 1.5, "1", [], %{}] do
      assert [%{"code" => "invalid_amount"}] =
               submit(conn, [transfer_deposit("source", "destination", amount)])
    end

    for field <- ~w(source_group_id destination_group_id amount_cents occurred_on) do
      assert [%{"code" => "invalid_operation"}] =
               submit(conn, [Map.delete(transfer_deposit("source", "destination", 1), field)])
    end

    for field <- ~w(source_group_id destination_group_id), value <- [nil, "", 10, []] do
      assert [%{"code" => "invalid_operation"}] =
               submit(conn, [Map.put(transfer_deposit("source", "destination", 1), field, value)])
    end

    assert snapshot() == before
  end

  test "same-batch guards, exact retries, conflicts and durable rejection replay", %{conn: conn} do
    transfer =
      transfer_deposit("source", "destination", 50, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    stale = transfer_deposit("source", "destination", 1, %{"expected_revision" => 2})

    [_, _, _, result, retry, rejection, correction_result, replay] =
      apply_batch =
      submit(conn, [
        booking("source", [100]),
        cash("source", "payment", 100),
        booking("destination", [100]),
        transfer,
        transfer,
        stale,
        correction("reduce_cash_payment", "payment", %{
          "amount_cents" => 60,
          "expected_revision" => 3
        }),
        transfer
      ])

    assert result == retry and retry == replay

    assert rejection == %{
             "operation_id" => stale["operation_id"],
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 2,
             "actual_revision" => 3
           }

    assert correction_result["revision"] == 4
    assert Enum.count(apply_batch, &(&1["status"] == "rejected")) == 1
    before = snapshot()

    assert [
             ^rejection,
             %{"code" => "operation_id_conflict"},
             %{"code" => "operation_id_conflict"}
           ] =
             submit(conn, [
               stale,
               Map.put(stale, "expected_revision", 4),
               Map.put(transfer, "amount_cents", 40)
             ])

    assert snapshot() == before
    assert statement(conn, "payment")["held_by_group"] == held_groups([{"source", 40}])
  end

  defp booking(id, deposits, overrides \\ %{}) do
    open_group(%{
      "group_id" => id,
      "departure_on" => "2026-12-11",
      "rooms" =>
        Enum.with_index(deposits, fn due, index ->
          %{"room_id" => "r-#{index}", "nightly_rate_cents" => due * 5}
        end)
    })
    |> Map.merge(overrides)
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

  defp cancel(group, overrides \\ %{}),
    do: operation("cancel_group", Map.put(overrides, "group_id", group))

  defp credit_application(group, amount),
    do: operation("apply_hotel_credit", %{"group_id" => group, "amount_cents" => amount})

  defp correction(type, payment, overrides \\ %{}),
    do:
      operation(type, Map.put(overrides, "payment_operation_id", payment))
      |> Map.delete("group_id")

  defp submit(conn, operations),
    do:
      conn
      |> recycle()
      |> post(~p"/api/v1/partner-batches", %{operations: operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp apply_all(conn, operations) do
    results = submit(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp read(conn, path),
    do: conn |> recycle() |> get(path) |> json_response(200) |> Map.fetch!("data")

  defp group(conn, id), do: read(conn, ~p"/api/v1/groups/#{id}")
  defp ledger(conn, on \\ "2026-10-03"), do: read(conn, ~p"/api/v1/ledger?on=#{on}")
  defp credit(conn, on), do: read(conn, ~p"/api/v1/guests/guest-22/credit?on=#{on}")

  defp statement(conn, id) do
    statement = read(conn, ~p"/api/v1/payments/#{id}")

    dispositions =
      Map.take(
        statement,
        ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
      )

    assert Enum.sum(Map.values(dispositions)) == statement["recorded_cents"]

    if Map.has_key?(statement, "held_by_group"),
      do:
        assert(
          Enum.sum(Enum.map(statement["held_by_group"], & &1["amount_cents"])) ==
            statement["held_cents"]
        )

    statement
  end

  defp held_groups(groups),
    do: Enum.map(groups, fn {id, amount} -> %{"group_id" => id, "amount_cents" => amount} end)

  defp revisions(conn, ids), do: Enum.map(ids, &group(conn, &1)["revision"])

  defp room_balances(conn, id),
    do: Enum.map(group(conn, id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp snapshot,
    do:
      Map.new(
        [Group, Room, CashEntry, CashAllocation, Lot, Allocation, Entitlement],
        &{&1, Repo.all(&1)}
      )
end
