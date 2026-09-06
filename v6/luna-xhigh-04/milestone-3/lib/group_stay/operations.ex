defmodule GroupStay.Operations do
  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias GroupStay.{CreditAllocation, CreditLot, Group, Ledger, OperationRecord, Repo, Room}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @cash "cash"
  @hotel_credit "hotel_credit"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @policy_cutover ~D[2027-01-01]

  @type operation :: map()

  @spec process_batch([operation()]) :: [map()]
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec get_group(String.t()) :: map() | nil
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> serialize_group()
    end
  end

  @spec guest_credit(String.t(), Date.t()) :: map()
  def guest_credit(guest_id, on) do
    lots = available_credit_lots(guest_id, on)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" => Enum.map(lots, &serialize_credit_lot/1)
    }
  end

  @spec ledger_totals(Date.t()) :: map()
  def ledger_totals(on \\ Date.utc_today()) do
    ledger = Repo.get!(Ledger, 1)

    %{
      "cash_held_cents" => ledger.cash_held_cents,
      "cash_refunded_cents" => ledger.cash_refunded_cents,
      "cash_retained_cents" => ledger.cash_retained_cents,
      "cash_converted_to_credit_cents" => ledger.cash_converted_to_credit_cents,
      "credit_liability_cents" => credit_liability_as_of(on)
    }
  end

  @spec get_operation_result(String.t()) :: map() | nil
  def get_operation_result(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  @spec parse_report_date(String.t() | nil) :: {:ok, Date.t()} | {:error, String.t()}
  def parse_report_date(nil), do: {:ok, Date.utc_today()}

  def parse_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_date"}
    end
  end

  def parse_report_date(_value), do: {:error, "invalid_date"}

  defp process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")

    case validate_operation_id(operation_id) do
      :ok -> process_durably(operation, operation_id)
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_durably(operation, operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case reserve_operation(operation, operation_id) do
          {:new, record} ->
            result = process_new_operation(operation, operation_id)

            record
            |> Changeset.change(result: result)
            |> Repo.update!()

            result

          {:existing, record} ->
            if equivalent_payload?(record.payload, operation) do
              record.result
            else
              rejected(operation_id, "operation_id_conflict")
            end
        end
      end)

    result
  end

  defp reserve_operation(operation, operation_id) do
    {inserted, _rows} =
      Repo.insert_all(
        OperationRecord,
        [
          %{
            operation_id: operation_id,
            type: operation_type(operation),
            payload: operation
          }
        ],
        on_conflict: :nothing
      )

    case inserted do
      1 -> {:new, Repo.get_by!(OperationRecord, operation_id: operation_id)}
      0 -> {:existing, Repo.get_by!(OperationRecord, operation_id: operation_id)}
    end
  end

  defp process_new_operation(operation, operation_id) do
    with type when is_binary(type) <- value(operation, "type"),
         {:ok, result} <- dispatch(type, operation, operation_id) do
      result
    else
      {:error, code} -> rejected(operation_id, code)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp dispatch("open_group", operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      result =
        if Repo.get(Group, group_id) do
          rejected(operation_id, "group_already_exists", group_id)
        else
          with {:ok, guest_id} <- required_identifier(operation, "guest_id"),
               {:ok, property_id} <- required_identifier(operation, "property_id") do
            open_group(operation, operation_id, group_id, guest_id, property_id)
          else
            {:error, code} -> rejected(operation_id, code, group_id)
          end
        end

      {:ok, result}
    end
  end

  defp dispatch(type, operation, operation_id)
       when type in [
              "record_cash_payment",
              "reschedule_group",
              "cancel_group",
              "apply_hotel_credit"
            ] do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      result =
        case Repo.get(Group, group_id) do
          nil -> rejected(operation_id, "group_not_found", group_id)
          group -> apply_existing_group_operation(type, operation, operation_id, group)
        end

      {:ok, result}
    end
  end

  defp dispatch(_type, _operation, _operation_id), do: {:error, "invalid_operation"}

  defp open_group(operation, operation_id, group_id, guest_id, property_id) do
    with {:ok, booked_on} <- parse_date(operation, "occurred_on"),
         {:ok, arrival_on} <- parse_date(operation, "arrival_on"),
         {:ok, departure_on} <- parse_date(operation, "departure_on"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         {:ok, room_data} <- validate_rooms(operation, departure_on, arrival_on, rate_plan) do
      lodging_total_cents = Enum.sum(Enum.map(room_data, & &1.lodging_cents))
      deposit_due_cents = Enum.sum(Enum.map(room_data, & &1.deposit_cents))

      group = %Group{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version_for(rate_plan, booked_on),
        status: @active,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        revision: 1
      }

      Repo.insert!(group)

      room_data
      |> Enum.with_index()
      |> Enum.each(fn {room, position} ->
        Repo.insert!(%Room{
          group_id: group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position
        })
      end)

      applied(operation_id, %{
        "group_id" => group_id,
        "deposit_due_cents" => deposit_due_cents,
        "revision" => 1
      })
    else
      {:error, code} -> rejected(operation_id, code, group_id)
    end
  end

  defp apply_existing_group_operation(type, operation, operation_id, group) do
    case check_expected_revision(operation, operation_id, group) do
      :ok ->
        case type do
          "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
          "reschedule_group" -> reschedule_group(operation, operation_id, group)
          "cancel_group" -> cancel_group(operation, operation_id, group)
          "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id, group)
        end

      {:error, result} ->
        result
    end
  end

  defp check_expected_revision(operation, operation_id, group) do
    case optional_value(operation, "expected_revision") do
      :missing ->
        :ok

      {:present, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:error,
           rejected(operation_id, "stale_revision", group.group_id, %{
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           })}
        end

      {:present, _invalid_revision} ->
        {:error, rejected(operation_id, "invalid_operation", group.group_id)}
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_operation", group.group_id)

      not valid_positive_integer?(value(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", group.group_id)

      value(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        amount_cents = value(operation, "amount_cents")

        updated_group =
          group
          |> Changeset.change(
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            cash_paid_cents: cash_paid(group) + amount_cents,
            revision: group.revision + 1
          )
          |> Repo.update!()

        update_ledger!(cash_held_cents: amount_cents)

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding_deposit(updated_group),
          "revision" => updated_group.revision
        })
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_stay", group.group_id)

      true ->
        with {:ok, occurred_on} <- parse_date(operation, "occurred_on"),
             {:ok, new_arrival_on} <- parse_date(operation, "new_arrival_on"),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, shift)

          updated_group =
            group
            |> Changeset.change(
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            )
            |> Repo.update!()

          applied(operation_id, %{
            "group_id" => group.group_id,
            "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
            "policy_version" => policy_version(updated_group),
            "refundable_until" => refundable_until(updated_group),
            "revision" => updated_group.revision
          })
        else
          _ -> rejected(operation_id, "invalid_stay", group.group_id)
        end
    end
  end

  defp cancel_group(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_stay", group.group_id)

      true ->
        with {:ok, occurred_on} <- parse_date(operation, "occurred_on"),
             {:ok, refund_method} <- refund_method(operation) do
          refundable? = refundable?(group, occurred_on)

          if not refundable? and refund_method == @hotel_credit do
            rejected(operation_id, "refund_method_not_available", group.group_id)
          else
            settle_cancellation(
              group,
              operation_id,
              occurred_on,
              refundable?,
              refund_method
            )
          end
        else
          {:error, code} -> rejected(operation_id, code, group.group_id)
        end
    end
  end

  defp settle_cancellation(group, operation_id, occurred_on, refundable?, refund_method) do
    cash_paid_cents = cash_paid(group)
    settle_applied_credit(group.group_id, occurred_on, refundable?)

    credit_issued_cents =
      if refundable? and refund_method == @hotel_credit do
        credit_from_cash(cash_paid_cents)
      else
        0
      end

    if credit_issued_cents > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        expires_on: Date.add(occurred_on, 366)
      })
    end

    updated_group =
      group
      |> Changeset.change(status: @cancelled, revision: group.revision + 1)
      |> Repo.update!()

    ledger_changes = cancellation_ledger_changes(cash_paid_cents, refundable?, refund_method)

    update_ledger!(ledger_changes)
    refresh_credit_liability!()

    applied(operation_id, %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded_cents(cash_paid_cents, refundable?, refund_method),
      "retained_cents" => retained_cents(cash_paid_cents, refundable?, refund_method),
      "credit_issued_cents" => credit_issued_cents,
      "revision" => updated_group.revision
    })
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    cond do
      group.status != @active ->
        rejected(operation_id, "group_not_active", group.group_id)

      not valid_occurred_on?(operation) ->
        rejected(operation_id, "invalid_operation", group.group_id)

      not valid_positive_integer?(value(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", group.group_id)

      value(operation, "amount_cents") > outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        {:ok, occurred_on} = parse_date(operation, "occurred_on")
        amount_cents = value(operation, "amount_cents")
        lots = available_credit_lots(group.guest_id, occurred_on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
          rejected(operation_id, "insufficient_credit", group.group_id)
        else
          allocate_credit!(lots, group.group_id, amount_cents)

          updated_group =
            group
            |> Changeset.change(
              deposit_paid_cents: group.deposit_paid_cents + amount_cents,
              credit_paid_cents: credit_paid(group) + amount_cents,
              revision: group.revision + 1
            )
            |> Repo.update!()

          refresh_credit_liability!()

          applied(operation_id, %{
            "group_id" => group.group_id,
            "amount_cents" => amount_cents,
            "outstanding_deposit_cents" => outstanding_deposit(updated_group),
            "revision" => updated_group.revision
          })
        end
    end
  end

  defp settle_applied_credit(group_id, occurred_on, refundable?) do
    allocations =
      from(a in CreditAllocation,
        join: lot in CreditLot,
        on: lot.id == a.credit_lot_id,
        where: a.group_id == ^group_id,
        select: {a, lot}
      )
      |> Repo.all()

    Enum.each(allocations, fn {allocation, lot} ->
      if refundable? and Date.compare(lot.expires_on, occurred_on) == :gt do
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end
    end)

    Repo.delete_all(from(a in CreditAllocation, where: a.group_id == ^group_id))
  end

  defp allocate_credit!(lots, group_id, amount_cents) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining_cents ->
      amount_from_lot = min(lot.remaining_cents, remaining_cents)

      lot
      |> Changeset.change(remaining_cents: lot.remaining_cents - amount_from_lot)
      |> Repo.update!()

      Repo.insert!(%CreditAllocation{
        group_id: group_id,
        credit_lot_id: lot.id,
        amount_cents: amount_from_lot
      })

      remaining_cents = remaining_cents - amount_from_lot

      if remaining_cents == 0 do
        {:halt, 0}
      else
        {:cont, remaining_cents}
      end
    end)
  end

  defp cancellation_ledger_changes(cash_paid_cents, refundable?, refund_method) do
    cash_settlement =
      cond do
        refundable? and refund_method == @hotel_credit ->
          [cash_converted_to_credit_cents: cash_paid_cents]

        refundable? ->
          [cash_refunded_cents: cash_paid_cents]

        true ->
          [cash_retained_cents: cash_paid_cents]
      end

    [cash_held_cents: -cash_paid_cents] ++ cash_settlement
  end

  defp refunded_cents(cash_paid_cents, true, @cash), do: cash_paid_cents
  defp refunded_cents(_cash_paid_cents, _refundable?, _refund_method), do: 0

  defp retained_cents(cash_paid_cents, false, @cash), do: cash_paid_cents
  defp retained_cents(_cash_paid_cents, _refundable?, _refund_method), do: 0

  defp refund_method(operation) do
    case optional_value(operation, "refund_method") do
      :missing -> {:ok, @cash}
      {:present, @cash} -> {:ok, @cash}
      {:present, @hotel_credit} -> {:ok, @hotel_credit}
      {:present, _invalid_method} -> {:error, "invalid_operation"}
    end
  end

  defp credit_from_cash(cash_cents), do: cash_cents + rounded_percentage(cash_cents, 10)

  defp rounded_percentage(amount_cents, percentage),
    do: div(amount_cents * percentage + 50, 100)

  defp cash_paid(group), do: group.cash_paid_cents || 0
  defp credit_paid(group), do: group.credit_paid_cents || 0

  defp validate_operation_id(operation_id) when is_binary(operation_id) and operation_id != "",
    do: :ok

  defp validate_operation_id(_operation_id), do: {:error, "invalid_operation"}

  defp required_identifier(operation, key) do
    case value(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(operation, key) do
    case value(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      _ ->
        {:error, "invalid_stay"}
    end
  end

  defp valid_occurred_on?(operation),
    do: match?({:ok, _date}, parse_date(operation, "occurred_on"))

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(operation) do
    case value(operation, "rate_plan") do
      @flexible -> {:ok, @flexible}
      @advance_purchase -> {:ok, @advance_purchase}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp validate_rooms(operation, departure_on, arrival_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    case value(operation, "rooms") do
      rooms when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, MapSet.new(), []}, fn {room, _position}, {:ok, ids, acc} ->
          with {:ok, room_id} <- required_identifier(room, "room_id"),
               {:ok, nightly_rate_cents} <- positive_room_rate(room),
               false <- MapSet.member?(ids, room_id) do
            lodging_cents = nights * nightly_rate_cents
            deposit_cents = deposit_for(rate_plan, lodging_cents)

            {:cont,
             {:ok, MapSet.put(ids, room_id),
              [
                %{
                  room_id: room_id,
                  nightly_rate_cents: nightly_rate_cents,
                  lodging_cents: lodging_cents,
                  deposit_cents: deposit_cents
                }
                | acc
              ]}}
          else
            _ -> {:halt, {:error, "invalid_rooms"}}
          end
        end)
        |> case do
          {:ok, _ids, rooms} -> {:ok, Enum.reverse(rooms)}
          {:error, code} -> {:error, code}
        end

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp positive_room_rate(room) when is_map(room) do
    case value(room, "nightly_rate_cents") do
      rate when is_integer(rate) and rate > 0 -> {:ok, rate}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp positive_room_rate(_room), do: {:error, "invalid_rooms"}

  defp deposit_for(@advance_purchase, lodging_cents), do: lodging_cents
  defp deposit_for(@flexible, lodging_cents), do: rounded_percentage(lodging_cents, 20)

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: @flex_14, else: @flex_30
  end

  defp policy_version(group) do
    group.policy_version || policy_version_for(group.rate_plan, group.booked_on)
  end

  defp policy_window(@flex_14), do: 14
  defp policy_window(@flex_30), do: 30
  defp policy_window(@advance_nonrefundable), do: nil

  defp refundable?(group, occurred_on) do
    case policy_window(policy_version(group)) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp refundable_until(group) do
    case policy_window(policy_version(group)) do
      nil -> nil
      window -> Date.to_iso8601(Date.add(group.arrival_on, -window))
    end
  end

  defp valid_positive_integer?(amount), do: is_integer(amount) and amount > 0

  defp outstanding_deposit(group) do
    if group.status == @active do
      group.deposit_due_cents - group.deposit_paid_cents
    else
      0
    end
  end

  defp available_credit_lots(guest_id, on) do
    from(lot in CreditLot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
    |> Repo.all()
  end

  defp credit_liability_as_of(on) do
    available_cents =
      available_credit_lots_for_liability(on)
      |> Enum.map(& &1.remaining_cents)
      |> Enum.sum()

    applied_cents =
      from(a in CreditAllocation,
        join: group in Group,
        on: group.group_id == a.group_id,
        where: group.status == @active,
        select: a.amount_cents
      )
      |> Repo.all()
      |> Enum.sum()

    available_cents + applied_cents
  end

  defp available_credit_lots_for_liability(on) do
    from(lot in CreditLot,
      where: lot.remaining_cents > 0 and lot.expires_on > ^on
    )
    |> Repo.all()
  end

  defp refresh_credit_liability! do
    ledger = Repo.get!(Ledger, 1)

    ledger
    |> Changeset.change(credit_liability_cents: credit_liability_as_of(Date.utc_today()))
    |> Repo.update!()
  end

  defp update_ledger!(increments) do
    ledger = Repo.get!(Ledger, 1)

    updated_values =
      Enum.reduce(increments, %{}, fn {field, increment}, values ->
        Map.put(values, field, Map.fetch!(ledger, field) + increment)
      end)

    ledger
    |> Changeset.change(updated_values)
    |> Repo.update!()
  end

  defp serialize_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "rooms" =>
        group.rooms
        |> Enum.sort_by(& &1.position)
        |> Enum.map(fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => cash_paid(group),
      "credit_paid_cents" => credit_paid(group),
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp serialize_credit_lot(lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

  defp rejected(operation_id, code, group_id \\ nil, extra \\ []) do
    base = %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    base = if group_id, do: Map.put(base, "group_id", group_id), else: base
    Enum.into(extra, base)
  end

  defp operation_type(operation) do
    case value(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp equivalent_payload?(left, right),
    do: canonical_payload(left) == canonical_payload(right)

  defp canonical_payload(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} ->
      {canonical_key(key), canonical_payload(nested_value)}
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp canonical_payload(value) when is_list(value),
    do: Enum.map(value, &canonical_payload/1)

  defp canonical_payload(value), do: value

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(key), do: inspect(key)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> value_for_atom_key(map, key)
    end
  end

  defp value(_map, _key), do: nil

  defp optional_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      atom_key_exists?(map, key) -> {:present, Map.get(map, String.to_existing_atom(key))}
      true -> :missing
    end
  end

  defp value_for_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp atom_key_exists?(map, key) do
    Map.has_key?(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> false
  end
end
