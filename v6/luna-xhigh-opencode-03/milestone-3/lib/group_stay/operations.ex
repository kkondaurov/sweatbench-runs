defmodule GroupStay.Operations do
  import Ecto.Query
  import Ecto.Changeset

  alias GroupStay.{
    CancellationPolicy,
    CreditLot,
    Group,
    GroupCreditAllocation,
    OperationRecord,
    GroupRoom,
    Repo
  }

  @flexible_rate_plan "flexible"
  @advance_purchase_rate_plan "advance_purchase"
  @max_sqlite_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply/1)
  end

  def get(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, Jason.decode!(record.result_json)}
    end
  end

  def get(_operation_id), do: {:error, :operation_not_found}

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
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group"
            ] do
    in_transaction(operation, operation_id, fn current_operation, current_id ->
      with {:ok, group} <- find_group(current_operation, current_id),
           :ok <- check_revision(current_operation, current_id, group),
           :ok <- active_group(current_id, group) do
        case type do
          "record_cash_payment" -> record_cash_payment(current_operation, current_id, group)
          "apply_hotel_credit" -> apply_hotel_credit(current_operation, current_id, group)
          "reschedule_group" -> reschedule_group(current_operation, current_id, group)
          "cancel_group" -> cancel_group(current_operation, current_id, group)
        end
      end
    end)
  end

  defp apply_known_operation(operation, operation_id) do
    in_transaction(operation, operation_id, fn _operation, current_id ->
      reject(current_id, "invalid_operation")
    end)
  end

  defp in_transaction(operation, operation_id, function) do
    payload_json = encode_payload(operation)

    {:ok, result} =
      Repo.transaction(
        fn ->
          case Repo.get_by(OperationRecord, operation_id: operation_id) do
            nil ->
              result = execute_operation(function, operation, operation_id)
              persist_operation!(operation, operation_id, payload_json, result)
              Jason.decode!(encode_result(result))

            record ->
              if record.payload_json == payload_json do
                Jason.decode!(record.result_json)
              else
                rejected(operation_id, "operation_id_conflict")
              end
          end
        end,
        mode: :immediate
      )

    result
  end

  defp execute_operation(function, operation, operation_id) do
    Repo.query!("SAVEPOINT group_stay_operation")

    try do
      result = function.(operation, operation_id)
      Repo.query!("RELEASE SAVEPOINT group_stay_operation")
      result
    catch
      :throw, {:group_stay_rejected, result} ->
        Repo.query!("ROLLBACK TO SAVEPOINT group_stay_operation")
        Repo.query!("RELEASE SAVEPOINT group_stay_operation")
        result
    end
  end

  defp persist_operation!(operation, operation_id, payload_json, result) do
    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload_json: payload_json,
      result_json: encode_result(result)
    })
    |> Repo.insert!()
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp encode_payload(operation), do: operation |> canonicalize() |> Jason.encode!()
  defp encode_result(result), do: Jason.encode!(result)

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, nested_value} -> {key, canonicalize(nested_value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

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
      update_group!(group, %{
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        cash_paid_cents: group.cash_paid_cents + amount_cents
      })

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

  defp apply_hotel_credit(operation, operation_id, group) do
    with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(Map.get(operation, "amount_cents")),
         outstanding when amount_cents <= outstanding <- outstanding_deposit(group),
         lots <- available_credit_lots(group.guest_id, occurred_on),
         :ok <- enough_credit(lots, amount_cents),
         :ok <- allocate_credit(group, lots, amount_cents) do
      update_group!(group, %{
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        credit_paid_cents: group.credit_paid_cents + amount_cents
      })

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
        policy_version: group.policy_version,
        refundable_until:
          CancellationPolicy.refundable_until(group.policy_version, new_arrival_on)
          |> format_date(),
        revision: group.revision + 1
      }
    else
      _ -> reject_and_rollback({"invalid_stay", %{}, operation_id})
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(Map.get(operation, "occurred_on")),
         {:ok, refund_method} <- refund_method(operation),
         refundable <- refundable?(group, occurred_on),
         :ok <- available_refund_method(refund_method, refundable) do
      {refunded_cents, retained_cents, credit_issued_cents, cash_converted_to_credit_cents} =
        settle_cancellation(group, occurred_on, refund_method, refundable, operation_id)

      update_group!(group, %{
        status: "cancelled",
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        cash_converted_to_credit_cents: cash_converted_to_credit_cents
      })

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: group.revision + 1
      }
    else
      {:error, code} -> reject_and_rollback({code, %{}, operation_id})
    end
  end

  defp available_credit_lots(guest_id, occurred_on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
    |> Enum.filter(&(Date.compare(&1.expires_on, occurred_on) == :gt))
  end

  defp enough_credit(lots, amount_cents) do
    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) >= amount_cents do
      :ok
    else
      {:error, "insufficient_credit"}
    end
  end

  defp allocate_credit(group, lots, amount_cents) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining ->
      allocated = min(lot.remaining_cents, remaining)

      if allocated > 0 do
        lot
        |> change(remaining_cents: lot.remaining_cents - allocated)
        |> Repo.update!()

        %GroupCreditAllocation{}
        |> GroupCreditAllocation.changeset(%{
          group_record_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: allocated
        })
        |> Repo.insert!()
      end

      remaining = remaining - allocated

      if remaining == 0 do
        {:halt, 0}
      else
        {:cont, remaining}
      end
    end)

    :ok
  end

  defp settle_cancellation(group, occurred_on, "cash", true, _operation_id) do
    restore_credit_allocations(group, occurred_on)
    {group.cash_paid_cents, 0, 0, 0}
  end

  defp settle_cancellation(group, _occurred_on, "cash", false, _operation_id) do
    consume_credit_allocations(group)
    {0, group.cash_paid_cents, 0, 0}
  end

  defp settle_cancellation(group, occurred_on, "hotel_credit", true, operation_id) do
    restore_credit_allocations(group, occurred_on)
    credit_issued_cents = credit_value(group.cash_paid_cents)

    if credit_issued_cents > 0 do
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        expires_on: Date.add(occurred_on, 366)
      })
      |> Repo.insert!()
    end

    {0, 0, credit_issued_cents, group.cash_paid_cents}
  end

  defp consume_credit_allocations(group) do
    Repo.delete_all(
      from allocation in GroupCreditAllocation, where: allocation.group_record_id == ^group.id
    )

    :ok
  end

  defp restore_credit_allocations(group, occurred_on) do
    allocations =
      Repo.all(
        from allocation in GroupCreditAllocation,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where: allocation.group_record_id == ^group.id,
          select: {allocation, lot}
      )

    Enum.each(allocations, fn {allocation, lot} ->
      if Date.compare(lot.expires_on, occurred_on) == :gt do
        lot = Repo.get!(CreditLot, lot.id)

        lot
        |> change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)

    :ok
  end

  defp refundable?(group, occurred_on) do
    CancellationPolicy.refundable?(group.policy_version, group.arrival_on, occurred_on)
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_refund_method"}
    end
  end

  defp available_refund_method("cash", _refundable), do: :ok
  defp available_refund_method("hotel_credit", true), do: :ok

  defp available_refund_method("hotel_credit", false),
    do: {:error, "refund_method_not_available"}

  defp credit_value(cash_paid_cents) do
    cash_paid_cents + round_half_up(cash_paid_cents * 10, 100)
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
           policy_version: CancellationPolicy.version(rate_plan, booked_on),
           status: "active",
           revision: 1,
           lodging_total_cents: lodging_total_cents,
           deposit_due_cents: deposit_due_cents,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           refunded_cents: 0,
           retained_cents: 0,
           cash_converted_to_credit_cents: 0,
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
    throw({:group_stay_rejected, rejected(operation_id, code, details)})
  end

  defp normalize_rejection({code, details, operation_id}), do: {code, details, operation_id}
  defp normalize_rejection(code), do: {code, %{}, nil}
end
