defmodule GroupStay.Groups do
  @moduledoc """
  Applies partner operations and exposes the resulting group-deposit records.

  Every operation runs in its own immediate transaction. This makes a rejection
  atomic without coupling it to the rest of its batch, and serializes writes so
  revision checks observe the latest committed group state.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger do
    from(group in Group,
      select: %{
        cash_held_cents: coalesce(sum(group.deposit_paid_cents), 0),
        cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
        cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0)
      }
    )
    |> Repo.one!()
  end

  defp process_operation(operation) do
    transaction = fn ->
      case apply_operation(operation) do
        %{status: "rejected"} = rejection -> Repo.rollback(rejection)
        result -> result
      end
    end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} when is_map(result) -> result
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: update_group(operation, &record_cash_payment/2)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: update_group(operation, &reschedule_group/2)

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: update_group(operation, &cancel_group/2)

  defp apply_operation(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with :ok <- require_open_fields(operation),
         nil <- Repo.get(Group, operation["group_id"]),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
      deposit_due = deposit_due(rooms, nights, operation["rate_plan"])

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        status: "active",
        rooms: %{"items" => rooms},
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        revision: 1
      }

      case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
        {:ok, _group} ->
          applied(operation,
            group_id: operation["group_id"],
            deposit_due_cents: deposit_due,
            revision: 1
          )

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            reject(operation, "group_already_exists")
          else
            reject(operation, "invalid_operation")
          end
      end
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      %Group{} -> reject(operation, "group_already_exists")
      {:error, :invalid_date} -> reject(operation, "invalid_stay")
      {:error, :invalid_stay} -> reject(operation, "invalid_stay")
      {:error, :invalid_rate_plan} -> reject(operation, "invalid_rate_plan")
      {:error, :invalid_rooms} -> reject(operation, "invalid_rooms")
    end
  end

  defp update_group(operation, callback) do
    with :ok <- require_update_fields(operation),
         %Group{} = group <- Repo.get(Group, operation["group_id"]),
         :ok <- check_revision(operation, group) do
      callback.(operation, group)
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      nil -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> stale_revision(operation, group)
    end
  end

  defp record_cash_payment(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "amount_cents"]),
         :ok <- active(group),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- valid_amount(operation["amount_cents"]),
         outstanding = group.deposit_due_cents - group.deposit_paid_cents,
         :ok <- not_excessive(operation["amount_cents"], outstanding) do
      paid = group.deposit_paid_cents + operation["amount_cents"]
      revision = group.revision + 1

      {:ok, _group} = persist(group, %{deposit_paid_cents: paid, revision: revision})

      applied(operation,
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: group.deposit_due_cents - paid,
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_amount} ->
        reject(operation, "invalid_amount")

      {:error, :payment_exceeds_outstanding} ->
        reject(operation, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "new_arrival_on"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- future_arrival(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: revision
        })

      applied(operation,
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival_on),
        new_departure_on: Date.to_iso8601(new_departure_on),
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_stay")

      {:error, :invalid_stay} ->
        reject(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      refundable =
        group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

      refunded = if refundable, do: group.deposit_paid_cents, else: 0
      retained = if refundable, do: 0, else: group.deposit_paid_cents
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{
          status: "cancelled",
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_refunded_cents: refunded,
          cash_retained_cents: retained,
          revision: revision
        })

      applied(operation,
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")
    end
  end

  defp persist(group, attrs) do
    group
    |> Group.changeset(Map.merge(Map.from_struct(group), attrs))
    |> Repo.update()
  end

  defp require_open_fields(operation) do
    required = [
      "operation_id",
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    with :ok <- require_fields(operation, required),
         true <-
           Enum.all?(
             ["operation_id", "group_id", "guest_id", "property_id"],
             &usable_id?(operation[&1])
           ),
         true <- is_binary(operation["occurred_on"]),
         true <- is_binary(operation["arrival_on"]),
         true <- is_binary(operation["departure_on"]),
         true <- is_binary(operation["rate_plan"]),
         true <- is_list(operation["rooms"]),
         true <- Enum.all?(operation["rooms"], &complete_room?/1) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp require_update_fields(operation) do
    with :ok <- require_fields(operation, ["operation_id", "group_id"]),
         true <- usable_id?(operation["operation_id"]),
         true <- usable_id?(operation["group_id"]) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp require_fields(operation, fields) when is_map(operation) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)), do: :ok, else: {:error, :missing_data}
  end

  defp require_fields(_operation, _fields), do: {:error, :missing_data}

  defp usable_id?(value), do: is_binary(value) and value != ""

  defp complete_room?(room) when is_map(room) do
    Map.has_key?(room, "room_id") and Map.has_key?(room, "nightly_rate_cents")
  end

  defp complete_room?(_room), do: false

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_date}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, :invalid_rate_plan}
  end

  defp validate_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1["room_id"])

    valid =
      rooms != [] and
        Enum.all?(rooms, fn room ->
          usable_id?(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
            room["nightly_rate_cents"] > 0
        end) and Enum.uniq(room_ids) == room_ids

    if valid, do: {:ok, rooms}, else: {:error, :invalid_rooms}
  end

  defp deposit_due(rooms, nights, "flexible") do
    Enum.sum_by(rooms, fn room ->
      room_lodging = room["nightly_rate_cents"] * nights
      div(room_lodging * 20 + 50, 100)
    end)
  end

  defp deposit_due(rooms, nights, "advance_purchase") do
    Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
  end

  defp check_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error, :stale_revision, group}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp valid_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_amount(_amount), do: {:error, :invalid_amount}

  defp not_excessive(amount, outstanding) when amount <= outstanding, do: :ok
  defp not_excessive(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp future_arrival(arrival_on, occurred_on) do
    if Date.compare(arrival_on, occurred_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp serialize_group(group) do
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
      rooms: group.rooms["items"],
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  defp stale_revision(operation, group) do
    reject(operation, "stale_revision",
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    )
  end

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "applied"})
  end

  defp reject(operation, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "rejected", code: code})
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil
end
