defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, OperationRecord, Repo, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @max_sqlite_integer 9_223_372_036_854_775_807

  def process_batch(operations) do
    Enum.map(operations, fn operation ->
      case Repo.transaction(fn -> process_idempotently(operation) end, mode: :immediate) do
        {:ok, result} -> result
        {:error, result} -> result
      end
    end)
  end

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_operation_result(_operation_id), do: nil

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> case do
      nil -> nil
      group -> Repo.preload(group, rooms: from(r in Room, order_by: r.position))
    end
  end

  def get_group(_group_id), do: nil

  def ledger(on \\ Date.utc_today()) do
    Repo.all(Group)
    |> Enum.reduce(
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0
      },
      fn group, totals ->
        %{
          cash_held_cents:
            totals.cash_held_cents +
              if(group.status == "active", do: group.cash_paid_cents, else: 0),
          cash_refunded_cents: totals.cash_refunded_cents + group.refunded_cents,
          cash_retained_cents: totals.cash_retained_cents + group.retained_cents,
          cash_converted_to_credit_cents:
            totals.cash_converted_to_credit_cents + group.cash_converted_to_credit_cents
        }
      end
    )
    |> Map.put(:credit_liability_cents, credit_liability(on))
  end

  def guest_credit(guest_id, on) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def report_date(nil), do: {:ok, Date.utc_today()}
  def report_date(value), do: parse_date(value)

  def policy_version(%Group{policy_version: version}) when is_binary(version), do: version
  def policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version(%Group{booked_on: booked_on}) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  def refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> group.arrival_on |> Date.add(-14) |> Date.to_iso8601()
      "flex-30" -> group.arrival_on |> Date.add(-30) |> Date.to_iso8601()
      "advance-nonrefundable" -> nil
    end
  end

  def outstanding(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding(%Group{}), do: 0

  defp process_idempotently(operation) do
    case rememberable_operation_id(operation) do
      nil ->
        process_operation(operation)

      operation_id ->
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          nil -> process_and_remember(operation_id, operation)
          record -> replay_or_conflict(record, operation)
        end
    end
  end

  defp process_and_remember(operation_id, operation) do
    result = process_operation(operation)

    %OperationRecord{}
    |> OperationRecord.changeset(%{
      operation_id: operation_id,
      operation_type: submitted_type(operation),
      submission: operation,
      result: result
    })
    |> Repo.insert!()

    result
  end

  defp replay_or_conflict(record, operation) do
    if record.submission === operation do
      record.result
    else
      rejected(record.operation_id, "operation_id_conflict")
    end
  end

  defp rememberable_operation_id(%{"operation_id" => operation_id})
       when is_binary(operation_id),
       do: operation_id

  defp rememberable_operation_id(_operation), do: nil

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  defp process_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp process_operation(%{"type" => type} = operation)
       when type in [
              "record_cash_payment",
              "apply_hotel_credit",
              "reschedule_group",
              "cancel_group"
            ] do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> rejected(operation_id, "group_not_found")
        group -> process_existing(operation, operation_id, group)
      end
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp process_operation(operation) when is_map(operation) do
    rejected(operation_id(operation), "invalid_operation")
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp open_group(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, occurred_on_value} <- required_value(operation, "occurred_on"),
         {:ok, arrival_value} <- required_value(operation, "arrival_on"),
         {:ok, departure_value} <- required_value(operation, "departure_on"),
         {:ok, rate_plan} <- required_value(operation, "rate_plan"),
         {:ok, rooms} <- required_value(operation, "rooms") do
      cond do
        Repo.exists?(from g in Group, where: g.group_id == ^group_id) ->
          rejected(operation_id, "group_already_exists")

        rate_plan not in @rate_plans ->
          rejected(operation_id, "invalid_rate_plan")

        true ->
          create_group(operation_id, %{
            group_id: group_id,
            guest_id: guest_id,
            property_id: property_id,
            occurred_on: occurred_on_value,
            arrival_on: arrival_value,
            departure_on: departure_value,
            rate_plan: rate_plan,
            rooms: rooms
          })
      end
    else
      _ -> rejected(operation_id(operation), "invalid_operation")
    end
  end

  defp create_group(operation_id, attrs) do
    with {:ok, booked_on} <- parse_date(attrs.occurred_on),
         {:ok, arrival_on} <- parse_date(attrs.arrival_on),
         {:ok, departure_on} <- parse_date(attrs.departure_on),
         true <- Date.compare(departure_on, arrival_on) == :gt do
      nights = Date.diff(departure_on, arrival_on)

      case validate_rooms(attrs.rooms, nights, attrs.rate_plan) do
        {:ok, rooms, lodging_total, deposit_due} ->
          persist_group(
            operation_id,
            attrs,
            booked_on,
            arrival_on,
            departure_on,
            rooms,
            lodging_total,
            deposit_due
          )

        :error ->
          rejected(operation_id, "invalid_rooms")
      end
    else
      _ -> rejected(operation_id, "invalid_stay")
    end
  end

  defp persist_group(
         operation_id,
         attrs,
         booked_on,
         arrival_on,
         departure_on,
         rooms,
         lodging_total,
         deposit_due
       ) do
    group_attrs = %{
      group_id: attrs.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: attrs.rate_plan,
      policy_version: policy_version(attrs.rate_plan, booked_on),
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    }

    case %Group{} |> Group.changeset(group_attrs) |> Repo.insert() do
      {:ok, group} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          Enum.map(rooms, fn room ->
            Map.merge(room, %{
              id: Ecto.UUID.generate(),
              group_ref: group.id,
              inserted_at: now,
              updated_at: now
            })
          end)

        {room_count, _} = Repo.insert_all(Room, room_rows)

        if room_count != length(room_rows) do
          raise "failed to persist every room"
        end

        applied(operation_id, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, changeset} ->
        code =
          if changeset.errors[:group_id], do: "group_already_exists", else: "invalid_operation"

        rejected(operation_id, code)
    end
  end

  defp process_existing(operation, operation_id, group) do
    with :ok <- validate_expected_revision(operation, group) do
      case operation["type"] do
        "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id, group)
        "reschedule_group" -> reschedule_group(operation, operation_id, group)
        "cancel_group" -> cancel_group(operation, operation_id, group)
      end
    else
      {:stale, expected} -> stale(operation_id, group, expected)
      :invalid -> rejected(operation_id, "invalid_operation")
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    with {:ok, occurred_value} <- required_value(operation, "occurred_on"),
         {:ok, _occurred_on} <- parse_date(occurred_value),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        not (is_integer(amount) and amount > 0) ->
          rejected(operation_id, "invalid_amount")

        amount > outstanding(group) ->
          rejected(operation_id, "payment_exceeds_outstanding")

        true ->
          {:ok, updated} =
            group
            |> Group.changeset(%{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              cash_paid_cents: group.cash_paid_cents + amount,
              revision: group.revision + 1
            })
            |> Repo.update()

          applied(operation_id, %{
            group_id: updated.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          })
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with {:ok, occurred_value} <- required_value(operation, "occurred_on"),
         {:ok, occurred_on} <- parse_date(occurred_value),
         {:ok, amount} <- required_value(operation, "amount_cents") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        not (is_integer(amount) and amount > 0) ->
          rejected(operation_id, "invalid_amount")

        amount > outstanding(group) ->
          rejected(operation_id, "payment_exceeds_outstanding")

        available_credit(group.guest_id, occurred_on) < amount ->
          rejected(operation_id, "insufficient_credit")

        true ->
          consume_credit(group, amount, occurred_on)

          {:ok, updated} =
            group
            |> Group.changeset(%{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: group.credit_paid_cents + amount,
              revision: group.revision + 1
            })
            |> Repo.update()

          applied(operation_id, %{
            group_id: updated.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(updated),
            revision: updated.revision
          })
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with {:ok, occurred_value} <- required_value(operation, "occurred_on"),
         {:ok, arrival_value} <- required_value(operation, "new_arrival_on") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        true ->
          move_group(operation_id, group, occurred_value, arrival_value)
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp move_group(operation_id, group, occurred_value, arrival_value) do
    with {:ok, occurred_on} <- parse_date(occurred_value),
         {:ok, new_arrival_on} <- parse_date(arrival_value),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      new_departure_on = Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))

      {:ok, updated} =
        group
        |> Group.changeset(%{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })
        |> Repo.update()

      applied(operation_id, %{
        group_id: updated.group_id,
        new_arrival_on: Date.to_iso8601(updated.arrival_on),
        new_departure_on: Date.to_iso8601(updated.departure_on),
        policy_version: policy_version(updated),
        refundable_until: refundable_until(updated),
        revision: updated.revision
      })
    else
      _ -> rejected(operation_id, "invalid_stay")
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with {:ok, occurred_value} <- required_value(operation, "occurred_on") do
      cond do
        group.status != "active" ->
          rejected(operation_id, "group_not_active")

        true ->
          case refund_method(operation) do
            {:ok, refund_method} ->
              settle_cancellation(operation_id, group, occurred_value, refund_method)

            :error ->
              rejected(operation_id, "invalid_operation")
          end
      end
    else
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp settle_cancellation(operation_id, group, occurred_value, refund_method) do
    case parse_date(occurred_value) do
      {:ok, occurred_on} ->
        refundable = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable do
          rejected(operation_id, "refund_method_not_available")
        else
          complete_cancellation(operation_id, group, occurred_on, refundable, refund_method)
        end

      :error ->
        rejected(operation_id, "invalid_operation")
    end
  end

  defp complete_cancellation(operation_id, group, occurred_on, refundable, refund_method) do
    refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    converted =
      if refundable and refund_method == "hotel_credit", do: group.cash_paid_cents, else: 0

    credit_issued = converted + div(converted * 10 + 50, 100)

    if credit_issued > 0 do
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()
    end

    settle_allocated_credit(group, occurred_on, refundable)

    {:ok, updated} =
      group
      |> Group.changeset(%{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained,
        cash_converted_to_credit_cents: converted,
        revision: group.revision + 1
      })
      |> Repo.update()

    applied(operation_id, %{
      group_id: updated.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: updated.revision
    })
  end

  defp refundable?(group, occurred_on) do
    case policy_version(group) do
      "flex-14" -> Date.compare(occurred_on, Date.add(group.arrival_on, -14)) != :gt
      "flex-30" -> Date.compare(occurred_on, Date.add(group.arrival_on, -30)) != :gt
      "advance-nonrefundable" -> false
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> :error
    end
  end

  defp available_credit(guest_id, on) do
    Repo.one(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
        select: coalesce(sum(l.remaining_cents), 0)
    )
  end

  defp consume_credit(group, amount, on) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^group.guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    Enum.reduce_while(lots, amount, fn lot, left ->
      used = min(left, lot.remaining_cents)
      lot |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - used}) |> Repo.update!()

      case Repo.get_by(CreditAllocation, lot_id: lot.id, group_ref: group.id) do
        nil ->
          %CreditAllocation{}
          |> CreditAllocation.changeset(%{
            lot_id: lot.id,
            group_ref: group.id,
            amount_cents: used
          })
          |> Repo.insert!()

        allocation ->
          allocation
          |> CreditAllocation.changeset(%{amount_cents: allocation.amount_cents + used})
          |> Repo.update!()
      end

      if used == left, do: {:halt, 0}, else: {:cont, left - used}
    end)
  end

  defp settle_allocated_credit(group, occurred_on, refundable) do
    allocations =
      Repo.all(from a in CreditAllocation, where: a.group_ref == ^group.id, preload: [:lot])

    Enum.each(allocations, fn allocation ->
      if refundable and Date.compare(allocation.lot.expires_on, occurred_on) != :lt do
        allocation.lot
        |> CreditLot.changeset(%{
          remaining_cents: allocation.lot.remaining_cents + allocation.amount_cents
        })
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp credit_liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from a in CreditAllocation,
          join: g in Group,
          on: g.id == a.group_ref,
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + allocated
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp validate_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected > 0 ->
        if expected == group.revision, do: :ok, else: {:stale, expected}

      {:ok, _expected} ->
        :invalid
    end
  end

  defp validate_rooms(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    parsed =
      Enum.with_index(rooms)
      |> Enum.reduce_while([], fn
        {%{"room_id" => room_id, "nightly_rate_cents" => rate}, position}, acc
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          {:cont, [%{room_id: room_id, nightly_rate_cents: rate, position: position} | acc]}

        _, _acc ->
          {:halt, :error}
      end)

    case parsed do
      :error ->
        :error

      rooms ->
        rooms = Enum.reverse(rooms)

        if Enum.uniq_by(rooms, & &1.room_id) == rooms do
          totals =
            Enum.reduce(rooms, {0, 0}, fn room, {lodging_total, deposit_total} ->
              lodging = room.nightly_rate_cents * nights
              deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
              {lodging_total + lodging, deposit_total + deposit}
            end)

          {lodging_total, deposit_due} = totals

          if Enum.all?(rooms, &(&1.nightly_rate_cents <= @max_sqlite_integer)) and
               lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer do
            {:ok, rooms, lodging_total, deposit_due}
          else
            :error
          end
        else
          :error
        end
    end
  end

  defp validate_rooms(_rooms, _nights, _rate_plan), do: :error

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp required_value(map, key), do: Map.fetch(map, key)

  defp operation_id(%{"operation_id" => operation_id}) when is_binary(operation_id),
    do: operation_id

  defp operation_id(_operation), do: nil

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp rejected(operation_id, code),
    do: %{operation_id: operation_id, status: "rejected", code: code}

  defp stale(operation_id, group, expected) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: expected,
      actual_revision: group.revision
    }
  end
end
