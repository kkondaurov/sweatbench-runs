defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}

  alias GroupStay.Reservations.{
    CashAllocation,
    CashEntry,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    RoomCreditAllocation
  }

  test "mixed funding moves newest first, fills active destination rooms, and preserves all ledger totals",
       %{conn: conn} do
    seed_credit(conn)

    submit(conn, [
      booking("group-81"),
      payment(%{"operation_id" => "older", "amount_cents" => 60, "occurred_on" => "2026-11-03"}),
      credit_application(%{"amount_cents" => 110}),
      payment(%{"operation_id" => "newer", "amount_cents" => 130, "occurred_on" => "2026-10-01"}),
      booking("destination", %{
        "property_id" => "another-property",
        "rooms" => rooms(~w(z a m last))
      }),
      room_cancellation(%{"group_id" => "destination", "room_ids" => ["z"]}),
      payment(%{
        "group_id" => "destination",
        "operation_id" => "destination-payment",
        "amount_cents" => 20
      })
    ])

    ledger = Reservations.ledger(~D[2026-11-03])

    operation =
      transfer(%{
        "amount_cents" => 210,
        "expected_revision" => 4,
        "destination_expected_revision" => 3
      })

    assert [result] = submit(conn, [operation])

    assert result == %{
             "operation_id" => operation["operation_id"],
             "status" => "applied",
             "source_group_id" => "group-81",
             "destination_group_id" => "destination",
             "amount_cents" => 210,
             "source_outstanding_deposit_cents" => 210,
             "destination_outstanding_deposit_cents" => 70,
             "source_revision" => 5,
             "destination_revision" => 4
           }

    assert room_balances(conn, "group-81") == [{60, 30}, {0, 0}, {0, 0}]
    assert room_balances(conn, "destination") == [{0, 0}, {100, 0}, {50, 50}, {0, 30}]
    assert Reservations.ledger(~D[2026-11-03]) == ledger
    assert statement(conn, "newer")["held_by_group"] == [held("destination", 130)]
    refute Map.has_key?(statement(conn, "older"), "held_by_group")
    refute Map.has_key?(statement(conn, "destination-payment"), "held_by_group")

    before = snapshot()
    assert submit(conn, [operation]) == [result]
    assert snapshot() == before

    assert get(conn, "/api/v1/operations/#{operation["operation_id"]}") |> json_response(200) ==
             %{"data" => result}
  end

  test "transferred portions become newest and repeated transfers preserve draw order", %{
    conn: conn
  } do
    seed_credit(conn)

    submit(conn, [
      booking("group-81"),
      booking("destination"),
      booking("third"),
      payment(%{"operation_id" => "payment", "amount_cents" => 60}),
      credit_application(%{"amount_cents" => 110}),
      payment(%{"operation_id" => "last", "amount_cents" => 130}),
      transfer(%{"amount_cents" => 210}),
      transfer(%{
        "source_group_id" => "destination",
        "destination_group_id" => "third",
        "amount_cents" => 100
      })
    ])

    assert room_balances(conn, "third") == [{20, 80}, {0, 0}, {0, 0}]
    assert room_balances(conn, "destination") == [{100, 0}, {10, 0}, {0, 0}]

    assert statement(conn, "last")["held_by_group"] == [
             held("destination", 110),
             held("third", 20)
           ]

    assert [%{"revision" => 6}] =
             submit(conn, [
               reduction(%{
                 "payment_operation_id" => "last",
                 "amount_cents" => 40,
                 "expected_revision" => 5
               })
             ])

    assert room_balances(conn, "third") == [{0, 80}, {0, 0}, {0, 0}]
    assert room_balances(conn, "destination") == [{90, 0}, {0, 0}, {0, 0}]
    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "third")["revision"] == 3
    assert statement(conn, "last")["held_by_group"] == [held("destination", 90)]
  end

  test "existence and both revision guards precede transfer rules and payload validation", %{
    conn: conn
  } do
    submit(conn, [booking("group-81"), booking("destination"), payment(%{"amount_cents" => 100})])

    cases = [
      {%{"source_group_id" => "missing-source", "destination_group_id" => "missing-destination"},
       %{"code" => "group_not_found", "group_id" => "missing-source"}},
      {%{"destination_group_id" => "missing-destination", "expected_revision" => 0},
       %{"code" => "group_not_found", "group_id" => "missing-destination"}},
      {%{"expected_revision" => 1, "destination_expected_revision" => 0, "amount_cents" => -1},
       %{
         "code" => "stale_revision",
         "group_id" => "group-81",
         "expected_revision" => 1,
         "actual_revision" => 2
       }},
      {%{
         "expected_revision" => 2,
         "destination_expected_revision" => 0,
         "amount_cents" => -1,
         "occurred_on" => "bad"
       },
       %{
         "code" => "stale_revision",
         "group_id" => "destination",
         "expected_revision" => 0,
         "actual_revision" => 1
       }},
      {%{"destination_group_id" => "group-81", "destination_expected_revision" => 0},
       %{
         "code" => "stale_revision",
         "group_id" => "group-81",
         "expected_revision" => 0,
         "actual_revision" => 2
       }}
    ]

    for {overrides, fields} <- cases do
      operation = transfer(overrides)
      before = snapshot()

      assert submit(conn, [operation]) == [
               Map.merge(fields, %{
                 "operation_id" => operation["operation_id"],
                 "status" => "rejected"
               })
             ]

      assert snapshot() == before
    end

    for field <- ~w(expected_revision destination_expected_revision),
        value <- [nil, "1", 1.0, false] do
      assert [%{"code" => "stale_revision"}] = submit(conn, [transfer(%{field => value})])
    end
  end

  test "transfer validation rejects atomically and identifies the inactive group", %{conn: conn} do
    submit(conn, [
      booking("group-81"),
      booking("destination"),
      booking("other-guest", %{"guest_id" => "other"}),
      booking("cancelled"),
      cancellation(%{"group_id" => "cancelled"}),
      payment(%{"amount_cents" => 100}),
      payment(%{"group_id" => "destination", "amount_cents" => 280})
    ])

    cases =
      [
        {%{"destination_group_id" => "group-81"}, "invalid_transfer", nil},
        {%{"destination_group_id" => "other-guest"}, "invalid_transfer", nil},
        {%{"source_group_id" => "cancelled"}, "group_not_active", "cancelled"},
        {%{"destination_group_id" => "cancelled"}, "group_not_active", "cancelled"},
        {%{"amount_cents" => 101}, "transfer_exceeds_held_funding", nil},
        {%{"amount_cents" => 21}, "transfer_exceeds_outstanding", nil}
      ] ++
        Enum.map(
          [0, -1, nil, true, 1.0, "1", [], %{}],
          &{%{"amount_cents" => &1}, "invalid_amount", nil}
        )

    for {overrides, code, group_id} <- cases do
      before = snapshot()
      assert [result] = submit(conn, [transfer(overrides)])
      assert result["code"] == code
      assert result["group_id"] == group_id
      assert snapshot() == before
    end

    for field <- ~w(source_group_id destination_group_id amount_cents occurred_on) do
      assert [%{"code" => "invalid_operation"}] = submit(conn, [Map.delete(transfer(), field)])
    end

    for field <- ~w(source_group_id destination_group_id), value <- [nil, " ", 1, %{}] do
      assert [%{"code" => "invalid_operation"}] = submit(conn, [transfer(%{field => value})])
    end
  end

  test "same-batch guards see transfers and exact results survive later corrections and conflicts",
       %{conn: conn} do
    original = payment(%{"operation_id" => "payment", "amount_cents" => 100})

    move =
      transfer(%{
        "expected_revision" => 2,
        "destination_expected_revision" => 1,
        "amount_cents" => 100
      })

    early = transfer(%{"operation_id" => "early"})

    [rejected, _, _, original_result, move_result, stale, applied] =
      submit(conn, [
        early,
        booking("group-81"),
        booking("destination"),
        original,
        move,
        payment(%{"group_id" => "destination", "expected_revision" => 1, "amount_cents" => 10}),
        reduction(%{"amount_cents" => 100, "expected_revision" => 3})
      ])

    assert stale["code"] == "stale_revision"
    assert stale["actual_revision"] == 2
    assert applied["revision"] == 4
    assert group(conn, "destination")["revision"] == 3
    assert statement(conn, "payment")["held_by_group"] == []

    before = snapshot()
    assert submit(conn, [early, original, move]) == [rejected, original_result, move_result]
    assert snapshot() == before

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(move, "destination_expected_revision", 3)])
  end

  test "reductions follow newest cash across groups and advance each affected group once", %{
    conn: conn
  } do
    submit(conn, [
      booking("group-81"),
      booking("destination"),
      booking("third"),
      payment(%{"operation_id" => "payment", "amount_cents" => 300}),
      transfer(%{"amount_cents" => 120}),
      transfer(%{"destination_group_id" => "third", "amount_cents" => 80})
    ])

    assert statement(conn, "payment")["held_by_group"] == [
             held("destination", 120),
             held("group-81", 100),
             held("third", 80)
           ]

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 200}] =
             submit(conn, [reduction(%{"amount_cents" => 150, "expected_revision" => 4})])

    assert room_balances(conn, "destination") == [{50, 0}, {0, 0}, {0, 0}]
    assert room_balances(conn, "third") == [{0, 0}, {0, 0}, {0, 0}]
    assert group(conn, "destination")["revision"] == 3
    assert group(conn, "third")["revision"] == 3

    assert statement(conn, "payment")["held_by_group"] == [
             held("destination", 50),
             held("group-81", 100)
           ]

    before = snapshot()

    assert [%{"code" => "stale_revision", "group_id" => "group-81", "actual_revision" => 5}] =
             submit(conn, [chargeback(%{"expected_revision" => 4})])

    assert snapshot() == before

    assert [%{"revision" => 6, "charged_back_cents" => 150}] =
             submit(conn, [chargeback(%{"expected_revision" => 5})])

    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "third")["revision"] == 3
    assert statement(conn, "payment")["held_by_group"] == []
    assert Reservations.ledger().cash_reduced_cents == 150
    assert Reservations.ledger().cash_charged_back_cents == 150
  end

  test "corrections still address a cancelled original group after all held cash has moved", %{
    conn: conn
  } do
    submit(conn, [
      booking("group-81"),
      booking("destination"),
      payment(%{"operation_id" => "payment", "amount_cents" => 100}),
      transfer(%{"amount_cents" => 100}),
      cancellation()
    ])

    assert [%{"group_id" => "group-81", "revision" => 5, "outstanding_deposit_cents" => 0}] =
             submit(conn, [reduction(%{"expected_revision" => 4})])

    assert group(conn, "destination")["revision"] == 3

    assert [%{"group_id" => "group-81", "revision" => 6, "charged_back_cents" => 50}] =
             submit(conn, [chargeback(%{"expected_revision" => 5})])

    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "group-81")["status"] == "cancelled"
    assert statement(conn, "payment")["held_by_group"] == []
  end

  test "cash settles under destination policy and chargeback follows every transferred disposition",
       %{conn: conn} do
    submit(conn, [
      booking("group-81", %{"rate_plan" => "advance_purchase"}),
      booking("destination"),
      booking("retained", %{"rate_plan" => "advance_purchase"}),
      booking("converted"),
      booking("held"),
      payment(%{"operation_id" => "payment", "amount_cents" => 500}),
      transfer(%{"amount_cents" => 100}),
      transfer(%{"destination_group_id" => "retained", "amount_cents" => 100}),
      transfer(%{"destination_group_id" => "converted", "amount_cents" => 100}),
      transfer(%{"destination_group_id" => "held", "amount_cents" => 100}),
      cancellation(%{"group_id" => "destination"}),
      cancellation(%{"group_id" => "retained"}),
      cancellation(%{"group_id" => "converted", "refund_method" => "hotel_credit"}),
      reduction(%{"amount_cents" => 20})
    ])

    current = statement(conn, "payment")

    assert Map.take(
             current,
             ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents)
           ) == %{
             "held_cents" => 180,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 20
           }

    assert current["held_by_group"] == [held("group-81", 100), held("held", 80)]
    assert [%{"charged_back_cents" => 480, "revision" => 8}] = submit(conn, [chargeback()])
    assert group(conn, "held")["revision"] == 4
    current = statement(conn, "payment")
    assert current["charged_back_cents"] == 480
    assert current["reduced_cents"] == 20
    assert current["held_by_group"] == []
    ledger = Reservations.ledger(~D[2026-11-01])
    assert ledger.cash_held_cents == 0
    assert ledger.cash_refunded_cents == 0
    assert ledger.cash_retained_cents == 0
    assert ledger.cash_converted_to_credit_cents == 0
    assert ledger.credit_liability_cents == 0
  end

  test "conversion entitlements follow destination allocation order and telescope per lot", %{
    conn: conn
  } do
    submit(conn, [
      booking("group-81"),
      booking("destination"),
      payment(%{"operation_id" => "first", "amount_cents" => 5}),
      payment(%{"operation_id" => "second", "amount_cents" => 5}),
      transfer(%{"amount_cents" => 10}),
      cancellation(%{
        "group_id" => "destination",
        "operation_id" => "lot",
        "refund_method" => "hotel_credit"
      })
    ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 11
    # The second payment arrived first at the destination and owns the rounded bonus.
    assert [%{"charged_back_cents" => 5}] =
             submit(conn, [chargeback(%{"payment_operation_id" => "first"})])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 6

    assert [%{"charged_back_cents" => 5}] =
             submit(conn, [chargeback(%{"payment_operation_id" => "second"})])

    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 0
  end

  test "transferred credit stays applied past expiry and restores to its original lot without a bonus",
       %{conn: conn} do
    seed_credit(conn)

    submit(conn, [
      booking("group-81"),
      booking("destination", %{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-02"}),
      credit_application(%{"amount_cents" => 110})
    ])

    before = Reservations.ledger(~D[2027-12-01])

    assert [%{"status" => "applied"}] =
             submit(conn, [transfer(%{"amount_cents" => 110, "occurred_on" => "2027-12-01"})])

    assert Reservations.ledger(~D[2027-12-01]) == before

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             submit(conn, [
               cancellation(%{
                 "group_id" => "destination",
                 "occurred_on" => "2027-12-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert Reservations.guest_credit("guest-22", ~D[2027-12-01]).available_cents == 0
    assert Reservations.ledger(~D[2027-12-01]).credit_liability_cents == 0

    assert [
             %CreditLot{
               source_operation_id: "seed-lot",
               expires_on: ~D[2027-11-01],
               remaining_cents: 110
             }
           ] = Repo.all(CreditLot)
  end

  test "transferred shortfalled credit absorbs restoration before expiry and is consumed normally",
       %{conn: conn} do
    seed_credit(conn)

    submit(conn, [
      booking("group-81"),
      booking("destination", %{"arrival_on" => "2028-01-01", "departure_on" => "2028-01-02"}),
      credit_application(%{"amount_cents" => 110}),
      transfer(%{"amount_cents" => 110}),
      chargeback(%{"payment_operation_id" => "seed-payment"})
    ])

    assert Reservations.ledger(~D[2026-11-01]).credit_shortfall_cents == 110
    assert group(conn, "destination")["revision"] == 2

    assert [%{"credit_issued_cents" => 0}] =
             submit(conn, [
               room_cancellation(%{
                 "group_id" => "destination",
                 "room_ids" => ["z"],
                 "occurred_on" => "2027-12-01"
               })
             ])

    assert Reservations.ledger(~D[2027-12-01]).credit_shortfall_cents == 10
    assert [%CreditLot{remaining_cents: 0, unrecovered_clawback_cents: 10}] = Repo.all(CreditLot)
    submit(conn, [cancellation(%{"group_id" => "destination", "occurred_on" => "2028-01-01"})])
    assert Reservations.ledger(~D[2028-01-01]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 0
  end

  test "transfers draw newer credit lots first and restore every portion to its original lot", %{
    conn: conn
  } do
    seed_credit(conn)

    submit(conn, [
      booking("second-seed"),
      payment(%{
        "group_id" => "second-seed",
        "operation_id" => "second-seed-payment",
        "amount_cents" => 100
      }),
      cancellation(%{
        "group_id" => "second-seed",
        "operation_id" => "second-lot",
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-11-02"
      }),
      booking("group-81"),
      booking("destination"),
      credit_application(%{"amount_cents" => 130, "occurred_on" => "2026-11-03"}),
      transfer(%{"amount_cents" => 15, "occurred_on" => "2026-11-03"}),
      cancellation(%{
        "group_id" => "destination",
        "refund_method" => "hotel_credit",
        "occurred_on" => "2026-11-03"
      })
    ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-03]).lots == [
             %{
               source_operation_id: "second-lot",
               remaining_cents: 105,
               expires_on: ~D[2027-11-02]
             }
           ]

    assert Reservations.ledger(~D[2026-11-03]).credit_liability_cents == 220

    submit(conn, [
      booking("third"),
      transfer(%{"destination_group_id" => "third", "amount_cents" => 45}),
      cancellation(%{"group_id" => "third"})
    ])

    assert Reservations.guest_credit("guest-22", ~D[2026-11-03]).lots == [
             %{source_operation_id: "seed-lot", remaining_cents: 40, expires_on: ~D[2027-11-01]},
             %{
               source_operation_id: "second-lot",
               remaining_cents: 110,
               expires_on: ~D[2027-11-02]
             }
           ]

    assert Reservations.ledger(~D[2026-11-03]).credit_liability_cents == 220
    refute Map.has_key?(statement(conn, "seed-payment"), "held_by_group")
    refute Map.has_key?(statement(conn, "second-seed-payment"), "held_by_group")
  end

  test "a round trip retains statement participation after all held cash is settled", %{
    conn: conn
  } do
    submit(conn, [
      booking("group-81"),
      booking("destination"),
      payment(%{"operation_id" => "payment", "amount_cents" => 100}),
      transfer(%{"amount_cents" => 100}),
      transfer(%{
        "source_group_id" => "destination",
        "destination_group_id" => "group-81",
        "amount_cents" => 100
      })
    ])

    assert statement(conn, "payment")["held_by_group"] == [held("group-81", 100)]
    submit(conn, [cancellation()])
    assert statement(conn, "payment")["held_by_group"] == []
    assert statement(conn, "payment")["refunded_cents"] == 100
  end

  defp booking(id, overrides \\ %{}),
    do:
      open_group(
        Map.merge(
          %{"group_id" => id, "departure_on" => "2026-12-11", "rooms" => rooms(~w(z a m))},
          overrides
        )
      )

  defp rooms(ids), do: Enum.map(ids, &%{"room_id" => &1, "nightly_rate_cents" => 500})

  defp seed_credit(conn) do
    submit(conn, [
      booking("seed"),
      payment(%{"group_id" => "seed", "operation_id" => "seed-payment", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "seed",
        "operation_id" => "seed-lot",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp room_balances(conn, id),
    do: Enum.map(group(conn, id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp held(id, amount), do: %{"group_id" => id, "amount_cents" => amount}

  defp statement(conn, id) do
    before = snapshot()
    data = conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")
    assert snapshot() == before

    assert Enum.sum(
             Map.values(
               Map.take(
                 data,
                 ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
               )
             )
           ) == data["recorded_cents"]

    if Map.has_key?(data, "held_by_group"),
      do:
        assert(
          Enum.sum(Enum.map(data["held_by_group"], & &1["amount_cents"])) == data["held_cents"]
        )

    data
  end

  defp snapshot,
    do:
      Enum.map(
        [
          Group,
          CashEntry,
          CashAllocation,
          CreditLot,
          CreditAllocation,
          RoomCreditAllocation,
          CreditEntitlement
        ],
        &Repo.all/1
      )
end
