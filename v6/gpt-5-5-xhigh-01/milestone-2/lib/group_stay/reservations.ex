defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.LedgerEntry
  alias GroupStay.Reservations.Room

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @cash_payment "cash_payment"
  @cash_refund "cash_refund"
  @cash_retention "cash_retention"
  @cash_credit_conversion "cash_credit_conversion"
  @refund_cash "cash"
  @refund_hotel_credit "hotel_credit"

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation_transaction/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    group_id
    |> fetch_group()
    |> preload_rooms()
  end

  def get_group(_group_id), do: nil

  def group_data(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until_data(group),
      status: group.status,
      rooms: Enum.map(group.rooms, &room_data/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: deposit_paid_cents(group),
      cash_paid_cents: cash_paid_cents(group),
      credit_paid_cents: credit_paid_cents(group),
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def ledger_totals(on_param \\ nil) do
    as_of = as_of_date(on_param)

    totals =
      LedgerEntry
      |> group_by([entry], entry.entry_type)
      |> select([entry], {entry.entry_type, sum(entry.amount_cents)})
      |> Repo.all()
      |> Map.new(fn {entry_type, amount} -> {entry_type, amount || 0} end)

    refunded_cents = Map.get(totals, @cash_refund, 0)
    retained_cents = Map.get(totals, @cash_retention, 0)
    converted_cents = Map.get(totals, @cash_credit_conversion, 0)
    payment_cents = Map.get(totals, @cash_payment, 0)

    %{
      cash_held_cents: max(payment_cents - refunded_cents - retained_cents - converted_cents, 0),
      cash_refunded_cents: refunded_cents,
      cash_retained_cents: retained_cents,
      cash_converted_to_credit_cents: converted_cents,
      credit_liability_cents: credit_liability_cents(as_of)
    }
  end

  def guest_credit_data(guest_id, on_param \\ nil) when is_binary(guest_id) do
    as_of = as_of_date(on_param)
    lots = available_credit_lots(guest_id, as_of)
    available_cents = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    %{
      guest_id: guest_id,
      available_cents: available_cents,
      lots: Enum.map(lots, &credit_lot_data/1)
    }
  end

  defp apply_operation_transaction(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:ok, result} -> result
             {:error, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp apply_operation(operation) do
    with {:ok, metadata} <- parse_common(operation) do
      case metadata.type do
        "open_group" -> open_group(metadata)
        "record_cash_payment" -> record_cash_payment(metadata)
        "apply_hotel_credit" -> apply_hotel_credit(metadata)
        "reschedule_group" -> reschedule_group(metadata)
        "cancel_group" -> cancel_group(metadata)
        _type -> reject(metadata, "invalid_operation")
      end
    end
  end

  defp parse_common(operation) when is_map(operation) do
    operation_id = operation["operation_id"]
    type = operation["type"]

    with true <- present_string?(operation_id),
         true <- present_string?(type),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      {:ok,
       %{
         operation: operation,
         operation_id: operation_id,
         type: type,
         occurred_on: occurred_on
       }}
    else
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp parse_common(operation), do: reject(operation, "invalid_operation")

  defp open_group(%{operation: operation} = metadata) do
    with :ok <- require_open_identifiers(operation, metadata),
         :ok <- ensure_group_unique(operation["group_id"], metadata),
         {:ok, arrival_on, departure_on, nights} <- parse_stay_dates(operation, metadata),
         :ok <- validate_rate_plan(operation["rate_plan"], metadata),
         {:ok, rooms} <- validate_rooms(operation["rooms"], metadata) do
      lodging_total_cents = lodging_total_cents(rooms, nights)
      deposit_due_cents = deposit_due_cents(rooms, nights, operation["rate_plan"])

      group =
        %Group{}
        |> Group.changeset(%{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: metadata.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          policy_version: policy_version_for(operation["rate_plan"], metadata.occurred_on),
          status: @active,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          revision: 1
        })
        |> Repo.insert()

      case group do
        {:ok, group} ->
          Enum.each(rooms, fn room ->
            %Room{}
            |> Room.changeset(%{
              group_id: group.id,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: room.position
            })
            |> Repo.insert!()
          end)

          apply_result(metadata, %{
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          })

        {:error, _changeset} ->
          reject(metadata, "group_already_exists")
      end
    end
  end

  defp record_cash_payment(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, amount_cents} <- payment_amount(metadata),
         :ok <- ensure_payment_within_outstanding(group, amount_cents, metadata) do
      group =
        update_group!(group, %{
          cash_paid_cents: cash_paid_cents(group) + amount_cents,
          deposit_paid_cents: deposit_paid_cents(group) + amount_cents,
          revision: group.revision + 1
        })

      insert_ledger_entry!(group, metadata, @cash_payment, amount_cents)

      apply_result(metadata, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group),
        revision: group.revision
      })
    end
  end

  defp apply_hotel_credit(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, amount_cents} <- payment_amount(metadata),
         :ok <- ensure_payment_within_outstanding(group, amount_cents, metadata),
         {:ok, consumed_lots} <- consume_credit_lots(group, amount_cents, metadata) do
      group =
        update_group!(group, %{
          credit_paid_cents: credit_paid_cents(group) + amount_cents,
          deposit_paid_cents: deposit_paid_cents(group) + amount_cents,
          revision: group.revision + 1
        })

      Enum.each(consumed_lots, fn {lot, consumed_cents} ->
        insert_credit_application!(group, lot, metadata, consumed_cents)
      end)

      apply_result(metadata, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group),
        revision: group.revision
      })
    end
  end

  defp reschedule_group(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, new_arrival_on} <- parse_reschedule_arrival(metadata) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      group =
        update_group!(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })

      apply_result(metadata, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        policy_version: policy_version(group),
        refundable_until: refundable_until_data(group),
        revision: group.revision
      })
    end
  end

  defp cancel_group(metadata) do
    with {:ok, group} <- fetch_existing_group_for_update(metadata),
         :ok <- ensure_active(group, metadata),
         {:ok, refund_method} <- refund_method(metadata),
         :ok <-
           ensure_refund_method_available(group, metadata.occurred_on, refund_method, metadata) do
      {refunded_cents, retained_cents, credit_issued_cents} =
        settle_cancellation!(group, metadata, refund_method)

      group =
        update_group!(group, %{
          status: @cancelled,
          revision: group.revision + 1
        })

      apply_result(metadata, %{
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: group.revision
      })
    end
  end

  defp require_open_identifiers(operation, metadata) do
    required_fields = ["group_id", "guest_id", "property_id"]

    if Enum.all?(required_fields, &present_string?(operation[&1])) do
      :ok
    else
      reject(metadata, "invalid_operation")
    end
  end

  defp ensure_group_unique(group_id, metadata) do
    if fetch_group(group_id) do
      reject(metadata, "group_already_exists")
    else
      :ok
    end
  end

  defp parse_stay_dates(operation, metadata) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> reject(metadata, "invalid_stay")
    end
  end

  defp validate_rate_plan(rate_plan, _metadata) when rate_plan in [@flexible, @advance_purchase],
    do: :ok

  defp validate_rate_plan(_rate_plan, metadata), do: reject(metadata, "invalid_rate_plan")

  defp validate_rooms(rooms, metadata) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {room, position},
                                                     {:ok, valid_rooms, room_ids} ->
      case validate_room(room, position, room_ids) do
        {:ok, valid_room} ->
          {:cont, {:ok, [valid_room | valid_rooms], MapSet.put(room_ids, valid_room.room_id)}}

        :error ->
          {:halt, reject(metadata, "invalid_rooms")}
      end
    end)
    |> case do
      {:ok, valid_rooms, _room_ids} -> {:ok, Enum.reverse(valid_rooms)}
      {:error, _result} = error -> error
    end
  end

  defp validate_rooms(_rooms, metadata), do: reject(metadata, "invalid_rooms")

  defp validate_room(room, position, room_ids) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate_cents = room["nightly_rate_cents"]

    cond do
      not present_string?(room_id) ->
        :error

      not (is_integer(nightly_rate_cents) and nightly_rate_cents >= 0) ->
        :error

      MapSet.member?(room_ids, room_id) ->
        :error

      true ->
        {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
    end
  end

  defp validate_room(_room, _position, _room_ids), do: :error

  defp fetch_existing_group_for_update(%{operation: operation} = metadata) do
    group_id = operation["group_id"]

    if present_string?(group_id) do
      case fetch_group(group_id) do
        nil -> reject(metadata, "group_not_found")
        group -> ensure_current_revision(group, metadata)
      end
    else
      reject(metadata, "invalid_operation")
    end
  end

  defp ensure_current_revision(group, %{operation: operation} = metadata) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        {:ok, group}

      {:ok, expected_revision} when expected_revision == group.revision ->
        {:ok, group}

      {:ok, expected_revision} ->
        {:error,
         %{
           operation_id: metadata.operation_id,
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp ensure_active(%Group{status: @active}, _metadata), do: :ok
  defp ensure_active(%Group{}, metadata), do: reject(metadata, "group_not_active")

  defp payment_amount(%{operation: operation} = metadata) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        reject(metadata, "invalid_amount")

      :error ->
        reject(metadata, "invalid_operation")
    end
  end

  defp ensure_payment_within_outstanding(group, amount_cents, metadata) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      reject(metadata, "payment_exceeds_outstanding")
    end
  end

  defp consume_credit_lots(group, amount_cents, metadata) do
    lots = available_credit_lots(group.guest_id, metadata.occurred_on)
    available_cents = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available_cents < amount_cents do
      reject(metadata, "insufficient_credit")
    else
      consumed_lots =
        lots
        |> take_credit(amount_cents)
        |> Enum.map(fn {lot, consumed_cents} ->
          lot =
            update_credit_lot!(lot, %{
              remaining_cents: lot.remaining_cents - consumed_cents
            })

          {lot, consumed_cents}
        end)

      {:ok, consumed_lots}
    end
  end

  defp take_credit(_lots, 0), do: []

  defp take_credit([lot | rest], amount_cents) do
    consumed_cents = min(lot.remaining_cents, amount_cents)
    [{lot, consumed_cents} | take_credit(rest, amount_cents - consumed_cents)]
  end

  defp parse_reschedule_arrival(%{operation: operation, occurred_on: occurred_on} = metadata) do
    with {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :gt <- Date.compare(new_arrival_on, occurred_on) do
      {:ok, new_arrival_on}
    else
      _ -> reject(metadata, "invalid_stay")
    end
  end

  defp refund_method(%{operation: operation} = metadata) do
    case Map.get(operation, "refund_method", @refund_cash) do
      @refund_cash -> {:ok, @refund_cash}
      @refund_hotel_credit -> {:ok, @refund_hotel_credit}
      _other -> reject(metadata, "invalid_operation")
    end
  end

  defp ensure_refund_method_available(group, occurred_on, @refund_hotel_credit, metadata) do
    if refundable_cancellation?(group, occurred_on) do
      :ok
    else
      reject(metadata, "refund_method_not_available")
    end
  end

  defp ensure_refund_method_available(_group, _occurred_on, @refund_cash, _metadata), do: :ok

  defp settle_cancellation!(group, metadata, refund_method) do
    if refundable_cancellation?(group, metadata.occurred_on) do
      restore_credit_applications!(group, metadata.occurred_on)
      settle_refundable_cash!(group, metadata, refund_method)
    else
      retained_cents = cash_paid_cents(group)
      insert_ledger_entry!(group, metadata, @cash_retention, retained_cents)

      {0, retained_cents, 0}
    end
  end

  defp settle_refundable_cash!(group, metadata, @refund_cash) do
    refunded_cents = cash_paid_cents(group)
    insert_ledger_entry!(group, metadata, @cash_refund, refunded_cents)

    {refunded_cents, 0, 0}
  end

  defp settle_refundable_cash!(group, metadata, @refund_hotel_credit) do
    cash_cents = cash_paid_cents(group)
    credit_issued_cents = cash_cents + percentage_cents(cash_cents, 10)

    insert_ledger_entry!(group, metadata, @cash_credit_conversion, cash_cents)
    insert_credit_lot!(group.guest_id, metadata, credit_issued_cents)

    {0, 0, credit_issued_cents}
  end

  defp restore_credit_applications!(group, occurred_on) do
    CreditApplication
    |> where([application], application.group_id == ^group.id)
    |> select([application], {application.credit_lot_id, sum(application.amount_cents)})
    |> group_by([application], application.credit_lot_id)
    |> Repo.all()
    |> Enum.each(fn {credit_lot_id, amount_cents} ->
      lot = Repo.get!(CreditLot, credit_lot_id)

      if Date.compare(lot.expires_on, occurred_on) in [:gt, :eq] do
        update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents + amount_cents})
      end
    end)
  end

  defp refundable_cancellation?(%Group{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
  end

  defp policy_version(%Group{policy_version: policy_version})
       when is_binary(policy_version) and policy_version != "" do
    policy_version
  end

  defp policy_version(%Group{} = group), do: policy_version_for(group.rate_plan, group.booked_on)

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt do
      @flex_14
    else
      @flex_30
    end
  end

  defp refundable_until(%Group{} = group) do
    case policy_version(group) do
      @flex_14 -> Date.add(group.arrival_on, -14)
      @flex_30 -> Date.add(group.arrival_on, -30)
      @advance_nonrefundable -> nil
    end
  end

  defp refundable_until_data(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp lodging_total_cents(rooms, nights) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + room.nightly_rate_cents * nights
    end)
  end

  defp deposit_due_cents(rooms, nights, @flexible) do
    Enum.reduce(rooms, 0, fn room, total ->
      lodging_cents = room.nightly_rate_cents * nights
      total + percentage_cents(lodging_cents, 20)
    end)
  end

  defp deposit_due_cents(rooms, nights, @advance_purchase) do
    lodging_total_cents(rooms, nights)
  end

  defp percentage_cents(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp outstanding_deposit_cents(%Group{status: @active} = group) do
    max(group.deposit_due_cents - deposit_paid_cents(group), 0)
  end

  defp outstanding_deposit_cents(%Group{}), do: 0

  defp deposit_paid_cents(%Group{deposit_paid_cents: deposit_paid_cents})
       when is_integer(deposit_paid_cents) do
    deposit_paid_cents
  end

  defp deposit_paid_cents(%Group{} = group), do: cash_paid_cents(group) + credit_paid_cents(group)

  defp cash_paid_cents(%Group{cash_paid_cents: cash_paid_cents}) when is_integer(cash_paid_cents),
    do: cash_paid_cents

  defp cash_paid_cents(%Group{deposit_paid_cents: deposit_paid_cents})
       when is_integer(deposit_paid_cents),
       do: deposit_paid_cents

  defp cash_paid_cents(%Group{}), do: 0

  defp credit_paid_cents(%Group{credit_paid_cents: credit_paid_cents})
       when is_integer(credit_paid_cents),
       do: credit_paid_cents

  defp credit_paid_cents(%Group{}), do: 0

  defp credit_liability_cents(as_of) do
    available_cents =
      CreditLot
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on >= ^as_of)
      |> select([lot], sum(lot.remaining_cents))
      |> Repo.one()
      |> case do
        nil -> 0
        amount_cents -> amount_cents
      end

    applied_cents =
      CreditApplication
      |> join(:inner, [application], group in assoc(application, :group))
      |> where([_application, group], group.status == @active)
      |> select([application, _group], sum(application.amount_cents))
      |> Repo.one()
      |> case do
        nil -> 0
        amount_cents -> amount_cents
      end

    available_cents + applied_cents
  end

  defp available_credit_lots(guest_id, as_of) do
    CreditLot
    |> where(
      [lot],
      lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^as_of
    )
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp update_group!(group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update!()
  end

  defp update_credit_lot!(lot, attrs) do
    lot
    |> CreditLot.changeset(attrs)
    |> Repo.update!()
  end

  defp insert_ledger_entry!(_group, _metadata, _entry_type, 0), do: :ok

  defp insert_ledger_entry!(group, metadata, entry_type, amount_cents) do
    %LedgerEntry{}
    |> LedgerEntry.changeset(%{
      group_id: group.id,
      operation_id: metadata.operation_id,
      entry_type: entry_type,
      amount_cents: amount_cents,
      occurred_on: metadata.occurred_on
    })
    |> Repo.insert!()
  end

  defp insert_credit_lot!(_guest_id, _metadata, 0), do: :ok

  defp insert_credit_lot!(guest_id, metadata, amount_cents) do
    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: guest_id,
      source_operation_id: metadata.operation_id,
      remaining_cents: amount_cents,
      expires_on: Date.add(metadata.occurred_on, 365)
    })
    |> Repo.insert!()
  end

  defp insert_credit_application!(group, lot, metadata, amount_cents) do
    %CreditApplication{}
    |> CreditApplication.changeset(%{
      group_id: group.id,
      credit_lot_id: lot.id,
      operation_id: metadata.operation_id,
      amount_cents: amount_cents
    })
    |> Repo.insert!()
  end

  defp apply_result(metadata, fields) do
    {:ok,
     metadata
     |> base_result("applied")
     |> Map.merge(fields)}
  end

  defp reject(metadata_or_operation, code) do
    {:error,
     metadata_or_operation
     |> base_result("rejected")
     |> Map.put(:code, code)}
  end

  defp base_result(%{operation_id: operation_id}, status) when is_binary(operation_id) do
    %{operation_id: operation_id, status: status}
  end

  defp base_result(operation, status) when is_map(operation) do
    operation_id =
      case operation["operation_id"] do
        operation_id when is_binary(operation_id) -> operation_id
        _other -> nil
      end

    %{operation_id: operation_id, status: status}
  end

  defp base_result(_operation, status), do: %{operation_id: nil, status: status}

  defp room_data(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents
    }
  end

  defp credit_lot_data(%CreditLot{} = lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp fetch_group(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  defp preload_rooms(nil), do: nil

  defp preload_rooms(%Group{} = group) do
    rooms_query = from room in Room, order_by: [asc: room.position]
    Repo.preload(group, rooms: rooms_query)
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp as_of_date(%Date{} = date), do: date

  defp as_of_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> Date.utc_today()
    end
  end

  defp as_of_date(_value), do: Date.utc_today()

  defp present_string?(value), do: is_binary(value) and value != ""
end
