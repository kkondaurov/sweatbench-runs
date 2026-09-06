defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashEntry, CreditApplication, CreditLot, Group, Room}

  @rate_plans ["flexible", "advance_purchase"]

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def guest_credit(guest_id, on \\ Date.utc_today())

  def guest_credit(guest_id, on) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

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

  def guest_credit(_guest_id, _on), do: {:error, :guest_not_found}

  def ledger_totals(on \\ Date.utc_today()) do
    %{
      cash_held_cents: active_cash_held(),
      cash_refunded_cents: cash_total("cash_refund"),
      cash_retained_cents: cash_total("cash_retention"),
      cash_converted_to_credit_cents: cash_total("cash_credit_conversion"),
      credit_liability_cents: credit_liability(on)
    }
  end

  defp apply_operation(operation) when is_map(operation) do
    if Map.get(operation, "type") in [
         "open_group",
         "record_cash_payment",
         "reschedule_group",
         "cancel_group",
         "apply_hotel_credit"
       ] do
      case Repo.transaction(fn ->
             case perform_operation(operation) do
               {:applied, result} -> result
               {:rejected, result} -> Repo.rollback(result)
             end
           end) do
        {:ok, result} -> result
        {:error, :concurrent_update} -> apply_operation(operation)
        {:error, result} -> result
      end
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp apply_operation(operation), do: rejected(operation, "invalid_operation")

  defp perform_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp perform_operation(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp perform_operation(%{"type" => "reschedule_group"} = operation),
    do: reschedule_group(operation)

  defp perform_operation(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp perform_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp open_group(operation) do
    with {:ok, booked_on} <- validate_common(operation),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, guest_id} <- identifier(operation, "guest_id"),
         {:ok, property_id} <- identifier(operation, "property_id"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation, arrival_on, departure_on, rate_plan) do
      if Repo.exists?(from group in Group, where: group.group_id == ^group_id) do
        {:rejected, rejected(operation, "group_already_exists")}
      else
        lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
        deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_cents))

        attrs = %{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: "active",
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          policy_version: policy_version(rate_plan, booked_on),
          revision: 1
        }

        case Repo.insert(Group.changeset(%Group{}, attrs)) do
          {:ok, group} ->
            Enum.each(rooms, fn room ->
              Repo.insert!(
                Room.changeset(%Room{}, %{
                  group_id: group.id,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents,
                  position: room.position
                })
              )
            end)

            {:applied,
             applied(operation, %{
               "group_id" => group.group_id,
               "deposit_due_cents" => deposit_due_cents,
               "revision" => group.revision
             })}

          {:error, _changeset} ->
            {:rejected, rejected(operation, "group_already_exists")}
        end
      end
    else
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- payment_amount(operation),
         :ok <- within_outstanding(amount_cents, group) do
      outstanding_deposit_cents =
        group.deposit_due_cents - group.deposit_paid_cents - amount_cents

      group =
        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: group.cash_paid_cents + amount_cents,
          revision: group.revision + 1
        })

      insert_cash_entry!(group, "cash_payment", amount_cents, occurred_on)

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit_cents,
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- arrival_after_operation(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      group =
        update_group!(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "policy_version" => effective_policy_version(group),
         "refundable_until" => refundable_until(group),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, refund_method} <- refund_method(operation, group, occurred_on) do
      refundable? = refundable?(group, occurred_on)
      credit_issued_cents = credit_issued(group, refund_method)

      group = update_group!(group, %{status: "cancelled", revision: group.revision + 1})

      {refunded_cents, retained_cents} =
        settle_cash!(
          group,
          refundable?,
          refund_method,
          credit_issued_cents,
          operation,
          occurred_on
        )

      settle_applied_credit!(group, refundable?, occurred_on)

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- payment_amount(operation),
         :ok <- within_outstanding(amount_cents, group),
         {:ok, allocations} <- credit_allocations(group.guest_id, amount_cents, occurred_on) do
      Enum.each(allocations, fn {lot, amount} ->
        consume_credit_lot!(lot, amount)

        Repo.insert!(
          CreditApplication.changeset(%CreditApplication{}, %{
            group_id: group.id,
            credit_lot_id: lot.id,
            amount_cents: amount
          })
        )
      end)

      group =
        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          credit_paid_cents: group.credit_paid_cents + amount_cents,
          revision: group.revision + 1
        })

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp validate_common(operation) do
    with {:ok, _operation_id} <- identifier(operation, "operation_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on") do
      {:ok, occurred_on}
    end
  end

  defp identifier(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(operation, key) do
    case Map.fetch(operation, key) do
      :error -> {:error, "invalid_operation"}
      {:ok, nil} -> {:error, "invalid_operation"}
      {:ok, date} when is_binary(date) -> parse_date(date)
      {:ok, _value} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed_date} -> {:ok, parsed_date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, "invalid_operation"}
      {:ok, rate_plan} when rate_plan in @rate_plans -> {:ok, rate_plan}
      {:ok, _rate_plan} -> {:error, "invalid_rate_plan"}
    end
  end

  defp rooms(operation, arrival_on, departure_on, rate_plan) do
    case Map.fetch(operation, "rooms") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {room, position},
                                                           {:ok, {valid_rooms, ids}} ->
          case room_details(room, position, arrival_on, departure_on, rate_plan, ids) do
            {:ok, valid_room, updated_ids} ->
              {:cont, {:ok, {[valid_room | valid_rooms], updated_ids}}}

            {:error, code} ->
              {:halt, {:error, code}}
          end
        end)
        |> case do
          {:ok, {valid_rooms, _ids}} -> {:ok, Enum.reverse(valid_rooms)}
          {:error, code} -> {:error, code}
        end

      {:ok, _rooms} ->
        {:error, "invalid_rooms"}
    end
  end

  defp room_details(room, position, arrival_on, departure_on, rate_plan, ids) when is_map(room) do
    with room_id when is_binary(room_id) and byte_size(room_id) > 0 <- Map.get(room, "room_id"),
         false <- MapSet.member?(ids, room_id),
         nightly_rate_cents when is_integer(nightly_rate_cents) and nightly_rate_cents >= 0 <-
           Map.get(room, "nightly_rate_cents") do
      lodging_total_cents = Date.diff(departure_on, arrival_on) * nightly_rate_cents

      deposit_cents =
        if rate_plan == "flexible" do
          round_half_up(lodging_total_cents * 20, 100)
        else
          lodging_total_cents
        end

      {:ok,
       %{
         room_id: room_id,
         nightly_rate_cents: nightly_rate_cents,
         lodging_total_cents: lodging_total_cents,
         deposit_cents: deposit_cents,
         position: position
       }, MapSet.put(ids, room_id)}
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp room_details(_room, _position, _arrival_on, _departure_on, _rate_plan, _ids),
    do: {:error, "invalid_rooms"}

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp current_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         Map.get(operation, "expected_revision") != group.revision do
      {:error,
       {:stale_revision,
        rejected(operation, "stale_revision", %{
          "group_id" => group.group_id,
          "expected_revision" => Map.get(operation, "expected_revision"),
          "actual_revision" => group.revision
        })}}
    else
      :ok
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(%Group{}), do: {:error, "group_not_active"}

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, "invalid_amount"}
    end
  end

  defp within_outstanding(amount_cents, group) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp effective_policy_version(%Group{policy_version: policy_version})
       when is_binary(policy_version),
       do: policy_version

  defp effective_policy_version(%Group{} = group),
    do: policy_version(group.rate_plan, group.booked_on)

  defp refundable?(group, occurred_on) do
    case cancellation_window(group) do
      nil -> false
      window -> Date.compare(occurred_on, Date.add(group.arrival_on, -window)) != :gt
    end
  end

  defp cancellation_window(%Group{policy_version: "flex-14"}), do: 14
  defp cancellation_window(%Group{policy_version: "flex-30"}), do: 30
  defp cancellation_window(%Group{policy_version: "advance-nonrefundable"}), do: nil

  defp cancellation_window(%Group{} = group),
    do: cancellation_window(policy_version(group.rate_plan, group.booked_on))

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30
  defp cancellation_window("advance-nonrefundable"), do: nil

  defp refundable_until(group) do
    case cancellation_window(group) do
      nil -> nil
      window -> group.arrival_on |> Date.add(-window) |> Date.to_iso8601()
    end
  end

  defp refund_method(operation, group, occurred_on) do
    case Map.get(operation, "refund_method", "cash") do
      "cash" ->
        {:ok, "cash"}

      "hotel_credit" ->
        if refundable?(group, occurred_on),
          do: {:ok, "hotel_credit"},
          else: {:error, "refund_method_not_available"}

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp credit_issued(%Group{cash_paid_cents: cash_paid_cents}, "hotel_credit") do
    cash_paid_cents + round_half_up(cash_paid_cents * 10, 100)
  end

  defp credit_issued(%Group{}, _refund_method), do: 0

  defp settle_cash!(group, true, "cash", _credit_issued_cents, _operation, occurred_on) do
    insert_cash_entry_if_positive!(group, "cash_refund", group.cash_paid_cents, occurred_on)
    {group.cash_paid_cents, 0}
  end

  defp settle_cash!(group, true, "hotel_credit", credit_issued_cents, operation, occurred_on) do
    if credit_issued_cents > 0 do
      Repo.insert!(
        CreditLot.changeset(%CreditLot{}, %{
          guest_id: group.guest_id,
          source_operation_id: Map.fetch!(operation, "operation_id"),
          remaining_cents: credit_issued_cents,
          expires_on: Date.add(occurred_on, 366)
        })
      )
    end

    insert_cash_entry_if_positive!(
      group,
      "cash_credit_conversion",
      group.cash_paid_cents,
      occurred_on
    )

    {0, 0}
  end

  defp settle_cash!(group, false, _refund_method, _credit_issued_cents, _operation, occurred_on) do
    insert_cash_entry_if_positive!(group, "cash_retention", group.cash_paid_cents, occurred_on)
    {0, group.cash_paid_cents}
  end

  defp settle_applied_credit!(group, refundable?, occurred_on) do
    Repo.all(
      from application in CreditApplication,
        join: lot in CreditLot,
        on: lot.id == application.credit_lot_id,
        where: application.group_id == ^group.id,
        select: {application, lot}
    )
    |> Enum.each(fn {application, lot} ->
      if refundable? and credit_available_on?(lot, occurred_on) do
        Repo.update_all(
          from(current_lot in CreditLot, where: current_lot.id == ^lot.id),
          inc: [remaining_cents: application.amount_cents]
        )
      end

      Repo.delete!(application)
    end)
  end

  defp credit_allocations(guest_id, amount_cents, occurred_on) do
    available_credit_lots(guest_id, occurred_on)
    |> Enum.reduce_while({amount_cents, []}, fn lot, {remaining, allocations} ->
      amount = min(remaining, lot.remaining_cents)
      updated_allocations = [{lot, amount} | allocations]

      if amount == remaining do
        {:halt, {0, updated_allocations}}
      else
        {:cont, {remaining - amount, updated_allocations}}
      end
    end)
    |> case do
      {0, allocations} -> {:ok, Enum.reverse(allocations)}
      {_remaining, _allocations} -> {:error, "insufficient_credit"}
    end
  end

  defp consume_credit_lot!(lot, amount_cents) do
    {updated_count, _} =
      Repo.update_all(
        from(current_lot in CreditLot,
          where: current_lot.id == ^lot.id and current_lot.remaining_cents >= ^amount_cents
        ),
        inc: [remaining_cents: -amount_cents]
      )

    if updated_count != 1, do: Repo.rollback(:concurrent_update)
  end

  defp update_group!(group, attrs) do
    {updated_count, _} =
      Repo.update_all(
        from(current_group in Group,
          where: current_group.id == ^group.id and current_group.revision == ^group.revision
        ),
        set: Map.to_list(attrs)
      )

    if updated_count == 1 do
      struct(group, attrs)
    else
      Repo.rollback(:concurrent_update)
    end
  end

  defp insert_cash_entry!(group, entry_type, amount_cents, occurred_on) do
    Repo.insert!(
      CashEntry.changeset(%CashEntry{}, %{
        group_id: group.id,
        entry_type: entry_type,
        amount_cents: amount_cents,
        occurred_on: occurred_on
      })
    )
  end

  defp insert_cash_entry_if_positive!(_group, _entry_type, 0, _occurred_on), do: :ok

  defp insert_cash_entry_if_positive!(group, entry_type, amount_cents, occurred_on) do
    insert_cash_entry!(group, entry_type, amount_cents, occurred_on)
  end

  defp active_cash_held do
    Repo.one(
      from group in Group,
        where: group.status == "active",
        select: coalesce(sum(group.cash_paid_cents), 0)
    )
  end

  defp cash_total(entry_type) do
    Repo.one(
      from entry in CashEntry,
        where: entry.entry_type == ^entry_type,
        select: coalesce(sum(entry.amount_cents), 0)
    )
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
  end

  defp credit_available_on?(lot, on), do: Date.compare(lot.expires_on, on) == :gt

  defp credit_liability(on) do
    available_cents =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from application in CreditApplication,
          join: group in Group,
          on: group.id == application.group_id,
          where: group.status == "active",
          select: coalesce(sum(application.amount_cents), 0)
      )

    available_cents + applied_cents
  end

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.id,
          order_by: [asc: room.position]
      )

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      policy_version: effective_policy_version(group),
      refundable_until: refundable_until(group),
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0
  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp applied(operation, fields), do: Map.merge(base_result(operation, "applied"), fields)

  defp rejected(operation, code, fields \\ %{}),
    do: Map.merge(base_result(operation, "rejected"), Map.put(fields, "code", code))

  defp base_result(operation, status) when is_map(operation) do
    %{"status" => status}
    |> maybe_put_operation_id(Map.get(operation, "operation_id"))
  end

  defp base_result(_operation, status), do: %{"status" => status}

  defp maybe_put_operation_id(result, operation_id) when is_binary(operation_id),
    do: Map.put(result, "operation_id", operation_id)

  defp maybe_put_operation_id(result, _operation_id), do: result
end
