defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditEntitlement
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.FundingAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Operation
  alias GroupStay.Groups.PaymentStatement
  alias GroupStay.Groups.Room

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @active "active"
  @cancelled "cancelled"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @flex_30_start ~D[2027-01-01]
  @flex_14_days 14
  @flex_30_days 30
  @credit_available_days 365
  @cash "cash"
  @hotel_credit "hotel_credit"

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> preload_rooms()
  end

  def get_group(_), do: nil

  def get_operation(operation_id) when is_binary(operation_id) do
    Repo.get_by(Operation, operation_id: operation_id)
  end

  def get_operation(_), do: nil

  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case get_operation(payment_operation_id) do
      nil ->
        {:error, :not_found}

      operation ->
        if applied_cash_payment?(operation) do
          {:ok, serialize_payment_statement(payment_view(operation))}
        else
          {:error, :not_reconcilable}
        end
    end
  end

  def get_payment_statement(_), do: {:error, :not_found}

  def backfill_room_accounting! do
    Group
    |> Repo.all()
    |> Enum.each(&backfill_group!/1)
  end

  def backfill_group_accounting!(%Group{} = group), do: backfill_group!(group)

  def serialize_group(%Group{} = group) do
    group = preload_rooms(group)
    policy_version = policy_version(group)

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
      policy_version: policy_version,
      refundable_until: iso_date(refundable_until(group.arrival_on, policy_version)),
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents
    }
  end

  def guest_credit(guest_id, as_of \\ nil) when is_binary(guest_id) do
    as_of = as_of_date(as_of)
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end),
      lots: Enum.map(lots, &serialize_lot/1)
    }
  end

  def ledger_totals(as_of \\ nil) do
    as_of = as_of_date(as_of)

    cash =
      Group
      |> select([g], %{
        status: g.status,
        cash_paid_cents: g.cash_paid_cents,
        refunded_cents: g.refunded_cents,
        retained_cents: g.retained_cents,
        cash_converted_to_credit_cents: g.cash_converted_to_credit_cents,
        cash_reduced_cents: g.cash_reduced_cents,
        cash_charged_back_cents: g.cash_charged_back_cents
      })
      |> Repo.all()
      |> Enum.reduce(
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0
        },
        fn group, acc ->
          held = if group.status == @active, do: group.cash_paid_cents, else: 0

          %{
            cash_held_cents: acc.cash_held_cents + held,
            cash_refunded_cents: acc.cash_refunded_cents + group.refunded_cents,
            cash_retained_cents: acc.cash_retained_cents + group.retained_cents,
            cash_converted_to_credit_cents:
              acc.cash_converted_to_credit_cents + group.cash_converted_to_credit_cents,
            cash_reduced_cents: acc.cash_reduced_cents + group.cash_reduced_cents,
            cash_charged_back_cents: acc.cash_charged_back_cents + group.cash_charged_back_cents
          }
        end
      )

    cash
    |> Map.put(:credit_liability_cents, credit_liability_cents(as_of))
    |> Map.put(:credit_shortfall_cents, credit_shortfall_cents())
  end

  def as_of_date(%Date{} = date), do: date

  def as_of_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  def as_of_date(_), do: Date.utc_today()

  def room_deposit_cents(lodging_cents, @flexible), do: round_percent(lodging_cents, 20)
  def room_deposit_cents(lodging_cents, @advance_purchase), do: lodging_cents

  def round_percent(amount_cents, percent)
      when is_integer(amount_cents) and is_integer(percent) and amount_cents >= 0 do
    numerator = amount_cents * percent
    quotient = div(numerator, 100)
    remainder = rem(numerator, 100)

    if remainder >= 50, do: quotient + 1, else: quotient
  end

  defp apply_operation(operation) when is_map(operation) do
    operation = canonicalize(operation)

    case Map.get(operation, "operation_id") do
      operation_id when is_binary(operation_id) and operation_id != "" ->
        apply_identified(operation, operation_id)

      _ ->
        apply_unidentified(operation)
    end
  end

  defp apply_operation(_) do
    %{status: "rejected", code: "invalid_operation"}
  end

  defp apply_identified(operation, operation_id) do
    case fetch_stored_operation(operation_id) do
      %Operation{} = existing ->
        replay(existing, operation, operation_id)

      nil ->
        first_attempt(operation, operation_id)
    end
  end

  defp apply_unidentified(operation) do
    case Repo.transaction(fn ->
           case dispatch(operation) do
             {:applied, fields} -> applied(nil, fields)
             {:rejected, fields} -> Repo.rollback({:handled_rejection, fields})
           end
         end) do
      {:ok, result} -> result
      {:error, {:handled_rejection, fields}} -> rejected(nil, fields)
    end
  end

  defp replay(existing, operation, operation_id) do
    if payloads_equivalent?(existing.payload, operation) do
      existing.result
    else
      rejected(operation_id, %{code: "operation_id_conflict"})
    end
  end

  defp first_attempt(operation, operation_id) do
    payload = canonicalize(operation)
    type = operation_type(operation)

    case Repo.transaction(fn ->
           Repo.query!("SAVEPOINT domain_op")

           result =
             case dispatch(operation) do
               {:applied, fields} ->
                 applied(operation_id, fields)

               {:rejected, fields} ->
                 Repo.query!("ROLLBACK TO SAVEPOINT domain_op")
                 rejected(operation_id, fields)
             end

           persist_in_transaction!(operation_id, type, payload, result)
         end) do
      {:ok, result} ->
        result

      {:error, :duplicate} ->
        replay_stored(operation_id, payload)
    end
  end

  defp persist_in_transaction!(operation_id, type, payload, result) do
    case persist_operation(operation_id, type, payload, result) do
      {:ok, stored} -> stored.result
      {:error, :duplicate} -> Repo.rollback(:duplicate)
    end
  end

  defp replay_stored(operation_id, payload) do
    case fetch_stored_operation(operation_id) do
      %Operation{} = existing -> replay(existing, payload, operation_id)
    end
  end

  defp persist_operation(operation_id, type, payload, result) do
    changeset =
      Operation.changeset(%Operation{}, %{
        operation_id: operation_id,
        type: type,
        payload: payload,
        result: canonicalize(result)
      })

    try do
      case Repo.insert(changeset) do
        {:ok, stored} ->
          {:ok, stored}

        {:error, %Ecto.Changeset{} = failed} ->
          if unique_operation_id_error?(failed) do
            {:error, :duplicate}
          else
            raise Ecto.InvalidChangesetError, action: :insert, changeset: failed
          end
      end
    rescue
      exception in [Ecto.ConstraintError] ->
        if unique_constraint_error?(exception) do
          {:error, :duplicate}
        else
          reraise exception, __STACKTRACE__
        end
    end
  end

  defp fetch_stored_operation(operation_id) do
    Repo.get_by(Operation, operation_id: operation_id)
  end

  defp payloads_equivalent?(left, right) do
    canonicalize(left) == canonicalize(right)
  end

  defp canonicalize(%{__struct__: _} = struct), do: struct

  defp canonicalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), canonicalize(value)} end)
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp unique_operation_id_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp unique_constraint_error?(%Ecto.ConstraintError{type: :unique} = exception) do
    exception.constraint in ["operations_operation_id_index", "operation_id"]
  end

  defp unique_constraint_error?(_), do: false

  defp dispatch(operation) do
    case operation_type(operation) do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "cancel_rooms" -> cancel_rooms(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      _ -> reject("invalid_operation")
    end
  end

  defp operation_type(%{"type" => type}) when is_atom(type), do: Atom.to_string(type)
  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil

  defp open_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         :ok <- reject_if_exists(group_id),
         {:ok, guest_id} <- require_id(operation, "guest_id"),
         {:ok, property_id} <- require_id(operation, "property_id"),
         {:ok, booked_on} <- require_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- require_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- require_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay_length(arrival_on, departure_on),
         {:ok, rate_plan} <- require_rate_plan(operation),
         {:ok, rooms} <- parse_rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)

      rooms =
        Enum.map(rooms, fn room ->
          Map.put(room, :lodging_cents, nights * room.nightly_rate_cents)
        end)

      persist_open_group(%{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    end
  end

  defp persist_open_group(attrs) do
    lodging_total_cents =
      Enum.reduce(attrs.rooms, 0, fn room, acc -> acc + room.lodging_cents end)

    deposit_due_cents =
      Enum.reduce(attrs.rooms, 0, fn room, acc ->
        acc + room_deposit_cents(room.lodging_cents, attrs.rate_plan)
      end)

    policy_version = policy_version_for(attrs.rate_plan, attrs.booked_on)

    group_attrs = %{
      group_id: attrs.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: attrs.booked_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      status: @active,
      revision: 1,
      policy_version: policy_version,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      outstanding_deposit_cents: deposit_due_cents,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      cash_reduced_cents: 0,
      cash_charged_back_cents: 0
    }

    case %Group{} |> Group.changeset(group_attrs) |> Repo.insert() do
      {:ok, group} ->
        Enum.each(attrs.rooms, fn room ->
          deposit_due_cents = room_deposit_cents(room.lodging_cents, attrs.rate_plan)

          %Room{}
          |> Room.changeset(%{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position,
            group_id: group.id,
            status: @active,
            lodging_cents: room.lodging_cents,
            deposit_due_cents: deposit_due_cents,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          })
          |> Repo.insert!()
        end)

        {:applied,
         %{
           group_id: attrs.group_id,
           deposit_due_cents: deposit_due_cents,
           revision: 1
         }}

      {:error, changeset} ->
        if unique_group_id_error?(changeset) do
          reject("group_already_exists")
        else
          reject("invalid_operation")
        end
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, amount_cents} <- require_payment_amount(operation) do
      if amount_cents > group.outstanding_deposit_cents do
        reject("payment_exceeds_outstanding")
      else
        operation_id = map_get(operation, :operation_id)
        group = load_group(group)
        allocate_to_rooms(group, amount_cents, cash_source_attrs(operation_id))
        persist_payment_statement!(group_id, operation_id, amount_cents)
        revision = group.revision + 1
        totals = active_room_totals(load_group(group))

        group
        |> Group.changeset(Map.put(totals, :revision, revision))
        |> Repo.update!()

        {:applied,
         %{
           group_id: group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: totals.outstanding_deposit_cents,
           revision: revision
         }}
      end
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, occurred_on} <- require_date(operation, "occurred_on", "invalid_operation"),
         {:ok, amount_cents} <- require_payment_amount(operation) do
      cond do
        amount_cents > group.outstanding_deposit_cents ->
          reject("payment_exceeds_outstanding")

        true ->
          operation_id = map_get(operation, :operation_id)

          case consume_credit(load_group(group), amount_cents, occurred_on, operation_id) do
            :ok ->
              revision = group.revision + 1
              totals = active_room_totals(load_group(group))

              group
              |> Group.changeset(Map.put(totals, :revision, revision))
              |> Repo.update!()

              {:applied,
               %{
                 group_id: group_id,
                 amount_cents: amount_cents,
                 outstanding_deposit_cents: totals.outstanding_deposit_cents,
                 revision: revision
               }}

            :insufficient ->
              reject("insufficient_credit")
          end
      end
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, occurred_on} <- require_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- require_date(operation, "new_arrival_on", "invalid_stay"),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)
      revision = group.revision + 1
      policy_version = policy_version(group)

      group
      |> Group.changeset(%{
        arrival_on: new_arrival_on,
        departure_on: new_departure_on,
        revision: revision
      })
      |> Repo.update!()

      {:applied,
       %{
         group_id: group_id,
         new_arrival_on: Date.to_iso8601(new_arrival_on),
         new_departure_on: Date.to_iso8601(new_departure_on),
         revision: revision,
         policy_version: policy_version,
         refundable_until: iso_date(refundable_until(new_arrival_on, policy_version))
       }}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, occurred_on} <- require_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- require_refund_method(operation) do
      group = load_group(group)
      refundable? = refundable?(group, occurred_on)

      cond do
        refund_method == @hotel_credit and not refundable? ->
          reject("refund_method_not_available")

        true ->
          rooms = active_rooms(group)

          settle_selected_rooms(
            group,
            rooms,
            operation,
            occurred_on,
            refund_method,
            refundable?,
            :cancel_group
          )
      end
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group_id} <- require_id(operation, "group_id"),
         {:ok, group} <- fetch_group(group_id),
         :ok <- match_revision(group, operation),
         :ok <- require_active(group),
         {:ok, occurred_on} <- require_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- require_refund_method(operation) do
      group = load_group(group)

      with {:ok, rooms} <- parse_selected_rooms(operation, group) do
        refundable? = refundable?(group, occurred_on)

        cond do
          refund_method == @hotel_credit and not refundable? ->
            reject("refund_method_not_available")

          true ->
            settle_selected_rooms(
              group,
              rooms,
              operation,
              occurred_on,
              refund_method,
              refundable?,
              :cancel_rooms
            )
        end
      end
    end
  end

  defp settle_selected_rooms(
         group,
         rooms,
         operation,
         occurred_on,
         refund_method,
         refundable?,
         result_kind
       ) do
    room_ids = Enum.map(rooms, & &1.id)

    allocs =
      FundingAllocation
      |> where([a], a.room_id in ^room_ids)
      |> order_by([a], asc: a.fill_sequence)
      |> Repo.all()

    cash_allocs = Enum.filter(allocs, &(&1.funding_kind == "cash"))
    credit_allocs = Enum.filter(allocs, &(&1.funding_kind == "credit"))
    cash_total = Enum.reduce(cash_allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      cash_settlement_amount(cash_total, refund_method, refundable?)

    with :ok <-
           maybe_issue_converted_credit(
             group,
             operation,
             credit_issued_cents,
             occurred_on,
             cash_allocs,
             converted_cents
           ) do
      apply_cash_disposition(cash_allocs, refunded_cents, retained_cents, converted_cents)
      settle_room_credit(group, credit_allocs, occurred_on, refundable?)
      Enum.each(allocs, &Repo.delete!/1)

      Enum.each(rooms, fn room ->
        room
        |> Room.changeset(%{status: @cancelled, cash_paid_cents: 0, credit_paid_cents: 0})
        |> Repo.update!()
      end)

      sync_credit_applications(group)

      revision = group.revision + 1
      totals = active_room_totals(load_group(group))

      group
      |> Group.changeset(
        totals
        |> Map.put(:revision, revision)
        |> Map.put(:refunded_cents, group.refunded_cents + refunded_cents)
        |> Map.put(:retained_cents, group.retained_cents + retained_cents)
        |> Map.put(
          :cash_converted_to_credit_cents,
          group.cash_converted_to_credit_cents + converted_cents
        )
      )
      |> Repo.update!()

      settlement_result(
        result_kind,
        group.group_id,
        rooms,
        refunded_cents,
        retained_cents,
        credit_issued_cents,
        revision
      )
    end
  end

  defp settlement_result(
         :cancel_group,
         group_id,
         _rooms,
         refunded_cents,
         retained_cents,
         credit_issued_cents,
         revision
       ) do
    {:applied,
     %{
       group_id: group_id,
       refunded_cents: refunded_cents,
       retained_cents: retained_cents,
       credit_issued_cents: credit_issued_cents,
       revision: revision
     }}
  end

  defp settlement_result(
         :cancel_rooms,
         group_id,
         rooms,
         refunded_cents,
         retained_cents,
         credit_issued_cents,
         revision
       ) do
    {:applied,
     %{
       group_id: group_id,
       cancelled_room_ids: Enum.map(rooms, & &1.room_id),
       refunded_cents: refunded_cents,
       retained_cents: retained_cents,
       credit_issued_cents: credit_issued_cents,
       revision: revision
     }}
  end

  defp cash_settlement_amount(cash, refund_method, true) do
    if refund_method == @hotel_credit do
      {0, 0, cash, credit_from_cash(cash)}
    else
      {cash, 0, 0, 0}
    end
  end

  defp cash_settlement_amount(cash, _refund_method, false), do: {0, cash, 0, 0}

  defp maybe_issue_converted_credit(_group, _operation, 0, _occurred_on, _allocs, _converted),
    do: :ok

  defp maybe_issue_converted_credit(
         group,
         operation,
         credit_issued_cents,
         occurred_on,
         cash_allocs,
         converted_cents
       )
       when converted_cents > 0 do
    with {:ok, source_operation_id} <- require_id(operation, "operation_id") do
      lot =
        issue_credit_lot(group.guest_id, source_operation_id, credit_issued_cents, occurred_on)

      persist_entitlements!(lot, cash_allocs)
      :ok
    end
  end

  defp credit_from_cash(0), do: 0
  defp credit_from_cash(cash_cents), do: cash_cents + round_percent(cash_cents, 10)

  defp consume_credit(group, amount_cents, occurred_on, operation_id) do
    lots = available_lots(group.guest_id, occurred_on)
    available = Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end)

    if available < amount_cents do
      :insufficient
    else
      consume_lots(lots, group, amount_cents, operation_id)
      :ok
    end
  end

  defp consume_lots(lots, group, amount_cents, operation_id) do
    {slices, _} =
      Enum.reduce_while(lots, {[], amount_cents}, fn lot, {slices, remaining} ->
        take = min(lot.remaining_cents, remaining)

        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - take})
        |> Repo.update!()

        %CreditApplication{}
        |> CreditApplication.changeset(%{
          amount_cents: take,
          group_id: group.id,
          credit_lot_id: lot.id
        })
        |> Repo.insert!()

        slices = [{lot, take} | slices]

        case remaining - take do
          0 -> {:halt, {Enum.reverse(slices), 0}}
          left -> {:cont, {slices, left}}
        end
      end)

    Enum.each(slices, fn {lot, take} ->
      allocate_to_rooms(load_group(group), take, credit_source_attrs(operation_id, lot.id))
    end)
  end

  defp settle_room_credit(_group, credit_allocs, occurred_on, refundable?) do
    Enum.each(credit_allocs, fn alloc ->
      if refundable? and alloc.credit_lot_id do
        lot = Repo.get!(CreditLot, alloc.credit_lot_id)
        restore_to_lot(lot, alloc.amount_cents, occurred_on)
      end
    end)
  end

  defp restore_to_lot(lot, amount_cents, occurred_on) do
    lot = Repo.get!(CreditLot, lot.id)
    absorb = min(lot.unrecovered_clawback_cents, amount_cents)
    leftover = amount_cents - absorb
    new_clawback = lot.unrecovered_clawback_cents - absorb

    new_remaining =
      if leftover > 0 and Date.compare(lot.expires_on, occurred_on) != :lt do
        lot.remaining_cents + leftover
      else
        lot.remaining_cents
      end

    lot
    |> CreditLot.changeset(%{
      remaining_cents: new_remaining,
      unrecovered_clawback_cents: new_clawback
    })
    |> Repo.update!()
  end

  defp issue_credit_lot(guest_id, source_operation_id, amount_cents, occurred_on) do
    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      issued_cents: amount_cents,
      unrecovered_clawback_cents: 0,
      expires_on: Date.add(occurred_on, @credit_available_days)
    })
    |> Repo.insert!()
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment_operation_id} <- require_id(operation, "payment_operation_id"),
         {:ok, stored} <- fetch_required_operation(payment_operation_id) do
      case resolve_addressed_group(stored) do
        {:ok, group} ->
          with :ok <- match_revision(group, operation),
               :ok <- require_reducible(stored, payment_operation_id),
               {:ok, amount_cents} <- require_payment_amount(operation),
               :ok <- require_held_covers(payment_operation_id, amount_cents) do
            apply_cash_reduction(group, payment_operation_id, amount_cents)
          end

        :no_group ->
          reject("payment_not_reducible")
      end
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment_operation_id} <- require_id(operation, "payment_operation_id"),
         {:ok, stored} <- fetch_required_operation(payment_operation_id) do
      case resolve_addressed_group(stored) do
        {:ok, group} ->
          with :ok <- match_revision(group, operation),
               :ok <- require_chargeable(stored, payment_operation_id) do
            apply_chargeback(group, payment_operation_id)
          end

        :no_group ->
          reject("payment_not_chargeable")
      end
    end
  end

  defp apply_cash_reduction(group, payment_operation_id, amount_cents) do
    remove_held_cash(payment_operation_id, amount_cents)

    statement = fetch_statement!(payment_operation_id)

    statement
    |> PaymentStatement.changeset(%{
      held_cents: statement.held_cents - amount_cents,
      reduced_cents: statement.reduced_cents + amount_cents
    })
    |> Repo.update!()

    revision = group.revision + 1
    totals = active_room_totals(load_group(group))

    group
    |> Group.changeset(
      totals
      |> Map.put(:revision, revision)
      |> Map.put(:cash_reduced_cents, group.cash_reduced_cents + amount_cents)
    )
    |> Repo.update!()

    {:applied,
     %{
       payment_operation_id: payment_operation_id,
       group_id: group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: totals.outstanding_deposit_cents,
       revision: revision
     }}
  end

  defp apply_chargeback(group, payment_operation_id) do
    statement = fetch_statement!(payment_operation_id)
    held = statement.held_cents
    refunded = statement.refunded_cents
    retained = statement.retained_cents
    converted = statement.converted_to_credit_cents
    charged_back_cents = held + refunded + retained + converted

    if held > 0 do
      remove_held_cash(payment_operation_id, held)
    end

    if converted > 0 do
      revoke_payment_entitlements(payment_operation_id)
    end

    statement
    |> PaymentStatement.changeset(%{
      held_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: statement.charged_back_cents + charged_back_cents
    })
    |> Repo.update!()

    revision = group.revision + 1
    totals = active_room_totals(load_group(group))

    group
    |> Group.changeset(
      totals
      |> Map.put(:revision, revision)
      |> Map.put(:refunded_cents, group.refunded_cents - refunded)
      |> Map.put(:retained_cents, group.retained_cents - retained)
      |> Map.put(
        :cash_converted_to_credit_cents,
        group.cash_converted_to_credit_cents - converted
      )
      |> Map.put(:cash_charged_back_cents, group.cash_charged_back_cents + charged_back_cents)
    )
    |> Repo.update!()

    {:applied,
     %{
       payment_operation_id: payment_operation_id,
       group_id: group.group_id,
       charged_back_cents: charged_back_cents,
       outstanding_deposit_cents: totals.outstanding_deposit_cents,
       revision: revision
     }}
  end

  defp remove_held_cash(payment_operation_id, amount_cents) do
    allocs =
      FundingAllocation
      |> where(
        [a],
        a.source_operation_id == ^payment_operation_id and a.funding_kind == "cash"
      )
      |> order_by([a], desc: a.fill_sequence)
      |> Repo.all()
      |> Repo.preload(:room)

    Enum.reduce(allocs, amount_cents, fn alloc, left ->
      take = min(alloc.amount_cents, left)

      if take > 0 do
        if take == alloc.amount_cents do
          Repo.delete!(alloc)
        else
          alloc
          |> FundingAllocation.changeset(%{amount_cents: alloc.amount_cents - take})
          |> Repo.update!()
        end

        room = alloc.room

        room
        |> Room.changeset(%{cash_paid_cents: room.cash_paid_cents - take})
        |> Repo.update!()
      end

      left - take
    end)
  end

  defp revoke_payment_entitlements(payment_operation_id) do
    entitlements =
      CreditEntitlement
      |> where([e], e.payment_operation_id == ^payment_operation_id)
      |> preload(:credit_lot)
      |> Repo.all()

    Enum.each(entitlements, fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      take = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered = entitlement.entitlement_cents - take

      lot
      |> CreditLot.changeset(%{
        remaining_cents: lot.remaining_cents - take,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
      })
      |> Repo.update!()
    end)
  end

  defp persist_entitlements!(lot, cash_allocs) do
    cash_allocs
    |> entitlement_sources()
    |> Enum.reduce({0, 0}, fn {{_kind, operation_id}, amount}, {running, position} ->
      new_running = running + amount
      entitlement = credit_from_cash(new_running) - credit_from_cash(running)

      if entitlement > 0 do
        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          payment_operation_id: operation_id,
          entitlement_cents: entitlement,
          position: position
        })
        |> Repo.insert!()
      end

      {new_running, position + 1}
    end)
  end

  defp entitlement_sources(cash_allocs) do
    cash_allocs
    |> Enum.sort_by(& &1.fill_sequence)
    |> Enum.reduce([], fn alloc, acc ->
      key = {alloc.source_kind, alloc.source_operation_id}

      case Enum.find_index(acc, fn {existing, _} -> existing == key end) do
        nil ->
          acc ++ [{key, alloc.amount_cents}]

        index ->
          List.update_at(acc, index, fn {^key, amount} -> {key, amount + alloc.amount_cents} end)
      end
    end)
  end

  defp apply_cash_disposition(_allocs, 0, 0, 0), do: :ok

  defp apply_cash_disposition(cash_allocs, refunded, retained, converted) do
    field =
      cond do
        converted > 0 -> :converted_to_credit_cents
        refunded > 0 -> :refunded_cents
        retained > 0 -> :retained_cents
      end

    cash_allocs
    |> Enum.group_by(& &1.source_operation_id)
    |> Enum.each(fn
      {nil, _allocs} ->
        :ok

      {operation_id, allocs} ->
        amount = Enum.reduce(allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)
        move_statement_held(operation_id, field, amount)
    end)
  end

  defp move_statement_held(operation_id, field, amount) do
    case Repo.get_by(PaymentStatement, payment_operation_id: operation_id) do
      nil ->
        :ok

      statement ->
        statement
        |> PaymentStatement.changeset(
          Map.put(
            %{held_cents: statement.held_cents - amount},
            field,
            Map.fetch!(statement, field) + amount
          )
        )
        |> Repo.update!()
    end
  end

  defp allocate_to_rooms(group, amount_cents, source_attrs) do
    rooms = active_rooms(group)
    seq = next_fill_sequence(group.id)

    paid_field =
      if source_attrs.funding_kind == "cash", do: :cash_paid_cents, else: :credit_paid_cents

    Enum.reduce(rooms, {amount_cents, seq}, fn room, {left, seq} ->
      capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      take = min(capacity, left)

      if take > 0 do
        %FundingAllocation{}
        |> FundingAllocation.changeset(
          Map.merge(source_attrs, %{
            amount_cents: take,
            fill_sequence: seq,
            group_id: group.id,
            room_id: room.id
          })
        )
        |> Repo.insert!()

        room
        |> Room.changeset(%{paid_field => Map.fetch!(room, paid_field) + take})
        |> Repo.update!()

        {left - take, seq + 1}
      else
        {left, seq}
      end
    end)
  end

  defp cash_source_attrs(nil) do
    %{source_kind: "legacy", source_operation_id: nil, funding_kind: "cash", credit_lot_id: nil}
  end

  defp cash_source_attrs(operation_id) do
    %{
      source_kind: "cash_payment",
      source_operation_id: operation_id,
      funding_kind: "cash",
      credit_lot_id: nil
    }
  end

  defp credit_source_attrs(nil, lot_id) do
    %{
      source_kind: "legacy",
      source_operation_id: nil,
      funding_kind: "credit",
      credit_lot_id: lot_id
    }
  end

  defp credit_source_attrs(operation_id, lot_id) do
    %{
      source_kind: "hotel_credit",
      source_operation_id: operation_id,
      funding_kind: "credit",
      credit_lot_id: lot_id
    }
  end

  defp next_fill_sequence(group_pk) do
    max =
      FundingAllocation
      |> where([a], a.group_id == ^group_pk)
      |> select([a], max(a.fill_sequence))
      |> Repo.one()

    (max || 0) + 1
  end

  defp persist_payment_statement!(_group_id, nil, _amount), do: :ok

  defp persist_payment_statement!(group_id, operation_id, amount_cents) do
    %PaymentStatement{}
    |> PaymentStatement.changeset(%{
      payment_operation_id: operation_id,
      group_id: group_id,
      recorded_cents: amount_cents,
      held_cents: amount_cents,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    })
    |> Repo.insert!()
  end

  defp fetch_statement!(payment_operation_id) do
    Repo.get_by!(PaymentStatement, payment_operation_id: payment_operation_id)
  end

  defp fetch_required_operation(operation_id) do
    case fetch_stored_operation(operation_id) do
      nil -> reject("operation_not_found")
      operation -> {:ok, operation}
    end
  end

  defp resolve_addressed_group(operation) do
    case operation_group_id(operation) do
      group_id when is_binary(group_id) and group_id != "" ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> :no_group
          group -> {:ok, group}
        end

      _ ->
        :no_group
    end
  end

  defp require_reducible(stored, payment_operation_id) do
    if applied_cash_payment?(stored) do
      case Repo.get_by(PaymentStatement, payment_operation_id: payment_operation_id) do
        %PaymentStatement{held_cents: held} when held > 0 -> :ok
        _ -> reject("payment_not_reducible")
      end
    else
      reject("payment_not_reducible")
    end
  end

  defp require_chargeable(stored, payment_operation_id) do
    if applied_cash_payment?(stored) do
      case Repo.get_by(PaymentStatement, payment_operation_id: payment_operation_id) do
        %PaymentStatement{charged_back_cents: charged} when charged > 0 ->
          reject("payment_not_chargeable")

        %PaymentStatement{} = statement ->
          chargeable =
            statement.held_cents + statement.refunded_cents + statement.retained_cents +
              statement.converted_to_credit_cents

          if chargeable > 0, do: :ok, else: reject("payment_not_chargeable")

        nil ->
          reject("payment_not_chargeable")
      end
    else
      reject("payment_not_chargeable")
    end
  end

  defp require_held_covers(payment_operation_id, amount_cents) do
    statement = fetch_statement!(payment_operation_id)

    if amount_cents > statement.held_cents do
      reject("reduction_exceeds_held_cash")
    else
      :ok
    end
  end

  defp applied_cash_payment?(%Operation{type: type} = operation) do
    type == "record_cash_payment" and map_get(operation.result, :status) == "applied"
  end

  defp applied_cash_payment?(_), do: false

  defp payment_view(operation) do
    case Repo.get_by(PaymentStatement, payment_operation_id: operation.operation_id) do
      nil ->
        %{
          payment_operation_id: operation.operation_id,
          group_id: operation_group_id(operation),
          recorded_cents: operation_amount(operation) || 0,
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          reduced_cents: 0,
          charged_back_cents: 0
        }

      statement ->
        statement
    end
  end

  defp serialize_payment_statement(statement) do
    %{
      payment_operation_id: statement.payment_operation_id,
      original_group_id: statement.group_id,
      recorded_cents: statement.recorded_cents,
      held_cents: statement.held_cents,
      refunded_cents: statement.refunded_cents,
      retained_cents: statement.retained_cents,
      converted_to_credit_cents: statement.converted_to_credit_cents,
      reduced_cents: statement.reduced_cents,
      charged_back_cents: statement.charged_back_cents
    }
  end

  defp parse_selected_rooms(operation, group) do
    case Map.get(operation, "room_ids") do
      ids when is_list(ids) ->
        cond do
          ids == [] ->
            reject("invalid_rooms")

          Enum.any?(ids, fn id -> not (is_binary(id) and id != "") end) ->
            reject("invalid_rooms")

          ids != Enum.uniq(ids) ->
            reject("invalid_rooms")

          true ->
            by_id = Map.new(group.rooms, &{&1.room_id, &1})

            Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
              case Map.get(by_id, id) do
                %Room{status: @active} = room -> {:cont, {:ok, [room | acc]}}
                _ -> {:halt, reject("invalid_rooms")}
              end
            end)
            |> case do
              {:ok, rooms} -> {:ok, Enum.sort_by(rooms, & &1.position)}
              other -> other
            end
        end

      _ ->
        reject("invalid_operation")
    end
  end

  defp active_rooms(group) do
    group
    |> rooms_of()
    |> Enum.filter(&(&1.status == @active))
    |> Enum.sort_by(& &1.position)
  end

  defp rooms_of(%Group{rooms: rooms}) when is_list(rooms), do: rooms
  defp rooms_of(group), do: load_group(group).rooms

  defp load_group(%Group{id: id}) do
    Group
    |> Repo.get!(id)
    |> Repo.preload(:rooms)
  end

  defp active_room_totals(group) do
    rooms = active_rooms(group)

    lodging = Enum.reduce(rooms, 0, fn room, acc -> acc + room.lodging_cents end)
    due = Enum.reduce(rooms, 0, fn room, acc -> acc + room.deposit_due_cents end)
    cash = Enum.reduce(rooms, 0, fn room, acc -> acc + room.cash_paid_cents end)
    credit = Enum.reduce(rooms, 0, fn room, acc -> acc + room.credit_paid_cents end)

    %{
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit,
      outstanding_deposit_cents: due - cash - credit,
      status: if(rooms == [], do: @cancelled, else: group.status)
    }
  end

  defp sync_credit_applications(group) do
    CreditApplication
    |> where([a], a.group_id == ^group.id)
    |> Repo.delete_all()

    FundingAllocation
    |> where([a], a.group_id == ^group.id and a.funding_kind == "credit")
    |> Repo.all()
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn
      {nil, _} ->
        :ok

      {lot_id, allocs} ->
        amount = Enum.reduce(allocs, 0, fn alloc, acc -> acc + alloc.amount_cents end)

        %CreditApplication{}
        |> CreditApplication.changeset(%{
          amount_cents: amount,
          group_id: group.id,
          credit_lot_id: lot_id
        })
        |> Repo.insert!()
    end)
  end

  defp backfill_group!(group) do
    group = load_group(group)
    ensure_room_metadata!(group)
    group = load_group(group)
    persist_existing_payment_statements!(group)

    if group.status == @cancelled do
      cancel_unmigrated_rooms!(group)
      settle_existing_statements!(group)
      zero_cancelled_group_totals!(group)
    else
      allocate_existing_funding!(group)
    end

    backfill_lot_from_group!(Repo.get!(Group, group.id))
  end

  defp ensure_room_metadata!(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.each(group.rooms, fn room ->
      lodging =
        if room.lodging_cents > 0,
          do: room.lodging_cents,
          else: nights * room.nightly_rate_cents

      deposit =
        if room.deposit_due_cents > 0,
          do: room.deposit_due_cents,
          else: room_deposit_cents(lodging, group.rate_plan)

      status =
        cond do
          room.status in [@active, @cancelled] -> room.status
          group.status == @cancelled -> @cancelled
          true -> @active
        end

      if room.lodging_cents != lodging or room.deposit_due_cents != deposit or
           room.status != status do
        room
        |> Room.changeset(%{
          lodging_cents: lodging,
          deposit_due_cents: deposit,
          status: status
        })
        |> Repo.update!()
      end
    end)
  end

  defp cancel_unmigrated_rooms!(group) do
    group
    |> load_group()
    |> Map.get(:rooms)
    |> Enum.each(fn room ->
      if room.status != @cancelled do
        room
        |> Room.changeset(%{status: @cancelled, cash_paid_cents: 0, credit_paid_cents: 0})
        |> Repo.update!()
      end
    end)
  end

  defp zero_cancelled_group_totals!(group) do
    group = Repo.get!(Group, group.id)

    if group.lodging_total_cents != 0 or group.deposit_due_cents != 0 or
         group.cash_paid_cents != 0 or group.credit_paid_cents != 0 do
      group
      |> Group.changeset(%{
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        outstanding_deposit_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })
      |> Repo.update!()
    end
  end

  defp persist_existing_payment_statements!(group) do
    Enum.each(applied_funding_operations(group.group_id, "record_cash_payment"), fn operation ->
      amount = operation_amount(operation) || 0

      if amount > 0 and
           is_nil(Repo.get_by(PaymentStatement, payment_operation_id: operation.operation_id)) do
        persist_payment_statement!(group.group_id, operation.operation_id, amount)
      end
    end)
  end

  defp settle_existing_statements!(group) do
    field =
      cond do
        group.cash_converted_to_credit_cents > 0 -> :converted_to_credit_cents
        group.refunded_cents > 0 -> :refunded_cents
        group.retained_cents > 0 -> :retained_cents
        true -> nil
      end

    if field do
      PaymentStatement
      |> where([s], s.group_id == ^group.group_id)
      |> Repo.all()
      |> Enum.each(fn statement ->
        statement
        |> PaymentStatement.changeset(Map.put(%{held_cents: 0}, field, statement.held_cents))
        |> Repo.update!()
      end)
    end
  end

  defp allocate_existing_funding!(group) do
    existing =
      FundingAllocation
      |> where([a], a.group_id == ^group.id)
      |> select([a], count(a.id))
      |> Repo.one()

    if existing == 0 do
      group
      |> funding_sources()
      |> Enum.each(fn {amount, attrs} ->
        allocate_to_rooms(load_group(group), amount, attrs)
      end)
    end
  end

  defp funding_sources(group) do
    ops =
      (applied_funding_operations(group.group_id, "record_cash_payment") ++
         applied_funding_operations(group.group_id, "apply_hotel_credit"))
      |> Enum.sort_by(& &1.id)

    recorded_cash =
      ops
      |> Enum.filter(&(&1.type == "record_cash_payment"))
      |> Enum.reduce(0, fn op, acc -> acc + (operation_amount(op) || 0) end)

    recorded_credit =
      ops
      |> Enum.filter(&(&1.type == "apply_hotel_credit"))
      |> Enum.reduce(0, fn op, acc -> acc + (operation_amount(op) || 0) end)

    legacy_cash = max(group.cash_paid_cents - recorded_cash, 0)
    legacy_credit = max(group.credit_paid_cents - recorded_credit, 0)

    apps =
      CreditApplication
      |> where([a], a.group_id == ^group.id)
      |> order_by([a], asc: a.id)
      |> Repo.all()

    {legacy_slices, remaining_apps} = take_app_slices(apps, legacy_credit)

    sources =
      []
      |> maybe_add_source(legacy_cash, cash_source_attrs(nil))
      |> Kernel.++(
        Enum.map(legacy_slices, fn {app, amount} ->
          {amount, credit_source_attrs(nil, app.credit_lot_id)}
        end)
      )

    {sources, _} =
      Enum.reduce(ops, {sources, remaining_apps}, fn op, {sources, apps} ->
        amount = operation_amount(op) || 0

        if op.type == "record_cash_payment" do
          {sources ++ [{amount, cash_source_attrs(op.operation_id)}], apps}
        else
          {slices, apps} = take_app_slices(apps, amount)

          credit_sources =
            if slices == [] do
              [{amount, credit_source_attrs(op.operation_id, nil)}]
            else
              Enum.map(slices, fn {app, slice_amount} ->
                {slice_amount, credit_source_attrs(op.operation_id, app.credit_lot_id)}
              end)
            end

          {sources ++ credit_sources, apps}
        end
      end)

    sources
  end

  defp maybe_add_source(sources, amount, _attrs) when amount <= 0, do: sources
  defp maybe_add_source(sources, amount, attrs), do: sources ++ [{amount, attrs}]

  defp take_app_slices(apps, 0), do: {[], apps}
  defp take_app_slices(apps, target), do: take_app_slices(apps, target, [])

  defp take_app_slices(apps, 0, acc), do: {Enum.reverse(acc), apps}
  defp take_app_slices([], _left, acc), do: {Enum.reverse(acc), []}

  defp take_app_slices([app | rest], left, acc) do
    take = min(app.amount_cents, left)
    acc = [{app, take} | acc]

    if take == app.amount_cents do
      take_app_slices(rest, left - take, acc)
    else
      leftover = %{app | amount_cents: app.amount_cents - take}
      {Enum.reverse(acc), [leftover | rest]}
    end
  end

  defp backfill_lot_from_group!(group) do
    converted = group.cash_converted_to_credit_cents

    if converted > 0 do
      cancel_ops =
        Operation
        |> where([o], o.type in ["cancel_group", "cancel_rooms"])
        |> order_by([o], asc: o.id)
        |> Repo.all()
        |> Enum.filter(fn op ->
          map_get(op.result, :status) == "applied" and operation_group_id(op) == group.group_id
        end)

      Enum.each(cancel_ops, fn op ->
        issued = map_get(op.result, :credit_issued_cents) || 0

        if issued > 0 do
          case Repo.get_by(CreditLot, source_operation_id: op.operation_id) do
            nil ->
              :ok

            lot ->
              lot
              |> CreditLot.changeset(%{issued_cents: issued})
              |> Repo.update!()

              existing =
                CreditEntitlement
                |> where([e], e.credit_lot_id == ^lot.id)
                |> select([e], count(e.id))
                |> Repo.one()

              if existing == 0 do
                payments = applied_funding_operations(group.group_id, "record_cash_payment")

                recorded =
                  Enum.reduce(payments, 0, fn payment, acc ->
                    acc + (operation_amount(payment) || 0)
                  end)

                legacy = max(converted - recorded, 0)

                fake_allocs =
                  entitlement_backfill_allocs(legacy, payments)

                persist_entitlements!(lot, fake_allocs)
              end
          end
        end
      end)
    end
  end

  defp entitlement_backfill_allocs(legacy, payments) do
    legacy_allocs =
      if legacy > 0 do
        [
          %{
            source_kind: "legacy",
            source_operation_id: nil,
            amount_cents: legacy,
            fill_sequence: 0
          }
        ]
      else
        []
      end

    payment_allocs =
      payments
      |> Enum.with_index(1)
      |> Enum.map(fn {payment, index} ->
        %{
          source_kind: "cash_payment",
          source_operation_id: payment.operation_id,
          amount_cents: operation_amount(payment) || 0,
          fill_sequence: index
        }
      end)

    legacy_allocs ++ payment_allocs
  end

  defp applied_funding_operations(group_id, type) do
    Operation
    |> where([o], o.type == ^type)
    |> order_by([o], asc: o.id)
    |> Repo.all()
    |> Enum.filter(fn op ->
      map_get(op.result, :status) == "applied" and operation_group_id(op) == group_id
    end)
  end

  defp operation_group_id(%Operation{payload: payload, result: result}) do
    map_get(payload, :group_id) || map_get(result, :group_id)
  end

  defp operation_amount(%Operation{payload: payload, result: result}) do
    map_get(result, :amount_cents) || map_get(payload, :amount_cents)
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defp credit_shortfall_cents do
    CreditLot
    |> where([l], l.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, acc ->
      applied = applied_credit_from_lot(lot.id)
      acc + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp applied_credit_from_lot(lot_id) do
    CreditApplication
    |> join(:inner, [a], g in Group, on: a.group_id == g.id)
    |> where([a, g], a.credit_lot_id == ^lot_id and g.status == @active)
    |> select([a, g], coalesce(sum(a.amount_cents), 0))
    |> Repo.one()
  end

  defp available_lots(guest_id, as_of) do
    CreditLot
    |> where(
      [l],
      l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of
    )
    |> order_by([l], asc: l.expires_on, asc: l.source_operation_id)
    |> Repo.all()
  end

  defp credit_liability_cents(as_of) do
    available =
      CreditLot
      |> where([l], l.remaining_cents > 0 and l.expires_on >= ^as_of)
      |> select([l], coalesce(sum(l.remaining_cents), 0))
      |> Repo.one()

    applied =
      Group
      |> where([g], g.status == @active)
      |> select([g], coalesce(sum(g.credit_paid_cents), 0))
      |> Repo.one()

    available + applied
  end

  defp policy_version(%Group{} = group) do
    case group.policy_version do
      version when version in [@flex_14, @flex_30, @advance_nonrefundable] ->
        version

      _ ->
        policy_version_for(group.rate_plan, group.booked_on)
    end
  end

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @flex_30_start) == :lt do
      @flex_14
    else
      @flex_30
    end
  end

  defp policy_version_for(_rate_plan, booked_on) do
    if Date.compare(booked_on, @flex_30_start) == :lt do
      @flex_14
    else
      @flex_30
    end
  end

  defp refundable_until(_arrival_on, @advance_nonrefundable), do: nil
  defp refundable_until(arrival_on, @flex_14), do: Date.add(arrival_on, -@flex_14_days)
  defp refundable_until(arrival_on, @flex_30), do: Date.add(arrival_on, -@flex_30_days)
  defp refundable_until(_arrival_on, _policy), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group.arrival_on, policy_version(group)) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end

  defp require_refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil ->
        {:ok, @cash}

      @cash ->
        {:ok, @cash}

      @hotel_credit ->
        {:ok, @hotel_credit}

      value when is_atom(value) ->
        require_refund_method(Map.put(operation, "refund_method", Atom.to_string(value)))

      _ ->
        reject("invalid_operation")
    end
  end

  defp reject_if_exists(group_id) do
    if Repo.get_by(Group, group_id: group_id) do
      reject("group_already_exists")
    else
      :ok
    end
  end

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> reject("group_not_found")
      group -> {:ok, group}
    end
  end

  defp match_revision(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, expected} ->
        if expected == group.revision do
          :ok
        else
          {:rejected,
           %{
             code: "stale_revision",
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           }}
        end
    end
  end

  defp require_active(%Group{status: @active}), do: :ok
  defp require_active(_), do: reject("group_not_active")

  defp require_id(operation, field) do
    case Map.get(operation, field) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> reject("invalid_operation")
    end
  end

  defp require_date(operation, field, code) do
    case parse_date(Map.get(operation, field)) do
      {:ok, date} -> {:ok, date}
      :error -> reject(code)
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp validate_stay_length(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      reject("invalid_stay")
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      reject("invalid_stay")
    end
  end

  defp require_rate_plan(operation) do
    plan =
      case Map.get(operation, "rate_plan") do
        value when is_atom(value) -> Atom.to_string(value)
        value -> value
      end

    if plan in [@flexible, @advance_purchase] do
      {:ok, plan}
    else
      reject("invalid_rate_plan")
    end
  end

  defp parse_rooms(operation) do
    case Map.get(operation, "rooms") do
      rooms when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {room, index}, {:ok, acc} ->
          case parse_room(room, index) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:rejected, _} = rejected -> {:halt, rejected}
          end
        end)
        |> case do
          {:ok, parsed} ->
            parsed = Enum.reverse(parsed)
            room_ids = Enum.map(parsed, & &1.room_id)

            if room_ids == Enum.uniq(room_ids) do
              {:ok, parsed}
            else
              reject("invalid_rooms")
            end

          other ->
            other
        end

      _ ->
        reject("invalid_rooms")
    end
  end

  defp parse_room(room, position) when is_map(room) do
    room = stringify_keys(room)
    room_id = Map.get(room, "room_id")
    rate = Map.get(room, "nightly_rate_cents")

    cond do
      not (is_binary(room_id) and room_id != "") ->
        reject("invalid_rooms")

      not is_integer(rate) or rate < 0 ->
        reject("invalid_rooms")

      true ->
        {:ok, %{room_id: room_id, nightly_rate_cents: rate, position: position}}
    end
  end

  defp parse_room(_, _), do: reject("invalid_rooms")

  defp require_payment_amount(operation) do
    case Map.get(operation, "amount_cents") do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> reject("invalid_amount")
    end
  end

  defp reject(code), do: {:rejected, %{code: code}}

  defp applied(nil, fields), do: Map.put(fields, :status, "applied")

  defp applied(operation_id, fields) do
    fields
    |> Map.put(:status, "applied")
    |> Map.put(:operation_id, operation_id)
  end

  defp rejected(nil, fields), do: Map.put(fields, :status, "rejected")

  defp rejected(operation_id, fields) do
    fields
    |> Map.put(:status, "rejected")
    |> Map.put(:operation_id, operation_id)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp preload_rooms(nil), do: nil

  defp preload_rooms(%Group{rooms: rooms} = group) when is_list(rooms) do
    %{group | rooms: Enum.sort_by(rooms, & &1.position)}
  end

  defp preload_rooms(%Group{} = group), do: Repo.preload(group, :rooms)

  defp serialize_room(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      status: room.status,
      deposit_due_cents: room.deposit_due_cents,
      cash_paid_cents: room.cash_paid_cents,
      credit_paid_cents: room.credit_paid_cents
    }
  end

  defp serialize_lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp unique_group_id_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end
end
