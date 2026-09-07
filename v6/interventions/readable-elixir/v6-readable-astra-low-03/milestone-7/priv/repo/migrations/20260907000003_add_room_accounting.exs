defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration
  import Ecto.Query

  def up do
    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
      add :credit_lot_id, references(:credit_lots)
      add :entitlement_cents, :integer, null: false, default: 0
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:payment_operation_id])

    alter table(:credit_allocations) do
      add :room_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    flush()
    backfill()
  end

  # This upgrade uses only the release's persisted columns and raw maps, so later
  # schema changes cannot change how old funding is reconstructed.
  defp backfill do
    groups =
      repo().all(
        from(g in "groups",
          select:
            map(g, [
              :group_id,
              :rooms,
              :arrival_on,
              :departure_on,
              :rate_plan,
              :status,
              :cash_paid_cents,
              :credit_paid_cents,
              :refunded_cents,
              :retained_cents,
              :cash_converted_to_credit_cents
            ])
        )
      )

    records_by_group =
      repo().all(
        from(o in "operations",
          order_by: o.id,
          select: map(o, [:operation_id, :operation_type, :result])
        )
      )
      |> Enum.map(fn record -> %{record | result: decode(record.result)} end)
      |> Enum.filter(&(&1.result["status"] == "applied"))
      |> Enum.group_by(& &1.result["group_id"])

    for group <- groups do
      records = Map.get(records_by_group, group.group_id, [])

      payments = Enum.filter(records, &(&1.operation_type == "record_cash_payment"))
      applications = Enum.filter(records, &(&1.operation_type == "apply_hotel_credit"))

      allocations =
        repo().all(
          from(a in "credit_allocations",
            where: a.group_id == ^group.group_id,
            order_by: a.id,
            select: map(a, [:id, :credit_lot_id, :amount_cents])
          )
        )

      nights = Date.diff(date(group.departure_on), date(group.arrival_on))

      rooms =
        Enum.map(decode(group.rooms), fn room ->
          lodging = nights * room["nightly_rate_cents"]
          due = if group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

          Map.merge(room, %{
            "status" => group.status,
            "lodging_total_cents" => lodging,
            "deposit_due_cents" => due,
            "cash_paid_cents" => 0,
            "credit_paid_cents" => 0
          })
        end)

      if group.status == "active" do
        legacy_cash =
          group.cash_paid_cents - Enum.sum(Enum.map(payments, & &1.result["amount_cents"]))

        legacy_credit =
          group.credit_paid_cents - Enum.sum(Enum.map(applications, & &1.result["amount_cents"]))

        repo().delete_all(from(a in "credit_allocations", where: a.group_id == ^group.group_id))

        events =
          [{:cash, nil, legacy_cash}, {:credit, nil, legacy_credit}] ++
            (records
             |> Enum.filter(&(&1.operation_type in ["record_cash_payment", "apply_hotel_credit"]))
             |> Enum.map(fn r ->
               {if(r.operation_type == "record_cash_payment", do: :cash, else: :credit),
                r.operation_id, r.result["amount_cents"]}
             end))

        {rooms, _} =
          Enum.reduce(events, {rooms, allocations}, fn
            {:cash, id, amount}, {rooms, lots} ->
              {fill(rooms, amount, :cash, group.group_id, id), lots}

            {:credit, _, amount}, {rooms, lots} ->
              consume(rooms, lots, amount, group.group_id)
          end)

        save_rooms(group.group_id, rooms)
      else
        disposition =
          cond do
            group.cash_converted_to_credit_cents > 0 -> "converted_to_credit"
            group.refunded_cents > 0 -> "refunded"
            true -> "retained"
          end

        total = group.refunded_cents + group.retained_cents + group.cash_converted_to_credit_cents
        legacy = total - Enum.sum(Enum.map(payments, & &1.result["amount_cents"]))
        cancellation = Enum.find(records, &(&1.operation_type == "cancel_group"))

        lot_id =
          if cancellation,
            do:
              repo().one(
                from(l in "credit_lots",
                  where: l.source_operation_id == ^cancellation.operation_id,
                  select: l.id
                )
              )

        Enum.reduce(
          [{nil, legacy} | Enum.map(payments, &{&1.operation_id, &1.result["amount_cents"]})],
          0,
          fn {id, amount}, preceding ->
            if amount > 0 do
              entitlement = if lot_id, do: bonus(preceding + amount) - bonus(preceding), else: 0

              repo().insert_all("cash_allocations", [
                %{
                  group_id: group.group_id,
                  payment_operation_id: id,
                  amount_cents: amount,
                  disposition: disposition,
                  credit_lot_id: lot_id,
                  entitlement_cents: entitlement
                }
              ])
            end

            preceding + amount
          end
        )

        save_rooms(group.group_id, rooms)

        repo().update_all(from(g in "groups", where: g.group_id == ^group.group_id),
          set: [lodging_total_cents: 0]
        )
      end
    end
  end

  defp consume(rooms, lots, 0, _), do: {rooms, lots}

  defp consume(rooms, [lot | rest], amount, group_id) do
    used = min(amount, lot.amount_cents)
    rooms = fill(rooms, used, :credit, group_id, lot.credit_lot_id)

    lots =
      if used == lot.amount_cents,
        do: rest,
        else: [%{lot | amount_cents: lot.amount_cents - used} | rest]

    consume(rooms, lots, amount - used, group_id)
  end

  defp fill(rooms, amount, kind, group_id, source) do
    {rooms, _} =
      Enum.map_reduce(rooms, amount, fn room, needed ->
        used =
          min(
            needed,
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]
          )

        key = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"

        if used > 0 do
          if kind == :cash do
            repo().insert_all("cash_allocations", [
              %{
                group_id: group_id,
                room_id: room["room_id"],
                payment_operation_id: source,
                amount_cents: used,
                disposition: "held",
                entitlement_cents: 0
              }
            ])
          else
            repo().insert_all("credit_allocations", [
              %{
                group_id: group_id,
                room_id: room["room_id"],
                credit_lot_id: source,
                amount_cents: used
              }
            ])
          end
        end

        {Map.update!(room, key, &(&1 + used)), needed - used}
      end)

    rooms
  end

  defp save_rooms(id, rooms),
    do:
      repo().update_all(from(g in "groups", where: g.group_id == ^id),
        set: [rooms: Jason.encode!(rooms)]
      )

  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value
  defp date(value) when is_binary(value), do: Date.from_iso8601!(value)
  defp date(value), do: value
  defp bonus(amount), do: amount + div(amount * 10 + 50, 100)

  def down do
    drop table(:cash_allocations)
    alter table(:credit_allocations), do: remove(:room_id)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)
  end
end
