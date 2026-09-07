defmodule GroupStay.RoomAccountingPersistenceTest do
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

  test "upgrade allocates senior cash then senior lots before durable funding in commit order" do
    submit([
      booking("donor-one"),
      payment(%{"group_id" => "donor-one", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "donor-one",
        "operation_id" => "lot-one",
        "refund_method" => "hotel_credit"
      }),
      booking("donor-two"),
      payment(%{"group_id" => "donor-two", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "donor-two",
        "operation_id" => "lot-two",
        "refund_method" => "hotel_credit"
      }),
      booking("group-81"),
      credit_application(%{"operation_id" => "old-credit", "amount_cents" => 70}),
      payment(%{"operation_id" => "old-cash", "amount_cents" => 60}),
      credit_application(%{
        "operation_id" => "z-recorded-credit",
        "amount_cents" => 70,
        "occurred_on" => "2026-11-03"
      }),
      payment(%{
        "operation_id" => "a-recorded-cash",
        "amount_cents" => 200,
        "occurred_on" => "2026-10-01"
      }),
      credit_application(%{
        "operation_id" => "recorded-credit-last",
        "amount_cents" => 50,
        "occurred_on" => "2026-11-02"
      })
    ])

    # These two funding facts precede the durable journal. Their timestamps and
    # references still exist, but neither is a targetable payment identifier.
    Repo.delete_all(
      from record in OperationRecord, where: record.operation_id in ["old-credit", "old-cash"]
    )

    balances = Reservations.ledger(~D[2026-11-03])
    journal = Repo.all(OperationRecord)
    cash_history = Repo.all(CashEntry)
    credit_history = Repo.all(CreditAllocation)
    before = Reservations.get_group("group-81")

    downgrade_room_accounting()
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [20_260_907_000_003]
    group = Reservations.get_group("group-81")
    assert group.revision == before.revision
    assert group.updated_at == before.updated_at
    assert group.deposit_paid_cents == 450
    assert group.credit_paid_cents == 190

    assert Enum.map(group.rooms, &{&1.room_id, &1.cash_paid_cents, &1.credit_paid_cents}) == [
             {"z", 60, 40},
             {"a", 0, 100},
             {"m", 100, 0},
             {"n", 100, 0},
             {"last", 0, 50}
           ]

    assert Reservations.ledger(~D[2026-11-03]) == balances
    assert Repo.all(OperationRecord) == journal
    assert Repo.all(CashEntry) == cash_history
    assert Repo.all(CreditAllocation) == credit_history
    assert {:error, :operation_not_found} = Reservations.payment_statement("old-cash")

    assert [%{"code" => "operation_not_found"}] =
             submit([reduction(%{"payment_operation_id" => "old-cash"})])

    assert {:ok, %{held_cents: 200, recorded_cents: 200}} =
             Reservations.payment_statement("a-recorded-cash")

    assert [%{"amount_cents" => 150}] =
             submit([
               reduction(%{"payment_operation_id" => "a-recorded-cash", "amount_cents" => 150})
             ])

    assert Enum.map(Reservations.get_group("group-81").rooms, & &1.cash_paid_cents) == [
             60,
             0,
             50,
             0,
             0
           ]

    assert [%{"refunded_cents" => 60}] = submit([room_cancellation(%{"room_ids" => ["z"]})])
    assert Reservations.guest_credit("guest-22", ~D[2026-11-03]).available_cents == 70
    assert Reservations.ledger(~D[2026-11-03]).credit_liability_cents == 220
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  test "upgrade retains original credit lot consumption order within the senior block" do
    submit([
      booking("source-one"),
      payment(%{"group_id" => "source-one", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "source-one",
        "operation_id" => "z-lot",
        "refund_method" => "hotel_credit"
      }),
      booking("group-81"),
      credit_application(%{
        "operation_id" => "old-first",
        "amount_cents" => 80,
        "occurred_on" => "2026-11-03"
      }),
      booking("source-two"),
      payment(%{"group_id" => "source-two", "amount_cents" => 100}),
      cancellation(%{
        "group_id" => "source-two",
        "operation_id" => "a-lot",
        "refund_method" => "hotel_credit"
      }),
      credit_application(%{
        "operation_id" => "old-second",
        "amount_cents" => 80,
        "occurred_on" => "2026-11-01"
      }),
      payment(%{"operation_id" => "old-cash", "amount_cents" => 40})
    ])

    Repo.delete_all(
      from record in OperationRecord,
        where: record.operation_id in ["old-first", "old-second", "old-cash"]
    )

    downgrade_room_accounting()
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    assert [%{"refunded_cents" => 40}] = submit([room_cancellation(%{"room_ids" => ["z"]})])
    # Senior cash occupies the first 40 cents, then the first redeemed lot gets
    # the next 60, regardless of lot name, current expiry ordering, or date.
    lots = Reservations.guest_credit("guest-22", ~D[2026-11-03]).lots
    assert Enum.find(lots, &(&1.source_operation_id == "z-lot")).remaining_cents == 90
    assert Enum.find(lots, &(&1.source_operation_id == "a-lot")).remaining_cents == 30
  end

  test "upgrade reconciles already settled payments and partitions legacy conversion bonuses" do
    submit([
      booking("group-81"),
      payment(%{"operation_id" => "senior", "amount_cents" => 5}),
      payment(%{"operation_id" => "payment", "amount_cents" => 5}),
      cancellation(%{"operation_id" => "lot", "refund_method" => "hotel_credit"}),
      booking("target"),
      credit_application(%{"group_id" => "target", "amount_cents" => 10}),
      booking("refunded"),
      payment(%{
        "group_id" => "refunded",
        "operation_id" => "refunded-payment",
        "amount_cents" => 10
      }),
      cancellation(%{"group_id" => "refunded"}),
      booking("retained"),
      payment(%{
        "group_id" => "retained",
        "operation_id" => "retained-payment",
        "amount_cents" => 10
      }),
      cancellation(%{"group_id" => "retained", "occurred_on" => "2026-12-01"})
    ])

    Repo.delete_all(from record in OperationRecord, where: record.operation_id == "senior")
    balances = Reservations.ledger(~D[2026-11-01])
    downgrade_room_accounting()
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    assert Reservations.ledger(~D[2026-11-01]) == balances

    assert {:ok, %{converted_to_credit_cents: 5, held_cents: 0}} =
             Reservations.payment_statement("payment")

    assert {:ok, %{refunded_cents: 10, held_cents: 0}} =
             Reservations.payment_statement("refunded-payment")

    assert {:ok, %{retained_cents: 10, held_cents: 0}} =
             Reservations.payment_statement("retained-payment")

    assert Enum.map(Reservations.get_group("group-81").rooms, & &1.status) ==
             List.duplicate(:cancelled, 5)

    target = Reservations.get_group("target")
    assert [%{"charged_back_cents" => 5}] = submit([chargeback()])
    assert Reservations.get_group("target") == target
    # The senior five cents own six credits; the recorded five own five.
    assert Reservations.ledger(~D[2026-11-01]).credit_shortfall_cents == 4
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 10
    submit([cancellation(%{"group_id" => "target"})])
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 6
    assert Reservations.ledger(~D[2026-11-01]).credit_shortfall_cents == 0
  end

  test "concurrent exact reduction and chargeback retries have one effect", %{repo: repo} do
    submit([booking("group-81"), payment(%{"operation_id" => "payment", "amount_cents" => 180})])
    reduction = reduction(%{"expected_revision" => 2})
    [first | retries] = race(repo, fn _ -> submit([reduction]) end)
    assert Enum.all?(retries, &(&1 === first))
    assert [%{"revision" => 3}] = first

    assert {:ok, %{held_cents: 130, reduced_cents: 50}} =
             Reservations.payment_statement("payment")

    chargeback = chargeback(%{"expected_revision" => 3})
    [first | retries] = race(repo, fn _ -> submit([chargeback]) end)
    assert Enum.all?(retries, &(&1 === first))
    assert [%{"revision" => 4, "charged_back_cents" => 130}] = first
    assert Reservations.ledger().cash_held_cents == 0
    assert Reservations.ledger().cash_charged_back_cents == 130
    assert Repo.aggregate(OperationRecord, :count) == 4
  end

  test "concurrent distinct reductions cannot remove more than held cash", %{repo: repo} do
    submit([booking("group-81"), payment(%{"operation_id" => "payment", "amount_cents" => 100})])

    results =
      race(repo, fn _ -> submit([reduction(%{"amount_cents" => 60})]) end) |> List.flatten()

    assert Enum.count(results, &(&1["status"] == "applied")) == 1
    assert Enum.count(results, &(&1["code"] == "reduction_exceeds_held_cash")) == 3
    assert {:ok, %{held_cents: 40, reduced_cents: 60}} = Reservations.payment_statement("payment")
  end

  test "overlapping room cancellations commit once and preserve original result on retries", %{
    repo: repo
  } do
    submit([booking("group-81"), payment(%{"operation_id" => "payment", "amount_cents" => 200})])
    operation = room_cancellation(%{"room_ids" => ["a", "z"], "refund_method" => "hotel_credit"})
    [first | retries] = race(repo, fn _ -> submit([operation]) end)
    assert Enum.all?(retries, &(&1 === first))
    assert [%{"credit_issued_cents" => 220, "revision" => 3}] = first
    assert Repo.aggregate(CreditLot, :count) == 1
    assert {:ok, %{converted_to_credit_cents: 200}} = Reservations.payment_statement("payment")
  end

  test "audit failure rolls back reductions, partial settlement, and credit clawback in full" do
    submit([booking("group-81"), payment(%{"operation_id" => "payment", "amount_cents" => 300})])

    operations = [
      reduction(%{"operation_id" => "fault"}),
      room_cancellation(%{
        "operation_id" => "fault",
        "room_ids" => ["z"],
        "refund_method" => "hotel_credit"
      }),
      chargeback(%{"operation_id" => "fault"})
    ]

    for operation <- operations do
      before = snapshot()
      fail_audit()
      assert_raise Exqlite.Error, fn -> submit([operation]) end
      assert snapshot() == before
      assert Reservations.get_operation_result("fault") == nil
      Repo.query!("DROP TRIGGER fail_accounting_audit")
    end

    submit([
      room_cancellation(%{"room_ids" => ["z"], "refund_method" => "hotel_credit"}),
      booking("target"),
      credit_application(%{"group_id" => "target", "amount_cents" => 100})
    ])

    before = snapshot()
    fail_audit()
    assert_raise Exqlite.Error, fn -> submit([chargeback(%{"operation_id" => "fault"})]) end
    assert snapshot() == before
    Repo.query!("DROP TRIGGER fail_accounting_audit")
    assert [%{"charged_back_cents" => 300}] = submit([chargeback(%{"operation_id" => "fault"})])
    assert Reservations.ledger(~D[2026-11-01]).credit_shortfall_cents == 100
  end

  test "room balances, statements, exact retries, and shortfall survive database restarts", %{
    options: options
  } do
    original = payment(%{"operation_id" => "payment", "amount_cents" => 300})

    operations = [
      booking("group-81"),
      original,
      reduction(),
      room_cancellation(%{"room_ids" => ["z"], "refund_method" => "hotel_credit"}),
      booking("target"),
      credit_application(%{"group_id" => "target", "amount_cents" => 100}),
      chargeback()
    ]

    results = submit(operations)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    before = snapshot()
    statement = Reservations.payment_statement("payment")
    balances = Reservations.ledger(~D[2026-11-01])
    assert balances.credit_shortfall_cents == 100
    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert snapshot() == before
    assert submit(operations) === results
    assert Reservations.payment_statement("payment") == statement
    assert Reservations.ledger(~D[2026-11-01]) == balances
    submit([cancellation(%{"group_id" => "target"})])
    assert Reservations.ledger(~D[2026-11-01]).credit_shortfall_cents == 0
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 0
  end

  test "rollback refuses to discard accounting facts the previous release cannot represent" do
    submit([
      booking("group-81"),
      payment(%{"operation_id" => "payment", "amount_cents" => 100}),
      reduction()
    ])

    before = snapshot()
    migration = [{20_260_907_000_003, GroupStay.Repo.Migrations.AddRoomAccounting}]

    assert_raise Ecto.MigrationError, ~r/cannot remove room accounting/, fn ->
      Ecto.Migrator.run(Repo, migration, :down, step: 1, log: false)
    end

    assert snapshot() == before
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  defp downgrade_room_accounting do
    migration = [{20_260_907_000_003, GroupStay.Repo.Migrations.AddRoomAccounting}]
    assert Ecto.Migrator.run(Repo, migration, :down, step: 1, log: false) == [20_260_907_000_003]
  end

  defp fail_audit do
    Repo.query!("""
    CREATE TRIGGER fail_accounting_audit BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fault'
    BEGIN SELECT RAISE(ABORT, 'forced accounting audit failure'); END
    """)
  end

  defp booking(id) do
    open_group(%{
      "group_id" => id,
      "departure_on" => "2026-12-11",
      "rooms" => Enum.map(~w(z a m n last), &%{"room_id" => &1, "nightly_rate_cents" => 500})
    })
  end

  defp submit(operations), do: Reservations.submit_batch(operations)

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
end
