defmodule GroupStay.LegacyMigrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Schemas.{Payment, RoomAllocation}

  # A database last written by the previous release carries funding without
  # durable operation records. Migration 000004 must bring that funding
  # forward as one unattributed senior block per active group (aggregate cash
  # first, then hotel-credit lots in original consumption order), then the
  # funding represented by durable operation records in commit order.
  test "legacy funding is brought forward into room accounting" do
    db =
      Path.join(System.tmp_dir!(), "group_stay_legacy_#{System.unique_integer([:positive])}.db")

    {:ok, repo} =
      Repo.start_link(
        database: db,
        name: nil,
        pool_size: 1,
        pool: DBConnection.ConnectionPool,
        log: false
      )

    Repo.put_dynamic_repo(repo)

    try do
      Ecto.Migrator.run(Repo, migrations_path(), :up, to: 20_260_826_000_003)

      seed_legacy_database!()

      Ecto.Migrator.run(Repo, migrations_path(), :up, to: 20_260_826_000_005)

      assert_room_allocations()
      assert_payments()
      assert_aggregate_balances_unchanged()
    after
      Repo.put_dynamic_repo(nil)
      GenServer.stop(repo)
      File.rm_rf(db)
    end
  end

  defp migrations_path do
    Application.app_dir(:group_stay, "priv/repo/migrations")
  end

  defp seed_legacy_database! do
    # Group "legacy-a" is active and funded by legacy cash (5000), a legacy
    # hotel-credit application (2000 from lot-1), a durable payment (1500,
    # op-pay-1), and a durable credit application (500 from lot-2,
    # op-credit-1). Its rooms hold deposits of 6000 and 3000 cents.
    insert_group!(
      id: uuid("ga"),
      group_id: "legacy-a",
      status: "active",
      revision: 3,
      lodging_total_cents: 45_000,
      deposit_due_cents: 9000,
      deposit_paid_cents: 9000,
      cash_paid_cents: 6500,
      credit_paid_cents: 2500,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0
    )

    insert_room!(id: uuid("ra"), group_id: uuid("ga"), room_id: "room-a", rate: 10_000)
    insert_room!(id: uuid("rb"), group_id: uuid("ga"), room_id: "room-b", rate: 5000)

    # Group "legacy-b" was cancelled after a refundable cash settlement of a
    # durable payment (op-pay-b).
    insert_group!(
      id: uuid("gb"),
      group_id: "legacy-b",
      status: "cancelled",
      revision: 3,
      lodging_total_cents: 30_000,
      deposit_due_cents: 6000,
      deposit_paid_cents: 4000,
      cash_paid_cents: 4000,
      credit_paid_cents: 0,
      refunded_cents: 4000,
      retained_cents: 0,
      converted_to_credit_cents: 0
    )

    insert_room!(id: uuid("rc"), group_id: uuid("gb"), room_id: "room-a", rate: 10_000)

    insert_lot!(id: uuid("lot1"), source: "cancel-old", remaining: 1300, expires: "2027-06-01")
    insert_lot!(id: uuid("lot2"), source: "cancel-old-2", remaining: 500, expires: "2027-07-01")

    # Consumption order: the legacy application was consumed first.
    insert_application!(
      id: uuid("app1"),
      group_id: uuid("ga"),
      lot_id: uuid("lot1"),
      amount: 2000
    )

    insert_application!(
      id: uuid("app2"),
      group_id: uuid("ga"),
      lot_id: uuid("lot2"),
      amount: 500
    )

    insert_operation_record!(
      "op-pay-1",
      "record_cash_payment",
      %{
        "operation_id" => "op-pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "legacy-a",
        "amount_cents" => 1500
      }
    )

    insert_operation_record!(
      "op-credit-1",
      "apply_hotel_credit",
      %{
        "operation_id" => "op-credit-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-06",
        "group_id" => "legacy-a",
        "amount_cents" => 500
      }
    )

    insert_operation_record!(
      "op-pay-b",
      "record_cash_payment",
      %{
        "operation_id" => "op-pay-b",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "legacy-b",
        "amount_cents" => 4000
      }
    )

    # A rejected payment against the cancelled group leaves no usable payment.
    insert_operation_record!(
      "op-pay-rej",
      "record_cash_payment",
      %{
        "operation_id" => "op-pay-rej",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => "legacy-b",
        "amount_cents" => 100
      },
      result: %{"status" => "rejected", "code" => "group_not_active"}
    )
  end

  defp insert_group!(opts) do
    query!(
      """
      INSERT INTO groups (id, group_id, guest_id, property_id, arrival_on, departure_on,
        booked_on, rate_plan, policy_version, status, revision, lodging_total_cents,
        deposit_due_cents, deposit_paid_cents, cash_paid_cents, credit_paid_cents,
        refunded_cents, retained_cents, converted_to_credit_cents, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        opts[:id],
        opts[:group_id],
        "guest-22",
        "ams-canal",
        "2026-12-10",
        "2026-12-13",
        "2026-10-01",
        "flexible",
        "flex-14",
        opts[:status],
        opts[:revision],
        opts[:lodging_total_cents],
        opts[:deposit_due_cents],
        opts[:deposit_paid_cents],
        opts[:cash_paid_cents],
        opts[:credit_paid_cents],
        opts[:refunded_cents],
        opts[:retained_cents],
        opts[:converted_to_credit_cents],
        now(),
        now()
      ]
    )
  end

  defp insert_room!(opts) do
    query!(
      """
      INSERT INTO rooms (id, group_id, room_id, nightly_rate_cents, position,
        inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [opts[:id], opts[:group_id], opts[:room_id], opts[:rate], position(opts), now(), now()]
    )
  end

  defp position(opts), do: opts[:position] || 1

  defp insert_lot!(opts) do
    query!(
      """
      INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents,
        expires_on, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [opts[:id], "guest-22", opts[:source], opts[:remaining], opts[:expires], now(), now()]
    )
  end

  defp insert_application!(opts) do
    query!(
      """
      INSERT INTO credit_applications (id, group_id, credit_lot_id, amount_cents,
        inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [opts[:id], opts[:group_id], opts[:lot_id], opts[:amount], now(), now()]
    )
  end

  defp insert_operation_record!(operation_id, type, payload, opts \\ []) do
    result =
      Keyword.get(opts, :result) ||
        %{
          "operation_id" => operation_id,
          "status" => "applied",
          "group_id" => payload["group_id"],
          "amount_cents" => payload["amount_cents"]
        }

    query!(
      """
      INSERT INTO operation_records (operation_id, type, payload, result,
        inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [operation_id, type, Jason.encode!(payload), Jason.encode!(result), now(), now()]
    )
  end

  defp assert_room_allocations do
    allocations = Repo.all(from a in RoomAllocation, order_by: a.position, preload: [:room])

    assert Enum.map(
             allocations,
             &{&1.position, &1.room.room_id, &1.kind, &1.amount_cents, &1.operation_id}
           ) ==
             [
               {1, "room-a", "cash", 5000, nil},
               {2, "room-a", "credit", 1000, nil},
               {3, "room-b", "credit", 1000, nil},
               {4, "room-b", "cash", 1500, "op-pay-1"},
               {5, "room-b", "credit", 500, "op-credit-1"}
             ]

    lot_ids =
      Repo.all(from l in "credit_lots", select: {l.source_operation_id, l.id}) |> Map.new()

    assert Enum.at(allocations, 1).credit_lot_id == lot_ids["cancel-old"]
    assert Enum.at(allocations, 2).credit_lot_id == lot_ids["cancel-old"]
    assert Enum.at(allocations, 4).credit_lot_id == lot_ids["cancel-old-2"]

    # Migration 000005 assigns each legacy allocation a globally comparable
    # creation sequence that respects each group's positions.
    assert allocations |> Enum.map(& &1.sequence) |> Enum.sort() == [1, 2, 3, 4, 5]

    assert room_row("legacy-a", "room-a") == %{
             "status" => "active",
             "deposit_due_cents" => 6000,
             "lodging_cents" => 30_000,
             "cash_paid_cents" => 5000,
             "credit_paid_cents" => 1000
           }

    assert room_row("legacy-a", "room-b") == %{
             "status" => "active",
             "deposit_due_cents" => 3000,
             "lodging_cents" => 15_000,
             "cash_paid_cents" => 1500,
             "credit_paid_cents" => 1500
           }

    # Rooms of a cancelled group are settled and hold no requirement.
    assert room_row("legacy-b", "room-a") == %{
             "status" => "cancelled",
             "deposit_due_cents" => 0,
             "lodging_cents" => 0,
             "cash_paid_cents" => 0,
             "credit_paid_cents" => 0
           }
  end

  defp room_row(group_ref, room_id) do
    %Exqlite.Result{rows: [[status, deposit, lodging, cash, credit]]} =
      query!(
        """
        SELECT r.status, r.deposit_due_cents, r.lodging_cents, r.cash_paid_cents,
          r.credit_paid_cents
        FROM rooms r
        JOIN groups g ON g.id = r.group_id
        WHERE g.group_id = ? AND r.room_id = ?
        """,
        [group_ref, room_id]
      )

    %{
      "status" => status,
      "deposit_due_cents" => deposit,
      "lodging_cents" => lodging,
      "cash_paid_cents" => cash,
      "credit_paid_cents" => credit
    }
  end

  defp assert_payments do
    payments = Repo.all(from(p in Payment)) |> Map.new(&{&1.operation_id, &1})

    assert Map.keys(payments) |> Enum.sort() == ["op-pay-1", "op-pay-b"]

    group_ids = Repo.all(from g in "groups", select: {g.group_id, g.id}) |> Map.new()

    assert_disposition(payments["op-pay-1"], %{
      group_id: group_ids["legacy-a"],
      recorded_cents: 1500,
      held_cents: 1500
    })

    assert_disposition(payments["op-pay-b"], %{
      group_id: group_ids["legacy-b"],
      recorded_cents: 4000,
      refunded_cents: 4000
    })
  end

  defp assert_disposition(payment, expected) do
    assert Map.take(payment, Map.keys(expected)) == expected

    disposition_fields = [
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_cents,
      :reduced_cents,
      :charged_back_cents
    ]

    assert payment
           |> Map.take(disposition_fields)
           |> Map.values()
           |> Enum.sum() == payment.recorded_cents
  end

  # Creating room allocations never changes an aggregate balance.
  defp assert_aggregate_balances_unchanged do
    %Exqlite.Result{rows: [[cash, credit, paid, refunded, retained, converted]]} =
      query!("""
      SELECT cash_paid_cents, credit_paid_cents, deposit_paid_cents, refunded_cents,
        retained_cents, converted_to_credit_cents
      FROM groups WHERE group_id = 'legacy-a'
      """)

    assert {cash, credit, paid, refunded, retained, converted} ==
             {6500, 2500, 9000, 0, 0, 0}
  end

  defp query!(sql, params \\ []), do: Repo.query!(sql, params)

  defp uuid(suffix) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
      Base.encode16(:erlang.md5(suffix), case: :lower)

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp now, do: "2026-10-01 10:00:00"
end
