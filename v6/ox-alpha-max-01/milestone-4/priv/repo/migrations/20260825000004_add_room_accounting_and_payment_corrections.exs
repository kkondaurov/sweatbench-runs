defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections do
  use Ecto.Migration

  alias GroupStay.Repo

  @flexible_percent 20

  def change do
    alter table(:rooms) do
      add :status, :text, null: false, default: "active"
      # Each room's own deposit requirement: a rounded 20% of its lodging for
      # flexible rooms, the full lodging amount for advance-purchase rooms.
      add :deposit_due_cents, :integer
    end

    # Attributes cash facts to the durable partner operation that caused them;
    # NULL marks funding from before durable operation records existed.
    alter table(:ledger_entries) do
      add :operation_id, :text
    end

    alter table(:credit_lots) do
      # Clawback entitlement that could not be removed from a lot's balance
      # because the credit had already been spent.
      add :clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_fundings) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      # The durable funding operation (record_cash_payment or
      # apply_hotel_credit); NULL for the unattributed legacy block.
      add :operation_id, :text
      # Set for credit fundings so cancellations can restore the amounts.
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:room_fundings, [:group_id, :kind])
    create index(:room_fundings, [:room_id])
    create index(:room_fundings, [:operation_id])
    create index(:room_fundings, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :text, null: false
      add :cents, :integer, null: false

      timestamps()
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    backfill_room_accounting()
  end

  # Rooms existed before this release with every room active and funding that
  # predates durable operation records. Compute each room's deposit
  # requirement and bring the unattributed funding forward as the senior
  # block per active group: aggregate cash first, then hotel-credit lots in
  # original consumption order, filling rooms in their original order.
  # Public so tests can exercise the legacy backfill against seeded
  # pre-release data.
  def backfill_room_accounting do
    now = strftime_now()

    groups =
      Repo.query!(
        "SELECT id, rate_plan, arrival_on, departure_on, status FROM groups ORDER BY id",
        []
      )

    for [id, rate_plan, arrival, departure, status] <- groups.rows do
      backfill_group(id, rate_plan, arrival, departure, status, now)
    end

    :ok
  end

  defp backfill_group(id, rate_plan, arrival, departure, status, now) do
    nights = date_diff_days(arrival, departure)

    rooms =
      Repo.query!(
        "SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position",
        [id]
      ).rows

    cancelled_group? = status == "cancelled"

    capacities =
      Enum.map(rooms, fn [room_id, rate] ->
        due =
          if rate_plan == "advance_purchase",
            do: rate,
            else: div(rate * nights * @flexible_percent + 50, 100)

        new_status = if cancelled_group?, do: "cancelled", else: "active"

        Repo.query!(
          "UPDATE rooms SET status = ?, deposit_due_cents = ? WHERE id = ?",
          [new_status, due, room_id]
        )

        {room_id, due}
      end)

    if not cancelled_group? do
      cash_pool =
        Repo.query!(
          "SELECT coalesce(sum(amount_cents), 0) FROM ledger_entries
           WHERE group_id = ? AND kind = 'payment'",
          [id]
        ).rows
        |> hd()
        |> hd()

      # The senior block continues where the previous slice stopped:
      # aggregate cash first, then each credit lot in consumption order.
      capacities =
        fill_rooms(capacities, cash_pool, fn room_id, amount ->
          insert_funding(id, room_id, "cash", nil, nil, amount, now)
        end)

      credit_fundings =
        Repo.query!(
          "SELECT credit_lot_id, amount_cents FROM credit_fundings
           WHERE group_id = ? ORDER BY id",
          [id]
        ).rows

      Enum.reduce(credit_fundings, capacities, fn [lot_id, amount], caps ->
        fill_rooms(caps, amount, fn room_id, part ->
          insert_funding(id, room_id, "credit", nil, lot_id, part, now)
        end)
      end)
    end

    :ok
  end

  # Fills successive rooms up to their deposit requirement until the pool is
  # exhausted; the pool never exceeds the total capacity by construction.
  # Returns the remaining capacities so successive pools continue where the
  # previous one stopped.
  defp fill_rooms([{room_id, capacity} | rest], pool, insert) when pool > 0 do
    take = min(capacity, pool)

    if take <= 0 do
      [{room_id, capacity} | fill_rooms(rest, pool, insert)]
    else
      insert.(room_id, take)
      [{room_id, capacity - take} | fill_rooms(rest, pool - take, insert)]
    end
  end

  defp fill_rooms(rooms, _pool, _insert), do: rooms

  defp insert_funding(group_id, room_id, kind, operation_id, lot_id, amount, now) do
    Repo.query!(
      "INSERT INTO room_fundings
       (group_id, room_id, kind, operation_id, credit_lot_id, amount_cents, inserted_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [group_id, room_id, kind, operation_id, lot_id, amount, now, now]
    )
  end

  defp date_diff_days(%Date{} = from, %Date{} = to), do: Date.diff(to, from)

  defp date_diff_days(from, to),
    do: Date.diff(to_date(to), to_date(from))

  defp to_date(%Date{} = date), do: date
  defp to_date(date) when is_binary(date), do: Date.from_iso8601!(date)

  defp strftime_now, do: NaiveDateTime.to_iso8601(NaiveDateTime.utc_now()) <> "Z"
end
