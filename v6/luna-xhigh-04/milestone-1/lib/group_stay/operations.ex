defmodule GroupStay.Operations do
  alias Ecto.Changeset
  alias GroupStay.{Group, Ledger, Repo, Room}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  @type operation :: map()

  @spec process_batch([operation()]) :: [map()]
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec get_group(String.t()) :: map() | nil
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> serialize_group()
    end
  end

  @spec ledger_totals() :: map()
  def ledger_totals do
    ledger = Repo.get!(Ledger, 1)

    %{
      "cash_held_cents" => ledger.cash_held_cents,
      "cash_refunded_cents" => ledger.cash_refunded_cents,
      "cash_retained_cents" => ledger.cash_retained_cents
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")

    with :ok <- validate_operation_id(operation_id),
         type when is_binary(type) <- value(operation, "type"),
         {:ok, result} <- dispatch(type, operation, operation_id) do
      result
    else
      {:error, code} -> rejected(operation_id, code)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp dispatch("open_group", operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      Repo.transaction(fn ->
        if Repo.get(Group, group_id) do
          rejected(operation_id, "group_already_exists", group_id)
        else
          with {:ok, guest_id} <- required_identifier(operation, "guest_id"),
               {:ok, property_id} <- required_identifier(operation, "property_id") do
            open_group(operation, operation_id, group_id, guest_id, property_id)
          else
            {:error, code} -> rejected(operation_id, code, group_id)
          end
        end
      end)
      |> transaction_result()
    end
  end

  defp dispatch(type, operation, operation_id)
       when type in ["record_cash_payment", "reschedule_group", "cancel_group"] do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, result} <-
           Repo.transaction(fn ->
             case Repo.get(Group, group_id) do
               nil -> rejected(operation_id, "group_not_found", group_id)
               group -> apply_existing_group_operation(type, operation, operation_id, group)
             end
           end) do
      {:ok, result}
    end
    |> transaction_result()
  end

  defp dispatch(_type, _operation, _operation_id), do: {:error, "invalid_operation"}

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp open_group(operation, operation_id, group_id, guest_id, property_id) do
    with {:ok, booked_on} <- parse_date(operation, "occurred_on"),
         {:ok, arrival_on} <- parse_date(operation, "arrival_on"),
         {:ok, departure_on} <- parse_date(operation, "departure_on"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         {:ok, room_data} <- validate_rooms(operation, departure_on, arrival_on, rate_plan) do
      lodging_total_cents = Enum.sum(Enum.map(room_data, & &1.lodging_cents))
      deposit_due_cents = Enum.sum(Enum.map(room_data, & &1.deposit_cents))

      group = %Group{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: @active,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        revision: 1
      }

      Repo.insert!(group)

      room_data
      |> Enum.with_index()
      |> Enum.each(fn {room, position} ->
        Repo.insert!(%Room{
          group_id: group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        })
      end)

      applied(operation_id, %{
        "group_id" => group_id,
        "deposit_due_cents" => deposit_due_cents,
        "revision" => 1
      })
    else
      {:error, code} -> rejected(operation_id, code, group_id)
    end
  end

  defp apply_existing_group_operation(type, operation, operation_id, group) do
    case check_expected_revision(operation, operation_id, group) do
      :ok ->
        case type do
          "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
          "reschedule_group" -> reschedule_group(operation, operation_id, group)
          "cancel_group" -> cancel_group(operation, operation_id, group)
        end

      {:error, result} ->
        result
    end
  end

  defp check_expected_revision(operation, operation_id, group) do
    case optional_value(operation, "expected_revision") do
      :missing ->
        :ok

      {:present, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:error,
           rejected(operation_id, "stale_revision", group.group_id, %{
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           })}
        end

      {:present, _invalid_revision} ->
        {:error, rejected(operation_id, "invalid_operation", group.group_id)}
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_operation", group.group_id)

      not valid_positive_integer?(value(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", group.group_id)

      value(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        amount_cents = value(operation, "amount_cents")

        updated_group =
          group
          |> Changeset.change(
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            revision: group.revision + 1
          )
          |> Repo.update!()

        update_ledger!(cash_held_cents: amount_cents)

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding_deposit(updated_group),
          "revision" => updated_group.revision
        })
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_stay", group.group_id)

      true ->
        with {:ok, occurred_on} <- parse_date(operation, "occurred_on"),
             {:ok, new_arrival_on} <- parse_date(operation, "new_arrival_on"),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, shift)

          updated_group =
            group
            |> Changeset.change(
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            )
            |> Repo.update!()

          applied(operation_id, %{
            "group_id" => group.group_id,
            "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
            "revision" => updated_group.revision
          })
        else
          _ -> rejected(operation_id, "invalid_stay", group.group_id)
        end
    end
  end

  defp cancel_group(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_stay", group.group_id)

      true ->
        {:ok, occurred_on} = parse_date(operation, "occurred_on")

        refundable? =
          group.rate_plan == @flexible and Date.diff(group.arrival_on, occurred_on) >= 14

        paid_cents = group.deposit_paid_cents
        refunded_cents = if refundable?, do: paid_cents, else: 0
        retained_cents = if refundable?, do: 0, else: paid_cents

        updated_group =
          group
          |> Changeset.change(status: @cancelled, revision: group.revision + 1)
          |> Repo.update!()

        update_ledger!(
          cash_held_cents: -paid_cents,
          cash_refunded_cents: refunded_cents,
          cash_retained_cents: retained_cents
        )

        applied(operation_id, %{
          "group_id" => group.group_id,
          "refunded_cents" => refunded_cents,
          "retained_cents" => retained_cents,
          "revision" => updated_group.revision
        })
    end
  end

  defp validate_operation_id(operation_id) when is_binary(operation_id) and operation_id != "",
    do: :ok

  defp validate_operation_id(_operation_id), do: {:error, "invalid_operation"}

  defp required_identifier(operation, key) do
    case value(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(operation, key) do
    case value(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp valid_occurred_on?(operation),
    do: match?({:ok, _date}, parse_date(operation, "occurred_on"))

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(operation) do
    case value(operation, "rate_plan") do
      @flexible -> {:ok, @flexible}
      @advance_purchase -> {:ok, @advance_purchase}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp validate_rooms(operation, departure_on, arrival_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    case value(operation, "rooms") do
      rooms when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, MapSet.new(), []}, fn {room, _position}, {:ok, ids, acc} ->
          with {:ok, room_id} <- required_identifier(room, "room_id"),
               {:ok, nightly_rate_cents} <- positive_room_rate(room),
               false <- MapSet.member?(ids, room_id) do
            lodging_cents = nights * nightly_rate_cents
            deposit_cents = deposit_for(rate_plan, lodging_cents)

            {:cont,
             {:ok, MapSet.put(ids, room_id),
              [
                %{
                  room_id: room_id,
                  nightly_rate_cents: nightly_rate_cents,
                  lodging_cents: lodging_cents,
                  deposit_cents: deposit_cents
                }
                | acc
              ]}}
          else
            _ -> {:halt, {:error, "invalid_rooms"}}
          end
        end)
        |> case do
          {:ok, _ids, rooms} -> {:ok, Enum.reverse(rooms)}
          {:error, code} -> {:error, code}
        end

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp positive_room_rate(room) when is_map(room) do
    case value(room, "nightly_rate_cents") do
      rate when is_integer(rate) and rate > 0 -> {:ok, rate}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp positive_room_rate(_room), do: {:error, "invalid_rooms"}

  defp deposit_for(@advance_purchase, lodging_cents), do: lodging_cents
  defp deposit_for(@flexible, lodging_cents), do: div(lodging_cents * 20 + 50, 100)

  defp valid_positive_integer?(amount), do: is_integer(amount) and amount > 0

  defp outstanding_deposit(group) do
    if group.status == @active do
      group.deposit_due_cents - group.deposit_paid_cents
    else
      0
    end
  end

  defp update_ledger!(increments) do
    ledger = Repo.get!(Ledger, 1)

    updated_values =
      Enum.reduce(increments, %{}, fn {field, increment}, values ->
        Map.put(values, field, Map.fetch!(ledger, field) + increment)
      end)

    ledger
    |> Changeset.change(updated_values)
    |> Repo.update!()
  end

  defp serialize_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" =>
        group.rooms
        |> Enum.sort_by(& &1.position)
        |> Enum.map(fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

  defp rejected(operation_id, code, group_id \\ nil, extra \\ []) do
    base = %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    base = if group_id, do: Map.put(base, "group_id", group_id), else: base
    Enum.into(extra, base)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp value(_map, _key), do: nil

  defp optional_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:present, Map.get(map, String.to_atom(key))}
      true -> :missing
    end
  end
end
