defmodule GroupStay.Reservations do
  @moduledoc """
  Processes ordered partner operations and owns reservation deposit accounting.

  Each operation has its own SQLite immediate transaction. Acquiring the write
  lock before reading a group makes revision checks and balance changes atomic
  across connections and service instances. Each identified submission and its
  JSON result commit with its domain changes. Handled rejections commit only
  that audit record; unexpected exceptions roll back and abort the batch.
  """
  alias GroupStay.{Finance, Repo}

  alias GroupStay.Reservations.{
    CancellationPolicy,
    CancellationSettlement,
    CashEntry,
    CashPayments,
    DepositTransfers,
    Group,
    HotelCredit,
    Ledger,
    Operation,
    OperationRecord,
    RoomAccounting
  }

  @doc "Applies operations in order and returns one JSON outcome for each input."
  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @doc "Fetches a group using its unchanged partner identifier."
  def get_group(group_id), do: Repo.get(Group, group_id)

  @doc "Returns the original JSON result, or nil if the identifier has not been recorded."
  def get_operation_result(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  @doc "Reconciles a durable cash payment using its current dispositions."
  def payment_statement(payment_id), do: CashPayments.statement(payment_id)

  @doc "Returns cash totals and credit liability, evaluating expiry on the supplied date."
  def ledger(on \\ Date.utc_today()), do: Ledger.totals(on)

  @doc "Returns a guest's current unredeemed credit that has not expired on the supplied date."
  def guest_credit(guest_id, on \\ Date.utc_today()), do: HotelCredit.available(guest_id, on)

  defp submit_operation(operation) do
    if Operation.identifier?(Operation.id(operation)) do
      {:ok, result} = Repo.transact_immediate(fn -> replay_or_apply(operation) end)
      result
    else
      # An unusable identifier cannot reserve a durable retry key.
      Operation.result(operation, {:error, :invalid_operation})
    end
  end

  defp replay_or_apply(operation) do
    case Repo.get_by(OperationRecord, operation_id: Operation.id(operation)) do
      nil ->
        outcome =
          with :ok <- Operation.identify(operation) do
            apply_operation(operation)
          end

        result = Operation.result(operation, outcome)
        Repo.insert!(OperationRecord.new(operation, result))
        {:ok, result}

      %OperationRecord{submission: submission, result: result} when submission === operation ->
        {:ok, result}

      %OperationRecord{} ->
        {:ok, Operation.result(operation, {:error, :operation_id_conflict})}
    end
  end

  # Domain transitions return handled rejections before writing any records.
  # Storage failures raise, rolling back both domain changes and the audit record.
  defp apply_operation(%{"type" => "start_finance_reporting"} = operation),
    do: Finance.start(operation)

  defp apply_operation(%{"type" => "close_finance_period"} = operation),
    do: Finance.close_period(operation)

  defp apply_operation(%{"type" => "open_group"} = operation) do
    if get_group(operation["group_id"]) do
      {:error, :group_already_exists}
    else
      with {:ok, occurred_on} <- Operation.validate_payload(operation),
           {:ok, changeset} <- Group.open(operation, occurred_on) do
        group = Repo.insert!(changeset)

        {:ok,
         %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         }}
      end
    end
  end

  defp apply_operation(%{"type" => "transfer_deposit"} = operation) do
    with {:ok, source} <- fetch_transfer_group(operation["source_group_id"]),
         {:ok, destination} <- fetch_transfer_group(operation["destination_group_id"]),
         :ok <- check_revision(source, operation),
         :ok <- check_revision(destination, operation, "destination_expected_revision"),
         {:ok, occurred_on} <- Operation.validate_payload(operation),
         {:ok, source_rooms, destination_rooms} <-
           DepositTransfers.transfer(source, destination, operation, occurred_on) do
      source = Repo.update!(Group.update_rooms(source, source_rooms))
      destination = Repo.update!(Group.update_rooms(destination, destination_rooms))

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: operation["amount_cents"],
         source_outstanding_deposit_cents: Group.outstanding_deposit(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp apply_operation(%{"type" => type} = operation)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    invalid_code =
      if type == "reduce_cash_payment", do: :payment_not_reducible, else: :payment_not_chargeable

    with {:ok, payment} <- CashPayments.fetch(operation["payment_operation_id"], invalid_code),
         {:ok, group} <- fetch_group(payment.result["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, occurred_on} <- Operation.validate_payload(operation) do
      correct_payment(group, payment, operation, occurred_on)
    end
  end

  defp apply_operation(operation) do
    with {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, occurred_on} <- Operation.validate_payload(operation),
         :ok <- ensure_active(group) do
      apply_to_group(group, operation, occurred_on)
    end
  end

  defp apply_to_group(group, %{"type" => "record_cash_payment"} = operation, occurred_on) do
    amount = operation["amount_cents"]

    with :ok <- Group.validate_payment(group, amount) do
      rooms = CashPayments.fund(group, operation, occurred_on)
      group = Repo.update!(Group.update_rooms(group, rooms))

      {:ok, payment_result(group, amount)}
    end
  end

  defp apply_to_group(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on) do
    amount = operation["amount_cents"]

    with :ok <- Group.validate_payment(group, amount),
         {:ok, rooms} <- HotelCredit.redeem(group, operation, occurred_on) do
      group = Repo.update!(Group.update_rooms(group, rooms))
      {:ok, payment_result(group, amount)}
    end
  end

  defp apply_to_group(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    with {:ok, changeset} <- Group.reschedule(group, operation["new_arrival_on"], occurred_on) do
      group = Repo.update!(changeset)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         policy_version: group.policy_version,
         refundable_until: CancellationPolicy.refundable_until(group),
         revision: group.revision
       }}
    end
  end

  defp apply_to_group(group, %{"type" => type} = operation, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    room_ids =
      if type == "cancel_group",
        do: group.rooms |> Enum.filter(&(&1.status == :active)) |> Enum.map(& &1.room_id),
        else: operation["room_ids"]

    with {:ok, selected} <- RoomAccounting.select(group.rooms, room_ids),
         {:ok, settlement} <-
           CancellationSettlement.calculate(
             group,
             occurred_on,
             Map.get(operation, "refund_method", "cash"),
             RoomAccounting.sum(selected, :cash_paid_cents)
           ) do
      room_ids = Enum.map(selected, & &1.room_id)
      cash_allocations = CashPayments.held_for_rooms(group.group_id, room_ids)
      rooms = RoomAccounting.cancel(group.rooms, room_ids)
      group = Repo.update!(Group.update_rooms(group, rooms))

      CashEntry.record(group.group_id, operation, occurred_on, :refund, settlement.refunded_cents)

      CashEntry.record(
        group.group_id,
        operation,
        occurred_on,
        :retention,
        settlement.retained_cents
      )

      CashEntry.record(
        group.group_id,
        operation,
        occurred_on,
        :credit_conversion,
        settlement.cash_converted_to_credit_cents
      )

      HotelCredit.settle_rooms(
        group.group_id,
        room_ids,
        settlement.restore_credit?,
        operation,
        occurred_on
      )

      lot = HotelCredit.issue(group, operation, occurred_on, settlement.credit_issued_cents)
      CashPayments.settle(cash_allocations, settlement, lot, operation, occurred_on)

      result =
        Map.merge(CancellationSettlement.result(settlement), %{
          group_id: group.group_id,
          revision: group.revision
        })

      result =
        if type == "cancel_rooms",
          do: Map.put(result, :cancelled_room_ids, room_ids),
          else: result

      {:ok, result}
    end
  end

  defp correct_payment(
         group,
         payment,
         %{"type" => "reduce_cash_payment"} = operation,
         occurred_on
       ) do
    with {:ok, portions} <- CashPayments.reduce(group, payment, operation, occurred_on) do
      group = update_corrected_groups(group, portions)

      {:ok,
       Map.put(
         payment_result(group, operation["amount_cents"]),
         :payment_operation_id,
         payment.operation_id
       )}
    end
  end

  defp correct_payment(
         group,
         payment,
         %{"type" => "charge_back_payment"} = operation,
         occurred_on
       ) do
    with {:ok, portions, amount} <-
           CashPayments.charge_back(group, payment, operation, occurred_on) do
      group = update_corrected_groups(group, portions)

      {:ok,
       %{
         payment_operation_id: payment.operation_id,
         group_id: group.group_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit(group),
         revision: group.revision
       }}
    end
  end

  # Corrections guard the original payment group, but follow held cash wherever
  # it now funds rooms. Advance each changed group once, including the addressed
  # group even if all of its payment's cash has moved away or already settled.
  defp update_corrected_groups(addressed_group, portions) do
    portions
    |> Enum.group_by(fn {group_id, _, _} -> group_id end, fn {_, room_id, amount} ->
      {room_id, amount}
    end)
    |> Map.put_new(addressed_group.group_id, [])
    |> Map.new(fn {group_id, removed} ->
      group =
        if group_id == addressed_group.group_id,
          do: addressed_group,
          else: Repo.get!(Group, group_id)

      rooms = RoomAccounting.remove(group.rooms, removed, :cash_paid_cents)
      {group_id, Repo.update!(Group.update_rooms(group, rooms))}
    end)
    |> Map.fetch!(addressed_group.group_id)
  end

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: Group.outstanding_deposit(group),
      revision: group.revision
    }
  end

  defp fetch_group(group_id) do
    case get_group(group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp fetch_transfer_group(group_id) do
    case fetch_group(group_id) do
      {:error, :group_not_found} -> {:error, %{code: "group_not_found", group_id: group_id}}
      result -> result
    end
  end

  defp check_revision(group, operation, field \\ "expected_revision") do
    case Map.fetch(operation, field) do
      {:ok, expected} when expected !== group.revision ->
        {:error,
         %{
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}

      _ ->
        :ok
    end
  end

  defp ensure_active(%Group{status: :active}), do: :ok
  defp ensure_active(%Group{}), do: {:error, :group_not_active}
end
