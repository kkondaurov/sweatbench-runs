defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner operations in request order.

  Each operation owns a separate database transaction. A rejection therefore
  rolls back only that operation, while successful changes remain visible to
  every later item in the same batch.
  """

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @operation_requirements %{
    "open_group" =>
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(operation_id occurred_on group_id amount_cents),
    "reschedule_group" => ~w(operation_id occurred_on group_id new_arrival_on),
    "cancel_group" => ~w(operation_id occurred_on group_id)
  }

  @spec process_batch([term()]) :: [map()]
  def process_batch(operations), do: Enum.map(operations, &process/1)

  def process(operation) when is_map(operation) do
    with {:ok, type} <- operation_type(operation),
         :ok <- validate_shape(operation, type) do
      run_transaction(operation, type)
    else
      _error -> rejection(operation, "invalid_operation")
    end
  end

  def process(_operation), do: rejection(%{}, "invalid_operation")

  defp run_transaction(operation, type) do
    case Repo.transaction(fn -> apply_operation(type, operation) end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  rescue
    Ecto.StaleEntryError ->
      if Map.has_key?(operation, "expected_revision") do
        concurrent_revision_rejection(operation)
      else
        # An unconditional operation always targets the latest version. If a
        # concurrent writer wins the optimistic update, reload and try again.
        run_transaction(operation, type)
      end
  end

  defp operation_type(%{"type" => type}) when is_map_key(@operation_requirements, type),
    do: {:ok, type}

  defp operation_type(_operation), do: :error

  defp validate_shape(operation, type) do
    required = Map.fetch!(@operation_requirements, type)

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["group_id"]) and
         valid_type_specific_identifiers?(operation, type) do
      :ok
    else
      :error
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp valid_type_specific_identifiers?(operation, "open_group") do
    valid_identifier?(operation["guest_id"]) and valid_identifier?(operation["property_id"])
  end

  defp valid_type_specific_identifiers?(_operation, _type), do: true

  defp apply_operation("open_group", operation), do: open_group(operation)
  defp apply_operation("record_cash_payment", operation), do: record_cash_payment(operation)
  defp apply_operation("reschedule_group", operation), do: reschedule_group(operation)
  defp apply_operation("cancel_group", operation), do: cancel_group(operation)

  defp open_group(operation) do
    if Repo.get(Group, operation["group_id"]) do
      rollback(operation, "group_already_exists")
    end

    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- parse_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)

      rooms_with_positions =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} -> Map.put(room, :position, position) end)

      lodging_total_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          total + room.nightly_rate_cents * nights
        end)

      deposit_due_cents = deposit_due(rooms, nights, rate_plan)

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: :active,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        revision: 1,
        rooms: rooms_with_positions
      }

      case %Group{} |> Group.creation_changeset(attrs) |> Repo.insert() do
        {:ok, group} ->
          applied(operation, %{
            "group_id" => group.group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            rollback(operation, "group_already_exists")
          else
            rollback(operation, "invalid_operation")
          end
      end
    else
      :error -> rollback(operation, "invalid_stay")
      {:error, :invalid_stay} -> rollback(operation, "invalid_stay")
      {:error, :invalid_rate_plan} -> rollback(operation, "invalid_rate_plan")
      {:error, :invalid_rooms} -> rollback(operation, "invalid_rooms")
    end
  end

  defp record_cash_payment(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    if parse_date(operation["occurred_on"]) == :error do
      rollback(operation, "invalid_operation")
    end

    amount = operation["amount_cents"]

    if not (is_integer(amount) and amount > 0) do
      rollback(operation, "invalid_amount")
    end

    outstanding = Group.outstanding_deposit_cents(group)

    if amount > outstanding do
      rollback(operation, "payment_exceeds_outstanding")
    end

    paid = group.deposit_paid_cents + amount
    {:ok, updated_group} = group |> Group.payment_changeset(paid) |> Repo.update()

    applied(operation, %{
      "group_id" => updated_group.group_id,
      "amount_cents" => amount,
      "outstanding_deposit_cents" => Group.outstanding_deposit_cents(updated_group),
      "revision" => updated_group.revision
    })
  end

  defp reschedule_group(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_future_arrival(new_arrival_on, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      {:ok, updated_group} =
        group
        |> Group.reschedule_changeset(new_arrival_on, new_departure_on)
        |> Repo.update()

      applied(operation, %{
        "group_id" => updated_group.group_id,
        "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
        "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
        "revision" => updated_group.revision
      })
    else
      _error -> rollback(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} ->
        {refunded_cents, retained_cents} = cancellation_settlement(group, occurred_on)

        {:ok, updated_group} =
          group
          |> Group.cancellation_changeset(refunded_cents, retained_cents)
          |> Repo.update()

        applied(operation, %{
          "group_id" => updated_group.group_id,
          "refunded_cents" => updated_group.refunded_cents,
          "retained_cents" => updated_group.retained_cents,
          "revision" => updated_group.revision
        })

      :error ->
        rollback(operation, "invalid_operation")
    end
  end

  defp fetch_group!(operation) do
    case Repo.get(Group, operation["group_id"]) do
      nil -> rollback(operation, "group_not_found")
      group -> group
    end
  end

  defp ensure_current_revision!(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when expected == group.revision ->
        :ok

      {:ok, expected} ->
        rollback(stale_rejection(operation, group.group_id, expected, group.revision))
    end
  end

  defp ensure_active!(%Group{status: :active}, _operation), do: :ok
  defp ensure_active!(_group, operation), do: rollback(operation, "group_not_active")

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp validate_future_arrival(arrival_on, occurred_on) do
    if Date.compare(arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp parse_rate_plan("flexible"), do: {:ok, :flexible}
  defp parse_rate_plan("advance_purchase"), do: {:ok, :advance_purchase}
  defp parse_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    parsed = Enum.map(rooms, &validate_room/1)

    with true <- Enum.all?(parsed, &match?({:ok, _room}, &1)),
         room_values = Enum.map(parsed, fn {:ok, room} -> room end),
         true <- unique_room_ids?(room_values) do
      {:ok, room_values}
    else
      _invalid -> {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp validate_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 do
    {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
  end

  defp validate_room(_room), do: {:error, :invalid_room}

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp deposit_due(rooms, nights, :advance_purchase) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + room.nightly_rate_cents * nights
    end)
  end

  defp deposit_due(rooms, nights, :flexible) do
    Enum.reduce(rooms, 0, fn room, total ->
      room_lodging = room.nightly_rate_cents * nights
      total + div(room_lodging * 20 + 50, 100)
    end)
  end

  defp cancellation_settlement(%Group{rate_plan: :flexible} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp cancellation_settlement(group, _occurred_on), do: {0, group.deposit_paid_cents}

  defp concurrent_revision_rejection(operation) do
    case Repo.get(Group, operation["group_id"]) do
      nil ->
        rejection(operation, "group_not_found")

      group ->
        expected = Map.get(operation, "expected_revision", group.revision - 1)
        stale_rejection(operation, group.group_id, expected, group.revision)
    end
  end

  defp applied(operation, fields) do
    Map.merge(
      %{"operation_id" => operation["operation_id"], "status" => "applied"},
      fields
    )
  end

  defp rejection(operation, code) do
    %{
      "operation_id" => Map.get(operation, "operation_id"),
      "status" => "rejected",
      "code" => code
    }
  end

  defp stale_rejection(operation, group_id, expected, actual) do
    operation
    |> rejection("stale_revision")
    |> Map.merge(%{
      "group_id" => group_id,
      "expected_revision" => expected,
      "actual_revision" => actual
    })
  end

  defp rollback(operation, code), do: Repo.rollback(rejection(operation, code))
  defp rollback(result) when is_map(result), do: Repo.rollback(result)
end
