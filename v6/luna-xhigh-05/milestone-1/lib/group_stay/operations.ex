defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations one at a time, preserving batch order.

  Each operation gets its own transaction. That lets a rejected operation roll
  back independently while retaining successful operations before and after it.
  """

  import Ecto.Query

  alias GroupStay.{Group, Repo, Room}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  @spec submit_batch(term()) :: {:ok, [map()]} | {:error, :invalid_batch}
  def submit_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def submit_batch(_operations), do: {:error, :invalid_batch}

  @spec get_group(String.t()) :: {:ok, map()} | {:error, :group_not_found}
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group_view(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  @spec ledger_totals() :: map()
  def ledger_totals do
    %{
      cash_held_cents: sum_for_status(@active, :deposit_paid_cents),
      cash_refunded_cents: sum_for_status(@cancelled, :refunded_cents),
      cash_retained_cents: sum_for_status(@cancelled, :retained_cents)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")
    operation_type = value(operation, "type")

    if operation_type == "open_group" do
      process_open_group(operation, operation_id)
    else
      process_existing_group(operation, operation_id, operation_type)
    end
  end

  defp process_operation(_operation), do: rejection(nil, "invalid_operation")

  defp process_open_group(operation, operation_id) do
    group_id = value(operation, "group_id")

    cond do
      not identifier?(operation_id) ->
        rejection(operation_id, "invalid_operation")

      not identifier?(group_id) ->
        rejection(operation_id, "invalid_operation")

      true ->
        transaction_result(fn ->
          if Repo.get(Group, group_id) do
            reject(rejection(operation_id, "group_already_exists", %{group_id: group_id}))
          else
            case validate_open_group(operation) do
              {:ok, attrs, rooms} ->
                group = Repo.insert!(Group.changeset(%Group{}, attrs))
                insert_rooms!(group.group_id, rooms)

                {:ok,
                 applied("open_group", operation_id, %{
                   group_id: group.group_id,
                   deposit_due_cents: group.deposit_due_cents,
                   revision: group.revision
                 })}

              {:error, code} ->
                reject(rejection(operation_id, code, %{group_id: group_id}))
            end
          end
        end)
    end
  end

  defp process_existing_group(operation, operation_id, operation_type) do
    group_id = value(operation, "group_id")

    if not identifier?(group_id) do
      rejection(operation_id, "invalid_operation")
    else
      transaction_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            reject(rejection(operation_id, "group_not_found", %{group_id: group_id}))

          group ->
            case revision_check(operation, group) do
              :ok -> apply_existing(group, operation, operation_id, operation_type)
              {:error, stale} -> reject(stale)
            end
        end
      end)
    end
  end

  defp apply_existing(group, operation, operation_id, operation_type) do
    case operation_type do
      "record_cash_payment" ->
        apply_cash_payment(group, operation, operation_id)

      "reschedule_group" ->
        apply_reschedule(group, operation, operation_id)

      "cancel_group" ->
        apply_cancellation(group, operation, operation_id)

      _ ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_cash_payment(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, _occurred_on} ->
            apply_cash_payment_amount(group, operation, operation_id)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_cash_payment_amount(group, operation, operation_id) do
    amount_cents = value(operation, "amount_cents")
    outstanding = outstanding_deposit(group)

    cond do
      not usable_amount?(amount_cents) ->
        reject(rejection(operation_id, "invalid_amount", %{group_id: group.group_id}))

      amount_cents > outstanding ->
        reject(
          rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})
        )

      true ->
        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          revision: group.revision + 1
        })

        {:ok,
         applied("record_cash_payment", operation_id, %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding - amount_cents,
           revision: group.revision + 1
         })}
    end
  end

  defp apply_reschedule(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, occurred_on} ->
            reschedule_from(group, operation, operation_id, occurred_on)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp reschedule_from(group, operation, operation_id, occurred_on) do
    with {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      update_group!(group, %{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        revision: group.revision + 1
      })

      {:ok,
       applied("reschedule_group", operation_id, %{
         group_id: group.group_id,
         new_arrival_on: Date.to_iso8601(new_arrival_on),
         new_departure_on: Date.to_iso8601(new_departure_on),
         revision: group.revision + 1
       })}
    else
      _ -> reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))
    end
  end

  defp apply_cancellation(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:ok, occurred_on} ->
            refundable? =
              group.rate_plan == @flexible and Date.diff(group.arrival_on, occurred_on) >= 14

            {refunded_cents, retained_cents} =
              if refundable? do
                {group.deposit_paid_cents, 0}
              else
                {0, group.deposit_paid_cents}
              end

            update_group!(group, %{
              status: @cancelled,
              refunded_cents: refunded_cents,
              retained_cents: retained_cents,
              revision: group.revision + 1
            })

            {:ok,
             applied("cancel_group", operation_id, %{
               group_id: group.group_id,
               refunded_cents: refunded_cents,
               retained_cents: retained_cents,
               revision: group.revision + 1
             })}

          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp validate_open_group(operation) do
    with {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, rate_plan} <- valid_rate_plan(value(operation, "rate_plan")),
         {:ok, rooms} <- valid_rooms(value(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total_cents = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))

      deposit_due_cents =
        rooms
        |> Enum.map(fn room ->
          lodging = room.nightly_rate_cents * nights

          case rate_plan do
            @flexible -> round_percentage(lodging, 20)
            @advance_purchase -> lodging
          end
        end)
        |> Enum.sum()

      attrs = %{
        group_id: value(operation, "group_id"),
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: @active,
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0
      }

      {:ok, attrs, rooms}
    else
      {:error, "invalid_operation"} -> {:error, "invalid_operation"}
      {:error, "invalid_stay"} -> {:error, "invalid_stay"}
      {:error, "invalid_rooms"} -> {:error, "invalid_rooms"}
      {:error, "invalid_rate_plan"} -> {:error, "invalid_rate_plan"}
      false -> {:error, "invalid_stay"}
    end
  end

  defp valid_rate_plan(@flexible), do: {:ok, @flexible}
  defp valid_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(Enum.with_index(rooms), {:ok, MapSet.new(), []}, fn
      {room, position}, {:ok, room_ids, valid} when is_map(room) ->
        room_id = value(room, "room_id")
        nightly_rate_cents = value(room, "nightly_rate_cents")

        cond do
          not identifier?(room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          MapSet.member?(room_ids, room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          not is_integer(nightly_rate_cents) or nightly_rate_cents < 0 ->
            {:halt, {:error, "invalid_rooms"}}

          true ->
            {:cont,
             {:ok, MapSet.put(room_ids, room_id),
              [
                %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}
                | valid
              ]}}
        end

      _room, _acc ->
        {:halt, {:error, "invalid_rooms"}}
    end)
    |> case do
      {:ok, _room_ids, rooms} -> {:ok, Enum.reverse(rooms)}
      error -> error
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp required_identifier(operation, key) do
    case value(operation, key) do
      identifier when is_binary(identifier) and identifier != "" -> {:ok, identifier}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(operation, key) do
    case value(operation, key) do
      date when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp operation_date(operation) do
    case value(operation, "occurred_on") do
      nil ->
        {:error, "invalid_operation"}

      date when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp validate_operation_id(operation_id) when is_binary(operation_id) and operation_id != "",
    do: :ok

  defp validate_operation_id(_operation_id), do: {:error, "invalid_operation"}

  defp identifier?(identifier) when is_binary(identifier), do: identifier != ""
  defp identifier?(_identifier), do: false

  defp revision_check(operation, group) do
    case present_value(operation, "expected_revision") do
      :missing ->
        :ok

      {:present, expected_revision} when expected_revision == group.revision ->
        :ok

      {:present, expected_revision} ->
        {:error,
         rejection(value(operation, "operation_id"), "stale_revision", %{
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         })}
    end
  end

  defp transaction_result(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback({:rejected, result})
             result -> result
           end
         end) do
      {:ok, result} -> result
      {:error, {:rejected, result}} -> result
    end
  end

  defp reject(result), do: {:error, result}

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update!()
  end

  defp insert_rooms!(group_id, rooms) do
    Repo.insert_all(
      Room,
      Enum.map(rooms, fn room -> Map.put(room, :group_id, group_id) end)
    )
  end

  defp group_view(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.position
      )

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
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp outstanding_deposit(%Group{status: @cancelled}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp sum_for_status(status, field) do
    Repo.one(
      from group in Group,
        where: group.status == ^status,
        select: coalesce(sum(field(group, ^field)), 0)
    )
  end

  defp usable_amount?(amount_cents), do: is_integer(amount_cents) and amount_cents > 0

  defp round_percentage(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
  end

  defp applied(_type, operation_id, attrs) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, attrs)
  end

  defp rejection(operation_id, code, attrs \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, attrs)
  end

  defp value(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> nil
    end
  end

  defp present_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:present, Map.get(map, String.to_atom(key))}
      true -> :missing
    end
  end
end
