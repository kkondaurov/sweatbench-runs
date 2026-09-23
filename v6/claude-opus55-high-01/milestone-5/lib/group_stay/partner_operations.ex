defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner batch operations in order.

  Each operation runs in its own transaction, which also commits the operation's durable record
  (see `GroupStay.OperationRecords`). A rejected operation leaves domain state exactly as it found
  it but its rejection is remembered, and processing continues with the next operation.

  An operation whose `operation_id` has already been remembered is not applied again: an
  equivalent submission receives the stored result without consulting domain state, and a
  different submission is rejected with `operation_id_conflict`.

  An unexpected exception rolls back the current operation, leaves it unremembered, and
  propagates, aborting the rest of the batch.
  """

  import Ecto.Query

  alias GroupStay.{CancellationPolicy, Credits, Deposits, OperationRecords, Payments}
  alias GroupStay.{RoomAccounting, WriteLock}
  alias GroupStay.Credits.{CreditApplication, CreditLot}
  alias GroupStay.Groups.{CashAllocation, Group, LedgerEntry, Room}
  alias GroupStay.Repo

  @refund_methods ~w(cash hotel_credit)

  # Largest amount stored or reported. Keeps totals within SQLite integers and JSON-safe numbers.
  @max_cents 9_007_199_254_740_991

  @doc """
  Processes a list of raw (decoded JSON) operations and returns one result map per operation, in
  the same order.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Processes a single raw operation and returns its result as decoded JSON."
  def process_operation(%{"operation_id" => operation_id} = operation)
      when is_binary(operation_id) and operation_id != "" do
    payload = OperationRecords.canonical_json(operation)

    # The record is looked up inside the write transaction, so concurrent submissions of one
    # identifier are serialized and only the first is applied.
    {:ok, result} =
      WriteLock.run(fn ->
        Repo.transaction(fn -> remembered_or_applied(operation_id, operation, payload) end,
          mode: :immediate
        )
      end)

    result
  end

  # Without a usable identifier an operation cannot be applied or remembered.
  def process_operation(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id")
    result({:error, %{code: "invalid_operation"}}, operation_id)
  end

  defp remembered_or_applied(operation_id, operation, payload) do
    case OperationRecords.get(operation_id) do
      nil ->
        result = operation |> evaluate() |> result(operation_id)
        OperationRecords.insert!(operation_id, operation, payload, result)

      %{payload: ^payload} = record ->
        OperationRecords.result(record)

      _other_submission ->
        result({:error, %{code: "operation_id_conflict"}}, operation_id)
    end
  end

  defp evaluate(operation) do
    case parse(operation) do
      {:ok, command} -> in_savepoint(fn -> apply_command(command) end)
      {:error, code} -> {:error, %{code: code}}
    end
  end

  defp result({:ok, fields}, operation_id),
    do: json_form(Map.merge(%{operation_id: operation_id, status: "applied"}, fields))

  defp result({:error, fields}, operation_id),
    do: json_form(Map.merge(%{operation_id: operation_id, status: "rejected"}, fields))

  # Results take the form they are stored and returned in, so a first response and its retries
  # are identical.
  defp json_form(result), do: result |> Jason.encode!() |> Jason.decode!()

  # A rejection undoes any domain changes the command made, while the enclosing transaction goes
  # on to commit the operation's record. Ecto's nested transactions cannot roll back on their
  # own, so this uses a savepoint directly.
  defp in_savepoint(fun) do
    Repo.query!("SAVEPOINT partner_operation")

    outcome = fun.()

    if match?({:error, _}, outcome), do: Repo.query!("ROLLBACK TO partner_operation")
    Repo.query!("RELEASE partner_operation")

    outcome
  end

  ## Parsing
  #
  # Parsing only checks that the operation can be identified and carries the data it needs.
  # Domain rules (dates, rooms, amounts, rate plans) are evaluated when the command is applied.

  defp parse(%{} = op) do
    with {:ok, operation_id} <- required_identifier(op, "operation_id"),
         {:ok, type} <- required_identifier(op, "type"),
         {:ok, occurred_on} <- required_date(op, "occurred_on") do
      base = %{operation_id: operation_id, occurred_on: occurred_on}
      parse_type(type, op, base)
    end
  end

  defp parse(_operation), do: {:error, "invalid_operation"}

  defp parse_type("open_group", op, base) do
    with {:ok, group_id} <- required_identifier(op, "group_id"),
         {:ok, guest_id} <- required_identifier(op, "guest_id"),
         {:ok, property_id} <- required_identifier(op, "property_id"),
         {:ok, arrival_on} <- required_present(op, "arrival_on"),
         {:ok, departure_on} <- required_present(op, "departure_on"),
         {:ok, rate_plan} <- required_present(op, "rate_plan"),
         {:ok, rooms} <- required_present(op, "rooms") do
      {:ok,
       Map.merge(base, %{
         type: :open_group,
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       })}
    end
  end

  defp parse_type("record_cash_payment", op, base) do
    with {:ok, command} <- group_command(:record_cash_payment, op, base),
         {:ok, amount} <- required_present(op, "amount_cents") do
      {:ok, Map.put(command, :amount_cents, amount)}
    end
  end

  defp parse_type("reschedule_group", op, base) do
    with {:ok, command} <- group_command(:reschedule_group, op, base),
         {:ok, new_arrival_on} <- required_present(op, "new_arrival_on") do
      {:ok, Map.put(command, :new_arrival_on, new_arrival_on)}
    end
  end

  defp parse_type("apply_hotel_credit", op, base) do
    with {:ok, command} <- group_command(:apply_hotel_credit, op, base),
         {:ok, amount} <- required_present(op, "amount_cents") do
      {:ok, Map.put(command, :amount_cents, amount)}
    end
  end

  defp parse_type("cancel_group", op, base) do
    with {:ok, command} <- group_command(:cancel_group, op, base),
         {:ok, refund_method} <- optional_refund_method(op) do
      {:ok, Map.put(command, :refund_method, refund_method)}
    end
  end

  defp parse_type("cancel_rooms", op, base) do
    with {:ok, command} <- group_command(:cancel_rooms, op, base),
         {:ok, room_ids} <- required_present(op, "room_ids"),
         {:ok, refund_method} <- optional_refund_method(op) do
      {:ok, Map.merge(command, %{room_ids: room_ids, refund_method: refund_method})}
    end
  end

  defp parse_type("reduce_cash_payment", op, base) do
    with {:ok, command} <- payment_command(:reduce_cash_payment, op, base),
         {:ok, amount} <- required_present(op, "amount_cents") do
      {:ok, Map.put(command, :amount_cents, amount)}
    end
  end

  defp parse_type("charge_back_payment", op, base),
    do: payment_command(:charge_back_payment, op, base)

  defp parse_type("transfer_deposit", op, base) do
    with {:ok, source_group_id} <- required_identifier(op, "source_group_id"),
         {:ok, destination_group_id} <- required_identifier(op, "destination_group_id"),
         {:ok, amount} <- required_present(op, "amount_cents"),
         {:ok, expected_revision} <- optional_revision(op, "expected_revision"),
         {:ok, destination_expected_revision} <-
           optional_revision(op, "destination_expected_revision") do
      {:ok,
       Map.merge(base, %{
         type: :transfer_deposit,
         source_group_id: source_group_id,
         destination_group_id: destination_group_id,
         amount_cents: amount,
         expected_revision: expected_revision,
         destination_expected_revision: destination_expected_revision
       })}
    end
  end

  defp parse_type(_type, _op, _base), do: {:error, "invalid_operation"}

  defp group_command(type, op, base) do
    with {:ok, group_id} <- required_identifier(op, "group_id"),
         {:ok, expected_revision} <- optional_revision(op, "expected_revision") do
      {:ok,
       Map.merge(base, %{type: type, group_id: group_id, expected_revision: expected_revision})}
    end
  end

  # Payment corrections address a durably recorded payment; its group is derived from it.
  defp payment_command(type, op, base) do
    with {:ok, payment_operation_id} <- required_identifier(op, "payment_operation_id"),
         {:ok, expected_revision} <- optional_revision(op, "expected_revision") do
      {:ok,
       Map.merge(base, %{
         type: type,
         payment_operation_id: payment_operation_id,
         expected_revision: expected_revision
       })}
    end
  end

  defp required_identifier(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_present(op, key) do
    case Map.get(op, key) do
      nil -> {:error, "invalid_operation"}
      value -> {:ok, value}
    end
  end

  defp required_date(op, key) do
    case parse_date(Map.get(op, key)) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp optional_revision(op, key) do
    case Map.get(op, key) do
      nil -> {:ok, nil}
      revision when is_integer(revision) and revision > 0 -> {:ok, revision}
      _ -> {:error, "invalid_operation"}
    end
  end

  # Omitting the refund method means cash, as it did before hotel credit existed.
  defp optional_refund_method(op) do
    case Map.get(op, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in @refund_methods -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_value), do: :error

  ## Opening

  defp apply_command(%{type: :open_group} = cmd) do
    with :ok <- ensure_group_absent(cmd.group_id),
         {:ok, arrival_on, departure_on} <- validate_stay(cmd),
         {:ok, rate_plan} <- validate_rate_plan(cmd.rate_plan),
         {:ok, rooms} <- validate_rooms(cmd.rooms),
         {:ok, priced_rooms} <- price_rooms(rooms, arrival_on, departure_on, rate_plan) do
      group =
        Repo.insert!(%Group{
          group_id: cmd.group_id,
          guest_id: cmd.guest_id,
          property_id: cmd.property_id,
          booked_on: cmd.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: CancellationPolicy.version_for(rate_plan, cmd.occurred_on),
          status: "active",
          revision: 1,
          lodging_total_cents: sum(priced_rooms, :lodging_cents),
          deposit_due_cents: sum(priced_rooms, :deposit_cents),
          deposit_paid_cents: 0,
          credit_paid_cents: 0
        })

      Enum.each(priced_rooms, fn room ->
        Repo.insert!(struct!(Room, Map.put(room, :group_ref, group.id)))
      end)

      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    end
  end

  ## Cash payments

  defp apply_command(%{type: :record_cash_payment} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(cmd.amount_cents),
         :ok <- ensure_within_outstanding(group, amount) do
      insert_ledger_entry!(group.id, cmd, "cash_payment", amount)

      for {:cash, room_ref, allocated} <- RoomAccounting.fill(group, [{:cash, amount}]) do
        Repo.insert!(%CashAllocation{
          group_ref: group.id,
          room_ref: room_ref,
          payment_operation_id: cmd.operation_id,
          amount_cents: allocated,
          status: "held",
          allocation_seq: RoomAccounting.next_allocation_seq()
        })
      end

      group = update_group!(group, deposit_paid_cents: group.deposit_paid_cents + amount)

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  ## Hotel credit

  defp apply_command(%{type: :apply_hotel_credit} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group),
         {:ok, amount} <- validate_amount(cmd.amount_cents),
         :ok <- ensure_within_outstanding(group, amount),
         {:ok, draws} <- draw_credit(group.guest_id, amount, cmd.occurred_on) do
      Enum.each(draws, fn {lot, drawn} ->
        {1, _} =
          Repo.update_all(
            from(l in CreditLot, where: l.id == ^lot.id and l.remaining_cents >= ^drawn),
            inc: [remaining_cents: -drawn],
            set: [updated_at: now()]
          )
      end)

      for {lot, room_ref, allocated} <- RoomAccounting.fill(group, draws) do
        Repo.insert!(%CreditApplication{
          group_ref: group.id,
          lot_ref: lot.id,
          room_ref: room_ref,
          operation_id: cmd.operation_id,
          amount_cents: allocated,
          applied_on: cmd.occurred_on,
          status: "applied",
          allocation_seq: RoomAccounting.next_allocation_seq()
        })
      end

      group =
        update_group!(group,
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount
        )

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  ## Rescheduling

  defp apply_command(%{type: :reschedule_group} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on, new_departure_on} <- validate_new_stay(group, cmd) do
      group = update_group!(group, arrival_on: new_arrival_on, departure_on: new_departure_on)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         policy_version: group.policy_version,
         refundable_until: Group.refundable_until(group),
         revision: group.revision
       }}
    end
  end

  ## Cancellation

  defp apply_command(%{type: :cancel_group} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group),
         {:ok, group, settlement} <- settle_rooms(group, active_rooms(group), cmd) do
      {:ok, Map.merge(%{group_id: group.group_id, revision: group.revision}, settlement)}
    end
  end

  defp apply_command(%{type: :cancel_rooms} = cmd) do
    with {:ok, group} <- fetch_group_for_update(cmd),
         :ok <- ensure_active(group),
         {:ok, rooms} <- select_rooms(group, cmd.room_ids),
         {:ok, group, settlement} <- settle_rooms(group, rooms, cmd) do
      {:ok,
       Map.merge(
         %{
           group_id: group.group_id,
           cancelled_room_ids: Enum.map(rooms, & &1.room_id),
           revision: group.revision
         },
         settlement
       )}
    end
  end

  ## Payment corrections

  defp apply_command(%{type: :reduce_cash_payment} = cmd) do
    with {:ok, payment, group} <- fetch_payment_group_for_update(cmd, "payment_not_reducible"),
         held = held_allocations(payment),
         held_cents = sum(held, :amount_cents),
         :ok <- if(held_cents > 0, do: :ok, else: {:error, %{code: "payment_not_reducible"}}),
         {:ok, amount} <- validate_amount(cmd.amount_cents),
         :ok <- ensure_within(held_cents, amount, "reduction_exceeds_held_cash") do
      removed =
        held
        |> take_funding(amount)
        |> Enum.map(fn {allocation, cents} ->
          split_off!(allocation, cents, status: "reduced", settled_on: cmd.occurred_on)
          {allocation.group_ref, cents}
        end)
        |> sum_by_key()

      for {group_ref, cents} <- removed,
          do: insert_ledger_entry!(group_ref, cmd, "cash_reduced", cents)

      group = withdraw_held_cash!(group, removed)

      {:ok,
       %{
         payment_operation_id: payment.payment_operation_id,
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  defp apply_command(%{type: :charge_back_payment} = cmd) do
    with {:ok, payment, group} <- fetch_payment_group_for_update(cmd, "payment_not_chargeable"),
         allocations = chargeable_allocations(payment),
         charged_back = sum(allocations, :amount_cents),
         :ok <- if(charged_back > 0, do: :ok, else: {:error, %{code: "payment_not_chargeable"}}) do
      by_group_and_status =
        allocations |> Enum.map(&{{&1.group_ref, &1.status}, &1.amount_cents}) |> sum_by_key()

      # Entitlements are computed from the lot's converted cash, which the chargeback keeps
      # attributed to the lot, so the order of these steps does not matter.
      for lot_ref <-
            allocations |> Enum.map(& &1.lot_ref) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
        entitlement =
          lot_ref
          |> Payments.lot_entitlements()
          |> Enum.find_value(0, fn {id, cents} ->
            if id == payment.payment_operation_id, do: cents
          end)

        claw_back_credit!(lot_ref, entitlement)
      end

      {_count, _} =
        Repo.update_all(from(a in CashAllocation, where: a.id in ^Enum.map(allocations, & &1.id)),
          set: [status: "charged_back", settled_on: cmd.occurred_on, updated_at: now()]
        )

      for {{group_ref, status}, cents} <- by_group_and_status,
          do: insert_ledger_entry!(group_ref, cmd, "cash_charged_back_" <> status, cents)

      # Only held cash funds groups; settled cash is reclassified without reversing the
      # historical refund, retention, or conversion.
      group =
        withdraw_held_cash!(
          group,
          for({{group_ref, "held"}, cents} <- by_group_and_status, do: {group_ref, cents})
        )

      {:ok,
       %{
         payment_operation_id: payment.payment_operation_id,
         group_id: group.group_id,
         charged_back_cents: charged_back,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  ## Deposit transfers

  defp apply_command(%{type: :transfer_deposit} = cmd) do
    with {:ok, source} <- fetch_transfer_group(cmd.source_group_id),
         {:ok, destination} <- fetch_transfer_group(cmd.destination_group_id),
         :ok <- ensure_revision(source, cmd.expected_revision),
         :ok <- ensure_revision(destination, cmd.destination_expected_revision),
         :ok <- ensure_transferable(source, destination),
         :ok <- ensure_transfer_active(source),
         :ok <- ensure_transfer_active(destination),
         {:ok, amount} <- validate_amount(cmd.amount_cents),
         held = RoomAccounting.held_funding(source),
         :ok <- ensure_within(sum(held, :amount_cents), amount, "transfer_exceeds_held_funding"),
         :ok <-
           ensure_within(
             Group.outstanding_deposit_cents(destination),
             amount,
             "transfer_exceeds_outstanding"
           ) do
      credit = transfer_funding!(held, amount, destination, cmd)

      source =
        update_group!(source,
          deposit_paid_cents: source.deposit_paid_cents - amount,
          credit_paid_cents: source.credit_paid_cents - credit
        )

      destination =
        update_group!(destination,
          deposit_paid_cents: destination.deposit_paid_cents + amount,
          credit_paid_cents: destination.credit_paid_cents + credit
        )

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: amount,
         source_outstanding_deposit_cents: Group.outstanding_deposit_cents(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit_cents(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  # A transfer names both of its groups, so a missing one is identified.
  defp fetch_transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, %{code: "group_not_found", group_id: group_id}}
      group -> {:ok, group}
    end
  end

  defp ensure_transferable(source, destination) do
    if source.id != destination.id and source.guest_id == destination.guest_id,
      do: :ok,
      else: {:error, %{code: "invalid_transfer"}}
  end

  defp ensure_transfer_active(%Group{status: "active"}), do: :ok

  defp ensure_transfer_active(%Group{} = group),
    do: {:error, %{code: "group_not_active", group_id: group.group_id}}

  # Moves `amount` of the source's held funding (most recently allocated first) to the
  # destination's rooms, which it fills in the order it was drawn. Moved funding keeps its
  # payment or credit lot and is allocated anew in the destination. Returns the credit moved.
  defp transfer_funding!(held, amount, destination, cmd) do
    draws = take_funding(held, amount)
    moved = [transfer_operation_id: cmd.operation_id]

    Enum.each(draws, fn {funding, cents} ->
      split_off!(funding, cents, [status: "transferred", settled_on: cmd.occurred_on] ++ moved)
    end)

    for {funding, room_ref, cents} <- RoomAccounting.fill(destination, draws) do
      insert_copy!(
        funding,
        [
          group_ref: destination.id,
          room_ref: room_ref,
          amount_cents: cents,
          allocation_seq: RoomAccounting.next_allocation_seq()
        ] ++ moved
      )
    end

    for({%CreditApplication{}, cents} <- draws, do: cents) |> Enum.sum()
  end

  ## Settling rooms

  defp active_rooms(group),
    do: for(%Room{status: "active"} = room <- RoomAccounting.rooms(group), do: room)

  # Every identifier must name a distinct active room of the group. Rooms are returned in the
  # group's original order.
  defp select_rooms(group, [_ | _] = room_ids) do
    active = active_rooms(group)
    active_ids = MapSet.new(active, & &1.room_id)

    if Enum.all?(room_ids, &(is_binary(&1) and &1 in active_ids)) and
         Enum.uniq(room_ids) == room_ids do
      {:ok, Enum.filter(active, &(&1.room_id in room_ids))}
    else
      {:error, %{code: "invalid_rooms"}}
    end
  end

  defp select_rooms(_group, _room_ids), do: {:error, %{code: "invalid_rooms"}}

  # Settles the funding of `rooms` under the group's policy on the operation date and cancels
  # them. Cancelling the last active rooms cancels the group.
  defp settle_rooms(group, rooms, cmd) do
    refundable? =
      CancellationPolicy.refundable?(group.policy_version, group.arrival_on, cmd.occurred_on)

    if not refundable? and cmd.refund_method == "hotel_credit" do
      # Hotel credit is only offered in place of a cash refund, never for a non-refundable group.
      {:error, %{code: "refund_method_not_available"}}
    else
      room_refs = Enum.map(rooms, & &1.id)
      closing? = length(rooms) == length(active_rooms(group))
      {cash, settlement} = settle_cash!(group, room_refs, closing?, cmd, refundable?)
      credit = settle_applied_credit!(group, room_refs, closing?, cmd.occurred_on, refundable?)

      {_count, _} =
        Repo.update_all(from(r in Room, where: r.id in ^room_refs), set: [status: "cancelled"])

      changes =
        if closing? do
          [
            status: "cancelled",
            lodging_total_cents: 0,
            deposit_due_cents: 0,
            deposit_paid_cents: 0,
            credit_paid_cents: 0
          ]
        else
          [
            lodging_total_cents: group.lodging_total_cents - sum(rooms, :lodging_cents),
            deposit_due_cents: group.deposit_due_cents - sum(rooms, :deposit_cents),
            deposit_paid_cents: group.deposit_paid_cents - cash - credit,
            credit_paid_cents: group.credit_paid_cents - credit
          ]
        end

      {:ok, update_group!(group, changes), settlement}
    end
  end

  # Cash is refunded, retained, or converted to one new credit lot whose bonus is computed on the
  # combined cash of the settled rooms.
  defp settle_cash!(group, room_refs, closing?, cmd, refundable?) do
    allocations =
      from(a in CashAllocation, where: a.group_ref == ^group.id and a.status == "held")
      |> in_rooms(room_refs, closing?)
      |> Repo.all()

    cash = sum(allocations, :amount_cents)

    {status, kind, settlement} =
      cond do
        not refundable? ->
          {"retained", "cash_retained", %{refunded_cents: 0, retained_cents: cash}}

        cmd.refund_method == "cash" ->
          {"refunded", "cash_refund", %{refunded_cents: cash, retained_cents: 0}}

        cmd.refund_method == "hotel_credit" ->
          {"converted", "cash_converted_to_credit", %{refunded_cents: 0, retained_cents: 0}}
      end

    {issued, lot_ref} =
      if status == "converted", do: issue_credit!(group, cmd, cash), else: {0, nil}

    {_count, _} =
      Repo.update_all(from(a in CashAllocation, where: a.id in ^Enum.map(allocations, & &1.id)),
        set: [status: status, lot_ref: lot_ref, settled_on: cmd.occurred_on, updated_at: now()]
      )

    insert_ledger_entry!(group.id, cmd, kind, cash)

    {cash, Map.put(settlement, :credit_issued_cents, issued)}
  end

  # Converted cash becomes a new lot worth the cash plus the bonus.
  defp issue_credit!(_group, _cmd, 0 = _cash), do: {0, nil}

  defp issue_credit!(group, cmd, cash) do
    issued = cash + Deposits.percentage_cents(cash, Credits.bonus_percent())

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: cmd.operation_id,
        source_group_ref: group.id,
        issued_cents: issued,
        remaining_cents: issued,
        issued_on: cmd.occurred_on,
        expires_on: Credits.expires_on(cmd.occurred_on)
      })

    {issued, lot.id}
  end

  # Credit funding the settled rooms returns to its original lots when the cancellation is
  # refundable, without a second bonus. A lot's unrecovered clawback absorbs returning credit
  # first; the rest expires at once if the lot has already expired. A non-refundable
  # cancellation consumes it. Returns the amount of credit settled.
  defp settle_applied_credit!(group, room_refs, closing?, cancelled_on, refundable?) do
    applications =
      from(a in CreditApplication, where: a.group_ref == ^group.id and a.status == "applied")
      |> in_rooms(room_refs, closing?)
      |> Repo.all()

    Enum.each(applications, fn application ->
      if refundable?,
        do: return_credit!(application, cancelled_on),
        else: settle_application!(application, "consumed", application.amount_cents, cancelled_on)
    end)

    sum(applications, :amount_cents)
  end

  defp return_credit!(application, cancelled_on) do
    lot = Repo.get!(CreditLot, application.lot_ref)
    absorbed = min(lot.unrecovered_clawback_cents, application.amount_cents)
    returned = application.amount_cents - absorbed
    usable? = Credits.usable?(lot.expires_on, cancelled_on)
    restored = if usable?, do: returned, else: 0

    {1, _} =
      Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id),
        inc: [unrecovered_clawback_cents: -absorbed, remaining_cents: restored],
        set: [updated_at: now()]
      )

    if absorbed > 0 and returned > 0 do
      insert_copy!(application,
        amount_cents: absorbed,
        status: "absorbed",
        settled_on: cancelled_on
      )
    end

    cond do
      returned == 0 -> settle_application!(application, "absorbed", absorbed, cancelled_on)
      usable? -> settle_application!(application, "restored", returned, cancelled_on)
      true -> settle_application!(application, "expired", returned, cancelled_on)
    end
  end

  defp settle_application!(application, status, amount, settled_on) do
    {1, _} =
      Repo.update_all(from(a in CreditApplication, where: a.id == ^application.id),
        set: [status: status, amount_cents: amount, settled_on: settled_on, updated_at: now()]
      )
  end

  # Settling the group's last active rooms also settles any funding no room could hold.
  defp in_rooms(query, _room_refs, true = _closing?), do: query
  defp in_rooms(query, room_refs, false), do: where(query, [a], a.room_ref in ^room_refs)

  ## Payment allocations

  # The payment named by a correction, and its group with the revision precondition checked.
  # A remembered operation that is not an applied payment has no group to address.
  defp fetch_payment_group_for_update(cmd, not_payment_code) do
    case Payments.fetch(cmd.payment_operation_id) do
      {:error, :not_found} ->
        {:error, %{code: "operation_not_found"}}

      {:error, :not_payment} ->
        {:error, %{code: not_payment_code}}

      {:ok, payment} ->
        target = %{group_id: payment.group_id, expected_revision: cmd.expected_revision}

        with {:ok, group} <- fetch_group_for_update(target), do: {:ok, payment, group}
    end
  end

  # The payment's cash still funding active rooms in any group, most recently allocated first.
  defp held_allocations(payment) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment.payment_operation_id and a.status == "held",
        order_by: [desc: a.allocation_seq, desc: a.id]
    )
  end

  # The payment's cash, wherever it is, that has not been reduced or already charged back.
  defp chargeable_allocations(payment) do
    Repo.all(
      from a in CashAllocation,
        where:
          a.payment_operation_id == ^payment.payment_operation_id and
            a.status in ["held", "refunded", "retained", "converted"],
        order_by: [a.allocation_seq, a.id]
    )
  end

  # Removes held cash from the groups it funds, as `%{group_ref => cents}`. Every group that
  # loses funding moves to a new revision, and the addressed group always does, exactly once.
  defp withdraw_held_cash!(%Group{} = addressed, removed) do
    for {group_ref, cents} <- removed, group_ref != addressed.id do
      group = Repo.get!(Group, group_ref)
      update_group!(group, deposit_paid_cents: group.deposit_paid_cents - cents)
    end

    removed_here =
      Enum.find_value(removed, 0, fn {ref, cents} -> ref == addressed.id && cents end)

    update_group!(addressed, deposit_paid_cents: addressed.deposit_paid_cents - removed_here)
  end

  # Revokes a charged-back payment's entitlement from a lot: first from its remaining balance,
  # and whatever that cannot cover becomes the lot's unrecovered clawback.
  defp claw_back_credit!(lot_ref, entitlement) do
    lot = Repo.get!(CreditLot, lot_ref)
    removed = min(lot.remaining_cents, entitlement)

    {1, _} =
      Repo.update_all(from(l in CreditLot, where: l.id == ^lot_ref),
        inc: [remaining_cents: -removed, unrecovered_clawback_cents: entitlement - removed],
        set: [updated_at: now()]
      )
  end

  ## Shared rules

  defp ensure_group_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id),
      do: {:error, %{code: "group_already_exists"}},
      else: :ok
  end

  # Group existence is resolved first, then the revision precondition, before any other rule.
  defp fetch_group_for_update(%{group_id: group_id, expected_revision: expected}) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, %{code: "group_not_found"}}

      group ->
        with :ok <- ensure_revision(group, expected), do: {:ok, group}
    end
  end

  defp ensure_revision(%Group{revision: actual} = group, expected)
       when is_integer(expected) and expected != actual do
    {:error,
     %{
       code: "stale_revision",
       group_id: group.group_id,
       expected_revision: expected,
       actual_revision: actual
     }}
  end

  defp ensure_revision(%Group{}, _expected), do: :ok

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:error, %{code: "group_not_active"}}

  defp validate_stay(cmd) do
    with {:ok, arrival_on} <- parse_date(cmd.arrival_on),
         {:ok, departure_on} <- parse_date(cmd.departure_on),
         true <- Date.compare(arrival_on, cmd.occurred_on) == :gt,
         true <- Date.compare(departure_on, arrival_on) == :gt do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, %{code: "invalid_stay"}}
    end
  end

  # The departure moves by the same number of days as the arrival, keeping the stay's length.
  defp validate_new_stay(group, cmd) do
    with {:ok, new_arrival_on} <- parse_date(cmd.new_arrival_on),
         :gt <- Date.compare(new_arrival_on, cmd.occurred_on),
         new_departure_on =
           Date.add(group.departure_on, Date.diff(new_arrival_on, group.arrival_on)),
         true <- new_departure_on.year <= 9999 do
      {:ok, new_arrival_on, new_departure_on}
    else
      _ -> {:error, %{code: "invalid_stay"}}
    end
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in Deposits.rate_plans(),
      do: {:ok, rate_plan},
      else: {:error, %{code: "invalid_rate_plan"}}
  end

  defp validate_rooms([_ | _] = rooms) do
    parsed = Enum.map(rooms, &parse_room/1)
    room_ids = Enum.map(parsed, &elem(&1, 0))

    if Enum.all?(parsed, &match?({id, _} when is_binary(id), &1)) and
         Enum.uniq(room_ids) == room_ids do
      {:ok, parsed}
    else
      {:error, %{code: "invalid_rooms"}}
    end
  end

  defp validate_rooms(_rooms), do: {:error, %{code: "invalid_rooms"}}

  defp parse_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0,
       do: {room_id, rate}

  defp parse_room(_room), do: {:invalid, nil}

  defp price_rooms(rooms, arrival_on, departure_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    priced_rooms =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {{room_id, rate}, position} ->
        lodging = Deposits.room_lodging_cents(nights, rate)

        %{
          position: position,
          room_id: room_id,
          nightly_rate_cents: rate,
          lodging_cents: lodging,
          deposit_cents: Deposits.room_deposit_cents(rate_plan, lodging)
        }
      end)

    if sum(priced_rooms, :lodging_cents) <= @max_cents,
      do: {:ok, priced_rooms},
      else: {:error, %{code: "invalid_rooms"}}
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp validate_amount(_amount), do: {:error, %{code: "invalid_amount"}}

  defp ensure_within_outstanding(group, amount),
    do:
      ensure_within(Group.outstanding_deposit_cents(group), amount, "payment_exceeds_outstanding")

  defp ensure_within(limit, amount, code),
    do: if(amount <= limit, do: :ok, else: {:error, %{code: code}})

  # Takes `amount` from funding rows in the order given, as `{row, cents}` draws.
  defp take_funding(rows, amount) do
    rows
    |> Enum.reduce_while({[], amount}, fn
      _row, {draws, 0} ->
        {:halt, {draws, 0}}

      row, {draws, left} ->
        taken = min(row.amount_cents, left)
        {:cont, {[{row, taken} | draws], left - taken}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Gives `cents` of a funding row the attributes `changes`. A row taken in full is changed in
  # place; otherwise it keeps its remainder and the part taken becomes a new row.
  defp split_off!(%schema{amount_cents: cents} = row, cents, changes) do
    {1, _} =
      Repo.update_all(from(r in schema, where: r.id == ^row.id),
        set: [updated_at: now()] ++ changes
      )
  end

  defp split_off!(%schema{} = row, cents, changes) do
    {1, _} =
      Repo.update_all(from(r in schema, where: r.id == ^row.id),
        inc: [amount_cents: -cents],
        set: [updated_at: now()]
      )

    insert_copy!(row, [amount_cents: cents] ++ changes)
  end

  # Takes `amount` from the guest's lots usable on `on`, earliest expiry first. Returns the
  # lots with the amount drawn from each.
  defp draw_credit(guest_id, amount, on) do
    {draws, short} =
      guest_id
      |> Credits.available_lots_query(on)
      |> Repo.all()
      |> Enum.reduce_while({[], amount}, fn
        _lot, {draws, 0} ->
          {:halt, {draws, 0}}

        lot, {draws, needed} ->
          drawn = min(lot.remaining_cents, needed)
          {:cont, {[{lot, drawn} | draws], needed - drawn}}
      end)

    if short == 0,
      do: {:ok, Enum.reverse(draws)},
      else: {:error, %{code: "insufficient_credit"}}
  end

  # Every applied operation addressed to a group increments its revision exactly once. The
  # revision guard in the WHERE clause protects against a concurrent writer.
  defp update_group!(%Group{} = group, changes) do
    changes = Keyword.merge(changes, revision: group.revision + 1, updated_at: now())

    {1, _} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision),
        set: changes
      )

    struct!(group, changes)
  end

  defp insert_ledger_entry!(_group_ref, _cmd, _kind, 0 = _amount), do: :ok

  defp insert_ledger_entry!(group_ref, cmd, kind, amount) do
    Repo.insert!(%LedgerEntry{
      group_ref: group_ref,
      operation_id: cmd.operation_id,
      kind: kind,
      amount_cents: amount,
      occurred_on: cmd.occurred_on
    })
  end

  # Splits a row: a new row with the same attributes apart from `changes`.
  defp insert_copy!(%schema{} = row, changes) do
    row
    |> Map.take(schema.__schema__(:fields) -- [:id, :inserted_at, :updated_at])
    |> then(&struct!(schema, &1))
    |> struct!(changes)
    |> Repo.insert!()
  end

  defp sum(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  # Sums `{key, amount}` pairs by key, in key order.
  defp sum_by_key(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {key, amounts} -> {key, Enum.sum(amounts)} end)
    |> Enum.sort()
  end

  defp now, do: DateTime.utc_now()
end
