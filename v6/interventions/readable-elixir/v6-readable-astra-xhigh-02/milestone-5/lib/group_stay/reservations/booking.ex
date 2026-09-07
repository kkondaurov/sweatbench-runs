defmodule GroupStay.Reservations.Booking do
  @moduledoc """
  Validates partner booking details and prices room deposits using integer cents.
  Percentage deposits are rounded per room before summing, never on the group total.
  """

  # SQLite stores signed 64-bit integers. Reject unrepresentable room prices before
  # persistence so a malformed operation cannot interrupt the rest of its batch.
  @max_cents 9_223_372_036_854_775_807

  def identifier?(value), do: is_binary(value) and byte_size(value) > 0

  def date(value) when is_binary(value), do: Date.from_iso8601(value)
  def date(_value), do: {:error, :invalid_format}

  def required_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: {:error, :invalid_operation}
  end

  def open_attributes(operation) do
    with :ok <-
           required_fields(
             operation,
             ~w(guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         :ok <- validate_identifiers(operation),
         {:ok, arrival, departure} <- stay(operation),
         :ok <- rate_plan(operation["rate_plan"]),
         {:ok, rooms, lodging, deposit} <-
           price_rooms(operation["rooms"], Date.diff(departure, arrival), operation["rate_plan"]) do
      {:ok,
       %{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         arrival_on: arrival,
         departure_on: departure,
         rate_plan: operation["rate_plan"],
         rooms: rooms,
         lodging_total_cents: lodging,
         deposit_due_cents: deposit
       }}
    end
  end

  defp validate_identifiers(operation) do
    if identifier?(operation["guest_id"]) and identifier?(operation["property_id"]),
      do: :ok,
      else: {:error, :invalid_operation}
  end

  defp stay(operation) do
    with {:ok, arrival} <- date(operation["arrival_on"]),
         {:ok, departure} <- date(operation["departure_on"]),
         true <- Date.compare(departure, arrival) == :gt do
      {:ok, arrival, departure}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp rate_plan(plan) when plan in ["flexible", "advance_purchase"], do: :ok
  defp rate_plan(_plan), do: {:error, :invalid_rate_plan}

  defp price_rooms([_ | _] = rooms, nights, plan) do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      priced_rooms =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          %{
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            lodging_total_cents: nights * room["nightly_rate_cents"],
            deposit_due_cents: room_deposit(nights * room["nightly_rate_cents"], plan),
            position: position
          }
        end)

      {lodging, deposit} =
        Enum.reduce(priced_rooms, {0, 0}, fn room, {lodging, deposit} ->
          {lodging + room.lodging_total_cents, deposit + room.deposit_due_cents}
        end)

      if lodging <= @max_cents,
        do: {:ok, priced_rooms, lodging, deposit},
        else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp price_rooms(_rooms, _nights, _plan), do: {:error, :invalid_rooms}

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}) do
    identifier?(id) and is_integer(rate) and rate >= 0
  end

  defp valid_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(Enum.uniq(ids)) == length(ids)
  end

  defp room_deposit(lodging, "advance_purchase"), do: lodging
  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
end
