defmodule GroupStay.Reservations.Booking do
  @moduledoc """
  Validates booking details and calculates deposits using integer cents only.
  Flexible deposits round per room, before summing the group's requirement.
  """

  alias GroupStay.Reservations.{CancellationPolicy, Group}

  # SQLite stores monetary values as signed 64-bit integers.
  @max_cents 9_223_372_036_854_775_807

  def build(operation, booked_on) do
    with {:ok, arrival} <- date(operation["arrival_on"]),
         {:ok, departure} <- date(operation["departure_on"]),
         nights when nights > 0 <- Date.diff(departure, arrival),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- rooms(operation["rooms"]),
         {:ok, lodging, deposit} <- totals(rooms, nights, operation["rate_plan"]) do
      {:ok,
       %Group{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival,
         departure_on: departure,
         rate_plan: operation["rate_plan"],
         policy_version: CancellationPolicy.version(operation["rate_plan"], booked_on),
         rooms: rooms,
         lodging_total_cents: lodging,
         deposit_due_cents: deposit
       }}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_stay"}
    end
  end

  def date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_stay"}
    end
  end

  def date(_), do: {:error, "invalid_stay"}

  defp validate_rate_plan(plan) when plan in ["flexible", "advance_purchase"], do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and
         length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) do
      {:ok,
       Enum.map(rooms, fn room ->
         %Group.Room{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp rooms(_), do: {:error, "invalid_rooms"}

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}) do
    is_binary(id) and id != "" and is_integer(rate) and rate >= 0 and rate <= @max_cents
  end

  defp valid_room?(_), do: false

  defp totals(rooms, nights, plan) do
    {lodging, deposit} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging, deposit} ->
        amount = nights * room.nightly_rate_cents
        due = if plan == "flexible", do: div(amount * 20 + 50, 100), else: amount
        {lodging + amount, deposit + due}
      end)

    if lodging <= @max_cents,
      do: {:ok, lodging, deposit},
      else: {:error, "invalid_rooms"}
  end
end
