defmodule GroupStay.Groups do
  @moduledoc "The group-deposit domain and its ordered partner operations."

  import Ecto.Query

  alias GroupStay.Groups.{CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]
  @top_level_open ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_), do: nil

  def ledger(on \\ Date.utc_today()) do
    groups = Repo.all(Group)

    %{
      cash_held_cents:
        groups
        |> Enum.filter(&(&1.status == "active"))
        |> Enum.map(& &1.cash_paid_cents)
        |> Enum.sum(),
      cash_refunded_cents: groups |> Enum.map(& &1.cash_refunded_cents) |> Enum.sum(),
      cash_retained_cents: groups |> Enum.map(& &1.cash_retained_cents) |> Enum.sum(),
      cash_converted_to_credit_cents:
        groups |> Enum.map(& &1.cash_converted_to_credit_cents) |> Enum.sum(),
      credit_liability_cents: credit_liability(on)
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def parse_read_date(nil), do: {:ok, Date.utc_today()}
  def parse_read_date(value), do: parse_date(value)

  def group_json(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    case validate_envelope(operation) do
      :ok -> transact_operation(operation, operation_id)
      :error -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_), do: rejected(nil, "invalid_operation")

  defp validate_envelope(operation) do
    if nonempty_string?(operation["operation_id"]) and nonempty_string?(operation["type"]) do
      :ok
    else
      :error
    end
  end

  defp transact_operation(operation, operation_id) do
    transact_operation(operation, operation_id, 0)
  end

  defp transact_operation(operation, operation_id, attempt) do
    try do
      case Repo.transaction(fn -> dispatch(operation, operation_id) end) do
        {:ok, result} -> result
        {:error, result} when is_map(result) -> result
        {:error, _reason} -> rejected(operation_id, "invalid_operation")
      end
    rescue
      Ecto.StaleEntryError -> handle_concurrent_update(operation, operation_id, attempt)
    end
  end

  defp handle_concurrent_update(operation, operation_id, attempt) do
    if Map.has_key?(operation, "expected_revision") do
      case get_group(operation["group_id"]) do
        nil ->
          rejected(operation_id, "group_not_found", operation["group_id"])

        group ->
          rejected(operation_id, "stale_revision", group.group_id, %{
            expected_revision: operation["expected_revision"],
            actual_revision: group.revision
          })
      end
    else
      # Unconditional operations retain their existing behavior under a competing writer.
      if attempt < 3,
        do: transact_operation(operation, operation_id, attempt + 1),
        else: rejected(operation_id, "invalid_operation")
    end
  end

  defp dispatch(%{"type" => "open_group"} = operation, operation_id),
    do: open_group(operation, operation_id)

  defp dispatch(%{"type" => "record_cash_payment"} = operation, operation_id),
    do: with_group(operation, operation_id, &record_cash_payment(&1, operation, operation_id))

  defp dispatch(%{"type" => "reschedule_group"} = operation, operation_id),
    do: with_group(operation, operation_id, &reschedule_group(&1, operation, operation_id))

  defp dispatch(%{"type" => "cancel_group"} = operation, operation_id),
    do: with_group(operation, operation_id, &cancel_group(&1, operation, operation_id))

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation, operation_id),
    do: with_group(operation, operation_id, &apply_hotel_credit(&1, operation, operation_id))

  defp dispatch(_operation, operation_id), do: reject(operation_id, "invalid_operation")

  defp open_group(operation, operation_id) do
    cond do
      not Enum.all?(@top_level_open, &Map.has_key?(operation, &1)) ->
        reject(operation_id, "invalid_operation")

      not valid_open_identifiers?(operation) ->
        reject(operation_id, "invalid_operation")

      Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) ->
        reject(operation_id, "group_already_exists", operation["group_id"])

      operation["rate_plan"] not in @rate_plans ->
        reject(operation_id, "invalid_rate_plan", operation["group_id"])

      true ->
        create_group(operation, operation_id)
    end
  end

  defp create_group(operation, operation_id) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.compare(arrival_on, departure_on) == :lt || :invalid_stay,
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = rooms |> Enum.map(&(&1.nightly_rate_cents * nights)) |> Enum.sum()

      deposit_due =
        rooms
        |> Enum.map(fn room ->
          lodging = room.nightly_rate_cents * nights
          if operation["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        end)
        |> Enum.sum()

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version(operation["rate_plan"], booked_on),
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          now = DateTime.utc_now()

          room_rows =
            rooms
            |> Enum.with_index()
            |> Enum.map(fn {room, position} ->
              room
              |> Map.put(:group_id, group.id)
              |> Map.put(:position, position)
              |> Map.put(:inserted_at, now)
              |> Map.put(:updated_at, now)
            end)

          {_count, nil} = Repo.insert_all(Room, room_rows)

          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          }

        {:error, changeset} ->
          if changeset.errors[:group_id],
            do: reject(operation_id, "group_already_exists", operation["group_id"]),
            else: reject(operation_id, "invalid_operation")
      end
    else
      :invalid_stay -> reject(operation_id, "invalid_stay", operation["group_id"])
      {:error, :date} -> reject(operation_id, "invalid_stay", operation["group_id"])
      {:error, :rooms} -> reject(operation_id, "invalid_rooms", operation["group_id"])
    end
  end

  defp with_group(operation, operation_id, function) do
    group_id = operation["group_id"]

    if not nonempty_string?(group_id) do
      reject(operation_id, "invalid_operation")
    else
      case Repo.get_by(Group, group_id: group_id) do
        nil -> reject(operation_id, "group_not_found", group_id)
        group -> check_revision(group, operation, operation_id, function)
      end
    end
  end

  defp check_revision(group, operation, operation_id, function) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      reject(operation_id, "stale_revision", group.group_id, %{
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      function.(group)
    end
  end

  defp record_cash_payment(group, operation, operation_id) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(amount) and amount > 0) ->
        reject(operation_id, "invalid_amount", group.group_id)

      amount > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        group =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })

        %{
          operation_id: operation_id,
          status: "applied",
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        }
    end
  end

  defp reschedule_group(group, operation, operation_id) do
    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "new_arrival_on") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      true ->
        apply_reschedule(group, operation, operation_id)
    end
  end

  defp apply_reschedule(group, operation, operation_id) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      group =
        update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: group.group_id,
        new_arrival_on: new_arrival_on,
        new_departure_on: new_departure_on,
        policy_version: policy_version(group),
        refundable_until: refundable_until(group),
        revision: group.revision
      }
    else
      _ -> reject(operation_id, "invalid_stay", group.group_id)
    end
  end

  defp cancel_group(group, operation, operation_id) do
    refund_method = Map.get(operation, "refund_method", "cash")

    cond do
      not Map.has_key?(operation, "occurred_on") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      refund_method not in ["cash", "hotel_credit"] ->
        reject(operation_id, "invalid_operation", group.group_id)

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            apply_cancellation(group, occurred_on, refund_method, operation_id)

          {:error, :date} ->
            reject(operation_id, "invalid_operation")
        end
    end
  end

  defp apply_cancellation(group, occurred_on, refund_method, operation_id) do
    refundable = refundable?(group, occurred_on)

    if refund_method == "hotel_credit" and not refundable do
      reject(operation_id, "refund_method_not_available", group.group_id)
    end

    refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    credit_issued =
      if refundable and refund_method == "hotel_credit" do
        credit = group.cash_paid_cents + round_percentage(group.cash_paid_cents, 10)

        if credit > 0 do
          %CreditLot{}
          |> CreditLot.changeset(%{
            guest_id: group.guest_id,
            source_operation_id: operation_id,
            remaining_cents: credit,
            expires_on: Date.add(occurred_on, 365)
          })
          |> Repo.insert!()
        end

        credit
      else
        0
      end

    settle_allocated_credit(group, refundable, occurred_on)

    group =
      update_group!(group, %{
        status: "cancelled",
        cash_refunded_cents: refunded,
        cash_retained_cents: retained,
        cash_converted_to_credit_cents:
          if(refundable and refund_method == "hotel_credit", do: group.cash_paid_cents, else: 0)
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: group.revision
    }
  end

  defp apply_hotel_credit(group, operation, operation_id) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "amount_cents") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active", group.group_id)

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(amount) and amount > 0) ->
        reject(operation_id, "invalid_amount", group.group_id)

      amount > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        apply_credit_lots(group, amount, occurred_on, operation_id)
    end
  end

  defp apply_credit_lots(group, amount, occurred_on, operation_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      reject(operation_id, "insufficient_credit", group.group_id)
    end

    consume_lots(lots, group, amount)

    group =
      update_group!(group, %{
        deposit_paid_cents: group.deposit_paid_cents + amount,
        credit_paid_cents: group.credit_paid_cents + amount
      })

    %{
      operation_id: operation_id,
      status: "applied",
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(group),
      revision: group.revision
    }
  end

  defp consume_lots(_lots, _group, 0), do: :ok

  defp consume_lots([lot | rest], group, amount) do
    consumed = min(lot.remaining_cents, amount)

    lot
    |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - consumed})
    |> Repo.update!()

    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: consumed
    })
    |> Repo.insert!()

    consume_lots(rest, group, amount - consumed)
  end

  defp settle_allocated_credit(group, refundable, occurred_on) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.id
      )

    Enum.each(allocations, fn allocation ->
      # A lot may fund the same group through several operations. Reload it for each allocation so
      # each restoration builds on the preceding one rather than on a shared preloaded value.
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable and Date.compare(lot.expires_on, occurred_on) != :lt do
        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents + allocation.amount_cents})
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp credit_liability(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: allocation.group_id == group.id,
          where: group.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp policy_version(%Group{policy_version: version}) when is_binary(version), do: version
  defp policy_version(%Group{} = group), do: policy_version(group.rate_plan, group.booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{} = group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, deadline) != :gt
    end
  end

  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Ecto.Changeset.optimistic_lock(:revision)
    |> Repo.update!()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          nonempty_string?(room_id) and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(room_ids) == room_ids do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, :rooms}
    end
  end

  defp validate_rooms(_), do: {:error, :rooms}

  defp valid_open_identifiers?(operation) do
    Enum.all?(~w(group_id guest_id property_id), &nonempty_string?(operation[&1]))
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :date}
    end
  end

  defp parse_date(_), do: {:error, :date}

  defp valid_date?(value), do: match?({:ok, _}, parse_date(value))
  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0

  defp reject(operation_id, code, group_id \\ nil, extra \\ %{}) do
    Repo.rollback(rejected(operation_id, code, group_id, extra))
  end

  defp rejected(operation_id, code, group_id \\ nil, extra \\ %{}) do
    %{operation_id: operation_id, status: "rejected", code: code}
    |> maybe_put(:group_id, group_id)
    |> Map.merge(extra)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
