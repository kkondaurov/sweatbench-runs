defmodule GroupStay.Reservations.Pricing do
  @moduledoc """
  Deposit pricing in integer cents. Each room is rounded before summing, using
  half-up rounding without floating-point arithmetic.
  """

  alias GroupStay.Reservations.Operation

  # SQLite stores monetary columns as signed 64-bit integers.
  @max_cents 9_223_372_036_854_775_807

  def quote(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {lodging, deposit} =
        Enum.reduce(rooms, {0, 0}, fn room, {lodging, deposit} ->
          room_total = room["nightly_rate_cents"] * nights
          {lodging + room_total, deposit + room_deposit(room_total, rate_plan)}
        end)

      if lodging <= @max_cents do
        {:ok, %{lodging_total_cents: lodging, deposit_due_cents: deposit}}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  def quote(_, _, _), do: {:error, "invalid_rooms"}

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}) do
    Operation.identifier?(id) and is_integer(rate) and rate >= 0
  end

  defp valid_room?(_), do: false

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(Enum.uniq(ids)) == length(ids)
  end

  defp room_deposit(lodging, :flexible), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, :advance_purchase), do: lodging
end
