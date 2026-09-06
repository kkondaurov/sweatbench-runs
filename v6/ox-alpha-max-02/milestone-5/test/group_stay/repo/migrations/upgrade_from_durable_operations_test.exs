defmodule GroupStay.Repo.Migrations.UpgradeFromDurableOperationsTest do
  use ExUnit.Case, async: false

  alias GroupStay.UpgradeRepo

  @migrations_dir "priv/repo/migrations"
  @durable_version 20_260_826_000_003

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "group-stay-upgrade-rooms-#{System.unique_integer([:positive])}.db"
      )

    Application.put_env(:group_stay, UpgradeRepo, database: path, pool_size: 1)
    start_supervised!(UpgradeRepo)

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"] do
        File.rm(path <> suffix)
      end
    end)

    :ok
  end

  test "funding without durable records moves forward ahead of recorded funding" do
    upgrade_to_durable_release()

    # Three nights: room-a lodges 45000 (deposit 9000), room-b 36000 (7200).
    insert_group(
      group_id: "g-mix",
      rate_plan: "flexible",
      status: "active",
      booked_on: "2026-05-01",
      arrival_on: "2026-06-10",
      departure_on: "2026-06-13",
      revision: 5,
      policy_version: "flex-14",
      lodging_total_cents: 81_000,
      deposit_due_cents: 16_200,
      deposit_paid_cents: 13_000,
      cash_paid_cents: 11_000,
      credit_paid_cents: 2_000
    )

    insert_room(group_id: "g-mix", position: 0, room_id: "room-a", nightly_rate_cents: 15_000)
    insert_room(group_id: "g-mix", position: 1, room_id: "room-b", nightly_rate_cents: 12_000)

    # Recorded funding: two cash payments and one credit application, committed
    # in this order. Everything else the group received (3000 cash and the
    # first 1200 of credit consumption) predates durable records.
    insert_operation(%{
      operation_id: "pay-9",
      type: "record_cash_payment",
      payload: %{
        "operation_id" => "pay-9",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-05-20",
        "group_id" => "g-mix",
        "amount_cents" => 3_000
      },
      result: %{
        "operation_id" => "pay-9",
        "status" => "applied",
        "group_id" => "g-mix",
        "amount_cents" => 3_000,
        "outstanding_deposit_cents" => 13_200,
        "revision" => 3
      }
    })

    insert_operation(%{
      operation_id: "pay-10",
      type: "record_cash_payment",
      payload: %{
        "operation_id" => "pay-10",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-05-21",
        "group_id" => "g-mix",
        "amount_cents" => 5_000
      },
      result: %{
        "operation_id" => "pay-10",
        "status" => "applied",
        "group_id" => "g-mix",
        "amount_cents" => 5_000,
        "outstanding_deposit_cents" => 8_200,
        "revision" => 4
      }
    })

    lot_id = insert_credit_lot(source_operation_id: "cancel-legacy")

    insert_application(group_id: "g-mix", credit_lot_id: lot_id, applied_cents: 2_000)

    insert_operation(%{
      operation_id: "apply-1",
      type: "apply_hotel_credit",
      payload: %{
        "operation_id" => "apply-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-05-22",
        "group_id" => "g-mix",
        "amount_cents" => 800
      },
      result: %{
        "operation_id" => "apply-1",
        "status" => "applied",
        "group_id" => "g-mix",
        "amount_cents" => 800,
        "outstanding_deposit_cents" => 7_400,
        "revision" => 5
      }
    })

    run_accounting_migration()

    assert rooms("g-mix") == [
             %{
               "room_id" => "room-a",
               "status" => "active",
               "lodging_cents" => 45_000,
               "deposit_due_cents" => 9_000,
               "cash_paid_cents" => 7_800,
               "credit_paid_cents" => 1_200
             },
             %{
               "room_id" => "room-b",
               "status" => "active",
               "lodging_cents" => 36_000,
               "deposit_due_cents" => 7_200,
               "cash_paid_cents" => 3_200,
               "credit_paid_cents" => 800
             }
           ]

    # The senior block is the unattributed legacy funding: its aggregate cash
    # first, then its credit lot. Durable payments follow in commit order.
    assert allocations() == [
             {nil, 3_000, "held"},
             {"pay-9", 3_000, "held"},
             {"pay-10", 1_800, "held"},
             {"pay-10", 3_200, "held"}
           ]

    assert room_applications() == [
             {"room-a", "cancel-legacy", 1_200},
             {"room-b", "cancel-legacy", 800}
           ]

    # One shared creation sequence spans both funding kinds, oldest first:
    # the legacy cash block, then recorded cash in commit order, then the
    # applications this migration replayed.
    assert allocation_sequences() == [
             {nil, 3_000},
             {"pay-9", 3_000},
             {"pay-10", 1_800},
             {"pay-10", 3_200},
             {"cancel-legacy", 1_200},
             {"cancel-legacy", 800}
           ]
  end

  test "aggregate balances survive the allocation unchanged" do
    upgrade_to_durable_release()

    insert_group(
      group_id: "g-sum",
      rate_plan: "flexible",
      status: "active",
      booked_on: "2026-05-01",
      arrival_on: "2026-06-10",
      departure_on: "2026-06-13",
      revision: 2,
      policy_version: "flex-14",
      lodging_total_cents: 81_000,
      deposit_due_cents: 16_200,
      deposit_paid_cents: 4_000,
      cash_paid_cents: 4_000,
      credit_paid_cents: 0
    )

    insert_room(group_id: "g-sum", position: 0, room_id: "room-a", nightly_rate_cents: 15_000)
    insert_room(group_id: "g-sum", position: 1, room_id: "room-b", nightly_rate_cents: 12_000)

    run_accounting_migration()

    assert %{columns: columns, rows: [[cash, credit, converted]]} =
             UpgradeRepo.query!(
               "SELECT cash_paid_cents, credit_paid_cents, cash_converted_to_credit_cents " <>
                 "FROM groups WHERE group_id = 'g-sum'"
             )

    assert Enum.map(columns, &String.to_existing_atom/1) == [
             :cash_paid_cents,
             :credit_paid_cents,
             :cash_converted_to_credit_cents
           ]

    assert {cash, credit, converted} == {4_000, 0, 0}

    assert %{rows: [[due, paid]]} =
             UpgradeRepo.query!(
               "SELECT deposit_due_cents, deposit_paid_cents FROM groups WHERE group_id = 'g-sum'"
             )

    assert {due, paid} == {16_200, 4_000}

    assert UpgradeRepo.query!("""
           SELECT r.room_id, a.payment_operation_id, a.amount_cents, a.disposition
           FROM room_cash_allocations a
           JOIN group_rooms r ON r.id = a.room_id
           ORDER BY a.rowid
           """).rows == [["room-a", nil, 4_000, "held"]]
  end

  test "payments settled before the release keep their dispositions readable" do
    upgrade_to_durable_release()

    insert_group(
      group_id: "g-done",
      rate_plan: "advance_purchase",
      status: "cancelled",
      booked_on: "2026-04-01",
      arrival_on: "2026-06-10",
      departure_on: "2026-06-13",
      revision: 3,
      policy_version: "advance-nonrefundable",
      lodging_total_cents: 30_000,
      deposit_due_cents: 0,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      retained_cents: 6_000
    )

    insert_room(group_id: "g-done", position: 0, room_id: "room-a", nightly_rate_cents: 10_000)

    insert_operation(%{
      operation_id: "pay-old",
      type: "record_cash_payment",
      payload: %{
        "operation_id" => "pay-old",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-04-15",
        "group_id" => "g-done",
        "amount_cents" => 6_000
      },
      result: %{
        "operation_id" => "pay-old",
        "status" => "applied",
        "group_id" => "g-done",
        "amount_cents" => 6_000,
        "outstanding_deposit_cents" => 0,
        "revision" => 2
      }
    })

    run_accounting_migration()

    assert allocations() == [{"pay-old", 6_000, "retained"}]

    assert %{rows: [["cancelled"]]} =
             UpgradeRepo.query!("SELECT status FROM group_rooms WHERE room_id = 'room-a'")
  end

  defp upgrade_to_durable_release do
    Ecto.Migrator.run(UpgradeRepo, @migrations_dir, :up, to: @durable_version, log: false)
  end

  defp run_accounting_migration do
    Ecto.Migrator.run(UpgradeRepo, @migrations_dir, :up, all: true, log: false)
  end

  defp insert_group(fields) do
    fields =
      Keyword.merge(
        fields,
        guest_id: "guest-upgrade",
        property_id: "ams-canal",
        refunded_cents: Keyword.get(fields, :refunded_cents, 0),
        retained_cents: Keyword.get(fields, :retained_cents, 0),
        cash_converted_to_credit_cents: 0
      )

    UpgradeRepo.query!(
      """
      INSERT INTO groups
        (id, group_id, guest_id, property_id, rate_plan, status, booked_on,
         arrival_on, departure_on, revision, policy_version, lodging_total_cents,
         deposit_due_cents, deposit_paid_cents, cash_paid_cents, credit_paid_cents,
         refunded_cents, retained_cents, cash_converted_to_credit_cents,
         inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Ecto.UUID.bingenerate(),
        fields[:group_id],
        fields[:guest_id],
        fields[:property_id],
        fields[:rate_plan],
        fields[:status],
        fields[:booked_on],
        fields[:arrival_on],
        fields[:departure_on],
        fields[:revision],
        fields[:policy_version],
        fields[:lodging_total_cents],
        fields[:deposit_due_cents],
        fields[:deposit_paid_cents],
        fields[:cash_paid_cents],
        fields[:credit_paid_cents],
        fields[:refunded_cents],
        fields[:retained_cents],
        fields[:cash_converted_to_credit_cents],
        "2026-05-01 00:00:00Z",
        "2026-05-01 00:00:00Z"
      ]
    )
  end

  defp insert_room(fields) do
    UpgradeRepo.query!(
      """
      INSERT INTO group_rooms (id, group_id, position, room_id, nightly_rate_cents)
      SELECT ?, g.id, ?, ?, ? FROM groups g WHERE g.group_id = ?
      """,
      [
        Ecto.UUID.bingenerate(),
        fields[:position],
        fields[:room_id],
        fields[:nightly_rate_cents],
        fields[:group_id]
      ]
    )
  end

  defp insert_operation(fields) do
    UpgradeRepo.query!(
      """
      INSERT INTO operations
        (operation_id, type, payload, result, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        fields[:operation_id],
        fields[:type],
        Jason.encode!(fields[:payload]),
        Jason.encode!(fields[:result]),
        "2026-05-02 00:00:00Z",
        "2026-05-02 00:00:00Z"
      ]
    )
  end

  defp insert_credit_lot(fields) do
    id = Ecto.UUID.bingenerate()

    UpgradeRepo.query!(
      """
      INSERT INTO credit_lots
        (id, guest_id, source_operation_id, issued_on, expires_on, remaining_cents,
         inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 0, ?, ?)
      """,
      [
        id,
        "guest-upgrade",
        fields[:source_operation_id],
        "2026-04-20",
        "2027-04-21",
        "2026-04-20 00:00:00Z",
        "2026-04-20 00:00:00Z"
      ]
    )

    id
  end

  defp insert_application(fields) do
    UpgradeRepo.query!(
      """
      INSERT INTO group_credit_applications
        (id, group_id, credit_lot_id, applied_cents, inserted_at, updated_at)
      SELECT ?, g.id, ?, ?, ?, ? FROM groups g WHERE g.group_id = ?
      """,
      [
        Ecto.UUID.bingenerate(),
        fields[:credit_lot_id],
        fields[:applied_cents],
        "2026-04-25 00:00:00Z",
        "2026-04-25 00:00:00Z",
        fields[:group_id]
      ]
    )
  end

  defp rooms(group_id) do
    %{rows: rows} =
      UpgradeRepo.query!(
        """
        SELECT r.room_id, r.status, r.lodging_cents, r.deposit_due_cents,
               r.cash_paid_cents, r.credit_paid_cents
        FROM group_rooms r
        JOIN groups g ON g.id = r.group_id
        WHERE g.group_id = ?
        ORDER BY r.position
        """,
        [group_id]
      )

    Enum.map(rows, fn [room_id, status, lodging, due, cash, credit] ->
      %{
        "room_id" => room_id,
        "status" => status,
        "lodging_cents" => lodging,
        "deposit_due_cents" => due,
        "cash_paid_cents" => cash,
        "credit_paid_cents" => credit
      }
    end)
  end

  defp allocations do
    %{rows: rows} =
      UpgradeRepo.query!(
        """
        SELECT a.payment_operation_id, a.amount_cents, a.disposition
        FROM room_cash_allocations a
        ORDER BY rowid
        """,
        []
      )

    Enum.map(rows, fn [payment_operation_id, amount, disposition] ->
      {payment_operation_id, amount, disposition}
    end)
  end

  defp room_applications do
    %{rows: rows} =
      UpgradeRepo.query!(
        """
        SELECT r.room_id, l.source_operation_id, a.applied_cents
        FROM room_credit_applications a
        JOIN group_rooms r ON r.id = a.room_id
        JOIN credit_lots l ON l.id = a.credit_lot_id
        ORDER BY a.rowid
        """,
        []
      )

    Enum.map(rows, fn [room_id, source_operation_id, applied] ->
      {room_id, source_operation_id, applied}
    end)
  end

  # Every allocation of both funding kinds merged into one oldest-to-newest
  # list by their shared creation sequence.
  defp allocation_sequences do
    cash =
      UpgradeRepo.query!(
        """
        SELECT payment_operation_id, amount_cents, allocation_seq
        FROM room_cash_allocations
        """,
        []
      ).rows
      |> Enum.map(fn [payment_operation_id, amount, seq] ->
        {seq, payment_operation_id || "", amount}
      end)

    credit =
      UpgradeRepo.query!(
        """
        SELECT l.source_operation_id, a.applied_cents, a.allocation_seq
        FROM room_credit_applications a
        JOIN credit_lots l ON l.id = a.credit_lot_id
        """,
        []
      ).rows
      |> Enum.map(fn [source_operation_id, amount, seq] ->
        {seq, source_operation_id, amount}
      end)

    (cash ++ credit)
    |> Enum.sort()
    |> Enum.map(fn {_seq, who, amount} -> {who, amount} end)
    |> Enum.map(fn {who, amount} -> {if(who == "", do: nil, else: who), amount} end)
  end
end
