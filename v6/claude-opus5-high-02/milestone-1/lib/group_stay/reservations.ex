defmodule GroupStay.Reservations do
  @moduledoc """
  Group reservations, their deposits, and the finance totals derived from them.

  Every partner operation is applied through `apply_operation/1`, which either applies the whole
  operation or leaves the database exactly as it was.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Partner.Operation
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  @flexible_deposit_percent 20
  @refundable_window_days 14

  @doc """
  Returns the group with the given partner identifier, with its rooms in their original order.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> Repo.preload(:rooms)
  end

  @doc """
  Cash totals across all groups.
  """
  def ledger_totals do
    active = from(g in Group, where: g.status == "active")

    %{
      cash_held_cents: sum_of(active, :deposit_paid_cents),
      cash_refunded_cents: sum_of(Group, :cash_refunded_cents),
      cash_retained_cents: sum_of(Group, :cash_retained_cents)
    }
  end

  defp sum_of(queryable, field), do: Repo.aggregate(queryable, :sum, field) || 0

  @doc """
  Applies a parsed partner operation.

  Returns `{:ok, result}` with the fields the API reports for an applied operation, or
  `{:error, code, details}` where `details` carries any extra fields the rejection reports.
  """
  def apply_operation(%Operation{type: :open_group} = operation) do
    transaction(fn -> open_group(operation) end)
  end

  def apply_operation(%Operation{} = operation) do
    transaction(fn ->
      # Existence is resolved first, and a stale revision is rejected before any other domain rule.
      with {:ok, group} <- fetch_group(operation.group_id),
           :ok <- check_revision(group, operation.expected_revision) do
        apply_to_group(operation, group)
      end
    end)
  end

  defp apply_to_group(%Operation{type: :record_cash_payment} = operation, group),
    do: record_cash_payment(operation, group)

  defp apply_to_group(%Operation{type: :reschedule_group} = operation, group),
    do: reschedule_group(operation, group)

  defp apply_to_group(%Operation{type: :cancel_group} = operation, group),
    do: cancel_group(operation, group)

  ## Opening a group

  defp open_group(%Operation{data: data} = operation) do
    with :ok <- ensure_group_absent(operation.group_id),
         {:ok, arrival_on, departure_on, nights} <- validate_stay(data),
         {:ok, rooms} <- validate_rooms(data["rooms"]),
         {:ok, rate_plan} <- validate_rate_plan(data["rate_plan"]) do
      priced = Enum.map(rooms, &price_room(&1, nights, rate_plan))

      group =
        Repo.insert!(%Group{
          group_id: operation.group_id,
          guest_id: data["guest_id"],
          property_id: data["property_id"],
          booked_on: operation.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: "active",
          revision: 1,
          lodging_total_cents: Enum.sum(Enum.map(priced, & &1.lodging_cents)),
          deposit_due_cents: Enum.sum(Enum.map(priced, & &1.deposit_cents)),
          deposit_paid_cents: 0,
          rooms: priced
        })

      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    end
  end

  defp price_room(room, nights, rate_plan) do
    lodging_cents = nights * room.nightly_rate_cents

    %Room{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_cents: lodging_cents,
      deposit_cents: room_deposit_cents(lodging_cents, rate_plan),
      position: room.position
    }
  end

  defp room_deposit_cents(lodging_cents, "advance_purchase"), do: lodging_cents

  defp room_deposit_cents(lodging_cents, "flexible"),
    do: percent_of(lodging_cents, @flexible_deposit_percent)

  # Rounds to the nearest cent, with an exact half-cent rounding upward.
  defp percent_of(amount_cents, percent), do: div(amount_cents * percent + 50, 100)

  defp ensure_group_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp validate_stay(data) do
    with {:ok, arrival_on} <- parse_date(data["arrival_on"]),
         {:ok, departure_on} <- parse_date(data["departure_on"]),
         nights when nights >= 1 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, index}, {:ok, acc} ->
      case validate_room(room, index, acc) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp validate_room(%{"room_id" => room_id, "nightly_rate_cents" => rate}, index, seen)
       when is_binary(room_id) and is_integer(rate) and rate >= 0 do
    cond do
      String.trim(room_id) == "" -> {:error, :invalid_rooms}
      Enum.any?(seen, &(&1.room_id == room_id)) -> {:error, :invalid_rooms}
      true -> {:ok, %{room_id: room_id, nightly_rate_cents: rate, position: index}}
    end
  end

  defp validate_room(_room, _index, _seen), do: {:error, :invalid_rooms}

  defp validate_rate_plan(rate_plan) when is_binary(rate_plan) do
    if rate_plan in Group.rate_plans() do
      {:ok, rate_plan}
    else
      {:error, :invalid_rate_plan}
    end
  end

  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  ## Recording cash

  defp record_cash_payment(%Operation{data: data}, group) do
    with :ok <- ensure_active(group),
         {:ok, amount_cents} <- validate_amount(data["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      group =
        group
        |> change(deposit_paid_cents: group.deposit_paid_cents + amount_cents)
        |> Repo.update!()

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp validate_amount(_amount), do: {:error, :invalid_amount}

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents > Group.outstanding_deposit_cents(group) do
      {:error, :payment_exceeds_outstanding}
    else
      :ok
    end
  end

  ## Rescheduling

  defp reschedule_group(%Operation{data: data} = operation, group) do
    with :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- validate_new_arrival(data["new_arrival_on"], operation) do
      # The stay keeps its length, so the departure moves by the same number of calendar days.
      new_departure_on = Date.add(group.departure_on, Date.diff(new_arrival_on, group.arrival_on))

      group =
        group
        |> change(arrival_on: new_arrival_on, departure_on: new_departure_on)
        |> Repo.update!()

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         revision: group.revision
       }}
    end
  end

  defp validate_new_arrival(value, %Operation{occurred_on: occurred_on}) do
    case parse_date(value) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:error, :invalid_stay}
        end

      _ ->
        {:error, :invalid_stay}
    end
  end

  ## Cancelling

  defp cancel_group(%Operation{occurred_on: occurred_on}, group) do
    with :ok <- ensure_active(group) do
      refunded_cents = if refundable?(group, occurred_on), do: group.deposit_paid_cents, else: 0
      retained_cents = group.deposit_paid_cents - refunded_cents

      group =
        group
        |> change(
          status: "cancelled",
          cash_refunded_cents: refunded_cents,
          cash_retained_cents: retained_cents
        )
        |> Repo.update!()

      {:ok,
       %{
         group_id: group.group_id,
         refunded_cents: group.cash_refunded_cents,
         retained_cents: group.cash_retained_cents,
         revision: group.revision
       }}
    end
  end

  defp refundable?(%Group{rate_plan: "flexible"} = group, occurred_on),
    do: Date.diff(group.arrival_on, occurred_on) >= @refundable_window_days

  defp refundable?(%Group{}, _occurred_on), do: false

  ## Shared group handling

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_revision(_group, nil), do: :ok

  defp check_revision(%Group{revision: revision}, expected) when revision == expected, do: :ok

  defp check_revision(%Group{} = group, expected) do
    {:error,
     {:stale_revision,
      %{
        group_id: group.group_id,
        expected_revision: expected,
        actual_revision: group.revision
      }}}
  end

  defp ensure_active(group) do
    if Group.active?(group), do: :ok, else: {:error, :group_not_active}
  end

  # Every applied operation addressed to an existing group increments its revision exactly once,
  # even when it leaves the visible booking fields alone. The revision is also the optimistic lock,
  # so the write refuses to run over a row that moved underneath it. Forcing the revision change
  # keeps `Repo.update` from skipping an otherwise empty update.
  defp change(group, changes) do
    group
    |> Changeset.change(changes)
    |> Changeset.optimistic_lock(:revision)
    |> Changeset.force_change(:revision, group.revision + 1)
  end

  ## Transaction handling

  # An operation is applied whole or not at all, so a rejection leaves the database exactly as it
  # was. The transaction takes its write lock upfront, so the revision an operation checks is still
  # the group's revision when the operation writes.
  defp transaction(fun) do
    result =
      Repo.transaction(
        fn ->
          case fun.() do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, applied} -> {:ok, applied}
      {:error, {code, details}} -> {:error, code, details}
      {:error, code} -> {:error, code, %{}}
    end
  end
end
