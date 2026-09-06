defmodule GroupStay.Groups do
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Groups.CreditAllocation
  alias GroupStay.Groups.HotelCreditLot
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  def apply_operation(operation) when is_map(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  def apply_operation(_), do: rejected(%{}, "invalid_operation")

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        group
        |> Repo.preload(rooms: from(room in Room, order_by: room.position))
        |> serialize_group()
    end
  end

  def ledger(on \\ Date.utc_today()) do
    %{
      cash_held_cents: total_for("active", :cash_paid_cents),
      cash_refunded_cents: total_for("cancelled", :refunded_cents),
      cash_retained_cents: total_for("cancelled", :retained_cents),
      cash_converted_to_credit_cents: total_for("cancelled", :cash_converted_to_credit_cents),
      credit_liability_cents: available_credit_total(on) + applied_credit_total()
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: date_string(lot.expires_on)
          }
        end)
    }
  end

  defp open_group(operation) do
    with {:ok, booked_on} <- common_date(operation),
         {:ok, attributes, rooms} <- open_attributes(operation, booked_on) do
      transaction(fn ->
        if Repo.get_by(Group, group_id: attributes.group_id) do
          {:error, group_error(operation, "group_already_exists", attributes.group_id)}
        else
          case Repo.insert(Group.changeset(%Group{}, attributes)) do
            {:ok, group} ->
              room_rows = Enum.map(rooms, &Map.put(&1, :group_id, group.id))
              {room_count, _} = Repo.insert_all(Room, room_rows)

              if room_count == length(room_rows) do
                {:ok,
                 applied(operation, %{
                   group_id: group.group_id,
                   deposit_due_cents: group.deposit_due_cents,
                   revision: group.revision
                 })}
              else
                {:error, rejected(operation, "invalid_operation")}
              end

            {:error, changeset} ->
              if Keyword.has_key?(changeset.errors, :group_id) do
                {:error, group_error(operation, "group_already_exists", attributes.group_id)}
              else
                {:error, rejected(operation, "invalid_operation")}
              end
          end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, _occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        amount = operation["amount_cents"]

        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          not positive_integer?(amount) ->
            {:error, group_error(operation, "invalid_amount", group.group_id)}

          amount > group.deposit_due_cents - group.deposit_paid_cents ->
            {:error, group_error(operation, "payment_exceeds_outstanding", group.group_id)}

          true ->
            {:update,
             [
               deposit_paid_cents: group.deposit_paid_cents + amount,
               cash_paid_cents: group.cash_paid_cents + amount
             ],
             fn updated ->
               applied(operation, %{
                 group_id: updated.group_id,
                 amount_cents: amount,
                 outstanding_deposit_cents:
                   updated.deposit_due_cents - updated.deposit_paid_cents,
                 revision: updated.revision
               })
             end}
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp reschedule_group(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          true ->
            case parse_date(operation["new_arrival_on"]) do
              {:ok, new_arrival_on} ->
                if Date.compare(new_arrival_on, occurred_on) == :gt do
                  stay_length = Date.diff(group.departure_on, group.arrival_on)
                  new_departure_on = Date.add(new_arrival_on, stay_length)

                  {:update, [arrival_on: new_arrival_on, departure_on: new_departure_on],
                   fn updated ->
                     applied(operation, %{
                       group_id: updated.group_id,
                       new_arrival_on: date_string(updated.arrival_on),
                       new_departure_on: date_string(updated.departure_on),
                       policy_version: updated.policy_version,
                       refundable_until: date_string(refundable_until(updated)),
                       revision: updated.revision
                     })
                   end}
                else
                  {:error, group_error(operation, "invalid_stay", group.group_id)}
                end

              _ ->
                {:error, group_error(operation, "invalid_stay", group.group_id)}
            end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp cancel_group(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        cancel_group_changes(operation, group, occurred_on)
      end)
    else
      {:error, result} -> result
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, occurred_on} <- common_date(operation),
         {:ok, group_id} <- operation_group_id(operation) do
      apply_to_group(operation, group_id, fn group ->
        amount = operation["amount_cents"]
        outstanding_cents = group.deposit_due_cents - group.deposit_paid_cents

        cond do
          group.status != "active" ->
            {:error, group_error(operation, "group_not_active", group.group_id)}

          not positive_integer?(amount) ->
            {:error, group_error(operation, "invalid_amount", group.group_id)}

          amount > outstanding_cents ->
            {:error, group_error(operation, "payment_exceeds_outstanding", group.group_id)}

          true ->
            case credit_redemptions(group.guest_id, occurred_on, amount) do
              {:error, :insufficient_credit} ->
                {:error, group_error(operation, "insufficient_credit", group.group_id)}

              {:ok, redemptions} ->
                case redeem_credit(redemptions, group.id) do
                  :ok ->
                    {:update,
                     [
                       deposit_paid_cents: group.deposit_paid_cents + amount,
                       credit_paid_cents: group.credit_paid_cents + amount
                     ],
                     fn updated ->
                       applied(operation, %{
                         group_id: updated.group_id,
                         amount_cents: amount,
                         outstanding_deposit_cents:
                           updated.deposit_due_cents - updated.deposit_paid_cents,
                         revision: updated.revision
                       })
                     end}

                  :error ->
                    {:error, group_error(operation, "insufficient_credit", group.group_id)}
                end
            end
        end
      end)
    else
      {:error, result} -> result
    end
  end

  defp cancel_group_changes(operation, group, occurred_on) do
    cond do
      group.status != "active" ->
        {:error, group_error(operation, "group_not_active", group.group_id)}

      refund_method(operation) == :invalid ->
        {:error, group_error(operation, "refund_method_not_available", group.group_id)}

      refund_method(operation) == :hotel_credit and not refundable?(group, occurred_on) ->
        {:error, group_error(operation, "refund_method_not_available", group.group_id)}

      true ->
        refundable? = refundable?(group, occurred_on)
        refund_method = refund_method(operation)
        cash_paid_cents = group.cash_paid_cents

        {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
          cancellation_amounts(refundable?, refund_method, cash_paid_cents)

        if refundable? do
          restore_credit_allocations(group.id, occurred_on)
        else
          consume_credit_allocations(group.id)
        end

        if credit_issued_cents > 0 do
          create_credit_lot(
            group.guest_id,
            operation["operation_id"],
            credit_issued_cents,
            Date.add(occurred_on, 365)
          )
        end

        {:update,
         [
           status: "cancelled",
           deposit_due_cents: 0,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           refunded_cents: refunded_cents,
           retained_cents: retained_cents,
           cash_converted_to_credit_cents: converted_cents
         ],
         fn updated ->
           applied(operation, %{
             group_id: updated.group_id,
             refunded_cents: refunded_cents,
             retained_cents: retained_cents,
             credit_issued_cents: credit_issued_cents,
             revision: updated.revision
           })
         end}
    end
  end

  defp apply_to_group(operation, group_id, action) do
    result =
      transaction(fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            {:error, group_error(operation, "group_not_found", group_id)}

          group ->
            if stale_revision?(operation, group) do
              {:error, stale_revision_error(operation, group)}
            else
              case action.(group) do
                {:error, result} ->
                  {:error, result}

                {:update, changes, result_builder} ->
                  case update_group(group, changes) do
                    {:ok, updated} ->
                      {:ok, result_builder.(updated)}

                    {:conflict, latest} ->
                      if has_expected_revision?(operation) do
                        {:error, stale_revision_error(operation, latest)}
                      else
                        {:error, :retry}
                      end
                  end
              end
            end
        end
      end)

    case result do
      :retry -> apply_to_group(operation, group_id, action)
      result -> result
    end
  end

  defp update_group(group, changes) do
    changeset =
      group
      |> change(changes)
      |> optimistic_lock(:revision)

    case Repo.update(changeset, stale_error_field: :revision) do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:conflict, Repo.get!(Group, group.id)}
    end
  end

  defp open_attributes(operation, booked_on) do
    required = [
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         Enum.all?(["group_id", "guest_id", "property_id"], &valid_identifier?(operation[&1])) do
      with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
           {:ok, departure_on} <- parse_date(operation["departure_on"]),
           :ok <- valid_stay(arrival_on, departure_on),
           :ok <- valid_rate_plan(operation["rate_plan"]),
           {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
             build_rooms(
               operation["rooms"],
               Date.diff(departure_on, arrival_on),
               operation["rate_plan"]
             ) do
        {:ok,
         %{
           group_id: operation["group_id"],
           guest_id: operation["guest_id"],
           property_id: operation["property_id"],
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: operation["rate_plan"],
           policy_version: policy_version_for(operation["rate_plan"], booked_on),
           status: "active",
           revision: 1,
           lodging_total_cents: lodging_total_cents,
           deposit_due_cents: deposit_due_cents,
           deposit_paid_cents: 0,
           cash_paid_cents: 0,
           credit_paid_cents: 0,
           refunded_cents: 0,
           retained_cents: 0,
           cash_converted_to_credit_cents: 0
         }, rooms}
      else
        :invalid_stay ->
          {:error, group_error(operation, "invalid_stay", operation["group_id"])}

        :invalid_rate_plan ->
          {:error, group_error(operation, "invalid_rate_plan", operation["group_id"])}

        :invalid_rooms ->
          {:error, group_error(operation, "invalid_rooms", operation["group_id"])}

        _ ->
          {:error, group_error(operation, "invalid_stay", operation["group_id"])}
      end
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp build_rooms(rooms, nights, rate_plan) when is_list(rooms) and rooms != [] do
    room_data =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        if is_map(room) and valid_identifier?(room["room_id"]) and
             positive_integer?(room["nightly_rate_cents"]) do
          lodging_cents = room["nightly_rate_cents"] * nights

          %{
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position,
            lodging_cents: lodging_cents,
            deposit_cents: deposit_for(lodging_cents, rate_plan)
          }
        else
          :invalid
        end
      end)

    if :invalid in room_data or duplicate_room_ids?(room_data) do
      :invalid_rooms
    else
      lodging_total_cents = Enum.sum(Enum.map(room_data, & &1.lodging_cents))
      deposit_due_cents = Enum.sum(Enum.map(room_data, & &1.deposit_cents))

      room_rows =
        Enum.map(room_data, fn room ->
          Map.take(room, [:room_id, :nightly_rate_cents, :position])
        end)

      {:ok, room_rows, lodging_total_cents, deposit_due_cents}
    end
  end

  defp build_rooms(_, _, _), do: :invalid_rooms

  defp duplicate_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)
    length(room_ids) != MapSet.size(MapSet.new(room_ids))
  end

  defp deposit_for(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, "advance_purchase"), do: lodging_cents

  defp valid_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: :invalid_stay
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_), do: :invalid_rate_plan

  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for("flexible", booked_on) do
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
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp operation_group_id(operation) do
    if valid_identifier?(operation["group_id"]) do
      {:ok, operation["group_id"]}
    else
      {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp common_date(operation) do
    with true <- valid_identifier?(operation["operation_id"]),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      {:ok, occurred_on}
    else
      _ -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp has_expected_revision?(operation), do: Map.has_key?(operation, "expected_revision")

  defp stale_revision?(operation, group) do
    has_expected_revision?(operation) and operation["expected_revision"] != group.revision
  end

  defp stale_revision_error(operation, group) do
    rejected(operation, "stale_revision", %{
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    })
  end

  defp total_for(status, field) do
    Repo.aggregate(from(group in Group, where: group.status == ^status), :sum, field) || 0
  end

  defp available_credit_total(on) do
    Repo.aggregate(
      from(lot in HotelCreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^on
      ),
      :sum,
      :remaining_cents
    ) || 0
  end

  defp applied_credit_total do
    Repo.aggregate(
      from(allocation in CreditAllocation,
        join: group in Group,
        on: allocation.group_id == group.id,
        where: group.status == "active"
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from(lot in HotelCreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )
    )
  end

  defp credit_redemptions(guest_id, occurred_on, amount) do
    lots = available_credit_lots(guest_id, occurred_on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, :insufficient_credit}
    else
      {redemptions, _remaining} =
        Enum.reduce(lots, {[], amount}, fn lot, {redemptions, remaining} ->
          redeemed_cents = min(lot.remaining_cents, remaining)
          {[{lot, redeemed_cents} | redemptions], remaining - redeemed_cents}
        end)

      {:ok, Enum.reverse(redemptions) |> Enum.reject(fn {_lot, cents} -> cents == 0 end)}
    end
  end

  defp redeem_credit(redemptions, group_id) do
    with :ok <- decrement_credit_lots(redemptions) do
      allocation_rows =
        Enum.map(redemptions, fn {lot, amount_cents} ->
          %{group_id: group_id, hotel_credit_lot_id: lot.id, amount_cents: amount_cents}
        end)

      case Repo.insert_all(CreditAllocation, allocation_rows) do
        {count, _} when count == length(allocation_rows) -> :ok
        _ -> :error
      end
    end
  end

  defp decrement_credit_lots(redemptions) do
    Enum.reduce_while(redemptions, :ok, fn {lot, amount_cents}, :ok ->
      {count, _} =
        Repo.update_all(
          from(current_lot in HotelCreditLot,
            where: current_lot.id == ^lot.id and current_lot.remaining_cents >= ^amount_cents
          ),
          inc: [remaining_cents: -amount_cents]
        )

      if count == 1, do: {:cont, :ok}, else: {:halt, :error}
    end)
  end

  defp restore_credit_allocations(group_id, occurred_on) do
    group_credit_allocations(group_id)
    |> Enum.each(fn {allocation, lot} ->
      if Date.compare(lot.expires_on, occurred_on) != :lt do
        Repo.update_all(
          from(current_lot in HotelCreditLot, where: current_lot.id == ^lot.id),
          inc: [remaining_cents: allocation.amount_cents]
        )
      end
    end)

    consume_credit_allocations(group_id)
  end

  defp consume_credit_allocations(group_id) do
    Repo.delete_all(from(allocation in CreditAllocation, where: allocation.group_id == ^group_id))
  end

  defp group_credit_allocations(group_id) do
    Repo.all(
      from(allocation in CreditAllocation,
        join: lot in HotelCreditLot,
        on: allocation.hotel_credit_lot_id == lot.id,
        where: allocation.group_id == ^group_id,
        select: {allocation, lot}
      )
    )
  end

  defp create_credit_lot(guest_id, source_operation_id, amount_cents, expires_on) do
    Repo.insert!(%HotelCreditLot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      expires_on: expires_on
    })
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      "cash" -> :cash
      "hotel_credit" -> :hotel_credit
      _ -> :invalid
    end
  end

  defp cancellation_amounts(true, :cash, cash_paid_cents),
    do: {cash_paid_cents, 0, 0, 0}

  defp cancellation_amounts(true, :hotel_credit, cash_paid_cents) do
    credit_issued_cents = cash_paid_cents + percentage(cash_paid_cents, 10)
    {0, 0, cash_paid_cents, credit_issued_cents}
  end

  defp cancellation_amounts(false, :cash, cash_paid_cents),
    do: {0, cash_paid_cents, 0, 0}

  defp percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)

  defp serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: date_string(group.booked_on),
      arrival_on: date_string(group.arrival_on),
      departure_on: date_string(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: date_string(refundable_until(group)),
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
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  defp date_string(nil), do: nil
  defp date_string(date), do: Date.to_iso8601(date)

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation, fields),
    do: Map.merge(base_result(operation), Map.put(fields, :status, "applied"))

  defp rejected(operation, code, fields \\ %{}) do
    base_result(operation)
    |> Map.merge(%{status: "rejected", code: code})
    |> Map.merge(fields)
  end

  defp group_error(operation, code, group_id),
    do: rejected(operation, code, %{group_id: group_id})

  defp base_result(operation) do
    case Map.fetch(operation, "operation_id") do
      {:ok, operation_id} -> %{operation_id: operation_id}
      :error -> %{}
    end
  end
end
