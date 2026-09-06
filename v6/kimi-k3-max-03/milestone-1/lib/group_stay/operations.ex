defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and reports one result per operation.

  Every operation runs in its own transaction: rejections leave the database
  exactly as they found it, while applied operations commit and are visible to
  later operations in the same batch.
  """

  alias GroupStay.{Groups, Repo}
  alias GroupStay.Groups.Group
  alias GroupStay.Money

  @deposit_percent 20
  @refundable_window_days 14
  @addressed_types ~w(record_cash_payment reschedule_group cancel_group)

  @doc """
  Applies a list of operations sequentially, returning one result per
  operation in the same order.
  """
  def apply_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &apply_operation/1)}
  end

  @doc """
  Applies a single operation. Returns a result map whose `status` is
  `"applied"` or `"rejected"`.
  """
  def apply_operation(operation) when is_map(operation) do
    result =
      Repo.transaction(fn ->
        case dispatch(operation) do
          {:ok, result} -> result
          {:error, result} -> Repo.rollback(result)
        end
      end)

    case result do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  def apply_operation(_other) do
    reject_result(%{}, "invalid_operation")
  end

  defp dispatch(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, type} <- required_string(operation, "type"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      apply_typed(operation, operation_id, type, occurred_on)
    else
      :error -> reject(operation, "invalid_operation")
    end
  end

  defp apply_typed(operation, operation_id, "open_group", occurred_on) do
    open_group(operation, operation_id, occurred_on)
  end

  defp apply_typed(operation, operation_id, type, occurred_on)
       when type in @addressed_types do
    with_addressed_group(operation, operation_id, type, occurred_on)
  end

  defp apply_typed(operation, _operation_id, _unknown_type, _occurred_on) do
    {:error, reject_result(operation, "invalid_operation")}
  end

  ## open_group

  defp open_group(operation, operation_id, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         :ok <- group_missing?(Groups.get_group(group_id)),
         {:ok, rate_plan} <- valid_rate_plan(operation["rate_plan"]),
         {:ok, arrival_on, departure_on} <- valid_stay(operation),
         {:ok, rooms} <- valid_rooms(operation["rooms"]) do
      create_group(operation, %{
        operation_id: operation_id,
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        rate_plan: rate_plan,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rooms: rooms
      })
    else
      :error -> reject(operation, "invalid_operation", operation_id)
      {:reject, code} -> reject(operation, code, operation_id)
    end
  end

  defp create_group(operation, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms_attrs =
      attrs.rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"]
        }
      end)

    lodging_total_cents =
      Enum.sum(for room <- attrs.rooms, do: nights * room["nightly_rate_cents"])

    deposit_due_cents =
      case attrs.rate_plan do
        "flexible" ->
          attrs.rooms
          |> Enum.map(&Money.percent_of(nights * &1["nightly_rate_cents"], @deposit_percent))
          |> Enum.sum()

        "advance_purchase" ->
          lodging_total_cents
      end

    changeset =
      Group.create_changeset(%{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        rate_plan: attrs.rate_plan,
        status: "active",
        booked_on: attrs.booked_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        rooms: rooms_attrs
      })

    case Repo.insert(changeset) do
      {:ok, group} ->
        {:ok,
         apply_result(operation, %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         })}

      {:error, _changeset} ->
        {:error, reject_result(operation, "invalid_operation")}
    end
  end

  ## operations addressed to an existing group

  defp with_addressed_group(operation, operation_id, type, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id") do
      case Groups.get_group(group_id) do
        nil ->
          reject(operation, "group_not_found", operation_id)

        group ->
          case revision_ok?(operation, group) do
            :ok ->
              apply_addressed(operation, operation_id, type, occurred_on, group)

            {:error, stale} ->
              reject(operation, "stale_revision", operation_id, stale)
          end
      end
    else
      :error -> reject(operation, "invalid_operation", operation_id)
    end
  end

  defp revision_ok?(operation, group) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:error,
         %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}
    end
  end

  defp apply_addressed(operation, op_id, "record_cash_payment", _on, group) do
    record_payment(operation, op_id, group)
  end

  defp apply_addressed(operation, op_id, "reschedule_group", occurred_on, group) do
    reschedule(operation, op_id, occurred_on, group)
  end

  defp apply_addressed(operation, op_id, "cancel_group", occurred_on, group) do
    cancel(operation, op_id, occurred_on, group)
  end

  ## record_cash_payment

  defp record_payment(operation, operation_id, group) do
    cond do
      group.status != "active" ->
        reject(operation, "group_not_active", operation_id)

      not usable_amount?(operation["amount_cents"]) ->
        reject(operation, "invalid_amount", operation_id)

      operation["amount_cents"] > outstanding(group) ->
        reject(operation, "payment_exceeds_outstanding", operation_id)

      true ->
        amount = operation["amount_cents"]

        changeset =
          Group.changeset(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            {:ok,
             apply_result(operation, %{
               group_id: updated.group_id,
               amount_cents: amount,
               outstanding_deposit_cents: outstanding(updated),
               revision: updated.revision
             })}

          {:error, _changeset} ->
            {:error, reject_result(operation, "invalid_operation")}
        end
    end
  end

  ## reschedule_group

  defp reschedule(operation, operation_id, occurred_on, group) do
    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      if group.status == "active" do
        shift_days = Date.diff(new_arrival, group.arrival_on)
        new_departure = Date.add(group.departure_on, shift_days)

        changeset =
          Group.changeset(group, %{
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            {:ok,
             apply_result(operation, %{
               group_id: updated.group_id,
               new_arrival_on: updated.arrival_on,
               new_departure_on: updated.departure_on,
               revision: updated.revision
             })}

          {:error, _changeset} ->
            {:error, reject_result(operation, "invalid_operation")}
        end
      else
        reject(operation, "group_not_active", operation_id)
      end
    else
      _ -> reject(operation, "invalid_stay", operation_id)
    end
  end

  ## cancel_group

  defp cancel(operation, operation_id, occurred_on, group) do
    if group.status == "active" do
      refundable? =
        group.rate_plan == "flexible" and
          Date.diff(group.arrival_on, occurred_on) >= @refundable_window_days

      {refunded_cents, retained_cents} =
        if refundable?, do: {group.deposit_paid_cents, 0}, else: {0, group.deposit_paid_cents}

      changeset =
        Group.changeset(group, %{
          status: "cancelled",
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          revision: group.revision + 1
        })

      case Repo.update(changeset) do
        {:ok, updated} ->
          {:ok,
           apply_result(operation, %{
             group_id: updated.group_id,
             refunded_cents: updated.refunded_cents,
             retained_cents: updated.retained_cents,
             revision: updated.revision
           })}

        {:error, _changeset} ->
          {:error, reject_result(operation, "invalid_operation")}
      end
    else
      reject(operation, "group_not_active", operation_id)
    end
  end

  ## validation helpers

  defp group_missing?(nil), do: :ok
  defp group_missing?(_group), do: {:reject, "group_already_exists"}

  defp valid_rate_plan(rate_plan) when rate_plan in ~w(flexible advance_purchase) do
    {:ok, rate_plan}
  end

  defp valid_rate_plan(_rate_plan), do: {:reject, "invalid_rate_plan"}

  defp valid_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.diff(departure_on, arrival_on) >= 1 do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:reject, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &usable_room?/1) and unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      {:reject, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:reject, "invalid_rooms"}

  defp usable_room?(room) when is_map(room) do
    is_binary(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] > 0
  end

  defp usable_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) == length(Enum.uniq(ids))
  end

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp required_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_value), do: :error

  ## result helpers

  defp apply_result(operation, fields) do
    %{status: "applied"}
    |> put_optional(:operation_id, operation["operation_id"])
    |> Map.merge(fields)
  end

  defp reject(operation, code, operation_id \\ nil, extra \\ %{}) do
    {:error, reject_result(operation, code, operation_id, extra)}
  end

  defp reject_result(operation, code, operation_id \\ nil, extra \\ %{}) do
    %{status: "rejected", code: code}
    |> put_optional(:operation_id, operation_id)
    |> Map.merge(extra)
    |> put_optional_group(operation)
  end

  defp put_optional_group(result, operation) do
    put_optional(result, :group_id, operation["group_id"])
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
