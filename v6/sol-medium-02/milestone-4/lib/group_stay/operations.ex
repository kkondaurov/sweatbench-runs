defmodule GroupStay.Operations do
  @moduledoc "Applies partner operations and exposes the resulting group-deposit state."

  import Ecto.Query

  alias GroupStay.Credits.{CreditApplication, CreditEntitlement, CreditLot}
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.PartnerOperation
  alias GroupStay.Payments.{CashAllocation, PaymentFunding}
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  # Called by the request-04 migration after its new tables and columns exist. It reconstructs
  # provenance without changing any group, cash, credit, liability, or revision total.
  def backfill_room_accounting! do
    Repo.all(Group)
    |> Enum.each(&backfill_group_accounting!/1)
  end

  def apply_batch(operations) when is_list(operations),
    do: Enum.map(operations, &apply_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms, force: true)}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      %PartnerOperation{result: result} when is_map(result) -> {:ok, result}
      _ -> {:error, :operation_not_found}
    end
  end

  def get_operation_result(_), do: {:error, :operation_not_found}

  def get_payment_statement(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      operation ->
        case payment_funding(operation) do
          {:ok, funding} -> {:ok, serialize_payment(funding)}
          :error -> {:error, :payment_not_reconcilable}
        end
    end
  end

  def get_payment_statement(_), do: {:error, :operation_not_found}

  defp backfill_group_accounting!(group) do
    operations =
      Repo.all(from operation in PartnerOperation, order_by: [asc: operation.id])
      |> Enum.filter(fn operation ->
        operation.operation_type in ["record_cash_payment", "apply_hotel_credit"] and
          operation.result["status"] == "applied" and
          operation.result["group_id"] == group.group_id
      end)

    payments =
      operations
      |> Enum.filter(&(&1.operation_type == "record_cash_payment"))
      |> Enum.map(fn operation ->
        amount = operation.result["amount_cents"]

        funding =
          Repo.get_by(PaymentFunding, partner_operation_id: operation.id) ||
            Repo.insert!(
              PaymentFunding.changeset(
                %PaymentFunding{},
                backfilled_payment_attrs(group, operation, amount)
              )
            )

        {operation, funding, amount}
      end)

    if group.status == "active" do
      backfill_active_allocations!(group, operations, payments)
    else
      backfill_converted_entitlements!(group, payments)
    end
  end

  defp backfilled_payment_attrs(group, operation, amount) do
    disposition =
      cond do
        group.status == "active" -> :held_cents
        group.refunded_cents > 0 -> :refunded_cents
        group.retained_cents > 0 -> :retained_cents
        group.cash_converted_to_credit_cents > 0 -> :converted_to_credit_cents
        true -> :held_cents
      end

    %{partner_operation_id: operation.id, group_id: group.id, recorded_cents: amount}
    |> Map.put(disposition, amount)
  end

  defp backfill_active_allocations!(group, operations, payments) do
    rooms =
      Repo.all(
        from room in Room, where: room.group_id == ^group.id, order_by: [asc: room.position]
      )

    room_ids = Enum.map(rooms, & &1.id)

    old_credit =
      Repo.all(
        from application in CreditApplication,
          where: application.group_id == ^group.id,
          order_by: [asc: application.id]
      )

    credit_queue = Enum.map(old_credit, &{&1.credit_lot_id, &1.amount_cents})
    Repo.delete_all(from allocation in CashAllocation, where: allocation.room_id in ^room_ids)

    Repo.delete_all(
      from application in CreditApplication, where: application.group_id == ^group.id
    )

    Enum.each(rooms, &update_room!(&1, %{cash_paid_cents: 0, credit_paid_cents: 0}))

    durable_cash = Enum.sum(Enum.map(payments, &elem(&1, 2)))

    durable_credit =
      operations
      |> Enum.filter(&(&1.operation_type == "apply_hotel_credit"))
      |> Enum.map(& &1.result["amount_cents"])
      |> Enum.sum()

    legacy_cash = max(group.cash_paid_cents - durable_cash, 0)
    legacy_credit = max(group.credit_paid_cents - durable_credit, 0)
    payment_map = Map.new(payments, fn {operation, funding, _} -> {operation.id, funding} end)

    events =
      if(legacy_cash > 0, do: [{:cash, nil, legacy_cash}], else: []) ++
        if(legacy_credit > 0, do: [{:credit, nil, legacy_credit}], else: []) ++
        Enum.map(operations, fn operation ->
          if operation.operation_type == "record_cash_payment" do
            {:cash, payment_map[operation.id], operation.result["amount_cents"]}
          else
            {:credit, operation.operation_id, operation.result["amount_cents"]}
          end
        end)

    {_rooms, queue, _cash_position, _credit_position} =
      Enum.reduce(
        events,
        {Repo.all(from r in Room, where: r.id in ^room_ids, order_by: [asc: r.position]),
         credit_queue, 0, 0},
        fn
          {:cash, funding, amount}, {state_rooms, queue, cash_position, credit_position} ->
            {next_rooms, next_position} =
              backfill_cash_event(state_rooms, funding, amount, cash_position)

            {next_rooms, queue, next_position, credit_position}

          {:credit, operation_id, amount}, {state_rooms, queue, cash_position, credit_position} ->
            {next_rooms, next_queue, next_position} =
              backfill_credit_event(
                group,
                state_rooms,
                queue,
                operation_id,
                amount,
                credit_position
              )

            {next_rooms, next_queue, cash_position, next_position}
        end
      )

    if queue != [], do: raise("legacy credit allocations exceed the group credit total")
  end

  defp backfill_cash_event(rooms, funding, amount, position) do
    {rooms, {remaining, position}} =
      Enum.map_reduce(rooms, {amount, position}, fn room, {remaining, next_position} ->
        used = min(room_outstanding(room), remaining)

        if used > 0 do
          Repo.insert!(
            CashAllocation.changeset(%CashAllocation{}, %{
              room_id: room.id,
              payment_funding_id: funding && funding.id,
              amount_cents: used,
              position: next_position
            })
          )
        end

        updated =
          if used > 0,
            do: update_room!(room, %{cash_paid_cents: room.cash_paid_cents + used}),
            else: room

        {updated, {remaining - used, next_position + if(used > 0, do: 1, else: 0)}}
      end)

    if remaining != 0, do: raise("legacy cash exceeds active room deposits")
    {rooms, position}
  end

  defp backfill_credit_event(group, rooms, queue, operation_id, amount, position) do
    {rooms, {remaining, queue, position}} =
      Enum.map_reduce(rooms, {amount, queue, position}, fn room, {remaining, queue, position} ->
        capacity = min(room_outstanding(room), remaining)

        {queue, position} =
          backfill_credit_pieces(group, room, queue, operation_id, capacity, position)

        updated =
          if capacity > 0,
            do: update_room!(room, %{credit_paid_cents: room.credit_paid_cents + capacity}),
            else: room

        {updated, {remaining - capacity, queue, position}}
      end)

    if remaining != 0, do: raise("legacy credit exceeds active room deposits")
    {rooms, queue, position}
  end

  defp backfill_credit_pieces(_group, _room, queue, _operation_id, 0, position),
    do: {queue, position}

  defp backfill_credit_pieces(
         group,
         room,
         [{lot_id, available} | rest],
         operation_id,
         amount,
         position
       ) do
    used = min(available, amount)

    Repo.insert!(
      CreditApplication.changeset(%CreditApplication{}, %{
        group_id: group.id,
        room_id: room.id,
        credit_lot_id: lot_id,
        operation_id: operation_id,
        amount_cents: used,
        status: "active",
        position: position
      })
    )

    queue = if used == available, do: rest, else: [{lot_id, available - used} | rest]
    backfill_credit_pieces(group, room, queue, operation_id, amount - used, position + 1)
  end

  defp backfill_credit_pieces(_group, _room, [], _operation_id, amount, _position)
       when amount > 0,
       do: raise("legacy credit allocation is missing its source lot")

  defp backfill_converted_entitlements!(group, payments) do
    if group.cash_converted_to_credit_cents > 0 do
      cancellation_ids =
        Repo.all(
          from operation in PartnerOperation,
            where: operation.operation_type in ["cancel_group", "cancel_rooms"],
            order_by: [asc: operation.id]
        )
        |> Enum.filter(
          &(&1.result["status"] == "applied" and &1.result["group_id"] == group.group_id and
              &1.result["credit_issued_cents"] > 0)
        )
        |> Enum.map(& &1.operation_id)

      lots =
        Repo.all(
          from lot in CreditLot,
            where: lot.source_operation_id in ^cancellation_ids,
            order_by: [asc: lot.id]
        )

      durable = Enum.sum(Enum.map(payments, &elem(&1, 2)))

      contributors =
        if(group.cash_converted_to_credit_cents > durable,
          do: [{nil, group.cash_converted_to_credit_cents - durable}],
          else: []
        ) ++
          Enum.map(payments, fn {_operation, funding, amount} -> {funding.id, amount} end)

      Enum.each(lots, fn lot ->
        unless Repo.exists?(
                 from entitlement in CreditEntitlement,
                   where: entitlement.credit_lot_id == ^lot.id
               ) do
          contributors
          |> Enum.reduce({0, 0}, fn {funding_id, principal}, {cumulative, position} ->
            next = cumulative + principal

            Repo.insert!(
              CreditEntitlement.changeset(%CreditEntitlement{}, %{
                credit_lot_id: lot.id,
                payment_funding_id: funding_id,
                principal_cents: principal,
                entitlement_cents: bonused(next) - bonused(cumulative),
                position: position
              })
            )

            {next, position + 1}
          end)
        end
      end)
    end
  end

  def ledger(on \\ Date.utc_today()) do
    cash =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0),
            cash_reduced_cents: coalesce(sum(g.cash_reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(g.cash_charged_back_cents), 0)
          }
      )

    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    active_by_lot =
      Repo.all(
        from a in CreditApplication,
          where: a.status == "active",
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, sum(a.amount_cents)}
      )

    lot_ids = Enum.map(active_by_lot, &elem(&1, 0))

    clawbacks =
      if lot_ids == [],
        do: %{},
        else:
          Repo.all(
            from lot in CreditLot,
              where: lot.id in ^lot_ids,
              select: {lot.id, lot.unrecovered_clawback_cents}
          )
          |> Map.new()

    applied = Enum.sum(Enum.map(active_by_lot, &elem(&1, 1)))

    shortfall =
      Enum.sum(
        Enum.map(active_by_lot, fn {id, amount} -> min(Map.get(clawbacks, id, 0), amount) end)
      )

    cash
    |> Map.put(:credit_liability_cents, available + applied)
    |> Map.put(:credit_shortfall_cents, shortfall)
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

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

  def serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: iso_date(group.refundable_until),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id),
      do: apply_durable_operation(operation, operation_id),
      else: process_operation(operation, operation_id)
  end

  defp apply_operation(_), do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  defp apply_durable_operation(operation, operation_id) do
    transaction_result =
      Repo.transaction(
        fn ->
          attrs = %{
            operation_id: operation_id,
            operation_type: submitted_type(operation),
            submission: operation
          }

          case Repo.insert(PartnerOperation.reservation_changeset(%PartnerOperation{}, attrs)) do
            {:ok, record} ->
              result = operation |> process_operation(operation_id) |> normalize_json()
              Repo.update!(PartnerOperation.result_changeset(record, result))
              result

            {:error, changeset} ->
              if operation_id_taken?(changeset),
                do: Repo.rollback(:operation_id_taken),
                else: raise(Ecto.InvalidChangesetError, action: :insert, changeset: changeset)
          end
        end,
        mode: :immediate
      )

    case transaction_result do
      {:ok, result} -> result
      {:error, :operation_id_taken} -> replay_or_conflict(operation, operation_id)
    end
  end

  defp process_operation(operation, operation_id) do
    case dispatch(operation) do
      {:ok, applied} -> Map.merge(%{operation_id: operation_id, status: "applied"}, applied)
      {:error, rejected} -> Map.merge(%{operation_id: operation_id, status: "rejected"}, rejected)
    end
  end

  defp replay_or_conflict(operation, operation_id) do
    stored = Repo.get_by!(PartnerOperation, operation_id: operation_id)

    if equivalent_json?(stored.submission, operation),
      do: stored.result,
      else: %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_), do: nil

  defp operation_id_taken?(changeset),
    do:
      Enum.any?(changeset.errors, fn
        {:operation_id, {_message, options}} -> options[:constraint] == :unique
        _ -> false
      end)

  defp equivalent_json?(left, right) when is_map(left) and is_map(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        case Map.fetch(right, key) do
          {:ok, other} -> equivalent_json?(value, other)
          :error -> false
        end
      end)
  end

  defp equivalent_json?(left, right) when is_list(left) and is_list(right),
    do:
      length(left) == length(right) and
        Enum.zip(left, right) |> Enum.all?(fn {a, b} -> equivalent_json?(a, b) end)

  defp equivalent_json?(left, right), do: left === right

  defp normalize_json(value) when is_map(value),
    do:
      Map.new(value, fn {key, nested} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), normalize_json(nested)}
      end)

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)
  defp normalize_json(value), do: value

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)
  defp dispatch(%{"type" => "record_cash_payment"} = operation), do: with_group(operation, &pay/3)

  defp dispatch(%{"type" => "reschedule_group"} = operation),
    do: with_group(operation, &reschedule/3)

  defp dispatch(%{"type" => "cancel_group"} = operation), do: with_group(operation, &cancel/3)

  defp dispatch(%{"type" => "cancel_rooms"} = operation),
    do: with_group(operation, &cancel_rooms/3)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: with_group(operation, &apply_credit/3)

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation),
    do: with_payment(operation, :reduce)

  defp dispatch(%{"type" => "charge_back_payment"} = operation),
    do: with_payment(operation, :charge_back)

  defp dispatch(_), do: reject("invalid_operation")

  defp open_group(operation) do
    with true <-
           required_keys?(
             operation,
             ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         true <- common_valid?(operation),
         {:ok, booked_on} <- date(operation["occurred_on"]),
         true <- valid_identifier?(operation["group_id"]),
         true <- valid_identifier?(operation["guest_id"]),
         true <- valid_identifier?(operation["property_id"]),
         false <- Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]),
         {:ok, arrival_on} <- date(operation["arrival_on"]),
         {:ok, departure_on} <- date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, room_attrs} <- rooms(operation["rooms"]),
         true <- operation["rate_plan"] in @rate_plans do
      nights = Date.diff(departure_on, arrival_on)

      room_attrs =
        Enum.map(room_attrs, fn room ->
          lodging = room.nightly_rate_cents * nights

          due =
            if operation["rate_plan"] == "flexible",
              do: round_flexible_deposit(lodging),
              else: lodging

          Map.merge(room, %{lodging_total_cents: lodging, deposit_due_cents: due})
        end)

      lodging_total = Enum.sum(Enum.map(room_attrs, & &1.lodging_total_cents))
      deposit_due = Enum.sum(Enum.map(room_attrs, & &1.deposit_due_cents))
      version = policy_version(operation["rate_plan"], booked_on)

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: version,
        refundable_until: refundable_until(version, arrival_on),
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }

      case Repo.insert(Group.create_changeset(%Group{}, attrs)) do
        {:ok, group} ->
          Enum.each(room_attrs, fn room ->
            Repo.insert!(Room.changeset(%Room{}, Map.put(room, :group_id, group.id)))
          end)

          {:ok, %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: 1}}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id),
            do: reject("group_already_exists"),
            else: reject("invalid_operation")
      end
    else
      false -> open_error(operation)
      {:error, :invalid_rooms} -> reject("invalid_rooms")
      {:error, :invalid_date} -> open_error(operation)
    end
  end

  defp open_error(operation) do
    cond do
      not required_keys?(
        operation,
        ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
      ) ->
        reject("invalid_operation")

      not common_valid?(operation) ->
        reject("invalid_operation")

      not valid_identifier?(operation["group_id"]) or not valid_identifier?(operation["guest_id"]) or
          not valid_identifier?(operation["property_id"]) ->
        reject("invalid_operation")

      Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) ->
        reject("group_already_exists")

      operation["rate_plan"] not in @rate_plans ->
        reject("invalid_rate_plan")

      not valid_rooms?(operation["rooms"]) ->
        reject("invalid_rooms")

      true ->
        reject("invalid_stay")
    end
  end

  defp with_group(operation, function) do
    with true <- required_keys?(operation, required_fields(operation["type"])),
         true <- common_valid?(operation),
         true <- valid_identifier?(operation["group_id"]),
         %Group{} = group <- Repo.get_by(Group, group_id: operation["group_id"]),
         :ok <- revision_matches(operation, group) do
      function.(operation, group, operation_date(operation))
    else
      false -> reject("invalid_operation")
      nil -> reject("group_not_found", %{group_id: operation["group_id"]})
      {:error, :invalid_date} -> reject("invalid_operation")
      {:error, stale} when is_map(stale) -> {:error, stale}
    end
  end

  defp with_payment(operation, kind) do
    with true <- required_keys?(operation, required_fields(operation["type"])),
         true <- common_valid?(operation),
         true <- valid_identifier?(operation["payment_operation_id"]) do
      case Repo.get_by(PartnerOperation, operation_id: operation["payment_operation_id"]) do
        nil -> reject("operation_not_found")
        target -> resolve_payment_operation(operation, target, kind)
      end
    else
      false -> reject("invalid_operation")
    end
  end

  defp resolve_payment_operation(operation, target, kind) do
    error = if kind == :reduce, do: "payment_not_reducible", else: "payment_not_chargeable"

    case payment_funding(target) do
      {:ok, funding} ->
        group = Repo.get!(Group, funding.group_id)

        case revision_matches(operation, group) do
          :ok ->
            if kind == :reduce,
              do: reduce_payment(operation, group, funding),
              else: charge_back_payment(operation, group, funding)

          {:error, stale} ->
            {:error, stale}
        end

      :error ->
        reject(error)
    end
  end

  defp pay(operation, group, {:ok, _occurred_on}) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      not (is_integer(amount) and amount > 0) ->
        reject("invalid_amount", %{group_id: group.group_id})

      amount > outstanding(group) ->
        reject("payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        partner_operation =
          Repo.get_by!(PartnerOperation, operation_id: operation["operation_id"])

        funding =
          Repo.insert!(
            PaymentFunding.changeset(%PaymentFunding{}, %{
              partner_operation_id: partner_operation.id,
              group_id: group.id,
              recorded_cents: amount,
              held_cents: amount
            })
          )

        allocate_cash(group, funding, amount)
        updated = update_group_from_rooms(group)

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding(updated),
           revision: updated.revision
         }}
    end
  end

  defp pay(_operation, _group, {:error, :invalid_date}), do: reject("invalid_operation")

  defp allocate_cash(group, funding, amount) do
    active_rooms(group.id)
    |> Enum.reduce_while({amount, 0}, fn room, {remaining, position} ->
      used = min(room_outstanding(room), remaining)

      if used > 0 do
        Repo.insert!(
          CashAllocation.changeset(%CashAllocation{}, %{
            room_id: room.id,
            payment_funding_id: funding.id,
            amount_cents: used,
            position: position
          })
        )

        update_room!(room, %{cash_paid_cents: room.cash_paid_cents + used})
      end

      if used == remaining,
        do: {:halt, {0, position + 1}},
        else: {:cont, {remaining - used, position + 1}}
    end)
  end

  defp reschedule(operation, group, {:ok, occurred_on}) do
    with true <- group.status == "active",
         {:ok, arrival_on} <- date(operation["new_arrival_on"]),
         true <- Date.compare(arrival_on, occurred_on) == :gt do
      departure_on = Date.add(group.departure_on, Date.diff(arrival_on, group.arrival_on))

      {:ok, updated} =
        persist_update(group, %{
          arrival_on: arrival_on,
          departure_on: departure_on,
          refundable_until: refundable_until(group.policy_version, arrival_on)
        })

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: Date.to_iso8601(arrival_on),
         new_departure_on: Date.to_iso8601(departure_on),
         policy_version: group.policy_version,
         refundable_until: iso_date(updated.refundable_until),
         revision: updated.revision
       }}
    else
      false when group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      _ ->
        reject("invalid_stay", %{group_id: group.group_id})
    end
  end

  defp reschedule(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp cancel(operation, group, {:ok, occurred_on}) do
    if group.status == "active",
      do: settle_selected_rooms(operation, group, active_rooms(group.id), occurred_on, false),
      else: reject("group_not_active", %{group_id: group.group_id})
  end

  defp cancel(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp cancel_rooms(operation, group, {:ok, occurred_on}) do
    supplied = operation["room_ids"]
    rooms = active_rooms(group.id)

    cond do
      group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      not valid_selected_rooms?(supplied, rooms) ->
        reject("invalid_rooms", %{group_id: group.group_id})

      true ->
        selected_ids = MapSet.new(supplied)

        settle_selected_rooms(
          operation,
          group,
          Enum.filter(rooms, &MapSet.member?(selected_ids, &1.room_id)),
          occurred_on,
          true
        )
    end
  end

  defp cancel_rooms(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp settle_selected_rooms(operation, group, selected, occurred_on, include_room_ids?) do
    refund_method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred_on)

    cond do
      refund_method not in ["cash", "hotel_credit"] ->
        reject("invalid_operation", %{group_id: group.group_id})

      refund_method == "hotel_credit" and not refundable ->
        reject("refund_method_not_available", %{group_id: group.group_id})

      true ->
        do_settle_selected(
          operation,
          group,
          selected,
          occurred_on,
          refundable,
          refund_method,
          include_room_ids?
        )
    end
  end

  defp do_settle_selected(
         operation,
         group,
         selected,
         occurred_on,
         refundable,
         refund_method,
         include_room_ids?
       ) do
    ids = Enum.map(selected, & &1.id)
    cash_allocations = cash_allocations_for_rooms(ids)
    credit_applications = credit_applications_for_rooms(ids)
    cash_amount = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))

    {refunded, retained, converted, issued} =
      cond do
        refundable and refund_method == "cash" ->
          {cash_amount, 0, 0, 0}

        refundable ->
          issued = bonused(cash_amount)

          if issued > 0,
            do:
              issue_credit_for_allocations!(
                operation,
                group,
                cash_allocations,
                issued,
                occurred_on
              )

          {0, 0, cash_amount, issued}

        true ->
          {0, cash_amount, 0, 0}
      end

    classify_cash_allocations(
      cash_allocations,
      if(refundable, do: refund_method, else: "retained")
    )

    settle_credit_applications(credit_applications, occurred_on, refundable)

    Enum.each(
      selected,
      &update_room!(&1, %{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
    )

    active_remaining? =
      Repo.exists?(from r in Room, where: r.group_id == ^group.id and r.status == "active")

    updated =
      update_group_from_rooms(group, %{
        status: if(active_remaining?, do: "active", else: "cancelled"),
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
      })

    result = %{
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: updated.revision
    }

    result =
      if include_room_ids?,
        do: Map.put(result, :cancelled_room_ids, Enum.map(selected, & &1.room_id)),
        else: result

    {:ok, result}
  end

  defp classify_cash_allocations(allocations, classification) do
    allocations
    |> Enum.group_by(& &1.payment_funding_id)
    |> Enum.each(fn
      {nil, rows} ->
        Repo.delete_all(from a in CashAllocation, where: a.id in ^Enum.map(rows, & &1.id))

      {funding_id, rows} ->
        amount = Enum.sum(Enum.map(rows, & &1.amount_cents))
        funding = Repo.get!(PaymentFunding, funding_id)

        field =
          case classification do
            "cash" -> :refunded_cents
            "hotel_credit" -> :converted_to_credit_cents
            "retained" -> :retained_cents
          end

        attrs =
          %{held_cents: funding.held_cents - amount}
          |> Map.put(field, Map.fetch!(funding, field) + amount)

        Repo.update!(PaymentFunding.changeset(funding, attrs))
        Repo.delete_all(from a in CashAllocation, where: a.id in ^Enum.map(rows, & &1.id))
    end)
  end

  defp issue_credit_for_allocations!(operation, group, allocations, issued, occurred_on) do
    lot =
      insert_credit_lot!(
        group.guest_id,
        operation["operation_id"],
        issued,
        Date.add(occurred_on, 365)
      )

    allocations
    |> Enum.group_by(& &1.payment_funding_id)
    |> Enum.map(fn {funding_id, rows} ->
      {funding_id, Enum.sum(Enum.map(rows, & &1.amount_cents))}
    end)
    |> Enum.sort_by(fn {funding_id, _} -> funding_order(funding_id) end)
    |> Enum.reduce({0, 0}, fn {funding_id, principal}, {cumulative, position} ->
      next = cumulative + principal

      Repo.insert!(
        CreditEntitlement.changeset(%CreditEntitlement{}, %{
          credit_lot_id: lot.id,
          payment_funding_id: funding_id,
          principal_cents: principal,
          entitlement_cents: bonused(next) - bonused(cumulative),
          position: position
        })
      )

      {next, position + 1}
    end)
  end

  defp apply_credit(operation, group, {:ok, occurred_on}) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      not (is_integer(amount) and amount > 0) ->
        reject("invalid_amount", %{group_id: group.group_id})

      amount > outstanding(group) ->
        reject("payment_exceeds_outstanding", %{group_id: group.group_id})

      available_credit(group.guest_id, occurred_on) < amount ->
        reject("insufficient_credit", %{group_id: group.group_id})

      true ->
        consume_and_allocate_credit(group, amount, occurred_on, operation["operation_id"])
        updated = update_group_from_rooms(group)

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding(updated),
           revision: updated.revision
         }}
    end
  end

  defp apply_credit(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp consume_and_allocate_credit(group, amount, on, operation_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    {remaining, room_states, applications} =
      Enum.reduce_while(lots, {amount, active_rooms(group.id), []}, fn lot,
                                                                       {needed, rooms, apps} ->
        available = min(lot.remaining_cents, needed)

        {unused, new_rooms, new_apps} =
          allocate_credit_lot(lot, available, rooms, apps, operation_id)

        used = available - unused
        Repo.update!(CreditLot.changeset(lot, %{remaining_cents: lot.remaining_cents - used}))
        state = {needed - used, new_rooms, new_apps}
        if needed == used, do: {:halt, state}, else: {:cont, state}
      end)

    if remaining != 0, do: raise("credit allocation invariant violated")

    Enum.each(room_states, fn room ->
      update_room!(Repo.get!(Room, room.id), %{credit_paid_cents: room.credit_paid_cents})
    end)

    Enum.reverse(applications)
    |> Enum.each(&Repo.insert!(CreditApplication.changeset(%CreditApplication{}, &1)))
  end

  defp allocate_credit_lot(lot, amount, rooms, applications, operation_id) do
    Enum.map_reduce(rooms, {amount, applications}, fn room, {remaining, apps} ->
      used = min(room_outstanding(room), remaining)
      updated_room = %{room | credit_paid_cents: room.credit_paid_cents + used}

      apps =
        if used > 0 do
          [
            %{
              group_id: room.group_id,
              room_id: room.id,
              credit_lot_id: lot.id,
              operation_id: operation_id,
              amount_cents: used,
              status: "active",
              position: length(apps)
            }
            | apps
          ]
        else
          apps
        end

      {updated_room, {remaining - used, apps}}
    end)
    |> then(fn {updated_rooms, {remaining, apps}} -> {remaining, updated_rooms, apps} end)
  end

  defp settle_credit_applications(applications, occurred_on, refundable) do
    Enum.each(applications, fn application ->
      if refundable do
        restore_to_lot(application.credit_lot_id, application.amount_cents, occurred_on)
        Repo.update!(CreditApplication.changeset(application, %{status: "restored"}))
      else
        Repo.update!(CreditApplication.changeset(application, %{status: "consumed"}))
      end
    end)
  end

  defp restore_to_lot(lot_id, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    excess = amount - absorbed
    restored = if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt], do: excess, else: 0

    Repo.update!(
      CreditLot.changeset(lot, %{
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        remaining_cents: lot.remaining_cents + restored
      })
    )
  end

  defp reduce_payment(operation, group, funding) do
    amount = operation["amount_cents"]

    cond do
      funding.held_cents <= 0 ->
        reject("payment_not_reducible")

      not (is_integer(amount) and amount > 0) ->
        reject("invalid_amount", %{group_id: group.group_id})

      amount > funding.held_cents ->
        reject("reduction_exceeds_held_cash", %{group_id: group.group_id})

      true ->
        remove_held_allocations(funding, amount)

        Repo.update!(
          PaymentFunding.changeset(funding, %{
            held_cents: funding.held_cents - amount,
            reduced_cents: funding.reduced_cents + amount
          })
        )

        updated =
          update_group_from_rooms(group, %{cash_reduced_cents: group.cash_reduced_cents + amount})

        {:ok,
         %{
           payment_operation_id: operation["payment_operation_id"],
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding(updated),
           revision: updated.revision
         }}
    end
  end

  defp charge_back_payment(operation, group, funding) do
    chargeable = funding.recorded_cents - funding.reduced_cents

    cond do
      chargeable <= 0 or funding.charged_back_cents > 0 ->
        reject("payment_not_chargeable")

      true ->
        remove_held_allocations(funding, funding.held_cents)
        revoke_entitlements(funding.id)

        Repo.update!(
          PaymentFunding.changeset(funding, %{
            held_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            charged_back_cents: chargeable
          })
        )

        updated =
          update_group_from_rooms(group, %{
            refunded_cents: group.refunded_cents - funding.refunded_cents,
            retained_cents: group.retained_cents - funding.retained_cents,
            cash_converted_to_credit_cents:
              group.cash_converted_to_credit_cents - funding.converted_to_credit_cents,
            cash_charged_back_cents: group.cash_charged_back_cents + chargeable
          })

        {:ok,
         %{
           payment_operation_id: operation["payment_operation_id"],
           group_id: group.group_id,
           charged_back_cents: chargeable,
           outstanding_deposit_cents: outstanding(updated),
           revision: updated.revision
         }}
    end
  end

  defp remove_held_allocations(_funding, 0), do: :ok

  defp remove_held_allocations(funding, amount) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.payment_funding_id == ^funding.id,
          order_by: [desc: a.position, desc: a.id]
      )

    remaining =
      Enum.reduce_while(allocations, amount, fn allocation, left ->
        removed = min(allocation.amount_cents, left)
        room = Repo.get!(Room, allocation.room_id)
        update_room!(room, %{cash_paid_cents: room.cash_paid_cents - removed})

        if removed == allocation.amount_cents,
          do: Repo.delete!(allocation),
          else:
            Repo.update!(
              CashAllocation.changeset(allocation, %{
                amount_cents: allocation.amount_cents - removed
              })
            )

        if removed == left, do: {:halt, 0}, else: {:cont, left - removed}
      end)

    if remaining != 0, do: raise("cash allocation invariant violated")
  end

  defp revoke_entitlements(funding_id) do
    Repo.all(
      from e in CreditEntitlement,
        where: e.payment_funding_id == ^funding_id and e.revoked_cents < e.entitlement_cents
    )
    |> Enum.each(fn entitlement ->
      amount = entitlement.entitlement_cents - entitlement.revoked_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      from_available = min(lot.remaining_cents, amount)

      Repo.update!(
        CreditLot.changeset(lot, %{
          remaining_cents: lot.remaining_cents - from_available,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - from_available
        })
      )

      Repo.update!(
        CreditEntitlement.changeset(entitlement, %{revoked_cents: entitlement.entitlement_cents})
      )
    end)
  end

  defp payment_funding(
         %PartnerOperation{
           operation_type: "record_cash_payment",
           result: %{"status" => "applied"}
         } = operation
       ) do
    case Repo.get_by(PaymentFunding, partner_operation_id: operation.id) do
      nil -> :error
      funding -> {:ok, Repo.preload(funding, [:group, :partner_operation])}
    end
  end

  defp payment_funding(_), do: :error

  defp serialize_payment(funding),
    do: %{
      payment_operation_id: funding.partner_operation.operation_id,
      original_group_id: funding.group.group_id,
      recorded_cents: funding.recorded_cents,
      held_cents: funding.held_cents,
      refunded_cents: funding.refunded_cents,
      retained_cents: funding.retained_cents,
      converted_to_credit_cents: funding.converted_to_credit_cents,
      reduced_cents: funding.reduced_cents,
      charged_back_cents: funding.charged_back_cents
    }

  defp update_group_from_rooms(group, extra \\ %{}) do
    totals =
      Repo.one(
        from r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          select: %{
            lodging_total_cents: coalesce(sum(r.lodging_total_cents), 0),
            deposit_due_cents: coalesce(sum(r.deposit_due_cents), 0),
            cash_paid_cents: coalesce(sum(r.cash_paid_cents), 0),
            credit_paid_cents: coalesce(sum(r.credit_paid_cents), 0)
          }
      )

    attrs =
      totals
      |> Map.put(:deposit_paid_cents, totals.cash_paid_cents + totals.credit_paid_cents)
      |> Map.merge(extra)

    {:ok, updated} = persist_update(group, attrs)
    updated
  end

  defp active_rooms(group_id),
    do:
      Repo.all(
        from r in Room,
          where: r.group_id == ^group_id and r.status == "active",
          order_by: [asc: r.position]
      )

  defp cash_allocations_for_rooms([]), do: []

  defp cash_allocations_for_rooms(ids),
    do: Repo.all(from a in CashAllocation, where: a.room_id in ^ids, order_by: [asc: a.id])

  defp credit_applications_for_rooms([]), do: []

  defp credit_applications_for_rooms(ids),
    do:
      Repo.all(
        from a in CreditApplication,
          where: a.room_id in ^ids and a.status == "active",
          order_by: [asc: a.id]
      )

  defp funding_order(nil), do: {0, 0}
  defp funding_order(id), do: {1, Repo.get!(PaymentFunding, id).partner_operation_id}
  defp update_room!(room, attrs), do: Repo.update!(Room.changeset(room, attrs))

  defp persist_update(group, attrs),
    do:
      group
      |> Group.update_changeset(Map.put(attrs, :revision, group.revision + 1))
      |> Repo.update()

  defp available_credit(guest_id, on),
    do:
      Repo.one(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

  defp insert_credit_lot!(guest_id, source_operation_id, amount, expires_on),
    do:
      Repo.insert!(
        CreditLot.changeset(%CreditLot{}, %{
          guest_id: guest_id,
          source_operation_id: source_operation_id,
          remaining_cents: amount,
          expires_on: expires_on
        })
      )

  defp revision_matches(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp common_valid?(operation),
    do:
      valid_identifier?(operation["operation_id"]) and
        is_binary(operation["type"]) and match?({:ok, _}, date(operation["occurred_on"]))

  defp operation_date(operation), do: date(operation["occurred_on"])

  defp required_fields("record_cash_payment"),
    do: ~w(operation_id type occurred_on group_id amount_cents)

  defp required_fields("reschedule_group"),
    do: ~w(operation_id type occurred_on group_id new_arrival_on)

  defp required_fields("cancel_group"), do: ~w(operation_id type occurred_on group_id)
  defp required_fields("cancel_rooms"), do: ~w(operation_id type occurred_on group_id room_ids)

  defp required_fields("apply_hotel_credit"),
    do: ~w(operation_id type occurred_on group_id amount_cents)

  defp required_fields("reduce_cash_payment"),
    do: ~w(operation_id type occurred_on payment_operation_id amount_cents)

  defp required_fields("charge_back_payment"),
    do: ~w(operation_id type occurred_on payment_operation_id)

  defp required_fields(_), do: []
  defp required_keys?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))

  defp rooms(value) do
    if valid_rooms?(value),
      do:
        {:ok,
         value
         |> Enum.with_index()
         |> Enum.map(fn {room, position} ->
           %{
             room_id: room["room_id"],
             nightly_rate_cents: room["nightly_rate_cents"],
             position: position
           }
         end)},
      else: {:error, :invalid_rooms}
  end

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn
      %{"room_id" => id, "nightly_rate_cents" => rate} ->
        valid_identifier?(id) and is_integer(rate) and rate > 0

      _ ->
        false
    end) and Enum.uniq_by(rooms, & &1["room_id"]) == rooms
  end

  defp valid_rooms?(_), do: false

  defp valid_selected_rooms?(ids, rooms) when is_list(ids) and ids != [] do
    Enum.all?(ids, &valid_identifier?/1) and length(Enum.uniq(ids)) == length(ids) and
      MapSet.subset?(MapSet.new(ids), MapSet.new(Enum.map(rooms, & &1.room_id)))
  end

  defp valid_selected_rooms?(_, _), do: false

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_date}
    end
  end

  defp date(_), do: {:error, :invalid_date}
  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0

  defp room_outstanding(room),
    do: max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

  defp round_flexible_deposit(cents), do: div(cents + 2, 5)
  defp round_ten_percent(cents), do: div(cents + 5, 10)
  defp bonused(cents), do: cents + round_ten_percent(cents)
  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on),
    do: if(Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  defp refundable_until("flex-14", arrival), do: Date.add(arrival, -14)
  defp refundable_until("flex-30", arrival), do: Date.add(arrival, -30)
  defp refundable_until("advance-nonrefundable", _), do: nil
  defp refundable?(%Group{refundable_until: nil}, _), do: false
  defp refundable?(group, on), do: Date.compare(on, group.refundable_until) in [:lt, :eq]
  defp iso_date(nil), do: nil
  defp iso_date(date), do: Date.to_iso8601(date)
  defp reject(code, extra \\ %{}), do: {:error, Map.put(extra, :code, code)}
end
