defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentCorrections do
  use Ecto.Migration

  def up do
    alter table(:ledger) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:rooms) do
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    create table(:room_funding_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_position, :integer, null: false
      add :source_kind, :string, null: false
      add :source_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :amount_cents, :integer, null: false
    end

    create index(:room_funding_allocations, [:group_id, :room_position])
    create index(:room_funding_allocations, [:source_operation_id])

    create table(:cash_payment_records, primary_key: false) do
      add :operation_id, :string, primary_key: true

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payment_records, [:group_id])

    create table(:credit_lot_contributions) do
      add :credit_lot_id,
          references(:credit_lots, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
    end

    create index(:credit_lot_contributions, [:payment_operation_id])

    execute("""
    UPDATE rooms
    SET lodging_cents = nightly_rate_cents *
      CAST(julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
           julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.group_id = rooms.group_id) = 'advance_purchase'
            THEN nightly_rate_cents * CAST(julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
                                            julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER)
          ELSE CAST((nightly_rate_cents * CAST(julianday((SELECT departure_on FROM groups WHERE groups.group_id = rooms.group_id)) -
                                                  julianday((SELECT arrival_on FROM groups WHERE groups.group_id = rooms.group_id)) AS INTEGER) * 20 + 50) / 100 AS INTEGER)
    END,
        status = (SELECT status FROM groups WHERE groups.group_id = rooms.group_id)
    """)

    flush()
    backfill(repo())
  end

  def backfill(repo) do
    operations =
      repo.query!(
        "SELECT id, operation_id, type, payload, result FROM operation_records ORDER BY id"
      ).rows
      |> Enum.map(fn [id, operation_id, type, payload, result] ->
        %{
          commit: id,
          operation_id: operation_id,
          type: type,
          payload: decode_json(payload),
          result: decode_json(result)
        }
      end)

    repo.query!(
      "SELECT group_id, status, rate_plan, arrival_on, departure_on, cash_paid_cents, credit_paid_cents, deposit_paid_cents FROM groups"
    ).rows
    |> Enum.each(fn [
                      group_id,
                      status,
                      rate_plan,
                      arrival_on,
                      departure_on,
                      cash_paid,
                      credit_paid,
                      deposit_paid
                    ] ->
      nights = Date.diff(to_date(departure_on), to_date(arrival_on))
      rooms = backfill_rooms(repo, group_id, status, rate_plan, nights)
      cash_operations = applied_operations(operations, "record_cash_payment", group_id)
      credit_operations = applied_operations(operations, "apply_hotel_credit", group_id)

      Enum.each(cash_operations, fn operation ->
        amount = map_value(operation.result, "amount_cents")
        settlement = settlement_for_group(operations, group_id)

        {refunded, retained, converted} =
          if status == "active" do
            {0, 0, 0}
          else
            case settlement do
              %{refund_method: "hotel_credit"} -> {0, 0, amount}
              %{refunded_cents: refunded} when refunded > 0 -> {amount, 0, 0}
              _ -> {0, amount, 0}
            end
          end

        held = if status == "active", do: amount, else: 0

        insert_cash_payment(
          repo,
          operation.operation_id,
          group_id,
          amount,
          held,
          refunded,
          retained,
          converted
        )
      end)

      if status == "active" do
        durable_cash =
          Enum.reduce(cash_operations, 0, &(&2 + map_value(&1.result, "amount_cents")))

        legacy_cash = max((cash_paid || deposit_paid || 0) - durable_cash, 0)

        {rooms, _remaining} =
          allocate_source(repo, group_id, rooms, "legacy_cash", nil, nil, legacy_cash)

        lots = current_credit_lots(repo, group_id)

        durable_credit =
          Enum.reduce(credit_operations, 0, &(&2 + map_value(&1.result, "amount_cents")))

        legacy_credit = max((credit_paid || 0) - durable_credit, 0)

        {rooms, lots, _remaining} =
          allocate_credit_source(repo, group_id, rooms, lots, nil, legacy_credit)

        Enum.reduce(
          Enum.filter(operations, fn operation ->
            operation.type in ["record_cash_payment", "apply_hotel_credit"] and
              map_value(operation.result, "status") == "applied" and
              map_value(operation.result, "group_id") == group_id
          end),
          {rooms, lots},
          fn operation, {rooms, lots} ->
            case operation.type do
              "record_cash_payment" ->
                {rooms, _remaining} =
                  allocate_source(
                    repo,
                    group_id,
                    rooms,
                    "cash_payment",
                    operation.operation_id,
                    nil,
                    map_value(operation.result, "amount_cents")
                  )

                {rooms, lots}

              "apply_hotel_credit" ->
                {rooms, lots, _remaining} =
                  allocate_credit_source(
                    repo,
                    group_id,
                    rooms,
                    lots,
                    operation.operation_id,
                    map_value(operation.result, "amount_cents")
                  )

                {rooms, lots}
            end
          end
        )
      end
    end)

    backfill_credit_contributions(repo, operations)
  end

  defp backfill_rooms(repo, group_id, status, rate_plan, nights) do
    repo.query!(
      "SELECT position, room_id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position",
      [group_id]
    ).rows
    |> Enum.map(fn [position, room_id, nightly_rate] ->
      lodging = nightly_rate * nights

      deposit_due =
        if rate_plan == "advance_purchase", do: lodging, else: div(lodging * 20 + 50, 100)

      repo.query!(
        """
        UPDATE rooms
        SET lodging_cents = ?, deposit_due_cents = ?, status = ?, cash_paid_cents = 0, credit_paid_cents = 0
        WHERE group_id = ? AND position = ?
        """,
        [lodging, deposit_due, status, group_id, position]
      )

      %{
        position: position,
        room_id: room_id,
        deposit_due_cents: deposit_due,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      }
    end)
  end

  defp allocate_source(
         repo,
         group_id,
         rooms,
         source_kind,
         source_operation_id,
         credit_lot_id,
         amount
       ) do
    {rooms, remaining} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
        allocation = min(capacity, remaining)

        if allocation > 0 do
          repo.query!(
            """
            INSERT INTO room_funding_allocations
              (group_id, room_position, source_kind, source_operation_id, credit_lot_id, amount_cents)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [group_id, room.position, source_kind, source_operation_id, credit_lot_id, allocation]
          )

          field = if source_kind == "credit", do: "credit_paid_cents", else: "cash_paid_cents"

          repo.query!(
            "UPDATE rooms SET #{field} = #{field} + ? WHERE group_id = ? AND position = ?",
            [allocation, group_id, room.position]
          )
        end

        paid_field = if source_kind == "credit", do: :credit_paid_cents, else: :cash_paid_cents

        {Map.put(room, paid_field, Map.get(room, paid_field) + allocation),
         remaining - allocation}
      end)

    {rooms, remaining}
  end

  defp allocate_credit_source(repo, group_id, rooms, lots, source_operation_id, amount) do
    {lots, rooms, remaining} =
      Enum.reduce(lots, {[], rooms, amount}, fn {lot_id, available},
                                                {used_lots, rooms, remaining} ->
        allocation = min(available, remaining)

        {rooms, _remaining} =
          allocate_source(
            repo,
            group_id,
            rooms,
            "credit",
            source_operation_id,
            lot_id,
            allocation
          )

        {[{lot_id, available - allocation} | used_lots], rooms, remaining - allocation}
      end)

    {rooms, Enum.reverse(lots), remaining}
  end

  defp current_credit_lots(repo, group_id) do
    repo.query!(
      "SELECT credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY id",
      [group_id]
    ).rows
    |> Enum.map(fn [lot_id, amount] -> {lot_id, amount} end)
  end

  defp insert_cash_payment(
         repo,
         operation_id,
         group_id,
         amount,
         held,
         refunded,
         retained,
         converted
       ) do
    repo.query!(
      """
      INSERT OR IGNORE INTO cash_payment_records
        (operation_id, group_id, recorded_cents, held_cents, refunded_cents, retained_cents,
         converted_to_credit_cents, reduced_cents, charged_back_cents)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)
      """,
      [operation_id, group_id, amount, held, refunded, retained, converted]
    )
  end

  defp backfill_credit_contributions(repo, operations) do
    repo.query!("SELECT id, source_operation_id FROM credit_lots").rows
    |> Enum.each(fn [lot_id, source_operation_id] ->
      case Enum.find(operations, &(&1.operation_id == source_operation_id)) do
        %{type: type, result: result, commit: cancellation_commit}
        when type in ["cancel_group", "cancel_rooms"] ->
          group_id = map_value(result, "group_id")
          cash_operations = applied_operations(operations, "record_cash_payment", group_id)
          cash_operations = Enum.filter(cash_operations, &(&1.commit < cancellation_commit))

          durable_cash =
            Enum.reduce(cash_operations, 0, &(&2 + map_value(&1.result, "amount_cents")))

          total_cash =
            case repo.query!("SELECT cash_paid_cents FROM groups WHERE group_id = ?", [group_id]).rows do
              [[cash_paid]] when is_integer(cash_paid) -> cash_paid
              _ -> durable_cash
            end

          sources =
            [
              {nil, max(total_cash - durable_cash, 0)}
              | Enum.map(cash_operations, fn operation ->
                  {operation.operation_id, map_value(operation.result, "amount_cents")}
                end)
            ]
            |> Enum.filter(fn {_source, principal} -> principal > 0 end)

          {_, _} =
            Enum.reduce(sources, {0, 0}, fn {payment_operation_id, principal},
                                            {previous_cash, previous_value} ->
              current_cash = previous_cash + principal
              current_value = current_cash + div(current_cash * 10 + 50, 100)
              entitlement = current_value - previous_value

              repo.query!(
                """
                INSERT INTO credit_lot_contributions (credit_lot_id, payment_operation_id, principal_cents, entitlement_cents)
                VALUES (?, ?, ?, ?)
                """,
                [lot_id, payment_operation_id, principal, entitlement]
              )

              {current_cash, current_value}
            end)

        _ ->
          :ok
      end
    end)
  end

  defp applied_operations(operations, type, group_id) do
    Enum.filter(operations, fn operation ->
      operation.type == type and map_value(operation.result, "status") == "applied" and
        map_value(operation.result, "group_id") == group_id
    end)
  end

  defp settlement_for_group(operations, group_id) do
    operations
    |> Enum.find(fn operation ->
      operation.type in ["cancel_group", "cancel_rooms"] and
        map_value(operation.result, "status") == "applied" and
        map_value(operation.result, "group_id") == group_id
    end)
    |> case do
      nil ->
        nil

      operation ->
        %{
          refund_method:
            if(is_binary(map_value(operation.payload, "refund_method")),
              do: map_value(operation.payload, "refund_method"),
              else: "cash"
            ),
          refunded_cents: map_value(operation.result, "refunded_cents") || 0
        }
    end
  end

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(_value), do: %{}

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key), 0)
        rescue
          ArgumentError -> 0
        end
    end
  end

  defp map_value(_map, _key), do: 0

  defp to_date(%Date{} = date), do: date
  defp to_date(date), do: Date.from_iso8601!(to_string(date))

  def down do
    drop table(:credit_lot_contributions)
    drop table(:cash_payment_records)
    drop table(:room_funding_allocations)

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :status
      remove :deposit_due_cents
      remove :lodging_cents
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:ledger) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end
end
