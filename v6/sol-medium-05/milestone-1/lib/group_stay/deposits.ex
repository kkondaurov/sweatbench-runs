defmodule GroupStay.Deposits do
  @moduledoc """
  Applies partner operations and exposes the group-deposit read models.

  Every operation is committed in its own transaction. This is intentional: a
  batch is ordered, but one rejected operation must not undo successful work
  before it or prevent work after it.
  """

  import Ecto.Query

  alias GroupStay.Deposits.{Group, Room}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @group_operation_types ~w(record_cash_payment reschedule_group cancel_group)
  @max_sqlite_integer 9_223_372_036_854_775_807

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_group_id), do: nil

  def group_data(%Group{} = group) do
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
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  def ledger do
    sums =
      Repo.one(
        from g in Group,
          select: %{
            held:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.deposit_paid_cents
                  )
                ),
                0
              ),
            refunded: coalesce(sum(g.cash_refunded_cents), 0),
            retained: coalesce(sum(g.cash_retained_cents), 0)
          }
      )

    %{
      cash_held_cents: sums.held,
      cash_refunded_cents: sums.refunded,
      cash_retained_cents: sums.retained
    }
  end

  defp apply_operation(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp apply_operation(operation) do
    operation = stringify_keys(operation)

    case operation do
      %{"operation_id" => operation_id, "type" => type}
      when is_binary(operation_id) and operation_id != "" and is_binary(type) ->
        dispatch(operation, type)

      _ ->
        rejected(Map.get(operation, "operation_id"), "invalid_operation")
    end
  end

  defp dispatch(operation, "open_group"), do: transact(operation, &open_group/1)

  defp dispatch(operation, type) when type in @group_operation_types do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      transact(operation, fn op -> apply_to_existing_group(op, type, group_id) end)
    else
      :error -> rejected(operation["operation_id"], "invalid_operation")
    end
  end

  defp dispatch(operation, _type),
    do: rejected(operation["operation_id"], "invalid_operation")

  defp transact(operation, function) do
    transaction = fn ->
      case function.(operation) do
        {:ok, result} -> result
        {:error, result} -> Repo.rollback(result)
      end
    end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, result} -> result
      {:error, :retry} -> transact(operation, function)
      {:error, result} -> result
    end
  end

  defp open_group(operation) do
    with :ok <-
           require_keys(
             operation,
             ~w(occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         true <- identifiers_valid?(operation, ~w(group_id guest_id property_id)) do
      if Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) do
        {:error, rejected(operation, "group_already_exists", operation["group_id"])}
      else
        validate_and_insert_group(operation)
      end
    else
      _ -> {:error, rejected(operation["operation_id"], "invalid_operation")}
    end
  end

  defp validate_and_insert_group(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt do
      validate_group_rate_and_rooms(operation, booked_on, arrival_on, departure_on)
    else
      _ -> {:error, rejected(operation, "invalid_stay", operation["group_id"])}
    end
  end

  defp validate_group_rate_and_rooms(operation, booked_on, arrival_on, departure_on) do
    rate_plan = operation["rate_plan"]
    nights = Date.diff(departure_on, arrival_on)

    cond do
      rate_plan not in @rate_plans ->
        {:error, rejected(operation, "invalid_rate_plan", operation["group_id"])}

      not valid_rooms?(operation["rooms"], nights) ->
        {:error, rejected(operation, "invalid_rooms", operation["group_id"])}

      true ->
        insert_group(operation, booked_on, arrival_on, departure_on)
    end
  end

  defp insert_group(operation, booked_on, arrival_on, departure_on) do
    nights = Date.diff(departure_on, arrival_on)

    room_amounts =
      Enum.map(operation["rooms"], fn room -> nights * room["nightly_rate_cents"] end)

    lodging_total = Enum.sum(room_amounts)

    deposit_due =
      case operation["rate_plan"] do
        "flexible" -> room_amounts |> Enum.map(&div(&1 * 20 + 50, 100)) |> Enum.sum()
        "advance_purchase" -> lodging_total
      end

    attrs = %{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      revision: 1,
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      status: "active",
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0
    }

    case Repo.insert(Group.changeset(%Group{}, attrs)) do
      {:ok, group} ->
        insert_rooms!(group, operation["rooms"])

        {:ok,
         applied(operation, %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         })}

      {:error, _changeset} ->
        {:error, rejected(operation, "group_already_exists", operation["group_id"])}
    end
  end

  defp insert_rooms!(group, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          group_id: group.group_id,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          position: position,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, nil} = Repo.insert_all(Room, entries)
  end

  defp apply_to_existing_group(operation, type, group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error, rejected(operation, "group_not_found", group_id)}

      group ->
        with :ok <- validate_expected_revision(operation, group),
             :ok <- require_operation_fields(operation, type) do
          apply_group_operation(operation, type, group)
        else
          {:error, :stale_revision} ->
            {:error, stale_rejection(operation, group)}

          {:error, :invalid_operation} ->
            {:error, rejected(operation, "invalid_operation", group_id)}
        end
    end
  end

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, revision} when is_integer(revision) ->
        if revision == group.revision, do: :ok, else: {:error, :stale_revision}

      {:ok, _invalid} ->
        {:error, :invalid_operation}
    end
  end

  defp require_operation_fields(operation, "record_cash_payment") do
    if Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents"),
      do: :ok,
      else: {:error, :invalid_operation}
  end

  defp require_operation_fields(operation, "reschedule_group") do
    if Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "new_arrival_on"),
      do: :ok,
      else: {:error, :invalid_operation}
  end

  defp require_operation_fields(operation, "cancel_group") do
    if Map.has_key?(operation, "occurred_on"), do: :ok, else: {:error, :invalid_operation}
  end

  defp apply_group_operation(operation, _type, %{status: status} = group)
       when status != "active" do
    {:error, rejected(operation, "group_not_active", group.group_id)}
  end

  defp apply_group_operation(operation, "record_cash_payment", group) do
    amount = operation["amount_cents"]

    cond do
      not valid_date?(operation["occurred_on"]) ->
        {:error, rejected(operation, "invalid_operation", group.group_id)}

      not (is_integer(amount) and amount > 0) ->
        {:error, rejected(operation, "invalid_amount", group.group_id)}

      amount > outstanding_deposit(group) ->
        {:error, rejected(operation, "payment_exceeds_outstanding", group.group_id)}

      true ->
        update_group(
          operation,
          group,
          %{deposit_paid_cents: group.deposit_paid_cents + amount},
          fn updated ->
            %{
              group_id: updated.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: outstanding_deposit(updated),
              revision: updated.revision
            }
          end
        )
    end
  end

  defp apply_group_operation(operation, "reschedule_group", group) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      update_group(
        operation,
        group,
        %{arrival_on: new_arrival_on, departure_on: new_departure_on},
        fn updated ->
          %{
            group_id: updated.group_id,
            new_arrival_on: updated.arrival_on,
            new_departure_on: updated.departure_on,
            revision: updated.revision
          }
        end
      )
    else
      _ -> {:error, rejected(operation, "invalid_stay", group.group_id)}
    end
  end

  defp apply_group_operation(operation, "cancel_group", group) do
    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} ->
        refundable =
          group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

        refunded = if refundable, do: group.deposit_paid_cents, else: 0
        retained = if refundable, do: 0, else: group.deposit_paid_cents

        update_group(
          operation,
          group,
          %{
            status: "cancelled",
            cash_refunded_cents: refunded,
            cash_retained_cents: retained
          },
          fn updated ->
            %{
              group_id: updated.group_id,
              refunded_cents: refunded,
              retained_cents: retained,
              revision: updated.revision
            }
          end
        )

      :error ->
        {:error, rejected(operation, "invalid_operation", group.group_id)}
    end
  end

  defp update_group(operation, group, attrs, result_fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(g in Group, where: g.group_id == ^group.group_id and g.revision == ^group.revision),
        set: Keyword.put(Map.to_list(attrs), :updated_at, now),
        inc: [revision: 1]
      )

    if count == 1 do
      updated = Repo.get!(Group, group.group_id)
      {:ok, applied(operation, result_fields.(updated))}
    else
      if Map.has_key?(operation, "expected_revision") do
        actual = Repo.get!(Group, group.group_id)
        {:error, stale_rejection(operation, actual)}
      else
        {:error, :retry}
      end
    end
  end

  defp outstanding_deposit(%{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit(_group), do: 0

  defp valid_rooms?(rooms, nights) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 and
               rate <= @max_sqlite_integer ->
          true

        _ ->
          false
      end)

    if valid do
      room_ids = Enum.map(rooms, &Map.fetch!(&1, "room_id"))
      room_amounts = Enum.map(rooms, &(Map.fetch!(&1, "nightly_rate_cents") * nights))

      Enum.uniq(room_ids) == room_ids and Enum.sum(room_amounts) <= @max_sqlite_integer
    else
      false
    end
  end

  defp valid_rooms?(_rooms, _nights), do: false

  defp identifiers_valid?(operation, keys) do
    Enum.all?(keys, fn key -> is_binary(operation[key]) and operation[key] != "" end)
  end

  defp required_identifier(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp require_keys(operation, keys) do
    if Enum.all?(keys, &Map.has_key?(operation, &1)), do: :ok, else: :error
  end

  defp valid_date?(value), do: match?({:ok, _date}, parse_date(value))

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp applied(operation, fields) do
    fields
    |> Map.merge(%{operation_id: operation["operation_id"], status: "applied"})
  end

  defp stale_rejection(operation, group) do
    %{
      operation_id: operation["operation_id"],
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    }
  end

  defp rejected(operation, code, group_id) when is_map(operation) do
    rejected(operation["operation_id"], code)
    |> Map.put(:group_id, group_id)
  end

  defp rejected(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: code}
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
