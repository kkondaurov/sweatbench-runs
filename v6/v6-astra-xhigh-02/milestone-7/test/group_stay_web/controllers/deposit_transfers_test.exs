defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.ReservationFixtures
  alias GroupStay.{Repo, Reservations}

  test "transfers draw mixed funding newest first and fill only active destination rooms", %{
    conn: conn
  } do
    issue(conn, "issuer", 100)

    applied(conn, [
      opening("source", [100, 100, 100]),
      opening("destination", [0, 100, 100], %{"property_id" => "other-property"}),
      pay("old", "source", 60),
      op("apply_hotel_credit", "source", %{"amount_cents" => 100}),
      pay("new", "source", 90),
      pay("destination-pay", "destination", 20),
      op("cancel_rooms", "destination", %{"room_ids" => ["r1"]})
    ])

    before = ledger(conn)

    transfer =
      transfer("source", "destination", 170, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 3
      })

    [result] = applied(conn, [transfer])

    assert result == %{
             "operation_id" => transfer["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 170,
             "source_outstanding_deposit_cents" => 220,
             "destination_outstanding_deposit_cents" => 10,
             "source_revision" => 5,
             "destination_revision" => 4
           }

    assert room_balances(conn, "source") == [{60, 20}, {0, 0}, {0, 0}]
    assert room_balances(conn, "destination") == [{0, 0}, {100, 0}, {10, 80}]
    assert ledger(conn) == before
    assert statement(conn, "new")["held_by_group"] == held_by([{"destination", 90}])
    refute Map.has_key?(statement(conn, "old"), "held_by_group")
    refute Map.has_key?(statement(conn, "destination-pay"), "held_by_group")
    snapshot = snapshot()
    assert batch(conn, [transfer]) == [result]

    assert get(conn, "/api/v1/operations/#{transfer["operation_id"]}") |> json_response(200) == %{
             "data" => result
           }

    assert snapshot() == snapshot
  end

  test "transfer allocation order determines later cash bonus entitlements", %{conn: conn} do
    applied(conn, [
      opening("source", [10]),
      opening("destination", [5, 5]),
      pay("z-first", "source", 5),
      pay("a-second", "source", 5),
      transfer("source", "destination", 10)
    ])

    [cancelled] =
      applied(conn, [op("cancel_group", "destination", %{"refund_method" => "hotel_credit"})])

    assert cancelled["credit_issued_cents"] == 11
    applied(conn, [correction("charge_back_payment", "a-second")])
    assert ledger(conn)["credit_liability_cents"] == 5
    assert statement(conn, "a-second")["held_by_group"] == []
    assert statement(conn, "z-first")["converted_to_credit_cents"] == 5
    applied(conn, [correction("charge_back_payment", "z-first")])
    assert ledger(conn)["credit_liability_cents"] == 0
    assert ledger(conn)["cash_converted_to_credit_cents"] == 0
  end

  test "reductions follow global allocation creation order and revise only changed groups plus the origin",
       %{conn: conn} do
    payment = pay("p", "source", 300)

    results =
      applied(conn, [
        opening("source", [100, 100, 100]),
        opening("z", [100]),
        opening("a", [100]),
        opening("untouched", [100]),
        pay("seed-1", "source", 10),
        correction("reduce_cash_payment", "seed-1", %{"amount_cents" => 10}),
        pay("seed-2", "source", 10),
        correction("reduce_cash_payment", "seed-2", %{"amount_cents" => 10}),
        payment,
        transfer("source", "z", 100),
        transfer("source", "a", 100)
      ])

    original_payment = Enum.at(results, 8)

    assert statement(conn, "p")["held_by_group"] ==
             held_by([{"a", 100}, {"source", 100}, {"z", 100}])

    reduction =
      correction("reduce_cash_payment", "p", %{"amount_cents" => 150, "expected_revision" => 8})

    [reduced] = applied(conn, [reduction])
    assert reduced["revision"] == 9
    assert reduced["group_id"] == "source"
    assert reduced["outstanding_deposit_cents"] == 200
    assert statement(conn, "p")["held_by_group"] == held_by([{"source", 100}, {"z", 50}])
    assert group(conn, "a")["revision"] == 3
    assert group(conn, "z")["revision"] == 3
    assert group(conn, "untouched")["revision"] == 1

    # The original group may be cancelled while its payment still funds another group.
    applied(conn, [op("cancel_group", "source")])

    [last] =
      applied(conn, [
        correction("reduce_cash_payment", "p", %{"amount_cents" => 50, "expected_revision" => 10})
      ])

    assert last["revision"] == 11
    assert last["outstanding_deposit_cents"] == 0
    assert group(conn, "z")["revision"] == 4
    assert group(conn, "a")["revision"] == 3
    assert statement(conn, "p")["held_by_group"] == []
    assert statement(conn, "p")["refunded_cents"] == 100
    before = snapshot()
    assert batch(conn, [payment, reduction]) == [original_payment, reduced]
    assert snapshot() == before
  end

  test "chargebacks reclassify cash settled at every destination and leave credit-funded groups unchanged",
       %{conn: conn} do
    applied(conn, [
      opening("source", [550]),
      pay("p", "source", 550),
      correction("reduce_cash_payment", "p", %{"amount_cents" => 50})
    ])

    for id <- ~w(held refunded retained converted) do
      applied(conn, [opening(id, [100]), transfer("source", id, 100)])
    end

    applied(conn, [
      op("cancel_group", "refunded"),
      op("cancel_group", "retained", %{"occurred_on" => "2026-11-27"}),
      op("cancel_group", "converted", %{"refund_method" => "hotel_credit"}),
      opening("credit-user", [100]),
      op("apply_hotel_credit", "credit-user", %{"amount_cents" => 100})
    ])

    ids = ~w(source held refunded retained converted)
    revisions = Map.new(ids, &{&1, group(conn, &1)["revision"]})
    credit_user = group(conn, "credit-user")

    chargeback =
      correction("charge_back_payment", "p", %{"expected_revision" => revisions["source"]})

    [charged] = applied(conn, [chargeback])
    assert charged["charged_back_cents"] == 500
    assert charged["revision"] == revisions["source"] + 1
    for id <- ids, do: assert(group(conn, id)["revision"] == revisions[id] + 1)
    assert group(conn, "credit-user") == credit_user
    assert statement(conn, "p")["held_by_group"] == []
    assert statement(conn, "p")["reduced_cents"] == 50
    assert statement(conn, "p")["charged_back_cents"] == 500

    assert ledger(conn) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 500,
             "credit_liability_cents" => 100,
             "credit_shortfall_cents" => 100
           }

    before = snapshot()
    assert batch(conn, [chargeback]) == [charged]
    assert snapshot() == before
    applied(conn, [op("cancel_group", "credit-user")])
    assert ledger(conn)["credit_shortfall_cents"] == 0
    assert ledger(conn)["credit_liability_cents"] == 0
  end

  test "transferred cash settles under the destination policy and can return to its original group",
       %{conn: conn} do
    applied(conn, [
      opening("source", [100], %{"rate_plan" => "advance_purchase"}),
      opening("destination", [100]),
      pay("p", "source", 100),
      transfer("source", "destination", 100),
      transfer("destination", "source", 40)
    ])

    assert statement(conn, "p")["held_by_group"] == held_by([{"destination", 60}, {"source", 40}])
    applied(conn, [op("cancel_group", "destination"), op("cancel_group", "source")])
    assert statement(conn, "p")["refunded_cents"] == 60
    assert statement(conn, "p")["retained_cents"] == 40
    assert statement(conn, "p")["held_by_group"] == []
    applied(conn, [correction("charge_back_payment", "p")])
    assert ledger(conn)["cash_charged_back_cents"] == 100
  end

  test "credit transfers pause expiry and refundable returns preserve each lot and absorb shortfall first",
       %{conn: conn} do
    issue(conn, "issuer", 100)

    applied(conn, [
      opening("source", [110]),
      opening("destination", [110], %{
        "arrival_on" => "2028-04-01",
        "departure_on" => "2028-04-02"
      }),
      op("apply_hotel_credit", "source", %{"amount_cents" => 110})
    ])

    applied(conn, [correction("charge_back_payment", "issuer-pay")])
    before = ledger(conn, "2027-10-05")
    applied(conn, [transfer("source", "destination", 110, %{"occurred_on" => "2027-10-05"})])
    assert ledger(conn, "2027-10-05") == before
    assert group(conn, "destination")["credit_paid_cents"] == 110

    [cancelled] =
      applied(conn, [
        op("cancel_group", "destination", %{
          "occurred_on" => "2027-10-05",
          "refund_method" => "hotel_credit"
        })
      ])

    assert cancelled["credit_issued_cents"] == 0
    assert ledger(conn, "2027-10-05")["credit_liability_cents"] == 0
    assert ledger(conn, "2027-10-05")["credit_shortfall_cents"] == 0
    assert Repo.one(GroupStay.Reservations.CreditLot).unrecovered_clawback_cents == 0
  end

  test "transferred lots restore to their own expiry without a second bonus or are consumed", %{
    conn: conn
  } do
    issue(conn, "first", 100)
    issue(conn, "second", 100, "2026-10-05")

    applied(conn, [
      opening("source", [220]),
      opening("destination", [100, 100]),
      op("apply_hotel_credit", "source", %{"amount_cents" => 220, "occurred_on" => "2026-10-05"}),
      transfer("source", "destination", 150)
    ])

    # Reverse draw takes the second lot's 110, then 40 from the first.
    applied(conn, [op("cancel_rooms", "destination", %{"room_ids" => ["r1"]})])
    lots = Reservations.guest_credit("guest-22", ~D[2026-10-05]).lots

    assert Enum.map(lots, &{&1.source_operation_id, &1.remaining_cents, &1.expires_on}) ==
             [{"second-cancel", 100, ~D[2027-10-05]}]

    applied(conn, [op("cancel_group", "destination", %{"occurred_on" => "2026-11-27"})])
    assert ledger(conn)["credit_liability_cents"] == 170
    applied(conn, [op("cancel_group", "source")])
    assert Reservations.guest_credit("guest-22", ~D[2026-10-05]).available_cents == 170
  end

  test "existence and both revision guards precede transfer rules with stable group details", %{
    conn: conn
  } do
    applied(conn, [
      opening("source", [100]),
      opening("destination", [100]),
      pay("p", "source", 50)
    ])

    rejected(conn, transfer("absent-source", "absent-destination", 0), %{
      "code" => "group_not_found",
      "group_id" => "absent-source"
    })

    rejected(conn, transfer("source", "absent-destination", 0, %{"expected_revision" => 0}), %{
      "code" => "group_not_found",
      "group_id" => "absent-destination"
    })

    rejected(
      conn,
      transfer("source", "destination", 0, %{
        "expected_revision" => 1,
        "destination_expected_revision" => 0
      }),
      %{
        "code" => "stale_revision",
        "group_id" => "source",
        "expected_revision" => 1,
        "actual_revision" => 2
      }
    )

    stale =
      transfer("source", "destination", 0, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 0
      })

    result =
      rejected(conn, stale, %{
        "code" => "stale_revision",
        "group_id" => "destination",
        "expected_revision" => 0,
        "actual_revision" => 1
      })

    applied(conn, [transfer("source", "destination", 10)])
    assert batch(conn, [stale]) == [result]

    rejected(conn, Map.put(stale, "destination_expected_revision", 2), %{
      "code" => "operation_id_conflict"
    })

    for value <- [nil, "3", 3.0] do
      rejected(conn, transfer("source", "destination", 1, %{"expected_revision" => value}), %{
        "code" => "stale_revision",
        "group_id" => "source",
        "expected_revision" => value,
        "actual_revision" => 3
      })
    end

    applied(conn, [op("cancel_group", "destination")])

    rejected(
      conn,
      transfer("source", "destination", 1, %{"destination_expected_revision" => 1}),
      %{
        "code" => "stale_revision",
        "group_id" => "destination",
        "expected_revision" => 1,
        "actual_revision" => 3
      }
    )

    rejected(conn, transfer("source", "destination", 1), %{
      "code" => "group_not_active",
      "group_id" => "destination"
    })

    rejected(conn, transfer("destination", "source", 1), %{
      "code" => "group_not_active",
      "group_id" => "destination"
    })
  end

  test "invalid transfers are atomic, remembered, and do not stop the batch", %{conn: conn} do
    applied(conn, [
      opening("source", [100]),
      opening("destination", [10]),
      opening("stranger", [100], %{"guest_id" => "other-guest"}),
      pay("p", "source", 50)
    ])

    rejected(conn, transfer("source", "source", 1), %{"code" => "invalid_transfer"})
    rejected(conn, transfer("source", "stranger", 1), %{"code" => "invalid_transfer"})

    for amount <- [0, -1, 1.5, "1", nil, true, [], %{}] do
      rejected(conn, transfer("source", "destination", amount), %{"code" => "invalid_amount"})
    end

    for field <- ~w(operation_id source_group_id destination_group_id amount_cents occurred_on) do
      rejected(conn, Map.delete(transfer("source", "destination", 1), field), %{
        "code" => "invalid_operation"
      })
    end

    for field <- ~w(source_group_id destination_group_id), value <- ["", 1, nil, %{}] do
      rejected(conn, Map.put(transfer("source", "destination", 1), field, value), %{
        "code" => "invalid_operation"
      })
    end

    rejected(conn, Map.put(transfer("source", "destination", 1), "occurred_on", "bad-date"), %{
      "code" => "invalid_operation"
    })

    rejected(conn, transfer("source", "destination", 51), %{
      "code" => "transfer_exceeds_held_funding"
    })

    too_large = transfer("source", "destination", 11)
    result = rejected(conn, too_large, %{"code" => "transfer_exceeds_outstanding"})
    applied(conn, [opening("later", [100])])
    [_, success, _] = batch(conn, [too_large, transfer("source", "later", 50), too_large])
    assert success["status"] == "applied"
    assert batch(conn, [too_large]) == [result]
    assert group(conn, "source")["deposit_paid_cents"] == 0
    assert group(conn, "destination")["revision"] == 1
  end

  defp opening(id, deposits, attrs \\ %{}) do
    rooms =
      deposits
      |> Enum.with_index(1)
      |> Enum.map(fn {due, i} ->
        %{"room_id" => "r#{i}", "nightly_rate_cents" => due * 5}
      end)

    open_operation(
      Map.merge(%{"group_id" => id, "departure_on" => "2026-12-11", "rooms" => rooms}, attrs)
    )
  end

  defp op(type, group, attrs \\ %{}), do: operation(type, Map.put(attrs, "group_id", group))

  defp pay(id, group, amount),
    do: op("record_cash_payment", group, %{"operation_id" => id, "amount_cents" => amount})

  defp correction(type, payment, attrs \\ %{}),
    do: operation(type, Map.put(attrs, "payment_operation_id", payment)) |> Map.delete("group_id")

  defp transfer(source, destination, amount, attrs \\ %{}),
    do:
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

  defp issue(conn, id, amount, on \\ "2026-10-04") do
    applied(conn, [
      opening(id, [amount]),
      pay(id <> "-pay", id, amount),
      op("cancel_group", id, %{
        "operation_id" => id <> "-cancel",
        "occurred_on" => on,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp batch(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp applied(conn, operations) do
    results = batch(conn, operations)
    assert Enum.all?(results, &(&1["status"] == "applied")), inspect(results)
    results
  end

  defp group(conn, id),
    do: conn |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger(conn, on \\ "2026-10-05"),
    do: conn |> get("/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")

  defp room_balances(conn, id),
    do: Enum.map(group(conn, id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp held_by(groups),
    do: Enum.map(groups, fn {id, amount} -> %{"group_id" => id, "amount_cents" => amount} end)

  defp statement(conn, id) do
    statement = conn |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

    assert Enum.sum(
             for {key, value} <- statement,
                 String.ends_with?(key, "_cents") and key != "recorded_cents",
                 do: value
           ) == statement["recorded_cents"]

    if Map.has_key?(statement, "held_by_group"),
      do:
        assert(
          Enum.sum(Enum.map(statement["held_by_group"], & &1["amount_cents"])) ==
            statement["held_cents"]
        )

    statement
  end

  defp rejected(conn, operation, fields) do
    before = snapshot()
    [result] = batch(conn, [operation])

    assert result ==
             Map.merge(fields, %{
               "operation_id" => operation["operation_id"],
               "status" => "rejected"
             })

    assert snapshot() == before
    result
  end

  defp snapshot do
    for table <- ~w(groups room_allocations credit_lots credit_allocations credit_entitlements),
        do: Repo.query!("SELECT * FROM #{table} ORDER BY 1").rows
  end
end
