defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Groups.{CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"

  @doc """
  Applies a partner batch in order. Each operation has its own transaction so a
  rejected operation cannot undo an earlier operation in the same batch.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, serialize_group(load_rooms(group))}
    end
  end

  def get_group(_group_id), do: :not_found

  def ledger(on_date \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        %{
          "cash_held_cents" => sum_groups(@active, :cash_paid_cents),
          "cash_refunded_cents" => sum_groups(@cancelled, :refunded_cents),
          "cash_retained_cents" => sum_groups(@cancelled, :retained_cents),
          "cash_converted_to_credit_cents" =>
            sum_groups(@cancelled, :cash_converted_to_credit_cents),
          "credit_liability_cents" => credit_liability(on_date)
        }
      end)

    totals
  end

  def guest_credit(guest_id, on_date \\ Date.utc_today())

  def guest_credit(guest_id, on_date) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^on_date and
              lot.expires_on >= ^on_date,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      "lots" => Enum.map(lots, &serialize_credit_lot/1)
    }
  end

  def guest_credit(guest_id, _on_date) do
    %{"guest_id" => guest_id, "available_cents" => 0, "lots" => []}
  end

  defp process_operation(operation) do
    case Repo.transaction(
           fn ->
             case execute_operation(operation) do
               {:rejected, result} -> Repo.rollback({:rejected, result})
               applied -> applied
             end
           end,
           mode: :immediate
         ) do
      {:ok, {:applied, result}} -> result
      {:error, {:rejected, result}} -> result
    end
  end

  defp execute_operation(operation) when is_map(operation) do
    case field(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp execute_operation(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         :ok <- ensure_group_missing(group_id),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_stay"),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on"), "invalid_stay"),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on"), "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(field(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
      stay_length = Date.diff(departure_on, arrival_on)
      lodging_total_cents = calculate_lodging(rooms, stay_length)
      deposit_due_cents = calculate_deposit(rooms, rate_plan, stay_length)
      policy_version = policy_version(rate_plan, occurred_on)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version,
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

      case insert_group(attrs, rooms) do
        :ok ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           })}

        :already_exists ->
          reject(operation, "group_already_exists")

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, _occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- validate_payment_amount(amount_cents, group) do
      updated_group = %{
        group
        | deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: group.cash_paid_cents + amount_cents,
          revision: group.revision + 1
      }

      case update_group(group, %{
             deposit_paid_cents: updated_group.deposit_paid_cents,
             cash_paid_cents: updated_group.cash_paid_cents,
             revision: updated_group.revision
           }) do
        {:ok, _group} ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "amount_cents" => amount_cents,
             "outstanding_deposit_cents" => outstanding(updated_group),
             "revision" => updated_group.revision
           })}

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp apply_hotel_credit(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- validate_payment_amount(amount_cents, group),
         {:ok, lots} <- available_credit_lots(group.guest_id, amount_cents, occurred_on) do
      new_revision = group.revision + 1
      allocation_plan = build_allocation_plan(lots, amount_cents)

      case apply_credit_allocations(group, allocation_plan) do
        :ok ->
          updated_group = %{
            group
            | deposit_paid_cents: group.deposit_paid_cents + amount_cents,
              credit_paid_cents: group.credit_paid_cents + amount_cents,
              revision: new_revision
          }

          case update_group(group, %{
                 deposit_paid_cents: updated_group.deposit_paid_cents,
                 credit_paid_cents: updated_group.credit_paid_cents,
                 revision: updated_group.revision
               }) do
            {:ok, _group} ->
              {:applied,
               result(operation, "applied")
               |> Map.merge(%{
                 "group_id" => group_id,
                 "amount_cents" => amount_cents,
                 "outstanding_deposit_cents" => outstanding(updated_group),
                 "revision" => updated_group.revision
               })}

            :error ->
              reject(operation, "invalid_operation")
          end

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp reschedule_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_stay"),
         {:ok, new_arrival_on} <-
           parse_date(field(operation, "new_arrival_on"), "invalid_stay"),
         :ok <- validate_rescheduled_stay(occurred_on, new_arrival_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      updated_group = %{
        group
        | arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
      }

      case update_group(group, %{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: updated_group.revision
           }) do
        {:ok, _group} ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "new_arrival_on" => Date.to_iso8601(new_arrival_on),
             "new_departure_on" => Date.to_iso8601(new_departure_on),
             "policy_version" => policy_version(group),
             "refundable_until" =>
               refundable_until(%{
                 group
                 | arrival_on: new_arrival_on,
                   policy_version: policy_version(group)
               }),
             "revision" => updated_group.revision
           })}

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp cancel_group(operation) do
    with :ok <- validate_common(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(operation, group),
         :ok <- validate_active(group),
         {:ok, occurred_on} <- parse_date(field(operation, "occurred_on"), "invalid_operation"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, settlement} <- cancellation_settlement(group, occurred_on, refund_method) do
      if settlement.refundable do
        restore_credit_allocations(group, occurred_on)
      else
        consume_credit_allocations(group)
      end

      if settlement.credit_issued_cents > 0 do
        insert_credit_lot!(%{
          guest_id: group.guest_id,
          source_operation_id: field(operation, "operation_id"),
          remaining_cents: settlement.credit_issued_cents,
          issued_on: occurred_on,
          expires_on: Date.add(occurred_on, 365)
        })
      end

      updated_group = %{
        group
        | status: @cancelled,
          refunded_cents: settlement.refunded_cents,
          retained_cents: settlement.retained_cents,
          cash_converted_to_credit_cents: settlement.cash_converted_to_credit_cents,
          revision: group.revision + 1
      }

      case update_group(group, %{
             status: @cancelled,
             refunded_cents: settlement.refunded_cents,
             retained_cents: settlement.retained_cents,
             cash_converted_to_credit_cents: settlement.cash_converted_to_credit_cents,
             revision: updated_group.revision
           }) do
        {:ok, _group} ->
          {:applied,
           result(operation, "applied")
           |> Map.merge(%{
             "group_id" => group_id,
             "refunded_cents" => settlement.refunded_cents,
             "retained_cents" => settlement.retained_cents,
             "credit_issued_cents" => settlement.credit_issued_cents,
             "revision" => updated_group.revision
           })}

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp refund_method(operation) do
    case field_with_presence(operation, "refund_method") do
      :absent -> {:ok, :cash}
      {:present, "cash"} -> {:ok, :cash}
      {:present, "hotel_credit"} -> {:ok, :hotel_credit}
      {:present, _value} -> {:error, "invalid_operation"}
    end
  end

  defp cancellation_settlement(group, occurred_on, refund_method) do
    refundable = refundable?(group, occurred_on)
    cash_paid_cents = group.cash_paid_cents

    case {refundable, refund_method} do
      {false, :hotel_credit} ->
        {:error, "refund_method_not_available"}

      {true, :cash} ->
        {:ok,
         %{
           refundable: true,
           refunded_cents: cash_paid_cents,
           retained_cents: 0,
           credit_issued_cents: 0,
           cash_converted_to_credit_cents: 0
         }}

      {true, :hotel_credit} ->
        {:ok,
         %{
           refundable: true,
           refunded_cents: 0,
           retained_cents: 0,
           credit_issued_cents: cash_paid_cents + round_percentage(cash_paid_cents, 10, 100),
           cash_converted_to_credit_cents: cash_paid_cents
         }}

      {false, :cash} ->
        {:ok,
         %{
           refundable: false,
           refunded_cents: 0,
           retained_cents: cash_paid_cents,
           credit_issued_cents: 0,
           cash_converted_to_credit_cents: 0
         }}
    end
  end

  defp validate_common(operation) do
    if valid_identifier?(field(operation, "operation_id")) and
         field(operation, "occurred_on") != nil do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, key) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp existing_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp ensure_group_missing(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :ok
      _group -> {:error, "group_already_exists"}
    end
  end

  defp check_revision(operation, group) do
    case field_with_presence(operation, "expected_revision") do
      :absent ->
        :ok

      {:present, expected_revision} when expected_revision == group.revision ->
        :ok

      {:present, expected_revision} ->
        {:error,
         {:stale_revision,
          %{
            "operation_id" => field(operation, "operation_id"),
            "status" => "rejected",
            "code" => "stale_revision",
            "group_id" => group.group_id,
            "expected_revision" => expected_revision,
            "actual_revision" => group.revision
          }}}
    end
  end

  defp validate_active(%Group{status: @active}), do: :ok
  defp validate_active(_group), do: {:error, "group_not_active"}

  defp parse_date(value, error_code) when is_binary(value),
    do: date_result(Date.from_iso8601(value), error_code)

  defp parse_date(%Date{} = value, _error_code), do: {:ok, value}
  defp parse_date(_value, error_code), do: {:error, error_code}

  defp date_result({:ok, date}, _error_code), do: {:ok, date}
  defp date_result({:error, _reason}, error_code), do: {:error, error_code}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rescheduled_stay(occurred_on, new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(@flexible), do: {:ok, @flexible}
  defp validate_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp policy_version(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version(@flexible, booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: @flex_14, else: @flex_30
  end

  defp policy_version(%Group{policy_version: nil, rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp policy_version(%Group{policy_version: policy_version}), do: policy_version

  defp cancellation_window(@flex_14), do: 14
  defp cancellation_window(@flex_30), do: 30
  defp cancellation_window(@advance_nonrefundable), do: nil

  defp refundable?(%Group{} = group, occurred_on) do
    case cancellation_window(policy_version(group)) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp refundable_until(%{policy_version: @advance_nonrefundable}), do: nil

  defp refundable_until(%{arrival_on: arrival_on, policy_version: policy_version}) do
    arrival_on
    |> Date.add(-cancellation_window(policy_version))
    |> Date.to_iso8601()
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, valid_rooms} ->
      case validate_room(room, position) do
        {:ok, valid_room} -> {:cont, {:ok, [valid_room | valid_rooms]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, valid_rooms} ->
        valid_rooms = Enum.reverse(valid_rooms)

        if length(Enum.uniq_by(valid_rooms, & &1.room_id)) == length(valid_rooms) do
          {:ok, valid_rooms}
        else
          {:error, "invalid_rooms"}
        end

      error ->
        error
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_room(room, position) when is_map(room) do
    room_id = field(room, "room_id")
    nightly_rate_cents = field(room, "nightly_rate_cents")

    if valid_identifier?(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 do
      {:ok,
       %{
         room_id: room_id,
         nightly_rate_cents: nightly_rate_cents,
         position: position
       }}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_room(_room, _position), do: {:error, "invalid_rooms"}

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp calculate_lodging(rooms, stay_length) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + room.nightly_rate_cents * stay_length
    end)
  end

  defp calculate_deposit(rooms, @advance_purchase, stay_length) do
    calculate_lodging(rooms, stay_length)
  end

  defp calculate_deposit(rooms, @flexible, stay_length) do
    Enum.reduce(rooms, 0, fn room, total ->
      lodging_cents = room.nightly_rate_cents * stay_length
      total + round_percentage(lodging_cents, 20, 100)
    end)
  end

  defp round_percentage(amount, numerator, denominator) do
    quotient = div(amount * numerator, denominator)
    remainder = rem(amount * numerator, denominator)

    if remainder * 2 >= denominator, do: quotient + 1, else: quotient
  end

  defp insert_group(attrs, rooms) do
    changeset = Group.changeset(%Group{}, attrs)

    case Repo.insert(changeset) do
      {:ok, _group} ->
        rooms
        |> Enum.map(fn room ->
          Room.changeset(%Room{}, %{
            group_id: attrs.group_id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position
          })
        end)
        |> Enum.reduce_while(:ok, fn room_changeset, :ok ->
          case Repo.insert(room_changeset) do
            {:ok, _room} -> {:cont, :ok}
            {:error, _changeset} -> {:halt, :error}
          end
        end)

      {:error, _changeset} ->
        :already_exists
    end
  end

  defp update_group(group, changes) do
    group
    |> Group.changeset(changes)
    |> Repo.update()
  end

  defp available_credit_lots(guest_id, amount_cents, occurred_on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.issued_on <= ^occurred_on and
              lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) >= amount_cents do
      {:ok, lots}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp build_allocation_plan(lots, amount_cents) do
    {plan, _remaining} =
      Enum.map_reduce(lots, amount_cents, fn lot, remaining ->
        amount = min(lot.remaining_cents, remaining)
        {{lot, amount}, remaining - amount}
      end)

    Enum.reject(plan, fn {_lot, amount} -> amount == 0 end)
  end

  defp apply_credit_allocations(group, allocation_plan) do
    Enum.reduce_while(allocation_plan, :ok, fn {lot, amount_cents}, :ok ->
      with {:ok, _lot} <-
             update_credit_lot(lot, %{remaining_cents: lot.remaining_cents - amount_cents}),
           {:ok, _allocation} <-
             Repo.insert(
               CreditAllocation.changeset(%CreditAllocation{}, %{
                 group_id: group.group_id,
                 credit_lot_id: lot.id,
                 amount_cents: amount_cents
               })
             ) do
        {:cont, :ok}
      else
        _error -> {:halt, :error}
      end
    end)
  end

  defp update_credit_lot(lot, changes) do
    lot
    |> CreditLot.changeset(changes)
    |> Repo.update()
  end

  defp restore_credit_allocations(group, occurred_on) do
    group
    |> credit_allocations()
    |> Enum.group_by(fn {_allocation, lot} -> lot.id end)
    |> Enum.each(fn {_lot_id, allocations} ->
      {_allocation, lot} = hd(allocations)

      amount_cents =
        Enum.reduce(allocations, 0, fn {allocation, _lot}, total ->
          total + allocation.amount_cents
        end)

      if Date.compare(lot.expires_on, occurred_on) != :lt do
        update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents + amount_cents})
      end

      Enum.each(allocations, fn {allocation, _lot} -> Repo.delete!(allocation) end)
    end)
  end

  defp consume_credit_allocations(group) do
    Repo.delete_all(
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id
    )
  end

  defp credit_allocations(group) do
    Repo.all(
      from allocation in CreditAllocation,
        join: lot in CreditLot,
        on: lot.id == allocation.credit_lot_id,
        where: allocation.group_id == ^group.group_id,
        select: {allocation, lot}
    )
  end

  defp update_credit_lot!(lot, changes) do
    lot
    |> CreditLot.changeset(changes)
    |> Repo.update!()
  end

  defp insert_credit_lot!(attrs) do
    attrs
    |> then(&CreditLot.changeset(%CreditLot{}, &1))
    |> Repo.insert!()
  end

  defp usable_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp usable_amount(_amount_cents), do: {:error, "invalid_amount"}

  defp validate_payment_amount(amount_cents, group) do
    if amount_cents <= outstanding(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp outstanding(%Group{status: @active} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding(_group), do: 0

  defp load_rooms(group) do
    %{
      group
      | rooms:
          Repo.all(
            from room in Room, where: room.group_id == ^group.group_id, order_by: room.position
          )
    }
  end

  defp serialize_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until(%{group | policy_version: policy_version(group)}),
      "status" => group.status,
      "revision" => group.revision,
      "rooms" => Enum.map(group.rooms, &serialize_room/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  defp serialize_room(room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents
    }
  end

  defp serialize_credit_lot(lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end

  defp sum_groups(status, field_name) do
    Repo.one(
      from group in Group,
        where: group.status == ^status,
        select: coalesce(sum(field(group, ^field_name)), 0)
    )
  end

  defp credit_liability(on_date) do
    available_cents =
      Repo.one(
        from lot in CreditLot,
          where:
            lot.remaining_cents > 0 and lot.issued_on <= ^on_date and
              lot.expires_on >= ^on_date,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from allocation in CreditAllocation,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == ^@active and lot.issued_on <= ^on_date,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available_cents + applied_cents
  end

  defp result(operation, status),
    do: %{"operation_id" => field(operation, "operation_id"), "status" => status}

  defp reject(operation, code) when is_binary(code) do
    {:rejected, result(operation, "rejected") |> Map.put("code", code)}
  end

  defp reject(_operation, {:stale_revision, stale_result}), do: {:rejected, stale_result}

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp field(_map, _key), do: nil

  defp field_with_presence(map, key) when is_map(map) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, atom_key) -> {:present, Map.get(map, atom_key)}
      true -> :absent
    end
  end

  defp field_with_presence(_map, _key), do: :absent
end
