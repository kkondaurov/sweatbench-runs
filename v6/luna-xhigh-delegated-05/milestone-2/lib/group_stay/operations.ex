defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Ledger.Total
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @policy_cutover ~D[2027-01-01]

  @type result :: map()

  @spec parse_as_of(String.t() | nil) :: {:ok, Date.t()} | {:error, atom()}
  def parse_as_of(nil), do: {:ok, Date.utc_today()}

  def parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_as_of(_), do: {:error, :invalid_date}

  @spec submit_batch(list()) :: [result()]
  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @spec get_group(String.t()) :: map() | nil
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group.id,
              order_by: [asc: room.position]
          )

        group_response(group, rooms)
    end
  end

  @spec get_guest_credit(String.t(), Date.t()) :: map()
  def get_guest_credit(guest_id, as_of_date \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in Lot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^as_of_date,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  @spec get_ledger(Date.t()) :: map()
  def get_ledger(as_of_date \\ Date.utc_today()) do
    Repo.transaction(
      fn ->
        liability = credit_liability(as_of_date)

        if as_of_date == Date.utc_today(), do: sync_credit_liability(liability)

        ledger = Repo.get!(Total, 1)

        %{
          cash_held_cents: ledger.cash_held_cents,
          cash_refunded_cents: ledger.cash_refunded_cents,
          cash_retained_cents: ledger.cash_retained_cents,
          cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents,
          credit_liability_cents: liability
        }
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp submit_operation(operation) do
    Repo.transaction(
      fn ->
        case apply_operation(operation) do
          {:ok, result} ->
            sync_credit_liability()
            result

          {:error, result} ->
            Repo.rollback(result)
        end
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, result}) when is_map(result), do: result

  defp apply_operation(operation) when not is_map(operation) do
    {:error, reject(nil, "invalid_operation")}
  end

  defp apply_operation(operation) do
    operation_id = field(operation, "operation_id")

    with {:ok, type} <- required_type(operation),
         :ok <- validate_operation_id(operation_id) do
      case type do
        "open_group" ->
          open_group(operation, operation_id)

        type when type in ["record_cash_payment", "reschedule_group", "cancel_group"] ->
          apply_existing_group_operation(operation, operation_id, type)

        "apply_hotel_credit" ->
          apply_existing_group_operation(operation, operation_id, "apply_hotel_credit")

        _ ->
          {:error, reject(operation_id, "invalid_operation")}
      end
    else
      _ -> {:error, reject(operation_id, "invalid_operation")}
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         nil <- Repo.get_by(Group, group_id: group_id) do
      with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
           {:ok, guest_id} <- required_identifier(operation, "guest_id"),
           {:ok, property_id} <- required_identifier(operation, "property_id"),
           {:ok, arrival_on} <- required_date(operation, "arrival_on"),
           {:ok, departure_on} <- required_date(operation, "departure_on"),
           :ok <- validate_stay(arrival_on, departure_on),
           {:ok, rate_plan} <- validate_rate_plan(field(operation, "rate_plan")),
           {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
        nights = Date.diff(departure_on, arrival_on)
        rooms = Enum.map(rooms, &Map.put(&1, :lodging_cents, &1.nightly_rate_cents * nights))
        lodging_total_cents = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
        deposit_due_cents = deposit_due(rooms, rate_plan)

        group = %Group{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version(rate_plan, occurred_on),
          status: @active,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          revision: 1
        }

        case Repo.insert(group) do
          {:ok, group} ->
            Repo.insert_all(
              Room,
              Enum.map(rooms, fn room ->
                %{
                  group_id: group.id,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents,
                  position: room.position
                }
              end)
            )

            {:ok,
             applied(operation_id,
               group_id: group_id,
               deposit_due_cents: deposit_due_cents,
               revision: 1
             )}

          {:error, _changeset} ->
            {:error, reject(operation_id, "group_already_exists", group_id: group_id)}
        end
      else
        {:error, code} -> {:error, reject(operation_id, code, group_id: group_id)}
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code)}

      _group ->
        {:error,
         reject(operation_id, "group_already_exists", group_id: field(operation, "group_id"))}
    end
  end

  defp apply_existing_group_operation(operation, operation_id, type) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         group when not is_nil(group) <- Repo.get_by(Group, group_id: group_id),
         :ok <- check_expected_revision(operation, group) do
      case type do
        "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
        "reschedule_group" -> reschedule_group(operation, operation_id, group)
        "cancel_group" -> cancel_group(operation, operation_id, group)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id, group)
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code, group_id: field(operation, "group_id"))}

      nil ->
        {:error, reject(operation_id, "group_not_found", group_id: field(operation, "group_id"))}
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         {:ok, outstanding} <- payment_outstanding(group, amount_cents) do
      update_group(group,
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        cash_paid_cents: group.cash_paid_cents + amount_cents
      )

      update_ledger(cash_held_cents: amount_cents)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding - amount_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} ->
        {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         {:ok, outstanding} <- payment_outstanding(group, amount_cents),
         :ok <- ensure_credit_available(group.guest_id, amount_cents, occurred_on) do
      consume_credit(group.guest_id, group.id, amount_cents, occurred_on)

      update_group(group,
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        credit_paid_cents: group.credit_paid_cents + amount_cents
      )

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding - amount_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} ->
        {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- validate_reschedule(occurred_on, new_arrival_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      update_group(group,
        arrival_on: new_arrival_on,
        departure_on: new_departure_on
      )

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         new_arrival_on: new_arrival_on,
         new_departure_on: new_departure_on,
         policy_version: policy_version_for(group),
         refundable_until: refundable_until(group, new_arrival_on),
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation) do
      refundable = refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable do
        {:error, reject(operation_id, "refund_method_not_available", group_id: group.group_id)}
      else
        {refunded_cents, retained_cents, credit_issued_cents} =
          settle_cancellation(group, operation_id, occurred_on, refundable, refund_method)

        update_group(group, status: @cancelled)

        {:ok,
         applied(operation_id,
           group_id: group.group_id,
           refunded_cents: refunded_cents,
           retained_cents: retained_cents,
           credit_issued_cents: credit_issued_cents,
           revision: group.revision + 1
         )}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp settle_cancellation(group, _operation_id, occurred_on, true, "cash") do
    restore_group_credit(group.id, occurred_on)

    update_ledger_if_needed(
      cash_held_cents: -group.cash_paid_cents,
      cash_refunded_cents: group.cash_paid_cents
    )

    {group.cash_paid_cents, 0, 0}
  end

  defp settle_cancellation(group, operation_id, occurred_on, true, "hotel_credit") do
    restore_group_credit(group.id, occurred_on)
    credit_issued_cents = credit_with_bonus(group.cash_paid_cents)

    if credit_issued_cents > 0 do
      create_credit_lot(
        group.guest_id,
        operation_id,
        credit_issued_cents,
        Date.add(occurred_on, 365)
      )
    end

    update_ledger_if_needed(
      cash_held_cents: -group.cash_paid_cents,
      cash_converted_to_credit_cents: group.cash_paid_cents
    )

    {0, 0, credit_issued_cents}
  end

  defp settle_cancellation(group, _operation_id, _occurred_on, false, "cash") do
    consume_group_credit(group.id)

    update_ledger_if_needed(
      cash_held_cents: -group.cash_paid_cents,
      cash_retained_cents: group.cash_paid_cents
    )

    {0, group.cash_paid_cents, 0}
  end

  defp refund_method(operation) do
    if has_field?(operation, "refund_method") do
      case field(operation, "refund_method") do
        "cash" -> {:ok, "cash"}
        "hotel_credit" -> {:ok, "hotel_credit"}
        _ -> {:error, "invalid_refund_method"}
      end
    else
      {:ok, "cash"}
    end
  end

  defp refundable?(group, occurred_on) do
    case policy_version_for(group) do
      "flex-14" -> Date.diff(group.arrival_on, occurred_on) >= 14
      "flex-30" -> Date.diff(group.arrival_on, occurred_on) >= 30
      _ -> false
    end
  end

  defp policy_version(@advance_purchase, _booked_on), do: "advance-nonrefundable"

  defp policy_version(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version_for(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp policy_version_for(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp refundable_until(group), do: refundable_until(group, group.arrival_on)

  defp refundable_until(group, arrival_on) do
    case policy_version_for(group) do
      "flex-14" -> Date.add(arrival_on, -14)
      "flex-30" -> Date.add(arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp credit_with_bonus(0), do: 0

  defp credit_with_bonus(cash_cents),
    do: cash_cents + round_half_up(cash_cents * 10, 100)

  defp ensure_credit_available(guest_id, amount_cents, occurred_on) do
    if available_credit(guest_id, occurred_on) >= amount_cents,
      do: :ok,
      else: {:error, "insufficient_credit"}
  end

  defp available_credit(guest_id, as_of_date) do
    Repo.aggregate(
      from(lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^as_of_date
      ),
      :sum,
      :remaining_cents
    ) || 0
  end

  defp consume_credit(guest_id, group_id, amount_cents, occurred_on) do
    lots = available_credit_lots(guest_id, occurred_on)

    Enum.reduce_while(lots, amount_cents, fn lot, remaining ->
      amount = min(remaining, lot.remaining_cents)

      if amount > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - amount)
        |> Repo.update!()

        Repo.insert!(%Allocation{
          group_id: group_id,
          lot_id: lot.id,
          amount_cents: amount
        })
      end

      next_remaining = remaining - amount

      if next_remaining == 0,
        do: {:halt, 0},
        else: {:cont, next_remaining}
    end)
  end

  defp available_credit_lots(guest_id, as_of_date) do
    Repo.all(
      from lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^as_of_date,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp create_credit_lot(guest_id, source_operation_id, amount_cents, expires_on) do
    Repo.insert!(%Lot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      expires_on: expires_on
    })
  end

  defp restore_group_credit(group_id, occurred_on) do
    allocations =
      Repo.all(from allocation in Allocation, where: allocation.group_id == ^group_id)
      |> Repo.preload(:lot)

    allocations
    |> Enum.group_by(& &1.lot_id)
    |> Enum.reduce(0, fn {_lot_id, lot_allocations}, expired_total ->
      lot = hd(lot_allocations).lot
      applied_cents = Enum.reduce(lot_allocations, 0, &(&1.amount_cents + &2))

      if Date.compare(lot.expires_on, occurred_on) == :lt do
        expired_cents = lot.remaining_cents + applied_cents

        lot
        |> Ecto.Changeset.change(remaining_cents: 0)
        |> Repo.update!()

        expired_total + expired_cents
      else
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + applied_cents)
        |> Repo.update!()

        expired_total
      end
    end)
    |> tap(fn _ ->
      Repo.delete_all(from allocation in Allocation, where: allocation.group_id == ^group_id)
    end)
  end

  defp consume_group_credit(group_id) do
    query = from allocation in Allocation, where: allocation.group_id == ^group_id
    consumed_cents = Repo.aggregate(query, :sum, :amount_cents) || 0
    Repo.delete_all(query)
    consumed_cents
  end

  defp credit_liability(as_of_date) do
    available_credit_cents =
      Repo.aggregate(
        from(lot in Lot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^as_of_date
        ),
        :sum,
        :remaining_cents
      ) || 0

    applied_credit_cents =
      Repo.one(
        from allocation in Allocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: group.status == ^@active,
          select: sum(allocation.amount_cents)
      ) || 0

    available_credit_cents + applied_credit_cents
  end

  defp sync_credit_liability do
    sync_credit_liability(credit_liability(Date.utc_today()))
  end

  defp sync_credit_liability(liability) do
    ledger = Repo.get!(Total, 1)

    if ledger.credit_liability_cents != liability do
      ledger
      |> Ecto.Changeset.change(credit_liability_cents: liability)
      |> Repo.update!()
    end
  end

  defp update_group(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp update_ledger(deltas) do
    ledger = Repo.get!(Total, 1)

    attrs =
      Enum.reduce(deltas, %{}, fn {field, delta}, acc ->
        Map.put(acc, field, Map.fetch!(ledger, field) + delta)
      end)

    ledger
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp update_ledger_if_needed(deltas) do
    deltas
    |> Enum.reject(fn {_field, delta} -> delta == 0 end)
    |> case do
      [] -> :ok
      non_empty_deltas -> update_ledger(non_empty_deltas)
    end
  end

  defp group_response(group, rooms) do
    outstanding =
      if group.status == @active,
        do: group.deposit_due_cents - group.deposit_paid_cents,
        else: 0

    policy_version = policy_version_for(group)

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
      refundable_until: format_date(refundable_until(group)),
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
      outstanding_deposit_cents: outstanding
    }
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, acc} ->
      if Enum.any?(acc, &(&1.room_id == field(room, "room_id"))) do
        {:halt, {:error, "invalid_rooms"}}
      else
        with {:ok, room_id} <- required_identifier(room, "room_id"),
             {:ok, nightly_rate_cents} <- positive_amount(field(room, "nightly_rate_cents")) do
          {:cont,
           {:ok,
            [
              %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                lodging_cents: 0
              }
              | acc
            ]}}
        else
          {:error, _} -> {:halt, {:error, "invalid_rooms"}}
        end
      end
    end)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      error -> error
    end
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp deposit_due(rooms, @flexible) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + round_half_up(room.lodging_cents * 20, 100)
    end)
  end

  defp deposit_due(rooms, @advance_purchase), do: Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))

  defp required_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, key) when is_map(operation) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(_, _), do: {:error, "invalid_operation"}

  defp required_date(operation, key) do
    value = field(operation, key)

    case value do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_stay"}
        end

      _ ->
        if has_field?(operation, key),
          do: {:error, "invalid_stay"},
          else: {:error, "invalid_operation"}
    end
  end

  defp validate_stay(arrival_on, departure_on),
    do: if(Date.after?(departure_on, arrival_on), do: :ok, else: {:error, "invalid_stay"})

  defp validate_reschedule(occurred_on, new_arrival_on) do
    if Date.after?(new_arrival_on, occurred_on), do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(@flexible), do: {:ok, @flexible}
  defp validate_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp usable_amount(amount) do
    case positive_amount(amount) do
      {:ok, amount} -> {:ok, amount}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp positive_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp positive_amount(_), do: {:error, "invalid_amount"}

  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp payment_outstanding(group, amount_cents) do
    outstanding = outstanding_deposit(group)

    if amount_cents <= outstanding,
      do: {:ok, outstanding},
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp ensure_active(%Group{status: @active}), do: :ok
  defp ensure_active(_), do: {:error, "group_not_active"}

  defp check_expected_revision(operation, group) do
    if has_field?(operation, "expected_revision") and
         field(operation, "expected_revision") !== group.revision do
      {:error,
       {:stale_revision,
        [
          expected_revision: field(operation, "expected_revision"),
          actual_revision: group.revision
        ]}}
    else
      :ok
    end
  end

  defp reject(operation_id, code, fields \\ [])

  defp reject(operation_id, {:stale_revision, fields}, base_fields) do
    reject(operation_id, "stale_revision", Keyword.merge(base_fields, fields))
  end

  defp reject(operation_id, code, fields) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))

  defp validate_operation_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_operation_id(_), do: {:error, "invalid_operation"}

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp field(_, _), do: nil

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp has_field?(_, _), do: false

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)
end
