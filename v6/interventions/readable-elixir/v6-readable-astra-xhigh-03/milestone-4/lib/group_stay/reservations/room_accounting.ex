defmodule GroupStay.Reservations.RoomAccounting do
  @moduledoc """
  Pure room accounting in the booking's original order.

  Funding fills the earliest outstanding room. Settlement clears current room
  balances but preserves the agreed rate and lodging price for support history.
  Group balances are always derived from active rooms.
  """

  def fund(rooms, amount, field) when field in [:cash_paid_cents, :credit_paid_cents] do
    {rooms, {0, portions}} =
      Enum.map_reduce(rooms, {amount, []}, fn room, {remaining, portions} ->
        funded = if room.status == :active, do: min(outstanding(room), remaining), else: 0
        room = Map.update!(room, field, &(&1 + funded))
        portions = if funded > 0, do: [{room.room_id, funded} | portions], else: portions
        {room, {remaining - funded, portions}}
      end)

    {rooms, Enum.reverse(portions)}
  end

  def select(rooms, identifiers) when is_list(identifiers) and identifiers != [] do
    selected = Enum.filter(rooms, &(&1.status == :active and &1.room_id in identifiers))

    if length(selected) == length(identifiers),
      do: {:ok, selected},
      else: {:error, :invalid_rooms}
  end

  def select(_rooms, _identifiers), do: {:error, :invalid_rooms}

  def cancel(rooms, identifiers) do
    Enum.map(rooms, fn room ->
      if room.room_id in identifiers do
        %{
          room
          | status: :cancelled,
            deposit_due_cents: 0,
            cash_paid_cents: 0,
            credit_paid_cents: 0
        }
      else
        room
      end
    end)
  end

  def remove_cash(rooms, portions) do
    removed =
      Enum.reduce(portions, %{}, fn {id, amount}, acc ->
        Map.update(acc, id, amount, &(&1 + amount))
      end)

    Enum.map(
      rooms,
      &%{&1 | cash_paid_cents: &1.cash_paid_cents - Map.get(removed, &1.room_id, 0)}
    )
  end

  def totals(rooms) do
    active = Enum.filter(rooms, &(&1.status == :active))
    cash = sum(active, :cash_paid_cents)
    credit = sum(active, :credit_paid_cents)

    %{
      status: if(active == [], do: :cancelled, else: :active),
      lodging_total_cents: sum(active, :lodging_total_cents),
      deposit_due_cents: sum(active, :deposit_due_cents),
      deposit_paid_cents: cash + credit,
      credit_paid_cents: credit
    }
  end

  def sum(rooms, field), do: Enum.reduce(rooms, 0, &(&2 + Map.fetch!(&1, field)))

  defp outstanding(room),
    do: room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
end
