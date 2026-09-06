defmodule GroupStay.Batches do
  @moduledoc """
  Applies partner batch operations.

  Operations are processed in array order, each in its own database
  transaction, so an operation observes the changes of earlier operations in
  the same batch. The first operation received for an `operation_id` is
  processed and remembered together with its result; an exact retry replays
  the stored result without reading or changing domain state, and a
  different payload under the same identifier is rejected with
  `operation_id_conflict`. A handled rejection leaves domain state unchanged
  but commits its idempotency record, and never stops later operations. An
  unexpected exception rolls back the current operation, remembers nothing,
  and aborts the whole request.
  """

  alias GroupStay.Credits
  alias GroupStay.Finance
  alias GroupStay.Groups
  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger
  alias GroupStay.Operations
  alias GroupStay.Operations.Record
  alias GroupStay.Payments
  alias GroupStay.Repo

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group
                      apply_hotel_credit cancel_rooms reduce_cash_payment
                      charge_back_payment transfer_deposit start_finance_reporting
                      close_finance_period)

  # Fields an operation must carry to be identifiable and applicable at all.
  # Missing or wrongly typed values reject the operation as `invalid_operation`.
  @required_string_fields %{
    "open_group" => ~w(group_id guest_id property_id),
    "record_cash_payment" => ~w(group_id),
    "reschedule_group" => ~w(group_id),
    "cancel_group" => ~w(group_id),
    "apply_hotel_credit" => ~w(group_id),
    "cancel_rooms" => ~w(group_id),
    "reduce_cash_payment" => ~w(payment_operation_id),
    "charge_back_payment" => ~w(payment_operation_id),
    "transfer_deposit" => ~w(source_group_id destination_group_id),
    "start_finance_reporting" => [],
    "close_finance_period" => []
  }

  @required_present_fields %{
    "open_group" => ~w(arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => [],
    "apply_hotel_credit" => ~w(amount_cents),
    "cancel_rooms" => ~w(room_ids),
    "reduce_cash_payment" => ~w(amount_cents),
    "charge_back_payment" => [],
    "transfer_deposit" => ~w(amount_cents),
    # `starts_on` is validated as `invalid_reporting_date` instead.
    "start_finance_reporting" => [],
    # `period_end_on` is validated as `invalid_period` instead.
    "close_finance_period" => []
  }

  @refund_methods ~w(cash hotel_credit)

  # The number of days a credit lot is available after the cancellation that
  # issued it; it expires the following day.
  @credit_available_days 365

  @doc """
  Applies every operation in order and returns one result per operation, in
  the same order.
  """
  def apply_operations(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(operation) do
    {:ok, result} = Repo.transaction(fn -> process_operation(operation) end)
    result
  end

  ## Idempotent processing

  # Idempotency is keyed by the partner's operation identifier. A first
  # submission is processed and remembered in the same transaction as its
  # domain changes; an exact retry replays the stored result without
  # touching domain state; a different payload under the same identifier
  # conflicts and leaves the original record in place.
  defp process_operation(operation) do
    case idempotency_key(operation) do
      {:ok, operation_id} ->
        case Operations.get_record(operation_id) do
          nil -> apply_and_remember(operation, operation_id)
          %Record{} = record -> replay_or_conflict(record, operation)
        end

      :error ->
        # Without a usable identifier the operation cannot be remembered and
        # is simply processed.
        operation |> dispatch() |> outcome_result()
    end
  end

  defp idempotency_key(%{"operation_id" => operation_id}) when is_binary(operation_id) do
    {:ok, operation_id}
  end

  defp idempotency_key(_operation), do: :error

  defp apply_and_remember(operation, operation_id) do
    {_outcome, result} = dispatch(operation)

    Operations.insert_record!(
      operation_id,
      operation_type(operation),
      operation,
      result
    )

    result
  end

  defp replay_or_conflict(record, operation) do
    if Operations.equivalent_payload?(record, operation) do
      Operations.stored_result(record)
    else
      %{
        operation_id: record.operation_id,
        status: "rejected",
        code: "operation_id_conflict"
      }
    end
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp outcome_result({_outcome, result}), do: result

  ## Dispatch and structural validation

  defp dispatch(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  defp dispatch(operation) do
    operation_id = operation["operation_id"]
    type = operation["type"]

    with :ok <- check_operation_id(operation_id),
         :ok <- check_type(type),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         :ok <- check_required_fields(operation, type),
         :ok <- check_refund_method(operation, type) do
      dispatch_typed(type, operation, occurred_on)
    else
      :error -> rejected(operation_id_if_string(operation_id), "invalid_operation")
    end
  end

  ## Operation types

  defp dispatch_typed("start_finance_reporting", operation, _occurred_on) do
    operation_id = operation["operation_id"]

    with {:ok, starts_on} <- fetch_starts_on(operation),
         :ok <- check_reporting_not_started() do
      Finance.start!(starts_on)

      applied(operation_id, %{starts_on: Date.to_iso8601(starts_on)})
    else
      {:rejected, code} -> rejected(operation_id, code)
    end
  end

  defp dispatch_typed("close_finance_period", operation, _occurred_on) do
    operation_id = operation["operation_id"]

    with {:ok, period_end_on} <- fetch_period_end_on(operation),
         :ok <- check_period_closeable(period_end_on) do
      Finance.close!(period_end_on)

      applied(operation_id, %{period_end_on: Date.to_iso8601(period_end_on)})
    else
      {:rejected, code} -> rejected(operation_id, code)
    end
  end

  defp dispatch_typed("open_group", operation, occurred_on) do
    operation_id = operation["operation_id"]

    with :ok <- check_group_absent(operation["group_id"]),
         {:ok, arrival_on, departure_on} <- fetch_stay(operation),
         {:ok, rooms} <- fetch_rooms(operation["rooms"]),
         :ok <- check_rate_plan(operation["rate_plan"]) do
      apply_open_group(operation, occurred_on, arrival_on, departure_on, rooms)
    else
      {:rejected, code} -> rejected(operation_id, code)
    end
  end

  defp dispatch_typed("record_cash_payment", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]
      amount = operation["amount_cents"]

      with :ok <- check_active(group),
           :ok <- check_amount(group, amount) do
        Groups.allocate_funding!(group, "cash", amount, payment_operation_id: operation_id)
        Payments.record_payment!(operation_id, amount)
        Ledger.record_cash_received!(group, amount, occurred_on)
        Finance.record_movement!("cash", group.property_id, "received", amount, occurred_on)
        group = Groups.refresh_group!(group)

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("apply_hotel_credit", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]
      amount = operation["amount_cents"]

      with :ok <- check_active(group),
           :ok <- check_amount(group, amount),
           :ok <- check_credit_available(group, amount, occurred_on) do
        Credits.apply_to_group!(group, amount, occurred_on)
        group = Groups.refresh_group!(group)

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("reschedule_group", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]

      with :ok <- check_active(group),
           {:ok, new_arrival_on} <- fetch_new_arrival(operation, occurred_on) do
        shift = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.shift(group.departure_on, day: shift)

        group =
          Groups.refresh_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on
          })

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: Date.to_iso8601(group.arrival_on),
          new_departure_on: Date.to_iso8601(group.departure_on),
          policy_version: group.policy_version,
          refundable_until: Groups.refundable_until_iso8601(group),
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("cancel_group", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]
      refund_method = Map.get(operation, "refund_method") || "cash"

      with :ok <- check_active(group),
           :ok <- check_refund_method_available(group, refund_method, occurred_on) do
        {refunded_cents, retained_cents, credit_issued_cents} =
          settle_rooms(
            group,
            Groups.active_rooms(group),
            operation_id,
            refund_method,
            occurred_on
          )

        group = Groups.refresh_group!(group, %{status: "cancelled"})

        applied(operation_id, %{
          group_id: group.group_id,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          credit_issued_cents: credit_issued_cents,
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("cancel_rooms", operation, occurred_on) do
    with_group(operation, fn group ->
      operation_id = operation["operation_id"]
      refund_method = Map.get(operation, "refund_method") || "cash"

      with :ok <- check_active(group),
           {:ok, rooms} <- fetch_active_rooms(group, operation["room_ids"]),
           :ok <- check_refund_method_available(group, refund_method, occurred_on) do
        {refunded_cents, retained_cents, credit_issued_cents} =
          settle_rooms(group, rooms, operation_id, refund_method, occurred_on)

        extra_attrs =
          if Groups.active_room_count(group) == 0, do: %{status: "cancelled"}, else: %{}

        group = Groups.refresh_group!(group, extra_attrs)

        applied(operation_id, %{
          group_id: group.group_id,
          cancelled_room_ids: Enum.map(rooms, & &1.room_id),
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          credit_issued_cents: credit_issued_cents,
          revision: group.revision
        })
      else
        {:rejected, code} -> rejected(operation_id, code)
      end
    end)
  end

  defp dispatch_typed("reduce_cash_payment", operation, occurred_on) do
    operation_id = operation["operation_id"]
    amount = operation["amount_cents"]

    with {:ok, record} <- fetch_payment_record(operation["payment_operation_id"]),
         :ok <- check_payment_applied(record, "payment_not_reducible"),
         {:ok, group} <- check_payment_revision(record, operation),
         :ok <- check_positive_amount(amount),
         :ok <- check_reducible(record, amount) do
      units =
        Groups.draw_allocations!(Groups.payment_cash_allocations(record.operation_id), amount)

      Payments.move!(record.operation_id, "held", "reduced", amount)

      touched =
        reclassify_held_units(units, "reduced", occurred_on)

      group = refresh_addressed_group(group, touched)

      applied(operation_id, %{
        payment_operation_id: record.operation_id,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
        revision: group.revision
      })
    else
      {:rejected, code} -> rejected(operation_id, code)
      {:rejected, code, fields} -> rejected(operation_id, code, fields)
    end
  end

  defp dispatch_typed("charge_back_payment", operation, occurred_on) do
    operation_id = operation["operation_id"]

    with {:ok, record} <- fetch_payment_record(operation["payment_operation_id"]),
         :ok <- check_payment_applied(record, "payment_not_chargeable"),
         {:ok, group} <- check_payment_revision(record, operation),
         :ok <- check_chargeable(record) do
      dispositions = Payments.dispositions(record.operation_id)
      held = Map.get(dispositions, "held", 0)

      # Remove held allocations, which may fund other groups after
      # transfers, reopening their outstanding deposits.
      touched =
        if held > 0 do
          record.operation_id
          |> Groups.payment_cash_allocations()
          |> Groups.draw_allocations!(held)
          |> reclassify_held_units("charged_back", occurred_on)
        else
          []
        end

      if held > 0 do
        Payments.move!(record.operation_id, "held", "charged_back", held)
      end

      # Move settled portions to charged-back cash: the ledger
      # classification changes, but the historical refund to the guest or
      # retention by the hotel is not reversed or reissued.
      settled =
        for kind <- ["refunded", "retained", "converted_to_credit"] do
          amount = Map.get(dispositions, kind, 0)

          if amount > 0 do
            Payments.move!(record.operation_id, kind, "charged_back", amount)
            reclassify_settled(record, group, kind, amount, occurred_on)
          end

          amount
        end

      record_revocation!(record, occurred_on)

      group = refresh_addressed_group(group, touched)

      applied(operation_id, %{
        payment_operation_id: record.operation_id,
        group_id: group.group_id,
        charged_back_cents: held + Enum.sum(settled),
        outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
        revision: group.revision
      })
    else
      {:rejected, code} -> rejected(operation_id, code)
      {:rejected, code, fields} -> rejected(operation_id, code, fields)
    end
  end

  defp dispatch_typed("transfer_deposit", operation, occurred_on) do
    operation_id = operation["operation_id"]
    amount = operation["amount_cents"]

    with {:ok, source} <- fetch_transfer_group(operation["source_group_id"]),
         {:ok, destination} <- fetch_transfer_group(operation["destination_group_id"]),
         :ok <- check_transfer_revision(source, operation, "expected_revision"),
         :ok <- check_transfer_revision(destination, operation, "destination_expected_revision"),
         :ok <- check_transferable(source, destination),
         :ok <- check_transfer_active(source),
         :ok <- check_transfer_active(destination),
         :ok <- check_positive_amount(amount),
         :ok <- check_transfer_held(source, amount),
         :ok <- check_transfer_outstanding(destination, amount) do
      # Draw the source's held funding most recently created first,
      # regardless of funding kind, and fill the destination's rooms in
      # their original order. Each moved allocation keeps its provenance.
      units = Groups.draw_allocations!(Groups.held_allocations(source, :desc), amount)

      for unit <- units do
        Groups.allocate_funding!(destination, unit.kind, unit.amount_cents,
          payment_operation_id: unit.payment_operation_id,
          credit_lot_id: unit.credit_lot_id,
          transferred: true
        )
      end

      units
      |> Enum.filter(&(&1.kind == "cash" and not is_nil(&1.payment_operation_id)))
      |> Enum.map(& &1.payment_operation_id)
      |> Enum.uniq()
      |> Payments.mark_transferred!()

      # Transfers change no ledger total: only which property holds the cash
      # moves in the report.
      cash_moved =
        units
        |> Enum.filter(&(&1.kind == "cash"))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum()

      Finance.record_movement!(
        "cash",
        source.property_id,
        "transferred_out",
        cash_moved,
        occurred_on
      )

      Finance.record_movement!(
        "cash",
        destination.property_id,
        "transferred_in",
        cash_moved,
        occurred_on
      )

      source = Groups.refresh_group!(source)
      destination = Groups.refresh_group!(destination)

      applied(operation_id, %{
        source_group_id: source.group_id,
        destination_group_id: destination.group_id,
        amount_cents: amount,
        source_outstanding_deposit_cents: Groups.outstanding_deposit_cents(source),
        destination_outstanding_deposit_cents: Groups.outstanding_deposit_cents(destination),
        source_revision: source.revision,
        destination_revision: destination.revision
      })
    else
      {:rejected, code} -> rejected(operation_id, code)
      {:rejected, code, fields} -> rejected(operation_id, code, fields)
    end
  end

  ## Cancellation settlement

  # Settles the given rooms of a group: their allocated cash and credit
  # using the group's date, policy, and the requested refund method, and
  # their unpaid deposit ceasing to be due. On a refundable cancellation
  # cash is refunded or, when hotel credit is selected, converted to a
  # credit lot worth 110% of the cash (the bonus is computed once on the
  # combined cash amount); previously applied credit returns to its original
  # lots and expiries without a second bonus. On a non-refundable
  # cancellation cash is retained and applied credit is consumed.
  defp settle_rooms(%Group{} = group, rooms, operation_id, refund_method, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      group
      |> Groups.held_allocations()
      |> Enum.filter(&(&1.room_id in room_ids))

    cash =
      allocations
      |> Enum.filter(&(&1.kind == "cash"))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

    consumed_credit =
      allocations
      |> Enum.filter(&(&1.kind == "credit"))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

    {refunded_cents, retained_cents, credit_issued_cents} =
      case {Groups.refundable?(group, occurred_on), refund_method} do
        {true, "hotel_credit"} ->
          credit_issued = cash + Groups.round_half_up(cash * 10, 100)

          Ledger.record_cash_converted_to_credit!(group, cash, occurred_on)

          Finance.record_movement!(
            "cash",
            group.property_id,
            "converted_to_credit",
            cash,
            occurred_on
          )

          Finance.record_movement!("credit", nil, "issued", credit_issued, occurred_on)
          funding = Payments.settle_allocations!(allocations, "converted_to_credit")
          Payments.record_settlements!(allocations, "converted_to_credit")

          if lot =
               Credits.issue_lot!(
                 group.guest_id,
                 operation_id,
                 credit_issued,
                 Date.shift(occurred_on, day: @credit_available_days + 1)
               ) do
            Credits.record_entitlements!(lot, funding)
          end

          restore_credit_allocations(allocations, occurred_on)

          {0, 0, credit_issued}

        {true, "cash"} ->
          Ledger.record_cash_refunded!(group, cash, occurred_on)
          Finance.record_movement!("cash", group.property_id, "refunded", cash, occurred_on)
          Payments.settle_allocations!(allocations, "refunded")
          Payments.record_settlements!(allocations, "refunded")
          restore_credit_allocations(allocations, occurred_on)

          {cash, 0, 0}

        {false, "cash"} ->
          Ledger.record_cash_retained!(group, cash, occurred_on)
          Finance.record_movement!("cash", group.property_id, "retained", cash, occurred_on)
          Finance.record_movement!("credit", nil, "consumed", consumed_credit, occurred_on)
          Payments.settle_allocations!(allocations, "retained")
          Payments.record_settlements!(allocations, "retained")

          {0, cash, 0}
      end

    Groups.settle_rooms!(rooms)

    {refunded_cents, retained_cents, credit_issued_cents}
  end

  # Applied credit returns to its original lots with its original expiry and
  # never receives a second bonus. Liability leaving through shortfall
  # absorption or immediate expiry is reported.
  defp restore_credit_allocations(allocations, occurred_on) do
    for %Allocation{kind: "credit"} = allocation <- allocations do
      %{absorbed: absorbed, expired: expired} =
        Credits.restore_allocation!(allocation, occurred_on)

      Finance.record_movement!("credit", nil, "absorbed", absorbed, occurred_on)
      Finance.record_movement!("credit", nil, "expired", expired, occurred_on)
    end

    :ok
  end

  ## Payment correction helpers

  # Reclassifies the held cash of drawn units on the ledger of each group
  # holding them and refreshes every touched group; returns `{group, amount}`
  # pairs of the refreshed groups. Groups other than the addressed one are not
  # revision-guarded, but their revisions still increment because their
  # funding changed. The report movement of the given classification is
  # recorded per holding group, so corrections follow the cash to the
  # property where it is held.
  defp reclassify_held_units(units, classification, occurred_on) do
    ledger_kind = "cash_" <> classification

    units
    |> Enum.group_by(& &1.group_id, & &1.amount_cents)
    |> Enum.sort_by(fn {group_db_id, _amounts} -> group_db_id end)
    |> Enum.map(fn {group_db_id, amounts} ->
      group = Groups.get_group_by_id!(group_db_id)
      amount = Enum.sum(amounts)

      Ledger.reclassify_held_cash!(group, ledger_kind, amount, occurred_on)

      Finance.record_movement!(
        "cash",
        group.property_id,
        classification,
        amount,
        occurred_on
      )

      {Groups.refresh_group!(group), amount}
    end)
  end

  # The addressed original payment group always increments its revision
  # exactly once, even when none of its own funding changed.
  defp refresh_addressed_group(group, touched) do
    case Enum.find(touched, fn {%Group{} = touched_group, _amount} ->
           touched_group.id == group.id
         end) do
      nil -> Groups.refresh_group!(group)
      {%Group{} = refreshed, _amount} -> refreshed
    end
  end

  defp fetch_payment_record(payment_operation_id) do
    case Operations.get_record(payment_operation_id) do
      nil -> {:rejected, "operation_not_found"}
      %Record{} = record -> {:ok, record}
    end
  end

  defp check_payment_applied(record, code) do
    if Payments.applied_cash_payment?(record), do: :ok, else: {:rejected, code}
  end

  # Reclassifies settled cash of one kind against the groups that settled it:
  # the correction follows the affected cash to the property where it was
  # settled rather than the payment's original property. Settlements recorded
  # before attributions existed fall back to the original payment group.
  defp reclassify_settled(record, group, kind, amount, occurred_on) do
    ledger_kind = "cash_" <> kind

    case Payments.settled_attributions(record.operation_id, kind) do
      [] ->
        Ledger.reclassify_cash!(group, ledger_kind, "cash_charged_back", amount, occurred_on)

        Finance.record_movement!("cash", group.property_id, kind, -amount, occurred_on)
        Finance.record_movement!("cash", group.property_id, "charged_back", amount, occurred_on)

      attributions ->
        for {group_db_id, settled_amount} <- attributions do
          settled_group = Groups.get_group_by_id!(group_db_id)

          Ledger.reclassify_cash!(
            settled_group,
            ledger_kind,
            "cash_charged_back",
            settled_amount,
            occurred_on
          )

          Finance.record_movement!(
            "cash",
            settled_group.property_id,
            kind,
            -settled_amount,
            occurred_on
          )

          Finance.record_movement!(
            "cash",
            settled_group.property_id,
            "charged_back",
            settled_amount,
            occurred_on
          )
        end
    end

    Payments.clear_settlements!(record.operation_id, kind)

    :ok
  end

  # Revokes the payment's credit entitlements and records the liability
  # movement for the entitlement removed from still-available lots. Removal
  # from an already expired lot only refines that lot's derived expiry and
  # records no movement.
  defp record_revocation!(record, occurred_on) do
    details = Credits.revoke_entitlements!(record.operation_id)
    posting = Finance.posting_on(occurred_on)

    revoked =
      Enum.reduce(details, 0, fn {expires_on, removed}, sum ->
        if Date.compare(expires_on, posting) == :gt, do: sum + removed, else: sum
      end)

    Finance.record_movement!("credit", nil, "revoked", revoked, occurred_on)
  end

  # The addressed group is the original payment's group for revision
  # checking.
  defp check_payment_revision(record, operation) do
    group = Payments.payment_group(record)

    case Map.get(operation, "expected_revision") do
      nil ->
        {:ok, group}

      expected when expected == group.revision ->
        {:ok, group}

      expected ->
        {:rejected, "stale_revision",
         %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}
    end
  end

  defp check_reducible(record, amount) do
    held = Payments.held_cents(record.operation_id)

    cond do
      held == 0 -> {:rejected, "payment_not_reducible"}
      amount > held -> {:rejected, "reduction_exceeds_held_cash"}
      true -> :ok
    end
  end

  # A payment can be charged back while any portion of it has not already
  # been reduced or charged back.
  defp check_chargeable(record) do
    reversible =
      record.operation_id
      |> Payments.dispositions()
      |> Map.take(~w(held refunded retained converted_to_credit))
      |> Map.values()
      |> Enum.sum()

    if reversible > 0, do: :ok, else: {:rejected, "payment_not_chargeable"}
  end

  ## Transfer helpers

  defp fetch_transfer_group(group_id) do
    case Groups.get_group(group_id) do
      nil -> {:rejected, "group_not_found", %{group_id: group_id}}
      %Group{} = group -> {:ok, group}
    end
  end

  defp check_transfer_revision(group, operation, field) do
    case Map.get(operation, field) do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:rejected, "stale_revision",
         %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}
    end
  end

  defp check_transferable(%Group{} = source, %Group{} = destination) do
    if source.id == destination.id or source.guest_id != destination.guest_id do
      {:rejected, "invalid_transfer"}
    else
      :ok
    end
  end

  defp check_transfer_active(%Group{status: "active"}), do: :ok

  defp check_transfer_active(%Group{} = group) do
    {:rejected, "group_not_active", %{group_id: group.group_id}}
  end

  defp check_transfer_held(%Group{} = source, amount) do
    if Groups.held_funding_cents(source) >= amount do
      :ok
    else
      {:rejected, "transfer_exceeds_held_funding"}
    end
  end

  defp check_transfer_outstanding(%Group{} = destination, amount) do
    if Groups.outstanding_deposit_cents(destination) >= amount do
      :ok
    else
      {:rejected, "transfer_exceeds_outstanding"}
    end
  end

  ## Structural validation helpers

  defp check_operation_id(operation_id) when is_binary(operation_id), do: :ok
  defp check_operation_id(_operation_id), do: :error

  defp check_type(type) when type in @operation_types, do: :ok
  defp check_type(_type), do: :error

  defp fetch_occurred_on(operation) do
    case operation["occurred_on"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> :error
        end

      _other ->
        :error
    end
  end

  defp check_required_fields(operation, type) do
    string_fields = Map.fetch!(@required_string_fields, type)
    present_fields = Map.fetch!(@required_present_fields, type)

    strings_ok? = Enum.all?(string_fields, &is_binary(operation[&1]))
    present_ok? = Enum.all?(present_fields, &(not is_nil(operation[&1])))

    if strings_ok? and present_ok?, do: :ok, else: :error
  end

  # `refund_method` is optional on cancellation operations; when present it
  # must be one of the supported methods.
  defp check_refund_method(operation, type) when type in ["cancel_group", "cancel_rooms"] do
    case Map.get(operation, "refund_method") do
      nil -> :ok
      method when method in @refund_methods -> :ok
      _other -> :error
    end
  end

  defp check_refund_method(_operation, _type), do: :ok

  defp operation_id_if_string(operation_id) when is_binary(operation_id), do: operation_id
  defp operation_id_if_string(_operation_id), do: nil

  ## Domain validation helpers

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(%Group{}), do: {:rejected, "group_not_active"}

  defp check_amount(_group, amount) when not is_integer(amount) or amount <= 0 do
    {:rejected, "invalid_amount"}
  end

  defp check_amount(%Group{} = group, amount) do
    if amount > Groups.outstanding_deposit_cents(group) do
      {:rejected, "payment_exceeds_outstanding"}
    else
      :ok
    end
  end

  defp check_positive_amount(amount) when not is_integer(amount) or amount <= 0 do
    {:rejected, "invalid_amount"}
  end

  defp check_positive_amount(_amount), do: :ok

  defp check_credit_available(%Group{} = group, amount, %Date{} = occurred_on) do
    if Credits.available_cents(group.guest_id, occurred_on) >= amount do
      :ok
    else
      {:rejected, "insufficient_credit"}
    end
  end

  # Hotel credit is not a way around a non-refundable policy.
  defp check_refund_method_available(%Group{} = group, "hotel_credit", %Date{} = occurred_on) do
    if Groups.refundable?(group, occurred_on) do
      :ok
    else
      {:rejected, "refund_method_not_available"}
    end
  end

  defp check_refund_method_available(%Group{}, _refund_method, %Date{}), do: :ok

  defp fetch_new_arrival(operation, occurred_on) do
    case parse_date(operation["new_arrival_on"]) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:rejected, "invalid_stay"}
        end

      {:error, _} ->
        {:rejected, "invalid_stay"}
    end
  end

  defp check_group_absent(group_id) do
    case Groups.get_group(group_id) do
      nil -> :ok
      %Group{} -> {:rejected, "group_already_exists"}
    end
  end

  defp fetch_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- check_nights(arrival_on, departure_on) do
      {:ok, arrival_on, departure_on}
    else
      _other -> {:rejected, "invalid_stay"}
    end
  end

  defp check_nights(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: :error
  end

  defp fetch_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:rejected, "invalid_rooms"}
    end
  end

  defp fetch_rooms(_rooms), do: {:rejected, "invalid_rooms"}

  defp valid_room?(room) when is_map(room) do
    is_binary(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] > 0
  end

  defp valid_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1["room_id"])
    length(Enum.uniq(room_ids)) == length(room_ids)
  end

  # All supplied room identifiers must identify distinct, active rooms in
  # the group; the selected rooms are returned in the group's original room
  # order.
  defp fetch_active_rooms(%Group{} = group, room_ids) when is_list(room_ids) and room_ids != [] do
    active = Groups.active_rooms(group)
    active_room_ids = MapSet.new(Enum.map(active, & &1.room_id))

    distinct? = length(Enum.uniq(room_ids)) == length(room_ids)
    all_active? = Enum.all?(room_ids, &MapSet.member?(active_room_ids, &1))

    if distinct? and all_active? do
      {:ok, Enum.filter(active, &(&1.room_id in room_ids))}
    else
      {:rejected, "invalid_rooms"}
    end
  end

  defp fetch_active_rooms(_group, _room_ids), do: {:rejected, "invalid_rooms"}

  defp check_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"], do: :ok
  defp check_rate_plan(_rate_plan), do: {:rejected, "invalid_rate_plan"}

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_format}

  ## Finance reporting helpers

  # The only payload of a start operation; a missing or unusable date is
  # rejected as `invalid_reporting_date` rather than `invalid_operation`.
  defp fetch_starts_on(operation) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} -> {:ok, starts_on}
      {:error, _} -> {:rejected, "invalid_reporting_date"}
    end
  end

  defp check_reporting_not_started do
    if Finance.started?(), do: {:rejected, "reporting_already_started"}, else: :ok
  end

  # The only payload of a close operation; a missing or unusable date, a
  # cutoff before reporting started or before `starts_on`, or one not
  # strictly later than the latest successful close is `invalid_period`.
  defp fetch_period_end_on(operation) do
    case parse_date(operation["period_end_on"]) do
      {:ok, period_end_on} -> {:ok, period_end_on}
      {:error, _} -> {:rejected, "invalid_period"}
    end
  end

  defp check_period_closeable(%Date{} = period_end_on) do
    if Finance.closeable?(period_end_on), do: :ok, else: {:rejected, "invalid_period"}
  end

  ## Application helpers

  defp apply_open_group(operation, occurred_on, arrival_on, departure_on, rooms) do
    nights = Date.diff(departure_on, arrival_on)
    totals = Groups.totals(operation["rate_plan"], rooms, nights)
    rate_plan = operation["rate_plan"]

    rooms_with_position =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        room
        |> Map.put(:position, position)
        |> Map.put(
          :deposit_due_cents,
          Groups.room_deposit_cents(rate_plan, room.nightly_rate_cents * nights)
        )
      end)

    attrs = %{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: occurred_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      policy_version: Groups.policy_version(rate_plan, occurred_on),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      rooms: rooms_with_position
    }

    {:ok, group} =
      Group.open_changeset(attrs)
      |> Repo.insert()

    applied(operation["operation_id"], %{
      group_id: group.group_id,
      deposit_due_cents: group.deposit_due_cents,
      revision: group.revision
    })
  end

  # Resolves the addressed group, then checks the optional expected revision.
  # Existence is resolved first; a stale revision is rejected before any other
  # domain validation.
  defp with_group(operation, fun) do
    operation_id = operation["operation_id"]

    case Groups.get_group(operation["group_id"]) do
      nil ->
        rejected(operation_id, "group_not_found")

      %Group{} = group ->
        case Map.get(operation, "expected_revision") do
          nil ->
            fun.(group)

          expected_revision ->
            if expected_revision == group.revision do
              fun.(group)
            else
              rejected(operation_id, "stale_revision", %{
                group_id: group.group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              })
            end
        end
    end
  end

  defp applied(operation_id, fields) do
    {:applied, Map.merge(%{operation_id: operation_id, status: "applied"}, fields)}
  end

  defp rejected(operation_id, code, fields \\ %{}) do
    {:rejected, Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)}
  end
end
