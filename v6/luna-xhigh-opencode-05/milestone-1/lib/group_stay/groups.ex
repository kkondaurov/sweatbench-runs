defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  @doc """
  Applies a partner batch in order. Each operation has its own transaction so a
  rejected operation cannot undo an earlier operation in the same batch.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, serialize_group(load_rooms(group))}
    end
  end

  def get_group(_group_id), do: :not_found

  def ledger do
    %{
      "cash_held_cents" => sum_groups(@active, :deposit_paid_cents),
      "cash_refunded_cents" => sum_groups(@cancelled, :refunded_cents),
      "cash_retained_cents" => sum_groups(@cancelled, :retained_cents)
    }
  end

  defp process_operation(operation) do
    case Repo.transaction(
           fn ->
             case execute_operation(operation) do
               {:rejected, result} -> Repo.rollback({:rejected, result})
               applied -> applied
             end
           end,
           mode: :immediate
         ) do
      {:ok, {:applied, result}} -> result
      {:error, {:rejected, result}} -> result
    end
  end

  defp execute_operation(operation) when is_map(operation) do
    case field(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp execute_operation(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         :ok <- ensure_group_missing(group_id),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_stay"),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on"), "invalid_stay"),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on"), "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(field(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
      stay_length = Date.diff(departure_on, arrival_on)
      lodging_total_cents = calculate_lodging(rooms, stay_length)
      deposit_due_cents = calculate_deposit(rooms, rate_plan, stay_length)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
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

      case insert_group(attrs, rooms) do
        :ok ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           })}

        :already_exists ->
          reject(operation, "group_already_exists")

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, _occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- validate_payment_amount(amount_cents, group) do
      updated_group = %{
        group
        | deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          revision: group.revision + 1
      }

      case update_group(group, %{
             deposit_paid_cents: updated_group.deposit_paid_cents,
             revision: updated_group.revision
           }) do
        {:ok, _group} ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "amount_cents" => amount_cents,
             "outstanding_deposit_cents" => outstanding(updated_group),
             "revision" => updated_group.revision
           })}

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp reschedule_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_stay"),
         {:ok, new_arrival_on} <-
           parse_date(field(operation, "new_arrival_on"), "invalid_stay"),
         :ok <- validate_rescheduled_stay(occurred_on, new_arrival_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      updated_group = %{
        group
        | arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
      }

      case update_group(group, %{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: updated_group.revision
           }) do
        {:ok, _group} ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "new_arrival_on" => Date.to_iso8601(new_arrival_on),
             "new_departure_on" => Date.to_iso8601(new_departure_on),
             "revision" => updated_group.revision
           })}

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancel_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation") do
      {refunded_cents, retained_cents} = cancellation_totals(group, occurred_on)

      updated_group = %{
        group
        | status: @cancelled,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          revision: group.revision + 1
      }

      case update_group(group, %{
             status: @cancelled,
             refunded_cents: refunded_cents,
             retained_cents: retained_cents,
             revision: updated_group.revision
           }) do
        {:ok, _group} ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "refunded_cents" => refunded_cents,
             "retained_cents" => retained_cents,
             "revision" => updated_group.revision
           })}

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp validate_common(operation) do
    if valid_identifier?(field(operation, "operation_id")) and
         field(operation, "occurred_on") != nil do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, key) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp existing_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp ensure_group_missing(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :ok
      _group -> {:error, "group_already_exists"}
    end
  end

  defp check_revision(operation, group) do
    case field_with_presence(operation, "expected_revision") do
      :absent ->
        :ok

      {:present, expected_revision} when expected_revision == group.revision ->
        :ok

      {:present, expected_revision} ->
        {:error,
         {:stale_revision,
          %{
            "operation_id" => field(operation, "operation_id"),
            "status" => "rejected",
            "code" => "stale_revision",
            "group_id" => group.group_id,
            "expected_revision" => expected_revision,
            "actual_revision" => group.revision
          }}}
    end
  end

  defp validate_active(%Group{status: @active}), do: :ok
  defp validate_active(_group), do: {:error, "group_not_active"}

  defp parse_date(value, error_code) when is_binary(value),
    do: date_result(Date.from_iso8601(value), error_code)

  defp parse_date(%Date{} = value, _error_code), do: {:ok, value}
  defp parse_date(_value, error_code), do: {:error, error_code}

  defp date_result({:ok, date}, _error_code), do: {:ok, date}
  defp date_result({:error, _reason}, error_code), do: {:error, error_code}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rescheduled_stay(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(@flexible), do: {:ok, @flexible}
  defp validate_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, valid_rooms} ->
      case validate_room(room, position) do
        {:ok, valid_room} -> {:cont, {:ok, [valid_room | valid_rooms]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, valid_rooms} ->
        valid_rooms = Enum.reverse(valid_rooms)

        if length(Enum.uniq_by(valid_rooms, & &1.room_id)) == length(valid_rooms) do
          {:ok, valid_rooms}
        else
          {:error, "invalid_rooms"}
        end

      error ->
        error
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_room(room, position) when is_map(room) do
    room_id = field(room, "room_id")
    nightly_rate_cents = field(room, "nightly_rate_cents")

    if valid_identifier?(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 do
      {:ok,
       %{
         room_id: room_id,
         nightly_rate_cents: nightly_rate_cents,
         position: position
       }}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_room(_room, _position), do: {:error, "invalid_rooms"}

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp calculate_lodging(rooms, stay_length) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + room.nightly_rate_cents * stay_length
    end)
  end

  defp calculate_deposit(rooms, @advance_purchase, stay_length) do
    calculate_lodging(rooms, stay_length)
  end

  defp calculate_deposit(rooms, @flexible, stay_length) do
    Enum.reduce(rooms, 0, fn room, total ->
      lodging_cents = room.nightly_rate_cents * stay_length
      total + round_percentage(lodging_cents, 20, 100)
    end)
  end

  defp round_percentage(amount, numerator, denominator) do
    quotient = div(amount * numerator, denominator)
    remainder = rem(amount * numerator, denominator)

    if remainder * 2 >= denominator, do: quotient + 1, else: quotient
  end

  defp insert_group(attrs, rooms) do
    changeset = Group.changeset(%Group{}, attrs)

    case Repo.insert(changeset) do
      {:ok, _group} ->
        rooms
        |> Enum.map(fn room ->
          Room.changeset(%Room{}, %{
            group_id: attrs.group_id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position
          })
        end)
        |> Enum.reduce_while(:ok, fn room_changeset, :ok ->
          case Repo.insert(room_changeset) do
            {:ok, _room} -> {:cont, :ok}
            {:error, _changeset} -> {:halt, :error}
          end
        end)

      {:error, _changeset} ->
        :already_exists
    end
  end

  defp update_group(group, changes) do
    group
    |> Group.changeset(changes)
    |> Repo.update()
  end

  defp usable_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp usable_amount(_amount_cents), do: {:error, "invalid_amount"}

  defp validate_payment_amount(amount_cents, group) do
    if amount_cents <= outstanding(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp outstanding(%Group{status: @active} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding(_group), do: 0

  defp cancellation_totals(
         %Group{rate_plan: @flexible, arrival_on: arrival_on} = group,
         occurred_on
       ) do
    if Date.diff(arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp cancellation_totals(%Group{} = group, _occurred_on), do: {0, group.deposit_paid_cents}

  defp load_rooms(group) do
    %{
      group
      | rooms:
          Repo.all(
            from room in Room, where: room.group_id == ^group.group_id, order_by: room.position
          )
    }
  end

  defp serialize_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "revision" => group.revision,
      "rooms" => Enum.map(group.rooms, &serialize_room/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  defp serialize_room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents
    }
  end

  defp sum_groups(status, field_name) do
    Repo.one(
      from group in Group,
        where: group.status == ^status,
        select: coalesce(sum(field(group, ^field_name)), 0)
    )
  end

  defp result(operation, status),
    do: %{"operation_id" => field(operation, "operation_id"), "status" => status}

  defp reject(operation, code) when is_binary(code) do
    {:rejected, result(operation, "rejected") |> Map.put("code", code)}
  end

  defp reject(_operation, {:stale_revision, stale_result}), do: {:rejected, stale_result}

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp field(_map, _key), do: nil

  defp field_with_presence(map, key) when is_map(map) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, atom_key) -> {:present, Map.get(map, atom_key)}
      true -> :absent
    end
  end

  defp field_with_presence(_map, _key), do: :absent
end
