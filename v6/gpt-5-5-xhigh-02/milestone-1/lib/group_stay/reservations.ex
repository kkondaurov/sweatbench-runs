defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  def submit_partner_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &apply_operation/1)}
  end

  def submit_partner_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> where([group], group.group_id == ^group_id)
    |> preload_rooms()
    |> Repo.one()
  end

  def ledger_totals do
    active_totals =
      from(group in Group,
        where: group.status == @active,
        select: coalesce(sum(group.deposit_paid_cents), 0)
      )
      |> Repo.one()

    refunded_totals =
      from(group in Group,
        select: coalesce(sum(group.refunded_cents), 0)
      )
      |> Repo.one()

    retained_totals =
      from(group in Group,
        select: coalesce(sum(group.retained_cents), 0)
      )
      |> Repo.one()

    %{
      cash_held_cents: active_totals,
      cash_refunded_cents: refunded_totals,
      cash_retained_cents: retained_totals
    }
  end

  def serialize_group(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  defp serialize_room(%Room{} = room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents
    }
  end

  defp apply_operation(%{"operation_id" => operation_id, "type" => "open_group"} = operation)
       when is_binary(operation_id) do
    operation_transaction(fn -> open_group(operation) end)
  end

  defp apply_operation(
         %{"operation_id" => operation_id, "type" => "record_cash_payment"} = operation
       )
       when is_binary(operation_id) do
    operation_transaction(fn ->
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           :ok <- require_common_operation_date(operation),
           {:ok, amount_cents} <- fetch_payment_amount_value(operation),
           :ok <- ensure_usable_payment_amount(operation, amount_cents),
           :ok <- ensure_payment_within_outstanding(operation, group, amount_cents) do
        apply_cash_payment(operation, group, amount_cents)
      end
    end)
  end

  defp apply_operation(
         %{"operation_id" => operation_id, "type" => "reschedule_group"} = operation
       )
       when is_binary(operation_id) do
    operation_transaction(fn ->
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, new_arrival_on} <- fetch_date(operation, "new_arrival_on", :invalid_stay),
           :ok <- ensure_new_arrival_after_operation(operation, new_arrival_on, occurred_on) do
        reschedule_group(operation, group, new_arrival_on)
      end
    end)
  end

  defp apply_operation(%{"operation_id" => operation_id, "type" => "cancel_group"} = operation)
       when is_binary(operation_id) do
    operation_transaction(fn ->
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation) do
        cancel_group(operation, group, occurred_on)
      end
    end)
  end

  defp apply_operation(operation) do
    reject(operation_id_from(operation), :invalid_operation)
  end

  defp open_group(operation) do
    with {:ok, group_id} <- fetch_string(operation, "group_id"),
         {:ok, guest_id} <- fetch_string(operation, "guest_id"),
         {:ok, property_id} <- fetch_string(operation, "property_id"),
         {:ok, booked_on} <- fetch_operation_date(operation),
         {:ok, arrival_on} <- fetch_date(operation, "arrival_on", :invalid_stay),
         {:ok, departure_on} <- fetch_date(operation, "departure_on", :invalid_stay),
         :ok <- ensure_valid_stay(operation, arrival_on, departure_on),
         {:ok, rate_plan} <- fetch_rate_plan(operation),
         {:ok, rooms} <- build_rooms(operation, arrival_on, departure_on, rate_plan),
         :ok <- ensure_group_available(operation, group_id) do
      lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_amount_cents))
      deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

      group_attrs = %{
        group_id: group_id,
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

      case Repo.insert(Group.changeset(%Group{}, group_attrs)) do
        {:ok, group} ->
          insert_rooms(operation, group, rooms)

          {:ok,
           %{
             operation_id: operation["operation_id"],
             status: "applied",
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}

        {:error, changeset} ->
          if has_unique_group_error?(changeset) do
            {:error, reject(operation["operation_id"], :group_already_exists)}
          else
            {:error, reject(operation["operation_id"], :invalid_operation)}
          end
      end
    end
  end

  defp apply_cash_payment(operation, group, amount_cents) do
    new_paid_cents = group.deposit_paid_cents + amount_cents
    revision = group.revision + 1

    group
    |> Group.changeset(%{deposit_paid_cents: new_paid_cents, revision: revision})
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
           revision: updated_group.revision
         }}

      {:error, _changeset} ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp reschedule_group(operation, group, new_arrival_on) do
    stay_length_days = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, stay_length_days)
    revision = group.revision + 1

    group
    |> Group.changeset(%{
      arrival_on: new_arrival_on,
      departure_on: new_departure_on,
      revision: revision
    })
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
           new_departure_on: Date.to_iso8601(updated_group.departure_on),
           revision: updated_group.revision
         }}

      {:error, _changeset} ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp cancel_group(operation, group, occurred_on) do
    {refunded_cents, retained_cents} = cancellation_settlement(group, occurred_on)
    revision = group.revision + 1

    group
    |> Group.changeset(%{
      status: @cancelled,
      revision: revision,
      refunded_cents: group.refunded_cents + refunded_cents,
      retained_cents: group.retained_cents + retained_cents
    })
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           refunded_cents: refunded_cents,
           retained_cents: retained_cents,
           revision: updated_group.revision
         }}

      {:error, _changeset} ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp cancellation_settlement(%Group{rate_plan: @flexible} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp cancellation_settlement(%Group{rate_plan: @advance_purchase} = group, _occurred_on) do
    {0, group.deposit_paid_cents}
  end

  defp insert_rooms(operation, group, rooms) do
    Enum.each(rooms, fn room_attrs ->
      attrs = Map.put(room_attrs, :group_pk_id, group.id)

      case Repo.insert(Room.changeset(%Room{}, attrs)) do
        {:ok, _room} -> :ok
        {:error, _changeset} -> Repo.rollback(reject(operation["operation_id"], :invalid_rooms))
      end
    end)
  end

  defp operation_transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp fetch_addressed_group(operation) do
    with {:ok, group_id} <- fetch_string(operation, "group_id") do
      case get_group(group_id) do
        nil -> {:error, reject(operation["operation_id"], :group_not_found)}
        group -> {:ok, group}
      end
    end
  end

  defp check_expected_revision(operation, %Group{} = group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:error,
         %{
           operation_id: operation["operation_id"],
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp require_common_operation_date(operation) do
    case fetch_operation_date(operation) do
      {:ok, _date} -> :ok
      {:error, result} -> {:error, result}
    end
  end

  defp fetch_operation_date(operation) do
    fetch_date(operation, "occurred_on", :invalid_operation)
  end

  defp fetch_date(operation, key, code) do
    case fetch_string(operation, key) do
      {:ok, value} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, reject(operation["operation_id"], code)}
        end

      {:error, result} ->
        {:error, result}
    end
  end

  defp fetch_string(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp fetch_rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      _ -> {:error, reject(operation["operation_id"], :invalid_rate_plan)}
    end
  end

  defp build_rooms(operation, arrival_on, departure_on, rate_plan) do
    with {:ok, rooms} when is_list(rooms) and rooms != [] <- Map.fetch(operation, "rooms"),
         true <- unique_room_ids?(rooms),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, built_rooms} ->
        case build_room(room, position, nights, rate_plan) do
          {:ok, built_room} -> {:cont, {:ok, [built_room | built_rooms]}}
          :error -> {:halt, {:error, reject(operation["operation_id"], :invalid_rooms)}}
        end
      end)
      |> case do
        {:ok, built_rooms} -> {:ok, Enum.reverse(built_rooms)}
        error -> error
      end
    else
      _ -> {:error, reject(operation["operation_id"], :invalid_rooms)}
    end
  end

  defp build_room(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position,
         nights,
         rate_plan
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    lodging_amount_cents = nightly_rate_cents * nights

    {:ok,
     %{
       room_id: room_id,
       position: position,
       nightly_rate_cents: nightly_rate_cents,
       lodging_amount_cents: lodging_amount_cents,
       deposit_due_cents: room_deposit_due_cents(lodging_amount_cents, rate_plan)
     }}
  end

  defp build_room(_room, _position, _nights, _rate_plan), do: :error

  defp unique_room_ids?(rooms) do
    room_ids =
      Enum.map(rooms, fn
        %{"room_id" => room_id} when is_binary(room_id) and room_id != "" -> room_id
        _room -> nil
      end)

    Enum.all?(room_ids, &is_binary/1) and Enum.uniq(room_ids) == room_ids
  end

  defp room_deposit_due_cents(lodging_amount_cents, @flexible) do
    round_half_up(lodging_amount_cents, 20, 100)
  end

  defp room_deposit_due_cents(lodging_amount_cents, @advance_purchase), do: lodging_amount_cents

  defp round_half_up(amount, numerator, denominator) do
    div(amount * numerator + div(denominator, 2), denominator)
  end

  defp ensure_group_available(operation, group_id) do
    case Repo.exists?(from(group in Group, where: group.group_id == ^group_id)) do
      true -> {:error, reject(operation["operation_id"], :group_already_exists)}
      false -> :ok
    end
  end

  defp ensure_valid_stay(operation, arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) > 0 do
      :ok
    else
      {:error, reject(operation["operation_id"], :invalid_stay)}
    end
  end

  defp ensure_active(_operation, %Group{status: @active}), do: :ok

  defp ensure_active(operation, _group),
    do: {:error, reject(operation["operation_id"], :group_not_active)}

  defp fetch_payment_amount_value(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} ->
        {:ok, amount_cents}

      :error ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp ensure_usable_payment_amount(_operation, amount_cents)
       when is_integer(amount_cents) and amount_cents > 0 do
    :ok
  end

  defp ensure_usable_payment_amount(operation, _amount_cents) do
    {:error, reject(operation["operation_id"], :invalid_amount)}
  end

  defp ensure_payment_within_outstanding(operation, group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      {:error, reject(operation["operation_id"], :payment_exceeds_outstanding)}
    end
  end

  defp ensure_new_arrival_after_operation(operation, new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, reject(operation["operation_id"], :invalid_stay)}
    end
  end

  defp outstanding_deposit_cents(%Group{status: @cancelled}), do: 0

  defp outstanding_deposit_cents(%Group{} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp reject(operation_id, code) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: to_string(code)
    }
  end

  defp operation_id_from(%{"operation_id" => operation_id}), do: operation_id
  defp operation_id_from(_operation), do: nil

  defp preload_rooms(queryable) do
    from(group in queryable,
      preload: [rooms: ^from(room in Room, order_by: room.position)]
    )
  end

  defp has_unique_group_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_message, options}} -> options[:constraint] == :unique
      _error -> false
    end)
  end
end
