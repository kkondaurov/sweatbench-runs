defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :operation_id, :string
    end

    create table(:room_funding_allocations) do
      add :group_reservation_id,
          references(:group_reservations, on_delete: :delete_all),
          null: false

      add :group_room_id, references(:group_rooms, on_delete: :nilify_all)
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)

      add :credit_application_id,
          references(:credit_applications, on_delete: :nilify_all)

      add :funding_type, :string, null: false
      add :payment_operation_id, :string
      add :status, :string, null: false
      add :amount_cents, :integer, null: false
      add :credit_entitlement_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:room_funding_allocations, [:group_reservation_id, :funding_type, :status])
    create index(:room_funding_allocations, [:group_room_id, :funding_type, :status])

    create index(:room_funding_allocations, [
             :payment_operation_id,
             :funding_type,
             :status
           ])

    create index(:room_funding_allocations, [:credit_lot_id, :funding_type, :status])

    execute("""
    UPDATE group_rooms
    SET
      lodging_total_cents = CAST(
        (julianday((SELECT departure_on FROM group_reservations WHERE id = group_rooms.group_reservation_id)) -
         julianday((SELECT arrival_on FROM group_reservations WHERE id = group_rooms.group_reservation_id))) *
        nightly_rate_cents AS INTEGER
      ),
      deposit_due_cents = CASE
        WHEN (SELECT rate_plan FROM group_reservations WHERE id = group_rooms.group_reservation_id) = 'advance_purchase'
          THEN CAST(
            (julianday((SELECT departure_on FROM group_reservations WHERE id = group_rooms.group_reservation_id)) -
             julianday((SELECT arrival_on FROM group_reservations WHERE id = group_rooms.group_reservation_id))) *
            nightly_rate_cents AS INTEGER
          )
        ELSE CAST((
          CAST(
            (julianday((SELECT departure_on FROM group_reservations WHERE id = group_rooms.group_reservation_id)) -
             julianday((SELECT arrival_on FROM group_reservations WHERE id = group_rooms.group_reservation_id))) *
            nightly_rate_cents AS INTEGER
          ) * 20 + 50
        ) / 100 AS INTEGER)
      END,
      status = CASE
        WHEN (SELECT status FROM group_reservations WHERE id = group_rooms.group_reservation_id) = 'active'
          THEN 'active'
        ELSE 'cancelled'
      END
    """)

    flush()
    backfill_existing_accounting()
  end

  def down do
    drop index(:room_funding_allocations, [:credit_lot_id, :funding_type, :status])

    drop index(:room_funding_allocations, [
           :payment_operation_id,
           :funding_type,
           :status
         ])

    drop index(:room_funding_allocations, [:group_room_id, :funding_type, :status])
    drop index(:room_funding_allocations, [:group_reservation_id, :funding_type, :status])
    drop table(:room_funding_allocations)

    alter table(:credit_applications) do
      remove :operation_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  # The previous release tracked active funding only as group-level totals. Preserve that funding
  # as a senior unattributed block, then append durable payments/applications in their commit order.
  # This runs once during migration, so reads never need to mutate legacy data.
  defp backfill_existing_accounting do
    migration_repo = repo()

    active_groups =
      migration_repo.query!(
        "SELECT id, group_id, cash_paid_cents, credit_paid_cents FROM group_reservations WHERE status = 'active'"
      ).rows

    Enum.each(active_groups, fn [
                                  group_reservation_id,
                                  external_group_id,
                                  cash_paid_cents,
                                  credit_paid_cents
                                ] ->
      rooms = rooms_for(migration_repo, group_reservation_id)

      durable_operations =
        migration_repo.query!("""
        SELECT id, operation_id, operation_type, result
        FROM partner_operations
        WHERE operation_type IN ('record_cash_payment', 'apply_hotel_credit')
        ORDER BY id
        """).rows
        |> Enum.flat_map(fn [id, operation_id, type, result] ->
          case decode_result(result) do
            {:ok,
             %{
               "status" => "applied",
               "group_id" => ^external_group_id,
               "amount_cents" => amount_cents
             }}
            when is_integer(amount_cents) and amount_cents > 0 ->
              [%{id: id, operation_id: operation_id, type: type, amount_cents: amount_cents}]

            _ ->
              []
          end
        end)

      durable_cash =
        durable_operations
        |> Enum.filter(&(&1.type == "record_cash_payment"))
        |> Enum.sum_by(& &1.amount_cents)
        |> min(cash_paid_cents)

      legacy_cash = cash_paid_cents - durable_cash

      {rooms, _} =
        allocate_cash(migration_repo, group_reservation_id, rooms, legacy_cash, nil, "held")

      applications = credit_applications_for(migration_repo, group_reservation_id)

      legacy_applications =
        partition_credit_applications(
          migration_repo,
          applications,
          durable_operations,
          credit_paid_cents
        )

      {rooms, _} =
        allocate_credit_applications(
          migration_repo,
          group_reservation_id,
          rooms,
          legacy_applications
        )

      Enum.reduce(durable_operations, rooms, fn operation, current_rooms ->
        case operation.type do
          "record_cash_payment" ->
            {updated_rooms, _} =
              allocate_cash(
                migration_repo,
                group_reservation_id,
                current_rooms,
                operation.amount_cents,
                operation.operation_id,
                "held"
              )

            updated_rooms

          "apply_hotel_credit" ->
            operation_applications =
              credit_applications_for_operation(
                migration_repo,
                group_reservation_id,
                operation.operation_id
              )

            {updated_rooms, _} =
              allocate_credit_applications(
                migration_repo,
                group_reservation_id,
                current_rooms,
                operation_applications
              )

            updated_rooms
        end
      end)
    end)

    cancelled_groups =
      migration_repo.query!("""
      SELECT id, cash_paid_cents, refunded_cents, retained_cents, cash_converted_to_credit_cents
      FROM group_reservations
      WHERE status = 'cancelled'
      """).rows

    Enum.each(cancelled_groups, fn [group_id, paid, refunded, retained, converted] ->
      statuses = [
        {"refunded", refunded},
        {"retained", retained},
        {"converted", converted}
      ]

      recorded = Enum.sum_by(statuses, &elem(&1, 1))

      statuses =
        if recorded < paid do
          statuses ++ [{"retained", paid - recorded}]
        else
          statuses
        end

      Enum.each(statuses, fn {status, amount_cents} ->
        if amount_cents > 0 do
          insert_allocation(migration_repo, %{
            group_reservation_id: group_id,
            funding_type: "cash",
            status: status,
            amount_cents: amount_cents
          })
        end
      end)
    end)
  end

  defp rooms_for(migration_repo, group_id) do
    migration_repo.query!(
      """
      SELECT id, position, deposit_due_cents, cash_paid_cents, credit_paid_cents
      FROM group_rooms
      WHERE group_reservation_id = ? AND status = 'active'
      ORDER BY position
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [id, position, deposit_due_cents, cash_paid_cents, credit_paid_cents] ->
      %{
        id: id,
        position: position,
        deposit_due_cents: deposit_due_cents,
        cash_paid_cents: cash_paid_cents,
        credit_paid_cents: credit_paid_cents
      }
    end)
  end

  defp decode_result(result) when is_map(result), do: {:ok, result}
  defp decode_result(result) when is_binary(result), do: Jason.decode(result)
  defp decode_result(_result), do: :error

  defp credit_applications_for(migration_repo, group_id) do
    migration_repo.query!(
      """
      SELECT id, credit_lot_id, amount_cents
      FROM credit_applications
      WHERE group_reservation_id = ?
      ORDER BY id
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [id, credit_lot_id, amount_cents] ->
      %{id: id, credit_lot_id: credit_lot_id, amount_cents: amount_cents}
    end)
  end

  defp partition_credit_applications(
         migration_repo,
         applications,
         durable_operations,
         credit_paid_cents
       ) do
    durable_credit_operations =
      Enum.filter(durable_operations, &(&1.type == "apply_hotel_credit"))

    durable_amount =
      min(Enum.sum_by(durable_credit_operations, & &1.amount_cents), credit_paid_cents)

    legacy_amount = credit_paid_cents - durable_amount
    {legacy_applications, remaining} = take_amount(applications, legacy_amount)

    unmatched_applications =
      Enum.reduce(durable_credit_operations, remaining, fn operation, pending ->
        {operation_applications, rest} = take_amount(pending, operation.amount_cents)

        if Enum.sum_by(operation_applications, & &1.amount_cents) == operation.amount_cents do
          Enum.each(operation_applications, fn application ->
            migration_repo.query!(
              "UPDATE credit_applications SET operation_id = ? WHERE id = ?",
              [
                operation.operation_id,
                application.id
              ]
            )
          end)

          rest
        else
          pending
        end
      end)

    legacy_applications ++ unmatched_applications
  end

  defp take_amount(applications, amount_cents) do
    Enum.reduce_while(applications, {[], [], amount_cents}, fn application,
                                                               {taken, rest, remaining} ->
      cond do
        remaining == 0 ->
          {:cont, {taken, [application | rest], remaining}}

        application.amount_cents <= remaining ->
          {:cont, {[application | taken], rest, remaining - application.amount_cents}}

        true ->
          # Applications are written once per redemption, so a release boundary falls between
          # whole rows. Treat an inconsistent historical row as legacy rather than inventing an
          # operation attribution that could later make a chargeback targetable incorrectly.
          {:halt, {taken, [application | rest], remaining}}
      end
    end)
    |> then(fn {taken, rest, _remaining} -> {Enum.reverse(taken), Enum.reverse(rest)} end)
  end

  defp credit_applications_for_operation(migration_repo, group_id, operation_id) do
    migration_repo.query!(
      """
      SELECT id, credit_lot_id, amount_cents
      FROM credit_applications
      WHERE group_reservation_id = ? AND operation_id = ?
      ORDER BY id
      """,
      [group_id, operation_id]
    ).rows
    |> Enum.map(fn [id, credit_lot_id, amount_cents] ->
      %{id: id, credit_lot_id: credit_lot_id, amount_cents: amount_cents}
    end)
  end

  defp allocate_cash(_migration_repo, _group_id, rooms, 0, _operation_id, _status), do: {rooms, 0}

  defp allocate_cash(migration_repo, group_id, rooms, amount_cents, operation_id, status) do
    allocate_to_rooms(rooms, amount_cents, fn room, allocation_cents ->
      insert_allocation(migration_repo, %{
        group_reservation_id: group_id,
        group_room_id: room.id,
        funding_type: "cash",
        payment_operation_id: operation_id,
        status: status,
        amount_cents: allocation_cents
      })

      migration_repo.query!(
        "UPDATE group_rooms SET cash_paid_cents = cash_paid_cents + ? WHERE id = ?",
        [allocation_cents, room.id]
      )
    end)
  end

  defp allocate_credit_applications(_migration_repo, _group_id, rooms, []), do: {rooms, 0}

  defp allocate_credit_applications(migration_repo, group_id, rooms, applications) do
    Enum.reduce(applications, {rooms, 0}, fn application, {current_rooms, total} ->
      {updated_rooms, allocated} =
        allocate_to_rooms(current_rooms, application.amount_cents, fn room, allocation_cents ->
          insert_allocation(migration_repo, %{
            group_reservation_id: group_id,
            group_room_id: room.id,
            credit_lot_id: application.credit_lot_id,
            credit_application_id: application.id,
            funding_type: "credit",
            status: "held",
            amount_cents: allocation_cents
          })

          migration_repo.query!(
            "UPDATE group_rooms SET credit_paid_cents = credit_paid_cents + ? WHERE id = ?",
            [allocation_cents, room.id]
          )
        end)

      {updated_rooms, total + allocated}
    end)
  end

  defp allocate_to_rooms(rooms, amount_cents, callback) do
    {updated_rooms, remaining} =
      Enum.map_reduce(rooms, amount_cents, fn room, remaining ->
        outstanding = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        allocation_cents = min(max(outstanding, 0), remaining)

        if allocation_cents > 0, do: callback.(room, allocation_cents)

        {room, remaining - allocation_cents}
      end)

    # Reloading the compact room state is simpler and less error-prone than having the cash/credit
    # callback encode which counter it changed.
    updated_rooms =
      Enum.map(updated_rooms, fn room ->
        [cash_paid_cents, credit_paid_cents] =
          repo().query!(
            "SELECT cash_paid_cents, credit_paid_cents FROM group_rooms WHERE id = ?",
            [room.id]
          ).rows
          |> hd()

        %{room | cash_paid_cents: cash_paid_cents, credit_paid_cents: credit_paid_cents}
      end)

    {updated_rooms, amount_cents - remaining}
  end

  defp insert_allocation(migration_repo, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    columns = [
      :group_reservation_id,
      :group_room_id,
      :credit_lot_id,
      :credit_application_id,
      :funding_type,
      :payment_operation_id,
      :status,
      :amount_cents,
      :credit_entitlement_cents,
      :inserted_at,
      :updated_at
    ]

    values = [
      attrs.group_reservation_id,
      Map.get(attrs, :group_room_id),
      Map.get(attrs, :credit_lot_id),
      Map.get(attrs, :credit_application_id),
      attrs.funding_type,
      Map.get(attrs, :payment_operation_id),
      attrs.status,
      attrs.amount_cents,
      Map.get(attrs, :credit_entitlement_cents, 0),
      now,
      now
    ]

    migration_repo.query!(
      "INSERT INTO room_funding_allocations (#{Enum.join(columns, ", ")}) VALUES (#{Enum.join(List.duplicate("?", length(columns)), ", ")})",
      values
    )
  end
end
