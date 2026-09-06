defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations one at a time, preserving batch order.

  Each operation gets its own transaction. That lets a rejected operation roll
  back independently while retaining successful operations before and after it.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.{
    Group,
    HotelCreditAllocation,
    HotelCreditLot,
    Repo,
    Room
  }

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"

  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @new_policy_date ~D[2027-01-01]

  @spec submit_batch(term()) :: {:ok, [map()]} | {:error, :invalid_batch}
  def submit_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def submit_batch(_operations), do: {:error, :invalid_batch}

  @spec get_group(String.t()) :: {:ok, map()} | {:error, :group_not_found}
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group_view(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  @spec get_guest_credit(String.t(), String.t() | nil) :: {:ok, map()} | {:error, :invalid_date}
  def get_guest_credit(guest_id, on \\ nil)

  def get_guest_credit(guest_id, on) when is_binary(guest_id) do
    with {:ok, as_of} <- as_of_date(on) do
      lots = available_credit_lots(guest_id, as_of)

      {:ok,
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
       }}
    end
  end

  def get_guest_credit(_guest_id, _on), do: {:error, :invalid_date}

  @spec ledger_totals(String.t() | nil) :: map() | {:error, :invalid_date}
  def ledger_totals(on \\ nil) do
    with {:ok, as_of} <- as_of_date(on) do
      %{
        cash_held_cents: sum_for_status(@active, :cash_paid_cents),
        cash_refunded_cents: sum_for_status(@cancelled, :refunded_cents),
        cash_retained_cents: sum_for_status(@cancelled, :retained_cents),
        cash_converted_to_credit_cents: sum_for_field(:cash_converted_to_credit_cents),
        credit_liability_cents: credit_liability(as_of)
      }
    end
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")
    operation_type = value(operation, "type")

    if operation_type == "open_group" do
      process_open_group(operation, operation_id)
    else
      process_existing_group(operation, operation_id, operation_type)
    end
  end

  defp process_operation(_operation), do: rejection(nil, "invalid_operation")

  defp process_open_group(operation, operation_id) do
    group_id = value(operation, "group_id")

    cond do
      not identifier?(operation_id) ->
        rejection(operation_id, "invalid_operation")

      not identifier?(group_id) ->
        rejection(operation_id, "invalid_operation")

      true ->
        transaction_result(fn ->
          if Repo.get(Group, group_id) do
            reject(rejection(operation_id, "group_already_exists", %{group_id: group_id}))
          else
            case validate_open_group(operation) do
              {:ok, attrs, rooms} ->
                group = Repo.insert!(Group.changeset(%Group{}, attrs))
                insert_rooms!(group.group_id, rooms)

                {:ok,
                 applied("open_group", operation_id, %{
                   group_id: group.group_id,
                   deposit_due_cents: group.deposit_due_cents,
                   revision: group.revision
                 })}

              {:error, code} ->
                reject(rejection(operation_id, code, %{group_id: group_id}))
            end
          end
        end)
    end
  end

  defp process_existing_group(operation, operation_id, operation_type) do
    group_id = value(operation, "group_id")

    if not identifier?(group_id) do
      rejection(operation_id, "invalid_operation")
    else
      transaction_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            reject(rejection(operation_id, "group_not_found", %{group_id: group_id}))

          group ->
            case revision_check(operation, group) do
              :ok -> apply_existing(group, operation, operation_id, operation_type)
              {:error, stale} -> reject(stale)
            end
        end
      end)
    end
  end

  defp apply_existing(group, operation, operation_id, operation_type) do
    case operation_type do
      "record_cash_payment" ->
        apply_cash_payment(group, operation, operation_id)

      "apply_hotel_credit" ->
        apply_hotel_credit(group, operation, operation_id)

      "reschedule_group" ->
        apply_reschedule(group, operation, operation_id)

      "cancel_group" ->
        apply_cancellation(group, operation, operation_id)

      _ ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_cash_payment(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, _occurred_on} ->
            apply_cash_payment_amount(group, operation, operation_id)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_cash_payment_amount(group, operation, operation_id) do
    amount_cents = value(operation, "amount_cents")
    outstanding = outstanding_deposit(group)
    cash_paid = cash_paid(group)

    cond do
      not usable_amount?(amount_cents) ->
        reject(rejection(operation_id, "invalid_amount", %{group_id: group.group_id}))

      amount_cents > outstanding ->
        reject(
          rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})
        )

      true ->
        update_group!(group, %{
          deposit_paid_cents: deposit_paid(group) + amount_cents,
          cash_paid_cents: cash_paid + amount_cents,
          revision: group.revision + 1
        })

        {:ok,
         applied("record_cash_payment", operation_id, %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding - amount_cents,
           revision: group.revision + 1
         })}
    end
  end

  defp apply_hotel_credit(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, occurred_on} ->
            apply_hotel_credit_amount(group, operation, operation_id, occurred_on)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp apply_hotel_credit_amount(group, operation, operation_id, occurred_on) do
    amount_cents = value(operation, "amount_cents")
    outstanding = outstanding_deposit(group)

    cond do
      not usable_amount?(amount_cents) ->
        reject(rejection(operation_id, "invalid_amount", %{group_id: group.group_id}))

      amount_cents > outstanding ->
        reject(
          rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})
        )

      true ->
        lots = available_credit_lots(group.guest_id, occurred_on)

        case credit_allocation(lots, amount_cents) do
          {:error, :insufficient_credit} ->
            reject(rejection(operation_id, "insufficient_credit", %{group_id: group.group_id}))

          {:ok, allocations} ->
            consume_credit!(group.group_id, allocations)

            update_group!(group, %{
              deposit_paid_cents: deposit_paid(group) + amount_cents,
              credit_paid_cents: credit_paid(group) + amount_cents,
              revision: group.revision + 1
            })

            {:ok,
             applied("apply_hotel_credit", operation_id, %{
               group_id: group.group_id,
               amount_cents: amount_cents,
               outstanding_deposit_cents: outstanding - amount_cents,
               revision: group.revision + 1
             })}
        end
    end
  end

  defp apply_reschedule(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))

          {:ok, occurred_on} ->
            reschedule_from(group, operation, operation_id, occurred_on)
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp reschedule_from(group, operation, operation_id, occurred_on) do
    with {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         true <- Date.compare(new_arrival_on, occurred_on) == :gt do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      policy_version = group_policy_version(group)
      refundable_until = refundable_until(policy_version, new_arrival_on)

      update_group!(group, %{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        refundable_until: refundable_until,
        revision: group.revision + 1
      })

      {:ok,
       applied("reschedule_group", operation_id, %{
         group_id: group.group_id,
         new_arrival_on: Date.to_iso8601(new_arrival_on),
         new_departure_on: Date.to_iso8601(new_departure_on),
         policy_version: policy_version,
         refundable_until: date_value(refundable_until),
         revision: group.revision + 1
       })}
    else
      _ -> reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))
    end
  end

  defp apply_cancellation(group, operation, operation_id) do
    with :ok <- validate_operation_id(operation_id) do
      if group.status != @active do
        reject(rejection(operation_id, "group_not_active", %{group_id: group.group_id}))
      else
        case operation_date(operation) do
          {:ok, occurred_on} ->
            cancel_from(group, operation, operation_id, occurred_on)

          {:error, "invalid_operation"} ->
            reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

          {:error, "invalid_stay"} ->
            reject(rejection(operation_id, "invalid_stay", %{group_id: group.group_id}))
        end
      end
    else
      {:error, "invalid_operation"} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))
    end
  end

  defp cancel_from(group, operation, operation_id, occurred_on) do
    case refund_method(operation) do
      {:error, :invalid_refund_method} ->
        reject(rejection(operation_id, "invalid_operation", %{group_id: group.group_id}))

      {:ok, refund_method} ->
        refundable? = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable? do
          reject(
            rejection(operation_id, "refund_method_not_available", %{group_id: group.group_id})
          )
        else
          cash_paid = cash_paid(group)
          refunded_cents = if refundable? and refund_method == "cash", do: cash_paid, else: 0
          retained_cents = if refundable?, do: 0, else: cash_paid
          credit_issued_cents = credit_issued(refundable?, refund_method, cash_paid)

          settle_credit_allocations!(group.group_id, occurred_on, refundable?)

          if credit_issued_cents > 0 do
            issue_credit_lot!(group.guest_id, operation_id, credit_issued_cents, occurred_on)
          end

          cash_converted_to_credit_cents =
            if credit_issued_cents > 0, do: cash_paid, else: 0

          update_group!(group, %{
            status: @cancelled,
            refunded_cents: refunded_cents,
            retained_cents: retained_cents,
            cash_converted_to_credit_cents: cash_converted_to_credit_cents,
            revision: group.revision + 1
          })

          {:ok,
           applied("cancel_group", operation_id, %{
             group_id: group.group_id,
             refunded_cents: refunded_cents,
             retained_cents: retained_cents,
             credit_issued_cents: credit_issued_cents,
             revision: group.revision + 1
           })}
        end
    end
  end

  defp validate_open_group(operation) do
    with {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, rate_plan} <- valid_rate_plan(value(operation, "rate_plan")),
         {:ok, rooms} <- valid_rooms(value(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total_cents = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))

      deposit_due_cents =
        rooms
        |> Enum.map(fn room ->
          lodging = room.nightly_rate_cents * nights

          case rate_plan do
            @flexible -> round_percentage(lodging, 20)
            @advance_purchase -> lodging
          end
        end)
        |> Enum.sum()

      policy_version = policy_version(rate_plan, booked_on)

      attrs = %{
        group_id: value(operation, "group_id"),
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version,
        refundable_until: refundable_until(policy_version, arrival_on),
        status: @active,
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0
      }

      {:ok, attrs, rooms}
    else
      {:error, "invalid_operation"} -> {:error, "invalid_operation"}
      {:error, "invalid_stay"} -> {:error, "invalid_stay"}
      {:error, "invalid_rooms"} -> {:error, "invalid_rooms"}
      {:error, "invalid_rate_plan"} -> {:error, "invalid_rate_plan"}
      false -> {:error, "invalid_stay"}
    end
  end

  defp valid_rate_plan(@flexible), do: {:ok, @flexible}
  defp valid_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(Enum.with_index(rooms), {:ok, MapSet.new(), []}, fn
      {room, position}, {:ok, room_ids, valid} when is_map(room) ->
        room_id = value(room, "room_id")
        nightly_rate_cents = value(room, "nightly_rate_cents")

        cond do
          not identifier?(room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          MapSet.member?(room_ids, room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          not is_integer(nightly_rate_cents) or nightly_rate_cents < 0 ->
            {:halt, {:error, "invalid_rooms"}}

          true ->
            {:cont,
             {:ok, MapSet.put(room_ids, room_id),
              [
                %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}
                | valid
              ]}}
        end

      _room, _acc ->
        {:halt, {:error, "invalid_rooms"}}
    end)
    |> case do
      {:ok, _room_ids, rooms} -> {:ok, Enum.reverse(rooms)}
      error -> error
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp required_identifier(operation, key) do
    case value(operation, key) do
      identifier when is_binary(identifier) and identifier != "" -> {:ok, identifier}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(operation, key) do
    case value(operation, key) do
      date when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp operation_date(operation) do
    case value(operation, "occurred_on") do
      nil ->
        {:error, "invalid_operation"}

      date when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp refund_method(operation) do
    case present_value(operation, "refund_method") do
      :missing -> {:ok, "cash"}
      {:present, "cash"} -> {:ok, "cash"}
      {:present, "hotel_credit"} -> {:ok, "hotel_credit"}
      _ -> {:error, :invalid_refund_method}
    end
  end

  defp validate_operation_id(operation_id) when is_binary(operation_id) and operation_id != "",
    do: :ok

  defp validate_operation_id(_operation_id), do: {:error, "invalid_operation"}

  defp identifier?(identifier) when is_binary(identifier), do: identifier != ""
  defp identifier?(_identifier), do: false

  defp revision_check(operation, group) do
    case present_value(operation, "expected_revision") do
      :missing ->
        :ok

      {:present, expected_revision} when expected_revision == group.revision ->
        :ok

      {:present, expected_revision} ->
        {:error,
         rejection(value(operation, "operation_id"), "stale_revision", %{
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         })}
    end
  end

  defp transaction_result(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback({:rejected, result})
             result -> result
           end
         end) do
      {:ok, result} -> result
      {:error, {:rejected, result}} -> result
    end
  end

  defp reject(result), do: {:error, result}

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update!()
  end

  defp insert_rooms!(group_id, rooms) do
    Repo.insert_all(
      Room,
      Enum.map(rooms, fn room -> Map.put(room, :group_id, group_id) end)
    )
  end

  defp group_view(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.position
      )

    policy_version = group_policy_version(group)
    cash_paid_cents = cash_paid(group)
    credit_paid_cents = credit_paid(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version,
      refundable_until:
        date_value(group.refundable_until || refundable_until(policy_version, group.arrival_on)),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: deposit_paid(group),
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp outstanding_deposit(%Group{status: @cancelled}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - deposit_paid(group), 0)

  defp sum_for_status(status, field_name) do
    Repo.one(
      from group in Group,
        where: group.status == ^status,
        select: coalesce(sum(field(group, ^field_name)), 0)
    )
  end

  defp sum_for_field(field_name) do
    Repo.one(from group in Group, select: coalesce(sum(field(group, ^field_name)), 0))
  end

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in HotelCreditLot,
          where: lot.issued_on <= ^as_of and lot.expires_on > ^as_of and lot.remaining_cents > 0,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied = sum_for_status(@active, :credit_paid_cents)
    available + applied
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in HotelCreditLot,
        where:
          lot.guest_id == ^guest_id and lot.issued_on <= ^as_of and lot.expires_on > ^as_of and
            lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp credit_allocation(lots, amount_cents) do
    {allocations, remaining} =
      Enum.reduce_while(lots, {[], amount_cents}, fn lot, {allocations, remaining} ->
        used = min(lot.remaining_cents, remaining)

        if used == remaining do
          {:halt, {[{lot, used} | allocations], 0}}
        else
          {:cont, {[{lot, used} | allocations], remaining - used}}
        end
      end)

    if remaining == 0 do
      {:ok, Enum.reverse(allocations)}
    else
      {:error, :insufficient_credit}
    end
  end

  defp consume_credit!(group_id, allocations) do
    Repo.insert_all(
      HotelCreditAllocation,
      Enum.map(allocations, fn {lot, amount_cents} ->
        %{group_id: group_id, credit_lot_id: lot.id, amount_cents: amount_cents}
      end)
    )

    Enum.each(allocations, fn {lot, amount_cents} ->
      lot
      |> change(remaining_cents: lot.remaining_cents - amount_cents)
      |> Repo.update!()
    end)
  end

  defp settle_credit_allocations!(group_id, occurred_on, refundable?) do
    allocations =
      Repo.all(
        from allocation in HotelCreditAllocation,
          join: lot in HotelCreditLot,
          on: lot.id == allocation.credit_lot_id,
          where: allocation.group_id == ^group_id,
          select: {allocation.amount_cents, lot}
      )

    if refundable? do
      Enum.each(allocations, fn {amount_cents, lot} ->
        if Date.compare(lot.expires_on, occurred_on) == :gt do
          lot
          |> change(remaining_cents: lot.remaining_cents + amount_cents)
          |> Repo.update!()
        end
      end)
    end

    Repo.delete_all(
      from allocation in HotelCreditAllocation, where: allocation.group_id == ^group_id
    )
  end

  defp issue_credit_lot!(guest_id, source_operation_id, amount_cents, cancelled_on) do
    Repo.insert!(%HotelCreditLot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      issued_on: cancelled_on,
      expires_on: Date.add(cancelled_on, 366)
    })
  end

  defp credit_issued(true, "hotel_credit", cash_paid), do: round_percentage(cash_paid, 110)
  defp credit_issued(_refundable?, _refund_method, _cash_paid), do: 0

  defp refundable?(group, occurred_on) do
    case group_policy_version(group) do
      @flex_14 -> Date.compare(occurred_on, refundable_until(@flex_14, group.arrival_on)) != :gt
      @flex_30 -> Date.compare(occurred_on, refundable_until(@flex_30, group.arrival_on)) != :gt
      _ -> false
    end
  end

  defp policy_version(rate_plan, booked_on) do
    case rate_plan do
      @advance_purchase ->
        @advance_nonrefundable

      @flexible ->
        if Date.compare(booked_on, @new_policy_date) == :lt, do: @flex_14, else: @flex_30
    end
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when is_binary(policy_version),
       do: policy_version

  defp group_policy_version(group), do: policy_version(group.rate_plan, group.booked_on)

  defp refundable_until(@flex_14, arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until(@flex_30, arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(@advance_nonrefundable, _arrival_on), do: nil

  defp cash_paid(%Group{cash_paid_cents: cash_paid_cents}) when is_integer(cash_paid_cents),
    do: cash_paid_cents

  defp cash_paid(group), do: group.deposit_paid_cents

  defp credit_paid(%Group{credit_paid_cents: credit_paid_cents})
       when is_integer(credit_paid_cents),
       do: credit_paid_cents

  defp credit_paid(_group), do: 0

  defp deposit_paid(group), do: cash_paid(group) + credit_paid(group)

  defp as_of_date(nil), do: {:ok, Date.utc_today()}

  defp as_of_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp as_of_date(_date), do: {:error, :invalid_date}

  defp date_value(nil), do: nil
  defp date_value(date), do: Date.to_iso8601(date)

  defp usable_amount?(amount_cents), do: is_integer(amount_cents) and amount_cents > 0

  defp round_percentage(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
  end

  defp applied(_type, operation_id, attrs) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, attrs)
  end

  defp rejection(operation_id, code, attrs \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, attrs)
  end

  defp value(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> nil
    end
  end

  defp present_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:present, Map.get(map, String.to_atom(key))}
      true -> :missing
    end
  end
end
