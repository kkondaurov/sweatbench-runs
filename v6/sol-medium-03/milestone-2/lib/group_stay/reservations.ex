defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations and exposes the resulting reservation and ledger views.

  Each operation gets its own transaction. This lets a rejected operation roll back without
  undoing earlier operations in the same batch.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditAllocation, CreditLot, Group, Room}

  @rate_plans ~w(flexible advance_purchase)
  @max_sqlite_integer 9_223_372_036_854_775_807

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, rooms: from(r in Room, order_by: r.position))}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

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
        if group.status == "active" do
          Map.update!(totals, :cash_held_cents, &(&1 + group.cash_paid_cents))
        else
          totals
          |> Map.update!(:cash_refunded_cents, &(&1 + group.refunded_cents))
          |> Map.update!(:cash_retained_cents, &(&1 + group.retained_cents))
          |> Map.update!(
            :cash_converted_to_credit_cents,
            &(&1 + group.cash_converted_to_credit_cents)
          )
        end
      end
    )
    |> Map.put(:credit_liability_cents, credit_liability(on))
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      CreditLot
      |> where([lot], lot.guest_id == ^guest_id)
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on >= ^on)
      |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
      |> Repo.all()

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

  def group_json(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
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
      outstanding_deposit_cents: if(group.status == "active", do: outstanding(group), else: 0)
    }
  end

  defp apply_operation(operation) do
    operation_id = operation_id(operation)

    # IMMEDIATE transactions serialize SQLite writers before they read a revision, so two
    # concurrent requests cannot both apply against the same expected revision.
    case Repo.transaction(fn -> transact_operation(operation, operation_id) end, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp transact_operation(%{"type" => "open_group"} = operation, operation_id),
    do: with_operation_id(operation_id, fn -> open_group(operation, operation_id) end)

  defp transact_operation(%{"type" => "record_cash_payment"} = operation, operation_id),
    do:
      with_operation_id(operation_id, fn ->
        with_group(operation, operation_id, &record_cash_payment/3)
      end)

  defp transact_operation(%{"type" => "reschedule_group"} = operation, operation_id),
    do:
      with_operation_id(operation_id, fn ->
        with_group(operation, operation_id, &reschedule_group/3)
      end)

  defp transact_operation(%{"type" => "cancel_group"} = operation, operation_id),
    do:
      with_operation_id(operation_id, fn ->
        with_group(operation, operation_id, &cancel_group/3)
      end)

  defp transact_operation(%{"type" => "apply_hotel_credit"} = operation, operation_id),
    do:
      with_operation_id(operation_id, fn ->
        with_group(operation, operation_id, &apply_hotel_credit/3)
      end)

  defp transact_operation(_operation, operation_id),
    do: reject(operation_id, "invalid_operation")

  defp open_group(operation, operation_id) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if valid_required_fields?(operation, required) do
      group_id = operation["group_id"]

      if Repo.get(Group, group_id) do
        reject(operation_id, "group_already_exists")
      else
        validate_and_insert_group(operation, operation_id)
      end
    else
      reject(operation_id, "invalid_operation")
    end
  end

  defp validate_and_insert_group(operation, operation_id) do
    case parse_date(operation["occurred_on"]) do
      {:ok, booked_on} -> validate_stay_and_insert(operation, operation_id, booked_on)
      _ -> reject(operation_id, "invalid_operation")
    end
  end

  defp validate_stay_and_insert(operation, operation_id, booked_on) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         nights = Date.diff(departure_on, arrival_on),
         {:ok, lodging_total, deposit_due} <-
           calculate_totals(rooms, nights, operation["rate_plan"]) do
      group =
        %Group{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          policy_version: policy_version(operation["rate_plan"], booked_on),
          status: "active",
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          revision: 1
        }
        |> Repo.insert!()

      rooms
      |> Enum.with_index()
      |> Enum.each(fn {room, position} ->
        Repo.insert!(%Room{
          group_id: group.group_id,
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"]
        })
      end)

      applied(operation_id, %{
        group_id: group.group_id,
        deposit_due_cents: deposit_due,
        revision: 1
      })
    else
      {:error, code} when code in ["invalid_stay", "invalid_rooms", "invalid_rate_plan"] ->
        reject(operation_id, code)

      _ ->
        reject(operation_id, "invalid_stay")
    end
  end

  defp with_group(operation, operation_id, callback) do
    case operation["group_id"] do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        case Repo.get(Group, group_id) do
          nil -> reject(operation_id, "group_not_found")
          group -> check_revision(operation, operation_id, group, callback)
        end

      _ ->
        reject(operation_id, "invalid_operation")
    end
  end

  defp check_revision(operation, operation_id, group, callback) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      reject(operation_id, "stale_revision", %{
        group_id: group.group_id,
        expected_revision: operation["expected_revision"],
        actual_revision: group.revision
      })
    else
      callback.(operation, operation_id, group)
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    cond do
      not (Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents")) ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        reject(operation_id, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]

        group =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount
          })

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group),
          revision: group.revision
        })
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    cond do
      not (Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "new_arrival_on")) ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
             :gt <- Date.compare(new_arrival_on, occurred_on) do
          shift = Date.diff(new_arrival_on, group.arrival_on)

          group =
            update_group!(group, %{
              arrival_on: new_arrival_on,
              departure_on: Date.add(group.departure_on, shift)
            })

          applied(operation_id, %{
            group_id: group.group_id,
            new_arrival_on: group.arrival_on,
            new_departure_on: group.departure_on,
            policy_version: group.policy_version,
            refundable_until: refundable_until(group),
            revision: group.revision
          })
        else
          _ -> reject(operation_id, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, operation_id, group) do
    refund_method = Map.get(operation, "refund_method", "cash")

    cond do
      not Map.has_key?(operation, "occurred_on") ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      refund_method not in ["cash", "hotel_credit"] ->
        reject(operation_id, "invalid_operation")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            settle_cancellation(operation_id, group, occurred_on, refund_method)

          :error ->
            reject(operation_id, "invalid_operation")
        end
    end
  end

  defp settle_cancellation(operation_id, group, occurred_on, refund_method) do
    refundable = refundable?(group, occurred_on)

    if not refundable and refund_method == "hotel_credit" do
      reject(operation_id, "refund_method_not_available")
    end

    {refunded, retained, converted, credit_issued} =
      cancellation_cash_settlement(group.cash_paid_cents, refundable, refund_method)

    if credit_issued > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 365)
      })
    end

    settle_allocated_credit(group, occurred_on, refundable)

    group =
      update_group!(group, %{
        status: "cancelled",
        refunded_cents: refunded,
        retained_cents: retained,
        cash_converted_to_credit_cents: converted
      })

    applied(operation_id, %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued,
      revision: group.revision
    })
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    cond do
      not (Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents")) ->
        reject(operation_id, "invalid_operation")

      group.status != "active" ->
        reject(operation_id, "group_not_active")

      not valid_date?(operation["occurred_on"]) ->
        reject(operation_id, "invalid_operation")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        reject(operation_id, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        reject(operation_id, "payment_exceeds_outstanding")

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        amount = operation["amount_cents"]
        lots = available_lots(group.guest_id, occurred_on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          reject(operation_id, "insufficient_credit")
        else
          allocate_credit!(group, lots, amount)

          group =
            update_group!(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: group.credit_paid_cents + amount
            })

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount,
            outstanding_deposit_cents: outstanding(group),
            revision: group.revision
          })
        end
    end
  end

  defp cancellation_cash_settlement(cash, true, "cash"), do: {cash, 0, 0, 0}

  defp cancellation_cash_settlement(cash, true, "hotel_credit") do
    issued = cash + div(cash * 10 + 50, 100)
    {0, 0, cash, issued}
  end

  defp cancellation_cash_settlement(cash, false, "cash"), do: {0, cash, 0, 0}

  defp settle_allocated_credit(group, occurred_on, refundable) do
    CreditAllocation
    |> where([allocation], allocation.group_id == ^group.group_id)
    |> preload(:credit_lot)
    |> Repo.all()
    |> Enum.each(fn allocation ->
      if refundable and Date.compare(allocation.credit_lot.expires_on, occurred_on) != :lt do
        lot = Repo.get!(CreditLot, allocation.credit_lot_id)

        lot
        |> Ecto.Changeset.change(%{
          remaining_cents: lot.remaining_cents + allocation.amount_cents
        })
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp available_lots(guest_id, on) do
    CreditLot
    |> where(
      [lot],
      lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on
    )
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
    |> Repo.all()
  end

  defp allocate_credit!(group, lots, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)

      lot
      |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents - used})
      |> Repo.update!()

      Repo.insert!(%CreditAllocation{
        group_id: group.group_id,
        credit_lot_id: lot.id,
        amount_cents: used
      })

      if used == remaining, do: {:halt, 0}, else: {:cont, remaining - used}
    end)
  end

  defp credit_liability(on) do
    available =
      CreditLot
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on >= ^on)
      |> select([lot], lot.remaining_cents)
      |> Repo.all()
      |> Enum.sum()

    allocated =
      CreditAllocation
      |> join(:inner, [allocation], group in Group,
        on: group.group_id == allocation.group_id and group.status == "active"
      )
      |> select([allocation, _group], allocation.amount_cents)
      |> Repo.all()
      |> Enum.sum()

    available + allocated
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(_group), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(occurred_on, cutoff) != :gt
    end
  end

  defp update_group!(group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp valid_required_fields?(operation, fields) do
    is_map(operation) and
      Enum.all?(fields, fn field ->
        Map.has_key?(operation, field) and not is_nil(operation[field])
      end) and
      Enum.all?(~w(operation_id group_id guest_id property_id), fn field ->
        is_binary(operation[field]) and byte_size(operation[field]) > 0
      end)
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(rate) and rate > 0 and
               rate <= @max_sqlite_integer ->
          true

        _ ->
          false
      end)

    unique = Enum.uniq_by(rooms, &Map.get(&1, "room_id")) == rooms

    if valid and unique, do: {:ok, rooms}, else: {:error, "invalid_rooms"}
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp lodging_total(rooms, nights) do
    Enum.sum(Enum.map(rooms, &(&1["nightly_rate_cents"] * nights)))
  end

  defp calculate_totals(rooms, nights, rate_plan) do
    lodging_total = lodging_total(rooms, nights)
    deposit_due = deposit_due(rooms, nights, rate_plan)

    if lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer do
      {:ok, lodging_total, deposit_due}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp deposit_due(rooms, nights, "advance_purchase"), do: lodging_total(rooms, nights)

  defp deposit_due(rooms, nights, "flexible") do
    Enum.sum(
      Enum.map(rooms, fn room ->
        lodging = room["nightly_rate_cents"] * nights
        div(lodging * 20 + 50, 100)
      end)
    )
  end

  defp outstanding(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error

  defp valid_date?(value), do: match?({:ok, _date}, parse_date(value))

  defp operation_id(%{"operation_id" => operation_id}), do: operation_id
  defp operation_id(_), do: nil

  defp with_operation_id(operation_id, callback)
       when is_binary(operation_id) and byte_size(operation_id) > 0,
       do: callback.()

  defp with_operation_id(operation_id, _callback), do: reject(operation_id, "invalid_operation")

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp reject(operation_id, code, fields \\ %{}) do
    result = Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
    Repo.rollback(result)
  end
end
