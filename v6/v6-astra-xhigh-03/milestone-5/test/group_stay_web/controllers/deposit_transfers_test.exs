defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{CreditEntitlement, CreditLot, Group, Operation, Repo, Room, RoomAllocation}

  test "mixed funding moves in reverse creation order into active rooms in original order" do
    issue_credit(100)

    batch([
      opening("source", [100, 100, 100]),
      opening("destination", [30, 50, 80, 100], %{"property_id" => "another-hotel"}),
      cancel_rooms("destination", ["r-0"]),
      cash("first", "source", 90),
      credit("source", 80),
      cash("last", "source", 70, %{"occurred_on" => "2026-01-01"})
    ])

    before_ledger = ledger()
    before_lots = Repo.all(CreditLot)

    op =
      transfer("source", "destination", 150, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 2
      })

    assert [result] = batch([op])

    assert result == %{
             "operation_id" => op["operation_id"],
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 150,
             "source_outstanding_deposit_cents" => 210,
             "destination_outstanding_deposit_cents" => 80,
             "source_revision" => 5,
             "destination_revision" => 3
           }

    assert funding("source") == [{90, 0}, {0, 0}, {0, 0}]
    assert funding("destination") == [{0, 0}, {50, 0}, {20, 60}, {0, 20}]
    assert ledger() == before_ledger
    assert Repo.all(CreditLot) == before_lots
    refute Map.has_key?(payment("first"), "held_by_group")
    assert payment("last")["held_by_group"] == [held("destination", 70)]

    before = snapshot()
    assert batch([op]) == [result]
    assert read("/api/v1/operations/" <> op["operation_id"]) == result
    assert snapshot() == before

    # Another transfer draws the latest credit fragments ahead of the earlier cash.
    batch([opening("third", [20]), transfer("destination", "third", 20)])
    assert funding("third") == [{0, 20}]
    assert funding("destination") == [{0, 0}, {50, 0}, {20, 60}, {0, 0}]
    assert ledger() == before_ledger
    assert_consistent()
  end

  test "a refill in an earlier room is drawn before older funding in a later room" do
    batch([
      opening("source", [100, 100]),
      opening("destination", [100]),
      cash("first", "source", 100),
      cash("second", "source", 100),
      reduce("first", 100),
      cash("refill", "source", 100),
      transfer("source", "destination", 50)
    ])

    assert funding("source") == [{50, 0}, {100, 0}]
    assert payment("refill")["held_by_group"] == [held("destination", 50), held("source", 50)]
    refute Map.has_key?(payment("second"), "held_by_group")
    refute Map.has_key?(payment("first"), "held_by_group")
    assert_consistent()
  end

  test "partial transfers leave the source fragment's order intact and preserve partner identifiers" do
    source = " Source + café "
    destination = " Destination + 東京 "

    batch([
      opening(source, [100]),
      opening(destination, [100]),
      cash("first", source, 60),
      cash("second", source, 40)
    ])

    op = transfer(source, destination, 30, %{"operation_id" => " Transfer + café "})
    [result] = GroupStay.submit_operations([op])
    assert result.source_group_id == source
    assert result.destination_group_id == destination
    assert result.operation_id == op["operation_id"]
    assert GroupStay.submit_operations([op]) == [result]

    # The ten cents left in the second payment are still newer than the first payment.
    batch([transfer(source, destination, 20)])
    assert payment("first")["held_by_group"] == [held(destination, 10), held(source, 50)]
    assert payment("second")["held_by_group"] == [held(destination, 40)]
    batch([reduce("second", 35)])
    assert payment("second")["held_by_group"] == [held(destination, 5)]
    assert funding(source) == [{50, 0}]
    assert funding(destination) == [{15, 0}]
    assert_consistent()
  end

  test "reductions follow global allocation order and revise each affected group exactly once" do
    pay = cash("pay", "source", 300)

    [_, _, _, original | _] =
      batch([
        opening("source", [100, 100, 100]),
        opening("b", [100, 100]),
        opening("c", [100]),
        pay,
        transfer("source", "b", 120),
        transfer("source", "c", 80),
        transfer("b", "source", 30)
      ])

    assert payment("pay")["held_by_group"] == [held("b", 90), held("c", 80), held("source", 130)]

    assert [%{"revision" => 6, "outstanding_deposit_cents" => 200}] =
             batch([reduce("pay", 50, %{"expected_revision" => 5})])

    assert funding("source") == [{100, 0}, {0, 0}, {0, 0}]
    assert funding("b") == [{90, 0}, {0, 0}]
    assert funding("c") == [{60, 0}]
    assert revisions(~w(source b c)) == [6, 3, 3]

    reduction = reduce("pay", 70, %{"expected_revision" => 6})
    stale = transfer("b", "c", 1, %{"expected_revision" => 3})

    assert [reduced, %{"code" => "stale_revision", "group_id" => "b", "actual_revision" => 4}] =
             batch([reduction, stale])

    assert reduced["revision"] == 7
    assert payment("pay")["held_by_group"] == [held("b", 80), held("source", 100)]
    assert revisions(~w(source b c)) == [7, 4, 4]

    assert [%{"charged_back_cents" => 180, "revision" => 8}] = batch([chargeback("pay")])
    assert revisions(~w(source b c)) == [8, 5, 4]
    assert payment("pay")["held_by_group"] == []
    assert payment("pay")["reduced_cents"] == 120
    before = snapshot()
    assert batch([pay, reduction]) == [original, reduced]
    assert snapshot() == before
    assert_consistent()
  end

  test "a cancelled original group is still addressed when all held cash is elsewhere" do
    batch([
      opening("source", [100]),
      opening("destination", [100]),
      cash("pay", "source", 100),
      transfer("source", "destination", 100),
      cancel("source")
    ])

    assert [%{"revision" => 5, "outstanding_deposit_cents" => 0}] =
             batch([reduce("pay", 20, %{"expected_revision" => 4})])

    assert revisions(~w(source destination)) == [5, 3]

    assert [%{"revision" => 6, "charged_back_cents" => 80, "outstanding_deposit_cents" => 0}] =
             batch([chargeback("pay", %{"expected_revision" => 5})])

    assert revisions(~w(source destination)) == [6, 4]
    assert funding("destination") == [{0, 0}]
    assert_consistent()
  end

  test "chargeback reclassifies destination settlements and leaves credit-funded groups unchanged" do
    pay = cash("pay", "source", 500)

    operations = [
      opening("source", [500]),
      opening("refunded", [100]),
      opening("retained", [100], %{"rate_plan" => "advance_purchase"}),
      opening("converted", [100]),
      opening("active", [100]),
      opening("credit-target", [80]),
      pay,
      transfer("source", "refunded", 100),
      transfer("source", "retained", 100),
      transfer("source", "converted", 100),
      transfer("source", "active", 100),
      cancel("refunded"),
      cancel("retained"),
      cancel("converted", %{"refund_method" => "hotel_credit"}),
      credit("credit-target", 80),
      reduce("pay", 50)
    ]

    results = batch(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert Map.take(
             payment("pay"),
             ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents)
           ) ==
             %{
               "held_cents" => 150,
               "refunded_cents" => 100,
               "retained_cents" => 100,
               "converted_to_credit_cents" => 100,
               "reduced_cents" => 50
             }

    assert payment("pay")["held_by_group"] == [held("active", 50), held("source", 100)]
    before_credit_target = group("credit-target")
    ids = ~w(source refunded retained converted active)
    before_revisions = revisions(ids)

    charge = chargeback("pay", %{"expected_revision" => group("source")["revision"]})
    assert [%{"charged_back_cents" => 450}] = batch([charge])
    assert revisions(ids) == Enum.map(before_revisions, &(&1 + 1))
    assert group("credit-target") == before_credit_target
    assert payment("pay")["held_by_group"] == []
    assert payment("pay")["charged_back_cents"] == 450

    assert ledger() == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 0,
             "cash_reduced_cents" => 50,
             "cash_charged_back_cents" => 450,
             "credit_liability_cents" => 80,
             "credit_shortfall_cents" => 80
           }

    assert batch([pay]) == [Enum.at(results, 6)]
    assert_consistent()
  end

  test "destination funding order determines telescoping bonus entitlements after transfer" do
    batch([
      opening("source", [10]),
      opening("destination", [5, 5]),
      cash("first", "source", 5),
      cash("second", "source", 5),
      transfer("source", "destination", 10),
      cancel("destination", %{"refund_method" => "hotel_credit"})
    ])

    assert available() == 11
    assert payment("first")["converted_to_credit_cents"] == 5
    assert payment("second")["converted_to_credit_cents"] == 5
    batch([chargeback("first")])
    assert available() == 6
    batch([chargeback("second")])
    assert available() == 0
    assert_consistent()
  end

  for {date, restored} <- [{"2027-11-26", 70}, {"2027-11-27", 0}] do
    test "transferred credit restores original expiry without a bonus on #{date}" do
      issue_credit(100)

      batch([
        future_opening("source", [110]),
        future_opening("destination", [70]),
        credit("source", 110)
      ])

      before = ledger(unquote(date))
      batch([transfer("source", "destination", 70, %{"occurred_on" => unquote(date)})])
      assert ledger(unquote(date)) == before
      assert funding("source") == [{0, 40}]
      assert funding("destination") == [{0, 70}]

      assert [%{"credit_issued_cents" => 0}] =
               batch([
                 cancel("destination", %{
                   "occurred_on" => unquote(date),
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert available(unquote(date)) == unquote(restored)
      assert ledger(unquote(date))["credit_liability_cents"] == 40 + unquote(restored)
      assert length(Repo.all(CreditLot)) == 1
      assert_consistent()
    end
  end

  for {date, restored} <- [{"2027-11-26", 30}, {"2027-11-27", 0}] do
    test "transferred credit absorbs shortfall before expiry on #{date}" do
      batch([
        opening("issuer", [100]),
        cash("first", "issuer", 50),
        cash("second", "issuer", 50),
        cancel("issuer", %{"refund_method" => "hotel_credit"}),
        future_opening("source", [105]),
        future_opening("destination", [80]),
        credit("source", 105),
        chargeback("first")
      ])

      assert ledger()["credit_shortfall_cents"] == 50
      batch([transfer("source", "destination", 80, %{"occurred_on" => unquote(date)})])
      assert ledger(unquote(date))["credit_shortfall_cents"] == 50
      batch([cancel("destination", %{"occurred_on" => unquote(date)})])
      assert available(unquote(date)) == unquote(restored)
      assert ledger(unquote(date))["credit_shortfall_cents"] == 0
      assert ledger(unquote(date))["credit_liability_cents"] == 25 + unquote(restored)
      assert Repo.one(CreditLot).unrecovered_clawback_cents == 0
      assert_consistent()
    end
  end

  test "nonrefundable destination consumption reduces transferred credit shortfall" do
    issue_credit(100)

    batch([
      opening("source", [110]),
      opening("destination", [80], %{"rate_plan" => "advance_purchase"}),
      credit("source", 110),
      chargeback("issuer-pay"),
      transfer("source", "destination", 80)
    ])

    assert ledger()["credit_shortfall_cents"] == 110
    batch([cancel("destination")])
    assert ledger()["credit_shortfall_cents"] == 30
    assert ledger()["credit_liability_cents"] == 30
    assert available() == 0
    assert_consistent()
  end

  test "existence then both revision guards take precedence over transfer domain rules" do
    batch([
      opening("source", [100]),
      opening("destination", [100]),
      cash("pay", "source", 50)
    ])

    assert_rejected(transfer("missing-source", "missing-destination", 1), "group_not_found", %{
      "group_id" => "missing-source"
    })

    assert_rejected(
      transfer("source", "missing", 0, %{"expected_revision" => 0}),
      "group_not_found",
      %{"group_id" => "missing"}
    )

    assert_rejected(
      transfer("source", "destination", 0, %{
        "expected_revision" => 0,
        "destination_expected_revision" => 0
      }),
      "stale_revision",
      %{"group_id" => "source", "expected_revision" => 0, "actual_revision" => 2}
    )

    for expected <- [0, 1.0, nil, "1"] do
      assert_rejected(
        transfer("source", "destination", 0, %{
          "expected_revision" => 2,
          "destination_expected_revision" => expected
        }),
        "stale_revision",
        %{"group_id" => "destination", "expected_revision" => expected, "actual_revision" => 1}
      )
    end

    assert_rejected(
      transfer("source", "source", 1, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      "stale_revision",
      %{"group_id" => "source", "expected_revision" => 1, "actual_revision" => 2}
    )

    batch([cancel("destination")])

    assert_rejected(
      transfer("source", "destination", 1, %{"destination_expected_revision" => 1}),
      "stale_revision",
      %{"group_id" => "destination"}
    )

    assert_rejected(transfer("source", "destination", 1), "group_not_active", %{
      "group_id" => "destination"
    })

    batch([cancel("source")])

    assert_rejected(transfer("source", "destination", 1), "group_not_active", %{
      "group_id" => "source"
    })
  end

  test "transfer validation is atomic and rejected attempts do not mark payments as transferred" do
    batch([
      opening("source", [100]),
      opening("destination", [30]),
      opening("different-guest", [100], %{"guest_id" => "someone-else"}),
      cash("pay", "source", 50)
    ])

    assert_rejected(transfer("source", "source", 1), "invalid_transfer")
    assert_rejected(transfer("source", "different-guest", 1), "invalid_transfer")

    for amount <- [0, -1, nil, 1.0, true, "1", [], %{}] do
      assert_rejected(transfer("source", "destination", amount), "invalid_amount")
    end

    assert_rejected(transfer("source", "destination", 51), "transfer_exceeds_held_funding")
    assert_rejected(transfer("source", "destination", 31), "transfer_exceeds_outstanding")

    for field <- ~w(source_group_id destination_group_id occurred_on amount_cents) do
      assert_rejected(
        Map.delete(transfer("source", "destination", 10), field),
        "invalid_operation"
      )
    end

    for field <- ~w(source_group_id destination_group_id), value <- [nil, "", 1, [], %{}] do
      assert_rejected(
        Map.put(transfer("source", "destination", 10), field, value),
        "invalid_operation"
      )
    end

    assert_rejected(
      transfer("source", "destination", 10, %{"occurred_on" => "bad-date"}),
      "invalid_operation"
    )

    refute Map.has_key?(payment("pay"), "held_by_group")
    batch([transfer("source", "destination", 30)])
    assert_rejected(transfer("source", "destination", 1), "transfer_exceeds_outstanding")
    assert_consistent()
  end

  test "rejections and successes replay after later changes with same-batch visibility" do
    batch([opening("source", [100]), opening("destination", [100])])
    rejected = transfer("source", "destination", 50)

    applied =
      transfer("source", "destination", 50, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    next =
      transfer("destination", "source", 20, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 3
      })

    assert [rejection, _, success, reverse] =
             batch([rejected, cash("pay", "source", 70), applied, next])

    assert rejection["code"] == "transfer_exceeds_held_funding"
    assert success["status"] == "applied"
    assert reverse["status"] == "applied"
    before = snapshot()
    assert batch([rejected, applied, next]) == [rejection, success, reverse]
    assert snapshot() == before
    assert_rejected(Map.put(applied, "amount_cents", 51), "operation_id_conflict")
    assert_rejected(Map.put(applied, "destination_expected_revision", 3), "operation_id_conflict")
    stored = Repo.get_by!(Operation, operation_id: applied["operation_id"])
    assert stored.type == "transfer_deposit"
    assert stored.payload == applied
    Repo.query!("ALTER TABLE room_allocations RENAME TO unavailable_allocations")
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")
    assert batch([rejected, applied, next]) == [rejection, success, reverse]
  end

  test "audit failure rolls back transfers and cross-group corrections and aborts the batch" do
    batch([
      opening("source", [100]),
      opening("destination", [100]),
      cash("pay", "source", 100)
    ])

    for op <- [transfer("source", "destination", 60), reduce("pay", 10), chargeback("pay")] do
      Repo.query!("CREATE TABLE failing_type (type TEXT)")
      Repo.query!("INSERT INTO failing_type VALUES (?)", [op["type"]])

      Repo.query!("""
      CREATE TRIGGER fail_change BEFORE INSERT ON operations
      WHEN NEW.type IN (SELECT type FROM failing_type)
      BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
      """)

      before = snapshot()
      assert_error_sent 500, fn -> batch([op, cancel("destination")]) end
      assert snapshot() == before
      Repo.query!("DROP TRIGGER fail_change")
      Repo.query!("DROP TABLE failing_type")
      assert [%{"status" => "applied"}] = batch([op])
      assert_consistent()
    end
  end

  defp opening(id, deposits, overrides \\ %{}) do
    rate_plan = Map.get(overrides, "rate_plan", "flexible")

    open_operation(
      Map.merge(
        %{
          "group_id" => id,
          "departure_on" => "2026-12-11",
          "rooms" =>
            Enum.with_index(deposits, fn due, index ->
              %{
                "room_id" => "r-#{index}",
                "nightly_rate_cents" => if(rate_plan == "flexible", do: due * 5, else: due)
              }
            end)
        },
        overrides
      )
    )
  end

  defp future_opening(id, deposits),
    do: opening(id, deposits, %{"arrival_on" => "2029-12-10", "departure_on" => "2029-12-11"})

  defp cash(id, group_id, amount, overrides \\ %{}),
    do:
      operation(
        "record_cash_payment",
        Map.merge(
          %{"operation_id" => id, "group_id" => group_id, "amount_cents" => amount},
          overrides
        )
      )

  defp credit(group_id, amount),
    do: operation("apply_hotel_credit", %{"group_id" => group_id, "amount_cents" => amount})

  defp cancel(group_id, overrides \\ %{}),
    do: operation("cancel_group", Map.merge(%{"group_id" => group_id}, overrides))

  defp cancel_rooms(group_id, ids),
    do: operation("cancel_rooms", %{"group_id" => group_id, "room_ids" => ids})

  defp reduce(id, amount, overrides \\ %{}),
    do:
      operation(
        "reduce_cash_payment",
        Map.merge(%{"payment_operation_id" => id, "amount_cents" => amount}, overrides)
      )
      |> Map.delete("group_id")

  defp chargeback(id, overrides \\ %{}),
    do:
      operation("charge_back_payment", Map.merge(%{"payment_operation_id" => id}, overrides))
      |> Map.delete("group_id")

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

  defp issue_credit(amount),
    do:
      batch([
        opening("issuer", [amount]),
        cash("issuer-pay", "issuer", amount),
        cancel("issuer", %{"refund_method" => "hotel_credit"})
      ])

  defp batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp read(path), do: build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
  defp group(id), do: read("/api/v1/groups/" <> URI.encode(id, &URI.char_unreserved?/1))
  defp payment(id), do: read("/api/v1/payments/" <> URI.encode(id, &URI.char_unreserved?/1))
  defp ledger(date \\ "2026-11-26"), do: read("/api/v1/ledger?on=" <> date)

  defp available(date \\ "2026-11-26"),
    do: read("/api/v1/guests/guest-22/credit?on=" <> date)["available_cents"]

  defp funding(id),
    do: Enum.map(group(id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp revisions(ids), do: Enum.map(ids, &group(&1)["revision"])
  defp held(id, amount), do: %{"group_id" => id, "amount_cents" => amount}

  defp assert_rejected(op, code, details \\ %{}) do
    before = snapshot(false)
    assert [%{"status" => "rejected", "code" => ^code} = result] = batch([op])
    assert Map.take(result, Map.keys(details)) == details
    assert snapshot(false) == before
  end

  defp snapshot(journal \\ true) do
    schemas =
      [Group, Room, RoomAllocation, CreditLot, CreditEntitlement] ++
        if(journal, do: [Operation], else: [])

    Enum.map(schemas, fn schema -> Repo.all(schema) |> Enum.sort() end)
  end

  defp assert_consistent do
    groups = Enum.map(Repo.all(Group), &group(&1.group_id))

    for group <- groups do
      active = Enum.filter(group["rooms"], &(&1["status"] == "active"))

      for field <- ~w(lodging_total_cents deposit_due_cents cash_paid_cents credit_paid_cents) do
        assert group[field] == Enum.sum(Enum.map(active, & &1[field]))
      end

      assert group["deposit_paid_cents"] == group["cash_paid_cents"] + group["credit_paid_cents"]

      assert group["outstanding_deposit_cents"] ==
               group["deposit_due_cents"] - group["deposit_paid_cents"]

      assert group["outstanding_deposit_cents"] >= 0
    end

    statements =
      for op <- Repo.all(Operation),
          op.type == "record_cash_payment",
          op.result["status"] == "applied",
          do: payment(op.operation_id)

    dispositions =
      ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)

    for statement <- statements do
      assert statement["recorded_cents"] == Enum.sum(Enum.map(dispositions, &statement[&1]))
      assert Enum.all?(dispositions, &(statement[&1] >= 0))

      if Map.has_key?(statement, "held_by_group") do
        assert statement["held_cents"] ==
                 Enum.sum(Enum.map(statement["held_by_group"], & &1["amount_cents"]))
      end
    end

    totals = ledger()

    for field <- dispositions do
      assert totals["cash_" <> field] == Enum.sum(Enum.map(statements, & &1[field]))
    end

    assert totals["cash_held_cents"] == Enum.sum(Enum.map(groups, & &1["cash_paid_cents"]))
  end
end
