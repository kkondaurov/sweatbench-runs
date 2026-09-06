defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Groups
  alias GroupStay.Groups.{CreditAllocation, CreditLot, Group}
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @valid_rate_plans ["flexible", "advance_purchase"]
  @valid_refund_methods ["cash", "hotel_credit"]

  @doc "Processes partner operations independently and in the order supplied."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp process_operation(operation) do
    if valid_identifier?(operation_id(operation)) do
      process_durable_operation(operation)
    else
      process_operation_body(operation)
    end
  end

  def result_for(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  defp process_durable_operation(operation) do
    with_write_lock(fn ->
      Repo.transaction(fn ->
        case claim_operation(operation) do
          {:new, record} ->
            result = process_operation_body(operation)
            remember_operation!(record, result)

          {:existing, record} ->
            if record.payload == operation do
              record.result
            else
              rejected(operation, "operation_id_conflict")
            end
        end
      end)
    end)
    |> transaction_result()
  end

  defp process_operation_body(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> update_group(operation, :payment)
      "apply_hotel_credit" -> update_group(operation, :credit)
      "reschedule_group" -> update_group(operation, :reschedule)
      "cancel_group" -> update_group(operation, :cancel)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp open_group(operation) do
    with :ok <- validate_common(operation),
         :ok <- validate_identifiers(operation, ["group_id", "guest_id", "property_id"]) do
      group_id = operation["group_id"]

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
              policy_version: details.policy_version,
              status: "active",
              lodging_total_cents: details.lodging_total_cents,
              deposit_due_cents: details.deposit_due_cents,
              deposit_paid_cents: 0,
              cash_paid_cents: 0,
              credit_paid_cents: 0,
              cash_refunded_cents: 0,
              cash_retained_cents: 0,
              cash_converted_to_credit_cents: 0,
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
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp update_group(operation, kind) do
    with :ok <- validate_operation_id(operation),
         :ok <- validate_identifiers(operation, ["group_id"]) do
      group_id = operation["group_id"]

      case Repo.get(Group, group_id) do
        nil ->
          rejected(operation, "group_not_found")

        group ->
          case check_expected_revision(operation, group) do
            :ok -> apply_group_operation(operation, kind, group)
            {:error, stale} -> stale
          end
      end
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
          updated =
            update_group!(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              cash_paid_cents: cash_paid_cents(group) + amount
            })

          applied(operation, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding_deposit(updated),
            revision: updated.revision
          })
      end
    end
  end

  defp apply_group_operation(operation, :credit, %Group{status: status} = group) do
    if status != "active" do
      rejected(operation, "group_not_active")
    else
      amount = operation["amount_cents"]

      cond do
        not usable_amount?(amount) ->
          rejected(operation, "invalid_amount")

        amount > outstanding_deposit(group) ->
          rejected(operation, "payment_exceeds_outstanding")

        true ->
          case parse_date(operation["occurred_on"]) do
            {:ok, occurred_on} ->
              lots = available_credit_lots(group.guest_id, occurred_on)

              if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
                rejected(operation, "insufficient_credit")
              else
                apply_credit_lots(group, lots, amount)

                updated =
                  update_group!(group, %{
                    deposit_paid_cents: group.deposit_paid_cents + amount,
                    credit_paid_cents: (group.credit_paid_cents || 0) + amount
                  })

                applied(operation, %{
                  group_id: group.group_id,
                  amount_cents: amount,
                  outstanding_deposit_cents: outstanding_deposit(updated),
                  revision: updated.revision
                })
              end

            {:error, _reason} ->
              rejected(operation, "invalid_operation")
          end
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
          policy_version: Groups.policy_version(updated),
          refundable_until: serialize_date(Groups.refundable_until(updated)),
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
      with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, refund_method} <- cancellation_refund_method(operation) do
        refundable = Groups.refundable?(group, occurred_on)

        cond do
          refund_method == "hotel_credit" and not refundable ->
            rejected(operation, "refund_method_not_available")

          refundable ->
            settle_refundable_cancellation(operation, group, occurred_on, refund_method)

          true ->
            settle_nonrefundable_cancellation(operation, group)
        end
      else
        {:error, "invalid_operation"} -> rejected(operation, "invalid_operation")
        _ -> rejected(operation, "invalid_stay")
      end
    end
  end

  defp settle_refundable_cancellation(operation, group, occurred_on, refund_method) do
    restore_credit_allocations(group.group_id, occurred_on)
    cash_paid = cash_paid_cents(group)

    {refunded, retained, converted, credit_issued} =
      case refund_method do
        "cash" ->
          {cash_paid, 0, 0, 0}

        "hotel_credit" ->
          credit_issued = cash_paid + round_percentage(cash_paid, 10, 100)

          if credit_issued > 0 do
            Repo.insert!(%CreditLot{
              guest_id: group.guest_id,
              source_operation_id: operation_id(operation),
              remaining_cents: credit_issued,
              expires_on: Date.add(occurred_on, 365)
            })
          end

          {0, 0, cash_paid, credit_issued}
      end

    updated =
      update_group!(group, %{
        status: "cancelled",
        cash_refunded_cents: refunded,
        cash_retained_cents: retained,
        cash_converted_to_credit_cents: converted
      })

    applied(operation, %{
      group_id: group.group_id,
      refunded_cents: updated.cash_refunded_cents,
      retained_cents: updated.cash_retained_cents,
      credit_issued_cents: credit_issued,
      revision: updated.revision
    })
  end

  defp settle_nonrefundable_cancellation(operation, group) do
    consume_credit_allocations(group.group_id)
    cash_paid = cash_paid_cents(group)

    updated =
      update_group!(group, %{
        status: "cancelled",
        cash_refunded_cents: 0,
        cash_retained_cents: cash_paid,
        cash_converted_to_credit_cents: 0
      })

    applied(operation, %{
      group_id: group.group_id,
      refunded_cents: updated.cash_refunded_cents,
      retained_cents: updated.cash_retained_cents,
      credit_issued_cents: 0,
      revision: updated.revision
    })
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
         policy_version: Groups.policy_version_for(operation["rate_plan"], booked_on),
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

  defp deposit_for("advance_purchase", lodging), do: lodging
  defp deposit_for("flexible", lodging), do: round_percentage(lodging, 20, 100)

  defp available_credit_lots(guest_id, occurred_on) do
    from(l in CreditLot,
      where:
        l.guest_id == ^guest_id and l.remaining_cents > 0 and
          l.expires_on >= ^occurred_on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
    |> Repo.all()
  end

  defp apply_credit_lots(group, lots, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      applied = min(remaining, lot.remaining_cents)

      if applied > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - applied)
        |> Repo.update!()

        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: applied
        })
      end

      next_remaining = remaining - applied

      if next_remaining == 0 do
        {:halt, 0}
      else
        {:cont, next_remaining}
      end
    end)
  end

  defp restore_credit_allocations(group_id, occurred_on) do
    group_credit_allocations(group_id)
    |> Enum.each(fn {allocation, lot} ->
      if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt] do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp consume_credit_allocations(group_id) do
    group_credit_allocations(group_id)
    |> Enum.each(fn {allocation, _lot} -> Repo.delete!(allocation) end)
  end

  defp group_credit_allocations(group_id) do
    from(a in CreditAllocation,
      join: l in CreditLot,
      on: l.id == a.credit_lot_id,
      where: a.group_id == ^group_id,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id, asc: a.id],
      select: {a, l}
    )
    |> Repo.all()
  end

  defp cancellation_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in @valid_refund_methods -> {:ok, method}
      _ -> {:error, "invalid_operation"}
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

  defp claim_operation(operation) do
    attrs = %{
      operation_id: operation_id(operation),
      type: stored_type(operation["type"]),
      payload: operation,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    case Repo.insert_all(Operation, [attrs],
           on_conflict: :nothing,
           conflict_target: [:operation_id]
         ) do
      {1, _} -> {:new, Repo.get_by!(Operation, operation_id: operation_id(operation))}
      {0, _} -> {:existing, Repo.get_by!(Operation, operation_id: operation_id(operation))}
    end
  end

  defp remember_operation!(record, result) do
    result = json_result(result)

    record
    |> Ecto.Changeset.change(result: result)
    |> Repo.update!()

    result
  end

  defp stored_type(type) when is_binary(type), do: type
  defp stored_type(_type), do: nil

  defp json_result(result), do: result |> Jason.encode!() |> Jason.decode!()

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

  defp cash_paid_cents(%Group{
         cash_paid_cents: cash,
         deposit_paid_cents: deposit,
         credit_paid_cents: credit
       }) do
    cond do
      is_integer(cash) and cash > 0 -> cash
      is_integer(credit) and credit > 0 -> 0
      is_integer(deposit) -> deposit
      true -> 0
    end
  end

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

  defp serialize_date(nil), do: nil
  defp serialize_date(date), do: Date.to_iso8601(date)
end
