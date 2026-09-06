defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  @moduledoc """
  Gives every room its own funding record.

  Deposits were already calculated room by room; this migration writes down which
  cash and which credit lot pays for which room, and where every cent of that
  funding currently stands. Group-level settlement columns and the group-level
  credit redemptions are folded into those rows, so the finance totals have a
  single source.

  Funding an earlier release recorded without a durable operation record has no
  payment identity. It is carried forward as one unattributed senior block per
  group that fills rooms ahead of everything a record can account for, and no
  aggregate cash, credit or liability balance moves while it is created.
  """

  use Ecto.Migration

  alias GroupStay.Funding.Plan

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :group_ref, references(:groups, on_delete: :delete_all), null: false
      add :room_ref, references(:rooms, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :operation_id, :string
      add :lot_ref, references(:credit_lots)
      add :issued_lot_ref, references(:credit_lots)
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:room_allocations, [:group_ref])
    create index(:room_allocations, [:room_ref])
    create index(:room_allocations, [:operation_id])
    create index(:room_allocations, [:issued_lot_ref])

    flush()

    execute """
    UPDATE rooms
       SET status = 'cancelled'
     WHERE group_ref IN (SELECT id FROM groups WHERE status = 'cancelled')
    """

    carry_funding_forward()

    drop table(:credit_redemptions)

    alter table(:groups) do
      remove :cash_refunded_cents
      remove :cash_retained_cents
      remove :cash_converted_to_credit_cents
    end
  end

  def down do
    alter table(:groups) do
      add :cash_refunded_cents, :integer, null: false, default: 0
      add :cash_retained_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    create table(:credit_redemptions) do
      add :lot_ref, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_ref, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_redemptions, [:lot_ref])
    create index(:credit_redemptions, [:group_ref])

    flush()

    for {column, disposition} <- [
          {"cash_refunded_cents", "refunded"},
          {"cash_retained_cents", "retained"},
          {"cash_converted_to_credit_cents", "converted"}
        ] do
      execute """
      UPDATE groups
         SET #{column} = (
               SELECT COALESCE(SUM(a.amount_cents), 0)
                 FROM room_allocations a
                WHERE a.group_ref = groups.id
                  AND a.kind = 'cash'
                  AND a.disposition = '#{disposition}'
             )
      """
    end

    execute """
    INSERT INTO credit_redemptions (lot_ref, group_ref, amount_cents, inserted_at, updated_at)
    SELECT lot_ref, group_ref, SUM(amount_cents), MIN(inserted_at), MIN(updated_at)
      FROM room_allocations
     WHERE kind = 'credit' AND lot_ref IS NOT NULL
     GROUP BY group_ref, lot_ref
    """

    drop table(:room_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
    end
  end

  # --- carrying existing funding forward ----------------------------------

  defp carry_funding_forward do
    records = funding_records()
    lots = settlement_lots()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    for group <- groups() do
      allocate(group, Map.get(records, group.group_id, []), Map.get(lots, group.group_id), now)
    end
  end

  defp allocate(group, records, issued_lot_ref, now) do
    rooms = rooms(group.id)

    events =
      Plan.carry_forward(
        group.cash_paid_cents,
        group.credit_paid_cents,
        records,
        redemptions(group.id)
      )

    Enum.reduce(events, Enum.map(rooms, & &1.deposit_cents), fn event, capacities ->
      {placements, _unplaced} = Plan.fill(capacities, event.amount_cents)

      for {index, amount_cents} <- placements do
        insert_allocation(
          group,
          Enum.fetch!(rooms, index),
          event,
          amount_cents,
          issued_lot_ref,
          now
        )
      end

      Enum.reduce(placements, capacities, fn {index, amount_cents}, capacities ->
        List.update_at(capacities, index, &(&1 - amount_cents))
      end)
    end)
  end

  defp insert_allocation(group, room, event, amount_cents, issued_lot_ref, now) do
    disposition = disposition(group, event.kind)

    query!(
      """
      INSERT INTO room_allocations
        (group_ref, room_ref, kind, operation_id, lot_ref, issued_lot_ref,
         amount_cents, disposition, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      """,
      [
        group.id,
        room.id,
        to_string(event.kind),
        event.operation_id,
        event.lot_ref,
        if(disposition == "converted", do: issued_lot_ref),
        amount_cents,
        disposition,
        now,
        now
      ]
    )
  end

  # An active group still holds its funding. A cancelled one settled all of its
  # cash the same way, so its rows take the settlement the group recorded.
  defp disposition(%{status: "active"}, _kind), do: "held"

  defp disposition(group, :cash) do
    cond do
      group.refunded_cents > 0 -> "refunded"
      group.converted_cents > 0 -> "converted"
      true -> "retained"
    end
  end

  # Credit on a cancelled group has already been returned to its lot or consumed;
  # either way it is no longer applied to an active group.
  defp disposition(group, :credit) do
    if group.retained_cents > 0, do: "consumed", else: "restored"
  end

  # --- reading the earlier shape ------------------------------------------

  defp groups do
    %{rows: rows} =
      query!("""
      SELECT id, group_id, status, cash_paid_cents, credit_paid_cents,
             cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents
        FROM groups
       ORDER BY id
      """)

    Enum.map(rows, fn [id, group_id, status, cash, credit, refunded, retained, converted] ->
      %{
        id: id,
        group_id: group_id,
        status: status,
        cash_paid_cents: cash,
        credit_paid_cents: credit,
        refunded_cents: refunded,
        retained_cents: retained,
        converted_cents: converted
      }
    end)
  end

  defp rooms(group_ref) do
    %{rows: rows} =
      query!("SELECT id, deposit_cents FROM rooms WHERE group_ref = ?1 ORDER BY position", [
        group_ref
      ])

    Enum.map(rows, fn [id, deposit_cents] -> %{id: id, deposit_cents: deposit_cents} end)
  end

  defp redemptions(group_ref) do
    %{rows: rows} =
      query!(
        "SELECT lot_ref, amount_cents FROM credit_redemptions WHERE group_ref = ?1 ORDER BY id",
        [group_ref]
      )

    Enum.map(rows, fn [lot_ref, amount_cents] -> {lot_ref, amount_cents} end)
  end

  # The applied funding operations of every group, in durable-record commit order.
  defp funding_records do
    %{rows: rows} =
      query!("""
      SELECT operation_id, type, result
        FROM operations
       WHERE type IN ('record_cash_payment', 'apply_hotel_credit')
       ORDER BY id
      """)

    rows
    |> Enum.flat_map(fn [operation_id, type, result] ->
      case Jason.decode!(result) do
        %{"status" => "applied", "group_id" => group_id, "amount_cents" => amount_cents}
        when is_binary(group_id) and is_integer(amount_cents) ->
          [
            {group_id,
             %{operation_id: operation_id, kind: kind(type), amount_cents: amount_cents}}
          ]

        _other ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp kind("record_cash_payment"), do: :cash
  defp kind("apply_hotel_credit"), do: :credit

  # The lot a group's own cancellation issued, so cash it converted can still be
  # traced to the credit it bought.
  defp settlement_lots do
    lots =
      query!("SELECT source_operation_id, id FROM credit_lots").rows
      |> Map.new(fn [source_operation_id, id] -> {source_operation_id, id} end)

    %{rows: rows} =
      query!(
        "SELECT operation_id, result FROM operations WHERE type = 'cancel_group' ORDER BY id"
      )

    rows
    |> Enum.flat_map(fn [operation_id, result] ->
      case Jason.decode!(result) do
        %{"status" => "applied", "group_id" => group_id, "credit_issued_cents" => issued}
        when is_binary(group_id) and is_integer(issued) and issued > 0 ->
          [{group_id, Map.get(lots, operation_id)}]

        _other ->
          []
      end
    end)
    |> Map.new()
  end

  defp query!(sql, params \\ []), do: repo().query!(sql, params)
end
