defmodule GroupStay.Groups do
  @moduledoc """
  Domain logic for group reservations: opening, funding, rescheduling, and
  cancelling groups, plus the finance totals derived from them.

  Every command runs inside a single transaction so a rejected operation
  leaves the database exactly as it was. Commands return one of:

      {:ok, result_fields}
      {:error, code}
      {:error, :stale_revision, %{group_id:, expected_revision:, actual_revision:}}

  `code` is an atom; the web layer turns these into API payloads.
  """

  import Ecto.Query, only: [from: 2]

  alias GroupStay.Repo
  alias GroupStay.Groups.{Group, Room}

  @rate_plans ~w(flexible advance_purchase)

  ## Queries

  @doc """
  Returns the group with the given partner identifier, with rooms in their
  original order, or nil when no such group exists.
  """
  def get_group(group_id) do
    Repo.one(group_query(group_id))
  end

  @doc """
  Cash accounting totals across all groups:

    * `cash_held_cents` - cash currently applied to active reservations;
    * `cash_refunded_cents` - cash returned after refundable cancellations;
    * `cash_retained_cents` - cash kept by the hotel after non-refundable cancellations.
  """
  def ledger_totals do
    Repo.one!(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.deposit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0)
        }
    )
  end

  ## Opening

  @doc """
  Opens a new group reservation from a raw `open_group` operation payload.

  The stay must span at least one night, at least one room is required, room
  identifiers are unique within the group, and the rate plan must be known.
  Flexible rooms require a 20% deposit rounded per room (half up); advance
  purchase rooms require the full lodging amount.
  """
  def open_group(attrs) do
    with {:ok, params} <- validate_open(attrs) do
      transact(fn ->
        if Repo.exists?(from g in Group, where: g.group_id == ^params.group_id) do
          Repo.rollback({:error, :group_already_exists})
        else
          insert_opened_group(params)
        end
      end)
    end
  end

  defp insert_opened_group(params) do
    %Group{}
    |> Group.open_changeset(params.attrs, params.rooms)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        {:ok,
         %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         }}

      _ ->
        Repo.rollback({:error, :group_already_exists})
    end
  end

  defp validate_open(attrs) do
    with {:ok, booked_on} <- operation_date(attrs["occurred_on"]),
         {:ok, arrival_on} <- stay_date(attrs["arrival_on"]),
         {:ok, departure_on} <- stay_date(attrs["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(attrs["rate_plan"]),
         {:ok, rooms} <- validate_rooms(attrs["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)

      lodgings = Enum.map(rooms, &{&1.room_id, &1.nightly_rate_cents * nights})
      lodging_total = lodgings |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      deposit_due =
        lodgings
        |> Enum.map(fn {_room_id, lodging} -> room_deposit(lodging, rate_plan) end)
        |> Enum.sum()

      room_structs =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, index} ->
          %Room{
            position: index,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents
          }
        end)

      {:ok,
       %{
         group_id: attrs["group_id"],
         deposit_due_cents: deposit_due,
         rooms: room_structs,
         attrs: %{
           group_id: attrs["group_id"],
           guest_id: attrs["guest_id"],
           property_id: attrs["property_id"],
           rate_plan: rate_plan,
           status: "active",
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           revision: 1,
           lodging_total_cents: lodging_total,
           deposit_due_cents: deposit_due,
           deposit_paid_cents: 0
         }
       }}
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) do
      room_ids = Enum.map(rooms, & &1["room_id"])

      if Enum.uniq(room_ids) == room_ids do
        {:ok,
         Enum.map(rooms, fn room ->
           %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
         end)}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 do
    true
  end

  defp valid_room?(_), do: false

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  ## Payments

  @doc """
  Applies a cash payment against the outstanding deposit of an active group.
  """
  def record_cash_payment(group_id, amount_cents, expected_revision) do
    transact(fn ->
      with {:ok, group} <- load_group(group_id),
           :ok <- ensure_revision(group, expected_revision),
           :ok <- ensure_active(group),
           {:ok, outstanding} <- payment_target(group, amount_cents) do
        {:ok, updated} =
          update_group!(group,
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            revision: group.revision + 1
          )

        {:ok,
         %{
           group_id: updated.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding - amount_cents,
           revision: updated.revision
         }}
      end
    end)
  end

  defp payment_target(_group, amount) when not is_integer(amount) or amount <= 0,
    do: {:error, :invalid_amount}

  defp payment_target(group, amount) do
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount > outstanding do
      {:error, :payment_exceeds_outstanding}
    else
      {:ok, outstanding}
    end
  end

  ## Rescheduling

  @doc """
  Moves an active group's stay to a new arrival date, shifting the departure
  by the same number of nights so length and price are unchanged.
  """
  def reschedule_group(group_id, new_arrival_on, occurred_on, expected_revision) do
    transact(fn ->
      with {:ok, occurred_on} <- operation_date(occurred_on),
           {:ok, group} <- load_group(group_id),
           :ok <- ensure_revision(group, expected_revision),
           :ok <- ensure_active(group),
           {:ok, new_arrival} <- movable_date(new_arrival_on, occurred_on) do
        nights = Date.diff(group.departure_on, group.arrival_on)
        new_departure = Date.add(new_arrival, nights)

        {:ok, updated} =
          update_group!(group,
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: group.revision + 1
          )

        {:ok,
         %{
           group_id: updated.group_id,
           new_arrival_on: updated.arrival_on,
           new_departure_on: updated.departure_on,
           revision: updated.revision
         }}
      end
    end)
  end

  defp movable_date(value, occurred_on) do
    case to_date(value) do
      {:ok, date} ->
        if Date.compare(date, occurred_on) == :gt do
          {:ok, date}
        else
          {:error, :invalid_stay}
        end

      _ ->
        {:error, :invalid_stay}
    end
  end

  ## Cancellation

  @doc """
  Cancels an active group.

  Flexible reservations cancelled at least 14 calendar days before arrival get
  their paid cash refunded; otherwise the cash is retained. Advance purchase
  reservations never get refunds. Unpaid deposit is no longer due.
  """
  def cancel_group(group_id, occurred_on, expected_revision) do
    transact(fn ->
      with {:ok, occurred_on} <- operation_date(occurred_on),
           {:ok, group} <- load_group(group_id),
           :ok <- ensure_revision(group, expected_revision),
           :ok <- ensure_active(group) do
        {refunded, retained} = settlement(group, occurred_on)

        {:ok, updated} =
          update_group!(group,
            status: "cancelled",
            deposit_due_cents: 0,
            deposit_paid_cents: 0,
            refunded_cents: group.refunded_cents + refunded,
            retained_cents: group.retained_cents + retained,
            revision: group.revision + 1
          )

        {:ok,
         %{
           group_id: updated.group_id,
           refunded_cents: refunded,
           retained_cents: retained,
           revision: updated.revision
         }}
      end
    end)
  end

  defp settlement(group, occurred_on) do
    refundable? =
      group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    paid = group.deposit_paid_cents

    if refundable? do
      {paid, 0}
    else
      {0, paid}
    end
  end

  ## Shared helpers

  defp group_query(group_id) do
    rooms_query = from r in Room, order_by: r.position

    from g in Group,
      where: g.group_id == ^group_id,
      preload: [rooms: ^rooms_query]
  end

  defp load_group(group_id) do
    case Repo.one(group_query(group_id)) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp ensure_revision(_group, :none), do: :ok

  defp ensure_revision(group, expected_revision) do
    if expected_revision == group.revision do
      :ok
    else
      {:error, :stale_revision,
       %{
         group_id: group.group_id,
         expected_revision: expected_revision,
         actual_revision: group.revision
       }}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, :group_not_active}

  defp operation_date(value) do
    case to_date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_operation}
    end
  end

  defp stay_date(value) do
    case to_date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_stay}
    end
  end

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp to_date(_), do: {:error, :invalid_date}

  defp update_group!(group, changes) do
    group
    |> Group.update_changeset(Map.new(changes))
    |> Repo.update()
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> value
      {:error, reason} -> reason
    end
  end
end
