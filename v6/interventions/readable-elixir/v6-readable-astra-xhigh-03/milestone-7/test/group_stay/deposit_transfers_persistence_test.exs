defmodule GroupStay.DepositTransfersPersistenceTest do
  use GroupStay.PersistenceCase

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}

  alias GroupStay.Reservations.{
    CashAllocation,
    CashEntry,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    OperationRecord,
    RoomCreditAllocation
  }

  test "upgrade reconstructs mixed funding order and preserves balances, history, and revisions" do
    seed_credit()

    submit([
      booking("group-81"),
      booking("destination"),
      payment(%{
        "operation_id" => "z-first",
        "amount_cents" => 60,
        "occurred_on" => "2026-11-03"
      }),
      credit_application(%{"amount_cents" => 110}),
      payment(%{
        "operation_id" => "a-last",
        "amount_cents" => 130,
        "occurred_on" => "2026-10-01"
      }),
      reduction(%{"payment_operation_id" => "a-last", "amount_cents" => 50})
    ])

    before = snapshot()
    balances = Reservations.ledger(~D[2026-11-03])

    downgrade_transfers()

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [
             20_260_907_000_004,
             20_260_907_000_005,
             20_260_907_000_006
           ]

    assert without_order(snapshot()) == without_order(before)
    assert Reservations.ledger(~D[2026-11-03]) == balances
    assert {:ok, statement} = Reservations.payment_statement("a-last")
    refute Map.has_key?(statement, :held_by_group)

    assert [%{"source_revision" => 6, "destination_revision" => 2}] =
             submit([transfer(%{"amount_cents" => 100})])

    assert room_balances("destination") == [{80, 20}, {0, 0}, {0, 0}]
    assert room_balances("group-81") == [{60, 40}, {0, 50}, {0, 0}]
    assert Reservations.ledger(~D[2026-11-03]) == balances
  end

  test "upgrade transfers unattributed senior cash and credit after durable funding is drawn" do
    seed_credit()

    submit([
      booking("group-81"),
      booking("destination"),
      credit_application(%{"operation_id" => "old-credit", "amount_cents" => 70}),
      payment(%{"operation_id" => "old-cash", "amount_cents" => 60}),
      payment(%{
        "operation_id" => "recorded",
        "amount_cents" => 70,
        "occurred_on" => "2026-10-01"
      })
    ])

    Repo.delete_all(
      from r in OperationRecord, where: r.operation_id in ["old-credit", "old-cash"]
    )

    # Recreate the room-accounting release's real senior block from the older
    # aggregate funding, then migrate that deployed layout to transfers.
    Ecto.Migrator.run(Repo, :down, to: 20_260_907_000_003, log: false)
    Ecto.Migrator.run(Repo, :up, to: 20_260_907_000_003, log: false)

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [
             20_260_907_000_004,
             20_260_907_000_005,
             20_260_907_000_006
           ]

    balances = Reservations.ledger(~D[2026-11-01])
    submit([transfer(%{"amount_cents" => 160})])
    assert room_balances("group-81") == [{40, 0}, {0, 0}, {0, 0}]
    assert room_balances("destination") == [{70, 30}, {20, 40}, {0, 0}]
    assert Reservations.ledger(~D[2026-11-01]) == balances
    assert {:error, :operation_not_found} = Reservations.payment_statement("old-cash")

    assert [%{"code" => "operation_not_found"}] =
             submit([reduction(%{"payment_operation_id" => "old-cash"})])

    assert [%{"refunded_cents" => 90}] = submit([cancellation(%{"group_id" => "destination"})])
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 110
  end

  test "concurrent retries move funding and advance both groups only once", %{repo: repo} do
    submit([
      booking("group-81"),
      booking("destination"),
      payment(%{"operation_id" => "payment", "amount_cents" => 100})
    ])

    operation =
      transfer(%{
        "amount_cents" => 100,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    [first | retries] = race(repo, fn _ -> submit([operation]) end)
    assert Enum.all?(retries, &(&1 === first))
    assert [%{"source_revision" => 3, "destination_revision" => 2}] = first
    assert Repo.aggregate(OperationRecord, :count) == 4

    assert {:ok,
            %{held_cents: 100, held_by_group: [%{group_id: "destination", amount_cents: 100}]}} =
             Reservations.payment_statement("payment")
  end

  test "competing transfers cannot overspend a source or overfill a destination", %{repo: repo} do
    submit([booking("group-81"), booking("destination"), payment(%{"amount_cents" => 100})])

    results =
      race(repo, fn _ -> submit([transfer(%{"amount_cents" => 60})]) end) |> List.flatten()

    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "transfer_exceeds_held_funding")) == 3

    submit([
      booking("full", %{"rooms" => rooms(["only"])}),
      payment(%{"group_id" => "full", "amount_cents" => 50})
    ])

    for i <- 1..4 do
      submit([
        booking("source-#{i}"),
        payment(%{"group_id" => "source-#{i}", "amount_cents" => 100})
      ])
    end

    results =
      race(repo, fn i ->
        submit([
          transfer(%{
            "source_group_id" => "source-#{i}",
            "destination_group_id" => "full",
            "amount_cents" => 40
          })
        ])
      end)
      |> List.flatten()

    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "transfer_exceeds_outstanding")) == 3
    assert Reservations.get_group("full").deposit_paid_cents == 90
  end

  test "a failed transfer or cross-group correction rolls back allocations, revisions, and audit" do
    seed_credit()

    submit([
      booking("group-81"),
      booking("destination"),
      payment(%{"operation_id" => "payment", "amount_cents" => 100}),
      credit_application(%{"amount_cents" => 100})
    ])

    for operation <- [transfer(%{"amount_cents" => 150}), reduction(), chargeback()] do
      operation = Map.put(operation, "operation_id", "fault")
      before = snapshot()

      Repo.query!("""
      CREATE TRIGGER reject_transfer_audit BEFORE INSERT ON operation_records
      WHEN NEW.operation_id = 'fault'
      BEGIN SELECT RAISE(ABORT, 'forced transfer audit failure'); END
      """)

      assert_raise Exqlite.Error, fn -> submit([operation]) end
      assert snapshot() == before
      assert Reservations.get_operation_result("fault") == nil
      Repo.query!("DROP TRIGGER reject_transfer_audit")

      if operation["type"] == "transfer_deposit" do
        assert [%{"status" => "applied"}] = submit([Map.put(operation, "operation_id", "move")])
      end
    end
  end

  test "transfers, exact retries, provenance, and new allocation order survive a repository restart",
       %{options: options} do
    seed_credit()

    operations = [
      booking("group-81"),
      booking("destination"),
      payment(%{"operation_id" => "payment", "amount_cents" => 150}),
      credit_application(%{"amount_cents" => 100}),
      transfer(%{"amount_cents" => 180})
    ]

    results = submit(operations)
    before = snapshot()
    balances = Reservations.ledger(~D[2026-11-01])
    statement = Reservations.payment_statement("payment")
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)

    assert submit(operations) === results
    assert snapshot() == before
    assert Reservations.ledger(~D[2026-11-01]) == balances
    assert Reservations.payment_statement("payment") == statement

    submit([
      payment(%{"group_id" => "destination", "operation_id" => "new", "amount_cents" => 20}),
      transfer(%{
        "source_group_id" => "destination",
        "destination_group_id" => "group-81",
        "amount_cents" => 30
      })
    ])

    assert {:ok, %{held_by_group: [%{group_id: "group-81", amount_cents: 20}]}} =
             Reservations.payment_statement("new")

    submit([reduction(%{"amount_cents" => 20})])
    assert Reservations.get_group("group-81").revision == 6
    assert Reservations.get_group("destination").revision == 5
  end

  test "migration refuses a downgrade after a transfer even if the funding returns" do
    submit([
      booking("group-81"),
      booking("destination"),
      payment(%{"amount_cents" => 100}),
      transfer(),
      transfer(%{"source_group_id" => "destination", "destination_group_id" => "group-81"})
    ])

    before = snapshot()

    assert_raise Ecto.MigrationError, ~r/cannot remove deposit transfers/, fn ->
      migration = [{20_260_907_000_004, GroupStay.Repo.Migrations.AddDepositTransfers}]
      Ecto.Migrator.run(Repo, migration, :down, step: 1, log: false)
    end

    assert snapshot() == before
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  defp downgrade_transfers, do: Ecto.Migrator.run(Repo, :down, to: 20_260_907_000_004, log: false)

  defp booking(id, overrides \\ %{}),
    do:
      open_group(
        Map.merge(
          %{"group_id" => id, "departure_on" => "2026-12-11", "rooms" => rooms(~w(z a m))},
          overrides
        )
      )

  defp rooms(ids), do: Enum.map(ids, &%{"room_id" => &1, "nightly_rate_cents" => 500})
  defp submit(operations), do: Reservations.submit_batch(operations)

  defp room_balances(id),
    do: Enum.map(Reservations.get_group(id).rooms, &{&1.cash_paid_cents, &1.credit_paid_cents})

  defp seed_credit do
    submit([
      booking("seed"),
      payment(%{"group_id" => "seed", "amount_cents" => 100}),
      cancellation(%{"group_id" => "seed", "refund_method" => "hotel_credit"})
    ])
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
          CreditEntitlement,
          OperationRecord
        ],
        &Repo.all/1
      )

  defp without_order(snapshot),
    do: Enum.map(snapshot, fn rows -> Enum.map(rows, &Map.delete(&1, :allocation_order)) end)
end
