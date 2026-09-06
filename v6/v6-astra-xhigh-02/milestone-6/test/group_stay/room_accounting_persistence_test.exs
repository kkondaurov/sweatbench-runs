defmodule GroupStay.RoomAccountingPersistenceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import GroupStay.ReservationFixtures
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.PartnerOperations.Operation

  alias GroupStay.Reservations.{
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Payments,
    RoomAllocation
  }

  @moduletag capture_log: true
  @migration 20_260_905_000_003
  @transfer_migration 20_260_905_000_004
  @finance_migration 20_260_905_000_005

  setup do
    directory = Path.expand("tmp/room-accounting-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> remove_database_directory(directory) end)

    options = [
      name: nil,
      database: Path.join(directory, "test.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    stop_supervised!(Repo)
    options = Keyword.put(options, :pool_size, 4)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    %{repo: repo, options: options}
  end

  test "upgrade allocates legacy cash then original credit consumption before recorded funding in commit order" do
    issue("source-1", "source-pay-1", 50, "2026-10-03")
    issue("source-2", "source-pay-2", 100, "2026-10-04")
    legacy_credit = operation("apply_hotel_credit", %{"amount_cents" => 50})
    legacy_cash = pay("legacy", 40)

    recorded_credit =
      operation("apply_hotel_credit", %{"amount_cents" => 20, "occurred_on" => "2026-11-20"})

    recorded_cash = pay("recorded", 150) |> Map.put("occurred_on", "2026-10-01")

    later_credit =
      operation("apply_hotel_credit", %{"amount_cents" => 30, "occurred_on" => "2026-10-04"})

    applied([
      opening([100, 100, 100]),
      legacy_credit,
      legacy_cash,
      recorded_credit,
      recorded_cash,
      later_credit
    ])

    assert Ecto.Migrator.run(Repo, :down, to: @migration, log: false) == [
             @finance_migration,
             @transfer_migration,
             @migration
           ]

    legacy_ids = [legacy_credit["operation_id"], legacy_cash["operation_id"]]
    Repo.delete_all(from o in Operation, where: o.operation_id in ^legacy_ids)
    # Audit type, not coincidental fields or the operation date, classifies funding.
    Repo.insert!(%Operation{
      operation_id: "misleading",
      type: "reschedule_group",
      payload: %{"type" => "record_cash_payment", "amount_cents" => 999},
      result: %{"status" => "applied", "group_id" => "group-81", "amount_cents" => 999}
    })

    before = raw_balances()
    audit = Repo.all(from o in Operation, order_by: o.id)

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [
             @migration,
             @transfer_migration,
             @finance_migration
           ]

    assert raw_balances() == before
    assert Repo.all(from o in Operation, order_by: o.id) == audit
    assert room_balances() == [{40, 60}, {90, 10}, {60, 30}]
    assert Reservations.get_group("group-81").revision == 6
    assert {:error, %{code: "operation_not_found"}} = Payments.statement("legacy")
    assert {:ok, %{held_cents: 150, recorded_cents: 150}} = Payments.statement("recorded")

    applied([
      operation("reduce_cash_payment", %{
        "payment_operation_id" => "recorded",
        "amount_cents" => 70
      })
    ])

    assert room_balances() == [{40, 60}, {80, 10}, {0, 30}]
    applied([operation("cancel_rooms", %{"room_ids" => ["r1"]})])
    lots = Reservations.guest_credit("guest-22", ~D[2026-10-04]).lots
    assert Enum.map(lots, & &1.remaining_cents) == [55, 70]
  end

  test "upgrade reconstructs settled payment statements and converted entitlements, with legacy cash senior" do
    applied([
      opening([10], %{"group_id" => "converted"}),
      pay("legacy", 5, "converted"),
      pay("recorded", 5, "converted"),
      operation("cancel_group", %{"group_id" => "converted", "refund_method" => "hotel_credit"})
    ])

    for {id, on} <- [{"refunded", "2026-10-04"}, {"retained", "2026-11-27"}] do
      applied([
        opening([100], %{"group_id" => id}),
        pay(id <> "-pay", 100, id),
        operation("cancel_group", %{"group_id" => id, "occurred_on" => on})
      ])
    end

    applied([opening([7]), operation("apply_hotel_credit", %{"amount_cents" => 7})])
    before = raw_balances()
    Ecto.Migrator.run(Repo, :down, to: @migration, log: false)
    Repo.delete_all(from o in Operation, where: o.operation_id == "legacy")

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [
             @migration,
             @transfer_migration,
             @finance_migration
           ]

    assert raw_balances() == before

    assert {:ok, %{converted_to_credit_cents: 5, recorded_cents: 5}} =
             Payments.statement("recorded")

    assert {:ok, %{refunded_cents: 100}} = Payments.statement("refunded-pay")
    assert {:ok, %{retained_cents: 100}} = Payments.statement("retained-pay")
    target = Reservations.get_group("group-81")
    applied([operation("charge_back_payment", %{"payment_operation_id" => "recorded"})])
    assert Reservations.get_group("group-81") == target
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 1
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 7
    applied([operation("cancel_group")])
    assert Reservations.guest_credit("guest-22", ~D[2026-10-04]).available_cents == 6

    applied([
      operation("charge_back_payment", %{"payment_operation_id" => "refunded-pay"}),
      operation("charge_back_payment", %{"payment_operation_id" => "retained-pay"})
    ])

    ledger = Reservations.ledger(~D[2026-10-04])
    assert ledger.cash_refunded_cents == 0
    assert ledger.cash_retained_cents == 0
    assert ledger.cash_converted_to_credit_cents == 5
    assert ledger.cash_charged_back_cents == 205
  end

  test "new allocations, statements, shortfall and exact retries survive a repo restart", %{
    options: options
  } do
    operations = [
      opening([100, 100, 100]),
      pay("p", 300),
      operation("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 40}),
      operation("cancel_rooms", %{"room_ids" => ["r1"], "refund_method" => "hotel_credit"}),
      opening([80], %{"group_id" => "target"}),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80}),
      operation("charge_back_payment", %{"payment_operation_id" => "p"}),
      operation("cancel_rooms", %{"room_ids" => ["r1"]})
    ]

    results = Reservations.process_batch(operations)
    assert List.last(results).code == "invalid_rooms"
    before = snapshot()
    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Reservations.process_batch(operations) == results
    assert snapshot() == before
    assert {:ok, %{reduced_cents: 40, charged_back_cents: 260}} = Payments.statement("p")
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 80
    applied([operation("cancel_group", %{"group_id" => "target"})])
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 0
  end

  test "concurrent retries and competing reversals have at most once cash and entitlement effects",
       %{repo: repo} do
    applied([opening([100, 100]), pay("p", 200)])

    reduction =
      operation("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 30})

    results = race(repo, List.duplicate(reduction, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).revision == 3
    assert Reservations.ledger().cash_reduced_cents == 30

    cancellation =
      operation("cancel_rooms", %{"room_ids" => ["r1"], "refund_method" => "hotel_credit"})

    results = race(repo, List.duplicate(cancellation, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).credit_issued_cents == 110
    assert Repo.aggregate(CreditLot, :count) == 1

    results =
      race(
        repo,
        for(
          _ <- 1..8,
          do:
            operation("charge_back_payment", %{
              "payment_operation_id" => "p",
              "expected_revision" => 4
            })
        )
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.ledger().cash_charged_back_cents == 170
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 0
    assert Reservations.get_group("group-81").revision == 5
  end

  test "a fault rolls back room, payment, credit and audit changes while preserving prior operations" do
    issue("source", "source-pay", 100, "2026-10-04")
    applied([opening([80]), operation("apply_hotel_credit", %{"amount_cents" => 80})])
    before = snapshot()

    Repo.query!(
      "CREATE TRIGGER fail_chargeback BEFORE INSERT ON partner_operations WHEN NEW.type = 'charge_back_payment' BEGIN SELECT RAISE(ABORT, 'forced audit failure'); END"
    )

    op = operation("charge_back_payment", %{"payment_operation_id" => "source-pay"})
    assert_raise Exqlite.Error, fn -> Reservations.process_batch([op]) end
    assert snapshot() == before
    Repo.query!("DROP TRIGGER fail_chargeback")
    applied([op])
    assert Reservations.ledger(~D[2026-10-04]).credit_shortfall_cents == 80
  end

  test "transfer migration preserves old allocations, balances and payment statement shapes" do
    issue("issuer", "issuer-pay", 30, "2026-10-04")

    applied([
      opening([100]),
      opening([100], %{"group_id" => "destination"}),
      pay("p", 40),
      operation("apply_hotel_credit", %{"amount_cents" => 20}),
      pay("legacy", 20)
    ])

    # An older release can carry cash with no durable payment identity.
    Repo.update_all(from(a in RoomAllocation, where: a.payment_operation_id == "legacy"),
      set: [payment_operation_id: nil]
    )

    Repo.delete_all(from o in Operation, where: o.operation_id == "legacy")
    before = snapshot()
    balances = Reservations.ledger(~D[2026-10-04])
    assert {:ok, statement} = Payments.statement("p")
    refute Map.has_key?(statement, :held_by_group)

    assert Ecto.Migrator.run(Repo, :down, to: @transfer_migration, log: false) == [
             @finance_migration,
             @transfer_migration
           ]

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == [
             @transfer_migration,
             @finance_migration
           ]

    assert snapshot() == before
    assert Payments.statement("p") == {:ok, statement}
    applied([transfer("group-81", "destination", 30)])
    assert Reservations.ledger(~D[2026-10-04]) == balances
    assert Reservations.get_group("destination").cash_paid_cents == 20
    assert Reservations.get_group("destination").credit_paid_cents == 10
    assert Payments.statement("p") == {:ok, statement}
    assert {:error, %{code: "operation_not_found"}} = Payments.statement("legacy")
  end

  test "transferred provenance and statement participation survive restarts and complete settlement",
       %{options: options} do
    operations = [
      opening([100]),
      opening([100], %{"group_id" => "destination"}),
      pay("p", 100),
      transfer("group-81", "destination", 70),
      operation("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 20}),
      transfer("destination", "group-81", 10)
    ]

    results = applied(operations)
    before = snapshot()
    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)
    assert Reservations.process_batch(operations) == results
    assert snapshot() == before

    assert {:ok,
            %{
              held_by_group: [
                %{group_id: "destination", amount_cents: 40},
                %{group_id: "group-81", amount_cents: 40}
              ]
            }} = Payments.statement("p")

    applied([operation("charge_back_payment", %{"payment_operation_id" => "p"})])
    stop_supervised!(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert {:ok, %{held_by_group: [], reduced_cents: 20, charged_back_cents: 80}} =
             Payments.statement("p")

    assert Reservations.process_batch(operations) == results
    assert Reservations.ledger().cash_held_cents == 0
  end

  test "concurrent transfer retries apply once and competing sources honor the destination guard",
       %{repo: repo} do
    applied([opening([100]), opening([100], %{"group_id" => "destination"}), pay("p", 100)])

    transfer =
      transfer("group-81", "destination", 40, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    results = race(repo, List.duplicate(transfer, 8))
    assert length(Enum.uniq(results)) == 1
    assert hd(results).source_revision == 3
    assert hd(results).destination_revision == 2
    assert Reservations.ledger().cash_held_cents == 100

    applied([opening([100], %{"group_id" => "other"}), pay("other-pay", 100, "other")])

    results =
      race(repo, [
        transfer("group-81", "destination", 60, %{"destination_expected_revision" => 2}),
        transfer("other", "destination", 60, %{"destination_expected_revision" => 2})
      ])

    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert [%{code: "stale_revision", group_id: "destination", actual_revision: 3}] =
             Enum.filter(results, &(&1.status == "rejected"))

    assert Reservations.get_group("destination").deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 200
  end

  test "faults after moving allocations or updating both groups roll back transfers and their audit record" do
    applied([opening([100]), opening([100], %{"group_id" => "destination"}), pay("p", 100)])
    transfer = transfer("group-81", "destination", 60)
    before = snapshot()

    for {name, trigger} <- [
          {"fail_destination", "BEFORE UPDATE ON groups WHEN NEW.group_id = 'destination'"},
          {"fail_transfer_audit",
           "BEFORE INSERT ON partner_operations WHEN NEW.type = 'transfer_deposit'"}
        ] do
      Repo.query!(
        "CREATE TRIGGER #{name} #{trigger} BEGIN SELECT RAISE(ABORT, 'forced transfer failure'); END"
      )

      assert_raise Exqlite.Error, fn -> Reservations.process_batch([transfer]) end
      assert snapshot() == before
      Repo.query!("DROP TRIGGER #{name}")
    end

    applied([transfer])

    before = snapshot()

    Repo.query!(
      "CREATE TRIGGER fail_correction BEFORE INSERT ON partner_operations WHEN NEW.type IN ('reduce_cash_payment', 'charge_back_payment') BEGIN SELECT RAISE(ABORT, 'forced correction failure'); END"
    )

    for type <- ~w(reduce_cash_payment charge_back_payment) do
      correction = operation(type, %{"payment_operation_id" => "p", "amount_cents" => 80})
      assert_raise Exqlite.Error, fn -> Reservations.process_batch([correction]) end
      assert snapshot() == before
    end

    Repo.query!("DROP TRIGGER fail_correction")
    applied([operation("charge_back_payment", %{"payment_operation_id" => "p"})])
    assert Reservations.get_group("group-81").revision == 4
    assert Reservations.get_group("destination").revision == 3
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

  defp opening(deposits, attrs \\ %{}) do
    rooms =
      deposits
      |> Enum.with_index(1)
      |> Enum.map(fn {due, i} -> %{"room_id" => "r#{i}", "nightly_rate_cents" => due * 5} end)

    open_operation(Map.merge(%{"departure_on" => "2026-12-11", "rooms" => rooms}, attrs))
  end

  defp pay(id, amount, group \\ "group-81"),
    do:
      operation("record_cash_payment", %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount
      })

  defp issue(group, payment, cash, on),
    do:
      applied([
        opening([cash], %{"group_id" => group}),
        pay(payment, cash, group),
        operation("cancel_group", %{
          "group_id" => group,
          "occurred_on" => on,
          "refund_method" => "hotel_credit"
        })
      ])

  defp applied(operations) do
    results = Reservations.process_batch(operations)
    assert Enum.all?(results, &(&1.status == "applied")), inspect(results)
    results
  end

  defp room_balances,
    do:
      Enum.map(
        Reservations.get_group("group-81").rooms,
        &{&1.cash_paid_cents, &1.credit_paid_cents}
      )

  defp raw_balances do
    {Repo.query!(
       "SELECT group_id, revision, cash_paid_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents FROM groups ORDER BY group_id"
     ).rows, Repo.query!("SELECT id, remaining_cents FROM credit_lots ORDER BY id").rows}
  end

  defp snapshot,
    do:
      for(
        schema <- [
          Group,
          RoomAllocation,
          CreditLot,
          CreditAllocation,
          CreditEntitlement,
          Operation
        ],
        do:
          Repo.all(
            from row in schema,
              order_by: field(row, ^if(schema == Group, do: :group_id, else: :id))
          )
      )

  defp race(repo, operations) do
    operations
    |> Enum.map(fn operation ->
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        [result] = Reservations.process_batch([operation])
        result
      end)
    end)
    |> Task.await_many(15_000)
  end

  defp remove_database_directory(directory, retries \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] and retries > 0 ->
        Process.sleep(20)
        remove_database_directory(directory, retries - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end
end
