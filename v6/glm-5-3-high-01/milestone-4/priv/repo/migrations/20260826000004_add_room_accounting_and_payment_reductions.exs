defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  import Ecto.Query

  @flexible_deposit_numerator 20

  def up do
    alter table(:rooms) do
      add :status, :text, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :amount_cents, :integer, null: false
      add :operation_id, :text
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all)
      add :position, :integer, null: false

      timestamps()
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:operation_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :operation_id, :text, null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:payments, [:operation_id])
    create index(:payments, [:group_id])

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :payment_operation_id, :text, null: false
      add :entitlement_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()

    records = durable_records()
    backfill_rooms()
    backfill_payments(records)
    backfill_room_allocations(records)

    drop table(:credit_applications)
  end

  def down do
    create table(:credit_applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])

    drop table(:credit_entitlements)
    drop table(:payments)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_cents
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  defp durable_records do
    repo().all(
      from(o in "operation_records",
        order_by: o.id,
        select: %{
          operation_id: o.operation_id,
          type: o.type,
          payload: o.payload,
          result: o.result
        }
      )
    )
    |> Enum.map(fn record ->
      %{
        record
        | payload: Jason.decode!(record.payload),
          result: Jason.decode!(record.result)
      }
    end)
    |> Enum.filter(fn record ->
      record.type in ["record_cash_payment", "apply_hotel_credit"] and
        record.result["status"] == "applied"
    end)
  end

  # Every room records the lodging and deposit amounts used to build the
  # group requirement. Rooms of cancelled groups are settled in full, so
  # they hold no requirement of their own.
  defp backfill_rooms do
    repo().all(
      from(g in "groups",
        select: %{
          id: g.id,
          status: g.status,
          rate_plan: g.rate_plan,
          arrival_on: g.arrival_on,
          departure_on: g.departure_on
        }
      )
    )
    |> Enum.each(fn group ->
      arrival_on = Date.from_iso8601!(group.arrival_on)
      departure_on = Date.from_iso8601!(group.departure_on)
      nights = Date.diff(departure_on, arrival_on)

      repo().all(
        from(r in "rooms",
          where: r.group_id == ^group.id,
          order_by: r.position,
          select: %{id: r.id, nightly_rate_cents: r.nightly_rate_cents}
        )
      )
      |> Enum.each(fn room ->
        {status, lodging_cents, deposit_due_cents} =
          if group.status == "active" do
            lodging = nights * room.nightly_rate_cents

            deposit =
              if group.rate_plan == "advance_purchase",
                do: lodging,
                else:
                  div(nights * room.nightly_rate_cents * @flexible_deposit_numerator + 50, 100)

            {"active", lodging, deposit}
          else
            {"cancelled", 0, 0}
          end

        repo().query!(
          "UPDATE rooms SET status = ?, lodging_cents = ?, deposit_due_cents = ? WHERE id = ?",
          [status, lodging_cents, deposit_due_cents, room.id]
        )
      end)
    end)
  end

  # Applied cash payments keep their durable identity so corrections and
  # chargebacks can address them. A payment on a cancelled group was settled
  # by that group's single cancellation, in one direction.
  defp backfill_payments(records) do
    records
    |> Enum.filter(&(&1.type == "record_cash_payment"))
    |> Enum.each(fn record ->
      group_ref = record.payload["group_id"]
      amount = record.result["amount_cents"]

      group = group_by_ref(group_ref)

      if group && is_integer(amount) do
        disposition =
          cond do
            group.converted_to_credit_cents > 0 -> :converted
            group.refunded_cents > 0 -> :refunded
            true -> :retained
          end

        held = if group.status == "active", do: amount, else: 0
        settled = if group.status == "active", do: 0, else: amount

        repo().insert_all(
          "payments",
          [
            %{
              id: Ecto.UUID.generate(),
              operation_id: record.operation_id,
              group_id: group.id,
              recorded_cents: amount,
              held_cents: held,
              refunded_cents: if(disposition == :refunded, do: settled, else: 0),
              retained_cents: if(disposition == :retained, do: settled, else: 0),
              converted_cents: if(disposition == :converted, do: settled, else: 0),
              reduced_cents: 0,
              charged_back_cents: 0,
              inserted_at: now(),
              updated_at: now()
            }
          ]
        )
      end
    end)
  end

  # Funding for active groups is rebuilt in room-accounting order: the
  # unattributed senior block first (aggregate legacy cash, then legacy
  # hotel-credit lots in original consumption order), then the funding
  # represented by durable operation records in commit order.
  defp backfill_room_allocations(records) do
    repo().all(
      from(g in "groups",
        where: g.status == "active",
        select: %{
          id: g.id,
          group_id: g.group_id,
          rate_plan: g.rate_plan,
          arrival_on: g.arrival_on,
          departure_on: g.departure_on,
          cash_paid_cents: g.cash_paid_cents,
          credit_paid_cents: g.credit_paid_cents,
          deposit_paid_cents: g.deposit_paid_cents
        }
      )
    )
    |> Enum.each(fn group ->
      group_records =
        Enum.filter(records, fn record ->
          record.payload["group_id"] == group.group_id
        end)

      durable_cash = sum_results(group_records, "record_cash_payment")
      durable_credit = sum_results(group_records, "apply_hotel_credit")

      legacy_cash = max(group.cash_paid_cents - durable_cash, 0)
      legacy_credit = max(group.credit_paid_cents - durable_credit, 0)

      applications =
        repo().all(
          from(a in "credit_applications",
            where: a.group_id == ^group.id,
            order_by: fragment("rowid"),
            select: %{credit_lot_id: a.credit_lot_id, amount_cents: a.amount_cents}
          )
        )

      {legacy_applications, durable_applications} =
        split_applications(applications, legacy_credit)

      funding =
        [{nil, "cash", legacy_cash, nil}] ++
          Enum.map(legacy_applications, &{nil, "credit", &1.amount_cents, &1.credit_lot_id}) ++
          durable_funding(group_records, durable_applications)

      rooms =
        repo().all(
          from(r in "rooms",
            where: r.group_id == ^group.id,
            order_by: r.position,
            select: %{
              id: r.id,
              deposit_due_cents: r.deposit_due_cents,
              cash_paid_cents: r.cash_paid_cents,
              credit_paid_cents: r.credit_paid_cents
            }
          )
        )

      {allocations, updated_rooms, allocated} = fill(rooms, funding, group.id)

      if allocated != group.deposit_paid_cents do
        raise RuntimeError,
              "room accounting backfill for group #{group.group_id} allocated #{allocated} cents " <>
                "but the group records #{group.deposit_paid_cents} cents of funding"
      end

      Enum.each(updated_rooms, fn room ->
        repo().query!(
          "UPDATE rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
          [room.cash_paid_cents, room.credit_paid_cents, room.id]
        )
      end)

      if allocations != [] do
        repo().insert_all("room_allocations", allocations)
      end
    end)
  end

  defp sum_results(records, type) do
    records
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(& &1.result["amount_cents"])
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  # Legacy credit applications were consumed before any durable operation
  # record existed, so they are the leading applications in consumption
  # order and sum to the group's legacy credit.
  defp split_applications(applications, legacy_credit),
    do: take_amount(applications, legacy_credit)

  defp take_amount(applications, amount) when amount <= 0, do: {[], applications}

  defp take_amount([app | rest], amount) do
    if app.amount_cents <= amount do
      {legacy, remaining} = take_amount(rest, amount - app.amount_cents)
      {[app | legacy], remaining}
    else
      # A durable application was never split by the legacy boundary; treat
      # this and later applications as durable.
      {[], [app | rest]}
    end
  end

  defp take_amount([], _amount), do: {[], []}

  # Durable funding in commit order. Durable credit applications trail the
  # legacy ones, so each apply operation's amount is matched against the
  # remaining application rows in consumption order.
  defp durable_funding(records, applications) do
    records
    |> Enum.reduce({[], applications}, fn record, {funding, apps} ->
      amount = record.result["amount_cents"] || 0

      case record.type do
        "record_cash_payment" ->
          {funding ++ [{record.operation_id, "cash", amount, nil}], apps}

        "apply_hotel_credit" ->
          {chunks, apps} = take_amount(apps, amount)

          {funding ++
             Enum.map(chunks, &{record.operation_id, "credit", &1.amount_cents, &1.credit_lot_id}),
           apps}
      end
    end)
    |> elem(0)
  end

  defp fill(rooms, funding, group_id) do
    {rooms, allocations, allocated} =
      Enum.reduce(funding, {rooms, [], 0}, fn entry, {rooms, allocations, allocated} ->
        {_operation_id, _kind, amount, _lot_id} = entry

        if amount > 0 do
          {rooms, new_allocations, filled} = fill_rooms(rooms, entry, group_id)
          {rooms, allocations ++ new_allocations, allocated + filled}
        else
          {rooms, allocations, allocated}
        end
      end)

    {renumber(allocations), rooms, allocated}
  end

  defp fill_rooms(rooms, {operation_id, kind, amount, lot_id}, group_id) do
    {rooms_rev, allocations, remaining} =
      Enum.reduce(rooms, {[], [], amount}, fn room, {rooms, allocations, remaining} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        take = min(max(capacity, 0), remaining)

        if take > 0 do
          updated_room =
            if kind == "cash",
              do: %{room | cash_paid_cents: room.cash_paid_cents + take},
              else: %{room | credit_paid_cents: room.credit_paid_cents + take}

          allocation = %{
            id: Ecto.UUID.generate(),
            room_id: room.id,
            group_id: group_id,
            kind: kind,
            amount_cents: take,
            operation_id: operation_id,
            credit_lot_id: lot_id,
            inserted_at: now(),
            updated_at: now()
          }

          {[updated_room | rooms], [allocation | allocations], remaining - take}
        else
          {[room | rooms], allocations, remaining}
        end
      end)

    {Enum.reverse(rooms_rev), Enum.reverse(allocations), amount - remaining}
  end

  defp renumber(allocations) do
    allocations
    |> Enum.with_index(1)
    |> Enum.map(fn {allocation, index} -> Map.put(allocation, :position, index) end)
  end

  defp group_by_ref(group_ref) when is_binary(group_ref) do
    repo().one(
      from(g in "groups",
        where: g.group_id == ^group_ref,
        select: %{
          id: g.id,
          status: g.status,
          refunded_cents: g.refunded_cents,
          converted_to_credit_cents: g.converted_to_credit_cents
        }
      )
    )
  end

  defp group_by_ref(_group_ref), do: nil

  defp now do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 19)
  end
end
