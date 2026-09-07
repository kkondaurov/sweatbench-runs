defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import GroupStay.PartnerOperations
  import GroupStay.RoomAccountingHelpers

  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.HotelCredit.{Entitlement, Lot}

  test "mixed funding moves newest allocations first, fills active rooms and preserves provenance",
       %{conn: conn} do
    seed_credit(conn, "lot-a")
    seed_credit(conn, "lot-b")

    submit(conn, [
      room_group("source", [100, 100, 100, 100]),
      payment(%{"group_id" => "source", "operation_id" => "p1", "amount_cents" => 70}),
      credit_payment(%{"group_id" => "source", "amount_cents" => 110}),
      payment(%{"group_id" => "source", "operation_id" => "p2", "amount_cents" => 100}),
      credit_payment(%{"group_id" => "source", "amount_cents" => 80}),
      room_group("destination", [100, 100, 100], %{"property_id" => "another-property"}),
      payment(%{"group_id" => "destination", "operation_id" => "own", "amount_cents" => 20}),
      cancel_rooms(["r2"], %{"group_id" => "destination"})
    ])

    ledger_before = ledger(conn)
    lots_before = Repo.all(Lot)

    move =
      transfer("source", "destination", 170, %{
        "expected_revision" => 5,
        "destination_expected_revision" => 3,
        "occurred_on" => "2026-10-10"
      })

    assert [result] = submit(conn, [move])

    assert result == %{
             "operation_id" => move["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 170,
             "source_outstanding_deposit_cents" => 210,
             "destination_outstanding_deposit_cents" => 10,
             "source_revision" => 6,
             "destination_revision" => 4
           }

    assert room_funding(conn, "source") == [{70, 30}, {10, 80}, {0, 0}, {0, 0}]
    assert room_funding(conn, "destination") == [{20, 80}, {0, 0}, {90, 0}]
    assert ledger(conn) == ledger_before
    assert Repo.all(Lot) == lots_before
    assert statement(conn, "p2")["held_by_group"] == [held("destination", 90), held("source", 10)]
    refute Map.has_key?(statement(conn, "p1"), "held_by_group")
    refute Map.has_key?(statement(conn, "own"), "held_by_group")

    before = domain_snapshot()
    assert submit(conn, [move]) == [result]
    assert Operations.get_result(move["operation_id"]) == result
    assert domain_snapshot() == before

    submit(conn, [transfer("destination", "source", 100)])
    assert room_funding(conn, "source") == [{70, 30}, {20, 80}, {80, 10}, {0, 0}]
    assert room_funding(conn, "destination") == [{20, 70}, {0, 0}, {0, 0}]
    assert statement(conn, "p2")["held_by_group"] == [held("source", 100)]
    assert ledger(conn) == ledger_before
  end

  test "existence and both revision guards precede all transfer rules", %{conn: conn} do
    submit(conn, [
      room_group("source"),
      room_group("destination", [100], %{"guest_id" => "other"})
    ])

    assert_rejected(
      conn,
      transfer("missing-source", "missing-destination", 0),
      "group_not_found",
      %{"group_id" => "missing-source"}
    )

    assert_rejected(
      conn,
      transfer("source", "missing-destination", 0, %{"expected_revision" => 99}),
      "group_not_found",
      %{"group_id" => "missing-destination"}
    )

    assert_rejected(
      conn,
      transfer("source", "destination", 0, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 2
      }),
      "stale_revision",
      %{"group_id" => "source", "expected_revision" => 2, "actual_revision" => 1}
    )

    assert_rejected(
      conn,
      transfer("source", "destination", 0, %{
        "expected_revision" => 1,
        "destination_expected_revision" => 2
      }),
      "stale_revision",
      %{"group_id" => "destination", "expected_revision" => 2, "actual_revision" => 1}
    )

    assert_rejected(
      conn,
      transfer("source", "source", 1, %{"destination_expected_revision" => nil}),
      "stale_revision",
      %{"group_id" => "source", "expected_revision" => nil, "actual_revision" => 1}
    )

    assert_rejected(conn, transfer("source", "source", 1), "invalid_transfer")
    assert_rejected(conn, transfer("source", "destination", 1), "invalid_transfer")
  end

  test "invalid envelopes and domain rejections are atomic and remembered", %{conn: conn} do
    submit(conn, [
      room_group("source"),
      payment(%{"group_id" => "source", "amount_cents" => 100}),
      room_group("destination", [50])
    ])

    for field <- ["source_group_id", "destination_group_id", "amount_cents", "occurred_on"] do
      assert_rejected(
        conn,
        Map.delete(transfer("source", "destination", 10), field),
        "invalid_operation"
      )
    end

    for field <- ["source_group_id", "destination_group_id"], value <- [nil, "", 1, []] do
      assert_rejected(
        conn,
        Map.put(transfer("source", "destination", 10), field, value),
        "invalid_operation"
      )
    end

    for amount <- [nil, 0, -1, 1.0, "1", true, [], %{}] do
      assert_rejected(conn, transfer("source", "destination", amount), "invalid_amount")
    end

    assert_rejected(conn, transfer("source", "destination", 101), "transfer_exceeds_held_funding")
    attempt = transfer("source", "destination", 51)
    rejection = assert_rejected(conn, attempt, "transfer_exceeds_outstanding")
    submit(conn, [transfer("source", "destination", 50), transfer("destination", "source", 50)])
    before = domain_snapshot()
    assert submit(conn, [attempt]) == [rejection]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(attempt, "amount_cents", 1)])

    assert domain_snapshot() == before
  end

  test "inactive groups are identified and revisions are checked first", %{conn: conn} do
    submit(conn, [
      room_group("source"),
      room_group("destination"),
      cancellation(%{"group_id" => "source"})
    ])

    assert_rejected(conn, transfer("source", "destination", 1), "group_not_active", %{
      "group_id" => "source"
    })

    assert_rejected(conn, transfer("destination", "source", 1), "group_not_active", %{
      "group_id" => "source"
    })

    assert_rejected(
      conn,
      transfer("destination", "source", 1, %{"destination_expected_revision" => 1}),
      "stale_revision",
      %{"group_id" => "source", "expected_revision" => 1, "actual_revision" => 2}
    )
  end

  test "same-batch transfers expose both revisions and stale retries remain exact", %{conn: conn} do
    move =
      transfer("source", "destination", 100, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    stale = transfer("source", "destination", 1, %{"destination_expected_revision" => 1})

    assert [_, _, _, applied, rejection, %{"revision" => 4}, %{"revision" => 3}] =
             submit(conn, [
               room_group("source"),
               room_group("destination"),
               payment(%{"group_id" => "source", "operation_id" => "p", "amount_cents" => 100}),
               move,
               stale,
               payment(%{"group_id" => "source", "amount_cents" => 1, "expected_revision" => 3}),
               payment(%{
                 "group_id" => "destination",
                 "amount_cents" => 1,
                 "expected_revision" => 2
               })
             ])

    assert rejection["code"] == "stale_revision"
    assert rejection["actual_revision"] == 2
    before = domain_snapshot()
    assert submit(conn, [move, stale]) == [applied, rejection]

    assert [%{"code" => "operation_id_conflict"}] =
             submit(conn, [Map.put(stale, "destination_expected_revision", 3)])

    assert domain_snapshot() == before
    assert statement(conn, "p")["held_by_group"] == [held("destination", 100)]
  end

  test "reductions remove a payment across groups by allocation order and revise only changed groups plus its origin",
       %{conn: conn} do
    original = payment(%{"group_id" => "origin", "operation_id" => "p", "amount_cents" => 300})

    [_, receipt | _] =
      submit(conn, [
        room_group("origin"),
        original,
        room_group("a", [50, 100]),
        room_group("z"),
        transfer("origin", "a", 150),
        transfer("a", "z", 100),
        transfer("origin", "z", 50)
      ])

    assert statement(conn, "p")["held_by_group"] == [
             held("a", 50),
             held("origin", 100),
             held("z", 150)
           ]

    untouched = group(conn, "a")
    reduction = reduce_cash("p", 120, %{"expected_revision" => 4})

    assert [%{"revision" => 5, "group_id" => "origin", "outstanding_deposit_cents" => 200}] =
             submit(conn, [reduction])

    assert group(conn, "a") == untouched
    assert group(conn, "z")["revision"] == 4
    assert room_funding(conn, "z") == [{30, 0}, {0, 0}, {0, 0}]

    assert statement(conn, "p")["held_by_group"] == [
             held("a", 50),
             held("origin", 100),
             held("z", 30)
           ]

    assert_rejected(conn, reduce_cash("p", 181, %{"expected_revision" => 4}), "stale_revision", %{
      "group_id" => "origin",
      "expected_revision" => 4,
      "actual_revision" => 5
    })

    assert_rejected(conn, reduce_cash("p", 181), "reduction_exceeds_held_cash")
    assert [%{"revision" => 6}] = submit(conn, [reduce_cash("p", 180)])
    assert group(conn, "a")["revision"] == 4
    assert group(conn, "z")["revision"] == 5
    assert statement(conn, "p")["held_by_group"] == []
    assert statement(conn, "p")["reduced_cents"] == 300
    assert ledger(conn)["cash_reduced_cents"] == 300
    assert submit(conn, [original]) == [receipt]
  end

  test "an emptied and cancelled original group still guards corrections to transferred cash", %{
    conn: conn
  } do
    submit(conn, [
      room_group("origin", [100]),
      room_group("destination"),
      payment(%{"group_id" => "origin", "operation_id" => "p", "amount_cents" => 100}),
      transfer("origin", "destination", 100),
      cancellation(%{"group_id" => "origin"})
    ])

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             submit(conn, [reduce_cash("p", 20, %{"expected_revision" => 4})])

    assert [%{"revision" => 6, "charged_back_cents" => 80, "outstanding_deposit_cents" => 0}] =
             submit(conn, [charge_back("p", %{"expected_revision" => 5})])

    assert group(conn, "destination")["revision"] == 4
    assert group(conn, "destination")["outstanding_deposit_cents"] == 300
    assert statement(conn, "p")["held_by_group"] == []
  end

  test "transferred cash settles under each destination policy and chargeback reclassifies the correct groups",
       %{conn: conn} do
    submit(conn, [
      room_group("origin", [100, 100, 100, 100]),
      payment(%{"group_id" => "origin", "operation_id" => "p", "amount_cents" => 400}),
      room_group("refund", [100]),
      room_group("retain", [20], %{"rate_plan" => "advance_purchase"}),
      room_group("convert", [100]),
      room_group("credit-user", [110]),
      transfer("origin", "refund", 100),
      transfer("origin", "retain", 100),
      transfer("origin", "convert", 100),
      cancellation(%{"group_id" => "refund"}),
      cancellation(%{"group_id" => "retain"}),
      cancellation(%{"group_id" => "convert", "refund_method" => "hotel_credit"}),
      credit_payment(%{"group_id" => "credit-user", "amount_cents" => 110}),
      reduce_cash("p", 20)
    ])

    assert %{
             "held_cents" => 80,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "converted_to_credit_cents" => 100,
             "reduced_cents" => 20
           } = statement(conn, "p")

    credit_user = group(conn, "credit-user")
    before = Map.new(~w(origin refund retain convert), &{&1, group(conn, &1)["revision"]})

    assert [%{"charged_back_cents" => 380, "revision" => 7}] =
             submit(conn, [charge_back("p", %{"expected_revision" => 6})])

    for id <- ~w(origin refund retain convert) do
      assert group(conn, id)["revision"] == before[id] + 1
      account = Reservations.get_group(id)

      assert {account.refunded_cents, account.retained_cents,
              account.cash_converted_to_credit_cents} == {0, 0, 0}
    end

    assert group(conn, "credit-user") == credit_user
    assert statement(conn, "p")["held_by_group"] == []

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 20,
             "cash_charged_back_cents" => 380,
             "credit_liability_cents" => 110,
             "credit_shortfall_cents" => 110
           }
  end

  test "transferred cash receives one combined bonus in destination allocation order", %{
    conn: conn
  } do
    submit(conn, [
      room_group("source", [10]),
      room_group("destination", [4, 6]),
      payment(%{"group_id" => "source", "operation_id" => "first", "amount_cents" => 4}),
      payment(%{"group_id" => "source", "operation_id" => "second", "amount_cents" => 6}),
      transfer("source", "destination", 10)
    ])

    assert [%{"credit_issued_cents" => 11}] =
             submit(conn, [
               cancel_rooms(["r2", "r1"], %{
                 "group_id" => "destination",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert Enum.map(Repo.all(Entitlement), & &1.amount_cents) == [7, 4]
    submit(conn, [charge_back("second")])
    assert credit(conn)["available_cents"] == 4
    assert statement(conn, "first")["converted_to_credit_cents"] == 4
  end

  test "selected destination rooms restore the exact lots that arrived in reverse order", %{
    conn: conn
  } do
    seed_credit(conn, "lot-a")

    submit(conn, [
      room_group("lot-b", [100]),
      payment(%{"group_id" => "lot-b", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "lot-b",
        "operation_id" => "issue-lot-b",
        "occurred_on" => "2026-11-02",
        "refund_method" => "hotel_credit"
      }),
      room_group("source", [110, 110]),
      room_group("destination", [110, 110]),
      credit_payment(%{
        "group_id" => "source",
        "amount_cents" => 220,
        "occurred_on" => "2026-11-03"
      }),
      transfer("source", "destination", 220),
      reschedule(%{"group_id" => "destination", "new_arrival_on" => "2028-06-01"})
    ])

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             submit(conn, [
               cancel_rooms(["r1"], %{
                 "group_id" => "destination",
                 "occurred_on" => "2027-11-01",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert read(conn, "/api/v1/guests/guest-22/credit?on=2027-11-01")["lots"] == [
             %{
               "source_operation_id" => "issue-lot-b",
               "remaining_cents" => 110,
               "expires_on" => "2027-11-02"
             }
           ]

    assert ledger(conn, "2027-11-01")["credit_liability_cents"] == 220

    submit(conn, [cancellation(%{"group_id" => "destination", "occurred_on" => "2027-11-02"})])
    assert ledger(conn, "2027-11-02")["credit_liability_cents"] == 110

    assert credit(conn)["lots"] == [
             %{
               "source_operation_id" => "issue-lot-b",
               "remaining_cents" => 110,
               "expires_on" => "2027-11-02"
             }
           ]
  end

  test "transferred credit stays redeemed after expiry and restores to its original lot without another bonus",
       %{conn: conn} do
    seed_credit(conn, "lot")

    submit(conn, [
      room_group("source", [110]),
      room_group("destination", [110]),
      credit_payment(%{"group_id" => "source", "amount_cents" => 110}),
      reschedule(%{"group_id" => "destination", "new_arrival_on" => "2028-06-01"})
    ])

    before = ledger(conn, "2027-11-02")
    submit(conn, [transfer("source", "destination", 110, %{"occurred_on" => "2027-11-02"})])
    assert ledger(conn, "2027-11-02") == before
    assert before["credit_liability_cents"] == 110

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             submit(conn, [
               cancellation(%{
                 "group_id" => "destination",
                 "occurred_on" => "2027-11-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert ledger(conn, "2027-11-02")["credit_liability_cents"] == 0
    assert credit(conn)["available_cents"] == 0

    assert [
             %Lot{
               source_operation_id: "issue-lot",
               expires_on: ~D[2027-11-01],
               remaining_cents: 0
             }
           ] = Repo.all(Lot)
  end

  test "shortfall follows transferred credit and absorbs refundable restoration before expiry", %{
    conn: conn
  } do
    seed_credit(conn, "lot")

    submit(conn, [
      room_group("source", [110]),
      room_group("destination", [50, 60]),
      credit_payment(%{"group_id" => "source", "amount_cents" => 110}),
      charge_back("cash-lot")
    ])

    before = ledger(conn)
    submit(conn, [transfer("source", "destination", 110)])
    assert ledger(conn) == before
    assert before["credit_shortfall_cents"] == 110

    submit(conn, [
      cancel_rooms(["r1"], %{"group_id" => "destination", "occurred_on" => "2026-11-27"})
    ])

    assert ledger(conn)["credit_shortfall_cents"] == 60
    assert ledger(conn)["credit_liability_cents"] == 60

    submit(conn, [
      reschedule(%{"group_id" => "destination", "new_arrival_on" => "2028-06-01"}),
      cancellation(%{"group_id" => "destination", "occurred_on" => "2027-11-02"})
    ])

    assert [%Lot{unrecovered_clawback_cents: 50, remaining_cents: 0}] = Repo.all(Lot)
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  defp seed_credit(conn, id) do
    submit(conn, [
      room_group(id, [100]),
      payment(%{"group_id" => id, "operation_id" => "cash-#{id}", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => id,
        "operation_id" => "issue-#{id}",
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp assert_rejected(conn, operation, code, details \\ %{}) do
    before = domain_snapshot()
    [result] = submit(conn, [operation])

    assert result ==
             Map.merge(
               %{
                 "operation_id" => operation["operation_id"],
                 "status" => "rejected",
                 "code" => code
               },
               details
             )

    assert domain_snapshot() == before
    assert Operations.get_result(operation["operation_id"]) == result
    result
  end

  defp room_funding(conn, id),
    do: Enum.map(group(conn, id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp held(id, amount), do: %{"group_id" => id, "amount_cents" => amount}

  defp submit(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(conn, path), do: conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(conn, id), do: read(conn, "/api/v1/groups/#{id}")
  defp statement(conn, id), do: read(conn, "/api/v1/payments/#{id}")
  defp ledger(conn, on \\ "2026-11-01"), do: read(conn, "/api/v1/ledger?on=#{on}")
  defp credit(conn), do: read(conn, "/api/v1/guests/guest-22/credit?on=2026-11-01")
end
