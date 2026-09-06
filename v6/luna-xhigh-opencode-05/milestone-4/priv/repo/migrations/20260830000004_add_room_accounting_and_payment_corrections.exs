defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:group_rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :original_group_id, references(:groups, column: :group_id, type: :string), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payments, [:original_group_id])

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:room_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    create table(:legacy_cash_fundings, primary_key: false) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          primary_key: true

      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
    end
  end

  def down do
    drop table(:legacy_cash_fundings)
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:cash_payments)

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_cents
      remove :status
    end
  end

  def backfill do
    query!(
      "UPDATE credit_lots SET issued_on = date(expires_on, '-365 day') WHERE issued_on IS NULL",
      []
    )

    query!(
      "UPDATE credit_lots SET unrecovered_clawback_cents = 0 WHERE unrecovered_clawback_cents IS NULL",
      []
    )

    query!("DELETE FROM credit_entitlements", [])

    groups =
      rows(
        """
        SELECT group_id, rate_plan, booked_on, arrival_on, departure_on, status,
               cash_paid_cents, credit_paid_cents, refunded_cents, retained_cents,
               cash_converted_to_credit_cents
        FROM groups
        """,
        [
          :group_id,
          :rate_plan,
          :booked_on,
          :arrival_on,
          :departure_on,
          :status,
          :cash_paid_cents,
          :credit_paid_cents,
          :refunded_cents,
          :retained_cents,
          :cash_converted_to_credit_cents
        ]
      )

    records = durable_records()
    cash_records = Enum.filter(records, &(&1.type == "record_cash_payment"))
    credit_records = Enum.filter(records, &(&1.type == "apply_hotel_credit"))

    group_map =
      Map.new(groups, fn row ->
        {row.group_id,
         %{
           id: row.group_id,
           rate_plan: row.rate_plan,
           booked_on: parse_date!(row.booked_on),
           arrival_on: parse_date!(row.arrival_on),
           departure_on: parse_date!(row.departure_on),
           status: row.status,
           cash_paid: row.cash_paid_cents,
           credit_paid: row.credit_paid_cents,
           refunded: row.refunded_cents,
           retained: row.retained_cents,
           converted: row.cash_converted_to_credit_cents
         }}
      end)

    durable_cash_by_group = sum_by_group(cash_records)
    durable_credit_by_group = sum_by_group(credit_records)

    Enum.each(cash_records, fn record ->
      case Map.get(group_map, record.group_id) do
        nil -> :ok
        group -> insert_cash_payment(record, group)
      end
    end)

    Enum.each(group_map, fn {group_id, group} ->
      legacy_cash = max(group.cash_paid - Map.get(durable_cash_by_group, group_id, 0), 0)

      if legacy_cash > 0 do
        insert_legacy_cash(group, legacy_cash)
      end

      backfill_group_rooms(
        group,
        legacy_cash,
        cash_records,
        credit_records,
        group_map,
        durable_cash_by_group,
        durable_credit_by_group
      )
    end)

    backfill_credit_entitlements(group_map, records, cash_records, durable_cash_by_group)
  end

  defp backfill_group_rooms(
         group,
         legacy_cash,
         cash_records,
         credit_records,
         _group_map,
         _durable_cash_by_group,
         durable_credit_by_group
       ) do
    rooms =
      rows(
        """
        SELECT id, room_id, nightly_rate_cents, position
        FROM group_rooms
        WHERE group_id = ?
        ORDER BY position
        """,
        [:id, :room_id, :nightly_rate_cents, :position],
        [group.id]
      )
      |> Enum.map(fn row ->
        lodging = row.nightly_rate_cents * Date.diff(group.departure_on, group.arrival_on)

        deposit =
          case group.rate_plan do
            "advance_purchase" -> lodging
            _ -> round_percentage(lodging, 20, 100)
          end

        %{id: row.id, due: deposit, cash: 0, credit: 0, lodging: lodging}
      end)

    query!("UPDATE group_rooms SET status = ? WHERE group_id = ?", [group.status, group.id])

    if group.status == "active" do
      existing_credit =
        rows(
          """
            SELECT id, credit_lot_id, amount_cents
            FROM credit_allocations
            WHERE group_id = ?
            ORDER BY id
          """,
          [:id, :credit_lot_id, :amount_cents],
          [group.id]
        )
        |> Enum.map(&{&1.credit_lot_id, &1.amount_cents})

      query!("DELETE FROM credit_allocations WHERE group_id = ?", [group.id])
      query!("DELETE FROM cash_allocations WHERE group_id = ?", [group.id])

      state = %{group_id: group.id, rooms: rooms}

      state = allocate_cash(group.id, state, legacy_cash, nil)

      legacy_credit = max(group.credit_paid - Map.get(durable_credit_by_group, group.id, 0), 0)
      {segments, state} = allocate_credit(state, existing_credit, legacy_credit, nil)

      group_records =
        (cash_records ++ credit_records)
        |> Enum.filter(&(&1.group_id == group.id))
        |> Enum.filter(&(&1.type in ["record_cash_payment", "apply_hotel_credit"]))
        |> Enum.sort_by(& &1.commit_order)

      {_segments, final_state} =
        Enum.reduce(group_records, {segments, state}, fn record, {segments, state} ->
          amount = record.amount

          case record.type do
            "record_cash_payment" ->
              {segments, allocate_cash(group.id, state, amount, record.operation_id)}

            "apply_hotel_credit" ->
              {new_segments, new_state} =
                allocate_credit(state, segments, amount, record.operation_id)

              {new_segments, new_state}
          end
        end)

      Enum.each(rooms_for_update(final_state), fn room ->
        query!(
          """
          UPDATE group_rooms
          SET lodging_cents = ?, deposit_due_cents = ?, cash_paid_cents = ?, credit_paid_cents = ?
          WHERE id = ?
          """,
          [room.lodging, room.due, room.cash, room.credit, room.id]
        )
      end)
    else
      Enum.each(rooms, fn room ->
        query!(
          """
          UPDATE group_rooms
          SET lodging_cents = ?, deposit_due_cents = ?, cash_paid_cents = 0, credit_paid_cents = 0
          WHERE id = ?
          """,
          [room.lodging, room.due, room.id]
        )
      end)
    end

    :ok
  end

  defp allocate_cash(_group_id, state, amount, _operation_id) when amount <= 0, do: state

  defp allocate_cash(group_id, state, amount, operation_id) do
    {rooms, _remaining} =
      Enum.map_reduce(state.rooms, amount, fn room, remaining ->
        capacity = max(room.due - room.cash - room.credit, 0)
        allocated = min(capacity, remaining)

        if allocated > 0 do
          query!(
            """
            INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents)
            VALUES (?, ?, ?, ?)
            """,
            [group_id, room.id, operation_id, allocated]
          )
        end

        {%{room | cash: room.cash + allocated}, remaining - allocated}
      end)

    %{state | rooms: rooms}
  end

  defp allocate_credit(state, segments, amount, _operation_id) when amount <= 0,
    do: {segments, state}

  defp allocate_credit(state, segments, amount, operation_id) do
    {taken, remaining_segments} = consume_segments(segments, amount)

    state =
      Enum.reduce(taken, state, fn {lot_id, segment_amount}, state ->
        {rooms, _remaining} =
          Enum.map_reduce(state.rooms, segment_amount, fn room, remaining ->
            capacity = max(room.due - room.cash - room.credit, 0)
            allocated = min(capacity, remaining)

            if allocated > 0 do
              query!(
                """
                INSERT INTO credit_allocations
                  (group_id, credit_lot_id, room_id, amount_cents, funding_operation_id)
                VALUES (?, ?, ?, ?, ?)
                """,
                [room_group_id(room, state), lot_id, room.id, allocated, operation_id]
              )
            end

            {%{room | credit: room.credit + allocated}, remaining - allocated}
          end)

        %{state | rooms: rooms}
      end)

    {remaining_segments, state}
  end

  defp room_group_id(_room, state), do: state.group_id

  defp rooms_for_update(%{rooms: rooms}), do: rooms

  defp consume_segments(segments, amount) do
    {taken, _remaining} =
      Enum.map_reduce(segments, amount, fn {lot_id, available}, remaining ->
        allocated = min(available, remaining)
        {{lot_id, allocated}, remaining - allocated}
      end)

    {Enum.reject(taken, fn {_lot_id, amount} -> amount == 0 end),
     Enum.zip(segments, taken)
     |> Enum.map(fn {{lot_id, available}, {_same_lot, allocated}} ->
       {lot_id, available - allocated}
     end)
     |> Enum.reject(fn {_lot_id, amount} -> amount == 0 end)}
  end

  defp insert_cash_payment(record, group) do
    {held, refunded, retained, converted} =
      if group.status == "active" do
        {record.amount, 0, 0, 0}
      else
        cond do
          group.refunded > 0 -> {0, record.amount, 0, 0}
          group.retained > 0 -> {0, 0, record.amount, 0}
          group.converted > 0 -> {0, 0, 0, record.amount}
          true -> {0, 0, 0, 0}
        end
      end

    query!(
      """
      INSERT OR IGNORE INTO cash_payments
        (payment_operation_id, original_group_id, recorded_cents, held_cents,
         refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents, charged_back_cents)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)
      """,
      [record.operation_id, group.id, record.amount, held, refunded, retained, converted]
    )
  end

  defp insert_legacy_cash(group, amount) do
    {held, refunded, retained, converted} =
      if group.status == "active" do
        {amount, 0, 0, 0}
      else
        cond do
          group.refunded > 0 -> {0, amount, 0, 0}
          group.retained > 0 -> {0, 0, amount, 0}
          group.converted > 0 -> {0, 0, 0, amount}
          true -> {0, 0, 0, 0}
        end
      end

    query!(
      """
      INSERT OR IGNORE INTO legacy_cash_fundings
        (group_id, recorded_cents, held_cents, refunded_cents, retained_cents, converted_to_credit_cents)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [group.id, amount, held, refunded, retained, converted]
    )
  end

  defp backfill_credit_entitlements(group_map, records, cash_records, durable_cash_by_group) do
    Enum.each(
      rows("SELECT id, source_operation_id FROM credit_lots", [:id, :source_operation_id]),
      fn lot ->
        cancellation =
          Enum.find(
            records,
            &(&1.operation_id == lot.source_operation_id and &1.type == "cancel_group")
          )

        with %{group_id: group_id} <- cancellation,
             group when not is_nil(group) <- Map.get(group_map, group_id),
             converted when converted > 0 <- group.converted do
          sources =
            [
              {nil, max(group.cash_paid - Map.get(durable_cash_by_group, group_id, 0), 0)}
              | cash_records
                |> Enum.filter(&(&1.group_id == group_id))
                |> Enum.sort_by(& &1.commit_order)
                |> Enum.map(&{&1.operation_id, &1.amount})
            ]

          {sources, _remaining} = take_sources(sources, converted)
          insert_entitlements(lot.id, sources)
        else
          _ -> :ok
        end
      end
    )
  end

  defp take_sources(sources, amount) do
    Enum.map_reduce(sources, amount, fn {source, available}, remaining ->
      used = min(available, remaining)
      {{source, used}, remaining - used}
    end)
  end

  defp insert_entitlements(lot_id, sources) do
    {_running, _previous} =
      Enum.reduce(sources, {0, 0}, fn {source, amount}, {running, previous} ->
        next = running + amount

        entitlement =
          round_percentage(next, 10, 100) + next - (round_percentage(running, 10, 100) + running)

        if entitlement > 0 do
          query!(
            """
            INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents)
            VALUES (?, ?, ?)
            """,
            [lot_id, source, entitlement]
          )
        end

        {next, previous + entitlement}
      end)
  end

  defp durable_records do
    rows(
      """
      SELECT id, operation_id, operation_type, result
      FROM operation_records
      ORDER BY id
      """,
      [:commit_order, :operation_id, :operation_type, :result]
    )
    |> Enum.flat_map(fn row ->
      result = Jason.decode!(row.result)

      if result["status"] == "applied" and is_binary(result["group_id"]) do
        [
          %{
            commit_order: row.commit_order,
            operation_id: row.operation_id,
            type: row.operation_type,
            group_id: result["group_id"],
            amount: result["amount_cents"] || 0
          }
        ]
      else
        []
      end
    end)
  end

  defp sum_by_group(records) do
    records
    |> Enum.group_by(& &1.group_id)
    |> Map.new(fn {group_id, group_records} ->
      {group_id, Enum.reduce(group_records, 0, &(&1.amount + &2))}
    end)
  end

  defp parse_date!(date), do: Date.from_iso8601!(date)

  defp round_percentage(amount, numerator, denominator) do
    quotient = div(amount * numerator, denominator)
    remainder = rem(amount * numerator, denominator)
    if remainder * 2 >= denominator, do: quotient + 1, else: quotient
  end

  defp query!(sql, params), do: repo().query!(sql, params)

  defp rows(sql, columns, params \\ []) do
    query!(sql, params).rows
    |> Enum.map(&Map.new(Enum.zip(columns, &1)))
  end
end
