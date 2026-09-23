defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  # This migration allocates existing funding to rooms with its own copy of the fill rules, so it
  # keeps working as the application's modules evolve.

  @durable_funding_types ~w(record_cash_payment apply_hotel_credit)
  @settlement_statuses %{
    "cash_refund" => "refunded",
    "cash_retained" => "retained",
    "cash_converted_to_credit" => "converted"
  }

  def up do
    alter table(:group_rooms) do
      # `active` or `cancelled`. Existing rooms of cancelled groups are cancelled below.
      add :status, :string, null: false, default: "active"
    end

    create table(:cash_allocations) do
      add :group_ref, references(:groups, on_delete: :restrict), null: false
      # `nil` only when the group had no room with deposit left to fund.
      add :room_ref, references(:group_rooms, on_delete: :restrict)
      # The durable payment the cash came from; `nil` for funding from before durable records.
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      # `held`, `refunded`, `retained`, `converted`, `reduced`, or `charged_back`.
      add :status, :string, null: false
      # The credit lot converted cash was issued into. Kept after a chargeback.
      add :lot_ref, references(:credit_lots, on_delete: :restrict)
      add :settled_on, :date

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cash_allocations, [:group_ref, :status])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:room_ref])
    create index(:cash_allocations, [:lot_ref])

    alter table(:credit_applications) do
      # The room the credit funds. Applications are split so each funds one room.
      add :room_ref, references(:group_rooms, on_delete: :restrict)
    end

    create index(:credit_applications, [:room_ref])

    alter table(:credit_lots) do
      # Clawed-back entitlement that could not be removed from the lot's remaining balance.
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    flush()

    backfill_allocations()
  end

  def down do
    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop index(:credit_applications, [:room_ref])

    alter table(:credit_applications) do
      remove :room_ref
    end

    drop table(:cash_allocations)

    alter table(:group_rooms) do
      remove :status
    end
  end

  ## Backfill
  #
  # Funding from before durable operation records is one unattributed senior block per group:
  # its cash first, then its credit applications in consumption order. Applied cash payments and
  # credit applications with durable records follow in commit order. Aggregate cash, credit, and
  # liability balances are left exactly as they were.

  defp backfill_allocations do
    funding = durable_funding() |> Enum.group_by(& &1.group_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{rows: groups} =
      repo().query!(
        "SELECT id, group_id, status, deposit_paid_cents, credit_paid_cents FROM groups ORDER BY id"
      )

    for [id, group_id, status, paid, credit_paid] <- groups do
      group = %{id: id, status: status, cash: paid - credit_paid}
      backfill_group(group, Map.get(funding, group_id, []), now)
    end
  end

  # Applied cash payments and credit applications with durable records, in commit order.
  defp durable_funding do
    %{rows: rows} =
      repo().query!(
        """
        SELECT operation_id, type, payload, result FROM operation_records
        WHERE status = 'applied' AND type IN (?, ?)
        ORDER BY id
        """,
        @durable_funding_types
      )

    for [operation_id, type, payload, result] <- rows do
      submitted = Jason.decode!(payload)
      result = Jason.decode!(result)

      %{
        operation_id: operation_id,
        type: type,
        group_id: result["group_id"] || submitted["group_id"],
        amount: result["amount_cents"] || submitted["amount_cents"]
      }
    end
  end

  defp backfill_group(group, records, now) do
    %{rows: rooms} =
      repo().query!(
        "SELECT id, deposit_cents FROM group_rooms WHERE group_ref = ? ORDER BY position",
        [group.id]
      )

    durable_cash =
      for(%{type: "record_cash_payment", amount: amount} <- records, do: amount) |> Enum.sum()

    legacy_cash = max(group.cash - durable_cash, 0)

    # Credit on a cancelled group has already been settled and no longer funds a room.
    {legacy_credit, durable_credit} =
      if group.status == "active",
        do: split_credit_applications(group.id, records),
        else: {[], %{}}

    pieces =
      [{:cash, nil, legacy_cash}] ++
        Enum.map(legacy_credit, &{:credit, &1}) ++
        Enum.flat_map(records, fn
          %{type: "record_cash_payment"} = record ->
            [{:cash, record.operation_id, record.amount}]

          %{type: "apply_hotel_credit"} = record ->
            durable_credit |> Map.get(record.operation_id, []) |> Enum.map(&{:credit, &1})
        end)

    settlement = if group.status == "active", do: nil, else: cancellation_settlement(group.id)
    capacities = Enum.map(rooms, fn [room_id, deposit] -> {room_id, deposit} end)

    Enum.reduce(pieces, capacities, fn piece, capacities ->
      {portions, capacities} = fill(capacities, piece_amount(piece))
      insert_piece(group, piece, portions, settlement, now)
      capacities
    end)

    if group.status != "active" do
      repo().query!("UPDATE group_rooms SET status = 'cancelled' WHERE group_ref = ?", [group.id])

      # Group totals now describe active rooms only, and a cancelled group has none.
      repo().query!(
        """
        UPDATE groups SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0,
          credit_paid_cents = 0
        WHERE id = ?
        """,
        [group.id]
      )
    end
  end

  # Separates a group's applied credit applications into those of durable `apply_hotel_credit`
  # records and the legacy remainder. An earlier release may have used the same operation
  # identifier, so each record claims its most recent applications up to its recorded amount.
  defp split_credit_applications(group_ref, records) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id, lot_ref, operation_id, amount_cents FROM credit_applications
        WHERE group_ref = ? AND status = 'applied'
        ORDER BY id
        """,
        [group_ref]
      )

    applications =
      Enum.map(rows, fn [id, lot_ref, operation_id, amount] ->
        %{id: id, lot_ref: lot_ref, operation_id: operation_id, amount: amount}
      end)

    {durable, claimed} =
      for %{type: "apply_hotel_credit"} = record <- records, reduce: {%{}, MapSet.new()} do
        {durable, claimed} ->
          {mine, _left} =
            applications
            |> Enum.filter(&(&1.operation_id == record.operation_id and &1.id not in claimed))
            |> Enum.reverse()
            |> Enum.reduce_while({[], record.amount}, fn
              _application, {mine, left} when left <= 0 ->
                {:halt, {mine, left}}

              application, {mine, left} ->
                {:cont, {[application | mine], left - application.amount}}
            end)

          {Map.put(durable, record.operation_id, mine),
           Enum.reduce(mine, claimed, &MapSet.put(&2, &1.id))}
      end

    {Enum.reject(applications, &(&1.id in claimed)), durable}
  end

  # How a cancelled group's cash was settled, from its cancellation ledger entry.
  defp cancellation_settlement(group_ref) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT kind, occurred_on FROM ledger_entries
        WHERE group_ref = ? AND kind IN ('cash_refund', 'cash_retained', 'cash_converted_to_credit')
        ORDER BY id LIMIT 1
        """,
        [group_ref]
      )

    %{rows: lots} =
      repo().query!(
        "SELECT id FROM credit_lots WHERE source_group_ref = ? ORDER BY id LIMIT 1",
        [group_ref]
      )

    lot_ref = match?([[_]], lots) && hd(hd(lots))

    case rows do
      [["cash_converted_to_credit", on]] when is_integer(lot_ref) ->
        %{status: "converted", settled_on: on, lot_ref: lot_ref}

      [[kind, on]] ->
        %{status: Map.get(@settlement_statuses, kind, "retained"), settled_on: on, lot_ref: nil}

      [] ->
        %{status: "retained", settled_on: nil, lot_ref: nil}
    end
  end

  defp piece_amount({:cash, _payment, amount}), do: amount
  defp piece_amount({:credit, application}), do: application.amount

  # Fills rooms in their original order. Funding beyond every room's deposit stays with the group.
  defp fill(capacities, amount) do
    {portions, capacities, left} =
      Enum.reduce(capacities, {[], [], amount}, fn {room_id, capacity}, {portions, rest, left} ->
        take = min(capacity, left)
        portions = if take > 0, do: [{room_id, take} | portions], else: portions
        {portions, [{room_id, capacity - take} | rest], left - take}
      end)

    portions = if left > 0, do: [{nil, left} | portions], else: portions
    {Enum.reverse(portions), Enum.reverse(capacities)}
  end

  defp insert_piece(group, {:cash, payment_operation_id, _amount}, portions, settlement, now) do
    {status, lot_ref, settled_on} =
      case settlement do
        nil -> {"held", nil, nil}
        %{} -> {settlement.status, settlement.lot_ref, settlement.settled_on}
      end

    for {room_ref, amount} <- portions do
      repo().query!(
        """
        INSERT INTO cash_allocations (group_ref, room_ref, payment_operation_id, amount_cents,
          status, lot_ref, settled_on, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [group.id, room_ref, payment_operation_id, amount, status, lot_ref, settled_on, now, now]
      )
    end
  end

  # The application keeps its first portion; each further room receives a copy of it.
  defp insert_piece(_group, {:credit, application}, portions, _settlement, now) do
    [{room_ref, amount} | others] = portions

    repo().query!(
      "UPDATE credit_applications SET room_ref = ?, amount_cents = ?, updated_at = ? WHERE id = ?",
      [room_ref, amount, now, application.id]
    )

    for {room_ref, amount} <- others do
      repo().query!(
        """
        INSERT INTO credit_applications (group_ref, lot_ref, room_ref, operation_id, amount_cents,
          applied_on, status, settled_on, inserted_at, updated_at)
        SELECT group_ref, lot_ref, ?, operation_id, ?, applied_on, status, settled_on, ?, ?
        FROM credit_applications WHERE id = ?
        """,
        [room_ref, amount, now, now, application.id]
      )
    end
  end
end
