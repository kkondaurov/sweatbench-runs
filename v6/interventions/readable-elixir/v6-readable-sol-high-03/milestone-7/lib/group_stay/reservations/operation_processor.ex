defmodule GroupStay.Reservations.OperationProcessor do
  @moduledoc """
  Validates and applies one partner operation.

  Every operation with a usable identifier is processed and durably receipted
  in one serialized transaction. Replays return the stored result without
  consulting domain state. Revision checks happen after resolving the target
  group and before state-dependent domain rules.
  """

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CancellationPolicy,
    CashFunding,
    Credit,
    DepositTransfer,
    FinanceReporting,
    Group,
    PartnerOperation,
    Room,
    RoomAccounting
  }

  @rate_plans ~w(flexible advance_purchase)

  def process(operation) do
    # SQLite's immediate transaction reserves the writer before reading. That
    # makes receipt lookup, domain changes, and receipt insertion one serialized
    # unit, including across separate application processes.
    {:ok, result} =
      Repo.transaction(fn -> process_in_transaction(operation) end, mode: :immediate)

    result
  rescue
    # The immediate transaction normally prevents a stale write. If another
    # database client bypasses that convention, retry from a new transaction so
    # expected-revision semantics are evaluated against the committed winner.
    Ecto.StaleEntryError -> process(operation)
  end

  defp process_in_transaction(operation) do
    with {:ok, operation_id} <- durable_operation_id(operation) do
      case Repo.get_by(PartnerOperation, operation_id: operation_id) do
        nil -> apply_and_remember(operation)
        receipt -> replay_or_reject_conflict(receipt, operation)
      end
    else
      :error -> operation |> apply_operation() |> json_value()
    end
  end

  defp apply_and_remember(operation) do
    submitted_payload = json_value(operation)
    finance_before = FinanceReporting.capture()
    result = operation |> apply_operation() |> json_value()
    :ok = FinanceReporting.record(operation, result, finance_before)

    %PartnerOperation{}
    |> PartnerOperation.creation_changeset(%{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submitted_payload: submitted_payload,
      result: result
    })
    |> Repo.insert!()

    result
  end

  defp replay_or_reject_conflict(receipt, operation) do
    if receipt.submitted_payload === json_value(operation) do
      receipt.result
    else
      rejected_result(operation, "operation_id_conflict")
    end
  end

  defp durable_operation_id(%{"operation_id" => operation_id})
       when is_binary(operation_id) do
    if String.trim(operation_id) == "", do: :error, else: {:ok, operation_id}
  end

  defp durable_operation_id(_operation), do: :error

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  # A JSON round trip gives object-order-independent comparison and ensures the
  # first response has precisely the same representation as later replays.
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp apply_operation(%{"type" => "close_finance_period"} = operation),
    do: close_finance_period(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: reschedule_group(operation)

  defp apply_operation(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp apply_operation(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp apply_operation(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp apply_operation(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp apply_operation(operation), do: reject(operation, "invalid_operation")

  defp start_finance_reporting(operation) do
    with :ok <- require_fields(operation, ~w(operation_id starts_on)),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id)),
         {:ok, starts_on} <- date(operation["starts_on"]),
         :ok <- FinanceReporting.start(starts_on) do
      applied(operation, %{"starts_on" => starts_on})
    else
      {:error, :missing_data} -> reject(operation, "invalid_reporting_date")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_reporting_date")
      {:error, :reporting_already_started} -> reject(operation, "reporting_already_started")
    end
  end

  defp close_finance_period(operation) do
    with :ok <- require_fields(operation, ~w(operation_id period_end_on)),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id)),
         {:ok, period_end_on} <- date(operation["period_end_on"]),
         :ok <- FinanceReporting.close(period_end_on) do
      applied(operation, %{"period_end_on" => period_end_on})
    else
      {:error, :invalid_identifier} ->
        reject(operation, "invalid_operation")

      {:error, reason} when reason in [:missing_data, :invalid_date, :invalid_period] ->
        reject(operation, "invalid_period")
    end
  end

  defp open_group(operation) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with :ok <- require_fields(operation, required),
         :ok <-
           validate_partner_identifiers(operation, ~w(operation_id group_id guest_id property_id)),
         {:ok, booked_on} <- date(operation["occurred_on"]),
         {:ok, arrival_on} <- date(operation["arrival_on"]),
         {:ok, departure_on} <- date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         {:ok, group} <- insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
      applied(operation, %{
        "group_id" => group.group_id,
        "deposit_due_cents" => group.deposit_due_cents,
        "revision" => group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_stay")
      {:error, :invalid_stay} -> reject(operation, "invalid_stay")
      {:error, :invalid_rate_plan} -> reject(operation, "invalid_rate_plan")
      {:error, :invalid_rooms} -> reject(operation, "invalid_rooms")
      {:error, :group_already_exists} -> reject(operation, "group_already_exists")
    end
  end

  defp record_cash_payment(operation) do
    required = ~w(operation_id occurred_on group_id amount_cents)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, _occurred_on} <- date(operation["occurred_on"]),
         :ok <- active(group),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- within_outstanding(operation["amount_cents"], group),
         _funding <-
           RoomAccounting.fund_cash(
             group,
             operation["operation_id"],
             operation["amount_cents"],
             next_commit_order()
           ),
         {:ok, updated_group} <-
           update_group_from_rooms(group) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "amount_cents" => operation["amount_cents"],
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_amount} -> reject(operation, "invalid_amount")
      {:error, :payment_exceeds_outstanding} -> reject(operation, "payment_exceeds_outstanding")
    end
  end

  defp apply_hotel_credit(operation) do
    required = ~w(operation_id occurred_on group_id amount_cents)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, occurred_on} <- date(operation["occurred_on"]),
         :ok <- active(group),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- within_outstanding(operation["amount_cents"], group),
         :ok <-
           Credit.apply(
             group,
             operation["amount_cents"],
             occurred_on,
             operation["operation_id"]
           ),
         {:ok, updated_group} <-
           update_group_from_rooms(group) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "amount_cents" => operation["amount_cents"],
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_amount} -> reject(operation, "invalid_amount")
      {:error, :payment_exceeds_outstanding} -> reject(operation, "payment_exceeds_outstanding")
      {:error, :insufficient_credit} -> reject(operation, "insufficient_credit")
    end
  end

  defp reschedule_group(operation) do
    required = ~w(operation_id occurred_on group_id new_arrival_on)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, occurred_on} <- date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- date(operation["new_arrival_on"]),
         :ok <- active(group),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on),
         shift = Date.diff(new_arrival_on, group.arrival_on),
         new_departure_on = Date.add(group.departure_on, shift),
         {:ok, updated_group} <-
           update_group(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on}) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "new_arrival_on" => updated_group.arrival_on,
        "new_departure_on" => updated_group.departure_on,
        "policy_version" => updated_group.policy_version,
        "refundable_until" => CancellationPolicy.refundable_until(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_stay")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_stay} -> reject(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation) do
    required = ~w(operation_id occurred_on group_id)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, occurred_on} <- date(operation["occurred_on"]),
         :ok <- active(group),
         {:ok, refund_method} <- refund_method(operation),
         refundable = CancellationPolicy.refundable?(group, occurred_on),
         :ok <- refund_method_available(refund_method, refundable),
         rooms = RoomAccounting.active_rooms(group.group_id),
         settlement =
           settle_rooms(group, rooms, operation, occurred_on, refund_method, refundable),
         {:ok, updated_group} <-
           update_group_after_settlement(group, settlement) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_identifier} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_found} ->
        reject(operation, "group_not_found")

      {:error, :stale_revision, group} ->
        reject_stale(operation, group)

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_refund_method} ->
        reject(operation, "invalid_operation")

      {:error, :refund_method_not_available} ->
        reject(operation, "refund_method_not_available")
    end
  end

  defp cancel_rooms(operation) do
    required = ~w(operation_id occurred_on group_id room_ids)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id group_id)),
         {:ok, group} <- load_group(operation),
         :ok <- compare_revision(operation, group),
         {:ok, occurred_on} <- date(operation["occurred_on"]),
         :ok <- active(group),
         {:ok, rooms} <- selected_active_rooms(group, operation["room_ids"]),
         {:ok, refund_method} <- refund_method(operation),
         refundable = CancellationPolicy.refundable?(group, occurred_on),
         :ok <- refund_method_available(refund_method, refundable),
         settlement =
           settle_rooms(group, rooms, operation, occurred_on, refund_method, refundable),
         {:ok, updated_group} <- update_group_after_settlement(group, settlement) do
      applied(operation, %{
        "group_id" => updated_group.group_id,
        "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_rooms} -> reject(operation, "invalid_rooms")
      {:error, :invalid_refund_method} -> reject(operation, "invalid_operation")
      {:error, :refund_method_not_available} -> reject(operation, "refund_method_not_available")
    end
  end

  defp reduce_cash_payment(operation) do
    required = ~w(operation_id occurred_on payment_operation_id amount_cents)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id payment_operation_id)),
         {:ok, funding} <- load_payment_funding(operation, :payment_not_reducible),
         {:ok, group} <- load_funding_group(funding),
         :ok <- compare_revision(operation, group),
         {:ok, _occurred_on} <- date(operation["occurred_on"]),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- reducible(funding),
         :ok <- within_held_cash(operation["amount_cents"], funding),
         changed_group_ids <- RoomAccounting.reduce_cash(funding, operation["amount_cents"]),
         {:ok, updated_group} <- update_changed_groups(group, changed_group_ids) do
      applied(operation, %{
        "payment_operation_id" => funding.payment_operation_id,
        "group_id" => updated_group.group_id,
        "amount_cents" => operation["amount_cents"],
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :operation_not_found} -> reject(operation, "operation_not_found")
      {:error, :payment_not_reducible} -> reject(operation, "payment_not_reducible")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :invalid_amount} -> reject(operation, "invalid_amount")
      {:error, :reduction_exceeds_held_cash} -> reject(operation, "reduction_exceeds_held_cash")
    end
  end

  defp charge_back_payment(operation) do
    required = ~w(operation_id occurred_on payment_operation_id)

    with :ok <- require_fields(operation, required),
         :ok <- validate_partner_identifiers(operation, ~w(operation_id payment_operation_id)),
         {:ok, funding} <- load_payment_funding(operation, :payment_not_chargeable),
         {:ok, group} <- load_funding_group(funding),
         :ok <- compare_revision(operation, group),
         {:ok, _occurred_on} <- date(operation["occurred_on"]),
         :ok <- chargeable(funding),
         :ok <- Credit.revoke_entitlements(funding.id),
         {charged_back_cents, changed_group_ids} = RoomAccounting.charge_back_cash(funding),
         {:ok, updated_group} <-
           update_changed_groups(group, changed_group_ids, %{
             cash_refunded_cents: max(group.cash_refunded_cents - funding.refunded_cents, 0),
             cash_retained_cents: max(group.cash_retained_cents - funding.retained_cents, 0),
             cash_converted_to_credit_cents:
               max(
                 group.cash_converted_to_credit_cents - funding.converted_to_credit_cents,
                 0
               )
           }) do
      applied(operation, %{
        "payment_operation_id" => funding.payment_operation_id,
        "group_id" => updated_group.group_id,
        "charged_back_cents" => charged_back_cents,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :invalid_identifier} -> reject(operation, "invalid_operation")
      {:error, :operation_not_found} -> reject(operation, "operation_not_found")
      {:error, :payment_not_chargeable} -> reject(operation, "payment_not_chargeable")
      {:error, :group_not_found} -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> reject_stale(operation, group)
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
    end
  end

  defp transfer_deposit(operation) do
    required =
      ~w(operation_id occurred_on source_group_id destination_group_id amount_cents)

    with :ok <- require_fields(operation, required),
         :ok <-
           validate_partner_identifiers(
             operation,
             ~w(operation_id source_group_id destination_group_id)
           ),
         {:ok, source} <- load_named_group(operation, "source_group_id"),
         {:ok, destination} <- load_named_group(operation, "destination_group_id"),
         :ok <- compare_revision(operation, source),
         :ok <-
           compare_revision(
             operation,
             destination,
             "destination_expected_revision"
           ),
         {:ok, _occurred_on} <- date(operation["occurred_on"]),
         :ok <- valid_transfer_pair(source, destination),
         :ok <- active_transfer_group(source),
         :ok <- active_transfer_group(destination),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- within_held_funding(operation["amount_cents"], source),
         :ok <- within_transfer_outstanding(operation["amount_cents"], destination),
         :ok <- DepositTransfer.move(source, destination, operation["amount_cents"]),
         {:ok, updated_source} <- update_group_from_rooms(source),
         {:ok, updated_destination} <- update_group_from_rooms(destination) do
      applied(operation, %{
        "source_group_id" => updated_source.group_id,
        "destination_group_id" => updated_destination.group_id,
        "amount_cents" => operation["amount_cents"],
        "source_outstanding_deposit_cents" => outstanding_deposit(updated_source),
        "destination_outstanding_deposit_cents" => outstanding_deposit(updated_destination),
        "source_revision" => updated_source.revision,
        "destination_revision" => updated_destination.revision
      })
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_identifier} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_found, group_id} ->
        reject_group(operation, "group_not_found", group_id)

      {:error, :stale_revision, group} ->
        reject_stale(operation, group)

      {:error, :stale_revision, group, revision_field} ->
        reject_stale(operation, group, revision_field)

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_transfer} ->
        reject(operation, "invalid_transfer")

      {:error, :group_not_active, group_id} ->
        reject_group(operation, "group_not_active", group_id)

      {:error, :invalid_amount} ->
        reject(operation, "invalid_amount")

      {:error, :transfer_exceeds_held_funding} ->
        reject(operation, "transfer_exceeds_held_funding")

      {:error, :transfer_exceeds_outstanding} ->
        reject(operation, "transfer_exceeds_outstanding")
    end
  end

  defp insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
    nights = Date.diff(departure_on, arrival_on)
    lodging_total = Enum.sum_by(rooms, &(&1.nightly_rate_cents * nights))
    deposit_due = deposit_due(operation["rate_plan"], rooms, nights)

    attributes = %{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      policy_version: CancellationPolicy.version(operation["rate_plan"], booked_on),
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    }

    case Repo.insert(Group.creation_changeset(%Group{}, attributes)) do
      {:ok, group} ->
        case insert_rooms(Repo, group, rooms) do
          {:ok, _rooms} -> {:ok, group}
          {:error, reason} -> raise "validated rooms could not be inserted: #{inspect(reason)}"
        end

      {:error, changeset} ->
        classify_group_insert(changeset)
    end
  end

  defp insert_rooms(repo, group, rooms) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, inserted} ->
      lodging_total_cents = room.nightly_rate_cents * nights

      changeset =
        Room.changeset(%Room{}, %{
          group_id: group.group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: room_deposit_due(group.rate_plan, lodging_total_cents)
        })

      case repo.insert(changeset) do
        {:ok, inserted_room} -> {:cont, {:ok, [inserted_room | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp classify_group_insert(changeset) do
    if Keyword.has_key?(changeset.errors, :group_id) do
      {:error, :group_already_exists}
    else
      raise "validated group could not be inserted: #{inspect(changeset.errors)}"
    end
  end

  defp load_group(operation) do
    case Repo.get(Group, operation["group_id"]) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp load_named_group(operation, field) do
    group_id = operation[field]

    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found, group_id}
      group -> {:ok, group}
    end
  end

  defp update_group(group, attributes) do
    group
    |> Group.operation_changeset(attributes)
    |> Repo.update()
  end

  defp update_group_from_rooms(group, additional_attributes \\ %{}) do
    attributes =
      group.group_id
      |> RoomAccounting.group_attributes()
      |> Map.merge(additional_attributes)

    update_group(group, attributes)
  end

  defp update_changed_groups(original_group, changed_group_ids, original_attributes \\ %{}) do
    group_ids =
      changed_group_ids
      |> MapSet.put(original_group.group_id)
      |> Enum.sort()

    updated_groups =
      Enum.map(group_ids, fn group_id ->
        group =
          if group_id == original_group.group_id,
            do: original_group,
            else: Repo.get!(Group, group_id)

        attributes = if group_id == original_group.group_id, do: original_attributes, else: %{}
        {:ok, updated_group} = update_group_from_rooms(group, attributes)
        updated_group
      end)

    {:ok, Enum.find(updated_groups, &(&1.group_id == original_group.group_id))}
  end

  defp update_group_after_settlement(group, settlement) do
    update_group_from_rooms(group, %{
      cash_refunded_cents: group.cash_refunded_cents + settlement.refunded_cents,
      cash_retained_cents: group.cash_retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.converted_cents
    })
  end

  defp compare_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, revision} when revision == group.revision -> :ok
      {:ok, _revision} -> {:error, :stale_revision, group}
    end
  end

  defp compare_revision(operation, group, revision_field) do
    case Map.fetch(operation, revision_field) do
      :error -> :ok
      {:ok, revision} when revision == group.revision -> :ok
      {:ok, _revision} -> {:error, :stale_revision, group, revision_field}
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp active_transfer_group(%Group{status: "active"}), do: :ok

  defp active_transfer_group(%Group{group_id: group_id}),
    do: {:error, :group_not_active, group_id}

  defp valid_transfer_pair(source, destination) do
    if source.group_id != destination.group_id and source.guest_id == destination.guest_id,
      do: :ok,
      else: {:error, :invalid_transfer}
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    with true <- Enum.all?(rooms, &valid_room?/1),
         room_ids = Enum.map(rooms, & &1["room_id"]),
         true <- length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      _ -> {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate}) do
    nonempty_string?(room_id) and is_integer(rate) and rate > 0
  end

  defp valid_room?(_room), do: false

  defp selected_active_rooms(group, room_ids) when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &nonempty_string?/1) and
         length(room_ids) == length(Enum.uniq(room_ids)) do
      requested = MapSet.new(room_ids)

      rooms =
        group.group_id
        |> RoomAccounting.active_rooms()
        |> Enum.filter(&MapSet.member?(requested, &1.room_id))

      if length(rooms) == length(room_ids),
        do: {:ok, rooms},
        else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp selected_active_rooms(_group, _room_ids), do: {:error, :invalid_rooms}

  defp valid_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_amount(_amount), do: {:error, :invalid_amount}

  defp within_outstanding(amount, group) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, :payment_exceeds_outstanding}
  end

  defp within_held_funding(amount, group) do
    if amount <= group.deposit_paid_cents,
      do: :ok,
      else: {:error, :transfer_exceeds_held_funding}
  end

  defp within_transfer_outstanding(amount, group) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, :transfer_exceeds_outstanding}
  end

  defp outstanding_deposit(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding_deposit(_group), do: 0

  defp deposit_due("advance_purchase", rooms, nights) do
    Enum.sum_by(rooms, &(&1.nightly_rate_cents * nights))
  end

  defp deposit_due("flexible", rooms, nights) do
    # Add half of the denominator before integer division: exact half-cents
    # therefore round upward, as required by the partner contract.
    Enum.sum_by(rooms, fn room ->
      lodging = room.nightly_rate_cents * nights
      div(lodging * 20 + 50, 100)
    end)
  end

  defp room_deposit_due("advance_purchase", lodging_total_cents), do: lodging_total_cents

  defp room_deposit_due("flexible", lodging_total_cents),
    do: div(lodging_total_cents * 20 + 50, 100)

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _invalid -> {:error, :invalid_refund_method}
    end
  end

  defp refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp refund_method_available(_method, _refundable), do: :ok

  defp settle_rooms(group, rooms, operation, occurred_on, refund_method, true) do
    room_ids = Enum.map(rooms, & &1.id)
    Credit.restore_allocations(room_ids, occurred_on)

    settlement =
      case refund_method do
        "cash" ->
          contributions = RoomAccounting.settle_cash(room_ids, :refunded)

          %{
            refunded_cents: contribution_total(contributions),
            retained_cents: 0,
            converted_cents: 0,
            credit_issued_cents: 0
          }

        "hotel_credit" ->
          contributions = RoomAccounting.settle_cash(room_ids, :converted)

          issued =
            Credit.issue(
              group.guest_id,
              operation["operation_id"],
              contributions,
              occurred_on
            )

          %{
            refunded_cents: 0,
            retained_cents: 0,
            converted_cents: contribution_total(contributions),
            credit_issued_cents: issued
          }
      end

    RoomAccounting.cancel_rooms(rooms)
    settlement
  end

  defp settle_rooms(_group, rooms, _operation, _occurred_on, "cash", false) do
    room_ids = Enum.map(rooms, & &1.id)
    Credit.consume_allocations(room_ids)
    contributions = RoomAccounting.settle_cash(room_ids, :retained)
    RoomAccounting.cancel_rooms(rooms)

    %{
      refunded_cents: 0,
      retained_cents: contribution_total(contributions),
      converted_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp contribution_total(contributions), do: Enum.sum_by(contributions, & &1.amount_cents)

  defp load_payment_funding(operation, invalid_payment_reason) do
    payment_operation_id = operation["payment_operation_id"]

    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %PartnerOperation{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(CashFunding, payment_operation_id: payment_operation_id) do
          nil -> {:error, invalid_payment_reason}
          funding -> {:ok, funding}
        end

      _receipt ->
        {:error, invalid_payment_reason}
    end
  end

  defp load_funding_group(funding) do
    case Repo.get(Group, funding.group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp reducible(%CashFunding{held_cents: held_cents}) when held_cents > 0, do: :ok
  defp reducible(_funding), do: {:error, :payment_not_reducible}

  defp within_held_cash(amount_cents, funding) do
    if amount_cents <= funding.held_cents,
      do: :ok,
      else: {:error, :reduction_exceeds_held_cash}
  end

  defp chargeable(%CashFunding{} = funding) do
    if funding.charged_back_cents == 0 and funding.reduced_cents < funding.recorded_cents,
      do: :ok,
      else: {:error, :payment_not_chargeable}
  end

  defp next_commit_order do
    (Repo.aggregate(PartnerOperation, :max, :commit_order) || 0) + 1
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp date(_value), do: {:error, :invalid_date}

  defp require_fields(operation, fields) when is_map(operation) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: {:error, :missing_data}
  end

  defp require_fields(_operation, _fields), do: {:error, :missing_data}

  defp validate_partner_identifiers(operation, fields) do
    if Enum.all?(fields, &nonempty_string?(operation[&1])),
      do: :ok,
      else: {:error, :invalid_identifier}
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp applied(operation, fields) do
    Map.merge(
      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied"
      },
      fields
    )
  end

  defp reject(operation, code) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => code
    }
  end

  defp reject_stale(operation, group) do
    stale_result(operation, group)
  end

  defp reject_stale(operation, group, revision_field) do
    stale_result(operation, group, revision_field)
  end

  defp stale_result(operation, group) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group.group_id,
      "expected_revision" => operation["expected_revision"],
      "actual_revision" => group.revision
    }
  end

  defp stale_result(operation, group, revision_field) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => group.group_id,
      "expected_revision" => operation[revision_field],
      "actual_revision" => group.revision
    }
  end

  defp reject_group(operation, code, group_id) do
    operation
    |> reject(code)
    |> Map.put("group_id", group_id)
  end

  defp rejected_result(operation, code) do
    %{
      "operation_id" => operation_id(operation),
      "status" => "rejected",
      "code" => code
    }
  end

  defp operation_id(operation) when is_map(operation), do: operation["operation_id"]
  defp operation_id(_operation), do: nil
end
