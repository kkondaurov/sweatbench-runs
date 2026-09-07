defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner operations one at a time.

  Each call owns a database transaction. `process_batch/1` deliberately performs calls in list
  order, so later operations observe earlier commits while a rejected operation rolls back only
  its own work.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.Reservations.{GroupReservation, Room}

  @rate_plans ~w(flexible advance_purchase)

  @doc "Processes a syntactically valid operation array in order."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    case validate_common_fields(operation) do
      :ok ->
        # An immediate SQLite transaction takes the write reservation before the group is read.
        # That makes the revision check and update one serialized decision across API requests.
        case Repo.transaction(fn -> dispatch(operation) end, mode: :immediate) do
          {:ok, result} -> applied_result(operation_id, result)
          {:error, reason} -> rejected_result(operation_id, reason)
        end

      {:error, reason} ->
        rejected_result(operation_id, reason)
    end
  end

  defp process_operation(_operation), do: rejected_result(nil, :invalid_operation)

  defp validate_common_fields(%{
         "operation_id" => operation_id,
         "type" => type,
         "occurred_on" => occurred_on
       })
       when is_binary(operation_id) and operation_id != "" and is_binary(type) and
              is_binary(occurred_on) do
    case Date.from_iso8601(occurred_on) do
      {:ok, _date} -> :ok
      _ -> {:error, :invalid_operation}
    end
  end

  defp validate_common_fields(_operation), do: {:error, :invalid_operation}

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)
  defp dispatch(_operation), do: Repo.rollback(:invalid_operation)

  defp open_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         :ok <- ensure_group_is_new(group_id),
         {:ok, attributes} <- validate_open_group(operation, group_id) do
      group =
        %GroupReservation{}
        |> Changeset.change(attributes)
        |> Changeset.unique_constraint(:group_id)
        |> Repo.insert()
        |> case do
          {:ok, group} -> group
          {:error, _changeset} -> Repo.rollback(:group_already_exists)
        end

      rooms =
        operation["rooms"]
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          now = DateTime.utc_now(:second)

          %{
            group_id: group.group_id,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position,
            inserted_at: now,
            updated_at: now
          }
        end)

      {_count, nil} = Repo.insert_all(Room, rooms)

      %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_open_group(operation, group_id) do
    required = ~w(guest_id property_id arrival_on departure_on rate_plan rooms)

    if Enum.any?(required, &(not Map.has_key?(operation, &1))) do
      {:error, :invalid_operation}
    else
      with {:ok, guest_id} <- identifier(operation["guest_id"]),
           {:ok, property_id} <- identifier(operation["property_id"]),
           {:ok, booked_on} <- parse_date(operation["occurred_on"], :invalid_operation),
           {:ok, arrival_on, departure_on, nights} <- validate_stay(operation),
           {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
           {:ok, rooms} <- validate_rooms(operation["rooms"]) do
        lodging_total = Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
        deposit_due = calculate_deposit(rooms, nights, rate_plan)

        {:ok,
         %{
           group_id: group_id,
           guest_id: guest_id,
           property_id: property_id,
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: rate_plan,
           status: "active",
           lodging_total_cents: lodging_total,
           deposit_due_cents: deposit_due,
           deposit_paid_cents: 0,
           cash_refunded_cents: 0,
           cash_retained_cents: 0,
           revision: 1
         }}
      end
    end
  end

  defp validate_stay(%{"arrival_on" => arrival, "departure_on" => departure}) do
    with {:ok, arrival_on} <- parse_date(arrival, :invalid_stay),
         {:ok, departure_on} <- parse_date(departure, :invalid_stay),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 ->
          true

        _room ->
          false
      end)

    if valid? do
      room_ids = Enum.map(rooms, &Map.fetch!(&1, "room_id"))

      if Enum.uniq(room_ids) == room_ids,
        do: {:ok, rooms},
        else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp calculate_deposit(rooms, nights, "advance_purchase") do
    Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
  end

  defp calculate_deposit(rooms, nights, "flexible") do
    Enum.sum_by(rooms, fn room ->
      lodging_amount = room["nightly_rate_cents"] * nights
      div(lodging_amount * 20 + 50, 100)
    end)
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(operation),
         outstanding = Reservations.outstanding_deposit(group),
         :ok <- ensure_payment_within_outstanding(amount, outstanding),
         {:ok, updated} <-
           update_group(group, deposit_paid_cents: group.deposit_paid_cents + amount) do
      %{
        group_id: group_id,
        amount_cents: amount,
        outstanding_deposit_cents: Reservations.outstanding_deposit(updated),
        revision: updated.revision
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         {:ok, new_arrival} <- reschedule_date(operation, occurred_on),
         shift = Date.diff(new_arrival, group.arrival_on),
         new_departure = Date.add(group.departure_on, shift),
         {:ok, updated} <-
           update_group(group, arrival_on: new_arrival, departure_on: new_departure) do
      %{
        group_id: group_id,
        new_arrival_on: updated.arrival_on,
        new_departure_on: updated.departure_on,
        revision: updated.revision
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- validate_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation) do
      refundable? =
        group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

      refunded = if refundable?, do: group.deposit_paid_cents, else: 0
      retained = if refundable?, do: 0, else: group.deposit_paid_cents

      {:ok, updated} =
        update_group(group,
          status: "cancelled",
          cash_refunded_cents: refunded,
          cash_retained_cents: retained
        )

      %{
        group_id: group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        revision: updated.revision
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp required_identifier(operation, key) do
    if Map.has_key?(operation, key),
      do: identifier(operation[key]),
      else: {:error, :invalid_operation}
  end

  defp identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp identifier(_value), do: {:error, :invalid_operation}

  defp ensure_group_is_new(group_id) do
    if Repo.exists?(from group in GroupReservation, where: group.group_id == ^group_id),
      do: {:error, :group_already_exists},
      else: :ok
  end

  defp fetch_group(group_id) do
    case Repo.get(GroupReservation, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        {:error,
         {:stale_revision,
          %{
            group_id: group.group_id,
            expected_revision: expected,
            actual_revision: group.revision
          }}}

      {:ok, _invalid} ->
        {:error, :invalid_operation}
    end
  end

  defp ensure_active(%GroupReservation{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, :group_not_active}

  defp validate_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, :invalid_amount}
      :error -> {:error, :invalid_operation}
    end
  end

  defp ensure_payment_within_outstanding(amount, outstanding) when amount <= outstanding, do: :ok

  defp ensure_payment_within_outstanding(_amount, _outstanding),
    do: {:error, :payment_exceeds_outstanding}

  defp reschedule_date(operation, occurred_on) do
    case Map.fetch(operation, "new_arrival_on") do
      {:ok, value} ->
        with {:ok, date} <- parse_date(value, :invalid_stay),
             true <- Date.after?(date, occurred_on) do
          {:ok, date}
        else
          _ -> {:error, :invalid_stay}
        end

      :error ->
        {:error, :invalid_operation}
    end
  end

  defp parse_date(value, error) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, error}
    end
  end

  defp parse_date(_value, error), do: {:error, error}

  defp update_group(group, attributes) do
    now = DateTime.utc_now(:second)

    query =
      from candidate in GroupReservation,
        where: candidate.group_id == ^group.group_id and candidate.revision == ^group.revision

    updates = [revision: group.revision + 1, updated_at: now] ++ attributes

    case Repo.update_all(query, set: updates) do
      {1, nil} ->
        {:ok, Repo.get!(GroupReservation, group.group_id)}

      {0, nil} ->
        actual = Repo.get!(GroupReservation, group.group_id).revision

        {:error,
         {:stale_revision,
          %{group_id: group.group_id, expected_revision: group.revision, actual_revision: actual}}}
    end
  end

  defp applied_result(operation_id, result) do
    result
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "applied")
  end

  defp rejected_result(operation_id, {:stale_revision, details}) do
    details
    |> Map.merge(%{operation_id: operation_id, status: "rejected", code: "stale_revision"})
  end

  defp rejected_result(operation_id, reason) when is_atom(reason) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(reason)}
  end
end
