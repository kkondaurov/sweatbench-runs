defmodule GroupStay.Repo.Migrations.AddRoomAndPaymentAccounting do
  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:reservation_rooms) do
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_allocations) do
      add :room_id, :string
      add :funding_operation_id, :string
    end

    create table(:cash_payment_allocations) do
      add :group_id,
          references(:group_reservations,
            column: :group_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :room_id, :string, null: false
      add :payment_operation_id, :string
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:cash_payment_allocations, [:group_id, :room_id])
    create index(:cash_payment_allocations, [:payment_operation_id])

    create table(:hotel_credit_lot_entitlements) do
      add :credit_lot_id, references(:hotel_credit_lots), null: false
      add :payment_operation_id, :string
      add :cash_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:hotel_credit_lot_entitlements, [:credit_lot_id])
    create index(:hotel_credit_lot_entitlements, [:payment_operation_id])

    flush()
    backfill_room_accounting()
  end

  def down do
    drop table(:hotel_credit_lot_entitlements)
    drop table(:cash_payment_allocations)

    alter table(:hotel_credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:reservation_rooms) do
      remove :status
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
    end
  end

  defp backfill_room_accounting do
    groups =
      repo().all(
        from(group in "group_reservations",
          select: %{
            group_id: field(group, :group_id),
            guest_id: field(group, :guest_id),
            status: field(group, :status),
            arrival_on: field(group, :arrival_on),
            departure_on: field(group, :departure_on),
            rate_plan: field(group, :rate_plan),
            lodging_total_cents: field(group, :lodging_total_cents),
            deposit_due_cents: field(group, :deposit_due_cents),
            deposit_paid_cents: field(group, :deposit_paid_cents),
            cash_paid_cents: field(group, :cash_paid_cents),
            credit_paid_cents: field(group, :credit_paid_cents),
            refunded_cents: field(group, :refunded_cents),
            retained_cents: field(group, :retained_cents),
            cash_converted_to_credit_cents: field(group, :cash_converted_to_credit_cents)
          }
        )
      )

    operations =
      repo().all(
        from(operation in "partner_operations",
          order_by: [asc: field(operation, :id)],
          select: %{
            id: field(operation, :id),
            operation_id: field(operation, :operation_id),
            operation_type: field(operation, :operation_type),
            result: field(operation, :result)
          }
        )
      )

    Enum.each(groups, fn group ->
      rooms =
        repo().all(
          from(room in "reservation_rooms",
            where: field(room, :group_id) == ^group.group_id,
            order_by: [asc: field(room, :position)],
            select: %{
              room_id: field(room, :room_id),
              nightly_rate_cents: field(room, :nightly_rate_cents),
              position: field(room, :position)
            }
          )
        )

      stay_nights = Date.diff(db_date(group.departure_on), db_date(group.arrival_on))

      rooms =
        Enum.map(rooms, fn room ->
          lodging = room.nightly_rate_cents * stay_nights

          due =
            if group.rate_plan == "flexible",
              do: div(lodging * 20 + 50, 100),
              else: lodging

          room
          |> Map.put(:lodging_cents, lodging)
          |> Map.put(:deposit_due_cents, due)
          |> Map.put(:cash_left_cents, due)
        end)

      Enum.each(rooms, fn room ->
        repo().query!(
          "UPDATE reservation_rooms SET deposit_due_cents = ?, status = ? WHERE group_id = ? AND room_id = ?",
          [
            if(group.status == "active", do: room.deposit_due_cents, else: 0),
            group.status,
            group.group_id,
            room.room_id
          ]
        )
      end)

      funding = funding_operations(operations, group.group_id)
      payment_funding = Enum.filter(funding, &(&1.type == "record_cash_payment"))
      credit_funding = Enum.filter(funding, &(&1.type == "apply_hotel_credit"))

      legacy_cash = max(group.cash_paid_cents - sum_amounts(payment_funding), 0)

      cash_sources =
        if(legacy_cash > 0, do: [%{operation_id: nil, amount: legacy_cash}], else: []) ++
          Enum.map(payment_funding, &%{operation_id: &1.operation_id, amount: &1.amount})

      credit_allocations =
        repo().all(
          from(allocation in "hotel_credit_allocations",
            join: lot in "hotel_credit_lots",
            on: field(lot, :id) == field(allocation, :credit_lot_id),
            where: field(allocation, :group_id) == ^group.group_id,
            order_by: [asc: field(allocation, :id)],
            select: %{
              id: field(allocation, :id),
              credit_lot_id: field(allocation, :credit_lot_id),
              amount_cents: field(allocation, :amount_cents)
            }
          )
        )

      legacy_credit = max(group.credit_paid_cents - sum_amounts(credit_funding), 0)

      {rooms, cash_rows, credit_rows} =
        if group.status == "active" do
          legacy_cash_source =
            if legacy_cash > 0, do: [%{operation_id: nil, amount: legacy_cash}], else: []

          legacy_credit_source =
            if legacy_credit > 0, do: [%{operation_id: nil, amount: legacy_credit}], else: []

          {rooms, legacy_cash_rows} = allocate_cash(rooms, legacy_cash_source, group)

          {rooms, legacy_credit_rows, credit_allocations} =
            allocate_credit(rooms, credit_allocations, legacy_credit_source)

          {rooms, durable_cash_rows, durable_credit_rows, _credit_allocations} =
            Enum.reduce(funding, {rooms, [], [], credit_allocations}, fn source,
                                                                         {current_rooms,
                                                                          current_cash,
                                                                          current_credit, lots} ->
              case source.type do
                "record_cash_payment" ->
                  {updated_rooms, rows} =
                    allocate_cash(
                      current_rooms,
                      [%{operation_id: source.operation_id, amount: source.amount}],
                      group
                    )

                  {updated_rooms, current_cash ++ rows, current_credit, lots}

                "apply_hotel_credit" ->
                  {updated_rooms, rows, lots} =
                    allocate_credit(current_rooms, lots, [
                      %{operation_id: source.operation_id, amount: source.amount}
                    ])

                  {updated_rooms, current_cash, current_credit ++ rows, lots}
              end
            end)

          {rooms, legacy_cash_rows ++ durable_cash_rows,
           legacy_credit_rows ++ durable_credit_rows}
        else
          {rooms, rows} = allocate_cash(rooms, cash_sources, group)
          {rooms, rows, []}
        end

      Enum.each(cash_rows, fn row ->
        repo().query!(
          "INSERT INTO cash_payment_allocations (group_id, room_id, payment_operation_id, recorded_cents, held_cents, refunded_cents, retained_cents, converted_cents, reduced_cents, charged_back_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
          [
            group.group_id,
            row.room_id,
            row.operation_id,
            row.recorded,
            row.held,
            row.refunded,
            row.retained,
            row.converted
          ]
        )
      end)

      Enum.each(credit_rows, fn row ->
        repo().query!(
          "INSERT INTO hotel_credit_allocations (credit_lot_id, group_id, amount_cents, room_id, funding_operation_id, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
          [row.credit_lot_id, group.group_id, row.amount, row.room_id, row.operation_id]
        )
      end)

      backfill_lot_entitlements(group.group_id, operations, cash_rows)

      if group.status == "active" do
        Enum.each(rooms, fn room ->
          room_cash =
            Enum.reduce(cash_rows, 0, fn row, total ->
              if row.room_id == room.room_id, do: total + row.held, else: total
            end)

          room_credit =
            Enum.reduce(credit_rows, 0, fn row, total ->
              if row.room_id == room.room_id, do: total + row.amount, else: total
            end)

          repo().query!(
            "UPDATE reservation_rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE group_id = ? AND room_id = ?",
            [room_cash, room_credit, group.group_id, room.room_id]
          )
        end)

        active_lodging = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
        active_due = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))
        active_cash = Enum.reduce(cash_rows, 0, &(&1.held + &2))
        active_credit = Enum.reduce(credit_rows, 0, &(&1.amount + &2))

        repo().query!(
          "UPDATE group_reservations SET lodging_total_cents = ?, deposit_due_cents = ?, deposit_paid_cents = ?, cash_paid_cents = ?, credit_paid_cents = ? WHERE group_id = ?",
          [
            active_lodging,
            active_due,
            active_cash + active_credit,
            active_cash,
            active_credit,
            group.group_id
          ]
        )
      else
        repo().query!(
          "UPDATE group_reservations SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0, cash_paid_cents = 0, credit_paid_cents = 0 WHERE group_id = ?",
          [group.group_id]
        )
      end

      # Preserve original credit-lot consumption order while replacing aggregate allocations
      # with room-level rows.
      Enum.each(credit_allocations, fn allocation ->
        repo().query!("DELETE FROM hotel_credit_allocations WHERE id = ?", [allocation.id])
      end)
    end)
  end

  defp funding_operations(operations, group_id) do
    Enum.flat_map(operations, fn operation ->
      result =
        case operation.result do
          result when is_map(result) -> result
          result when is_binary(result) -> Jason.decode!(result)
          _ -> %{}
        end

      if operation.operation_type in ["record_cash_payment", "apply_hotel_credit"] and
           result["status"] == "applied" and result["group_id"] == group_id and
           is_integer(result["amount_cents"]) do
        [
          %{
            operation_id: operation.operation_id,
            type: operation.operation_type,
            amount: result["amount_cents"]
          }
        ]
      else
        []
      end
    end)
  end

  defp sum_amounts(rows), do: Enum.reduce(rows, 0, &(&1.amount + &2))

  defp allocate_cash(rooms, sources, group) do
    {rooms, allocations} =
      Enum.reduce(sources, {rooms, []}, fn source, {current_rooms, allocations} ->
        {updated_rooms, rows} =
          allocate_source_cash(current_rooms, source.operation_id, source.amount)

        source_rows =
          Enum.map(rows, fn row ->
            Map.merge(row, %{operation_id: source.operation_id, recorded: row.amount})
          end)

        {updated_rooms, allocations ++ source_rows}
      end)

    rows =
      if group.status == "active" do
        Enum.map(allocations, fn row ->
          Map.merge(row, %{held: row.recorded, refunded: 0, retained: 0, converted: 0})
        end)
      else
        dispositions = [
          group.refunded_cents,
          group.retained_cents,
          group.cash_converted_to_credit_cents
        ]

        allocations
        |> Enum.map(&Map.merge(&1, %{held: 0, refunded: 0, retained: 0, converted: 0}))
        |> allocate_dispositions(dispositions)
      end

    {rooms, rows}
  end

  defp allocate_source_cash(rooms, operation_id, amount) do
    allocate_room_amount(rooms, amount, fn room, piece ->
      %{room_id: room.room_id, amount: piece, operation_id: operation_id}
    end)
  end

  defp allocate_room_amount(rooms, amount, row_fun) do
    Enum.reduce(rooms, {rooms, [], amount}, fn room, {current_rooms, rows, remaining} ->
      capacity = room.cash_left_cents
      piece = min(capacity, remaining)

      if piece > 0 do
        updated =
          Enum.map(current_rooms, fn current ->
            if current.room_id == room.room_id,
              do: %{current | cash_left_cents: current.cash_left_cents - piece},
              else: current
          end)

        {updated, rows ++ [row_fun.(room, piece)], remaining - piece}
      else
        {current_rooms, rows, remaining}
      end
    end)
    |> then(fn {updated, rows, _remaining} -> {updated, rows} end)
  end

  defp allocate_dispositions(rows, [refunded, retained, converted]) do
    {rows, refunded_left} = distribute_disposition(rows, refunded, :refunded)
    {rows, retained_left} = distribute_disposition(rows, retained, :retained)
    {rows, converted_left} = distribute_disposition(rows, converted, :converted)

    {rows, _unassigned_category} =
      distribute_disposition(rows, refunded_left + retained_left + converted_left, :retained)

    residual =
      Enum.reduce(rows, 0, fn row, total ->
        total + row.recorded - row.refunded - row.retained - row.converted
      end)

    {rows, _residual} = distribute_disposition(rows, residual, :retained)
    rows
  end

  defp distribute_disposition(rows, amount, key) do
    Enum.map_reduce(rows, amount, fn row, remaining ->
      occupied =
        Map.get(row, :refunded, 0) + Map.get(row, :retained, 0) + Map.get(row, :converted, 0)

      used = min(max(row.recorded - occupied, 0), remaining)
      {Map.put(row, key, used), remaining - used}
    end)
  end

  defp allocate_credit(rooms, allocations, sources) do
    allocations = Enum.map(allocations, &Map.put_new(&1, :remaining, &1.amount_cents))

    {rows, allocations, rooms} =
      Enum.reduce(sources, {[], allocations, rooms}, fn source, {rows, allocs, current_rooms} ->
        {new_rows, allocs, updated_rooms} = consume_credit_source(current_rooms, allocs, source)

        {rows ++ new_rows, allocs, updated_rooms}
      end)

    {rooms, rows, allocations}
  end

  defp consume_credit_source(rooms, allocations, source) do
    Enum.reduce(rooms, {[], allocations, rooms, source.amount}, fn room,
                                                                   {rows, allocs, current_rooms,
                                                                    remaining} ->
      capacity = room.cash_left_cents
      wanted = min(capacity, remaining)

      {new_rows, allocs, consumed} =
        take_credit_lots(allocs, wanted, room.room_id, source.operation_id)

      updated_rooms =
        Enum.map(current_rooms, fn current ->
          if current.room_id == room.room_id,
            do: %{current | cash_left_cents: current.cash_left_cents - consumed},
            else: current
        end)

      {rows ++ new_rows, allocs, updated_rooms, remaining - consumed}
    end)
    |> then(fn {rows, allocs, updated_rooms, _remaining} -> {rows, allocs, updated_rooms} end)
  end

  defp take_credit_lots(allocations, amount, room_id, operation_id) do
    Enum.reduce_while(allocations, {[], allocations, amount}, fn allocation,
                                                                 {rows, current, remaining} ->
      available = allocation.remaining
      piece = min(available, remaining)

      updated =
        Enum.map(current, fn item ->
          if item.id == allocation.id, do: %{item | remaining: item.remaining - piece}, else: item
        end)

      next_rows =
        if piece > 0,
          do:
            rows ++
              [
                %{
                  credit_lot_id: allocation.credit_lot_id,
                  amount: piece,
                  room_id: room_id,
                  operation_id: operation_id
                }
              ],
          else: rows

      left = remaining - piece

      if left == 0,
        do: {:halt, {next_rows, updated, 0}},
        else: {:cont, {next_rows, updated, left}}
    end)
    |> then(fn {rows, allocations, remaining} -> {rows, allocations, amount - remaining} end)
  end

  defp backfill_lot_entitlements(group_id, operations, cash_rows) do
    operation_order = Map.new(operations, &{&1.operation_id, &1.id})

    conversions =
      Enum.flat_map(operations, fn operation ->
        result =
          case operation.result do
            result when is_map(result) -> result
            result when is_binary(result) -> Jason.decode!(result)
            _ -> %{}
          end

        if operation.operation_type == "cancel_group" and result["status"] == "applied" and
             result["group_id"] == group_id and is_integer(result["credit_issued_cents"]) and
             result["credit_issued_cents"] > 0 do
          [{operation.operation_id, result["credit_issued_cents"]}]
        else
          []
        end
      end)

    Enum.each(conversions, fn {source_operation_id, _credit_issued} ->
      lot =
        repo().one(
          from(lot in "hotel_credit_lots",
            where: field(lot, :source_operation_id) == ^source_operation_id,
            select: %{id: field(lot, :id)}
          )
        )

      if lot do
        converted_sources =
          cash_rows
          |> Enum.filter(&(&1.converted > 0))
          |> Enum.group_by(& &1.operation_id, & &1.converted)
          |> Enum.map(fn {operation_id, amounts} -> {operation_id, Enum.sum(amounts)} end)
          |> Enum.sort_by(fn
            {nil, _amount} -> {0, 0}
            {operation_id, _amount} -> {1, Map.get(operation_order, operation_id, 0)}
          end)

        Enum.reduce(converted_sources, {0, 0}, fn {payment_operation_id, cash_amount},
                                                  {running_cash, running_credit} ->
          next_cash = running_cash + cash_amount
          next_credit = credit_for_cash(next_cash)
          entitlement = next_credit - running_credit

          repo().query!(
            "INSERT INTO hotel_credit_lot_entitlements (credit_lot_id, payment_operation_id, cash_cents, entitlement_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
            [lot.id, payment_operation_id, cash_amount, entitlement]
          )

          {next_cash, next_credit}
        end)
      end
    end)
  end

  defp credit_for_cash(0), do: 0
  defp credit_for_cash(cash_cents), do: cash_cents + div(cash_cents * 10 + 50, 100)

  defp db_date(%Date{} = date), do: date
  defp db_date(date) when is_binary(date), do: Date.from_iso8601!(date)
end
