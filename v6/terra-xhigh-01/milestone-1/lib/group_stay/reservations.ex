defmodule GroupStay.Reservations do
  @moduledoc """
  The group-deposit domain and its transactional partner operations.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{GroupReservation, GroupRoom}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  @doc "Processes partner operations in their submitted order."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns a group in the API representation, or `nil` when it does not exist."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(GroupReservation, partner_group_id: group_id) do
      nil -> nil
      group -> group_for_api(group)
    end
  end

  def fetch_group(_group_id), do: nil

  @doc "Returns the finance totals across all reservations."
  def ledger_totals do
    {:ok, totals} =
      Repo.transaction(fn ->
        %{
          cash_held_cents:
            Repo.one(
              from group in GroupReservation,
                where: group.status == ^@active,
                select: coalesce(sum(group.deposit_paid_cents), 0)
            ),
          cash_refunded_cents:
            Repo.one(
              from(group in GroupReservation, select: coalesce(sum(group.cash_refunded_cents), 0))
            ),
          cash_retained_cents:
            Repo.one(
              from(group in GroupReservation, select: coalesce(sum(group.cash_retained_cents), 0))
            )
        }
      end)

    totals
  end

  defp process_operation(operation) when is_map(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         true <- Map.get(operation, "type") in operation_types() do
      process_valid_operation(operation, operation_id)
    else
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: %{status: "rejected", code: "invalid_operation"}

  defp process_valid_operation(operation, operation_id, attempts \\ 0) do
    result =
      Repo.transaction(fn ->
        case Map.fetch!(operation, "type") do
          "open_group" -> open_group(operation)
          "record_cash_payment" -> record_cash_payment(operation)
          "reschedule_group" -> reschedule_group(operation)
          "cancel_group" -> cancel_group(operation)
        end
        |> case do
          {:ok, attributes} ->
            attributes

          {:rejected, code, attributes} ->
            Repo.rollback(rejected(operation, code, attributes))

          :retry ->
            Repo.rollback(:retry)
        end
      end)

    case result do
      {:ok, attributes} ->
        Map.merge(%{operation_id: operation_id, status: "applied"}, attributes)

      {:error, :retry} when attempts < 3 ->
        process_valid_operation(operation, operation_id, attempts + 1)

      {:error, :retry} ->
        rejected(operation, "invalid_operation")

      {:error, rejection} ->
        rejection
    end
  end

  defp open_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         false <-
           Repo.exists?(
             from(group in GroupReservation, where: group.partner_group_id == ^group_id)
           ),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on, departure_on} <- stay_dates(operation),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation),
         {:ok, lodging_total_cents, deposit_due_cents} <-
           totals(arrival_on, departure_on, rate_plan, rooms) do
      attributes = %{
        partner_group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: @active,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        outstanding_deposit_cents: deposit_due_cents,
        revision: 1
      }

      with {:ok, group} <-
             %GroupReservation{}
             |> GroupReservation.changeset(attributes)
             |> Repo.insert(),
           {:ok, _rooms} <- insert_rooms(group, rooms) do
        {:ok,
         %{
           group_id: group_id,
           deposit_due_cents: deposit_due_cents,
           revision: group.revision
         }}
      else
        {:error, changeset} ->
          if duplicate_group_id?(changeset),
            do: reject("group_already_exists", %{group_id: group_id}),
            else: reject("invalid_operation")
      end
    else
      true ->
        case required_string(operation, "group_id") do
          {:ok, group_id} -> reject("group_already_exists", %{group_id: group_id})
          :error -> reject("invalid_operation")
        end

      :error ->
        reject("invalid_operation")

      {:error, :invalid_stay} ->
        reject("invalid_stay")

      {:error, :invalid_rate_plan} ->
        reject("invalid_rate_plan")

      {:error, :invalid_rooms} ->
        reject("invalid_rooms")
    end
  end

  defp record_cash_payment(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, _occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, amount_cents} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount_cents),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               deposit_paid_cents: group.deposit_paid_cents + amount_cents,
               outstanding_deposit_cents: group.outstanding_deposit_cents - amount_cents
             }) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: updated_group.outstanding_deposit_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_amount} ->
          reject("invalid_amount", %{group_id: group.partner_group_id})

        {:error, :payment_exceeds_outstanding} ->
          reject("payment_exceeds_outstanding", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp reschedule_group(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, new_arrival_on} <- new_arrival_date(operation),
           :ok <- arrival_after_operation(new_arrival_on, occurred_on),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               arrival_on: new_arrival_on,
               departure_on:
                 Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))
             }) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
           new_departure_on: Date.to_iso8601(updated_group.departure_on),
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_stay} ->
          reject("invalid_stay", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp cancel_group(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {refunded_cents, retained_cents} <- cancellation_amounts(group, occurred_on),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               status: @cancelled,
               outstanding_deposit_cents: 0,
               cash_refunded_cents: group.cash_refunded_cents + refunded_cents,
               cash_retained_cents: group.cash_retained_cents + retained_cents
             }) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           refunded_cents: refunded_cents,
           retained_cents: retained_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp with_group_at_current_revision(operation, callback) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         %GroupReservation{} = group <- Repo.get_by(GroupReservation, partner_group_id: group_id),
         {:ok, expected_revision} <- expected_revision(operation),
         :ok <- revision_matches(group, expected_revision) do
      callback.(group, expected_revision)
    else
      nil ->
        case required_string(operation, "group_id") do
          {:ok, group_id} -> reject("group_not_found", %{group_id: group_id})
          :error -> reject("invalid_operation")
        end

      :error ->
        reject("invalid_operation")

      {:error, :stale_revision, group, expected_revision} ->
        reject("stale_revision", %{
          group_id: group.partner_group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })
    end
  end

  defp update_group(group, _expected_revision, attributes) do
    group
    |> Ecto.Changeset.change(attributes)
    |> Ecto.Changeset.optimistic_lock(:revision)
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        {:ok, updated_group}

      {:error, _changeset} ->
        actual_revision =
          Repo.one(
            from(current_group in GroupReservation,
              where: current_group.id == ^group.id,
              select: current_group.revision
            )
          ) || group.revision

        {:error, {:stale_update, actual_revision}}
    end
  end

  defp stale_update_rejection(group, expected_revision, actual_revision)
       when is_integer(expected_revision) do
    reject("stale_revision", %{
      group_id: group.partner_group_id,
      expected_revision: expected_revision,
      actual_revision: actual_revision
    })
  end

  defp stale_update_rejection(_group, nil, _actual_revision), do: :retry

  defp group_for_api(group) do
    rooms =
      Repo.all(
        from room in GroupRoom,
          where: room.group_reservation_id == ^group.id,
          order_by: [asc: room.position]
      )

    %{
      group_id: group.partner_group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents
    }
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, inserted_rooms} ->
      attributes = %{
        group_reservation_id: group.id,
        position: position,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents
      }

      case Repo.insert(%GroupRoom{} |> Ecto.Changeset.change(attributes)) do
        {:ok, inserted_room} -> {:cont, {:ok, [inserted_room | inserted_rooms]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp totals(arrival_on, departure_on, rate_plan, rooms) do
    nights = Date.diff(departure_on, arrival_on)

    room_totals = Enum.map(rooms, fn room -> room.nightly_rate_cents * nights end)
    lodging_total_cents = Enum.sum(room_totals)

    deposit_due_cents =
      case rate_plan do
        @flexible -> Enum.sum(Enum.map(room_totals, &rounded_flexible_deposit/1))
        @advance_purchase -> lodging_total_cents
      end

    {:ok, lodging_total_cents, deposit_due_cents}
  end

  defp rounded_flexible_deposit(lodging_total_cents) do
    div(lodging_total_cents * 20 + 50, 100)
  end

  defp cancellation_amounts(group, occurred_on) do
    refundable? =
      group.rate_plan == @flexible and Date.diff(group.arrival_on, occurred_on) >= 14

    if refundable? do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp active(%GroupReservation{status: @active}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp payment_within_outstanding(group, amount_cents)
       when amount_cents <= group.outstanding_deposit_cents,
       do: :ok

  defp payment_within_outstanding(_group, _amount_cents),
    do: {:error, :payment_exceeds_outstanding}

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp revision_matches(_group, nil), do: :ok

  defp revision_matches(group, expected_revision) when group.revision == expected_revision,
    do: :ok

  defp revision_matches(group, expected_revision),
    do: {:error, :stale_revision, group, expected_revision}

  defp expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        {:ok, nil}

      {:ok, expected_revision} when is_integer(expected_revision) ->
        {:ok, expected_revision}

      {:ok, _expected_revision} ->
        :error
    end
  end

  defp operation_date(operation) do
    with {:ok, occurred_on} <- required_string(operation, "occurred_on"),
         {:ok, date} <- parse_date(occurred_on) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp stay_dates(operation) do
    with {:ok, arrival_on} <- required_string(operation, "arrival_on"),
         {:ok, departure_on} <- required_string(operation, "departure_on"),
         {:ok, arrival_on} <- parse_date(arrival_on),
         {:ok, departure_on} <- parse_date(departure_on),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp new_arrival_date(operation) do
    with {:ok, new_arrival_on} <- required_string(operation, "new_arrival_on"),
         {:ok, date} <- parse_date(new_arrival_on) do
      {:ok, date}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      {:ok, _rate_plan} -> {:error, :invalid_rate_plan}
      :error -> :error
    end
  end

  defp rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) and rooms != [] -> validate_rooms(rooms)
      {:ok, _rooms} -> {:error, :invalid_rooms}
      :error -> :error
    end
  end

  defp validate_rooms(rooms) do
    rooms
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn
      %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
      {:ok, room_ids, validated_rooms}
      when is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 ->
        if MapSet.member?(room_ids, room_id) do
          {:halt, {:error, :invalid_rooms}}
        else
          room = %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
          {:cont, {:ok, MapSet.put(room_ids, room_id), [room | validated_rooms]}}
        end

      _room, _validated ->
        {:halt, {:error, :invalid_rooms}}
    end)
    |> case do
      {:ok, _room_ids, validated_rooms} -> {:ok, Enum.reverse(validated_rooms)}
      {:error, :invalid_rooms} -> {:error, :invalid_rooms}
    end
  end

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, :invalid_amount}

      :error ->
        :error
    end
  end

  defp required_string(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp operation_types do
    ["open_group", "record_cash_payment", "reschedule_group", "cancel_group"]
  end

  defp duplicate_group_id?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, options}} ->
      field == :partner_group_id and options[:constraint] == :unique
    end)
  end

  defp reject(code, attributes \\ %{}), do: {:rejected, code, attributes}

  defp rejected(operation, code, attributes \\ %{}) do
    base = Map.merge(%{status: "rejected", code: code}, attributes)

    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> Map.put(base, :operation_id, operation_id)
      :error -> base
    end
  end
end
