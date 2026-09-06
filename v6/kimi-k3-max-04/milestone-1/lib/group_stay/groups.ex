defmodule GroupStay.Groups do
  @moduledoc """
  The GroupStay domain: applying partner operations to group reservations and
  reading reservation and finance state.

  Partner operations are applied one at a time, each inside its own
  transaction. An operation either applies fully or is rejected, in which case
  the database is left exactly as it was before that operation began.
  """

  import Ecto.Query

  alias GroupStay.Money
  alias GroupStay.Repo
  alias GroupStay.Groups.{Group, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @flexible_deposit_percent 20
  @refundable_notice_days 14

  # --- Applying operations --------------------------------------------------

  @doc """
  Applies every operation in the list, in order, and returns one result per
  operation (applied or rejected) in the same order. A rejected operation
  never stops later operations.
  """
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single operation inside its own transaction. Returns a result map
  with `status` of either `"applied"` or `"rejected"`.
  """
  def apply_operation(operation) do
    case Repo.transaction(fn ->
           case process(operation) do
             {:applied, result} -> result
             {:rejected, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp process(%{"type" => type} = operation) when is_binary(type) do
    case type do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      _unknown -> reject(operation, "invalid_operation")
    end
  end

  defp process(operation), do: reject(operation, "invalid_operation")

  # --- open_group -----------------------------------------------------------

  defp open_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- required_date(operation, "departure_on", "invalid_stay"),
         {:ok, rate_plan} <- required_string(operation, "rate_plan"),
         {:ok, rooms} <- required_rooms(operation) do
      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      }

      cond do
        Repo.get_by(Group, group_id: group_id) ->
          reject(operation, "group_already_exists")

        Date.compare(departure_on, arrival_on) != :gt ->
          reject(operation, "invalid_stay")

        not valid_rooms?(rooms) ->
          reject(operation, "invalid_rooms")

        rate_plan not in @rate_plans ->
          reject(operation, "invalid_rate_plan")

        true ->
          apply_open_group(operation, attrs)
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_open_group(operation, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    {lodging_total, deposit_due} =
      Enum.reduce(attrs.rooms, {0, 0}, fn room, {lodging_acc, deposit_acc} ->
        room_lodging = room.nightly_rate_cents * nights
        room_deposit = room_deposit(room_lodging, attrs.rate_plan)
        {lodging_acc + room_lodging, deposit_acc + room_deposit}
      end)

    group =
      %Group{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        booked_on: attrs.booked_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        rate_plan: attrs.rate_plan,
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }
      |> Repo.insert!()

    attrs.rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      %Room{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position
      }
      |> Repo.insert!()
    end)

    apply_result(operation, %{
      group_id: group.group_id,
      deposit_due_cents: group.deposit_due_cents,
      revision: group.revision
    })
  end

  defp room_deposit(lodging_cents, "flexible"),
    do: Money.percent(lodging_cents, @flexible_deposit_percent)

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  # --- record_cash_payment --------------------------------------------------

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      with_group(operation, group_id, fn group ->
        outstanding = group.deposit_due_cents - group.deposit_paid_cents

        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          not usable_amount?(amount) ->
            reject(operation, "invalid_amount")

          amount > outstanding ->
            reject(operation, "payment_exceeds_outstanding")

          true ->
            apply_payment(operation, group, amount)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_payment(operation, group, amount) do
    group
    |> Ecto.Changeset.change(%{
      deposit_paid_cents: group.deposit_paid_cents + amount,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents - amount,
      revision: group.revision + 1
    })
  end

  # --- reschedule_group -----------------------------------------------------

  defp reschedule_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on", "invalid_stay") do
      with_group(operation, group_id, fn group ->
        cond do
          group.status != "active" ->
            reject(operation, "group_not_active")

          Date.compare(new_arrival_on, occurred_on) != :gt ->
            reject(operation, "invalid_stay")

          true ->
            apply_reschedule(operation, group, new_arrival_on)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_reschedule(operation, group, new_arrival_on) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, nights)

    group
    |> Ecto.Changeset.change(%{
      arrival_on: new_arrival_on,
      departure_on: new_departure_on,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      new_arrival_on: Date.to_string(new_arrival_on),
      new_departure_on: Date.to_string(new_departure_on),
      revision: group.revision + 1
    })
  end

  # --- cancel_group ---------------------------------------------------------

  defp cancel_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_operation") do
      with_group(operation, group_id, fn group ->
        if group.status != "active" do
          reject(operation, "group_not_active")
        else
          apply_cancel(operation, group, occurred_on)
        end
      end)
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_cancel(operation, group, occurred_on) do
    refundable? =
      group.rate_plan == "flexible" and
        Date.diff(group.arrival_on, occurred_on) >= @refundable_notice_days

    {refunded, retained} =
      if refundable? do
        {group.deposit_paid_cents, 0}
      else
        {0, group.deposit_paid_cents}
      end

    group
    |> Ecto.Changeset.change(%{
      status: "cancelled",
      refunded_cents: refunded,
      retained_cents: retained,
      revision: group.revision + 1
    })
    |> Repo.update!()

    apply_result(operation, %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: group.revision + 1
    })
  end

  # --- Shared operation helpers ---------------------------------------------

  # Resolves an existing group for group-addressed operations, then enforces
  # the optional `expected_revision` precondition before running the domain
  # rule in `fun`.
  defp with_group(operation, group_id, fun) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        reject(operation, "group_not_found")

      group ->
        case revision_ok?(group, operation) do
          :ok -> fun.(group)
          {:rejected, _result} = rejected -> rejected
        end
    end
  end

  defp revision_ok?(group, operation) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected when is_integer(expected) ->
        if expected == group.revision do
          :ok
        else
          stale_revision(operation, group, expected)
        end

      _other ->
        reject(operation, "invalid_operation")
    end
  end

  # --- Field extraction / validation ----------------------------------------

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "invalid_operation"}
    end
  end

  defp required_value(operation, field) do
    case Map.get(operation, field) do
      nil -> {:error, "invalid_operation"}
      value -> {:ok, value}
    end
  end

  # Missing data makes the operation unidentifiable/unappliable
  # (invalid_operation); data that is present but unusable for the field gets
  # the field-specific code (e.g. invalid_stay for stay dates).
  defp required_date(operation, field, code) do
    case Map.get(operation, field) do
      nil ->
        {:error, "invalid_operation"}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, code}
        end

      _other ->
        {:error, code}
    end
  end

  defp required_rooms(operation) do
    case Map.get(operation, "rooms") do
      rooms when is_list(rooms) ->
        if Enum.all?(rooms, &valid_room?/1) do
          {:ok,
           Enum.map(rooms, fn room ->
             %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
           end)}
        else
          {:error, "invalid_rooms"}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and is_integer(rate) and rate >= 0,
       do: true

  defp valid_room?(_other), do: false

  defp valid_rooms?(rooms) do
    rooms != [] and unique_room_ids?(rooms)
  end

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == length(Enum.uniq(ids))
  end

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

  # --- Result builders -------------------------------------------------------

  defp apply_result(operation, extra) do
    {:applied,
     Map.merge(
       %{operation_id: Map.get(operation, "operation_id"), status: "applied"},
       extra
     )}
  end

  defp reject(operation, code, extra \\ %{}) do
    base = %{
      operation_id: get_in_map(operation, "operation_id"),
      status: "rejected",
      code: code,
      group_id: get_in_map(operation, "group_id")
    }

    {:rejected, Map.merge(base, extra)}
  end

  defp stale_revision(operation, group, expected) do
    {:rejected,
     %{
       operation_id: Map.get(operation, "operation_id"),
       status: "rejected",
       code: "stale_revision",
       group_id: group.group_id,
       expected_revision: expected,
       actual_revision: group.revision
     }}
  end

  defp get_in_map(operation, key) when is_map(operation), do: Map.get(operation, key)
  defp get_in_map(_operation, _key), do: nil

  # --- Reads -----------------------------------------------------------------

  @doc "Fetches a group by its partner-supplied id, with rooms in order."
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  @doc "Serializes a group for the partner read endpoint."
  def group_view(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_string(group.booked_on),
      arrival_on: Date.to_string(group.arrival_on),
      departure_on: Date.to_string(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  @doc "Returns the finance totals for the ledger endpoint."
  def ledger_totals do
    %{
      cash_held_cents: sum_for_status("active", :deposit_paid_cents),
      cash_refunded_cents: sum_for_status("cancelled", :refunded_cents),
      cash_retained_cents: sum_for_status("cancelled", :retained_cents)
    }
  end

  defp sum_for_status(status, field) do
    Group
    |> where([g], g.status == ^status)
    |> select([g], coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end
end
