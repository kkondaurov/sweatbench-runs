defmodule GroupStay.GroupReservations do
  import Ecto.Query

  alias GroupStay.GroupReservations.GroupReservation
  alias GroupStay.Repo

  @active_status "active"
  @cancelled_status "cancelled"
  @flexible_rate_plan "flexible"
  @advance_purchase_rate_plan "advance_purchase"

  def submit_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def submit_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) do
    GroupReservation
    |> Repo.get_by(group_id: group_id)
    |> Repo.preload(:rooms)
  end

  def group_payload(nil), do: nil

  def group_payload(%GroupReservation{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def ledger_totals do
    active_cash_query =
      from group in GroupReservation,
        where: group.status == ^@active_status,
        select: coalesce(sum(group.deposit_paid_cents), 0)

    refunded_query =
      from group in GroupReservation,
        select: coalesce(sum(group.refunded_cents), 0)

    retained_query =
      from group in GroupReservation,
        select: coalesce(sum(group.retained_cents), 0)

    %{
      cash_held_cents: Repo.one(active_cash_query),
      cash_refunded_cents: Repo.one(refunded_query),
      cash_retained_cents: Repo.one(retained_query)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    {:ok, result} = Repo.transaction(fn -> apply_operation(operation) end)
    result
  end

  defp process_operation(_operation), do: rejection(nil, "invalid_operation")

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: with_existing_group(operation, &record_cash_payment(operation, &1))

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: with_existing_group(operation, &reschedule_group(operation, &1))

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: with_existing_group(operation, &cancel_group(operation, &1))

  defp apply_operation(operation), do: rejection(operation_id(operation), "invalid_operation")

  defp open_group(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, rate_plan} <- required_string(operation, "rate_plan"),
         :ok <- ensure_group_id_available(group_id),
         {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay?(arrival_on, departure_on),
         {:ok, rooms} <- required_rooms(operation),
         {:ok, deposit_calculator} <- deposit_calculator(rate_plan) do
      night_count = Date.diff(departure_on, arrival_on)

      rooms_with_totals =
        Enum.map(rooms, fn room ->
          lodging_total = night_count * room.nightly_rate_cents
          Map.put(room, :lodging_total_cents, lodging_total)
        end)

      lodging_total_cents = sum_field(rooms_with_totals, :lodging_total_cents)
      deposit_due_cents = sum_deposits(rooms_with_totals, deposit_calculator)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: @active_status,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        revision: 1,
        rooms:
          Enum.map(rooms, fn room ->
            %{
              position: room.position,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents
            }
          end)
      }

      case Repo.insert(GroupReservation.create_changeset(%GroupReservation{}, attrs)) do
        {:ok, group} ->
          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          }

        {:error, changeset} ->
          if changeset_error?(changeset, :group_id) do
            rejection(operation_id, "group_already_exists")
          else
            rejection(operation_id, "invalid_operation")
          end
      end
    else
      :group_already_exists -> rejection(operation_id(operation), "group_already_exists")
      :invalid_rate_plan -> rejection(operation_id(operation), "invalid_rate_plan")
      :invalid_rooms -> rejection(operation_id(operation), "invalid_rooms")
      :invalid_stay -> rejection(operation_id(operation), "invalid_stay")
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp record_cash_payment(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, amount_cents} <- required_integer(operation, "amount_cents"),
         :ok <- valid_payment_amount?(amount_cents),
         :ok <- payment_within_outstanding?(group, amount_cents) do
      new_outstanding = outstanding_deposit_cents(group) - amount_cents

      attrs = %{
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        revision: group.revision + 1,
        arrival_on: group.arrival_on,
        departure_on: group.departure_on,
        status: group.status,
        refunded_cents: group.refunded_cents,
        retained_cents: group.retained_cents
      }

      {:ok, updated_group} = Repo.update(GroupReservation.update_changeset(group, attrs))

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: new_outstanding,
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_amount -> rejection(operation_id, "invalid_amount")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :payment_exceeds_outstanding -> rejection(operation_id, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- new_arrival_after_occurrence?(new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      attrs = %{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        revision: group.revision + 1,
        status: group.status,
        deposit_paid_cents: group.deposit_paid_cents,
        refunded_cents: group.refunded_cents,
        retained_cents: group.retained_cents
      }

      {:ok, updated_group} = Repo.update(GroupReservation.update_changeset(group, attrs))

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
        new_departure_on: Date.to_iso8601(updated_group.departure_on),
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
    end
  end

  defp cancel_group(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on") do
      {refunded_cents, retained_cents} = cancellation_settlement(group, occurred_on)

      attrs = %{
        status: @cancelled_status,
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        revision: group.revision + 1,
        arrival_on: group.arrival_on,
        departure_on: group.departure_on,
        deposit_paid_cents: group.deposit_paid_cents
      }

      {:ok, updated_group} = Repo.update(GroupReservation.update_changeset(group, attrs))

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
    end
  end

  defp with_existing_group(operation, callback) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case get_group(group_id) do
        nil ->
          rejection(operation_id, "group_not_found")

        group ->
          case expected_revision(operation) do
            {:ok, nil} ->
              callback.(group)

            {:ok, expected_revision} when expected_revision == group.revision ->
              callback.(group)

            {:ok, expected_revision} ->
              %{
                operation_id: operation_id,
                status: "rejected",
                code: "stale_revision",
                group_id: group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              }

            :invalid_operation ->
              rejection(operation_id, "invalid_operation")
          end
      end
    else
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp ensure_group_id_available(group_id) do
    if Repo.exists?(from group in GroupReservation, where: group.group_id == ^group_id) do
      :group_already_exists
    else
      :ok
    end
  end

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :invalid_operation
    end
  end

  defp required_integer(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> :invalid_amount
      :error -> :invalid_operation
    end
  end

  defp required_date(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :invalid_stay
        end

      {:ok, _value} ->
        :invalid_stay

      :error ->
        :invalid_operation
    end
  end

  defp valid_stay?(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      :invalid_stay
    end
  end

  defp new_arrival_after_occurrence?(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      :invalid_stay
    end
  end

  defp required_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) ->
        normalize_rooms(rooms)

      {:ok, _rooms} ->
        :invalid_rooms

      :error ->
        :invalid_operation
    end
  end

  defp normalize_rooms([]), do: :invalid_rooms

  defp normalize_rooms(rooms) do
    normalized =
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {room, position}, acc ->
        case normalize_room(room, position) do
          {:ok, normalized_room} -> {:cont, [normalized_room | acc]}
          :invalid_rooms -> {:halt, :invalid_rooms}
        end
      end)

    case normalized do
      :invalid_rooms ->
        :invalid_rooms

      normalized_rooms ->
        rooms_in_original_order = Enum.reverse(normalized_rooms)
        room_ids = Enum.map(rooms_in_original_order, & &1.room_id)

        if length(Enum.uniq(room_ids)) == length(room_ids) do
          {:ok, rooms_in_original_order}
        else
          :invalid_rooms
        end
    end
  end

  defp normalize_room(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    {:ok, %{position: position, room_id: room_id, nightly_rate_cents: nightly_rate_cents}}
  end

  defp normalize_room(_room, _position), do: :invalid_rooms

  defp deposit_calculator(@flexible_rate_plan), do: {:ok, &flexible_deposit_cents/1}
  defp deposit_calculator(@advance_purchase_rate_plan), do: {:ok, & &1}
  defp deposit_calculator(_rate_plan), do: :invalid_rate_plan

  defp flexible_deposit_cents(lodging_total_cents) do
    div(lodging_total_cents * 20 + 50, 100)
  end

  defp sum_deposits(rooms, deposit_calculator) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + deposit_calculator.(room.lodging_total_cents)
    end)
  end

  defp sum_field(records, field) do
    Enum.reduce(records, 0, fn record, total -> total + Map.fetch!(record, field) end)
  end

  defp active_group?(%GroupReservation{status: @active_status}), do: :ok
  defp active_group?(_group), do: :group_not_active

  defp valid_payment_amount?(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: :ok

  defp valid_payment_amount?(_amount_cents), do: :invalid_amount

  defp payment_within_outstanding?(group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      :payment_exceeds_outstanding
    end
  end

  defp cancellation_settlement(
         %GroupReservation{rate_plan: @advance_purchase_rate_plan} = group,
         _date
       ) do
    {0, group.deposit_paid_cents}
  end

  defp cancellation_settlement(
         %GroupReservation{rate_plan: @flexible_rate_plan} = group,
         occurred_on
       ) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp outstanding_deposit_cents(%GroupReservation{status: @cancelled_status}), do: 0

  defp outstanding_deposit_cents(%GroupReservation{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> :invalid_operation
      :error -> {:ok, nil}
    end
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp rejection(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: code}
  end

  defp changeset_error?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end
end
