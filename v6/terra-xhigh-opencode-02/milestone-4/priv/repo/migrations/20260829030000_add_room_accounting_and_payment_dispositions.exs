defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentDispositions do
  use Ecto.Migration

  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CashPaymentDisposition,
    CreditApplication,
    CreditLot,
    CreditLotContribution,
    Group,
    PartnerOperation,
    Room
  }

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:rooms) do
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
      add :room_id, references(:rooms, on_delete: :delete_all)
    end

    create index(:credit_applications, [:room_id])

    create table(:cash_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:cash_payment_dispositions) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :payment_operation_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:cash_payment_dispositions, [:payment_operation_id])
    create index(:cash_payment_dispositions, [:group_id])

    create table(:credit_lot_contributions) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :converted_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:payment_operation_id])

    flush()
    backfill_room_accounting()
  end

  def down do
    drop index(:credit_lot_contributions, [:payment_operation_id])
    drop index(:credit_lot_contributions, [:credit_lot_id])
    drop table(:credit_lot_contributions)
    drop index(:cash_payment_dispositions, [:group_id])
    drop unique_index(:cash_payment_dispositions, [:payment_operation_id])
    drop table(:cash_payment_dispositions)
    drop index(:cash_allocations, [:payment_operation_id])
    drop index(:cash_allocations, [:room_id])
    drop table(:cash_allocations)
    drop index(:credit_applications, [:room_id])

    alter table(:credit_applications) do
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end

  defp backfill_room_accounting do
    repo = repo()

    repo.query!("""
    UPDATE rooms
    SET status = CASE
      WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_id) = 'cancelled'
      THEN 'cancelled' ELSE 'active'
    END,
    lodging_total_cents = CAST(
      (julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
       julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) * nightly_rate_cents
      AS INTEGER
    ),
    deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'advance_purchase'
      THEN CAST(
        (julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
         julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) * nightly_rate_cents
        AS INTEGER
      )
      ELSE CAST(
        (((julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
           julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) * nightly_rate_cents * 20) + 50) / 100
        AS INTEGER
      )
    END
    """)

    operations = repo.all(from(operation in PartnerOperation, order_by: operation.id))
    operations_by_id = Map.new(operations, &{&1.operation_id, &1})

    repo.all(from(group in Group, order_by: group.id))
    |> Enum.each(fn group ->
      payments = cash_payments_for(operations, group.group_id)

      if group.status == "active" do
        rooms =
          repo.all(from(room in Room, where: room.group_id == ^group.id, order_by: room.position))

        applications =
          repo.all(
            from(application in CreditApplication,
              where: application.group_id == ^group.id,
              order_by: application.id
            )
          )

        repo.delete_all(
          from(application in CreditApplication, where: application.group_id == ^group.id)
        )

        funding_operations = durable_funding_operations(operations, group.group_id)

        legacy_cash =
          max(
            group.cash_paid_cents -
              Enum.sum_by(funding_operations, &funding_amount(&1, "record_cash_payment")),
            0
          )

        legacy_credit =
          max(
            group.credit_paid_cents -
              Enum.sum_by(funding_operations, &funding_amount(&1, "apply_hotel_credit")),
            0
          )

        {rooms, _} = allocate_cash(repo, rooms, legacy_cash, nil)
        credit_sources = Enum.map(applications, &{&1.credit_lot_id, &1.amount_cents})

        {legacy_sources, remaining_sources} =
          take_credit_sources(credit_sources, legacy_credit, [])

        {rooms, :ok} = allocate_credit_sources(repo, group, rooms, legacy_sources)

        Enum.reduce(funding_operations, {rooms, remaining_sources}, fn operation,
                                                                       {current_rooms,
                                                                        current_sources} ->
          case operation.operation_type do
            "record_cash_payment" ->
              {next_rooms, held_cents} =
                allocate_cash(
                  repo,
                  current_rooms,
                  payment_amount(operation),
                  operation.operation_id
                )

              insert_disposition(repo, group, operation, held_cents, 0, 0, 0)
              {next_rooms, current_sources}

            "apply_hotel_credit" ->
              {sources, next_sources} =
                take_credit_sources(current_sources, payment_amount(operation), [])

              {next_rooms, :ok} = allocate_credit_sources(repo, group, current_rooms, sources)
              {next_rooms, next_sources}
          end
        end)
      else
        Enum.each(payments, fn payment ->
          amount = payment_amount(payment)

          {refunded, retained, converted} =
            historical_settlement(group, amount)

          insert_disposition(repo, group, payment, 0, refunded, retained, converted)
        end)
      end
    end)

    backfill_credit_contributions(repo, operations_by_id)
    sync_group_totals(repo)
  end

  defp cash_payments_for(operations, group_id) do
    Enum.filter(operations, fn operation ->
      operation.operation_type == "record_cash_payment" and
        operation.result["status"] == "applied" and operation.result["group_id"] == group_id
    end)
  end

  defp durable_funding_operations(operations, group_id) do
    Enum.filter(operations, fn operation ->
      operation.operation_type in ["record_cash_payment", "apply_hotel_credit"] and
        operation.result["status"] == "applied" and operation.result["group_id"] == group_id
    end)
  end

  defp funding_amount(operation, type) when operation.operation_type == type,
    do: payment_amount(operation)

  defp funding_amount(_operation, _type), do: 0

  defp payment_amount(operation), do: operation.result["amount_cents"]

  defp allocate_cash(_repo, rooms, 0, _operation_id), do: {rooms, 0}

  defp allocate_cash(repo, rooms, amount, operation_id) do
    {updated_rooms, allocated} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        available = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
        applied = min(available, remaining)

        if applied > 0 do
          repo.insert!(
            CashAllocation.changeset(%CashAllocation{}, %{
              room_id: room.id,
              payment_operation_id: operation_id,
              amount_cents: applied
            })
          )

          repo.update_all(from(current in Room, where: current.id == ^room.id),
            inc: [cash_paid_cents: applied]
          )
        end

        {%{room | cash_paid_cents: room.cash_paid_cents + applied}, remaining - applied}
      end)

    {updated_rooms, amount - allocated}
  end

  defp take_credit_sources(sources, 0, selected), do: {Enum.reverse(selected), sources}
  defp take_credit_sources([], _amount, selected), do: {Enum.reverse(selected), []}

  defp take_credit_sources([{lot_id, available} | rest], amount, selected) do
    taken = min(available, amount)

    remaining_sources =
      if taken == available, do: rest, else: [{lot_id, available - taken} | rest]

    take_credit_sources(remaining_sources, amount - taken, [{lot_id, taken} | selected])
  end

  defp allocate_credit_sources(repo, group, rooms, sources) do
    Enum.reduce(sources, {rooms, :ok}, fn {credit_lot_id, amount}, {current_rooms, :ok} ->
      {next_rooms, allocations} = allocate_credit_to_rooms(current_rooms, amount)

      Enum.each(allocations, fn {room, allocated} ->
        repo.insert!(
          CreditApplication.changeset(%CreditApplication{}, %{
            group_id: group.id,
            room_id: room.id,
            credit_lot_id: credit_lot_id,
            amount_cents: allocated
          })
        )

        repo.update_all(from(current in Room, where: current.id == ^room.id),
          inc: [credit_paid_cents: allocated]
        )
      end)

      {next_rooms, :ok}
    end)
  end

  defp allocate_credit_to_rooms(rooms, amount) do
    {updated_rooms, remaining, allocations} =
      Enum.reduce(rooms, {[], amount, []}, fn room, {updated, remaining, allocations} ->
        available = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
        applied = min(available, remaining)

        {
          [%{room | credit_paid_cents: room.credit_paid_cents + applied} | updated],
          remaining - applied,
          if(applied > 0, do: [{room, applied} | allocations], else: allocations)
        }
      end)

    {Enum.reverse(updated_rooms), remaining, Enum.reverse(allocations)}
    |> case do
      {updated_rooms, _remaining, allocations} -> {updated_rooms, allocations}
    end
  end

  defp historical_settlement(group, amount) do
    cond do
      group.cash_converted_to_credit_cents > 0 -> {0, 0, amount}
      group.cash_refunded_cents > 0 -> {amount, 0, 0}
      true -> {0, amount, 0}
    end
  end

  defp insert_disposition(repo, group, payment, held, refunded, retained, converted) do
    repo.insert!(
      CashPaymentDisposition.changeset(%CashPaymentDisposition{}, %{
        group_id: group.id,
        payment_operation_id: payment.operation_id,
        recorded_cents: payment_amount(payment),
        held_cents: held,
        refunded_cents: refunded,
        retained_cents: retained,
        converted_to_credit_cents: converted,
        reduced_cents: 0,
        charged_back_cents: 0
      })
    )
  end

  defp backfill_credit_contributions(repo, operations_by_id) do
    repo.all(CreditLot)
    |> Enum.each(fn lot ->
      case Map.get(operations_by_id, lot.source_operation_id) do
        %PartnerOperation{operation_type: "cancel_group", result: %{"group_id" => group_id}} ->
          group = repo.get_by!(Group, group_id: group_id)

          if group.cash_converted_to_credit_cents > 0 do
            payments =
              repo.all(
                from(disposition in CashPaymentDisposition,
                  where: disposition.group_id == ^group.id,
                  order_by: disposition.id
                )
              )

            legacy =
              max(
                group.cash_converted_to_credit_cents -
                  Enum.sum_by(payments, & &1.converted_to_credit_cents),
                0
              )

            contributions =
              if(legacy > 0, do: [{nil, legacy}], else: []) ++
                Enum.map(payments, &{&1.payment_operation_id, &1.converted_to_credit_cents})

            insert_contributions(
              repo,
              lot,
              Enum.reject(contributions, fn {_id, amount} -> amount == 0 end)
            )
          end

        _ ->
          :ok
      end
    end)
  end

  defp insert_contributions(repo, lot, contributions) do
    {_running, _} =
      Enum.reduce(contributions, {0, 0}, fn {operation_id, amount}, {running, previous_value} ->
        total = running + amount
        total_value = total + rounded_percentage(total, 10)
        entitlement = total_value - previous_value

        repo.insert!(
          CreditLotContribution.changeset(%CreditLotContribution{}, %{
            credit_lot_id: lot.id,
            payment_operation_id: operation_id,
            converted_cents: amount,
            entitlement_cents: entitlement
          })
        )

        {total, total_value}
      end)
  end

  defp sync_group_totals(repo) do
    repo.all(Group)
    |> Enum.each(fn group ->
      totals =
        repo.one(
          from(room in Room,
            where: room.group_id == ^group.id and room.status == "active",
            select: %{
              lodging: coalesce(sum(room.lodging_total_cents), 0),
              due: coalesce(sum(room.deposit_due_cents), 0),
              cash: coalesce(sum(room.cash_paid_cents), 0),
              credit: coalesce(sum(room.credit_paid_cents), 0)
            }
          )
        )

      repo.update_all(
        from(current in Group, where: current.id == ^group.id),
        set: [
          status:
            if(totals.due == 0 and group.status == "cancelled", do: "cancelled", else: "active"),
          lodging_total_cents: totals.lodging,
          deposit_due_cents: totals.due,
          deposit_paid_cents: totals.cash + totals.credit,
          cash_paid_cents: totals.cash,
          credit_paid_cents: totals.credit
        ]
      )
    end)
  end

  defp rounded_percentage(amount, percentage), do: div(amount * percentage + 50, 100)
end
