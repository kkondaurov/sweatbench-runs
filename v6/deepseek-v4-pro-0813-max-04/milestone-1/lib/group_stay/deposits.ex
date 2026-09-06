defmodule GroupStay.Deposits do
  @moduledoc """
  Group deposit records and the partner operations that maintain them.

  Every partner operation is applied inside its own transaction: a rejected
  operation rolls back completely and the batch continues with the next one.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Deposits.{Group, Room}
  alias GroupStay.Repo

  @operation_types ~w[open_group record_cash_payment reschedule_group cancel_group]
  @rate_plans ~w[flexible advance_purchase]
  @flexible_deposit_percent 20

  @doc """
  Applies a batch of raw partner operations in order, returning one result
  map per operation.
  """
  def submit(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @doc "Returns `{:ok, props}` for an existing group or `{:error, :not_found}`."
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, render_group(group)}
    end
  end

  @doc "Returns the finance totals: cash held, refunded and retained."
  def ledger do
    %{
      cash_held_cents:
        Repo.aggregate(where(Group, [g], g.status == "active"), :sum, :deposit_paid_cents) || 0,
      cash_refunded_cents: Repo.aggregate(Group, :sum, :refunded_cents) || 0,
      cash_retained_cents: Repo.aggregate(Group, :sum, :retained_cents) || 0
    }
  end

  defp submit_operation(raw) do
    case Repo.transaction(fn -> apply_operation(raw) end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_operation(raw) do
    case decode_operation(raw) do
      {:ok, op} -> apply_decoded(op)
      {:error, code} -> Repo.rollback(rejected_raw(raw, code))
    end
  end

  defp apply_decoded(%{type: "open_group"} = op), do: apply_open(op)
  defp apply_decoded(%{type: "record_cash_payment"} = op), do: apply_payment(op)
  defp apply_decoded(%{type: "reschedule_group"} = op), do: apply_reschedule(op)
  defp apply_decoded(%{type: "cancel_group"} = op), do: apply_cancel(op)

  ## Operation decoding (structure -> invalid_operation)

  defp decode_operation(raw) when is_map(raw) do
    with {:ok, type} <- type_of(raw),
         {:ok, operation_id} <- string_field(raw, "operation_id"),
         {:ok, occurred_on} <- occurred_on_of(raw) do
      base = %{operation_id: operation_id, occurred_on: occurred_on}

      case type do
        "open_group" -> decode_open(raw, base)
        "record_cash_payment" -> decode_payment(raw, base)
        "reschedule_group" -> decode_reschedule(raw, base)
        "cancel_group" -> decode_cancel(raw, base)
      end
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_operation(_), do: {:error, "invalid_operation"}

  defp decode_open(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         {:ok, guest_id} <- string_field(raw, "guest_id"),
         {:ok, property_id} <- string_field(raw, "property_id"),
         {:ok, rate_plan} <- string_field(raw, "rate_plan"),
         {:ok, arrival_on} <- string_field(raw, "arrival_on"),
         {:ok, departure_on} <- string_field(raw, "departure_on"),
         {:ok, rooms} <- rooms_field(raw) do
      {:ok,
       Map.merge(base, %{
         type: "open_group",
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         rate_plan: rate_plan,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rooms: rooms
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_payment(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         :ok <- amount_present?(raw),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "record_cash_payment",
         group_id: group_id,
         amount_cents: Map.get(raw, "amount_cents"),
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_reschedule(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         {:ok, new_arrival_on} <- string_field(raw, "new_arrival_on"),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "reschedule_group",
         group_id: group_id,
         new_arrival_on: new_arrival_on,
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_cancel(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "cancel_group",
         group_id: group_id,
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp type_of(raw) do
    case Map.fetch(raw, "type") do
      {:ok, type} when type in @operation_types -> {:ok, type}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp string_field(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp occurred_on_of(raw) do
    case Map.fetch(raw, "occurred_on") do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_operation"}
        end

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp amount_present?(raw) do
    if Map.has_key?(raw, "amount_cents"), do: :ok, else: {:error, "invalid_operation"}
  end

  defp optional_revision(raw) do
    case Map.fetch(raw, "expected_revision") do
      :error -> {:ok, nil}
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp rooms_field(raw) do
    case raw do
      %{"rooms" => rooms} when is_list(rooms) ->
        normalize_rooms(rooms)

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp normalize_rooms(rooms) do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, acc} ->
      case normalize_room(room) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and is_integer(rate) do
    {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
  end

  defp normalize_room(_), do: {:error, "invalid_operation"}

  ## open_group

  defp apply_open(op) do
    with :ok <- ensure_group_unknown(op.group_id),
         {:ok, {arrival, departure, nights}} <- stay_dates(op),
         :ok <- validate_rooms(op.rooms),
         :ok <- validate_rate_plan(op.rate_plan) do
      {lodging_total, deposit_due} = compute_amounts(op.rooms, nights, op.rate_plan)

      group =
        Repo.insert!(%Group{
          group_id: op.group_id,
          guest_id: op.guest_id,
          property_id: op.property_id,
          booked_on: op.occurred_on,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op.rate_plan,
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          outstanding_deposit_cents: deposit_due,
          refunded_cents: 0,
          retained_cents: 0
        })

      Enum.each(op.rooms, fn room ->
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents
        })
      end)

      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:error, code} -> Repo.rollback(rejected(op, code))
    end
  end

  defp ensure_group_unknown(group_id) do
    if Repo.get_by(Group, group_id: group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp stay_dates(op) do
    with {:ok, arrival} <- Date.from_iso8601(op.arrival_on),
         {:ok, departure} <- Date.from_iso8601(op.departure_on) do
      nights = Date.diff(departure, arrival)

      if nights >= 1,
        do: {:ok, {arrival, departure, nights}},
        else: {:error, "invalid_stay"}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms([]), do: {:error, "invalid_rooms"}

  defp validate_rooms(rooms) do
    ids = Enum.map(rooms, & &1.room_id)

    cond do
      length(Enum.uniq(ids)) != length(ids) -> {:error, "invalid_rooms"}
      Enum.any?(rooms, &(&1.nightly_rate_cents < 0)) -> {:error, "invalid_rooms"}
      true -> :ok
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp compute_amounts(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_total, deposit_total} ->
      lodging = nights * room.nightly_rate_cents
      {lodging_total + lodging, deposit_total + room_deposit(lodging, rate_plan)}
    end)
  end

  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp room_deposit(lodging, "flexible"),
    do: percent_round_half_up(lodging, @flexible_deposit_percent)

  # Percentage calculations round to the nearest cent; an exact half-cent rounds
  # upward. Implemented with integer arithmetic so it cannot drift on floats.
  defp percent_round_half_up(amount, percent) do
    numerator = amount * percent

    if rem(numerator, 100) * 2 >= 100,
      do: div(numerator, 100) + 1,
      else: div(numerator, 100)
  end

  ## record_cash_payment

  defp apply_payment(op) do
    case find_group(op) do
      {:error, code} ->
        Repo.rollback(rejected(op, code))

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             :ok <- validate_amount(op.amount_cents),
             :ok <- validate_outstanding(group, op.amount_cents) do
          changes = %{
            deposit_paid_cents: group.deposit_paid_cents + op.amount_cents,
            outstanding_deposit_cents: group.outstanding_deposit_cents - op.amount_cents,
            revision: group.revision + 1
          }

          update_group(group, changes)

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            amount_cents: op.amount_cents,
            outstanding_deposit_cents: changes.outstanding_deposit_cents,
            revision: changes.revision
          }
        else
          {:error, code} -> Repo.rollback(rejected(op, code))
          {:stale, expected, actual} -> Repo.rollback(stale_rejected(op, group, expected, actual))
        end
    end
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_), do: {:error, "invalid_amount"}

  defp validate_outstanding(%Group{outstanding_deposit_cents: outstanding}, amount)
       when amount <= outstanding do
    :ok
  end

  defp validate_outstanding(_, _), do: {:error, "payment_exceeds_outstanding"}

  ## reschedule_group

  defp apply_reschedule(op) do
    case find_group(op) do
      {:error, code} ->
        Repo.rollback(rejected(op, code))

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             {:ok, new_arrival} <- resolvable_new_arrival(op.new_arrival_on, op.occurred_on) do
          shift = Date.diff(new_arrival, group.arrival_on)
          new_departure = Date.add(group.departure_on, shift)
          revision = group.revision + 1

          update_group(group, %{
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: revision
          })

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            new_arrival_on: new_arrival,
            new_departure_on: new_departure,
            revision: revision
          }
        else
          {:error, code} -> Repo.rollback(rejected(op, code))
          {:stale, expected, actual} -> Repo.rollback(stale_rejected(op, group, expected, actual))
        end
    end
  end

  defp resolvable_new_arrival(value, occurred_on) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         :gt <- Date.compare(date, occurred_on) do
      {:ok, date}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp resolvable_new_arrival(_, _), do: {:error, "invalid_stay"}

  ## cancel_group

  defp apply_cancel(op) do
    case find_group(op) do
      {:error, code} ->
        Repo.rollback(rejected(op, code))

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group) do
          refunded = if refundable?(group, op.occurred_on), do: group.deposit_paid_cents, else: 0
          retained = group.deposit_paid_cents - refunded
          revision = group.revision + 1

          update_group(group, %{
            status: "cancelled",
            outstanding_deposit_cents: 0,
            refunded_cents: refunded,
            retained_cents: retained,
            revision: revision
          })

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            refunded_cents: refunded,
            retained_cents: retained,
            revision: revision
          }
        else
          {:error, code} -> Repo.rollback(rejected(op, code))
          {:stale, expected, actual} -> Repo.rollback(stale_rejected(op, group, expected, actual))
        end
    end
  end

  defp refundable?(group, occurred_on) do
    group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
  end

  ## Shared domain helpers

  defp find_group(op) do
    case Repo.get_by(Group, group_id: op.group_id) do
      nil -> {:error, "group_not_found"}
      group -> group
    end
  end

  defp check_revision(%Group{}, %{expected_revision: nil}), do: :ok
  defp check_revision(%Group{revision: revision}, %{expected_revision: revision}), do: :ok

  defp check_revision(%Group{revision: actual}, %{expected_revision: expected}),
    do: {:stale, expected, actual}

  defp require_active(%Group{status: "active"}), do: :ok
  defp require_active(_), do: {:error, "group_not_active"}

  defp update_group(%Group{} = group, changes) do
    group
    |> Changeset.change(changes)
    |> Repo.update!()
  end

  ## Results

  defp rejected(op, code) do
    %{operation_id: op.operation_id, status: "rejected", code: code}
  end

  defp stale_rejected(op, group, expected, actual) do
    %{
      operation_id: op.operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: expected,
      actual_revision: actual
    }
  end

  defp rejected_raw(raw, code) do
    %{operation_id: operation_id_of(raw), status: "rejected", code: code}
  end

  defp operation_id_of(%{"operation_id" => id}) when is_binary(id), do: id
  defp operation_id_of(_), do: nil

  ## Reads

  defp render_group(group) do
    rooms =
      from(r in Room, where: r.group_id == ^group.id, order_by: [asc: r.id])
      |> Repo.all()
      |> Enum.map(&%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents})

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents
    }
  end
end
