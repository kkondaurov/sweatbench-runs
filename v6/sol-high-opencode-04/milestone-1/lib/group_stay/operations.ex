defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{Group, Repo}

  @max_sqlite_integer 9_223_372_036_854_775_807
  @rate_plans ["flexible", "advance_purchase"]

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_group_id), do: nil

  def present_group(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  def ledger do
    from(g in Group,
      select: {g.status, g.deposit_paid_cents, g.refunded_cents, g.retained_cents}
    )
    |> Repo.all()
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn {status, paid, refunded, retained}, totals ->
        %{
          cash_held_cents: totals.cash_held_cents + if(status == "active", do: paid, else: 0),
          cash_refunded_cents: totals.cash_refunded_cents + refunded,
          cash_retained_cents: totals.cash_retained_cents + retained
        }
      end
    )
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    with true <- valid_identifier?(operation_id),
         type when is_binary(type) <- Map.get(operation, "type"),
         {:ok, occurred_on} <- parse_common_date(operation) do
      process_type(type, operation, operation_id, occurred_on)
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_type("open_group", operation, operation_id, occurred_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      open_group(operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type(type, operation, operation_id, occurred_on)
       when type in ["record_cash_payment", "reschedule_group", "cancel_group"] do
    required =
      case type do
        "record_cash_payment" -> ["group_id", "amount_cents"]
        "reschedule_group" -> ["group_id", "new_arrival_on"]
        "cancel_group" -> ["group_id"]
      end

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) do
      update_group(type, operation, operation_id, occurred_on)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_type(_type, _operation, operation_id, _occurred_on) do
    rejected(operation_id, "invalid_operation")
  end

  defp open_group(operation, operation_id, occurred_on) do
    group_id = operation["group_id"]

    Repo.transaction(
      fn ->
        if Repo.get_by(Group, group_id: group_id) do
          rejected(operation_id, "group_already_exists", group_id: group_id)
        else
          with {:ok, arrival_on, departure_on, nights} <- validate_stay(operation),
               {:ok, rooms} <- validate_rooms(operation["rooms"]),
               {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
               {:ok, lodging_total, deposit_due} <- calculate_totals(rooms, nights, rate_plan) do
            attrs = %{
              group_id: group_id,
              guest_id: operation["guest_id"],
              property_id: operation["property_id"],
              booked_on: occurred_on,
              arrival_on: arrival_on,
              departure_on: departure_on,
              rate_plan: rate_plan,
              status: "active",
              revision: 1,
              lodging_total_cents: lodging_total,
              deposit_due_cents: deposit_due,
              rooms: rooms
            }

            case %Group{} |> Group.create_changeset(attrs) |> Repo.insert() do
              {:ok, _group} ->
                applied(operation_id,
                  group_id: group_id,
                  deposit_due_cents: deposit_due,
                  revision: 1
                )

              {:error, changeset} ->
                if Keyword.has_key?(changeset.errors, :group_id) do
                  rejected(operation_id, "group_already_exists", group_id: group_id)
                else
                  Repo.rollback(:invalid_operation)
                end
            end
          else
            {:error, code} -> rejected(operation_id, code, group_id: group_id)
          end
        end
      end,
      mode: :immediate
    )
    |> transaction_result(operation_id)
  end

  defp update_group(type, operation, operation_id, occurred_on) do
    group_id = operation["group_id"]

    Repo.transaction(
      fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            rejected(operation_id, "group_not_found", group_id: group_id)

          group ->
            with :ok <- validate_revision(group, operation, operation_id),
                 :ok <- validate_active(group, operation_id),
                 {:ok, updates, fields} <- prepare_update(type, group, operation, occurred_on) do
              apply_update(group, updates, operation_id, fields, operation)
            else
              {:rejected, result} -> result
              {:error, code} -> rejected(operation_id, code, group_id: group_id)
            end
        end
      end,
      mode: :immediate
    )
    |> transaction_result(operation_id)
  end

  defp prepare_update("record_cash_payment", group, operation, _occurred_on) do
    amount = operation["amount_cents"]

    cond do
      not (is_integer(amount) and amount > 0) ->
        {:error, "invalid_amount"}

      amount > outstanding(group) ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        paid = group.deposit_paid_cents + amount

        {:ok, [deposit_paid_cents: paid],
         [
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: group.deposit_due_cents - paid
         ]}
    end
  end

  defp prepare_update("reschedule_group", group, operation, occurred_on) do
    case parse_date(operation["new_arrival_on"]) do
      {:ok, new_arrival} when new_arrival > occurred_on ->
        stay_length = Date.diff(group.departure_on, group.arrival_on)
        new_departure = Date.add(new_arrival, stay_length)

        if new_departure.year <= 9999 do
          {:ok, [arrival_on: new_arrival, departure_on: new_departure],
           [
             group_id: group.group_id,
             new_arrival_on: new_arrival,
             new_departure_on: new_departure
           ]}
        else
          {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp prepare_update("cancel_group", group, _operation, occurred_on) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.deposit_paid_cents

    {:ok, [status: "cancelled", refunded_cents: refunded, retained_cents: retained],
     [group_id: group.group_id, refunded_cents: refunded, retained_cents: retained]}
  end

  defp apply_update(group, updates, operation_id, fields, operation) do
    next_revision = group.revision + 1

    {count, _} =
      from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
      |> Repo.update_all(set: Keyword.put(updates, :revision, next_revision))

    if count == 1 do
      applied(operation_id, Keyword.put(fields, :revision, next_revision))
    else
      actual_revision = Repo.get!(Group, group.id).revision

      if Map.has_key?(operation, "expected_revision") do
        stale(operation_id, group.group_id, operation["expected_revision"], actual_revision)
      else
        Repo.rollback(:retry)
      end
    end
  end

  defp validate_revision(group, operation, operation_id) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when expected == group.revision ->
        :ok

      {:ok, expected} ->
        {:rejected, stale(operation_id, group.group_id, expected, group.revision)}
    end
  end

  defp validate_active(%Group{status: "active"}, _operation_id), do: :ok

  defp validate_active(group, operation_id) do
    {:rejected, rejected(operation_id, "group_not_active", group_id: group.group_id)}
  end

  defp validate_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn room ->
        is_map(room) and valid_identifier?(room["room_id"]) and
          is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0 and
          room["nightly_rate_cents"] <= @max_sqlite_integer
      end)

    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(room_ids) == room_ids do
      {:ok,
       rooms
       |> Enum.with_index()
       |> Enum.map(fn {room, position} ->
         %{
           room_id: room["room_id"],
           nightly_rate_cents: room["nightly_rate_cents"],
           position: position
         }
       end)}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp calculate_totals(rooms, nights, rate_plan) do
    room_lodging = Enum.map(rooms, &(&1.nightly_rate_cents * nights))
    lodging_total = Enum.sum(room_lodging)

    deposit_due =
      case rate_plan do
        "flexible" -> Enum.reduce(room_lodging, 0, &(div(&1 * 20 + 50, 100) + &2))
        "advance_purchase" -> lodging_total
      end

    if lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer do
      {:ok, lodging_total, deposit_due}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp parse_common_date(operation) do
    if Map.has_key?(operation, "occurred_on") do
      parse_date(operation["occurred_on"])
    else
      :error
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp outstanding(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding(%Group{}), do: 0

  defp applied(operation_id, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id, status: "applied"})
  end

  defp rejected(operation_id, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id, status: "rejected", code: code})
  end

  defp stale(operation_id, group_id, expected, actual) do
    rejected(operation_id, "stale_revision",
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    )
  end

  defp transaction_result({:ok, result}, _operation_id), do: result

  defp transaction_result({:error, :invalid_operation}, operation_id),
    do: rejected(operation_id, "invalid_operation")

  defp transaction_result({:error, :retry}, operation_id) do
    rejected(operation_id, "invalid_operation")
  end
end
