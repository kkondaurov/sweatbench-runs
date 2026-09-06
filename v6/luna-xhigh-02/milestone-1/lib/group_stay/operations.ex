defmodule GroupStay.Operations do
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group)

  def process(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")
    type = value(operation, "type")

    cond do
      not valid_identifier?(operation_id) -> rejection(operation_id, "invalid_operation")
      type == "open_group" -> process_open(operation, operation_id)
      type in @operation_types -> process_existing(operation, operation_id, type)
      true -> rejection(operation_id, "invalid_operation")
    end
  end

  def process(_operation), do: rejection(nil, "invalid_operation")

  defp process_open(operation, operation_id) do
    required = [
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if not present?(operation, required) do
      rejection(operation_id, "invalid_operation")
    else
      group_id = value(operation, "group_id")

      if not valid_identifier?(group_id) or
           not valid_identifier?(value(operation, "guest_id")) or
           not valid_identifier?(value(operation, "property_id")) do
        rejection(operation_id, "invalid_operation", %{group_id: group_id})
      else
        transact(fn -> open_group(operation, operation_id, group_id) end)
      end
    end
  end

  defp open_group(operation, operation_id, group_id) do
    if Repo.get(Group, group_id) do
      rejection(operation_id, "group_already_exists", %{group_id: group_id})
    else
      with {:ok, booked_on} <- parse_date(value(operation, "occurred_on")),
           {:ok, arrival_on} <- parse_date(value(operation, "arrival_on")),
           {:ok, departure_on} <- parse_date(value(operation, "departure_on")),
           :ok <- validate_stay(arrival_on, departure_on),
           {:ok, rate_plan} <- validate_rate_plan(value(operation, "rate_plan")),
           {:ok, rooms} <- validate_rooms(value(operation, "rooms")) do
        nights = Date.diff(departure_on, arrival_on)

        lodging_total =
          Enum.reduce(rooms, 0, fn room, total -> total + room.lodging_cents * nights end)

        deposit_due = calculate_deposit(rooms, nights, rate_plan)

        group_attrs = %{
          group_id: group_id,
          guest_id: value(operation, "guest_id"),
          property_id: value(operation, "property_id"),
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0
        }

        case Repo.insert(Group.changeset(%Group{}, group_attrs)) do
          {:ok, _group} ->
            room_rows =
              Enum.with_index(rooms, 1)
              |> Enum.map(fn {room, position} ->
                %{
                  group_id: group_id,
                  position: position,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents
                }
              end)

            Repo.insert_all(Room, room_rows)

            applied(operation_id, %{
              group_id: group_id,
              deposit_due_cents: deposit_due,
              revision: 1
            })

          {:error, _changeset} ->
            rejection(operation_id, "group_already_exists", %{group_id: group_id})
        end
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group_id})
      end
    end
  end

  defp process_existing(operation, operation_id, type) do
    group_id = value(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejection(operation_id, "invalid_operation")
    else
      transact(fn -> existing_operation(operation, operation_id, type, group_id) end)
    end
  end

  defp existing_operation(operation, operation_id, type, group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        rejection(operation_id, "group_not_found", %{group_id: group_id})

      group ->
        case check_revision(operation, group) do
          :ok ->
            if group.status != "active" do
              rejection(operation_id, "group_not_active", %{group_id: group_id})
            else
              apply_existing(operation, operation_id, type, group)
            end

          {:error, :invalid_operation} ->
            rejection(operation_id, "invalid_operation", %{group_id: group_id})

          {:error, :stale_revision, expected_revision} ->
            rejection(operation_id, "stale_revision", %{
              group_id: group_id,
              expected_revision: expected_revision,
              actual_revision: group.revision
            })
        end
    end
  end

  defp apply_existing(operation, operation_id, "record_cash_payment", group) do
    if not present?(operation, ["occurred_on", "amount_cents"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, _occurred_on} <- parse_date(value(operation, "occurred_on")),
           :ok <- validate_amount(value(operation, "amount_cents")) do
        amount = value(operation, "amount_cents")
        outstanding = max(group.deposit_due_cents - group.deposit_paid_cents, 0)

        if amount > outstanding do
          rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})
        else
          update_group!(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding - amount,
            revision: group.revision + 1
          })
        end
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp apply_existing(operation, operation_id, "reschedule_group", group) do
    if not present?(operation, ["occurred_on", "new_arrival_on"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
           {:ok, new_arrival_on} <- parse_date(value(operation, "new_arrival_on")),
           :ok <- validate_new_stay(occurred_on, new_arrival_on) do
        stay_length = Date.diff(group.departure_on, group.arrival_on)
        new_departure_on = Date.add(new_arrival_on, stay_length)
        update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(new_arrival_on),
          new_departure_on: Date.to_iso8601(new_departure_on),
          revision: group.revision + 1
        })
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp apply_existing(operation, operation_id, "cancel_group", group) do
    if not present?(operation, ["occurred_on"]) do
      rejection(operation_id, "invalid_operation", %{group_id: group.group_id})
    else
      with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")) do
        refundable? =
          group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

        {refunded, retained} =
          if refundable? do
            {group.deposit_paid_cents, 0}
          else
            {0, group.deposit_paid_cents}
          end

        update_group!(group, %{status: "cancelled"})
        update_ledger!(refunded, retained)

        applied(operation_id, %{
          group_id: group.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          revision: group.revision + 1
        })
      else
        {:error, code} -> rejection(operation_id, code, %{group_id: group.group_id})
      end
    end
  end

  defp update_group!(group, attrs) do
    attrs = Map.put(attrs, :revision, group.revision + 1)
    {:ok, _group} = Repo.update(Group.changeset(group, attrs))
  end

  defp update_ledger!(refunded, retained) do
    ledger = Repo.get(Ledger, 1) || %Ledger{id: 1, cash_refunded_cents: 0, cash_retained_cents: 0}

    attrs = %{
      cash_refunded_cents: ledger.cash_refunded_cents + refunded,
      cash_retained_cents: ledger.cash_retained_cents + retained
    }

    if ledger.id == 1 and Repo.get(Ledger, 1) == nil do
      {:ok, _ledger} = Repo.insert(Ledger.changeset(ledger, attrs))
    else
      {:ok, _ledger} = Repo.update(Ledger.changeset(ledger, attrs))
    end
  end

  defp calculate_deposit(rooms, nights, "advance_purchase") do
    Enum.reduce(rooms, 0, fn room, total -> total + room.lodging_cents * nights end)
  end

  defp calculate_deposit(rooms, nights, "flexible") do
    Enum.reduce(rooms, 0, fn room, total ->
      lodging = room.lodging_cents * nights
      total + round_percentage(lodging, 20, 100)
    end)
  end

  defp round_percentage(amount, numerator, denominator) do
    div(amount * numerator + div(denominator, 2), denominator)
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_new_stay(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"],
    do: {:ok, rate_plan}

  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount), do: {:error, "invalid_amount"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(rooms, {:ok, MapSet.new(), []}, fn room, {:ok, ids, valid_rooms} ->
      room_id = value(room, "room_id")
      nightly_rate = value(room, "nightly_rate_cents")

      cond do
        not is_map(room) or not valid_identifier?(room_id) ->
          {:halt, {:error, "invalid_rooms"}}

        not is_integer(nightly_rate) or nightly_rate <= 0 ->
          {:halt, {:error, "invalid_rooms"}}

        MapSet.member?(ids, room_id) ->
          {:halt, {:error, "invalid_rooms"}}

        true ->
          room_data = %{
            room_id: room_id,
            nightly_rate_cents: nightly_rate,
            lodging_cents: nightly_rate
          }

          {:cont, {:ok, MapSet.put(ids, room_id), [room_data | valid_rooms]}}
      end
    end)
    |> case do
      {:ok, _ids, rooms} -> {:ok, Enum.reverse(rooms)}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_date), do: {:error, "invalid_stay"}

  defp check_revision(operation, group) do
    case fetch(operation, "expected_revision") do
      :missing ->
        :ok

      {:ok, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, :stale_revision, expected_revision}
        end

      {:ok, _invalid_revision} ->
        {:error, :invalid_operation}
    end
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejection(operation_id, code, fields \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
  end

  defp present?(operation, keys) do
    Enum.all?(keys, fn key -> fetch(operation, key) != :missing end)
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp value(map, key) when is_map(map) do
    case fetch(map, key) do
      {:ok, value} -> value
      :missing -> nil
    end
  end

  defp value(_map, _key), do: nil

  defp fetch(map, key) do
    atom_key = String.to_existing_atom(key)

    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(map, atom_key) do
          {:ok, value} -> {:ok, value}
          :error -> :missing
        end
    end
  rescue
    ArgumentError -> :missing
  end
end
