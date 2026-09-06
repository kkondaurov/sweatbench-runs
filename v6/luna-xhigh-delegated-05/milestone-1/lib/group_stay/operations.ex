defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Ledger.Total
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  @type result :: map()

  @spec submit_batch(list()) :: [result()]
  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @spec get_group(String.t()) :: map() | nil
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group.id,
              order_by: [asc: room.position]
          )

        group_response(group, rooms)
    end
  end

  @spec get_ledger() :: map()
  def get_ledger do
    ledger = Repo.get!(Total, 1)

    %{
      cash_held_cents: ledger.cash_held_cents,
      cash_refunded_cents: ledger.cash_refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents
    }
  end

  defp submit_operation(operation) do
    Repo.transaction(
      fn ->
        case apply_operation(operation) do
          {:ok, result} -> result
          {:error, result} -> Repo.rollback(result)
        end
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, result}) when is_map(result), do: result

  defp apply_operation(operation) when not is_map(operation) do
    {:error, reject(nil, "invalid_operation")}
  end

  defp apply_operation(operation) do
    operation_id = field(operation, "operation_id")

    with {:ok, type} <- required_type(operation),
         :ok <- validate_operation_id(operation_id) do
      case type do
        "open_group" ->
          open_group(operation, operation_id)

        type when type in ["record_cash_payment", "reschedule_group", "cancel_group"] ->
          apply_existing_group_operation(operation, operation_id, type)

        _ ->
          {:error, reject(operation_id, "invalid_operation")}
      end
    else
      _ -> {:error, reject(operation_id, "invalid_operation")}
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         nil <- Repo.get_by(Group, group_id: group_id) do
      with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
           {:ok, guest_id} <- required_identifier(operation, "guest_id"),
           {:ok, property_id} <- required_identifier(operation, "property_id"),
           {:ok, arrival_on} <- required_date(operation, "arrival_on"),
           {:ok, departure_on} <- required_date(operation, "departure_on"),
           :ok <- validate_stay(arrival_on, departure_on),
           {:ok, rate_plan} <- validate_rate_plan(field(operation, "rate_plan")),
           {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
        nights = Date.diff(departure_on, arrival_on)
        rooms = Enum.map(rooms, &Map.put(&1, :lodging_cents, &1.nightly_rate_cents * nights))
        lodging_total_cents = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
        deposit_due_cents = deposit_due(rooms, rate_plan)

        group = %Group{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: @active,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          revision: 1
        }

        case Repo.insert(group) do
          {:ok, group} ->
            Repo.insert_all(
              Room,
              Enum.map(rooms, fn room ->
                %{
                  group_id: group.id,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents,
                  position: room.position
                }
              end)
            )

            {:ok,
             applied(operation_id,
               group_id: group_id,
               deposit_due_cents: deposit_due_cents,
               revision: 1
             )}

          {:error, _changeset} ->
            {:error, reject(operation_id, "group_already_exists", group_id: group_id)}
        end
      else
        {:error, code} -> {:error, reject(operation_id, code, group_id: group_id)}
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code)}

      _group ->
        {:error,
         reject(operation_id, "group_already_exists", group_id: field(operation, "group_id"))}
    end
  end

  defp apply_existing_group_operation(operation, operation_id, type) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         group when not is_nil(group) <- Repo.get_by(Group, group_id: group_id),
         :ok <- check_expected_revision(operation, group) do
      case type do
        "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
        "reschedule_group" -> reschedule_group(operation, operation_id, group)
        "cancel_group" -> cancel_group(operation, operation_id, group)
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code, group_id: field(operation, "group_id"))}

      nil ->
        {:error, reject(operation_id, "group_not_found", group_id: field(operation, "group_id"))}
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         {:ok, outstanding} <- payment_outstanding(group, amount_cents) do
      update_group(group, deposit_paid_cents: group.deposit_paid_cents + amount_cents)
      update_ledger(cash_held_cents: amount_cents)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding - amount_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} ->
        {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- validate_reschedule(occurred_on, new_arrival_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      update_group(group,
        arrival_on: new_arrival_on,
        departure_on: new_departure_on
      )

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         new_arrival_on: new_arrival_on,
         new_departure_on: new_departure_on,
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on") do
      refundable = group.rate_plan == @flexible and Date.diff(group.arrival_on, occurred_on) >= 14
      paid = group.deposit_paid_cents

      update_group(group, status: @cancelled)

      if paid > 0 do
        if refundable do
          update_ledger(cash_held_cents: -paid, cash_refunded_cents: paid)
        else
          update_ledger(cash_held_cents: -paid, cash_retained_cents: paid)
        end
      end

      {refunded_cents, retained_cents} =
        if refundable, do: {paid, 0}, else: {0, paid}

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         refunded_cents: refunded_cents,
         retained_cents: retained_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp update_group(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp update_ledger(deltas) do
    ledger = Repo.get!(Total, 1)

    attrs =
      Enum.reduce(deltas, %{}, fn {field, delta}, acc ->
        Map.put(acc, field, Map.fetch!(ledger, field) + delta)
      end)

    ledger
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp group_response(group, rooms) do
    outstanding =
      if group.status == @active,
        do: group.deposit_due_cents - group.deposit_paid_cents,
        else: 0

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
      outstanding_deposit_cents: outstanding
    }
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, acc} ->
      if Enum.any?(acc, &(&1.room_id == field(room, "room_id"))) do
        {:halt, {:error, "invalid_rooms"}}
      else
        with {:ok, room_id} <- required_identifier(room, "room_id"),
             {:ok, nightly_rate_cents} <- positive_amount(field(room, "nightly_rate_cents")) do
          {:cont,
           {:ok,
            [
              %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                lodging_cents: 0
              }
              | acc
            ]}}
        else
          {:error, _} -> {:halt, {:error, "invalid_rooms"}}
        end
      end
    end)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      error -> error
    end
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp deposit_due(rooms, @flexible) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + round_half_up(room.lodging_cents * 20, 100)
    end)
  end

  defp deposit_due(rooms, @advance_purchase), do: Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))

  defp required_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, key) when is_map(operation) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(_, _), do: {:error, "invalid_operation"}

  defp required_date(operation, key) do
    value = field(operation, key)

    case value do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_stay"}
        end

      _ ->
        if has_field?(operation, key),
          do: {:error, "invalid_stay"},
          else: {:error, "invalid_operation"}
    end
  end

  defp validate_stay(arrival_on, departure_on),
    do: if(Date.after?(departure_on, arrival_on), do: :ok, else: {:error, "invalid_stay"})

  defp validate_reschedule(occurred_on, new_arrival_on) do
    if Date.after?(new_arrival_on, occurred_on), do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(@flexible), do: {:ok, @flexible}
  defp validate_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp usable_amount(amount) do
    case positive_amount(amount) do
      {:ok, amount} -> {:ok, amount}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp positive_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp positive_amount(_), do: {:error, "invalid_amount"}

  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp payment_outstanding(group, amount_cents) do
    outstanding = outstanding_deposit(group)

    if amount_cents <= outstanding,
      do: {:ok, outstanding},
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp ensure_active(%Group{status: @active}), do: :ok
  defp ensure_active(_), do: {:error, "group_not_active"}

  defp check_expected_revision(operation, group) do
    if has_field?(operation, "expected_revision") and
         field(operation, "expected_revision") !== group.revision do
      {:error,
       {:stale_revision,
        [
          expected_revision: field(operation, "expected_revision"),
          actual_revision: group.revision
        ]}}
    else
      :ok
    end
  end

  defp reject(operation_id, code, fields \\ [])

  defp reject(operation_id, {:stale_revision, fields}, base_fields) do
    reject(operation_id, "stale_revision", Keyword.merge(base_fields, fields))
  end

  defp reject(operation_id, code, fields) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))

  defp validate_operation_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_operation_id(_), do: {:error, "invalid_operation"}

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp field(_, _), do: nil

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp has_field?(_, _), do: false

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)
end
