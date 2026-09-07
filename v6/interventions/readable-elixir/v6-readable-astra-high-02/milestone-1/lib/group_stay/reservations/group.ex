defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A reservation and its deposit balances.

  Deposit due and paid describe the current obligation. Cancellation clears both and
  moves paid cash into a permanent refunded or retained settlement. Lodging prices and
  the original rooms remain available after cancellation.

  All percentage calculations use integer arithmetic and round each room separately.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{Operation, Room}

  # SQLite stores integer amounts in signed 64-bit columns.
  @max_cents 9_223_372_036_854_775_807
  @primary_key {:group_id, :string, autogenerate: false}

  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, Ecto.Enum, values: [:flexible, :advance_purchase]
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0

    has_many :rooms, Room,
      foreign_key: :group_id,
      references: :group_id,
      preload_order: [asc: :position]
  end

  def outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  def open(operation, booked_on) do
    with {:ok, arrival, departure} <- stay(operation),
         {:ok, rate_plan} <- rate_plan(operation["rate_plan"]),
         {:ok, rooms, lodging, deposit} <-
           price_rooms(operation["rooms"], Date.diff(departure, arrival), rate_plan) do
      changeset =
        %__MODULE__{}
        |> change(%{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: rate_plan,
          lodging_total_cents: lodging,
          deposit_due_cents: deposit
        })
        |> put_assoc(:rooms, rooms)

      {:ok, changeset, %{deposit_due_cents: deposit}}
    end
  end

  def pay(group, amount) do
    cond do
      not is_integer(amount) or amount <= 0 or amount > @max_cents ->
        {:error, "invalid_amount"}

      amount > outstanding_deposit(group) ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        {:ok, change(group, deposit_paid_cents: group.deposit_paid_cents + amount),
         %{amount_cents: amount, outstanding_deposit_cents: outstanding_deposit(group) - amount}}
    end
  end

  def reschedule(group, new_arrival_on, occurred_on) do
    with {:ok, arrival} <- Operation.date(new_arrival_on),
         :gt <- Date.compare(arrival, occurred_on),
         {:ok, departure} <- shift_departure(group, arrival) do
      {:ok, change(group, arrival_on: arrival, departure_on: departure),
       %{new_arrival_on: arrival, new_departure_on: departure}}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  def cancel(group, occurred_on) do
    refundable? = group.rate_plan == :flexible and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable?, do: group.deposit_paid_cents, else: 0
    retained = if refundable?, do: 0, else: group.deposit_paid_cents

    changeset =
      change(group,
        status: :cancelled,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_refunded_cents: refunded,
        cash_retained_cents: retained
      )

    {:ok, changeset, %{refunded_cents: refunded, retained_cents: retained}}
  end

  defp stay(operation) do
    with {:ok, arrival} <- Operation.date(operation["arrival_on"]),
         {:ok, departure} <- Operation.date(operation["departure_on"]),
         :gt <- Date.compare(departure, arrival) do
      {:ok, arrival, departure}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp rate_plan("flexible"), do: {:ok, :flexible}
  defp rate_plan("advance_purchase"), do: {:ok, :advance_purchase}
  defp rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp price_rooms(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      priced_rooms =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          %Room{
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position
          }
        end)

      lodging = Enum.sum(Enum.map(priced_rooms, &(&1.nightly_rate_cents * nights)))

      deposit =
        Enum.sum(Enum.map(priced_rooms, &room_deposit(&1.nightly_rate_cents * nights, rate_plan)))

      if lodging <= @max_cents do
        {:ok, priced_rooms, lodging, deposit}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp price_rooms(_, _, _), do: {:error, "invalid_rooms"}

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}) do
    Operation.identifier?(id) and is_integer(rate) and rate >= 0 and rate <= @max_cents
  end

  defp valid_room?(_), do: false

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(Enum.uniq(ids)) == length(ids)
  end

  defp room_deposit(lodging, :flexible), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, :advance_purchase), do: lodging

  defp shift_departure(group, arrival) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    # Keep the resulting departure representable as an ISO 8601 calendar date.
    if nights <= Date.diff(~D[9999-12-31], arrival) do
      {:ok, Date.add(arrival, nights)}
    else
      {:error, :invalid_date}
    end
  end
end
