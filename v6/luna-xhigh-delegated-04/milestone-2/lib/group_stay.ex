defmodule GroupStay do
  @moduledoc """
  GroupStay keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, Repo, Room}

  @valid_rate_plans ["flexible", "advance_purchase"]
  @active_status "active"
  @cancelled_status "cancelled"
  @policy_cutover ~D[2027-01-01]

  @doc """
  Applies one partner operation. Each invocation is its own transaction so a rejected
  operation cannot undo an earlier operation in the same batch.
  """
  def apply_operation(operation) when is_map(operation) do
    if valid_operation_id?(operation) do
      case Map.get(operation, "type") do
        "open_group" ->
          run_group_transaction(operation, fn -> open_group(operation) end)

        "record_cash_payment" ->
          run_group_transaction(operation, fn -> update_group(operation, :payment) end)

        "reschedule_group" ->
          run_group_transaction(operation, fn -> update_group(operation, :reschedule) end)

        "cancel_group" ->
          run_group_transaction(operation, fn -> update_group(operation, :cancel) end)

        "apply_hotel_credit" ->
          run_group_transaction(operation, fn -> update_group(operation, :hotel_credit) end)

        _ ->
          {:error, rejection(operation, "invalid_operation")}
      end
    else
      {:error, rejection(operation, "invalid_operation")}
    end
  end

  def apply_operation(operation), do: {:error, rejection(operation, "invalid_operation")}

  @doc "Returns a serialized group or `:group_not_found`."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  @doc "Returns credit available to a guest as of the supplied UTC date."
  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, as_of)

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

  @doc "Returns the finance totals as of the supplied UTC date."
  def ledger_totals(as_of \\ Date.utc_today()) do
    group_totals =
      Repo.all(
        from group in Group,
          select: {
            group.status,
            group.cash_paid_cents,
            group.cash_refunded_cents,
            group.cash_retained_cents
          }
      )

    totals =
      Enum.reduce(
        group_totals,
        %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
        fn
          {@active_status, paid, _refunded, _retained}, totals ->
            %{totals | cash_held_cents: totals.cash_held_cents + paid}

          {_status, _paid, refunded, retained}, totals ->
            %{
              totals
              | cash_refunded_cents: totals.cash_refunded_cents + refunded,
                cash_retained_cents: totals.cash_retained_cents + retained
            }
        end
      )

    Map.merge(totals, %{
      cash_converted_to_credit_cents: cash_converted_to_credit_cents(),
      credit_liability_cents: credit_liability_cents(as_of)
    })
  end

  defp cash_converted_to_credit_cents do
    Repo.one(
      from lot in CreditLot,
        select: coalesce(sum(lot.cash_converted_cents), 0)
    )
  end

  defp credit_liability_cents(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.issued_on <= ^as_of and lot.expires_on > ^as_of,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where: group.status == @active_status and lot.issued_on <= ^as_of,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp run_transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # SQLite does not provide row-level SELECT ... FOR UPDATE locking. Serializing
  # operations makes the read/check/write revision sequence and guest-credit
  # consumption atomic within this application node, while the database remains
  # the authority for group identity.
  defp run_group_transaction(operation, fun) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        :global.trans({__MODULE__, :operations}, fn ->
          run_transaction(fun)
        end)

      _group_id ->
        run_transaction(fun)
    end
  end

  defp open_group(operation) do
    with :ok <- require_identifier(operation, "group_id"),
         :ok <- ensure_group_does_not_exist(operation["group_id"], operation),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], "invalid_operation", operation),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay", operation),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay", operation),
         :ok <- validate_stay(arrival_on, departure_on, operation),
         :ok <- validate_open_identifiers(operation),
         :ok <- validate_rate_plan(operation["rate_plan"], operation),
         {:ok, rooms} <- normalize_rooms(operation["rooms"], arrival_on, departure_on, operation),
         {:ok, group} <- insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "deposit_due_cents" => group.deposit_due_cents,
         "revision" => group.revision
       }}
    end
  end

  defp update_group(operation, kind) do
    with {:ok, group} <- existing_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- validate_active(group, operation),
         result <- apply_group_update(group, operation, kind) do
      result
    end
  end

  defp apply_group_update(group, operation, :payment) do
    with :ok <- validate_occurred_on(operation),
         :ok <- validate_amount(operation["amount_cents"], operation),
         :ok <- validate_payment_amount(group, operation["amount_cents"], operation),
         {:ok, updated_group} <-
           increment_group(
             group,
             %{
               deposit_paid_cents: group.deposit_paid_cents + operation["amount_cents"],
               cash_paid_cents: group.cash_paid_cents + operation["amount_cents"]
             },
             operation
           ) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => operation["amount_cents"],
         "outstanding_deposit_cents" => outstanding_deposit(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp apply_group_update(group, operation, :reschedule) do
    with :ok <- validate_occurred_on(operation),
         {:ok, new_arrival_on} <-
           parse_date(operation["new_arrival_on"], "invalid_stay", operation),
         :ok <- validate_rescheduled_arrival(new_arrival_on, operation["occurred_on"], operation),
         new_departure_on <-
           Date.add(group.departure_on, Date.diff(new_arrival_on, group.arrival_on)),
         {:ok, updated_group} <-
           increment_group(
             group,
             %{
               arrival_on: new_arrival_on,
               departure_on: new_departure_on
             },
             operation
           ) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
         "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
         "policy_version" => effective_policy_version(updated_group),
         "refundable_until" => refundable_until(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp apply_group_update(group, operation, :hotel_credit) do
    with {:ok, occurred_on} <-
           parse_date(operation["occurred_on"], "invalid_operation", operation),
         :ok <- validate_amount(operation["amount_cents"], operation),
         :ok <- validate_payment_amount(group, operation["amount_cents"], operation),
         {:ok, allocations} <-
           credit_allocations_for(
             group.guest_id,
             operation["amount_cents"],
             occurred_on,
             operation
           ),
         {:ok, updated_group} <-
           increment_group(
             group,
             %{
               deposit_paid_cents: group.deposit_paid_cents + operation["amount_cents"],
               credit_paid_cents: group.credit_paid_cents + operation["amount_cents"]
             },
             operation
           ),
         :ok <- persist_credit_allocations(group, allocations) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => operation["amount_cents"],
         "outstanding_deposit_cents" => outstanding_deposit(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp apply_group_update(group, operation, :cancel) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay", operation),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- validate_refund_method_available(group, refund_method, occurred_on, operation),
         {:ok, updated_group, credit_issued_cents} <-
           settle_cancellation(group, occurred_on, refund_method, operation) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "refunded_cents" => updated_group.cash_refunded_cents,
         "retained_cents" => updated_group.cash_retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => updated_group.revision
       }}
    end
  end

  defp existing_group(operation) do
    group_id = Map.get(operation, "group_id")

    cond do
      not valid_identifier?(group_id) ->
        {:error, rejection(operation, "invalid_operation")}

      true ->
        case Repo.get(Group, group_id) do
          nil -> {:error, rejection(operation, "group_not_found")}
          group -> {:ok, group}
        end
    end
  end

  defp check_expected_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       rejection(operation, "stale_revision", %{
         "group_id" => group.group_id,
         "expected_revision" => operation["expected_revision"],
         "actual_revision" => group.revision
       })}
    else
      :ok
    end
  end

  defp validate_active(%Group{status: @active_status}, _operation), do: :ok
  defp validate_active(_group, operation), do: {:error, rejection(operation, "group_not_active")}

  defp validate_occurred_on(operation) do
    case parse_date(Map.get(operation, "occurred_on"), "invalid_operation", operation) do
      {:ok, _date} -> :ok
      error -> error
    end
  end

  defp validate_amount(amount, _operation) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount, operation), do: {:error, rejection(operation, "invalid_amount")}

  defp validate_payment_amount(group, amount, operation) do
    if amount <= outstanding_deposit(group) do
      :ok
    else
      {:error, rejection(operation, "payment_exceeds_outstanding")}
    end
  end

  defp validate_rescheduled_arrival(new_arrival_on, occurred_on, operation) do
    case parse_date(occurred_on, "invalid_stay", operation) do
      {:ok, occurred_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          :ok
        else
          {:error, rejection(operation, "invalid_stay")}
        end

      error ->
        error
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _method -> {:error, rejection(operation, "invalid_refund_method")}
    end
  end

  defp validate_refund_method_available(group, "hotel_credit", occurred_on, operation) do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, rejection(operation, "refund_method_not_available")}
    end
  end

  defp validate_refund_method_available(_group, "cash", _occurred_on, _operation), do: :ok

  defp settle_cancellation(group, occurred_on, refund_method, operation) do
    refundable? = refundable?(group, occurred_on)
    settle_applied_credit(group, occurred_on, refundable?)

    {refunded, retained, credit_issued_cents} =
      cond do
        refundable? and refund_method == "cash" ->
          {group.cash_paid_cents, 0, 0}

        refundable? and refund_method == "hotel_credit" ->
          {0, 0, issue_credit_lot(group, occurred_on, operation)}

        true ->
          {0, group.cash_paid_cents, 0}
      end

    case increment_group(
           group,
           %{
             status: @cancelled_status,
             cash_refunded_cents: refunded,
             cash_retained_cents: retained
           },
           operation
         ) do
      {:ok, updated_group} -> {:ok, updated_group, credit_issued_cents}
      error -> error
    end
  end

  defp refundable?(group, occurred_on) do
    case policy_window(effective_policy_version(group)) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp settle_applied_credit(group, occurred_on, refundable?) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id
      )

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {credit_lot_id, lot_allocations} ->
      lot = Repo.get!(CreditLot, credit_lot_id)
      allocated_cents = Enum.sum(Enum.map(lot_allocations, & &1.amount_cents))

      if refundable? and credit_available_on?(lot.expires_on, occurred_on) do
        update_credit_lot!(lot, lot.remaining_cents + allocated_cents)
      end

      Enum.each(lot_allocations, &Repo.delete!/1)
    end)

    :ok
  end

  defp issue_credit_lot(group, occurred_on, operation) do
    cash_amount = group.cash_paid_cents
    bonus = percentage_amount(cash_amount, 10)
    amount = cash_amount + bonus

    if amount > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: amount,
        expires_on: Date.add(occurred_on, 366),
        cash_converted_cents: cash_amount,
        issued_on: occurred_on
      })
    end

    amount
  end

  defp credit_allocations_for(guest_id, amount, occurred_on, operation) do
    lots = available_credit_lots(guest_id, occurred_on)
    available = Enum.sum(Enum.map(lots, & &1.remaining_cents))

    if available < amount do
      {:error, rejection(operation, "insufficient_credit")}
    else
      {allocations, _remaining} =
        Enum.reduce_while(lots, {[], amount}, fn lot, {allocations, remaining} ->
          amount_from_lot = min(lot.remaining_cents, remaining)

          if amount_from_lot == 0 do
            {:cont, {allocations, remaining}}
          else
            allocation = %{lot: lot, amount_cents: amount_from_lot}
            remaining = remaining - amount_from_lot

            if remaining == 0 do
              {:halt, {[allocation | allocations], remaining}}
            else
              {:cont, {[allocation | allocations], remaining}}
            end
          end
        end)

      {:ok, Enum.reverse(allocations)}
    end
  end

  defp persist_credit_allocations(group, allocations) do
    Enum.each(allocations, fn %{lot: lot, amount_cents: amount} ->
      update_credit_lot!(lot, lot.remaining_cents - amount)

      Repo.insert!(%CreditAllocation{
        group_id: group.group_id,
        credit_lot_id: lot.id,
        amount_cents: amount
      })
    end)

    :ok
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^as_of and
            lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp credit_available_on?(expires_on, on) do
    Date.compare(expires_on, on) == :gt
  end

  defp update_credit_lot!(lot, remaining_cents) do
    lot
    |> Ecto.Changeset.change(remaining_cents: remaining_cents)
    |> Repo.update!()
  end

  defp increment_group(group, attrs, operation) do
    changes =
      attrs
      |> Map.put(:revision, group.revision + 1)
      |> then(&Ecto.Changeset.change(group, &1))

    case Repo.update(changes) do
      {:ok, updated_group} -> {:ok, updated_group}
      {:error, _changeset} -> {:error, rejection(operation, "invalid_operation")}
    end
  end

  defp ensure_group_does_not_exist(group_id, operation) do
    if Repo.exists?(from group in Group, where: group.group_id == ^group_id) do
      {:error, rejection(operation, "group_already_exists")}
    else
      :ok
    end
  end

  defp validate_open_identifiers(operation) do
    if valid_identifier?(Map.get(operation, "guest_id")) and
         valid_identifier?(Map.get(operation, "property_id")) do
      :ok
    else
      {:error, rejection(operation, "invalid_operation")}
    end
  end

  defp validate_rate_plan(rate_plan, _operation) when rate_plan in @valid_rate_plans, do: :ok

  defp validate_rate_plan(_rate_plan, operation),
    do: {:error, rejection(operation, "invalid_rate_plan")}

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on, operation) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, rejection(operation, "invalid_stay")}
    end
  end

  defp normalize_rooms(rooms, arrival_on, departure_on, operation) when is_list(rooms) do
    if rooms == [] do
      {:error, rejection(operation, "invalid_rooms")}
    else
      nights = Date.diff(departure_on, arrival_on)

      Enum.reduce_while(Enum.with_index(rooms), {:ok, [], MapSet.new()}, fn
        {room, position}, {:ok, normalized, seen_ids} when is_map(room) ->
          room_id = Map.get(room, "room_id")
          nightly_rate_cents = Map.get(room, "nightly_rate_cents")

          cond do
            not valid_identifier?(room_id) ->
              {:halt, {:error, rejection(operation, "invalid_rooms")}}

            MapSet.member?(seen_ids, room_id) ->
              {:halt, {:error, rejection(operation, "invalid_rooms")}}

            not (is_integer(nightly_rate_cents) and nightly_rate_cents > 0) ->
              {:halt, {:error, rejection(operation, "invalid_rooms")}}

            true ->
              room_amount = nights * nightly_rate_cents

              room_data = %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                lodging_amount_cents: room_amount
              }

              {:cont, {:ok, [room_data | normalized], MapSet.put(seen_ids, room_id)}}
          end

        {_room, _position}, _acc ->
          {:halt, {:error, rejection(operation, "invalid_rooms")}}
      end)
      |> case do
        {:ok, normalized, _seen_ids} -> {:ok, Enum.reverse(normalized)}
        error -> error
      end
    end
  end

  defp normalize_rooms(_rooms, _arrival_on, _departure_on, operation),
    do: {:error, rejection(operation, "invalid_rooms")}

  defp insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
    rate_plan = operation["rate_plan"]
    policy_version = policy_for(rate_plan, booked_on)

    lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_amount_cents))

    deposit_due_cents =
      rooms
      |> Enum.map(fn room -> deposit_for(room.lodging_amount_cents, rate_plan) end)
      |> Enum.sum()

    group_attrs = %{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      policy_version: policy_version,
      status: @active_status,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      revision: 1
    }

    case Repo.insert(struct(Group, group_attrs)) do
      {:ok, group} ->
        Enum.each(rooms, fn room ->
          Repo.insert!(%Room{
            group_id: group.group_id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position
          })
        end)

        {:ok, group}

      {:error, _changeset} ->
        {:error, rejection(operation, "group_already_exists")}
    end
  end

  defp deposit_for(lodging_amount_cents, "flexible"),
    do: percentage_amount(lodging_amount_cents, 20)

  defp deposit_for(lodging_amount_cents, "advance_purchase"), do: lodging_amount_cents

  defp percentage_amount(amount, percentage),
    do: div(amount * percentage + 50, 100)

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp effective_policy_version(%Group{
         policy_version: nil,
         rate_plan: rate_plan,
         booked_on: booked_on
       }),
       do: policy_for(rate_plan, booked_on)

  defp effective_policy_version(%Group{policy_version: policy_version}), do: policy_version

  defp policy_window("flex-14"), do: 14
  defp policy_window("flex-30"), do: 30
  defp policy_window(_policy_version), do: nil

  defp refundable_until(group) do
    case policy_window(effective_policy_version(group)) do
      nil -> nil
      window -> group.arrival_on |> Date.add(-window) |> Date.to_iso8601()
    end
  end

  defp parse_date(value, error_code, operation) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, rejection(operation, error_code)}
    end
  end

  defp parse_date(_value, error_code, operation), do: {:error, rejection(operation, error_code)}

  defp valid_operation_id?(operation),
    do: valid_identifier?(Map.get(operation, "operation_id"))

  defp require_identifier(operation, field) do
    if valid_identifier?(Map.get(operation, field)) do
      :ok
    else
      {:error, rejection(operation, "invalid_operation")}
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp outstanding_deposit(%Group{status: @active_status} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding_deposit(_group), do: 0

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: [asc: room.position],
          select: %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
      )
      |> Enum.map(&stringify_keys/1)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => effective_policy_version(group),
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "rooms" => rooms,
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group),
      "revision" => group.revision
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp rejection(operation, code, extra \\ %{}) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => code
    }
    |> Map.merge(extra)
  end
end
