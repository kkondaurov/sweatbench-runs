defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashEntry, Group, Room}

  @rate_plans ["flexible", "advance_purchase"]

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger_totals do
    %{
      cash_held_cents: active_cash_held(),
      cash_refunded_cents: cash_total("cash_refund"),
      cash_retained_cents: cash_total("cash_retention")
    }
  end

  defp apply_operation(operation) when is_map(operation) do
    if Map.get(operation, "type") in [
         "open_group",
         "record_cash_payment",
         "reschedule_group",
         "cancel_group"
       ] do
      case Repo.transaction(fn ->
             case perform_operation(operation) do
               {:applied, result} -> result
               {:rejected, result} -> Repo.rollback(result)
             end
           end) do
        {:ok, result} -> result
        {:error, :concurrent_update} -> apply_operation(operation)
        {:error, result} -> result
      end
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp apply_operation(operation), do: rejected(operation, "invalid_operation")

  defp perform_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp perform_operation(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp perform_operation(%{"type" => "reschedule_group"} = operation),
    do: reschedule_group(operation)

  defp perform_operation(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp open_group(operation) do
    with {:ok, booked_on} <- validate_common(operation),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, guest_id} <- identifier(operation, "guest_id"),
         {:ok, property_id} <- identifier(operation, "property_id"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation, arrival_on, departure_on, rate_plan) do
      if Repo.exists?(from group in Group, where: group.group_id == ^group_id) do
        {:rejected, rejected(operation, "group_already_exists")}
      else
        lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
        deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_cents))

        attrs = %{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: "active",
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          revision: 1
        }

        case Repo.insert(Group.changeset(%Group{}, attrs)) do
          {:ok, group} ->
            Enum.each(rooms, fn room ->
              Repo.insert!(
                Room.changeset(%Room{}, %{
                  group_id: group.id,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents,
                  position: room.position
                })
              )
            end)

            {:applied,
             applied(operation, %{
               "group_id" => group.group_id,
               "deposit_due_cents" => deposit_due_cents,
               "revision" => group.revision
             })}

          {:error, _changeset} ->
            {:rejected, rejected(operation, "group_already_exists")}
        end
      end
    else
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- payment_amount(operation),
         :ok <- within_outstanding(amount_cents, group) do
      outstanding_deposit_cents =
        group.deposit_due_cents - group.deposit_paid_cents - amount_cents

      group =
        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          revision: group.revision + 1
        })

      insert_cash_entry!(group, "cash_payment", amount_cents, occurred_on)

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit_cents,
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- arrival_after_operation(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      group =
        update_group!(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group) do
      refunded_cents = refundable_amount(group, occurred_on)
      retained_cents = group.deposit_paid_cents - refunded_cents

      group = update_group!(group, %{status: "cancelled", revision: group.revision + 1})

      if refunded_cents > 0 do
        insert_cash_entry!(group, "cash_refund", refunded_cents, occurred_on)
      end

      if retained_cents > 0 do
        insert_cash_entry!(group, "cash_retention", retained_cents, occurred_on)
      end

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp validate_common(operation) do
    with {:ok, _operation_id} <- identifier(operation, "operation_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on") do
      {:ok, occurred_on}
    end
  end

  defp identifier(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(operation, key) do
    case Map.fetch(operation, key) do
      :error -> {:error, "invalid_operation"}
      {:ok, nil} -> {:error, "invalid_operation"}
      {:ok, date} when is_binary(date) -> parse_date(date)
      {:ok, _value} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed_date} -> {:ok, parsed_date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, "invalid_operation"}
      {:ok, rate_plan} when rate_plan in @rate_plans -> {:ok, rate_plan}
      {:ok, _rate_plan} -> {:error, "invalid_rate_plan"}
    end
  end

  defp rooms(operation, arrival_on, departure_on, rate_plan) do
    case Map.fetch(operation, "rooms") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {room, position},
                                                           {:ok, {valid_rooms, ids}} ->
          case room_details(room, position, arrival_on, departure_on, rate_plan, ids) do
            {:ok, valid_room, updated_ids} ->
              {:cont, {:ok, {[valid_room | valid_rooms], updated_ids}}}

            {:error, code} ->
              {:halt, {:error, code}}
          end
        end)
        |> case do
          {:ok, {valid_rooms, _ids}} -> {:ok, Enum.reverse(valid_rooms)}
          {:error, code} -> {:error, code}
        end

      {:ok, _rooms} ->
        {:error, "invalid_rooms"}
    end
  end

  defp room_details(room, position, arrival_on, departure_on, rate_plan, ids) when is_map(room) do
    with room_id when is_binary(room_id) and byte_size(room_id) > 0 <- Map.get(room, "room_id"),
         false <- MapSet.member?(ids, room_id),
         nightly_rate_cents when is_integer(nightly_rate_cents) and nightly_rate_cents >= 0 <-
           Map.get(room, "nightly_rate_cents") do
      lodging_total_cents = Date.diff(departure_on, arrival_on) * nightly_rate_cents

      deposit_cents =
        if rate_plan == "flexible" do
          round_half_up(lodging_total_cents * 20, 100)
        else
          lodging_total_cents
        end

      {:ok,
       %{
         room_id: room_id,
         nightly_rate_cents: nightly_rate_cents,
         lodging_total_cents: lodging_total_cents,
         deposit_cents: deposit_cents,
         position: position
       }, MapSet.put(ids, room_id)}
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp room_details(_room, _position, _arrival_on, _departure_on, _rate_plan, _ids),
    do: {:error, "invalid_rooms"}

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp current_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         Map.get(operation, "expected_revision") != group.revision do
      {:error,
       {:stale_revision,
        rejected(operation, "stale_revision", %{
          "group_id" => group.group_id,
          "expected_revision" => Map.get(operation, "expected_revision"),
          "actual_revision" => group.revision
        })}}
    else
      :ok
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(%Group{}), do: {:error, "group_not_active"}

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, "invalid_amount"}
    end
  end

  defp within_outstanding(amount_cents, group) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp refundable_amount(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14, do: group.deposit_paid_cents, else: 0
  end

  defp refundable_amount(%Group{}, _occurred_on), do: 0

  defp update_group!(group, attrs) do
    {updated_count, _} =
      Repo.update_all(
        from(current_group in Group,
          where: current_group.id == ^group.id and current_group.revision == ^group.revision
        ),
        set: Map.to_list(attrs)
      )

    if updated_count == 1 do
      struct(group, attrs)
    else
      Repo.rollback(:concurrent_update)
    end
  end

  defp insert_cash_entry!(group, entry_type, amount_cents, occurred_on) do
    Repo.insert!(
      CashEntry.changeset(%CashEntry{}, %{
        group_id: group.id,
        entry_type: entry_type,
        amount_cents: amount_cents,
        occurred_on: occurred_on
      })
    )
  end

  defp active_cash_held do
    Repo.one(
      from group in Group,
        where: group.status == "active",
        select: coalesce(sum(group.deposit_paid_cents), 0)
    )
  end

  defp cash_total(entry_type) do
    Repo.one(
      from entry in CashEntry,
        where: entry.entry_type == ^entry_type,
        select: coalesce(sum(entry.amount_cents), 0)
    )
  end

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.id,
          order_by: [asc: room.position]
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

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0
  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp applied(operation, fields), do: Map.merge(base_result(operation, "applied"), fields)

  defp rejected(operation, code, fields \\ %{}),
    do: Map.merge(base_result(operation, "rejected"), Map.put(fields, "code", code))

  defp base_result(operation, status) when is_map(operation) do
    %{"status" => status}
    |> maybe_put_operation_id(Map.get(operation, "operation_id"))
  end

  defp base_result(_operation, status), do: %{"status" => status}

  defp maybe_put_operation_id(result, operation_id) when is_binary(operation_id),
    do: Map.put(result, "operation_id", operation_id)

  defp maybe_put_operation_id(result, _operation_id), do: result
end
