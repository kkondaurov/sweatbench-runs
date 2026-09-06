defmodule GroupStay.Repo.Migrations.RoomAccountingAndPaymentReductions do
  use Ecto.Migration

  import Ecto.Query

  alias GroupStay.Credit.CreditApplication
  alias GroupStay.Groups.{Group, RoomAllocation}
  alias GroupStay.Money
  alias GroupStay.Operations.OperationRecord

  @deposit_percent 20

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
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

    create table(:room_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false, default: "held"
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :position, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()

    backfill()

    drop table(:credit_applications)
  end

  def down do
    create table(:credit_applications) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:group_id])
    create index(:credit_applications, [:credit_lot_id])

    drop table(:credit_entitlements)
    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :status
    end
  end

  ## Backfill

  # Rebuilds room-level funding for every existing group. Aggregate cash,
  # credit, and liability balances are untouched; the funding is re-expressed
  # as allocations. Each group receives the unattributed senior block first
  # (aggregate legacy cash, then legacy hotel-credit lots in original
  # consumption order), followed by funding represented by durable operation
  # records in commit order.
  defp backfill do
    funding_records = funding_records()

    groups = repo().all(from(g in Group, preload: :rooms))

    Enum.each(groups, &backfill_group(&1, funding_records))
  end

  defp funding_records do
    repo().all(
      from(r in OperationRecord,
        where: r.type in ["record_cash_payment", "apply_hotel_credit"],
        order_by: [asc: r.id]
      )
    )
    |> Enum.map(fn record ->
      payload = Jason.decode!(record.payload)
      result = Jason.decode!(record.result)

      %{
        id: record.id,
        operation_id: record.operation_id,
        type: record.type,
        group_id: payload["group_id"],
        amount_cents: payload["amount_cents"],
        applied: result["status"] == "applied"
      }
    end)
  end

  defp backfill_group(group, funding_records) do
    entries = build_entries(group, funding_records)
    {filled_rooms, rows} = fill_entries(room_states(group), entries)

    Enum.each(rows, fn row ->
      %RoomAllocation{}
      |> RoomAllocation.changeset(Map.delete(row, :row_position))
      |> repo().insert!()
    end)

    for room <- filled_rooms do
      held = Enum.filter(rows, &(&1.row_position == room.position and &1.disposition == "held"))
      cash = held |> Enum.filter(&(&1.kind == "cash")) |> Enum.sum_by(& &1.amount_cents)
      credit = held |> Enum.filter(&(&1.kind == "credit")) |> Enum.sum_by(& &1.amount_cents)

      room
      |> Ecto.Changeset.change(
        status: group.status,
        deposit_due_cents: deposit_due_cents(group, room),
        cash_paid_cents: cash,
        credit_paid_cents: credit
      )
      |> repo().update!()
    end
  end

  # Builds the per-group funding entries in allocation order: the legacy
  # block first, then the durable records in commit order. Each entry knows
  # its disposition (held for active groups, the settlement destination for
  # cancelled ones).
  defp build_entries(group, funding_records) do
    group_records =
      funding_records
      |> Enum.filter(&(&1.group_id == group.group_id and &1.applied))
      |> Enum.sort_by(& &1.id)

    cash_ops = Enum.filter(group_records, &(&1.type == "record_cash_payment"))
    credit_ops = Enum.filter(group_records, &(&1.type == "apply_hotel_credit"))

    legacy_cash = group.cash_paid_cents - sum_amounts(cash_ops)

    # Credit funding survives only on active groups: cancellation restores or
    # consumes it, so cancelled groups rebuild cash entries alone.
    credit_survives? = group.status == "active"
    credit_ops = if credit_survives?, do: credit_ops, else: []

    legacy_credit =
      if credit_survives?, do: group.credit_paid_cents - sum_amounts(credit_ops), else: 0

    if legacy_cash < 0 or legacy_credit < 0 do
      raise "recorded funding exceeds the stored totals of #{group.group_id}"
    end

    applications = legacy_applications(group)
    {legacy_apps, recorded_apps} = split_front(applications, legacy_credit, [])
    credit_by_op = attribute_credit(credit_ops, recorded_apps)

    cash_disposition = settled_disposition(group)
    credit_disposition = if group.status == "active", do: "held", else: "settled"

    legacy_entries =
      if(legacy_cash > 0,
        do: [entry("cash", nil, nil, legacy_cash, cash_disposition)],
        else: []
      ) ++
        Enum.map(legacy_apps, fn app ->
          entry("credit", app.credit_lot_id, nil, app.amount_cents, credit_disposition)
        end)

    recorded_entries =
      Enum.flat_map(group_records, fn record ->
        case record.type do
          "record_cash_payment" ->
            [entry("cash", nil, record.operation_id, record.amount_cents, cash_disposition)]

          "apply_hotel_credit" ->
            Enum.map(Map.fetch!(credit_by_op, record.operation_id), fn {lot_id, amount} ->
              entry("credit", lot_id, record.operation_id, amount, credit_disposition)
            end)
        end
      end)

    legacy_entries ++ recorded_entries
  end

  defp legacy_applications(group) do
    if group.status == "active" and group.credit_paid_cents > 0 do
      repo().all(
        from(a in CreditApplication,
          where: a.group_id == ^group.id,
          order_by: [asc: a.id]
        )
      )
    else
      []
    end
  end

  defp entry(kind, lot_id, payment_operation_id, amount_cents, disposition) do
    %{
      kind: kind,
      credit_lot_id: lot_id,
      payment_operation_id: payment_operation_id,
      amount_cents: amount_cents,
      disposition: disposition
    }
  end

  defp settled_disposition(%{status: "active"}), do: "held"

  defp settled_disposition(group) do
    cond do
      group.refunded_cents > 0 -> "refunded"
      group.retained_cents > 0 -> "retained"
      group.cash_converted_to_credit_cents > 0 -> "converted"
      true -> "settled"
    end
  end

  # The legacy credit block is the exact front of the group's credit
  # applications; application rows were inserted in consumption order and are
  # therefore already oldest-first.
  defp split_front(remaining, 0, acc), do: {Enum.reverse(acc), remaining}

  defp split_front([app | rest], legacy_total, acc) when legacy_total > 0 do
    if app.amount_cents > legacy_total do
      raise "legacy credit block #{legacy_total} does not align with credit " <>
              "applications for group #{app.group_id}"
    end

    split_front(rest, legacy_total - app.amount_cents, [app | acc])
  end

  defp split_front([], legacy_total, _acc) do
    raise "legacy credit block #{legacy_total} has no matching credit applications"
  end

  # Attributes the group's remaining (recorded) credit applications to the
  # recorded apply_hotel_credit operations, first-in-first-out.
  defp attribute_credit(credit_ops, applications) do
    {by_op, leftovers} =
      Enum.reduce(credit_ops, {%{}, applications}, fn op, {by_op, remaining} ->
        {slices, still_remaining} = consume_applications(remaining, op.amount_cents, [])
        {Map.put(by_op, op.operation_id, Enum.reverse(slices)), still_remaining}
      end)

    if leftovers != [] do
      raise "credit applications exceed the recorded applied credit operations"
    end

    by_op
  end

  defp consume_applications(remaining, 0, acc), do: {acc, remaining}

  defp consume_applications([app | rest], needed, acc) when needed > 0 do
    take = min(app.amount_cents, needed)
    consume_applications(rest, needed - take, [{app.credit_lot_id, take} | acc])
  end

  defp consume_applications([], needed, _acc) do
    raise "recorded credit operation exceeds the remaining credit applications"
  end

  # Rooms in original order, each with its computed deposit requirement.
  # Every funding entry, in the group's allocation order, fills the first
  # rooms it can — exactly the rule new funding operations follow.
  defp room_states(group) do
    group.rooms
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn room ->
      %{
        room: room,
        due: deposit_due_cents(group, room),
        paid: 0
      }
    end)
  end

  defp fill_entries(rooms, entries) do
    Enum.reduce(entries, {rooms, []}, fn entry, {rooms, rows} ->
      {rooms, rows_created} = fill_entry(rooms, entry)
      {rooms, rows ++ rows_created}
    end)
    |> then(fn {states, rows} -> {Enum.map(states, & &1.room), rows} end)
  end

  defp fill_entry(rooms, entry) do
    {rooms, rows} =
      Enum.map_reduce(rooms, [], fn room_state, rows_acc ->
        filled_so_far = Enum.sum_by(rows_acc, & &1.amount_cents)
        take = min(entry.amount_cents - filled_so_far, room_state.due - room_state.paid)

        if take > 0 do
          row = %{
            room_id: room_state.room.id,
            row_position: room_state.room.position,
            position: room_state.room.position,
            kind: entry.kind,
            amount_cents: take,
            disposition: entry.disposition,
            payment_operation_id: entry.payment_operation_id,
            credit_lot_id: entry.credit_lot_id
          }

          {%{room_state | paid: room_state.paid + take}, [row | rows_acc]}
        else
          {room_state, rows_acc}
        end
      end)

    {rooms, Enum.reverse(rows)}
  end

  defp sum_amounts(ops), do: Enum.sum(Enum.map(ops, & &1.amount_cents))

  defp deposit_due_cents(group, room) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    lodging = nights * room.nightly_rate_cents

    case group.rate_plan do
      "flexible" -> Money.percent_of(lodging, @deposit_percent)
      "advance_purchase" -> lodging
    end
  end
end
