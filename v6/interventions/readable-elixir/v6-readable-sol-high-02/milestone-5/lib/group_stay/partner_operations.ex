defmodule GroupStay.PartnerOperations do
  @moduledoc """
  Applies partner operations in request order.

  Each operation owns a separate database transaction containing both its
  domain effects and durable idempotency record. A savepoint discards any
  partial domain work for a handled rejection while allowing that result to be
  remembered. Successful changes remain visible to every later item in the
  same batch.
  """

  alias GroupStay.Repo
  alias GroupStay.{Credits, DepositTransfers, Payments}
  alias GroupStay.PartnerOperations.OperationRecord
  alias GroupStay.Reservations.{CancellationPolicy, Group, RoomAccounting}

  @operation_requirements %{
    "open_group" =>
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(operation_id occurred_on group_id amount_cents),
    "apply_hotel_credit" => ~w(operation_id occurred_on group_id amount_cents),
    "reschedule_group" => ~w(operation_id occurred_on group_id new_arrival_on),
    "cancel_group" => ~w(operation_id occurred_on group_id),
    "cancel_rooms" => ~w(operation_id occurred_on group_id room_ids),
    "reduce_cash_payment" => ~w(operation_id occurred_on payment_operation_id amount_cents),
    "charge_back_payment" => ~w(operation_id occurred_on payment_operation_id),
    "transfer_deposit" =>
      ~w(operation_id occurred_on source_group_id destination_group_id amount_cents)
  }

  @spec process_batch([term()]) :: [map()]
  def process_batch(operations), do: Enum.map(operations, &process/1)

  def process(operation) when is_map(operation) do
    if valid_identifier?(operation["operation_id"]) do
      run_transaction(operation)
    else
      rejection(operation, "invalid_operation")
    end
  end

  def process(_operation), do: rejection(%{}, "invalid_operation")

  @doc "Returns the exact result stored for an operation identifier."
  @spec get_result(String.t()) :: map() | nil
  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_result(_operation_id), do: nil

  @doc "Returns a reconciliation statement or a stable read error."
  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil -> {:error, :operation_not_found}
      record -> payment_statement_for_record(record)
    end
  end

  def get_payment_statement(_payment_operation_id), do: {:error, :operation_not_found}

  defp run_transaction(operation) do
    case Repo.transaction(fn -> claim_or_replay(operation) end) do
      {:ok, result} -> result
      {:error, reason} -> raise "partner operation transaction rolled back: #{inspect(reason)}"
    end
  end

  defp claim_or_replay(operation) do
    changeset = OperationRecord.claim_changeset(%OperationRecord{}, operation)

    case Repo.insert(changeset, mode: :savepoint) do
      {:ok, record} ->
        result = execute_first_attempt(operation)

        record
        |> OperationRecord.result_changeset(result)
        |> Repo.update!()

        result

      {:error, changeset} ->
        if operation_id_conflict?(changeset) do
          replay_or_reject_conflict(operation)
        else
          raise "could not claim partner operation: #{inspect(changeset.errors)}"
        end
    end
  end

  defp replay_or_reject_conflict(operation) do
    record = Repo.get_by!(OperationRecord, operation_id: operation["operation_id"])

    if record.submission === operation do
      record.result
    else
      rejection(operation, "operation_id_conflict")
    end
  end

  defp operation_id_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {_message, metadata}} -> metadata[:constraint] == :unique
      _error -> false
    end)
  end

  defp execute_first_attempt(operation) do
    with {:ok, type} <- operation_type(operation),
         :ok <- validate_shape(operation, type) do
      apply_in_savepoint(operation, type)
    else
      _error -> rejection(operation, "invalid_operation")
    end
  end

  defp apply_in_savepoint(operation, type) do
    Repo.query!("SAVEPOINT partner_domain_operation")

    try do
      result = apply_operation(type, operation)
      Repo.query!("RELEASE SAVEPOINT partner_domain_operation")
      result
    catch
      {:handled_rejection, rejection} ->
        Repo.query!("ROLLBACK TO SAVEPOINT partner_domain_operation")
        Repo.query!("RELEASE SAVEPOINT partner_domain_operation")
        rejection
    end
  rescue
    error in Ecto.StaleEntryError ->
      rollback_domain_savepoint()
      stale_group_id = error.changeset.data.group_id

      case revision_guard_key(operation, stale_group_id) do
        {:ok, guard_key} ->
          concurrent_revision_rejection(operation, stale_group_id, guard_key)

        :unconditional ->
          # An unguarded group always targets its latest version. This also applies to groups
          # changed indirectly by payment corrections: revision guards are preconditions only
          # for groups explicitly addressed by the operation.
          apply_in_savepoint(operation, type)
      end
  end

  defp rollback_domain_savepoint do
    Repo.query!("ROLLBACK TO SAVEPOINT partner_domain_operation")
    Repo.query!("RELEASE SAVEPOINT partner_domain_operation")
  end

  defp operation_type(%{"type" => type}) when is_map_key(@operation_requirements, type),
    do: {:ok, type}

  defp operation_type(_operation), do: :error

  defp validate_shape(operation, type) do
    required = Map.fetch!(@operation_requirements, type)

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["operation_id"]) and
         valid_address_identifiers?(operation, type) and
         valid_type_specific_identifiers?(operation, type) do
      :ok
    else
      :error
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp valid_type_specific_identifiers?(operation, "open_group") do
    valid_identifier?(operation["guest_id"]) and valid_identifier?(operation["property_id"])
  end

  defp valid_type_specific_identifiers?(operation, type)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    valid_identifier?(operation["payment_operation_id"])
  end

  defp valid_type_specific_identifiers?(operation, "transfer_deposit") do
    valid_identifier?(operation["source_group_id"]) and
      valid_identifier?(operation["destination_group_id"])
  end

  defp valid_type_specific_identifiers?(_operation, _type), do: true

  defp valid_address_identifiers?(operation, type)
       when type in ["reduce_cash_payment", "charge_back_payment"],
       do: valid_identifier?(operation["payment_operation_id"])

  defp valid_address_identifiers?(operation, "transfer_deposit"),
    do:
      valid_identifier?(operation["source_group_id"]) and
        valid_identifier?(operation["destination_group_id"])

  defp valid_address_identifiers?(operation, _type),
    do: valid_identifier?(operation["group_id"])

  defp apply_operation("open_group", operation), do: open_group(operation)
  defp apply_operation("record_cash_payment", operation), do: record_cash_payment(operation)
  defp apply_operation("apply_hotel_credit", operation), do: apply_hotel_credit(operation)
  defp apply_operation("reschedule_group", operation), do: reschedule_group(operation)
  defp apply_operation("cancel_group", operation), do: cancel_group(operation)
  defp apply_operation("cancel_rooms", operation), do: cancel_rooms(operation)
  defp apply_operation("reduce_cash_payment", operation), do: reduce_cash_payment(operation)
  defp apply_operation("charge_back_payment", operation), do: charge_back_payment(operation)
  defp apply_operation("transfer_deposit", operation), do: transfer_deposit(operation)

  defp open_group(operation) do
    if Repo.get(Group, operation["group_id"]) do
      rollback(operation, "group_already_exists")
    end

    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- parse_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)

      rooms_with_positions =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          lodging_cents = room.nightly_rate_cents * nights

          room
          |> Map.put(:position, position)
          |> Map.put(:status, :active)
          |> Map.put(:lodging_total_cents, lodging_cents)
          |> Map.put(:deposit_due_cents, room_deposit_due(lodging_cents, rate_plan))
          |> Map.put(:cash_paid_cents, 0)
          |> Map.put(:credit_paid_cents, 0)
        end)

      lodging_total_cents =
        Enum.reduce(rooms, 0, fn room, total ->
          total + room.nightly_rate_cents * nights
        end)

      deposit_due_cents = Enum.sum(Enum.map(rooms_with_positions, & &1.deposit_due_cents))

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: CancellationPolicy.version(rate_plan, booked_on),
        status: :active,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1,
        rooms: rooms_with_positions
      }

      case %Group{} |> Group.creation_changeset(attrs) |> Repo.insert() do
        {:ok, group} ->
          applied(operation, %{
            "group_id" => group.group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            rollback(operation, "group_already_exists")
          else
            rollback(operation, "invalid_operation")
          end
      end
    else
      :error -> rollback(operation, "invalid_stay")
      {:error, :invalid_stay} -> rollback(operation, "invalid_stay")
      {:error, :invalid_rate_plan} -> rollback(operation, "invalid_rate_plan")
      {:error, :invalid_rooms} -> rollback(operation, "invalid_rooms")
    end
  end

  defp record_cash_payment(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    with {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, amount_cents} <- validate_payment_amount(operation["amount_cents"]),
         :ok <- validate_payment_within_outstanding(group, amount_cents) do
      record = Repo.get_by!(OperationRecord, operation_id: operation["operation_id"])
      Payments.record(group, operation["operation_id"], amount_cents, record.commit_order)
      {:ok, updated_group} = RoomAccounting.update_group(group)

      applied(operation, %{
        "group_id" => updated_group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => Group.outstanding_deposit_cents(updated_group),
        "revision" => updated_group.revision
      })
    else
      :error ->
        rollback(operation, "invalid_operation")

      {:error, :invalid_amount} ->
        rollback(operation, "invalid_amount")

      {:error, :payment_exceeds_outstanding} ->
        rollback(operation, "payment_exceeds_outstanding")
    end
  end

  defp apply_hotel_credit(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, amount_cents} <- validate_payment_amount(operation["amount_cents"]),
         :ok <- validate_payment_within_outstanding(group, amount_cents),
         :ok <-
           Credits.apply_to_group(group, amount_cents, occurred_on, operation["operation_id"]) do
      {:ok, updated_group} = RoomAccounting.update_group(group)

      applied(operation, %{
        "group_id" => updated_group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => Group.outstanding_deposit_cents(updated_group),
        "revision" => updated_group.revision
      })
    else
      :error ->
        rollback(operation, "invalid_operation")

      {:error, :invalid_amount} ->
        rollback(operation, "invalid_amount")

      {:error, :payment_exceeds_outstanding} ->
        rollback(operation, "payment_exceeds_outstanding")

      {:error, :insufficient_credit} ->
        rollback(operation, "insufficient_credit")
    end
  end

  defp reschedule_group(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_future_arrival(new_arrival_on, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      {:ok, updated_group} =
        group
        |> Group.reschedule_changeset(new_arrival_on, new_departure_on)
        |> Repo.update()

      applied(operation, %{
        "group_id" => updated_group.group_id,
        "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
        "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
        "policy_version" => CancellationPolicy.external_name(updated_group.policy_version),
        "refundable_until" => format_date(Group.refundable_until(updated_group)),
        "revision" => updated_group.revision
      })
    else
      _error -> rollback(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, refund_method} <- parse_refund_method(Map.get(operation, "refund_method", "cash")) do
      refundable? =
        CancellationPolicy.refundable?(group.policy_version, group.arrival_on, occurred_on)

      if refund_method == :hotel_credit and not refundable? do
        rollback(operation, "refund_method_not_available")
      end

      rooms = RoomAccounting.active_rooms(group.group_id)

      settlement =
        settle_rooms(group, rooms, refundable?, refund_method, operation, occurred_on)

      {:ok, updated_group} = update_group_after_settlement(group, settlement)

      applied(operation, %{
        "group_id" => updated_group.group_id,
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => updated_group.revision
      })
    else
      :error -> rollback(operation, "invalid_operation")
    end
  end

  defp cancel_rooms(operation) do
    group = fetch_group!(operation)
    ensure_current_revision!(group, operation)
    ensure_active!(group, operation)

    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, refund_method} <- parse_refund_method(Map.get(operation, "refund_method", "cash")),
         {:ok, rooms} <- validate_selected_rooms(group, operation["room_ids"]) do
      refundable? =
        CancellationPolicy.refundable?(group.policy_version, group.arrival_on, occurred_on)

      if refund_method == :hotel_credit and not refundable? do
        rollback(operation, "refund_method_not_available")
      end

      settlement =
        settle_rooms(group, rooms, refundable?, refund_method, operation, occurred_on)

      {:ok, updated_group} = update_group_after_settlement(group, settlement)

      applied(operation, %{
        "group_id" => group.group_id,
        "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => updated_group.revision
      })
    else
      :error -> rollback(operation, "invalid_operation")
      {:error, :invalid_rooms} -> rollback(operation, "invalid_rooms")
    end
  end

  defp reduce_cash_payment(operation) do
    payment = fetch_adjustable_payment!(operation, "payment_not_reducible")
    group = Repo.get!(Group, payment.group_id)
    ensure_current_revision!(group, operation)
    held_cents = Payments.held_cents(payment)

    if held_cents == 0, do: rollback(operation, "payment_not_reducible")

    with {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, amount_cents} <- validate_payment_amount(operation["amount_cents"]),
         :ok <- validate_reduction(amount_cents, held_cents) do
      affected_group_ids = Payments.reduce(payment, amount_cents)
      updated_groups = update_changed_groups(group, affected_group_ids)
      updated_group = Map.fetch!(updated_groups, group.group_id)

      applied(operation, %{
        "payment_operation_id" => payment.payment_operation_id,
        "group_id" => payment.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => Group.outstanding_deposit_cents(updated_group),
        "revision" => updated_group.revision
      })
    else
      :error -> rollback(operation, "invalid_operation")
      {:error, :invalid_amount} -> rollback(operation, "invalid_amount")
      {:error, :reduction_exceeds_held_cash} -> rollback(operation, "reduction_exceeds_held_cash")
    end
  end

  defp charge_back_payment(operation) do
    payment = fetch_adjustable_payment!(operation, "payment_not_chargeable")
    group = Repo.get!(Group, payment.group_id)
    ensure_current_revision!(group, operation)
    chargeable = Payments.remaining_chargeable_cents(payment)

    if chargeable == 0, do: rollback(operation, "payment_not_chargeable")

    with {:ok, _occurred_on} <- parse_date(operation["occurred_on"]) do
      summary = Payments.charge_back(payment)

      updated_groups = update_chargeback_groups(group, summary.groups)
      updated_group = Map.fetch!(updated_groups, group.group_id)

      applied(operation, %{
        "payment_operation_id" => payment.payment_operation_id,
        "group_id" => payment.group_id,
        "charged_back_cents" => summary.charged_back_cents,
        "outstanding_deposit_cents" => Group.outstanding_deposit_cents(updated_group),
        "revision" => updated_group.revision
      })
    else
      :error -> rollback(operation, "invalid_operation")
    end
  end

  defp transfer_deposit(operation) do
    source = fetch_transfer_group!(operation, operation["source_group_id"])
    destination = fetch_transfer_group!(operation, operation["destination_group_id"])
    ensure_current_revision!(source, operation)
    ensure_destination_revision!(destination, operation)

    with {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- validate_transfer_parties(source, destination),
         :ok <- ensure_transfer_active(source),
         :ok <- ensure_transfer_active(destination),
         {:ok, amount_cents} <- validate_payment_amount(operation["amount_cents"]),
         :ok <- validate_transfer_funding(source, amount_cents),
         :ok <- validate_transfer_capacity(destination, amount_cents) do
      DepositTransfers.transfer(source.group_id, destination.group_id, amount_cents)
      {:ok, updated_source} = RoomAccounting.update_group(source)
      {:ok, updated_destination} = RoomAccounting.update_group(destination)

      applied(operation, %{
        "source_group_id" => updated_source.group_id,
        "destination_group_id" => updated_destination.group_id,
        "amount_cents" => amount_cents,
        "source_outstanding_deposit_cents" => Group.outstanding_deposit_cents(updated_source),
        "destination_outstanding_deposit_cents" =>
          Group.outstanding_deposit_cents(updated_destination),
        "source_revision" => updated_source.revision,
        "destination_revision" => updated_destination.revision
      })
    else
      :error ->
        rollback(operation, "invalid_operation")

      {:error, :invalid_transfer} ->
        rollback(operation, "invalid_transfer")

      {:error, :invalid_amount} ->
        rollback(operation, "invalid_amount")

      {:error, :transfer_exceeds_held_funding} ->
        rollback(operation, "transfer_exceeds_held_funding")

      {:error, :transfer_exceeds_outstanding} ->
        rollback(operation, "transfer_exceeds_outstanding")

      {:error, :group_not_active, group_id} ->
        operation
        |> rejection("group_not_active")
        |> Map.put("group_id", group_id)
        |> rollback()
    end
  end

  defp fetch_group!(operation) do
    case Repo.get(Group, operation["group_id"]) do
      nil -> rollback(operation, "group_not_found")
      group -> group
    end
  end

  defp ensure_current_revision!(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when expected == group.revision ->
        :ok

      {:ok, expected} ->
        rollback(stale_rejection(operation, group.group_id, expected, group.revision))
    end
  end

  defp ensure_destination_revision!(group, operation) do
    case Map.fetch(operation, "destination_expected_revision") do
      :error ->
        :ok

      {:ok, expected} when expected == group.revision ->
        :ok

      {:ok, expected} ->
        rollback(stale_rejection(operation, group.group_id, expected, group.revision))
    end
  end

  defp ensure_active!(%Group{status: :active}, _operation), do: :ok
  defp ensure_active!(_group, operation), do: rollback(operation, "group_not_active")

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp validate_future_arrival(arrival_on, occurred_on) do
    if Date.compare(arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp validate_payment_amount(amount) when is_integer(amount) and amount > 0,
    do: {:ok, amount}

  defp validate_payment_amount(_amount), do: {:error, :invalid_amount}

  defp validate_payment_within_outstanding(group, amount_cents) do
    if amount_cents <= Group.outstanding_deposit_cents(group),
      do: :ok,
      else: {:error, :payment_exceeds_outstanding}
  end

  defp validate_reduction(amount_cents, held_cents) do
    if amount_cents <= held_cents,
      do: :ok,
      else: {:error, :reduction_exceeds_held_cash}
  end

  defp validate_transfer_parties(source, destination) do
    if source.group_id != destination.group_id and source.guest_id == destination.guest_id,
      do: :ok,
      else: {:error, :invalid_transfer}
  end

  defp ensure_transfer_active(%Group{status: :active}), do: :ok
  defp ensure_transfer_active(group), do: {:error, :group_not_active, group.group_id}

  defp validate_transfer_funding(source, amount_cents) do
    if amount_cents <= DepositTransfers.held_cents(source.group_id),
      do: :ok,
      else: {:error, :transfer_exceeds_held_funding}
  end

  defp validate_transfer_capacity(destination, amount_cents) do
    if amount_cents <= Group.outstanding_deposit_cents(destination),
      do: :ok,
      else: {:error, :transfer_exceeds_outstanding}
  end

  defp parse_refund_method("cash"), do: {:ok, :cash}
  defp parse_refund_method("hotel_credit"), do: {:ok, :hotel_credit}
  defp parse_refund_method(_refund_method), do: :error

  defp parse_rate_plan("flexible"), do: {:ok, :flexible}
  defp parse_rate_plan("advance_purchase"), do: {:ok, :advance_purchase}
  defp parse_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    parsed = Enum.map(rooms, &validate_room/1)

    with true <- Enum.all?(parsed, &match?({:ok, _room}, &1)),
         room_values = Enum.map(parsed, fn {:ok, room} -> room end),
         true <- unique_room_ids?(room_values) do
      {:ok, room_values}
    else
      _invalid -> {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp validate_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 do
    {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
  end

  defp validate_room(_room), do: {:error, :invalid_room}

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp room_deposit_due(lodging_cents, :advance_purchase), do: lodging_cents
  defp room_deposit_due(lodging_cents, :flexible), do: div(lodging_cents * 20 + 50, 100)

  defp validate_selected_rooms(group, room_ids)
       when is_list(room_ids) and room_ids != [] do
    valid_identifiers? = Enum.all?(room_ids, &valid_identifier?/1)
    distinct? = length(room_ids) == length(Enum.uniq(room_ids))

    if valid_identifiers? and distinct? do
      rooms = RoomAccounting.selected_active_rooms(group.group_id, room_ids)

      if length(rooms) == length(room_ids),
        do: {:ok, rooms},
        else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_selected_rooms(_group, _room_ids), do: {:error, :invalid_rooms}

  defp settle_rooms(group, rooms, refundable?, refund_method, operation, occurred_on) do
    settlement =
      Payments.settle_rooms(
        group,
        rooms,
        refundable?,
        refund_method,
        operation["operation_id"],
        occurred_on
      )

    Credits.settle_rooms(rooms, refundable?, occurred_on)
    Enum.each(rooms, &RoomAccounting.cancel_room/1)
    settlement
  end

  defp update_group_after_settlement(group, settlement) do
    RoomAccounting.update_group(group, %{
      refunded_cents: group.refunded_cents + settlement.refunded_cents,
      retained_cents: group.retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.converted_cents
    })
  end

  defp fetch_adjustable_payment!(operation, invalid_code) do
    case Repo.get_by(OperationRecord, operation_id: operation["payment_operation_id"]) do
      nil ->
        rollback(operation, "operation_not_found")

      record ->
        case payment_statement_for_record(record) do
          {:ok, _statement} -> Payments.get(record.operation_id)
          {:error, _reason} -> rollback(operation, invalid_code)
        end
    end
  end

  defp fetch_transfer_group!(operation, group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        operation
        |> rejection("group_not_found")
        |> Map.put("group_id", group_id)
        |> rollback()

      group ->
        group
    end
  end

  defp update_changed_groups(original_group, affected_group_ids) do
    affected_group_ids
    |> MapSet.put(original_group.group_id)
    |> Enum.sort_by(&{&1 != original_group.group_id, &1})
    |> Map.new(fn group_id ->
      group =
        if group_id == original_group.group_id,
          do: original_group,
          else: Repo.get!(Group, group_id)

      {:ok, updated_group} = RoomAccounting.update_group(group)
      {group_id, updated_group}
    end)
  end

  defp update_chargeback_groups(original_group, summaries) do
    summaries
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.put(original_group.group_id)
    |> Enum.sort_by(&{&1 != original_group.group_id, &1})
    |> Map.new(fn group_id ->
      group =
        if group_id == original_group.group_id,
          do: original_group,
          else: Repo.get!(Group, group_id)

      summary = Map.get(summaries, group_id, %{refunded: 0, retained: 0, converted: 0})

      extra = %{
        refunded_cents: group.refunded_cents - summary.refunded,
        retained_cents: group.retained_cents - summary.retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents - summary.converted
      }

      {:ok, updated_group} = RoomAccounting.update_group(group, extra)
      {group_id, updated_group}
    end)
  end

  defp payment_statement_for_record(%OperationRecord{
         operation_type: "record_cash_payment",
         result: %{"status" => "applied"},
         operation_id: operation_id
       }) do
    case Payments.get(operation_id) do
      nil -> {:error, :payment_not_reconcilable}
      payment -> {:ok, Payments.statement(payment)}
    end
  end

  defp payment_statement_for_record(_record), do: {:error, :payment_not_reconcilable}

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp concurrent_revision_rejection(operation, group_id, guard_key) do
    case Repo.get(Group, group_id) do
      nil ->
        rejection(operation, "group_not_found")

      group ->
        expected = Map.fetch!(operation, guard_key)
        stale_rejection(operation, group.group_id, expected, group.revision)
    end
  end

  defp revision_guard_key(%{"type" => "transfer_deposit"} = operation, group_id) do
    cond do
      group_id == operation["source_group_id"] and Map.has_key?(operation, "expected_revision") ->
        {:ok, "expected_revision"}

      group_id == operation["destination_group_id"] and
          Map.has_key?(operation, "destination_expected_revision") ->
        {:ok, "destination_expected_revision"}

      true ->
        :unconditional
    end
  end

  defp revision_guard_key(operation, group_id) do
    addressed_group_id =
      case operation["payment_operation_id"] && Payments.get(operation["payment_operation_id"]) do
        nil -> operation["group_id"]
        payment -> payment.group_id
      end

    if group_id == addressed_group_id and Map.has_key?(operation, "expected_revision"),
      do: {:ok, "expected_revision"},
      else: :unconditional
  end

  defp applied(operation, fields) do
    Map.merge(
      %{"operation_id" => operation["operation_id"], "status" => "applied"},
      fields
    )
  end

  defp rejection(operation, code) do
    %{
      "operation_id" => Map.get(operation, "operation_id"),
      "status" => "rejected",
      "code" => code
    }
  end

  defp stale_rejection(operation, group_id, expected, actual) do
    operation
    |> rejection("stale_revision")
    |> Map.merge(%{
      "group_id" => group_id,
      "expected_revision" => expected,
      "actual_revision" => actual
    })
  end

  defp rollback(operation, code), do: throw({:handled_rejection, rejection(operation, code)})
  defp rollback(result) when is_map(result), do: throw({:handled_rejection, result})
end
