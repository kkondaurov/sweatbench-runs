defmodule GroupStay.MigrationsTest do
  # Runs the migrations against its own database file, outside the sandboxed test database.
  use ExUnit.Case, async: false

  alias GroupStay.{FinanceReports, Groups, PartnerOperations, Payments, Repo}
  alias GroupStay.Groups.Group

  @migrations_path Application.app_dir(:group_stay, "priv/repo/migrations")
  @first_release 20_260_923_000_000
  @second_release 20_260_923_010_000
  @third_release 20_260_923_020_000
  @fourth_release 20_260_923_030_000
  @fifth_release 20_260_923_040_000

  setup do
    path =
      Path.join(System.tmp_dir!(), "group_stay_upgrade_#{System.unique_integer([:positive])}.db")

    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)

    repo =
      start_supervised!(
        {Repo, name: nil, database: path, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    %{repo: repo}
  end

  test "groups created by the first release receive the policy their booking date implies",
       %{repo: repo} do
    migrate(repo, to: @first_release)

    for {group_id, booked_on, rate_plan} <- [
          {"old-flex", "2026-12-31", "flexible"},
          {"new-flex", "2027-01-01", "flexible"},
          {"old-advance", "2026-10-03", "advance_purchase"}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
          inserted_at, updated_at)
        VALUES (?, 'guest-22', 'ams-canal', ?, '2027-03-01', '2027-03-04', ?, 'active', 2,
          97500, 19500, 5000, '2026-10-03T00:00:00.000000Z', '2026-10-03T00:00:00.000000Z')
        """,
        [group_id, booked_on, rate_plan]
      )
    end

    migrate(repo, all: true)

    assert {:ok, old_flex} = Groups.fetch_group("old-flex")
    assert old_flex.policy_version == "flex-14"
    assert Group.refundable_until(old_flex) == ~D[2027-02-15]
    assert old_flex.credit_paid_cents == 0
    assert Group.cash_paid_cents(old_flex) == 5000

    assert {:ok, new_flex} = Groups.fetch_group("new-flex")
    assert new_flex.policy_version == "flex-30"
    assert Group.refundable_until(new_flex) == ~D[2027-01-30]

    assert {:ok, old_advance} = Groups.fetch_group("old-advance")
    assert old_advance.policy_version == "advance-nonrefundable"
    assert Group.refundable_until(old_advance) == nil
  end

  test "groups created by the second release keep working with durable operations",
       %{repo: repo} do
    migrate(repo, to: @second_release)

    Repo.query!("""
    INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
      rate_plan, policy_version, status, revision, lodging_total_cents, deposit_due_cents,
      deposit_paid_cents, credit_paid_cents, inserted_at, updated_at)
    VALUES ('group-81', 'guest-22', 'ams-canal', '2026-10-03', '2026-12-10', '2026-12-13',
      'flexible', 'flex-14', 'active', 2, 97500, 19500, 5000, 0,
      '2026-10-03T00:00:00.000000Z', '2026-10-03T00:00:00.000000Z')
    """)

    Repo.query!("""
    INSERT INTO ledger_entries (group_ref, operation_id, kind, amount_cents, occurred_on,
      inserted_at)
    SELECT id, 'op-legacy', 'cash_payment', 5000, '2026-10-04', '2026-10-04T00:00:00.000000Z'
    FROM groups
    """)

    migrate(repo, all: true)

    # Identifiers from earlier releases are not reconstructed as idempotency records.
    assert {:error, :not_found} = GroupStay.OperationRecords.fetch_result("op-legacy")

    pay = %{
      "operation_id" => "op-legacy",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "amount_cents" => 1000,
      "expected_revision" => 2
    }

    assert %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 13_500} =
             GroupStay.PartnerOperations.process_operation(pay)

    assert {:ok, %{"status" => "applied", "revision" => 3}} =
             GroupStay.OperationRecords.fetch_result("op-legacy")

    assert Groups.ledger_totals(~D[2026-10-05]).cash_held_cents == 6000
  end

  describe "room accounting for groups created by the third release" do
    setup %{repo: repo} do
      migrate(repo, to: @third_release)

      # group-src was cancelled into lot "cancel-src" before durable records existed.
      src = insert_group!("group-src", "cancelled", paid: 5000)
      insert_ledger_entry!(src, "op-src-pay", "cash_payment", 5000)
      insert_ledger_entry!(src, "cancel-src", "cash_converted_to_credit", 5000)
      old_lot = insert_lot!(src, "cancel-src", 5500, 2500)

      # group-81 is active: 5000 cents of legacy cash and 2000 of legacy credit, then durable
      # payments committed in the order pay-late, pay-early despite their dates, and durable
      # credit whose identifier an earlier release had also used.
      group = insert_group!("group-81", "active", paid: 15_000, credit: 3000)
      room_a = insert_room!(group, 0, "room-a", 15_000, 9000)
      room_b = insert_room!(group, 1, "room-b", 17_500, 10_500)
      insert_ledger_entry!(group, "op-legacy", "cash_payment", 5000)
      insert_application!(group, old_lot, "op-legacy-credit", 2000, "applied")
      insert_ledger_entry!(group, "pay-late", "cash_payment", 3000)
      insert_payment_record!("pay-late", "group-81", 3000, "2026-10-09", 3)
      insert_ledger_entry!(group, "pay-early", "cash_payment", 4000)
      insert_payment_record!("pay-early", "group-81", 4000, "2026-10-05", 4)
      insert_application!(group, old_lot, "op-legacy-credit", 1000, "applied")
      insert_record!("apply_hotel_credit", "op-legacy-credit", "group-81", 1000, "2026-10-06", 5)

      # group-old was cancelled into lot "cancel-old" after a legacy payment and a durable one.
      old = insert_group!("group-old", "cancelled", paid: 1500)
      insert_room!(old, 0, "room-a", 15_000, 9000)
      insert_ledger_entry!(old, "op-old-legacy", "cash_payment", 500)
      insert_ledger_entry!(old, "pay-conv", "cash_payment", 1000)
      insert_payment_record!("pay-conv", "group-old", 1000, "2026-10-04", 2)
      insert_ledger_entry!(old, "cancel-old", "cash_converted_to_credit", 1500)
      insert_lot!(old, "cancel-old", 1650, 1650)

      before = Repo.query!("SELECT * FROM ledger_entries ORDER BY id").rows
      migrate(repo, all: true)
      assert Repo.query!("SELECT * FROM ledger_entries ORDER BY id").rows == before

      %{room_a: room_a, room_b: room_b}
    end

    test "allocates legacy funding first, then durable records in commit order" do
      assert {:ok, group} = Groups.fetch_group("group-81")

      assert Enum.map(
               group.rooms,
               &{&1.room_id, &1.status, &1.cash_paid_cents, &1.credit_paid_cents}
             ) ==
               [{"room-a", "active", 7000, 2000}, {"room-b", "active", 5000, 1000}]

      assert %{deposit_paid_cents: 15_000, credit_paid_cents: 3000, deposit_due_cents: 19_500} =
               group

      assert {:ok, %{held_cents: 3000, recorded_cents: 3000}} = Payments.statement("pay-late")
      assert {:ok, %{held_cents: 4000, recorded_cents: 4000}} = Payments.statement("pay-early")
    end

    test "leaves every aggregate balance unchanged" do
      assert Groups.ledger_totals(~D[2026-10-10]) == %{
               cash_held_cents: 12_000,
               cash_refunded_cents: 0,
               cash_retained_cents: 0,
               cash_converted_to_credit_cents: 6500,
               cash_reduced_cents: 0,
               cash_charged_back_cents: 0,
               credit_liability_cents: 2500 + 3000 + 1650,
               credit_shortfall_cents: 0
             }

      assert {:ok, old} = Groups.fetch_group("group-old")
      assert %{status: "cancelled", deposit_paid_cents: 0, deposit_due_cents: 0} = old
      assert [%{status: "cancelled", cash_paid_cents: 0}] = old.rooms
    end

    test "durable payments can be reduced, but legacy funding cannot be addressed" do
      assert %{"code" => "operation_not_found"} = reduce("op-legacy", 100)
      assert {:error, :not_found} = Payments.statement("op-legacy")

      assert %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 8500} =
               reduce("pay-early", 4000)

      assert {:ok, group} = Groups.fetch_group("group-81")

      assert Enum.map(group.rooms, &{&1.room_id, &1.cash_paid_cents, &1.credit_paid_cents}) ==
               [{"room-a", 7000, 2000}, {"room-b", 1000, 1000}]
    end

    test "transfers draw durable funding before the legacy block" do
      insert_open!("group-92")

      # The durable credit (sharing its identifier with legacy credit) is the most recent
      # allocation, then pay-early.
      assert %{"status" => "applied"} = transfer("group-81", "group-92", 1500)

      assert {:ok, group} = Groups.fetch_group("group-81")

      assert Enum.map(group.rooms, &{&1.room_id, &1.cash_paid_cents, &1.credit_paid_cents}) ==
               [{"room-a", 7000, 2000}, {"room-b", 4500, 0}]

      assert {:ok,
              %{
                held_by_group: [
                  %{group_id: "group-81", amount_cents: 3500},
                  %{group_id: "group-92", amount_cents: 500}
                ]
              }} =
               Payments.statement("pay-early")

      # Then the rest of pay-early, pay-late (room-b's part first), and the legacy credit, which
      # was allocated after the legacy cash.
      assert %{"status" => "applied"} = transfer("group-81", "group-92", 8000)

      assert {:ok, group} = Groups.fetch_group("group-81")

      assert Enum.map(group.rooms, &{&1.room_id, &1.cash_paid_cents, &1.credit_paid_cents}) ==
               [{"room-a", 5000, 500}, {"room-b", 0, 0}]
    end

    test "payments on groups cancelled earlier can be reconciled and charged back" do
      assert {:ok,
              %{
                original_group_id: "group-old",
                recorded_cents: 1000,
                held_cents: 0,
                converted_to_credit_cents: 1000
              }} = Payments.statement("pay-conv")

      assert %{"status" => "applied", "charged_back_cents" => 1000, "revision" => 3} =
               PartnerOperations.process_operation(%{
                 "operation_id" => "cb-conv",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-10",
                 "payment_operation_id" => "pay-conv"
               })

      # The legacy 500 cents are senior: 550 of the lot is theirs and 1100 was pay-conv's, so
      # 2500 available and 3000 applied credit remain besides 550 of "cancel-old".
      assert %{credit_liability_cents: 6050, cash_converted_to_credit_cents: 5500} =
               Groups.ledger_totals(~D[2026-10-10])
    end
  end

  describe "allocation order for funding created by the fourth release" do
    setup %{repo: repo} do
      migrate(repo, to: @fourth_release)

      src = insert_group!("group-src", "cancelled", paid: 0)
      lot = insert_lot!(src, "cancel-17", 5500, 3500)
      group = insert_group!("group-81", "active", paid: 9000, credit: 2000)
      room_a = insert_room!(group, 0, "room-a", 15_000, 9000)
      insert_room!(group, 1, "room-b", 17_500, 10_500)

      insert_group!("group-92", "active", paid: 0)
      |> insert_room!(0, "room-a", 15_000, 9000)

      # Committed in the order pay-1, credit-1, pay-2.
      insert_payment_record!("pay-1", "group-81", 6000, "2026-10-04", 3)
      insert_cash_allocation!(group, room_a, "pay-1", 6000)
      insert_record!("apply_hotel_credit", "credit-1", "group-81", 2000, "2026-10-05", 4)
      insert_application!(group, lot, "credit-1", 2000, "applied", room_a)
      insert_payment_record!("pay-2", "group-81", 1000, "2026-10-06", 5)
      insert_cash_allocation!(group, room_a, "pay-2", 1000)

      migrate(repo, all: true)
      :ok
    end

    test "transfers move the most recently allocated funding first" do
      assert %{"status" => "applied", "source_revision" => 3, "destination_revision" => 3} =
               transfer("group-81", "group-92", 2500)

      assert {:ok, source} = Groups.fetch_group("group-81")

      assert Enum.map(source.rooms, &{&1.room_id, &1.cash_paid_cents, &1.credit_paid_cents}) ==
               [{"room-a", 6000, 500}, {"room-b", 0, 0}]

      assert {:ok, destination} = Groups.fetch_group("group-92")

      assert Enum.map(destination.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) ==
               [{1000, 1500}]

      # Newly allocated funding follows the migrated funding.
      assert %{"status" => "applied"} =
               PartnerOperations.process_operation(%{
                 "operation_id" => "pay-3",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-08",
                 "group_id" => "group-81",
                 "amount_cents" => 500
               })

      assert %{"status" => "applied"} = transfer("group-81", "group-92", 1000)
      assert {:ok, source} = Groups.fetch_group("group-81")

      assert Enum.map(source.rooms, &{&1.cash_paid_cents, &1.credit_paid_cents}) ==
               [{6000, 0}, {0, 0}]
    end
  end

  describe "finance reporting over data created by the fifth release" do
    setup %{repo: repo} do
      migrate(repo, to: @fifth_release)

      src = insert_group!("group-src", "cancelled", paid: 0)
      lot = insert_lot!(src, "cancel-17", 5500, 2500)
      group = insert_group!("group-81", "active", paid: 6000, credit: 1000)
      room_a = insert_room!(group, 0, "room-a", 15_000, 9000)
      insert_room!(group, 1, "room-b", 17_500, 10_500)
      insert_payment_record!("pay-1", "group-81", 5000, "2026-10-04", 3)
      insert_cash_allocation!(group, room_a, "pay-1", 5000)
      insert_application!(group, lot, "credit-1", 1000, "applied", room_a)

      migrate(repo, all: true)
      :ok
    end

    test "opens with the held cash and credit liability already recorded" do
      assert FinanceReports.daily_report(~D[2026-10-05]) == {:error, :not_available}

      assert %{"status" => "applied", "starts_on" => "2026-10-05"} =
               PartnerOperations.process_operation(%{
                 "operation_id" => "start",
                 "type" => "start_finance_reporting",
                 "occurred_on" => "2026-10-05",
                 "starts_on" => "2026-10-05"
               })

      assert %{"status" => "applied"} =
               PartnerOperations.process_operation(%{
                 "operation_id" => "pay-2",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-06",
                 "group_id" => "group-81",
                 "amount_cents" => 1000
               })

      assert {:ok, %{cash: [ams], credit: credit}} = FinanceReports.daily_report(~D[2026-10-06])
      assert %{property_id: "ams-canal", opening_held_cents: 5000, closing_held_cents: 6000} = ams
      assert ams.movements["received_cents"] == 1000
      assert %{opening_liability_cents: 3500, closing_liability_cents: 3500} = credit

      # The lot's unapplied balance expires on its expiry date.
      assert {:ok, %{credit: expiring}} = FinanceReports.daily_report(~D[2027-10-05])
      assert %{closing_liability_cents: 1000} = expiring
      assert expiring.movements["expired_cents"] == 2500
      assert Groups.ledger_totals(~D[2027-10-05]).credit_liability_cents == 1000
    end
  end

  defp insert_open!(group_id) do
    assert %{"status" => "applied"} =
             PartnerOperations.process_operation(%{
               "operation_id" => "open-#{group_id}",
               "type" => "open_group",
               "occurred_on" => "2026-10-03",
               "group_id" => group_id,
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-13",
               "rate_plan" => "flexible",
               "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50_000}]
             })
  end

  defp transfer(source, destination, amount) do
    PartnerOperations.process_operation(%{
      "operation_id" => "transfer-#{System.unique_integer([:positive])}",
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-07",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    })
  end

  defp reduce(payment_operation_id, amount) do
    PartnerOperations.process_operation(%{
      "operation_id" => "reduce-#{payment_operation_id}",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-10",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    })
  end

  @timestamp "2026-10-03T00:00:00.000000Z"

  defp insert_group!(group_id, status, amounts) do
    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, credit_paid_cents, inserted_at, updated_at)
      VALUES (?, 'guest-22', 'ams-canal', '2026-10-03', '2026-12-10', '2026-12-13', 'flexible',
        'flex-14', ?, 2, 97500, 19500, ?, ?, ?, ?)
      RETURNING id
      """,
      [group_id, status, amounts[:paid], amounts[:credit] || 0, @timestamp, @timestamp]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_room!(group_ref, position, room_id, rate, deposit) do
    Repo.query!(
      """
      INSERT INTO group_rooms (group_ref, position, room_id, nightly_rate_cents, lodging_cents,
        deposit_cents)
      VALUES (?, ?, ?, ?, ?, ?) RETURNING id
      """,
      [group_ref, position, room_id, rate, rate * 3, deposit]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_ledger_entry!(group_ref, operation_id, kind, amount) do
    Repo.query!(
      """
      INSERT INTO ledger_entries (group_ref, operation_id, kind, amount_cents, occurred_on,
        inserted_at)
      VALUES (?, ?, ?, ?, '2026-10-04', ?)
      """,
      [group_ref, operation_id, kind, amount, @timestamp]
    )
  end

  defp insert_lot!(group_ref, source_operation_id, issued, remaining) do
    Repo.query!(
      """
      INSERT INTO credit_lots (guest_id, source_operation_id, source_group_ref, issued_cents,
        remaining_cents, issued_on, expires_on, inserted_at, updated_at)
      VALUES ('guest-22', ?, ?, ?, ?, '2026-10-04', '2027-10-05', ?, ?) RETURNING id
      """,
      [source_operation_id, group_ref, issued, remaining, @timestamp, @timestamp]
    ).rows
    |> hd()
    |> hd()
  end

  defp insert_application!(group_ref, lot_ref, operation_id, amount, status) do
    Repo.query!(
      """
      INSERT INTO credit_applications (group_ref, lot_ref, operation_id, amount_cents, applied_on,
        status, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, '2026-10-04', ?, ?, ?)
      """,
      [group_ref, lot_ref, operation_id, amount, status, @timestamp, @timestamp]
    )
  end

  defp insert_application!(group_ref, lot_ref, operation_id, amount, status, room_ref) do
    Repo.query!(
      """
      INSERT INTO credit_applications (group_ref, lot_ref, room_ref, operation_id, amount_cents,
        applied_on, status, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, '2026-10-04', ?, ?, ?)
      """,
      [group_ref, lot_ref, room_ref, operation_id, amount, status, @timestamp, @timestamp]
    )
  end

  defp insert_cash_allocation!(group_ref, room_ref, payment_operation_id, amount) do
    Repo.query!(
      """
      INSERT INTO cash_allocations (group_ref, room_ref, payment_operation_id, amount_cents,
        status, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, 'held', ?, ?)
      """,
      [group_ref, room_ref, payment_operation_id, amount, @timestamp, @timestamp]
    )
  end

  defp insert_payment_record!(operation_id, group_id, amount, occurred_on, revision),
    do:
      insert_record!("record_cash_payment", operation_id, group_id, amount, occurred_on, revision)

  defp insert_record!(type, operation_id, group_id, amount, occurred_on, revision) do
    payload = %{
      "operation_id" => operation_id,
      "type" => type,
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }

    result = %{
      "operation_id" => operation_id,
      "status" => "applied",
      "group_id" => group_id,
      "amount_cents" => amount,
      "outstanding_deposit_cents" => 0,
      "revision" => revision
    }

    Repo.query!(
      """
      INSERT INTO operation_records (operation_id, type, payload, result, status, inserted_at)
      VALUES (?, ?, ?, ?, 'applied', ?)
      """,
      [
        operation_id,
        type,
        GroupStay.OperationRecords.canonical_json(payload),
        Jason.encode!(result),
        @timestamp
      ]
    )
  end

  defp migrate(repo, opts) do
    Ecto.Migrator.run(Repo, @migrations_path, :up, [dynamic_repo: repo, log: false] ++ opts)
  end
end
