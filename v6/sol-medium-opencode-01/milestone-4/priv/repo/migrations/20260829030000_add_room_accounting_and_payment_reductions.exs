defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    execute("""
    UPDATE rooms
    SET lodging_total_cents = nightly_rate_cents * (
          SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
          FROM groups WHERE groups.id = rooms.group_id
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'flexible'
            THEN CAST((nightly_rate_cents * (
                   SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
                   FROM groups WHERE groups.id = rooms.group_id
                 )) / 5 AS INTEGER)
                 + CASE WHEN CAST((nightly_rate_cents * (
                     SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
                     FROM groups WHERE groups.id = rooms.group_id
                   )) AS INTEGER) % 5 >= 3 THEN 1 ELSE 0 END
          ELSE nightly_rate_cents * (
            SELECT CAST(julianday(groups.departure_on) - julianday(groups.arrival_on) AS INTEGER)
            FROM groups WHERE groups.id = rooms.group_id
          )
        END,
        status = CASE
          WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_id) = 'cancelled'
            THEN 'cancelled'
          ELSE 'active'
        END
    """)

    create table(:payment_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payment_dispositions, [:payment_operation_id])
    create index(:payment_dispositions, [:group_id])

    create table(:cash_allocations) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false

      add :payment_disposition_id,
          references(:payment_dispositions, type: :binary_id, on_delete: :delete_all)

      add :amount_cents, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_disposition_id, :id])

    drop unique_index(:credit_allocations, [:credit_lot_id, :group_id])

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all)
      add :application_operation_id, :string
      add :position, :integer
    end

    create index(:credit_allocations, [:room_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:conversion_contributions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :payment_disposition_id,
          references(:payment_dispositions, type: :binary_id, on_delete: :delete_all)

      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :position, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversion_contributions, [:payment_disposition_id])

    # Existing aggregate funding predates the allocation model. It is deliberately
    # carried forward as the senior, unattributed block without changing balances.
    execute(&backfill_existing_funding/0)
  end

  def down do
    drop table(:conversion_contributions)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop index(:credit_allocations, [:room_id])

    execute("""
    UPDATE credit_allocations
    SET amount_cents = (
      SELECT SUM(other.amount_cents)
      FROM credit_allocations AS other
      WHERE other.credit_lot_id = credit_allocations.credit_lot_id
        AND other.group_id = credit_allocations.group_id
    )
    WHERE id = (
      SELECT MIN(other.id)
      FROM credit_allocations AS other
      WHERE other.credit_lot_id = credit_allocations.credit_lot_id
        AND other.group_id = credit_allocations.group_id
    )
    """)

    execute("""
    DELETE FROM credit_allocations
    WHERE id != (
      SELECT MIN(other.id)
      FROM credit_allocations AS other
      WHERE other.credit_lot_id = credit_allocations.credit_lot_id
        AND other.group_id = credit_allocations.group_id
    )
    """)

    alter table(:credit_allocations) do
      remove :room_id
      remove :application_operation_id
      remove :position
    end

    create unique_index(:credit_allocations, [:credit_lot_id, :group_id])
    drop table(:cash_allocations)
    drop table(:payment_dispositions)

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  defp backfill_existing_funding do
    repo = repo()

    groups =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT id, cash_paid_cents, credit_paid_cents, status, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents FROM groups",
        []
      ).rows

    Enum.each(groups, fn [group_id, cash, credit, status, refunded, retained, converted] ->
      rooms =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT id, deposit_due_cents FROM rooms WHERE group_id = ? ORDER BY position",
          [group_id]
        ).rows

      operations = durable_funding(repo, group_id)

      payments =
        insert_payment_dispositions(
          repo,
          group_id,
          operations,
          status,
          refunded,
          retained,
          converted
        )

      if status == "active" do
        backfill_active_group(repo, group_id, rooms, cash, credit, operations, payments)
      else
        backfill_conversion_contributions(repo, group_id, cash, converted, operations, payments)
      end
    end)
  end

  defp durable_funding(repo, group_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT operation_id, operation_type, json_extract(submission, '$.amount_cents')
      FROM partner_operations
      WHERE json_extract(submission, '$.group_id') = ?
        AND json_extract(result, '$.status') = 'applied'
        AND operation_type IN ('record_cash_payment', 'apply_hotel_credit')
      ORDER BY id
      """,
      [group_id]
    ).rows
  end

  defp insert_payment_dispositions(
         repo,
         group_id,
         operations,
         status,
         refunded,
         retained,
         converted
       ) do
    classification =
      cond do
        status == "active" -> nil
        refunded > 0 -> "refunded_cents"
        retained > 0 -> "retained_cents"
        converted > 0 -> "converted_cents"
        true -> nil
      end

    operations
    |> Enum.filter(fn [_id, type, _amount] -> type == "record_cash_payment" end)
    |> Map.new(fn [operation_id, _type, amount] ->
      id = Ecto.UUID.generate()
      fields = if classification, do: ", #{classification}", else: ""
      values = if classification, do: ", ?", else: ""
      params = [id, operation_id, group_id, amount] ++ if(classification, do: [amount], else: [])

      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO payment_dispositions (id, payment_operation_id, group_id, recorded_cents#{fields}, inserted_at, updated_at) VALUES (?, ?, ?, ?#{values}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
        params
      )

      {operation_id, id}
    end)
  end

  defp backfill_active_group(repo, group_id, rooms, cash, credit, operations, payments) do
    durable_cash = sum_type(operations, "record_cash_payment")
    durable_credit = sum_type(operations, "apply_hotel_credit")
    legacy_cash = max(cash - durable_cash, 0)
    legacy_credit = max(credit - durable_credit, 0)

    credit_sources =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY inserted_at, id",
        [group_id]
      ).rows

    Ecto.Adapters.SQL.query!(repo, "DELETE FROM credit_allocations WHERE group_id = ?", [group_id])

    events =
      optional_event({:cash, nil, legacy_cash}) ++
        optional_event({:credit, nil, legacy_credit}) ++
        Enum.map(operations, fn [operation_id, type, amount] ->
          case type do
            "record_cash_payment" -> {:cash, Map.fetch!(payments, operation_id), amount}
            "apply_hotel_credit" -> {:credit, operation_id, amount}
          end
        end)

    room_state = Enum.map(rooms, fn [id, due] -> %{id: id, due: due, cash: 0, credit: 0} end)

    {room_state, remaining_sources, _position} =
      Enum.reduce(events, {room_state, credit_sources, 0}, fn event, state ->
        allocate_event(repo, group_id, event, state)
      end)

    if Enum.sum(Enum.map(remaining_sources, &List.last/1)) != 0,
      do: raise("could not classify existing credit allocations")

    Enum.each(room_state, fn room ->
      Ecto.Adapters.SQL.query!(
        repo,
        "UPDATE rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
        [room.cash, room.credit, room.id]
      )
    end)
  end

  defp allocate_event(repo, _group_id, {:cash, payment_id, amount}, {rooms, sources, position}) do
    {rooms, remaining} = allocate_cash_event(repo, rooms, payment_id, amount, [])
    if remaining != 0, do: raise("could not backfill cash allocations")
    {rooms, sources, position}
  end

  defp allocate_event(repo, group_id, {:credit, operation_id, amount}, {rooms, sources, position}) do
    {rooms, sources, remaining, position} =
      allocate_credit_event(repo, group_id, rooms, sources, operation_id, amount, position)

    if remaining != 0, do: raise("could not backfill credit allocations")
    {rooms, sources, position}
  end

  defp allocate_cash_event(_repo, rooms, _payment_id, 0, acc),
    do: {Enum.reverse(acc) ++ rooms, 0}

  defp allocate_cash_event(_repo, [], _payment_id, amount, acc),
    do: {Enum.reverse(acc), amount}

  defp allocate_cash_event(repo, [room | rooms], payment_id, amount, acc) do
    capacity = room.due - room.cash - room.credit
    applied = min(capacity, amount)

    if applied > 0 do
      Ecto.Adapters.SQL.query!(
        repo,
        "INSERT INTO cash_allocations (room_id, payment_disposition_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
        [room.id, payment_id, applied]
      )
    end

    allocate_cash_event(repo, rooms, payment_id, amount - applied, [
      %{room | cash: room.cash + applied} | acc
    ])
  end

  defp allocate_credit_event(repo, group_id, rooms, sources, operation_id, amount, position) do
    case {amount, rooms, sources} do
      {0, _, _} ->
        {rooms, sources, 0, position}

      {_, [], _} ->
        {[], sources, amount, position}

      {_, _, []} ->
        {rooms, [], amount, position}

      {_, [room | rest], [[lot_id, source_amount] | source_rest]} ->
        capacity = room.due - room.cash - room.credit

        if capacity == 0 do
          {updated, sources, remaining, position} =
            allocate_credit_event(repo, group_id, rest, sources, operation_id, amount, position)

          {[room | updated], sources, remaining, position}
        else
          applied = min(amount, min(capacity, source_amount))
          id = Ecto.UUID.generate()

          Ecto.Adapters.SQL.query!(
            repo,
            "INSERT INTO credit_allocations (id, credit_lot_id, group_id, room_id, application_operation_id, position, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
            [id, lot_id, group_id, room.id, operation_id, position, applied]
          )

          next_sources =
            if applied == source_amount,
              do: source_rest,
              else: [[lot_id, source_amount - applied] | source_rest]

          updated_room = %{room | credit: room.credit + applied}
          next_rooms = if applied == capacity, do: rest, else: [updated_room | rest]

          {updated, sources, remaining, position} =
            allocate_credit_event(
              repo,
              group_id,
              next_rooms,
              next_sources,
              operation_id,
              amount - applied,
              position + 1
            )

          updated = if applied == capacity, do: [updated_room | updated], else: updated
          {updated, sources, remaining, position}
        end
    end
  end

  defp optional_event({_type, _id, 0}), do: []
  defp optional_event(event), do: [event]

  defp sum_type(operations, type) do
    operations
    |> Enum.filter(fn [_id, operation_type, _amount] -> operation_type == type end)
    |> Enum.sum_by(&List.last/1)
  end

  defp backfill_conversion_contributions(repo, group_id, cash, converted, operations, payments)
       when converted > 0 do
    lots =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT credit_lots.id
        FROM credit_lots
        JOIN partner_operations ON partner_operations.operation_id = credit_lots.source_operation_id
        WHERE json_extract(partner_operations.submission, '$.group_id') = ?
          AND partner_operations.operation_type IN ('cancel_group', 'cancel_rooms')
        ORDER BY partner_operations.id
        """,
        [group_id]
      ).rows

    case lots do
      [[lot_id]] ->
        durable =
          operations
          |> Enum.filter(fn [_id, type, _amount] -> type == "record_cash_payment" end)
          |> Enum.map(fn [operation_id, _type, amount] ->
            {Map.fetch!(payments, operation_id), amount}
          end)

        legacy = max(cash - Enum.sum(Enum.map(durable, &elem(&1, 1))), 0)
        contributions = if(legacy > 0, do: [{nil, legacy}], else: []) ++ durable

        Enum.reduce(Enum.with_index(contributions), 0, fn {{payment_id, principal}, position},
                                                          running ->
          entitlement = with_bonus(running + principal) - with_bonus(running)

          Ecto.Adapters.SQL.query!(
            repo,
            "INSERT INTO conversion_contributions (id, credit_lot_id, payment_disposition_id, principal_cents, entitlement_cents, position, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
            [Ecto.UUID.generate(), lot_id, payment_id, principal, entitlement, position]
          )

          running + principal
        end)

      _ ->
        raise("could not identify existing converted-credit lot")
    end
  end

  defp backfill_conversion_contributions(
         _repo,
         _group_id,
         _cash,
         _converted,
         _operations,
         _payments
       ),
       do: :ok

  defp with_bonus(cash), do: cash + div(cash * 10 + 50, 100)
end
