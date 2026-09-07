defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group booking and the deposit currently applied to it.

  Money is calculated in integer cents, rounding each room's deposit separately.
  Current group balances sum active rooms. Cancelled rooms retain their
  agreed prices, while funding history remains in the accounting records.

  The transition functions return changesets without writing to the database.
  The reservations context commits each transition with its accounting records.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.{CancellationPolicy, Operation, Room, RoomAccounting}

  # SQLite stores monetary columns as signed 64-bit integers.
  @max_cents 9_223_372_036_854_775_807

  @primary_key {:group_id, :string, autogenerate: false}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, Ecto.Enum, values: [:flexible, :advance_purchase]
    field :policy_version, :string
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    embeds_many :rooms, Room, on_replace: :delete

    timestamps(type: :utc_datetime_usec)
  end

  def open(operation, booked_on) do
    with :ok <- validate_identifiers(operation),
         {:ok, arrival_on, departure_on} <- stay_dates(operation),
         {:ok, rate_plan} <- rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- rooms(operation["rooms"]),
         {:ok, rooms, lodging, deposit} <- price(rooms, arrival_on, departure_on, rate_plan) do
      {:ok,
       %__MODULE__{}
       |> change(%{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         policy_version: CancellationPolicy.version(rate_plan, booked_on),
         lodging_total_cents: lodging,
         deposit_due_cents: deposit
       })
       |> put_embed(:rooms, rooms)}
    end
  end

  @doc "Derives current totals from rooms and advances the group exactly once."
  def update_rooms(group, rooms) do
    group
    |> change(Map.put(RoomAccounting.totals(rooms), :revision, group.revision + 1))
    |> put_embed(:rooms, rooms)
  end

  def reschedule(group, new_arrival, occurred_on) do
    with {:ok, arrival_on} <- Operation.date(new_arrival),
         :gt <- Date.compare(arrival_on, occurred_on) do
      departure_on = Date.add(arrival_on, Date.diff(group.departure_on, group.arrival_on))

      if departure_on.year <= 9999 do
        {:ok, advance(group, arrival_on: arrival_on, departure_on: departure_on)}
      else
        {:error, :invalid_stay}
      end
    else
      _ -> {:error, :invalid_stay}
    end
  end

  def outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents
  def cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents

  defp advance(group, attributes) do
    change(group, Keyword.put(attributes, :revision, group.revision + 1))
  end

  def validate_payment(group, amount) do
    cond do
      not is_integer(amount) or amount <= 0 or amount > @max_cents ->
        {:error, :invalid_amount}

      amount > outstanding_deposit(group) ->
        {:error, :payment_exceeds_outstanding}

      true ->
        :ok
    end
  end

  defp validate_identifiers(operation) do
    if Operation.identifier?(operation["guest_id"]) and
         Operation.identifier?(operation["property_id"]) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  defp stay_dates(operation) do
    with {:ok, arrival} <- Operation.date(operation["arrival_on"]),
         {:ok, departure} <- Operation.date(operation["departure_on"]),
         :gt <- Date.compare(departure, arrival) do
      {:ok, arrival, departure}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp rate_plan("flexible"), do: {:ok, :flexible}
  defp rate_plan("advance_purchase"), do: {:ok, :advance_purchase}
  defp rate_plan(_), do: {:error, :invalid_rate_plan}

  defp rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok,
       Enum.map(rooms, fn room ->
         %Room{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp rooms(_), do: {:error, :invalid_rooms}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate}) do
    Operation.identifier?(room_id) and is_integer(rate) and rate >= 0 and rate <= @max_cents
  end

  defp valid_room?(_), do: false

  defp unique_room_ids?(rooms) do
    rooms |> Enum.map(& &1["room_id"]) |> Enum.uniq() |> length() == length(rooms)
  end

  defp price(rooms, arrival, departure, rate_plan) do
    nights = Date.diff(departure, arrival)

    rooms =
      Enum.map(rooms, fn room ->
        lodging = room.nightly_rate_cents * nights

        %{
          room
          | lodging_total_cents: lodging,
            deposit_due_cents: room_deposit(lodging, rate_plan)
        }
      end)

    lodging = RoomAccounting.sum(rooms, :lodging_total_cents)
    deposit = RoomAccounting.sum(rooms, :deposit_due_cents)

    if lodging <= @max_cents do
      {:ok, rooms, lodging, deposit}
    else
      {:error, :invalid_rooms}
    end
  end

  defp room_deposit(lodging, :flexible), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, :advance_purchase), do: lodging
end
