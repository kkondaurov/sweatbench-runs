defmodule GroupStay.Operations do
  import Ecto.Changeset

  alias GroupStay.{Group, GroupRoom, Repo}

  @flexible_rate_plan "flexible"
  @advance_purchase_rate_plan "advance_purchase"
  @max_sqlite_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply/1)
  end

  def apply(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      apply_known_operation(operation, operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  def apply(_operation), do: rejected(nil, "invalid_operation")

  defp apply_known_operation(%{"type" => "open_group"} = operation, operation_id) do
    in_transaction(operation, operation_id, &open_group(&1, &2))
  end

  defp apply_known_operation(%{"type" => type} = operation, operation_id)
       when type in ["record_cash_payment", "reschedule_group", "cancel_group"] do
    in_transaction(operation, operation_id, fn current_operation, current_id ->
      with {:ok, group} <- find_group(current_operation, current_id),
           :ok <- check_revision(current_operation, current_id, group),
           :ok <- active_group(current_id, group) do
        case type do
          "record_cash_payment" -> record_cash_payment(current_operation, current_id, group)
          "reschedule_group" -> reschedule_group(current_operation, current_id, group)
          "cancel_group" -> cancel_group(current_operation, current_id, group)
        end
      end
    end)
  end

  defp apply_known_operation(_operation, operation_id),
    do: rejected(operation_id, "invalid_operation")

  defp in_transaction(operation, operation_id, function) do
    case Repo.transaction(fn -> function.(operation, operation_id) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, {:rejected, result}} -> result
      {:error, _reason} -> rejected(operation_id, "invalid_operation")
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, attrs} <- validate_open(operation),
         nil <- Repo.get_by(Group, group_id: attrs.group_id) do
      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          case insert_rooms(group, attrs.rooms) do
            :ok ->
              %{
                operation_id: operation_id,
                status: "applied",
                group_id: group.group_id,
                deposit_due_cents: group.deposit_due_cents,
                revision: group.revision
              }

            {:error, :invalid_rooms} ->
              reject(operation_id, "invalid_rooms")
          end

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            reject(operation_id, "group_already_exists")
          else
            reject(operation_id, "invalid_operation")
          end
      end
    else
      {:error, code} -> reject(operation_id, code)
      %Group{} -> reject(operation_id, "group_already_exists")
    end
  end

  defp find_group(operation, operation_id) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> reject_and_rollback({"group_not_found", %{}, operation_id})
          group -> {:ok, group}
        end

      _ ->
        reject_and_rollback({"invalid_operation", %{}, operation_id})
    end
  end

  defp check_revision(operation, operation_id, %Group{} = group) do
    if Map.has_key?(operation, "expected_revision") and
         Map.get(operation, "expected_revision") !== group.revision do
      reject_and_rollback({
        "stale_revision",
        %{
          group_id: group.group_id,
          expected_revision: Map.get(operation, "expected_revision"),
          actual_revision: group.revision
        },
        operation_id
      })
    else
      :ok
    end
  end

  defp active_group(_operation_id, %Group{status: "active"}), do: :ok

  defp active_group(operation_id, %Group{}),
    do: reject_and_rollback({"group_not_active", %{}, operation_id})

  defp record_cash_payment(operation, operation_id, group) do
    with {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(Map.get(operation, "amount_cents")),
         outstanding when amount_cents <= outstanding <- outstanding_deposit(group) do
      update_group!(group, %{deposit_paid_cents: group.deposit_paid_cents + amount_cents})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding - amount_cents,
        revision: group.revision + 1
      }
    else
      {:error, code} -> reject_and_rollback({code, %{}, operation_id})
      _ -> reject_and_rollback({"payment_exceeds_outstanding", %{}, operation_id})
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(Map.get(operation, "occurred_on")),
         {:ok, new_arrival_on} <- parse_date(Map.get(operation, "new_arrival_on")),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      arrival_shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, arrival_shift)

      update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival_on),
        new_departure_on: Date.to_iso8601(new_departure_on),
        revision: group.revision + 1
      }
    else
      _ -> reject_and_rollback({"invalid_stay", %{}, operation_id})
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(Map.get(operation, "occurred_on")) do
      {refunded_cents, retained_cents} =
        if group.rate_plan == @flexible_rate_plan and
             Date.diff(group.arrival_on, occurred_on) >= 14 do
          {group.deposit_paid_cents, 0}
        else
          {0, group.deposit_paid_cents}
        end

      update_group!(group, %{
        status: "cancelled",
        refunded_cents: refunded_cents,
        retained_cents: retained_cents
      })

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: group.revision + 1
      }
    else
      _ -> reject_and_rollback({"invalid_stay", %{}, operation_id})
    end
  end

  defp validate_open(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rate_plan} <- valid_rate_plan(Map.get(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(Map.get(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)

      with {:ok, lodging_total_cents} <- lodging_total(rooms, nights) do
        deposit_due_cents = calculate_deposit(rooms, nights, rate_plan, lodging_total_cents)

        {:ok,
         %{
           group_id: group_id,
           guest_id: guest_id,
           property_id: property_id,
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: rate_plan,
           status: "active",
           revision: 1,
           lodging_total_cents: lodging_total_cents,
           deposit_due_cents: deposit_due_cents,
           deposit_paid_cents: 0,
           refunded_cents: 0,
           retained_cents: 0,
           rooms: rooms
         }}
      end
    else
      false -> {:error, "invalid_stay"}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    result =
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, MapSet.new(), []}, fn {room, position},
                                                       {:ok, ids, valid_rooms} ->
        with {:ok, room_id} <- required_identifier(room, "room_id"),
             {:ok, nightly_rate_cents} <- valid_rate(room, "nightly_rate_cents"),
             false <- MapSet.member?(ids, room_id) do
          {:cont,
           {:ok, MapSet.put(ids, room_id),
            [
              %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}
              | valid_rooms
            ]}}
        else
          true -> {:halt, {:error, "invalid_rooms"}}
          {:error, _code} -> {:halt, {:error, "invalid_rooms"}}
        end
      end)

    case result do
      {:ok, _ids, rooms_in_reverse_order} -> {:ok, Enum.reverse(rooms_in_reverse_order)}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp lodging_total(rooms, nights) do
    Enum.reduce_while(rooms, {:ok, 0}, fn room, {:ok, total} ->
      room_total = room.nightly_rate_cents * nights
      new_total = total + room_total

      if room_total <= @max_sqlite_integer and new_total <= @max_sqlite_integer do
        {:cont, {:ok, new_total}}
      else
        {:halt, {:error, "invalid_rooms"}}
      end
    end)
  end

  defp calculate_deposit(_rooms, _nights, @advance_purchase_rate_plan, lodging_total_cents),
    do: lodging_total_cents

  defp calculate_deposit(rooms, nights, @flexible_rate_plan, _lodging_total_cents) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + round_half_up(room.nightly_rate_cents * nights * 20, 100)
    end)
  end

  defp insert_rooms(group, rooms) do
    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      changeset =
        GroupRoom.changeset(%GroupRoom{}, %{
          group_record_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: room.position
        })

      case Repo.insert(changeset) do
        {:ok, _room} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:error, :invalid_rooms}}
      end
    end)
  end

  defp valid_rate_plan(@flexible_rate_plan), do: {:ok, @flexible_rate_plan}
  defp valid_rate_plan(@advance_purchase_rate_plan), do: {:ok, @advance_purchase_rate_plan}
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp valid_rate(room, key) when is_map(room) do
    case Map.get(room, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp required_identifier(operation, key) when is_map(operation) do
    case Map.get(operation, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(_operation, _key), do: {:error, "invalid_operation"}

  defp required_date(operation, key) do
    case parse_date(Map.get(operation, key)) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp usable_amount(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp usable_amount(_value), do: {:error, "invalid_amount"}

  defp outstanding_deposit(%Group{} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp update_group!(group, attrs) do
    group
    |> change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp round_half_up(numerator, denominator),
    do: div(numerator * 2 + denominator, denominator * 2)

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp rejected(operation_id, code, details \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, details)
  end

  defp reject(operation_id, code, details \\ %{}) do
    reject_and_rollback({code, details, operation_id})
  end

  defp reject_and_rollback(code) do
    {code, details, operation_id} = normalize_rejection(code)
    Repo.rollback({:rejected, rejected(operation_id, code, details)})
  end

  defp normalize_rejection({code, details, operation_id}), do: {code, details, operation_id}
  defp normalize_rejection(code), do: {code, %{}, nil}
end
