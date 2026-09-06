defmodule GroupStay.Reservations do
  @moduledoc """
  Domain operations for partner-managed group reservations.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashPaymentDisposition,
    CreditLot,
    CreditLotCashSource,
    Group,
    PartnerOperation,
    Room,
    RoomCreditAllocation
  }

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @cash "cash"
  @hotel_credit "hotel_credit"
  @policy_cutover ~D[2027-01-01]
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @held "held"
  @refunded "refunded"
  @retained "retained"
  @converted_to_credit "converted_to_credit"
  @reduced "reduced"
  @charged_back "charged_back"

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:error, :group_not_found}

      group ->
        {:ok,
         group |> Repo.preload(rooms: from(r in Room, order_by: r.position)) |> present_group()}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger_totals(on_param \\ nil) do
    with {:ok, on} <- reporting_date(on_param) do
      %{
        cash_held_cents: sum_groups(:cash_paid_cents, status: @active),
        cash_refunded_cents: sum_groups(:cash_refunded_cents),
        cash_retained_cents: sum_groups(:cash_retained_cents),
        cash_converted_to_credit_cents: sum_groups(:cash_converted_to_credit_cents),
        cash_reduced_cents: cash_disposition_total(@reduced),
        cash_charged_back_cents: cash_disposition_total(@charged_back),
        credit_liability_cents:
          available_credit_liability_cents(on) + active_credit_allocation_total_cents(),
        credit_shortfall_cents: credit_shortfall_cents()
      }
    end
  end

  def get_guest_credit(guest_id, on_param \\ nil)

  def get_guest_credit(guest_id, on_param) when is_binary(guest_id) do
    with {:ok, on} <- reporting_date(on_param) do
      lots = available_credit_lots(guest_id, on)

      {:ok,
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
       }}
    end
  end

  def get_guest_credit(_guest_id, _on_param),
    do: {:ok, %{guest_id: nil, available_cents: 0, lots: []}}

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      %PartnerOperation{result: result} when is_map(result) ->
        {:ok, result}

      _missing_or_incomplete ->
        {:error, :operation_not_found}
    end
  end

  def get_operation_result(_operation_id), do: {:error, :operation_not_found}

  def get_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        case applied_cash_payment_result(record) do
          {:ok, result} ->
            recorded_cents = map_get(result, "amount_cents")
            dispositions = payment_disposition_totals(payment_operation_id)

            {:ok,
             %{
               payment_operation_id: payment_operation_id,
               original_group_id: map_get(result, "group_id"),
               recorded_cents: recorded_cents,
               held_cents: Map.get(dispositions, @held, 0),
               refunded_cents: Map.get(dispositions, @refunded, 0),
               retained_cents: Map.get(dispositions, @retained, 0),
               converted_to_credit_cents: Map.get(dispositions, @converted_to_credit, 0),
               reduced_cents: Map.get(dispositions, @reduced, 0),
               charged_back_cents: Map.get(dispositions, @charged_back, 0)
             }}

          :error ->
            {:error, :payment_not_reconcilable}
        end
    end
  end

  def get_payment_statement(_payment_operation_id), do: {:error, :operation_not_found}

  defp process_operation(%{} = operation) do
    case fetch_operation_id(operation) do
      {:ok, operation_id} -> process_idempotent_operation(operation, operation_id)
      {:reject, _result} -> process_untracked_operation(operation)
    end
  end

  defp process_operation(operation), do: process_untracked_operation(operation)

  defp process_idempotent_operation(operation, operation_id) do
    canonical_payload = canonical_json(operation)

    case Repo.transaction(fn ->
           case reserve_partner_operation(operation, operation_id, canonical_payload) do
             {:reserved, record} ->
               result = apply_operation_result(operation)

               record
               |> change(result: result)
               |> Repo.update!()

               result

             {:existing, record} ->
               if record.canonical_payload == canonical_payload do
                 record.result
               else
                 rejected(operation, "operation_id_conflict")
               end
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp process_untracked_operation(operation) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:ok, result} -> result
             {:reject, result} -> Repo.rollback(result)
           end
         end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp reserve_partner_operation(operation, operation_id, canonical_payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {inserted_count, _rows} =
      Repo.insert_all(
        PartnerOperation,
        [
          %{
            operation_id: operation_id,
            operation_type: operation_type(operation),
            submitted_payload: operation,
            canonical_payload: canonical_payload,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: :operation_id
      )

    record = Repo.get_by!(PartnerOperation, operation_id: operation_id)

    case inserted_count do
      1 -> {:reserved, record}
      _already_seen -> {:existing, record}
    end
  end

  defp apply_operation_result(operation) do
    case apply_operation(operation) do
      {:ok, result} -> result
      {:reject, result} -> result
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation) do
    with_existing_group(operation, fn group -> record_cash_payment(operation, group) end)
  end

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation) do
    with_existing_group(operation, fn group -> apply_hotel_credit(operation, group) end)
  end

  defp apply_operation(%{"type" => "reduce_cash_payment"} = operation) do
    with_existing_payment_group(operation, "payment_not_reducible", fn group, payment_record ->
      reduce_cash_payment(operation, group, payment_record)
    end)
  end

  defp apply_operation(%{"type" => "charge_back_payment"} = operation) do
    with_existing_payment_group(operation, "payment_not_chargeable", fn group, payment_record ->
      charge_back_payment(operation, group, payment_record)
    end)
  end

  defp apply_operation(%{"type" => "reschedule_group"} = operation) do
    with_existing_group(operation, fn group -> reschedule_group(operation, group) end)
  end

  defp apply_operation(%{"type" => "cancel_rooms"} = operation) do
    with_existing_group(operation, fn group -> cancel_rooms(operation, group) end)
  end

  defp apply_operation(%{"type" => "cancel_group"} = operation) do
    with_existing_group(operation, fn group -> cancel_group(operation, group) end)
  end

  defp apply_operation(operation) when is_map(operation) do
    {:reject, rejected(operation, "invalid_operation")}
  end

  defp apply_operation(_operation) do
    {:reject, rejected(%{}, "invalid_operation")}
  end

  defp open_group(operation) do
    with :ok <- require_common_fields(operation),
         {:ok, group_id} <- fetch_string(operation, "group_id"),
         :ok <- ensure_group_available(operation, group_id),
         {:ok, guest_id} <- fetch_string(operation, "guest_id"),
         {:ok, property_id} <- fetch_string(operation, "property_id"),
         {:ok, booked_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, arrival_on} <- fetch_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- fetch_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay(operation, arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(operation),
         {:ok, rate_plan} <- validate_rate_plan(operation),
         totals <- calculate_totals(rooms, arrival_on, departure_on, rate_plan),
         {:ok, group} <-
           insert_group(%{
             group_id: group_id,
             guest_id: guest_id,
             property_id: property_id,
             booked_on: booked_on,
             arrival_on: arrival_on,
             departure_on: departure_on,
             rate_plan: rate_plan,
             policy_version: policy_version_for(rate_plan, booked_on),
             lodging_total_cents: totals.lodging_total_cents,
             deposit_due_cents: totals.deposit_due_cents
           }),
         :ok <- insert_rooms(group, totals.rooms) do
      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp record_cash_payment(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         outstanding <- outstanding_deposit_cents(group),
         :ok <- ensure_payment_fits(operation, group, amount_cents, outstanding),
         :ok <- allocate_cash_payment(group, operation_id(operation), amount_cents) do
      updated = refresh_group_summary!(group, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp apply_hotel_credit(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         outstanding <- outstanding_deposit_cents(group),
         :ok <- ensure_payment_fits(operation, group, amount_cents, outstanding),
         {:ok, lots} <-
           ensure_credit_available(operation, group.guest_id, amount_cents, occurred_on),
         :ok <- allocate_hotel_credit(group, operation_id(operation), lots, amount_cents) do
      updated = refresh_group_summary!(group, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp reschedule_group(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- fetch_date(operation, "new_arrival_on", "invalid_stay"),
         :ok <- ensure_future_arrival(operation, group, new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      updated =
        group
        |> change(
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        )
        |> Repo.update!()

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         new_arrival_on: Date.to_iso8601(updated.arrival_on),
         new_departure_on: Date.to_iso8601(updated.departure_on),
         policy_version: policy_version(updated),
         refundable_until: refundable_until_iso8601(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp cancel_group(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- fetch_refund_method(operation),
         refundable <- refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(operation, refund_method, refundable) do
      settlement =
        operation
        |> settle_selected_rooms(
          group,
          active_rooms(group),
          refund_method,
          refundable,
          occurred_on
        )

      updated = refresh_group_summary!(group, status: @cancelled, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp cancel_rooms(operation, group) do
    with :ok <- ensure_active(operation, group),
         {:ok, occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- fetch_refund_method(operation),
         {:ok, rooms} <- fetch_active_rooms(operation, group),
         refundable <- refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(operation, refund_method, refundable) do
      settlement =
        operation
        |> settle_selected_rooms(group, rooms, refund_method, refundable, occurred_on)

      updated = refresh_group_summary!(group, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         group_id: updated.group_id,
         cancelled_room_ids: Enum.map(rooms, & &1.room_id),
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp reduce_cash_payment(operation, group, payment_record) do
    payment_operation_id = payment_record.operation_id

    with {:ok, amount_cents} <-
           fetch_positive_integer(operation, "amount_cents", "invalid_amount"),
         held_cents <- payment_held_cash_cents(payment_operation_id),
         :ok <- ensure_payment_reducible(operation, held_cents),
         :ok <- ensure_reduction_fits(operation, amount_cents, held_cents),
         :ok <- reduce_held_payment_cash(payment_operation_id, amount_cents) do
      updated = refresh_group_summary!(group, revision: group.revision + 1)

      {:ok,
       %{
         operation_id: operation_id(operation),
         status: "applied",
         payment_operation_id: payment_operation_id,
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp charge_back_payment(operation, group, payment_record) do
    payment_operation_id = payment_record.operation_id
    dispositions = payment_disposition_totals(payment_operation_id)
    chargeable_cents = chargeable_payment_cents(dispositions)

    cond do
      Map.get(dispositions, @charged_back, 0) > 0 ->
        {:reject, rejected(operation, "payment_not_chargeable")}

      chargeable_cents <= 0 ->
        {:reject, rejected(operation, "payment_not_chargeable")}

      true ->
        charge_back_payment_dispositions(payment_operation_id)
        revoke_converted_credit_entitlements(payment_operation_id)
        updated = refresh_group_summary!(group, revision: group.revision + 1)

        {:ok,
         %{
           operation_id: operation_id(operation),
           status: "applied",
           payment_operation_id: payment_operation_id,
           group_id: updated.group_id,
           charged_back_cents: chargeable_cents,
           outstanding_deposit_cents: outstanding_deposit_cents(updated),
           revision: updated.revision
         }}
    end
  end

  defp with_existing_group(operation, callback) do
    with :ok <- require_common_fields(operation),
         {:ok, group_id} <- fetch_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          {:reject, rejected(operation, "group_not_found")}

        group ->
          case ensure_fresh_revision(operation, group) do
            :ok -> callback.(group)
            {:reject, result} -> {:reject, result}
          end
      end
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp with_existing_payment_group(operation, invalid_payment_code, callback) do
    with :ok <- require_common_fields(operation),
         {:ok, payment_operation_id} <- fetch_string(operation, "payment_operation_id") do
      case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
        nil ->
          {:reject, rejected(operation, "operation_not_found")}

        payment_record ->
          with {:ok, payment_result} <-
                 payment_result(payment_record, operation, invalid_payment_code),
               {:ok, group_id} <-
                 payment_group_id(payment_result, operation, invalid_payment_code),
               %Group{} = group <- Repo.get_by(Group, group_id: group_id),
               :ok <- ensure_fresh_revision(operation, group) do
            callback.(group, payment_record)
          else
            nil -> {:reject, rejected(operation, "group_not_found")}
            {:reject, result} -> {:reject, result}
          end
      end
    else
      {:reject, result} -> {:reject, result}
    end
  end

  defp payment_result(payment_record, operation, invalid_payment_code) do
    case applied_cash_payment_result(payment_record) do
      {:ok, result} -> {:ok, result}
      :error -> {:reject, rejected(operation, invalid_payment_code)}
    end
  end

  defp payment_group_id(result, operation, invalid_payment_code) do
    case map_get(result, "group_id") do
      group_id when is_binary(group_id) and group_id != "" ->
        {:ok, group_id}

      _other ->
        {:reject, rejected(operation, invalid_payment_code)}
    end
  end

  defp require_common_fields(operation) do
    with {:ok, _operation_id} <- fetch_string(operation, "operation_id"),
         {:ok, _occurred_on} <- fetch_date(operation, "occurred_on", "invalid_operation") do
      :ok
    else
      {:reject, _result} -> {:reject, rejected(operation, "invalid_operation")}
    end
  end

  defp ensure_group_available(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :ok
      _group -> {:reject, rejected(operation, "group_already_exists")}
    end
  end

  defp ensure_fresh_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:reject,
         %{
           operation_id: operation_id(operation),
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp ensure_active(_operation, %Group{status: @active}), do: :ok

  defp ensure_active(operation, _group) do
    {:reject, rejected(operation, "group_not_active")}
  end

  defp ensure_payment_fits(_operation, _group, amount_cents, outstanding)
       when amount_cents <= outstanding do
    :ok
  end

  defp ensure_payment_fits(operation, _group, _amount_cents, _outstanding) do
    {:reject, rejected(operation, "payment_exceeds_outstanding")}
  end

  defp ensure_future_arrival(operation, _group, new_arrival_on, occurred_on) do
    cond do
      Date.compare(new_arrival_on, occurred_on) == :gt ->
        :ok

      true ->
        {:reject, rejected(operation, "invalid_stay")}
    end
  end

  defp ensure_credit_available(operation, guest_id, amount_cents, occurred_on) do
    lots = available_credit_lots(guest_id, occurred_on)
    available_cents = Enum.sum(Enum.map(lots, & &1.remaining_cents))

    if available_cents >= amount_cents do
      {:ok, lots}
    else
      {:reject, rejected(operation, "insufficient_credit")}
    end
  end

  defp ensure_refund_method_available(operation, @hotel_credit, false) do
    {:reject, rejected(operation, "refund_method_not_available")}
  end

  defp ensure_refund_method_available(_operation, _refund_method, _refundable), do: :ok

  defp ensure_payment_reducible(operation, held_cents) when held_cents <= 0 do
    {:reject, rejected(operation, "payment_not_reducible")}
  end

  defp ensure_payment_reducible(_operation, _held_cents), do: :ok

  defp ensure_reduction_fits(_operation, amount_cents, held_cents)
       when amount_cents <= held_cents do
    :ok
  end

  defp ensure_reduction_fits(operation, _amount_cents, _held_cents) do
    {:reject, rejected(operation, "reduction_exceeds_held_cash")}
  end

  defp fetch_active_rooms(operation, group) do
    case Map.fetch(operation, "room_ids") do
      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        active_room_ids =
          group
          |> active_rooms()
          |> Enum.map(& &1.room_id)

        distinct? = Enum.uniq(room_ids) == room_ids
        valid? = Enum.all?(room_ids, &(&1 in active_room_ids))

        if distinct? and valid? do
          selected = MapSet.new(room_ids)

          {:ok,
           group
           |> active_rooms()
           |> Enum.filter(&MapSet.member?(selected, &1.room_id))}
        else
          {:reject, rejected(operation, "invalid_rooms")}
        end

      _other ->
        {:reject, rejected(operation, "invalid_rooms")}
    end
  end

  defp allocate_cash_payment(group, payment_operation_id, amount_cents) do
    sequence = next_funding_sequence()

    group
    |> room_funding_chunks(amount_cents)
    |> Enum.reduce(sequence, fn {room, chunk_cents}, next_sequence ->
      Repo.insert!(%CashPaymentDisposition{
        reservation_id: group.id,
        room_id: room.id,
        payment_operation_id: payment_operation_id,
        disposition: @held,
        amount_cents: chunk_cents,
        sequence: next_sequence
      })

      next_sequence + 1
    end)

    :ok
  end

  defp allocate_hotel_credit(group, source_operation_id, lots, amount_cents) do
    sequence = next_funding_sequence()

    group
    |> room_funding_chunks(amount_cents)
    |> Enum.reduce({lots, sequence}, fn {room, chunk_cents}, {remaining_lots, next_sequence} ->
      allocate_credit_to_room(
        group,
        source_operation_id,
        room,
        chunk_cents,
        remaining_lots,
        next_sequence
      )
    end)

    :ok
  end

  defp allocate_credit_to_room(_group, _source_operation_id, _room, 0, lots, sequence) do
    {lots, sequence}
  end

  defp allocate_credit_to_room(
         group,
         source_operation_id,
         room,
         amount_cents,
         [lot | lots],
         sequence
       ) do
    consumed_cents = min(cents(lot.remaining_cents), amount_cents)

    if consumed_cents == 0 do
      allocate_credit_to_room(group, source_operation_id, room, amount_cents, lots, sequence)
    else
      lot
      |> change(remaining_cents: lot.remaining_cents - consumed_cents)
      |> Repo.update!()

      Repo.insert!(%RoomCreditAllocation{
        reservation_id: group.id,
        room_id: room.id,
        credit_lot_id: lot.id,
        source_operation_id: source_operation_id,
        amount_cents: consumed_cents,
        active: true,
        sequence: sequence
      })

      updated_lot = %{lot | remaining_cents: lot.remaining_cents - consumed_cents}
      remaining_cents = amount_cents - consumed_cents
      next_sequence = sequence + 1

      cond do
        remaining_cents == 0 ->
          {[updated_lot | lots], next_sequence}

        updated_lot.remaining_cents <= 0 ->
          allocate_credit_to_room(
            group,
            source_operation_id,
            room,
            remaining_cents,
            lots,
            next_sequence
          )

        true ->
          allocate_credit_to_room(
            group,
            source_operation_id,
            room,
            remaining_cents,
            [updated_lot | lots],
            next_sequence
          )
      end
    end
  end

  defp settle_selected_rooms(operation, group, rooms, refund_method, refundable, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)
    cash_rows = held_cash_rows_for_rooms(room_ids)
    settle_credit_allocations(room_ids, occurred_on, refundable)

    settlement =
      settle_cash_rows(operation, group, cash_rows, refund_method, refundable, occurred_on)

    Enum.each(rooms, fn room ->
      room
      |> change(status: @cancelled)
      |> Repo.update!()
    end)

    settlement
  end

  defp settle_cash_rows(operation, group, cash_rows, @hotel_credit, true, occurred_on) do
    cash_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    credit_issued_cents = credit_issued_cents(cash_cents)

    credit_lot =
      if credit_issued_cents > 0 do
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation_id(operation),
          remaining_cents: credit_issued_cents,
          expires_on: credit_expires_on(occurred_on),
          unrecovered_clawback_cents: 0
        })
      end

    if credit_lot do
      create_credit_lot_cash_sources(credit_lot, cash_rows)
    end

    update_cash_rows_disposition(cash_rows, @converted_to_credit, credit_lot)

    %{
      refunded_cents: 0,
      retained_cents: 0,
      credit_issued_cents: credit_issued_cents
    }
  end

  defp settle_cash_rows(_operation, _group, cash_rows, @cash, true, _occurred_on) do
    refunded_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    update_cash_rows_disposition(cash_rows, @refunded)

    %{
      refunded_cents: refunded_cents,
      retained_cents: 0,
      credit_issued_cents: 0
    }
  end

  defp settle_cash_rows(_operation, _group, cash_rows, @cash, false, _occurred_on) do
    retained_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    update_cash_rows_disposition(cash_rows, @retained)

    %{
      refunded_cents: 0,
      retained_cents: retained_cents,
      credit_issued_cents: 0
    }
  end

  defp settle_credit_allocations(room_ids, occurred_on, true) do
    room_ids
    |> active_credit_allocations_for_rooms()
    |> Enum.each(fn allocation ->
      allocation
      |> change(active: false)
      |> Repo.update!()

      restore_credit_to_lot(allocation.credit_lot_id, allocation.amount_cents, occurred_on)
    end)
  end

  defp settle_credit_allocations(room_ids, _occurred_on, false) do
    room_ids
    |> active_credit_allocations_for_rooms()
    |> Enum.each(fn allocation ->
      allocation
      |> change(active: false)
      |> Repo.update!()
    end)
  end

  defp restore_credit_to_lot(credit_lot_id, amount_cents, occurred_on) do
    lot = Repo.get!(CreditLot, credit_lot_id)
    absorbed_cents = min(cents(lot.unrecovered_clawback_cents), amount_cents)
    restorable_cents = amount_cents - absorbed_cents

    available_cents =
      if Date.compare(lot.expires_on, occurred_on) == :gt do
        restorable_cents
      else
        0
      end

    lot
    |> change(
      remaining_cents: cents(lot.remaining_cents) + available_cents,
      unrecovered_clawback_cents: cents(lot.unrecovered_clawback_cents) - absorbed_cents
    )
    |> Repo.update!()
  end

  defp update_cash_rows_disposition(rows, disposition, credit_lot \\ nil) do
    Enum.each(rows, fn row ->
      row
      |> change(
        disposition: disposition,
        credit_lot_id: credit_lot && credit_lot.id
      )
      |> Repo.update!()
    end)
  end

  defp create_credit_lot_cash_sources(credit_lot, cash_rows) do
    cash_rows
    |> credit_lot_source_principals()
    |> Enum.reduce({0, 1}, fn source, {previous_cash_cents, source_order} ->
      running_cash_cents = previous_cash_cents + source.cash_cents

      credit_cents =
        credit_issued_cents(running_cash_cents) - credit_issued_cents(previous_cash_cents)

      Repo.insert!(%CreditLotCashSource{
        credit_lot_id: credit_lot.id,
        payment_operation_id: source.payment_operation_id,
        cash_cents: source.cash_cents,
        credit_cents: credit_cents,
        source_order: source_order
      })

      {running_cash_cents, source_order + 1}
    end)

    :ok
  end

  defp credit_lot_source_principals(cash_rows) do
    Enum.reduce(cash_rows, [], fn row, sources ->
      case List.last(sources) do
        %{payment_operation_id: payment_operation_id, cash_cents: cash_cents}
        when payment_operation_id == row.payment_operation_id ->
          List.replace_at(sources, -1, %{
            payment_operation_id: payment_operation_id,
            cash_cents: cash_cents + row.amount_cents
          })

        _other ->
          sources ++
            [
              %{
                payment_operation_id: row.payment_operation_id,
                cash_cents: row.amount_cents
              }
            ]
      end
    end)
  end

  defp reduce_held_payment_cash(payment_operation_id, amount_cents) do
    payment_operation_id
    |> held_cash_rows_for_payment()
    |> Enum.reduce_while(amount_cents, fn row, remaining_cents ->
      reduced_cents = min(row.amount_cents, remaining_cents)

      if reduced_cents == row.amount_cents do
        row
        |> change(disposition: @reduced)
        |> Repo.update!()
      else
        row
        |> change(amount_cents: row.amount_cents - reduced_cents)
        |> Repo.update!()

        Repo.insert!(%CashPaymentDisposition{
          reservation_id: row.reservation_id,
          room_id: row.room_id,
          payment_operation_id: row.payment_operation_id,
          disposition: @reduced,
          amount_cents: reduced_cents,
          sequence: row.sequence
        })
      end

      case remaining_cents - reduced_cents do
        0 -> {:halt, 0}
        next_remaining_cents -> {:cont, next_remaining_cents}
      end
    end)

    :ok
  end

  defp charge_back_payment_dispositions(payment_operation_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.payment_operation_id == ^payment_operation_id)
    |> where(
      [disposition],
      disposition.disposition in [@held, @refunded, @retained, @converted_to_credit]
    )
    |> Repo.update_all(set: [disposition: @charged_back])

    :ok
  end

  defp revoke_converted_credit_entitlements(payment_operation_id) do
    CreditLotCashSource
    |> where([source], source.payment_operation_id == ^payment_operation_id)
    |> preload(:credit_lot)
    |> Repo.all()
    |> Enum.each(fn source ->
      lot = source.credit_lot
      removed_cents = min(cents(lot.remaining_cents), source.credit_cents)
      unrecovered_cents = source.credit_cents - removed_cents

      lot
      |> change(
        remaining_cents: cents(lot.remaining_cents) - removed_cents,
        unrecovered_clawback_cents: cents(lot.unrecovered_clawback_cents) + unrecovered_cents
      )
      |> Repo.update!()
    end)

    :ok
  end

  defp validate_stay(operation, arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:reject, rejected(operation, "invalid_stay")}
    end
  end

  defp validate_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        normalize_rooms(operation, rooms)

      _other ->
        {:reject, rejected(operation, "invalid_rooms")}
    end
  end

  defp normalize_rooms(operation, rooms) do
    normalized =
      Enum.reduce_while(rooms, [], fn room, acc ->
        with %{} <- room,
             {:ok, room_id} <- fetch_string(room, "room_id"),
             {:ok, nightly_rate_cents} <-
               fetch_positive_integer(room, "nightly_rate_cents", "invalid_rooms") do
          {:cont, [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents} | acc]}
        else
          _other -> {:halt, :invalid}
        end
      end)

    case normalized do
      :invalid ->
        {:reject, rejected(operation, "invalid_rooms")}

      rooms ->
        rooms = Enum.reverse(rooms)
        room_ids = Enum.map(rooms, & &1.room_id)

        if Enum.uniq(room_ids) == room_ids do
          {:ok, rooms}
        else
          {:reject, rejected(operation, "invalid_rooms")}
        end
    end
  end

  defp validate_rate_plan(operation) do
    case Map.get(operation, "rate_plan") do
      rate_plan when rate_plan in [@flexible, @advance_purchase] ->
        {:ok, rate_plan}

      _other ->
        {:reject, rejected(operation, "invalid_rate_plan")}
    end
  end

  defp calculate_totals(rooms, arrival_on, departure_on, rate_plan) do
    nights = Date.diff(departure_on, arrival_on)

    Enum.reduce(rooms, %{lodging_total_cents: 0, deposit_due_cents: 0, rooms: []}, fn room,
                                                                                      totals ->
      lodging_cents = room.nightly_rate_cents * nights
      deposit_cents = deposit_for_room(lodging_cents, rate_plan)

      room =
        Map.merge(room, %{lodging_total_cents: lodging_cents, deposit_due_cents: deposit_cents})

      %{
        lodging_total_cents: totals.lodging_total_cents + lodging_cents,
        deposit_due_cents: totals.deposit_due_cents + deposit_cents,
        rooms: totals.rooms ++ [room]
      }
    end)
  end

  defp deposit_for_room(lodging_cents, @flexible), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for_room(lodging_cents, @advance_purchase), do: lodging_cents

  defp refundable?(group, occurred_on) do
    case cancellation_window_days(group) do
      nil ->
        false

      window_days ->
        Date.compare(occurred_on, Date.add(group.arrival_on, -window_days)) != :gt
    end
  end

  defp cancellation_window_days(%Group{} = group) do
    case policy_version(group) do
      @flex_14 -> 14
      @flex_30 -> 30
      @advance_nonrefundable -> nil
      _unknown -> nil
    end
  end

  defp policy_version(%Group{policy_version: nil, rate_plan: rate_plan, booked_on: booked_on}) do
    policy_version_for(rate_plan, booked_on)
  end

  defp policy_version(%Group{policy_version: policy_version}), do: policy_version

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) in [:eq, :gt] do
      @flex_30
    else
      @flex_14
    end
  end

  defp refundable_until(%Group{} = group) do
    case cancellation_window_days(group) do
      nil -> nil
      window_days -> Date.add(group.arrival_on, -window_days)
    end
  end

  defp refundable_until_iso8601(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp credit_issued_cents(cash_cents) do
    cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp credit_expires_on(occurred_on), do: Date.add(occurred_on, 366)

  defp insert_group(attrs) do
    %Group{
      group_id: attrs.group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: attrs.booked_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      policy_version: attrs.policy_version,
      status: @active,
      lodging_total_cents: attrs.lodging_total_cents,
      deposit_due_cents: attrs.deposit_due_cents,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      cash_converted_to_credit_cents: 0,
      revision: 1
    }
    |> Repo.insert()
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        reservation_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position,
        status: @active,
        lodging_total_cents: room.lodging_total_cents,
        deposit_due_cents: room.deposit_due_cents
      })
    end)

    :ok
  end

  defp present_group(group) do
    room_cash_totals = cash_totals_by_room(group.id)
    room_credit_totals = credit_totals_by_room(group.id)
    totals = group_active_totals(group.id)

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
      refundable_until: refundable_until_iso8601(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room_status(room),
            lodging_total_cents: room_lodging_total_cents(room),
            deposit_due_cents: room_deposit_due_cents(room),
            cash_paid_cents: Map.get(room_cash_totals, room.id, 0),
            credit_paid_cents: Map.get(room_credit_totals, room.id, 0)
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents
    }
  end

  defp outstanding_deposit_cents(%Group{status: @active} = group) do
    group.id
    |> group_active_totals()
    |> Map.fetch!(:outstanding_deposit_cents)
  end

  defp outstanding_deposit_cents(%Group{}), do: 0

  defp refresh_group_summary!(group, opts) do
    totals = group_active_totals(group.id)
    settlement_totals = group_cash_settlement_totals(group.id)

    status =
      Keyword.get_lazy(opts, :status, fn ->
        if totals.deposit_due_cents == 0 and active_room_count(group.id) == 0 do
          @cancelled
        else
          group.status
        end
      end)

    group
    |> change(
      status: status,
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      cash_refunded_cents: Map.get(settlement_totals, @refunded, 0),
      cash_retained_cents: Map.get(settlement_totals, @retained, 0),
      cash_converted_to_credit_cents: Map.get(settlement_totals, @converted_to_credit, 0),
      revision: Keyword.get(opts, :revision, group.revision)
    )
    |> Repo.update!()
  end

  defp available_credit_lots(guest_id, on) do
    CreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp available_credit_liability_cents(on) do
    CreditLot
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on)
    |> select([lot], coalesce(sum(lot.remaining_cents), 0))
    |> Repo.one()
  end

  defp active_credit_allocation_total_cents do
    RoomCreditAllocation
    |> join(:inner, [allocation], group in Group, on: allocation.reservation_id == group.id)
    |> join(:inner, [allocation, _group], room in Room, on: allocation.room_id == room.id)
    |> where(
      [allocation, group, room],
      allocation.active == true and group.status == @active and room.status == @active
    )
    |> select([allocation, _group, _room], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_shortfall_cents do
    CreditLot
    |> Repo.all()
    |> Enum.map(fn lot ->
      active_cents =
        RoomCreditAllocation
        |> join(:inner, [allocation], group in Group, on: allocation.reservation_id == group.id)
        |> join(:inner, [allocation, _group], room in Room, on: allocation.room_id == room.id)
        |> where([allocation, group, room], allocation.credit_lot_id == ^lot.id)
        |> where(
          [allocation, group, room],
          allocation.active == true and group.status == @active and room.status == @active
        )
        |> select([allocation, _group, _room], coalesce(sum(allocation.amount_cents), 0))
        |> Repo.one()

      min(cents(lot.unrecovered_clawback_cents), active_cents)
    end)
    |> Enum.sum()
  end

  defp active_rooms(group) do
    Room
    |> where([room], room.reservation_id == ^group.id)
    |> where([room], room.status == ^@active)
    |> order_by([room], asc: room.position)
    |> Repo.all()
  end

  defp active_room_count(group_id) do
    Room
    |> where([room], room.reservation_id == ^group_id)
    |> where([room], room.status == ^@active)
    |> select([room], count(room.id))
    |> Repo.one()
  end

  defp room_funding_chunks(group, amount_cents) do
    {_remaining_cents, chunks} =
      group
      |> active_rooms()
      |> Enum.reduce_while({amount_cents, []}, fn room, {remaining_cents, chunks} ->
        if remaining_cents == 0 do
          {:halt, {0, chunks}}
        else
          available_cents = max(room_deposit_due_cents(room) - room_paid_cents(room.id), 0)
          chunk_cents = min(available_cents, remaining_cents)

          if chunk_cents > 0 do
            {:cont, {remaining_cents - chunk_cents, chunks ++ [{room, chunk_cents}]}}
          else
            {:cont, {remaining_cents, chunks}}
          end
        end
      end)

    chunks
  end

  defp room_paid_cents(room_id) do
    cash_paid_cents_for_room(room_id) + credit_paid_cents_for_room(room_id)
  end

  defp group_active_totals(group_id) do
    lodging_total_cents =
      Room
      |> where([room], room.reservation_id == ^group_id)
      |> where([room], room.status == ^@active)
      |> select([room], coalesce(sum(room.lodging_total_cents), 0))
      |> Repo.one()

    deposit_due_cents =
      Room
      |> where([room], room.reservation_id == ^group_id)
      |> where([room], room.status == ^@active)
      |> select([room], coalesce(sum(room.deposit_due_cents), 0))
      |> Repo.one()

    cash_paid_cents = cash_held_cents_for_group(group_id)
    credit_paid_cents = credit_paid_cents_for_group(group_id)
    deposit_paid_cents = cash_paid_cents + credit_paid_cents

    %{
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      deposit_paid_cents: deposit_paid_cents,
      outstanding_deposit_cents: max(deposit_due_cents - deposit_paid_cents, 0)
    }
  end

  defp group_cash_settlement_totals(group_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.reservation_id == ^group_id)
    |> where(
      [disposition],
      disposition.disposition in [@refunded, @retained, @converted_to_credit]
    )
    |> group_by([disposition], disposition.disposition)
    |> select(
      [disposition],
      {disposition.disposition, coalesce(sum(disposition.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp cash_totals_by_room(group_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.reservation_id == ^group_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> group_by([disposition, _room], disposition.room_id)
    |> select(
      [disposition, _room],
      {disposition.room_id, coalesce(sum(disposition.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp credit_totals_by_room(group_id) do
    RoomCreditAllocation
    |> join(:inner, [allocation], room in Room, on: allocation.room_id == room.id)
    |> where([allocation, room], allocation.reservation_id == ^group_id)
    |> where([allocation, room], allocation.active == true and room.status == ^@active)
    |> group_by([allocation, _room], allocation.room_id)
    |> select(
      [allocation, _room],
      {allocation.room_id, coalesce(sum(allocation.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp cash_held_cents_for_group(group_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.reservation_id == ^group_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> select([disposition, _room], coalesce(sum(disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_paid_cents_for_group(group_id) do
    RoomCreditAllocation
    |> join(:inner, [allocation], room in Room, on: allocation.room_id == room.id)
    |> where([allocation, room], allocation.reservation_id == ^group_id)
    |> where([allocation, room], allocation.active == true and room.status == ^@active)
    |> select([allocation, _room], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp cash_paid_cents_for_room(room_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.room_id == ^room_id)
    |> where([disposition], disposition.disposition == ^@held)
    |> select([disposition], coalesce(sum(disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp credit_paid_cents_for_room(room_id) do
    RoomCreditAllocation
    |> where([allocation], allocation.room_id == ^room_id)
    |> where([allocation], allocation.active == true)
    |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
    |> Repo.one()
  end

  defp cash_disposition_total(disposition) do
    CashPaymentDisposition
    |> where([cash_disposition], cash_disposition.disposition == ^disposition)
    |> select([cash_disposition], coalesce(sum(cash_disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp payment_disposition_totals(payment_operation_id) do
    CashPaymentDisposition
    |> where([disposition], disposition.payment_operation_id == ^payment_operation_id)
    |> group_by([disposition], disposition.disposition)
    |> select(
      [disposition],
      {disposition.disposition, coalesce(sum(disposition.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp payment_held_cash_cents(payment_operation_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.payment_operation_id == ^payment_operation_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> select([disposition, _room], coalesce(sum(disposition.amount_cents), 0))
    |> Repo.one()
  end

  defp held_cash_rows_for_payment(payment_operation_id) do
    CashPaymentDisposition
    |> join(:inner, [disposition], room in Room, on: disposition.room_id == room.id)
    |> where([disposition, room], disposition.payment_operation_id == ^payment_operation_id)
    |> where([disposition, room], disposition.disposition == ^@held and room.status == ^@active)
    |> order_by([disposition, _room], desc: disposition.sequence, desc: disposition.id)
    |> select([disposition, _room], disposition)
    |> Repo.all()
  end

  defp held_cash_rows_for_rooms(room_ids) do
    CashPaymentDisposition
    |> where([disposition], disposition.room_id in ^room_ids)
    |> where([disposition], disposition.disposition == ^@held)
    |> order_by([disposition], asc: disposition.sequence, asc: disposition.id)
    |> Repo.all()
  end

  defp active_credit_allocations_for_rooms(room_ids) do
    RoomCreditAllocation
    |> where([allocation], allocation.room_id in ^room_ids)
    |> where([allocation], allocation.active == true)
    |> order_by([allocation], asc: allocation.sequence, asc: allocation.id)
    |> Repo.all()
  end

  defp chargeable_payment_cents(dispositions) do
    Enum.sum([
      Map.get(dispositions, @held, 0),
      Map.get(dispositions, @refunded, 0),
      Map.get(dispositions, @retained, 0),
      Map.get(dispositions, @converted_to_credit, 0)
    ])
  end

  defp next_funding_sequence do
    cash_sequence =
      CashPaymentDisposition
      |> select([disposition], max(disposition.sequence))
      |> Repo.one()
      |> cents()

    credit_sequence =
      RoomCreditAllocation
      |> select([allocation], max(allocation.sequence))
      |> Repo.one()
      |> cents()

    max(cash_sequence, credit_sequence) + 1
  end

  defp room_status(%Room{status: nil}), do: @active
  defp room_status(%Room{status: status}), do: status

  defp room_lodging_total_cents(%Room{lodging_total_cents: nil}), do: 0
  defp room_lodging_total_cents(%Room{lodging_total_cents: cents}), do: cents(cents)

  defp room_deposit_due_cents(%Room{deposit_due_cents: nil}), do: 0
  defp room_deposit_due_cents(%Room{deposit_due_cents: cents}), do: cents(cents)

  defp sum_groups(field, filters \\ []) do
    Group
    |> where(^filters)
    |> select([g], coalesce(sum(field(g, ^field)), 0))
    |> Repo.one()
  end

  defp cents(nil), do: 0
  defp cents(value), do: value

  defp fetch_string(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:reject, rejected(map, "invalid_operation")}
    end
  end

  defp fetch_positive_integer(map, field, code) do
    case Map.fetch(map, field) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:reject, rejected(map, code)}
    end
  end

  defp fetch_date(map, field, code) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:reject, rejected(map, code)}
        end

      _other ->
        {:reject, rejected(map, code)}
    end
  end

  defp fetch_refund_method(operation) do
    case Map.get(operation, "refund_method", @cash) do
      refund_method when refund_method in [@cash, @hotel_credit] ->
        {:ok, refund_method}

      _other ->
        {:reject, rejected(operation, "invalid_operation")}
    end
  end

  defp reporting_date(nil), do: {:ok, Date.utc_today()}

  defp reporting_date(on) when is_binary(on) do
    case Date.from_iso8601(on) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_on}
    end
  end

  defp reporting_date(_on), do: {:error, :invalid_on}

  defp fetch_operation_id(operation), do: fetch_string(operation, "operation_id")

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp applied_cash_payment_result(%PartnerOperation{
         operation_type: "record_cash_payment",
         result: result
       })
       when is_map(result) do
    if map_get(result, "status") == "applied" and is_integer(map_get(result, "amount_cents")) do
      {:ok, result}
    else
      :error
    end
  end

  defp applied_cash_payment_result(_record), do: :error

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_existing_atom(key)
        Map.get(map, atom_key)
    end
  end

  defp rejected(operation, code) do
    %{
      operation_id: operation_id(operation),
      status: "rejected",
      code: code
    }
  end

  defp canonical_json(%{} = map) do
    encoded_pairs =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(value)
      end)

    "{" <> Enum.join(encoded_pairs, ",") <> "}"
  end

  defp canonical_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value) do
    Jason.encode!(value)
  end
end
