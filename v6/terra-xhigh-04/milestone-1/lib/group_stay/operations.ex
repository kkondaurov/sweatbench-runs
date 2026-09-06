defmodule GroupStay.Operations do
  @moduledoc false

  alias GroupStay.Groups
  alias GroupStay.Repo

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @active "active"

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  def process_batch(_operations), do: []

  def process(%{"type" => "open_group"} = operation), do: open_group(operation)

  def process(%{"type" => "record_cash_payment"} = operation),
    do: existing_group(operation, &record_cash_payment/3)

  def process(%{"type" => "reschedule_group"} = operation),
    do: existing_group(operation, &reschedule_group/3)

  def process(%{"type" => "cancel_group"} = operation),
    do: existing_group(operation, &cancel_group/3)

  def process(operation) when is_map(operation), do: rejected(operation, "invalid_operation")
  def process(_operation), do: %{status: "rejected", code: "invalid_operation"}

  defp open_group(operation) do
    with {:ok, common} <- common(operation),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, payload} <- open_payload(operation, common) do
      transaction(fn ->
        case Groups.get(group_id) do
          {:ok, _group} ->
            reject!(operation, "group_already_exists")

          :error ->
            case Groups.create(payload.group, payload.rooms) do
              {:ok, group} ->
                applied(operation, %{
                  group_id: group.group_id,
                  deposit_due_cents: group.deposit_due_cents,
                  revision: group.revision
                })

              {:error, changeset} ->
                if unique_group_id_error?(changeset),
                  do: reject!(operation, "group_already_exists"),
                  else: raise(changeset)
            end
        end
      end)
    else
      :error -> rejected(operation, "invalid_operation")
      {:error, code} -> rejected(operation, code)
    end
  end

  defp existing_group(operation, handler) do
    case required_string(operation, "group_id") do
      :error ->
        rejected(operation, "invalid_operation")

      {:ok, group_id} ->
        case transaction(fn ->
               case Groups.get(group_id) do
                 :error ->
                   reject!(operation, "group_not_found")

                 {:ok, group} ->
                   ensure_expected_revision!(operation, group)

                   case common(operation) do
                     {:ok, %{occurred_on: occurred_on}} -> handler.(operation, group, occurred_on)
                     :error -> reject!(operation, "invalid_operation")
                   end
               end
             end) do
          :retry -> existing_group(operation, handler)
          result -> result
        end
    end
  end

  defp record_cash_payment(operation, group, _occurred_on) do
    with true <- group.status == @active,
         {:ok, amount_cents} <- positive_integer(operation, "amount_cents") do
      outstanding = outstanding_deposit(group)

      if amount_cents <= outstanding do
        case Groups.update(group, %{deposit_paid_cents: group.deposit_paid_cents + amount_cents}) do
          {:ok, updated_group} ->
            applied(operation, %{
              group_id: updated_group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents: outstanding_deposit(updated_group),
              revision: updated_group.revision
            })

          {:error, changeset} ->
            retry_or_raise(changeset)
        end
      else
        reject!(operation, "payment_exceeds_outstanding")
      end
    else
      false -> reject!(operation, "group_not_active")
      :error -> reject!(operation, "invalid_amount")
    end
  end

  defp reschedule_group(operation, group, occurred_on) do
    with true <- group.status == @active,
         {:ok, new_arrival_on} <- date(operation, "new_arrival_on"),
         :gt <- Date.compare(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      case Groups.update(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on}) do
        {:ok, updated_group} ->
          applied(operation, %{
            group_id: updated_group.group_id,
            new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
            new_departure_on: Date.to_iso8601(updated_group.departure_on),
            revision: updated_group.revision
          })

        {:error, changeset} ->
          retry_or_raise(changeset)
      end
    else
      false -> reject!(operation, "group_not_active")
      :error -> reject!(operation, "invalid_stay")
      _ -> reject!(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation, group, occurred_on) do
    if group.status != @active do
      reject!(operation, "group_not_active")
    end

    paid_cents = group.deposit_paid_cents

    {refunded_cents, retained_cents} =
      if refundable?(group, occurred_on), do: {paid_cents, 0}, else: {0, paid_cents}

    case Groups.update(group, %{
           status: "cancelled",
           deposit_due_cents: 0,
           deposit_paid_cents: 0,
           refunded_cents: refunded_cents,
           retained_cents: retained_cents
         }) do
      {:ok, updated_group} ->
        applied(operation, %{
          group_id: updated_group.group_id,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          revision: updated_group.revision
        })

      {:error, changeset} ->
        retry_or_raise(changeset)
    end
  end

  defp open_payload(operation, %{occurred_on: booked_on}) do
    with {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, arrival_on} <- opening_date(operation, "arrival_on"),
         {:ok, departure_on} <- opening_date(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation),
         {:ok, group_id} <- required_string(operation, "group_id") do
      nights = Date.diff(departure_on, arrival_on)

      room_totals =
        Enum.map(rooms, fn room ->
          lodging_cents = room.nightly_rate_cents * nights
          Map.put(room, :lodging_cents, lodging_cents)
        end)

      deposit_due_cents =
        Enum.reduce(room_totals, 0, fn room, total ->
          total + deposit_for(room.lodging_cents, rate_plan)
        end)

      {:ok,
       %{
         group: %{
           group_id: group_id,
           guest_id: guest_id,
           property_id: property_id,
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: rate_plan,
           lodging_total_cents: Enum.sum(Enum.map(room_totals, & &1.lodging_cents)),
           deposit_due_cents: deposit_due_cents
         },
         rooms: Enum.map(room_totals, &Map.take(&1, [:room_id, :nightly_rate_cents]))
       }}
    else
      false -> {:error, "invalid_stay"}
      :error -> {:error, "invalid_operation"}
      {:error, _} = error -> error
    end
  end

  defp common(operation) do
    with {:ok, _operation_id} <- required_string(operation, "operation_id"),
         {:ok, occurred_on} <- date(operation, "occurred_on") do
      {:ok, %{occurred_on: occurred_on}}
    else
      :error -> :error
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, "invalid_operation"}
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      {:ok, _} -> {:error, "invalid_rate_plan"}
    end
  end

  defp opening_date(operation, field) do
    with {:ok, value} <- Map.fetch(operation, field),
         true <- is_binary(value) and byte_size(value) > 0,
         {:ok, parsed_date} <- Date.from_iso8601(value) do
      {:ok, parsed_date}
    else
      :error -> {:error, "invalid_operation"}
      false -> {:error, "invalid_stay"}
      {:error, _} -> {:error, "invalid_stay"}
    end
  end

  defp rooms(operation) do
    case Map.fetch(operation, "rooms") do
      :error -> {:error, "invalid_operation"}
      {:ok, rooms} -> rooms_value(rooms)
    end
  end

  defp rooms_value(rooms) when is_list(rooms) and rooms != [] do
    parsed_rooms =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}
        when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(nightly_rate_cents) and
               nightly_rate_cents > 0 ->
          {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}}

        _ ->
          :error
      end)

    with true <- Enum.all?(parsed_rooms, &match?({:ok, _}, &1)),
         parsed_rooms <- Enum.map(parsed_rooms, fn {:ok, room} -> room end),
         room_ids <- Enum.map(parsed_rooms, & &1.room_id),
         true <- length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok, parsed_rooms}
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp rooms_value(_rooms), do: {:error, "invalid_rooms"}

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp positive_integer(operation, field) do
    case Map.get(operation, field) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp date(operation, field) do
    with {:ok, value} <- required_string(operation, field),
         {:ok, parsed_date} <- Date.from_iso8601(value) do
      {:ok, parsed_date}
    else
      _ -> :error
    end
  end

  defp ensure_expected_revision!(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         Map.get(operation, "expected_revision") != group.revision do
      reject!(operation, "stale_revision", %{
        group_id: group.group_id,
        expected_revision: Map.get(operation, "expected_revision"),
        actual_revision: group.revision
      })
    end
  end

  defp refundable?(group, occurred_on) do
    group.rate_plan == @flexible and Date.diff(group.arrival_on, occurred_on) >= 14
  end

  defp deposit_for(lodging_cents, @flexible), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, @advance_purchase), do: lodging_cents

  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation, attrs),
    do: Map.merge(%{operation_id: operation["operation_id"], status: "applied"}, attrs)

  defp rejected(operation, code, attrs \\ %{}) do
    base = %{status: "rejected", code: code}

    base =
      if is_binary(operation["operation_id"]),
        do: Map.put(base, :operation_id, operation["operation_id"]),
        else: base

    Map.merge(base, attrs)
  end

  defp reject!(operation, code, attrs \\ %{}), do: Repo.rollback(rejected(operation, code, attrs))

  defp retry_or_raise(changeset) do
    if Keyword.has_key?(changeset.errors, :revision),
      do: Repo.rollback(:retry),
      else: raise(changeset)
  end

  defp unique_group_id_error?(changeset), do: Keyword.has_key?(changeset.errors, :group_id)
end
