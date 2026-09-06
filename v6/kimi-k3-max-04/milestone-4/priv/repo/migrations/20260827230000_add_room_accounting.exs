defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  @moduledoc """
  Room-level accounting and payment reductions (docs/requests/04).

  Rooms gain a status, their own deposit requirement, and held cash/credit
  totals. Held cash is tracked per funding operation in `cash_allocations`
  (insertion order is fill order), credit applications gain room attribution,
  per-payment dispositions are kept in `payment_dispositions`, and credit lots
  record per-payment entitlements plus any unrecovered clawback.

  Existing funding predates room allocations. It is brought forward without
  changing any aggregate cash, credit, or liability balance: per group, the
  funding with no durable operation record becomes one unattributed senior
  block (aggregate cash first, then hotel-credit lots in original consumption
  order), followed by funding represented by durable operation records in
  commit order.
  """
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all)
    end

    # The integer primary key is the SQLite ROWID, so insertion order
    # preserves the fill order of allocations.
    create table(:cash_allocations, primary_key: false) do
      add :id, :integer, primary_key: true

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :operation_id, :string
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:operation_id])

    create table(:payment_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :string, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:payment_dispositions, [:operation_id])

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false

      add :operation_id, :string
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_entitlements, [:lot_id])
    create index(:credit_entitlements, [:operation_id])

    flush()

    backfill_room_accounting()
  end

  def down do
    # Room-level settlement history is lossy going down: cancelled groups get
    # their totals recomputed from their rooms, with paid cash approximated by
    # the settled amounts (the cash/credit split of old settlements is gone).
    for group <-
          query(
            "SELECT id, arrival_on, departure_on, rate_plan, refunded_cents, retained_cents, converted_cents FROM groups WHERE status = 'cancelled'"
          ) do
      rooms = query("SELECT nightly_rate_cents FROM rooms WHERE group_id = ?", [group.id])
      nights = Date.diff(group.departure_on, group.arrival_on)

      {lodging, due} =
        Enum.reduce(rooms, {0, 0}, fn room, {l, d} ->
          room_lodging = room.nightly_rate_cents * nights
          {l + room_lodging, d + room_deposit(room_lodging, group.rate_plan)}
        end)

      settled =
        (group.refunded_cents || 0) + (group.retained_cents || 0) + (group.converted_cents || 0)

      repo().query!(
        "UPDATE groups SET lodging_total_cents = ?, deposit_due_cents = ?, deposit_paid_cents = ?, cash_paid_cents = ?, credit_paid_cents = 0 WHERE id = ?",
        [lodging, due, settled, settled, group.id]
      )
    end

    drop(index(:credit_entitlements, [:operation_id]))
    drop(index(:credit_entitlements, [:lot_id]))
    drop(table(:credit_entitlements))
    drop(unique_index(:payment_dispositions, [:operation_id]))
    drop(table(:payment_dispositions))
    drop(index(:cash_allocations, [:operation_id]))
    drop(index(:cash_allocations, [:room_id]))
    drop(index(:cash_allocations, [:group_id]))
    drop(table(:cash_allocations))

    alter table(:credit_applications) do
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :reduced_cents
      remove :charged_back_cents
    end

    alter table(:rooms) do
      remove :status
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  # --- Backfill ---------------------------------------------------------------

  defp backfill_room_accounting do
    records = funding_records()
    now = timestamp()

    for group <- query("SELECT * FROM groups") do
      nights = Date.diff(group.departure_on, group.arrival_on)

      rooms =
        "SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position"
        |> query([group.id])
        |> Enum.map(fn room ->
          lodging = room.nightly_rate_cents * nights
          Map.merge(room, %{deposit_due_cents: room_deposit(lodging, group.rate_plan)})
        end)

      if group.status == "cancelled" do
        # Cancelled groups settled everything: no active rooms, so the group
        # totals that describe active rooms become zero.
        for room <- rooms do
          repo().query!(
            "UPDATE rooms SET status = 'cancelled', deposit_due_cents = ? WHERE id = ?",
            [room.deposit_due_cents, room.id]
          )
        end

        repo().query!(
          "UPDATE groups SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0, cash_paid_cents = 0, credit_paid_cents = 0 WHERE id = ?",
          [group.id]
        )
      else
        backfill_active_group(group, rooms, records, now)
      end
    end
  end

  defp backfill_active_group(group, rooms, records, now) do
    group_records = Enum.filter(records, &(&1.group_id == group.group_id))
    durable_cash = records_total(group_records, "record_cash_payment")
    durable_credit = records_total(group_records, "apply_hotel_credit")

    # Funding with no durable operation record is one unattributed senior
    # block, allocated before any durable-record funding.
    senior_cash = max(group.cash_paid_cents - durable_cash, 0)
    senior_credit = max(group.credit_paid_cents - durable_credit, 0)

    applications =
      query(
        """
        SELECT a.lot_id AS lot_id, a.amount_cents AS amount_cents
        FROM credit_applications a JOIN credit_lots l ON l.id = a.lot_id
        WHERE a.group_id = ?
        ORDER BY l.expires_on, l.source_operation_id, a.id
        """,
        [group.id]
      )

    {senior_lots, remaining_lots} = take_lots(applications, senior_credit)

    {durable_chunks, _leftover_lots} =
      Enum.map_reduce(group_records, remaining_lots, fn record, lots ->
        if record.type == "apply_hotel_credit" do
          {chunks, lots} = take_lots(lots, record.amount_cents)
          {Enum.map(chunks, fn {lot_id, amount} -> {:credit, lot_id, amount} end), lots}
        else
          {[{:cash, record.operation_id, record.amount_cents}], lots}
        end
      end)

    chunks =
      cash_chunk(nil, senior_cash) ++
        Enum.map(senior_lots, fn {lot_id, amount} -> {:credit, lot_id, amount} end) ++
        List.flatten(durable_chunks)

    # Applications are rewritten with room attribution.
    repo().query!("DELETE FROM credit_applications WHERE group_id = ?", [group.id])

    room_state =
      Map.new(rooms, fn room -> {room.id, %{due: room.deposit_due_cents, cash: 0, credit: 0}} end)

    room_state =
      Enum.reduce(chunks, room_state, fn chunk, state ->
        allocate_chunk(group, chunk, rooms, state, now)
      end)

    for room <- rooms do
      state = room_state[room.id]

      repo().query!(
        "UPDATE rooms SET deposit_due_cents = ?, cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
        [state.due, state.cash, state.credit, room.id]
      )
    end

    # Durable applied cash payments gain their disposition ledger entry.
    for record <- group_records, record.type == "record_cash_payment" do
      repo().query!(
        """
        INSERT INTO payment_dispositions
          (id, operation_id, refunded_cents, retained_cents, converted_cents, reduced_cents, charged_back_cents, inserted_at, updated_at)
        VALUES (?, ?, 0, 0, 0, 0, 0, ?, ?)
        """,
        [Ecto.UUID.generate(), record.operation_id, now, now]
      )
    end
  end

  defp cash_chunk(_operation_id, 0), do: []
  defp cash_chunk(operation_id, amount), do: [{:cash, operation_id, amount}]

  # Durable applied funding operations in commit (durable record) order,
  # classified by the retained type. `occurred_on` is deliberately ignored.
  defp funding_records do
    "SELECT id, operation_id, type, request FROM operation_records WHERE status = 'applied' AND type IN ('record_cash_payment', 'apply_hotel_credit') ORDER BY id"
    |> query()
    |> Enum.map(fn row ->
      request = Jason.decode!(row.request)

      %{
        operation_id: row.operation_id,
        type: row.type,
        group_id: request["group_id"],
        amount_cents: request["amount_cents"]
      }
    end)
  end

  defp records_total(records, type) do
    records
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  # Takes `amount` cents from the front of the lot-ordered applications,
  # splitting a row when it is only partially taken. Returns the taken
  # `{lot_id, amount}` chunks and the remaining applications.
  defp take_lots(applications, amount) do
    {taken, _left, rest} =
      Enum.reduce(applications, {[], amount, []}, fn app, {taken, left, rest} ->
        cond do
          left <= 0 ->
            {taken, left, [app | rest]}

          app.amount_cents <= left ->
            {[{app.lot_id, app.amount_cents} | taken], left - app.amount_cents, rest}

          true ->
            {[{app.lot_id, left} | taken], 0,
             [%{app | amount_cents: app.amount_cents - left} | rest]}
        end
      end)

    {Enum.reverse(taken), Enum.reverse(rest)}
  end

  # Allocates one funding chunk to the rooms in their original order, filling
  # one room's deposit before moving to the next.
  defp allocate_chunk(group, chunk, rooms, state, now) do
    {state, _left} =
      Enum.reduce(rooms, {state, chunk_amount(chunk)}, fn room, {state, left} ->
        room_state = state[room.id]
        take = min(room_state.due - room_state.cash - room_state.credit, left)

        if take <= 0 do
          {state, left}
        else
          persist_chunk(group, room, chunk, take, now)
          {Map.put(state, room.id, bump(room_state, chunk, take)), left - take}
        end
      end)

    state
  end

  defp chunk_amount({:cash, _operation_id, amount}), do: amount
  defp chunk_amount({:credit, _lot_id, amount}), do: amount

  defp bump(room_state, {:cash, _, _}, take), do: %{room_state | cash: room_state.cash + take}

  defp bump(room_state, {:credit, _, _}, take),
    do: %{room_state | credit: room_state.credit + take}

  defp persist_chunk(group, room, {:cash, operation_id, _amount}, take, now) do
    repo().query!(
      "INSERT INTO cash_allocations (group_id, room_id, operation_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      [group.id, room.id, operation_id, take, now, now]
    )
  end

  defp persist_chunk(group, room, {:credit, lot_id, _amount}, take, now) do
    repo().query!(
      "INSERT INTO credit_applications (id, lot_id, group_id, room_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [Ecto.UUID.generate(), lot_id, group.id, room.id, take, now, now]
    )
  end

  # Percentage deposit with the standard half-up rounding, matching Money.
  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents
  defp room_deposit(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)

  defp timestamp do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
  end

  defp query(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {column, value} -> {String.to_atom(column), decode_value(column, value)} end)
    end)
  end

  defp decode_value(column, value) do
    if String.ends_with?(column, "_on") and is_binary(value) do
      Date.from_iso8601!(value)
    else
      value
    end
  end
end
