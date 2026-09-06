defmodule GroupStay.Operations do
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @valid_rate_plans ["flexible", "advance_purchase"]

  @doc "Processes partner operations independently and in the order supplied."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp process_operation(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> update_group(operation, :payment)
      "reschedule_group" -> update_group(operation, :reschedule)
      "cancel_group" -> update_group(operation, :cancel)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp open_group(operation) do
    with :ok <- validate_common(operation),
         :ok <- validate_identifiers(operation, ["group_id", "guest_id", "property_id"]) do
      group_id = operation["group_id"]

      with_write_lock(fn ->
        Repo.transaction(fn ->
          if Repo.get(Group, group_id) do
            rejected(operation, "group_already_exists")
          else
            case open_details(operation) do
              {:ok, details} ->
                attrs = %{
                  group_id: group_id,
                  guest_id: operation["guest_id"],
                  property_id: operation["property_id"],
                  booked_on: details.booked_on,
                  arrival_on: details.arrival_on,
                  departure_on: details.departure_on,
                  rate_plan: operation["rate_plan"],
                  status: "active",
                  lodging_total_cents: details.lodging_total_cents,
                  deposit_due_cents: details.deposit_due_cents,
                  deposit_paid_cents: 0,
                  cash_refunded_cents: 0,
                  cash_retained_cents: 0,
                  revision: 1
                }

                case Groups.insert_group(attrs, details.rooms) do
                  {:ok, _group} ->
                    %{
                      operation_id: operation_id(operation),
                      status: "applied",
                      group_id: group_id,
                      deposit_due_cents: details.deposit_due_cents,
                      revision: 1
                    }

                  {:error, _reason} ->
                    Repo.rollback(:group_insert_failed)
                end

              {:error, code} ->
                rejected(operation, code)
            end
          end
        end)
      end)
      |> transaction_result()
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp update_group(operation, kind) do
    with :ok <- validate_operation_id(operation),
         :ok <- validate_identifiers(operation, ["group_id"]) do
      group_id = operation["group_id"]

      with_write_lock(fn ->
        Repo.transaction(fn ->
          case Repo.get(Group, group_id) do
            nil ->
              rejected(operation, "group_not_found")

            group ->
              case check_expected_revision(operation, group) do
                :ok -> apply_group_operation(operation, kind, group)
                {:error, stale} -> stale
              end
          end
        end)
      end)
      |> transaction_result()
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp apply_group_operation(operation, :payment, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      amount = operation["amount_cents"]

      cond do
        not usable_amount?(amount) ->
          rejected(operation, "invalid_amount")

        amount > outstanding_deposit(group) ->
          rejected(operation, "payment_exceeds_outstanding")

        not valid_date?(operation["occurred_on"]) ->
          rejected(operation, "invalid_operation")

        true ->
          updated = update_group!(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

          applied(operation, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding_deposit(updated),
            revision: updated.revision
          })
      end
    end
  end

  defp apply_group_operation(operation, :reschedule, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
           true <- Date.compare(new_arrival_on, occurred_on) == :gt do
        nights = Date.diff(group.departure_on, group.arrival_on)
        new_departure_on = Date.add(new_arrival_on, nights)

        updated =
          update_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on
          })

        applied(operation, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(updated.arrival_on),
          new_departure_on: Date.to_iso8601(updated.departure_on),
          revision: updated.revision
        })
      else
        _ -> rejected(operation, "invalid_stay")
      end
    end
  end

  defp apply_group_operation(operation, :cancel, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      case parse_date(operation["occurred_on"]) do
        {:ok, occurred_on} ->
          {refunded, retained} = cancellation_totals(group, occurred_on)

          updated =
            update_group!(group, %{
              status: "cancelled",
              cash_refunded_cents: refunded,
              cash_retained_cents: retained
            })

          applied(operation, %{
            group_id: group.group_id,
            refunded_cents: updated.cash_refunded_cents,
            retained_cents: updated.cash_retained_cents,
            revision: updated.revision
          })

        {:error, _reason} ->
          rejected(operation, "invalid_stay")
      end
    end
  end

  defp open_details(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         :ok <- validate_rate_plan(operation["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)

      room_totals =
        Enum.map(rooms, fn room ->
          lodging = nights * room.nightly_rate_cents
          deposit = deposit_for(operation["rate_plan"], lodging)
          Map.merge(room, %{lodging_cents: lodging, deposit_cents: deposit})
        end)

      {:ok,
       %{
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rooms:
           Enum.with_index(rooms)
           |> Enum.map(fn {room, position} -> Map.put(room, :position, position) end),
         lodging_total_cents: Enum.sum(Enum.map(room_totals, & &1.lodging_cents)),
         deposit_due_cents: Enum.sum(Enum.map(room_totals, & &1.deposit_cents))
       }}
    else
      false -> {:error, "invalid_stay"}
      {:error, "invalid_rooms"} -> {:error, "invalid_rooms"}
      {:error, "invalid_rate_plan"} -> {:error, "invalid_rate_plan"}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn room, {:ok, ids, valid_rooms} ->
      if is_map(room) and valid_identifier?(room["room_id"]) and
           usable_rate?(room["nightly_rate_cents"]) and
           not MapSet.member?(ids, room["room_id"]) do
        {:cont,
         {:ok, MapSet.put(ids, room["room_id"]),
          [
            %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
            | valid_rooms
          ]}}
      else
        {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, _ids, valid_rooms} -> {:ok, Enum.reverse(valid_rooms)}
      error -> error
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @valid_rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp cancellation_totals(
         %Group{rate_plan: "flexible", deposit_paid_cents: paid, arrival_on: arrival},
         occurred_on
       ) do
    if Date.diff(arrival, occurred_on) >= 14, do: {paid, 0}, else: {0, paid}
  end

  defp cancellation_totals(%Group{deposit_paid_cents: paid}, _occurred_on), do: {0, paid}

  defp deposit_for("advance_purchase", lodging), do: lodging
  defp deposit_for("flexible", lodging), do: round_percentage(lodging, 20, 100)

  defp round_percentage(amount, numerator, denominator) do
    div(amount * numerator + div(denominator, 2), denominator)
  end

  defp update_group!(group, attrs) do
    group
    |> Ecto.Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp check_expected_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       %{
         operation_id: operation_id(operation),
         status: "rejected",
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp validate_common(operation) do
    cond do
      validate_operation_id(operation) != :ok -> {:error, "invalid_operation"}
      not Map.has_key?(operation, "occurred_on") -> {:error, "invalid_operation"}
      true -> :ok
    end
  end

  defp validate_operation_id(operation) do
    if valid_identifier?(operation_id(operation)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp validate_identifiers(operation, keys) do
    if Enum.all?(keys, &valid_identifier?(operation[&1])) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp usable_rate?(value), do: is_integer(value) and value > 0
  defp usable_amount?(value), do: is_integer(value) and value > 0
  defp valid_date?(value), do: match?({:ok, _date}, parse_date(value))
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp transaction_result({:ok, result}), do: result

  defp transaction_result({:error, :group_insert_failed}), do: raise("could not insert group")

  defp with_write_lock(fun), do: :global.trans({__MODULE__, :write}, fun)

  defp applied(operation, fields) do
    Map.merge(%{operation_id: operation_id(operation), status: "applied"}, fields)
  end

  defp rejected(operation, code) do
    %{operation_id: operation_id(operation), status: "rejected", code: code}
  end

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_operation), do: nil

  defp outstanding_deposit(%Group{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end
end
