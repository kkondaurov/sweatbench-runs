defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    create table(:allocation_positions) do
    end

    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer
    end

    create table(:transferred_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
    end

    flush()
    backfill_order()
  end

  def down do
    drop table(:transferred_payments)
    alter table(:credit_allocations), do: remove(:allocation_order)
    alter table(:cash_allocations), do: remove(:allocation_order)
    drop table(:allocation_positions)
  end

  defp backfill_order do
    records =
      rows("SELECT operation_id, type, result FROM operations ORDER BY id")
      |> Enum.map(fn record ->
        Map.update!(record, "result", &decode/1)
      end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))
      |> Enum.group_by(& &1["result"]["group_id"])

    for group <- rows("SELECT group_id, rooms FROM groups") do
      rooms = decode(group["rooms"])

      cash =
        rows("SELECT * FROM cash_allocations WHERE group_id = ? ORDER BY id", [group["group_id"]])

      credit =
        rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [
          group["group_id"]
        ])

      history = Map.get(records, group["group_id"], [])

      # Cash retains even its settled slices. Credit slices disappear on settlement,
      # so recover their creation order by replaying allocation mechanics only.
      # No financial balances or journal records are rewritten.
      if Enum.any?(rooms, &(&1["status"] == "active")) do
        legacy_cash = cash |> Enum.filter(&is_nil(&1["payment_operation_id"])) |> sum_amounts()

        legacy_capacity =
          if Enum.any?(history, &(&1["type"] == "open_group")),
            do: 0,
            else: Enum.sum(Enum.map(rooms, & &1["deposit_due_cents"])) - legacy_cash

        slices = recover(rooms, cash, credit, history, legacy_cash, 0, legacy_capacity)
        assign_positions(cash, credit, slices)
      end
    end
  end

  # Legacy credit has no journal identity. Find the senior opening amount that
  # reproduces the retained cash fills and surviving credit. Settled legacy credit
  # may be ambiguous; any such ambiguity is confined to slices no longer held.
  defp recover(rooms, cash, credit, history, legacy_cash, low, high) when low <= high do
    candidate = div(low + high, 2)
    initial = %{rooms: rooms, slices: []}
    initial = fill(initial, nil, legacy_cash)
    initial = fill(initial, :credit, candidate)

    outcome =
      Enum.reduce_while(history, initial, fn record, state ->
        case replay(state, record, cash) do
          direction when direction in [:low, :high] -> {:halt, direction}
          state -> {:cont, state}
        end
      end)

    outcome =
      case outcome do
        direction when direction in [:low, :high] ->
          direction

        state ->
          expected = sum_amounts(credit)

          actual =
            state.slices
            |> Enum.filter(&(&1.identity == :credit))
            |> Enum.map(& &1.amount)
            |> Enum.sum()

          cond do
            actual < expected -> :low
            actual > expected -> :high
            true -> {:ok, state.slices}
          end
      end

    case outcome do
      :low -> recover(rooms, cash, credit, history, legacy_cash, candidate + 1, high)
      :high -> recover(rooms, cash, credit, history, legacy_cash, low, candidate - 1)
      {:ok, slices} -> slices
    end
  end

  defp recover(_rooms, _cash, _credit, _history, _legacy_cash, _low, _high),
    do: raise("Cannot reconstruct historical deposit allocation order")

  defp replay(state, record, cash) do
    result = record["result"]

    case record["type"] do
      "record_cash_payment" ->
        payment_id = record["operation_id"]
        filled = fill(state, payment_id, result["amount_cents"])

        if filled == :high do
          :high
        else
          actual = Enum.filter(filled.slices, &(&1.identity == payment_id))
          expected = Enum.filter(cash, &(&1["payment_operation_id"] == payment_id))

          Enum.reduce_while(state.rooms, filled, fn room, _ ->
            actual_amount =
              actual
              |> Enum.filter(&(&1.room_id == room["room_id"]))
              |> Enum.map(& &1.amount)
              |> Enum.sum()

            expected_amount =
              expected |> Enum.filter(&(&1["room_id"] == room["room_id"])) |> sum_amounts()

            cond do
              actual_amount > expected_amount -> {:halt, :low}
              actual_amount < expected_amount -> {:halt, :high}
              true -> {:cont, filled}
            end
          end)
        end

      "apply_hotel_credit" ->
        fill(state, :credit, result["amount_cents"])

      type when type in ["cancel_group", "cancel_rooms"] ->
        ids =
          if type == "cancel_group",
            do: Enum.map(state.rooms, & &1["room_id"]),
            else: result["cancelled_room_ids"]

        %{
          state
          | rooms: Enum.reject(state.rooms, &(&1["room_id"] in ids)),
            slices: Enum.reject(state.slices, &(&1.room_id in ids))
        }

      type when type in ["reduce_cash_payment", "charge_back_payment"] ->
        payment_id = result["payment_operation_id"]

        amount =
          if type == "reduce_cash_payment",
            do: result["amount_cents"],
            else: result["charged_back_cents"]

        {slices, _} =
          state.slices
          |> Enum.reverse()
          |> Enum.map_reduce(amount, fn slice, remaining ->
            used = if slice.identity == payment_id, do: min(slice.amount, remaining), else: 0
            {%{slice | amount: slice.amount - used}, remaining - used}
          end)

        %{state | slices: slices |> Enum.reverse() |> Enum.reject(&(&1.amount == 0))}

      _ ->
        state
    end
  end

  defp fill(:high, _, _), do: :high

  defp fill(state, identity, amount) do
    {state, remaining} =
      Enum.reduce(state.rooms, {state, amount}, fn room, {state, remaining} ->
        held =
          state.slices
          |> Enum.filter(&(&1.room_id == room["room_id"]))
          |> Enum.map(& &1.amount)
          |> Enum.sum()

        used = min(room["deposit_due_cents"] - held, remaining)

        if used > 0 do
          slice = %{
            identity: identity,
            room_id: room["room_id"],
            amount: used
          }

          {%{state | slices: state.slices ++ [slice]}, remaining - used}
        else
          {state, remaining}
        end
      end)

    if remaining == 0, do: state, else: :high
  end

  defp assign_positions(cash, credit, slices) do
    # A credit application can span multiple lots. Its surviving database rows
    # retain their own ID order within each replayed application/room slice.
    {entries, []} =
      Enum.reduce(slices, {[], credit}, fn slice, {entries, credit} ->
        if slice.identity == :credit do
          {selected, rest} = take_credit(credit, slice.room_id, slice.amount, [])
          {entries ++ Enum.map(selected, &{"credit_allocations", &1["id"]}), rest}
        else
          selected =
            Enum.filter(
              cash,
              &(&1["disposition"] == "held" and &1["payment_operation_id"] == slice.identity and
                  &1["room_id"] == slice.room_id)
            )

          {entries ++ Enum.map(selected, &{"cash_allocations", &1["id"]}), credit}
        end
      end)

    for {table, id} <- entries do
      repo().query!("INSERT INTO allocation_positions DEFAULT VALUES")

      repo().query!("UPDATE #{table} SET allocation_order = last_insert_rowid() WHERE id = ?", [
        id
      ])
    end
  end

  defp take_credit(rows, _room_id, 0, selected), do: {Enum.reverse(selected), rows}

  defp take_credit([row | rows], room_id, amount, selected) do
    if row["room_id"] == room_id do
      take_credit(rows, room_id, amount - row["amount_cents"], [row | selected])
    else
      {selected, rest} = take_credit(rows, room_id, amount, selected)
      {selected, [row | rest]}
    end
  end

  defp sum_amounts(rows), do: Enum.sum(Enum.map(rows, & &1["amount_cents"]))
  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
