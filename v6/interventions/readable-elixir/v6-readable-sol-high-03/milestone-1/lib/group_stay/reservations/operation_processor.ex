defmodule GroupStay.Reservations.OperationProcessor do
  @moduledoc """
  Validates and applies one partner operation.

  Domain rejections roll back the operation transaction. Revision checks happen
  after resolving the target group and before state-dependent domain rules.
  """

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @rate_plans ~w(flexible advance_purchase)

  def process(operation) do
    # SQLite's immediate transaction reserves the writer before reading. That
    # makes the revision comparison and following update one serialized unit.
    case Repo.transaction(fn -> apply_operation(operation) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  rescue
    Ecto.StaleEntryError -> concurrent_rejection(operation)
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: reschedule_group(operation)

  defp apply_operation(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)
  defp apply_operation(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with :ok <- require_fields(operation, required),
         :ok <-
           validate_partner_identifiers(operation, ~w(operation_id group_id guest_id property_id)),
         {:ok, booked_on} <- date(operation["occurred_on"]),
         {:ok, arrival_on} <- date(operation["arrival_on"]),
         {:ok, departure_on} <- date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         {:ok, group} <- insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
      applied(operation, %{
        "group_id" => group.group_id,
        "deposit_due_cents" => group.deposit_due_cents,
        "revision" => group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_stay")
      {:error, :invalid_stay} -> reject(operation, "invalid_stay")
      {:error, :invalid_rate_plan} -> reject(operation, "invalid_rate_plan")
      {:error, :invalid_rooms} -> reject(operation, "invalid_rooms")
      {:error, :group_already_exists} -> reject(operation, "group_already_exists")
    end
  end

  defp record_cash_payment(operation) do
    required = ~w(operation_id occurred_on group_id amount_cents)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, _occurred_on} <- date(operation["occurred_on"]),
         :ok <- active(group),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- within_outstanding(operation["amount_cents"], group),
         {:ok, updated_group} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + operation["amount_cents"]
           }) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "amount_cents" => operation["amount_cents"],
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_amount} -> reject(operation, "invalid_amount")
      {:error, :payment_exceeds_outstanding} -> reject(operation, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation) do
    required = ~w(operation_id occurred_on group_id new_arrival_on)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, occurred_on} <- date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- date(operation["new_arrival_on"]),
         :ok <- active(group),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on),
         shift = Date.diff(new_arrival_on, group.arrival_on),
         new_departure_on = Date.add(group.departure_on, shift),
         {:ok, updated_group} <-
           update_group(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on}) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "new_arrival_on" => updated_group.arrival_on,
        "new_departure_on" => updated_group.departure_on,
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_stay")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_stay} -> reject(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation) do
    required = ~w(operation_id occurred_on group_id)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, occurred_on} <- date(operation["occurred_on"]),
         :ok <- active(group),
         {refunded, retained} = settlement(group, occurred_on),
         {:ok, updated_group} <-
           update_group(group, %{
             status: "cancelled",
             cash_refunded_cents: refunded,
             cash_retained_cents: retained
           }) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "refunded_cents" => refunded,
        "retained_cents" => retained,
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :group_not_active} -> reject(operation, "group_not_active")
    end
  end

  defp insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
    nights = Date.diff(departure_on, arrival_on)
    lodging_total = Enum.sum_by(rooms, &(&1.nightly_rate_cents * nights))
    deposit_due = deposit_due(operation["rate_plan"], rooms, nights)

    attributes = %{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    }

    case Repo.insert(Group.creation_changeset(%Group{}, attributes)) do
      {:ok, group} ->
        case insert_rooms(Repo, group, rooms) do
          {:ok, _rooms} -> {:ok, group}
          {:error, reason} -> raise "validated rooms could not be inserted: #{inspect(reason)}"
        end

      {:error, changeset} ->
        classify_group_insert(changeset)
    end
  end

  defp insert_rooms(repo, group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, inserted} ->
      changeset =
        Room.changeset(%Room{}, %{
          group_id: group.group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        })

      case repo.insert(changeset) do
        {:ok, inserted_room} -> {:cont, {:ok, [inserted_room | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp classify_group_insert(changeset) do
    if Keyword.has_key?(changeset.errors, :group_id) do
      {:error, :group_already_exists}
    else
      raise "validated group could not be inserted: #{inspect(changeset.errors)}"
    end
  end

  defp load_group(operation) do
    case Repo.get(Group, operation["group_id"]) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp update_group(group, attributes) do
    group
    |> Group.operation_changeset(attributes)
    |> Repo.update()
  end

  defp compare_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, revision} when revision == group.revision -> :ok
      {:ok, _revision} -> {:error, :stale_revision, group}
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    with true <- Enum.all?(rooms, &valid_room?/1),
         room_ids = Enum.map(rooms, & &1["room_id"]),
         true <- length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      _ -> {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate}) do
    nonempty_string?(room_id) and is_integer(rate) and rate > 0
  end

  defp valid_room?(_room), do: false

  defp valid_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_amount(_amount), do: {:error, :invalid_amount}

  defp within_outstanding(amount, group) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, :payment_exceeds_outstanding}
  end

  defp outstanding_deposit(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding_deposit(_group), do: 0

  defp deposit_due("advance_purchase", rooms, nights) do
    Enum.sum_by(rooms, &(&1.nightly_rate_cents * nights))
  end

  defp deposit_due("flexible", rooms, nights) do
    # Add half of the denominator before integer division: exact half-cents
    # therefore round upward, as required by the partner contract.
    Enum.sum_by(rooms, fn room ->
      lodging = room.nightly_rate_cents * nights
      div(lodging * 20 + 50, 100)
    end)
  end

  defp settlement(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp settlement(group, _occurred_on), do: {0, group.deposit_paid_cents}

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp date(_value), do: {:error, :invalid_date}

  defp require_fields(operation, fields) when is_map(operation) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: {:error, :missing_data}
  end

  defp require_fields(_operation, _fields), do: {:error, :missing_data}

  defp validate_partner_identifiers(operation, fields) do
    if Enum.all?(fields, &nonempty_string?(operation[&1])),
      do: :ok,
      else: {:error, :invalid_identifier}
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp applied(operation, fields) do
    Map.merge(
      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied"
      },
      fields
    )
  end

  defp reject(operation, code) do
    Repo.rollback(%{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => code
    })
  end

  defp reject_stale(operation, group) do
    Repo.rollback(stale_result(operation, group))
  end

  defp concurrent_rejection(operation) do
    case operation do
      %{"group_id" => group_id, "expected_revision" => _revision} ->
        case Repo.get(Group, group_id) do
          nil -> rejected_result(operation, "group_not_found")
          group -> stale_result(operation, group)
        end

      _operation ->
        # An unconditional operation that collided with another writer retains
        # its unconditional semantics by being attempted again.
        process(operation)
    end
  end

  defp stale_result(operation, group) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group.group_id,
      "expected_revision" => operation["expected_revision"],
      "actual_revision" => group.revision
    }
  end

  defp rejected_result(operation, code) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => code
    }
  end

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_operation), do: nil
end
