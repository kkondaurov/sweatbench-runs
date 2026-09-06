defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  alias GroupStay.Repo

  def change do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    # Rooms carry the lodging and deposit amounts already used to calculate
    # the group requirement.
    execute(
      """
      UPDATE rooms SET deposit_due_cents =
        CASE (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id)
          WHEN 'advance_purchase' THEN rooms.nightly_rate_cents * (
            CAST(julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER) -
            CAST(julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER))
          ELSE (rooms.nightly_rate_cents * (
            CAST(julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER) -
            CAST(julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id)) AS INTEGER))
            * 20 + 50) / 100
        END
      """,
      ""
    )

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      # "cash" or "credit"
      add :kind, :string, null: false
      # The funding operation this portion came from; nil for the unattributed
      # senior block that predates durable operation records.
      add :source_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :amount_cents, :integer, null: false
      add :fill_order, :integer, null: false

      timestamps()
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:payment_dispositions) do
      add :payment_operation_id, :string, null: false
      add :group_id, :string, null: false
      add :recorded_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:payment_dispositions, [:payment_operation_id])

    create table(:lot_contributions) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :fill_order, :integer, null: false

      timestamps()
    end

    create index(:lot_contributions, [:credit_lot_id])

    execute(&backfill/0, &noop/0)

    drop table(:credit_applications)
  end

  defp noop, do: :ok

  # Brings pre-existing funding forward as room allocations without changing
  # any aggregate cash, credit, or liability balance:
  #
  #   * every durably recorded applied cash payment gets a disposition row so
  #     it stays reconcilable; for already cancelled groups its cash is
  #     classified with the group's settlement outcome;
  #   * active groups keep their held cash and credit on their rooms,
  #     allocated as one unattributed senior block first (aggregate cash,
  #     then hotel-credit applications in consumption order), followed by
  #     durably recorded applied payments in commit order.
  defp backfill do
    now = timestamp()

    {:ok, group_rows} =
      Repo.query("""
        SELECT id, group_id, status, cash_paid_cents, credit_paid_cents,
               refunded_cents, retained_cents, cash_converted_to_credit_cents
        FROM groups
        ORDER BY id
      """)

    durable_cash_payments = durable_applied_payments()

    Enum.each(group_rows.rows, fn [
                                    db_id,
                                    group_id,
                                    status,
                                    cash_paid,
                                    _credit_paid,
                                    refunded,
                                    retained,
                                    converted
                                  ] ->
      {own_payments, _other_payments} =
        Enum.split_with(durable_cash_payments, fn {_op, paid_group_id, _amount} ->
          paid_group_id == group_id
        end)

      if status == "active" and (cash_paid || 0) > 0 do
        {:ok, room_rows} =
          Repo.query(
            """
            SELECT id, deposit_due_cents, cash_paid_cents, credit_paid_cents
            FROM rooms WHERE group_id = ? AND status = 'active' ORDER BY position
            """,
            [db_id]
          )

        rooms =
          Enum.map(room_rows.rows, fn [id, due, cash, credit] ->
            %{id: id, capacity: max((due || 0) - cash - credit, 0)}
          end)

        durable_total =
          Enum.reduce(own_payments, 0, fn {_op, _gid, amount}, sum -> sum + amount end)

        legacy_cash = max((cash_paid || 0) - durable_total, 0)

        {order, rooms} = allocate!(db_id, rooms, legacy_cash, "cash", nil, nil, 1, now)

        {:ok, credit_rows} =
          Repo.query(
            "SELECT credit_lot_id, amount_cents FROM credit_applications WHERE group_id = ? ORDER BY id",
            [db_id]
          )

        {order, rooms} =
          Enum.reduce(credit_rows.rows, {order, rooms}, fn [lot_id, amount], acc ->
            {order, rooms} = acc
            allocate!(db_id, rooms, amount, "credit", nil, lot_id, order, now)
          end)

        Enum.reduce(own_payments, {order, rooms}, fn {op_id, _gid, amount}, acc ->
          {order, rooms} = acc
          allocate!(db_id, rooms, amount, "cash", op_id, nil, order, now)
        end)
      end
    end)

    create_dispositions(group_rows.rows, durable_cash_payments, now)
  end

  # Every durably recorded applied cash payment becomes a reconcilable
  # disposition. Payments of still-active groups are entirely held; payments
  # of already cancelled groups settled exactly once before this release, so
  # each moved entirely to that settlement's outcome.
  defp create_dispositions(group_rows, durable_cash_payments, now) do
    groups_by_id =
      Map.new(group_rows, fn [
                               _db_id,
                               group_id,
                               status,
                               _cash,
                               _credit,
                               refunded,
                               retained,
                               converted
                             ] ->
        {group_id, {status, refunded, retained, converted}}
      end)

    Enum.each(durable_cash_payments, fn {op_id, group_id, amount} ->
      {refunded_cents, retained_cents, converted_cents} =
        case Map.fetch(groups_by_id, group_id) do
          {:ok, {status, refunded, retained, converted}} ->
            classify_settled(status, amount, refunded, retained, converted)

          :error ->
            {0, 0, 0}
        end

      Repo.query!(
        """
        INSERT INTO payment_dispositions
          (payment_operation_id, group_id, recorded_cents, refunded_cents,
           retained_cents, converted_cents, reduced_cents, charged_back_cents,
           inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?)
        """,
        [op_id, group_id, amount, refunded_cents, retained_cents, converted_cents, now, now]
      )
    end)
  end

  # A cancelled group settled exactly once before this release, so each of its
  # recorded payments moved entirely to that settlement's outcome.
  defp classify_settled("active", _amount, _refunded, _retained, _converted), do: {0, 0, 0}

  defp classify_settled(_cancelled, amount, refunded, retained, converted) do
    remaining = amount
    refund_part = min(remaining, refunded || 0)
    remaining = remaining - refund_part
    retained_part = min(remaining, retained || 0)
    remaining = remaining - retained_part
    converted_part = min(remaining, converted || 0)

    {refund_part, retained_part, converted_part}
  end

  # Applied record_cash_payment operations in durable-record commit order.
  defp durable_applied_payments do
    {:ok, rows} =
      Repo.query(
        """
        SELECT operation_id, result FROM operation_records
        WHERE type = 'record_cash_payment' ORDER BY id
        """,
        []
      )

    Enum.flat_map(rows.rows, fn [operation_id, result] ->
      case Jason.decode(result) do
        {:ok, %{"status" => "applied", "group_id" => group_id, "amount_cents" => amount}}
        when is_binary(group_id) and is_integer(amount) ->
          [{operation_id, group_id, amount}]

        _ ->
          []
      end
    end)
  end

  # Allocates `amount` across `rooms` in fill order, updating room counters and
  # inserting allocation rows. Returns {next_fill_order, updated_rooms}.
  defp allocate!(group_db_id, rooms, amount, kind, source_op, lot_id, order, now) do
    {rooms_rev, order, leftover} =
      Enum.reduce(rooms, {[], order, amount}, fn room, {acc, order, remaining} ->
        cond do
          remaining <= 0 or room.capacity <= 0 ->
            {[room | acc], order, max(remaining, 0)}

          true ->
            take = min(room.capacity, remaining)
            insert_allocation!(group_db_id, room.id, kind, source_op, lot_id, take, order, now)
            bump_room_counters!(room.id, kind, take)

            {[%{room | capacity: room.capacity - take} | acc], order + 1, remaining - take}
        end
      end)

    # Defensive: an unallocatable remainder lands on the last active room so
    # room counters keep summing to the totals they were derived from.
    {order, rooms} =
      if leftover > 0 do
        case Enum.reverse(rooms_rev) do
          [] ->
            {order, []}

          rooms ->
            {rooms_before_last, [last]} = Enum.split(rooms, length(rooms) - 1)

            insert_allocation!(
              group_db_id,
              last.id,
              kind,
              source_op,
              lot_id,
              leftover,
              order,
              now
            )

            bump_room_counters!(last.id, kind, leftover)

            rooms_before_last ++ [Map.update!(last, :capacity, &max(&1 - leftover, 0))]
        end
        |> then(fn rooms -> {order + 1, rooms} end)
      else
        {order, Enum.reverse(rooms_rev)}
      end

    {order, rooms}
  end

  defp insert_allocation!(group_db_id, room_id, kind, source_op, lot_id, amount, order, now) do
    Repo.query!(
      """
      INSERT INTO room_allocations
        (group_id, room_id, kind, source_operation_id, credit_lot_id,
         amount_cents, fill_order, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [group_db_id, room_id, kind, source_op, lot_id, amount, order, now, now]
    )
  end

  defp bump_room_counters!(room_id, "cash", take) do
    Repo.query!(
      "UPDATE rooms SET cash_paid_cents = cash_paid_cents + ? WHERE id = ?",
      [take, room_id]
    )
  end

  defp bump_room_counters!(room_id, "credit", take) do
    Repo.query!(
      "UPDATE rooms SET credit_paid_cents = credit_paid_cents + ? WHERE id = ?",
      [take, room_id]
    )
  end

  defp timestamp do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> to_string()
  end
end
