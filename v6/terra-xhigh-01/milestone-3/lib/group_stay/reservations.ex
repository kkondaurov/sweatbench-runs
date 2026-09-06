defmodule GroupStay.Reservations do
  @moduledoc """
  The group-deposit domain and its transactional partner operations.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    GroupCreditPayment,
    GroupReservation,
    GroupRoom,
    HotelCreditLot,
    PartnerOperation
  }

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @policy_change_on ~D[2027-01-01]
  @operation_retry_attempts 5

  @doc "Processes partner operations in their submitted order."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns a group in the API representation, or `nil` when it does not exist."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get_by(GroupReservation, partner_group_id: group_id) do
      nil -> nil
      group -> group_for_api(group)
    end
  end

  def fetch_group(_group_id), do: nil

  @doc "Returns the originally stored result for a partner operation, or `nil`."
  def fetch_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def fetch_operation(_operation_id), do: nil

  @doc "Returns the finance totals across all reservations, including unexpired credit liability."
  def ledger_totals(as_of \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        %{
          cash_held_cents:
            Repo.one(
              from group in GroupReservation,
                where: group.status == ^@active,
                select: coalesce(sum(group.deposit_paid_cents), 0)
            ),
          cash_refunded_cents:
            Repo.one(
              from(group in GroupReservation, select: coalesce(sum(group.cash_refunded_cents), 0))
            ),
          cash_retained_cents:
            Repo.one(
              from(group in GroupReservation, select: coalesce(sum(group.cash_retained_cents), 0))
            ),
          cash_converted_to_credit_cents:
            Repo.one(
              from(group in GroupReservation,
                select: coalesce(sum(group.cash_converted_to_credit_cents), 0)
              )
            ),
          credit_liability_cents: available_credit_total(as_of) + applied_credit_total()
        }
      end)

    totals
  end

  @doc "Returns a guest's unexpired, available hotel-credit lots as of a calendar date."
  def guest_credit(guest_id, as_of \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum_by(lots, & &1.remaining_cents),
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

  defp process_operation(operation) when is_map(operation) do
    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> process_durable_operation(operation, operation_id)
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: %{status: "rejected", code: "invalid_operation"}

  defp process_durable_operation(operation, operation_id, attempts \\ 0) do
    fingerprint = payload_fingerprint(operation)

    result =
      Repo.transaction(
        fn ->
          case Repo.get_by(PartnerOperation, operation_id: operation_id) do
            nil ->
              process_new_durable_operation(operation, operation_id, fingerprint)

            stored_operation ->
              replay_or_reject_conflict(stored_operation, operation_id, fingerprint)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, response} ->
        response

      {:error, :retry} when attempts < @operation_retry_attempts ->
        process_durable_operation(operation, operation_id, attempts + 1)

      {:error, :retry} ->
        raise "could not durably process partner operation #{inspect(operation_id)}"
    end
  end

  defp process_new_durable_operation(operation, operation_id, fingerprint) do
    case create_operation_record(operation, operation_id, fingerprint) do
      {:ok, stored_operation} ->
        case execute_domain_operation(operation, operation_id) do
          :retry ->
            Repo.rollback(:retry)

          result ->
            result = json_result(result)

            case finalize_operation_record(stored_operation, result) do
              {:ok, _updated_operation} -> result
              {:error, _changeset} -> Repo.rollback(:retry)
            end
        end

      {:error, _changeset} ->
        Repo.rollback(:retry)
    end
  end

  defp create_operation_record(operation, operation_id, fingerprint) do
    %PartnerOperation{}
    |> PartnerOperation.create_changeset(%{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      submitted_payload: operation,
      payload_fingerprint: fingerprint
    })
    |> Repo.insert()
  end

  defp finalize_operation_record(stored_operation, result) do
    stored_operation
    |> Ecto.Changeset.change(result: result)
    |> Repo.update()
  end

  defp replay_or_reject_conflict(stored_operation, operation_id, fingerprint) do
    if stored_operation.payload_fingerprint == fingerprint do
      stored_operation.result || raise "stored partner operation is missing its result"
    else
      %{
        operation_id: operation_id,
        status: "rejected",
        code: "operation_id_conflict"
      }
    end
  end

  # The operation record is deliberately created outside this savepoint. A handled rejection
  # discards every domain write, then commits that durable record and its original result.
  defp execute_domain_operation(operation, operation_id) do
    Repo.query!("SAVEPOINT partner_operation_domain")

    case apply_domain_operation(operation) do
      {:ok, attributes} ->
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
        Map.merge(%{operation_id: operation_id, status: "applied"}, attributes)

      {:rejected, code, attributes} ->
        rollback_domain_savepoint()
        rejected(operation, code, attributes)

      :retry ->
        rollback_domain_savepoint()
        :retry
    end
  end

  defp rollback_domain_savepoint do
    Repo.query!("ROLLBACK TO SAVEPOINT partner_operation_domain")
    Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
  end

  defp apply_domain_operation(operation) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      _ -> reject("invalid_operation")
    end
  end

  defp open_group(operation) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         false <-
           Repo.exists?(
             from(group in GroupReservation, where: group.partner_group_id == ^group_id)
           ),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on, departure_on} <- stay_dates(operation),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation),
         {:ok, lodging_total_cents, deposit_due_cents} <-
           totals(arrival_on, departure_on, rate_plan, rooms) do
      attributes = %{
        partner_group_id: group_id,
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
        outstanding_deposit_cents: deposit_due_cents,
        revision: 1
      }

      with {:ok, group} <-
             %GroupReservation{}
             |> GroupReservation.changeset(attributes)
             |> Repo.insert(),
           {:ok, _rooms} <- insert_rooms(group, rooms) do
        {:ok,
         %{
           group_id: group_id,
           deposit_due_cents: deposit_due_cents,
           revision: group.revision
         }}
      else
        {:error, changeset} ->
          if duplicate_group_id?(changeset),
            do: reject("group_already_exists", %{group_id: group_id}),
            else: reject("invalid_operation")
      end
    else
      true ->
        case required_string(operation, "group_id") do
          {:ok, group_id} -> reject("group_already_exists", %{group_id: group_id})
          :error -> reject("invalid_operation")
        end

      :error ->
        reject("invalid_operation")

      {:error, :invalid_stay} ->
        reject("invalid_stay")

      {:error, :invalid_rate_plan} ->
        reject("invalid_rate_plan")

      {:error, :invalid_rooms} ->
        reject("invalid_rooms")
    end
  end

  defp record_cash_payment(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, _occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, amount_cents} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount_cents),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               deposit_paid_cents: group.deposit_paid_cents + amount_cents,
               outstanding_deposit_cents: group.outstanding_deposit_cents - amount_cents
             }) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: updated_group.outstanding_deposit_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_amount} ->
          reject("invalid_amount", %{group_id: group.partner_group_id})

        {:error, :payment_exceeds_outstanding} ->
          reject("payment_exceeds_outstanding", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp reschedule_group(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, new_arrival_on} <- new_arrival_date(operation),
           :ok <- arrival_after_operation(new_arrival_on, occurred_on),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               arrival_on: new_arrival_on,
               departure_on:
                 Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))
             }) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
           new_departure_on: Date.to_iso8601(updated_group.departure_on),
           policy_version: group_policy_version(updated_group),
           refundable_until: refundable_until_for_api(updated_group),
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_stay} ->
          reject("invalid_stay", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp cancel_group(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, operation_id} <- required_string(operation, "operation_id"),
           {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, refund_method} <- refund_method(operation),
           {:ok, settlement} <- cancellation_settlement(group, occurred_on, refund_method),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               status: @cancelled,
               outstanding_deposit_cents: 0,
               cash_refunded_cents: group.cash_refunded_cents + settlement.refunded_cents,
               cash_retained_cents: group.cash_retained_cents + settlement.retained_cents,
               cash_converted_to_credit_cents:
                 group.cash_converted_to_credit_cents + settlement.cash_converted_cents
             }),
           :ok <- settle_applied_credit(group, occurred_on, settlement.refundable?),
           :ok <- issue_cancellation_credit(group, operation_id, occurred_on, settlement) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :refund_method_not_available} ->
          reject("refund_method_not_available", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp apply_hotel_credit(operation) do
    with_group_at_current_revision(operation, fn group, expected_revision ->
      with {:ok, occurred_on} <- operation_date(operation),
           :ok <- active(group),
           {:ok, amount_cents} <- payment_amount(operation),
           :ok <- payment_within_outstanding(group, amount_cents),
           {:ok, _payments} <- consume_hotel_credit(group, amount_cents, occurred_on),
           {:ok, updated_group} <-
             update_group(group, expected_revision, %{
               credit_paid_cents: group.credit_paid_cents + amount_cents,
               outstanding_deposit_cents: group.outstanding_deposit_cents - amount_cents
             }) do
        {:ok,
         %{
           group_id: group.partner_group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: updated_group.outstanding_deposit_cents,
           revision: updated_group.revision
         }}
      else
        :error ->
          reject("invalid_operation")

        {:error, :group_not_active} ->
          reject("group_not_active", %{group_id: group.partner_group_id})

        {:error, :invalid_amount} ->
          reject("invalid_amount", %{group_id: group.partner_group_id})

        {:error, :payment_exceeds_outstanding} ->
          reject("payment_exceeds_outstanding", %{group_id: group.partner_group_id})

        {:error, :insufficient_credit} ->
          reject("insufficient_credit", %{group_id: group.partner_group_id})

        {:error, {:stale_update, actual_revision}} ->
          stale_update_rejection(group, expected_revision, actual_revision)
      end
    end)
  end

  defp with_group_at_current_revision(operation, callback) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         %GroupReservation{} = group <- Repo.get_by(GroupReservation, partner_group_id: group_id),
         {:ok, expected_revision} <- expected_revision(operation),
         :ok <- revision_matches(group, expected_revision) do
      callback.(group, expected_revision)
    else
      nil ->
        case required_string(operation, "group_id") do
          {:ok, group_id} -> reject("group_not_found", %{group_id: group_id})
          :error -> reject("invalid_operation")
        end

      :error ->
        reject("invalid_operation")

      {:error, :stale_revision, group, expected_revision} ->
        reject("stale_revision", %{
          group_id: group.partner_group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })
    end
  end

  defp update_group(group, _expected_revision, attributes) do
    group
    |> Ecto.Changeset.change(attributes)
    |> Ecto.Changeset.optimistic_lock(:revision)
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        {:ok, updated_group}

      {:error, _changeset} ->
        actual_revision =
          Repo.one(
            from(current_group in GroupReservation,
              where: current_group.id == ^group.id,
              select: current_group.revision
            )
          ) || group.revision

        {:error, {:stale_update, actual_revision}}
    end
  end

  defp stale_update_rejection(group, expected_revision, actual_revision)
       when is_integer(expected_revision) do
    reject("stale_revision", %{
      group_id: group.partner_group_id,
      expected_revision: expected_revision,
      actual_revision: actual_revision
    })
  end

  defp stale_update_rejection(_group, nil, _actual_revision), do: :retry

  defp group_for_api(group) do
    rooms =
      Repo.all(
        from room in GroupRoom,
          where: room.group_reservation_id == ^group.id,
          order_by: [asc: room.position]
      )

    %{
      group_id: group.partner_group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms:
        Enum.map(rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.deposit_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents,
      policy_version: group_policy_version(group),
      refundable_until: refundable_until_for_api(group)
    }
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, inserted_rooms} ->
      attributes = %{
        group_reservation_id: group.id,
        position: position,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents
      }

      case Repo.insert(%GroupRoom{} |> Ecto.Changeset.change(attributes)) do
        {:ok, inserted_room} -> {:cont, {:ok, [inserted_room | inserted_rooms]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp totals(arrival_on, departure_on, rate_plan, rooms) do
    nights = Date.diff(departure_on, arrival_on)

    room_totals = Enum.map(rooms, fn room -> room.nightly_rate_cents * nights end)
    lodging_total_cents = Enum.sum(room_totals)

    deposit_due_cents =
      case rate_plan do
        @flexible -> Enum.sum(Enum.map(room_totals, &rounded_flexible_deposit/1))
        @advance_purchase -> lodging_total_cents
      end

    {:ok, lodging_total_cents, deposit_due_cents}
  end

  defp rounded_flexible_deposit(lodging_total_cents) do
    div(lodging_total_cents * 20 + 50, 100)
  end

  defp cancellation_settlement(group, occurred_on, refund_method) do
    refundable? = refundable?(group, occurred_on)

    cond do
      refund_method == :hotel_credit and not refundable? ->
        {:error, :refund_method_not_available}

      refundable? and refund_method == :hotel_credit ->
        {:ok,
         %{
           refundable?: true,
           refunded_cents: 0,
           retained_cents: 0,
           cash_converted_cents: group.deposit_paid_cents,
           credit_issued_cents: cash_credit_value(group.deposit_paid_cents)
         }}

      refundable? ->
        {:ok,
         %{
           refundable?: true,
           refunded_cents: group.deposit_paid_cents,
           retained_cents: 0,
           cash_converted_cents: 0,
           credit_issued_cents: 0
         }}

      true ->
        {:ok,
         %{
           refundable?: false,
           refunded_cents: 0,
           retained_cents: group.deposit_paid_cents,
           cash_converted_cents: 0,
           credit_issued_cents: 0
         }}
    end
  end

  defp cash_credit_value(0), do: 0

  defp cash_credit_value(cash_cents) do
    cash_cents + div(cash_cents * 10 + 50, 100)
  end

  defp issue_cancellation_credit(_group, _operation_id, _occurred_on, %{
         credit_issued_cents: 0
       }),
       do: :ok

  defp issue_cancellation_credit(group, operation_id, occurred_on, settlement) do
    attributes = %{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: settlement.credit_issued_cents,
      expires_on: Date.add(occurred_on, 366)
    }

    case Repo.insert(%HotelCreditLot{} |> Ecto.Changeset.change(attributes)) do
      {:ok, _lot} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp settle_applied_credit(group, occurred_on, refundable?) do
    payments =
      Repo.all(
        from payment in GroupCreditPayment,
          where: payment.group_reservation_id == ^group.id,
          order_by: [asc: payment.id]
      )

    payments
    |> Enum.reduce_while(:ok, fn payment, :ok ->
      case refundable? do
        true -> restore_credit_payment(payment, occurred_on)
        false -> {:cont, :ok}
      end
    end)
    |> case do
      :ok ->
        Repo.delete_all(
          from payment in GroupCreditPayment,
            where: payment.group_reservation_id == ^group.id
        )

        :ok

      :error ->
        :error
    end
  end

  defp restore_credit_payment(payment, occurred_on) do
    case Repo.get(HotelCreditLot, payment.hotel_credit_lot_id) do
      %HotelCreditLot{} = lot ->
        if Date.compare(lot.expires_on, occurred_on) == :gt do
          case Repo.update(
                 lot
                 |> Ecto.Changeset.change(%{
                   remaining_cents: lot.remaining_cents + payment.amount_cents
                 })
               ) do
            {:ok, _lot} -> {:cont, :ok}
            {:error, _changeset} -> {:halt, :error}
          end
        else
          {:cont, :ok}
        end

      nil ->
        {:cont, :ok}
    end
  end

  defp consume_hotel_credit(group, amount_cents, occurred_on) do
    lots = available_credit_lots(group.guest_id, occurred_on)

    if Enum.sum_by(lots, & &1.remaining_cents) < amount_cents do
      {:error, :insufficient_credit}
    else
      lots
      |> Enum.reduce_while({:ok, amount_cents, []}, fn lot, {:ok, remaining, payments} ->
        amount_from_lot = min(remaining, lot.remaining_cents)

        case consume_credit_lot(group, lot, amount_from_lot) do
          {:ok, payment} when remaining == amount_from_lot ->
            {:halt, {:ok, 0, [payment | payments]}}

          {:ok, payment} ->
            {:cont, {:ok, remaining - amount_from_lot, [payment | payments]}}

          :error ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, 0, payments} -> {:ok, Enum.reverse(payments)}
        :error -> :error
      end
    end
  end

  defp consume_credit_lot(group, lot, amount_cents) do
    with {:ok, _updated_lot} <-
           Repo.update(
             lot
             |> Ecto.Changeset.change(%{remaining_cents: lot.remaining_cents - amount_cents})
           ),
         {:ok, payment} <-
           Repo.insert(
             %GroupCreditPayment{}
             |> Ecto.Changeset.change(%{
               group_reservation_id: group.id,
               hotel_credit_lot_id: lot.id,
               amount_cents: amount_cents
             })
           ) do
      {:ok, payment}
    else
      {:error, _changeset} -> :error
    end
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in HotelCreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp available_credit_total(as_of) do
    Repo.one(
      from lot in HotelCreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
        select: coalesce(sum(lot.remaining_cents), 0)
    )
  end

  defp applied_credit_total do
    Repo.one(
      from payment in GroupCreditPayment,
        join: group in GroupReservation,
        on: group.id == payment.group_reservation_id,
        where: group.status == ^@active,
        select: coalesce(sum(payment.amount_cents), 0)
    )
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refundable_until(group) do
    case group_policy_version(group) do
      @flex_14 -> Date.add(group.arrival_on, -14)
      @flex_30 -> Date.add(group.arrival_on, -30)
      @advance_nonrefundable -> nil
    end
  end

  defp refundable_until_for_api(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp group_policy_version(%GroupReservation{policy_version: policy_version})
       when policy_version in [@flex_14, @flex_30, @advance_nonrefundable],
       do: policy_version

  defp group_policy_version(group), do: policy_version_for(group.rate_plan, group.booked_on)

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_change_on) == :lt, do: @flex_14, else: @flex_30
  end

  defp refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, :cash}
      {:ok, "cash"} -> {:ok, :cash}
      {:ok, "hotel_credit"} -> {:ok, :hotel_credit}
      {:ok, _refund_method} -> :error
    end
  end

  defp active(%GroupReservation{status: @active}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp payment_within_outstanding(group, amount_cents)
       when amount_cents <= group.outstanding_deposit_cents,
       do: :ok

  defp payment_within_outstanding(_group, _amount_cents),
    do: {:error, :payment_exceeds_outstanding}

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp revision_matches(_group, nil), do: :ok

  defp revision_matches(group, expected_revision) when group.revision == expected_revision,
    do: :ok

  defp revision_matches(group, expected_revision),
    do: {:error, :stale_revision, group, expected_revision}

  defp expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        {:ok, nil}

      {:ok, expected_revision} when is_integer(expected_revision) ->
        {:ok, expected_revision}

      {:ok, _expected_revision} ->
        :error
    end
  end

  defp operation_date(operation) do
    with {:ok, occurred_on} <- required_string(operation, "occurred_on"),
         {:ok, date} <- parse_date(occurred_on) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp stay_dates(operation) do
    with {:ok, arrival_on} <- required_string(operation, "arrival_on"),
         {:ok, departure_on} <- required_string(operation, "departure_on"),
         {:ok, arrival_on} <- parse_date(arrival_on),
         {:ok, departure_on} <- parse_date(departure_on),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp new_arrival_date(operation) do
    with {:ok, new_arrival_on} <- required_string(operation, "new_arrival_on"),
         {:ok, date} <- parse_date(new_arrival_on) do
      {:ok, date}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      {:ok, _rate_plan} -> {:error, :invalid_rate_plan}
      :error -> :error
    end
  end

  defp rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) and rooms != [] -> validate_rooms(rooms)
      {:ok, _rooms} -> {:error, :invalid_rooms}
      :error -> :error
    end
  end

  defp validate_rooms(rooms) do
    rooms
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn
      %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
      {:ok, room_ids, validated_rooms}
      when is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 ->
        if MapSet.member?(room_ids, room_id) do
          {:halt, {:error, :invalid_rooms}}
        else
          room = %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
          {:cont, {:ok, MapSet.put(room_ids, room_id), [room | validated_rooms]}}
        end

      _room, _validated ->
        {:halt, {:error, :invalid_rooms}}
    end)
    |> case do
      {:ok, _room_ids, validated_rooms} -> {:ok, Enum.reverse(validated_rooms)}
      {:error, :invalid_rooms} -> {:error, :invalid_rooms}
    end
  end

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, :invalid_amount}

      :error ->
        :error
    end
  end

  defp required_string(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  # JSON object keys are unordered, while arrays and scalar JSON values are not. Turning maps
  # into sorted tuples before encoding gives the same durable fingerprint for equivalent JSON
  # objects without treating an array reordering as a retry.
  defp payload_fingerprint(payload) do
    payload
    |> canonical_json_value()
    |> :erlang.term_to_binary()
  end

  defp canonical_json_value(value) when is_map(value) do
    {:object,
     value
     |> Enum.map(fn {key, nested_value} -> {key, canonical_json_value(nested_value)} end)
     |> Enum.sort_by(&elem(&1, 0))}
  end

  defp canonical_json_value(value) when is_list(value),
    do: {:array, Enum.map(value, &canonical_json_value/1)}

  defp canonical_json_value(value), do: {:scalar, value}

  defp json_result(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {json_key(key), json_result(nested_value)} end)
  end

  defp json_result(value) when is_list(value), do: Enum.map(value, &json_result/1)
  defp json_result(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key

  defp duplicate_group_id?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, options}} ->
      field == :partner_group_id and options[:constraint] == :unique
    end)
  end

  defp reject(code, attributes \\ %{}), do: {:rejected, code, attributes}

  defp rejected(operation, code, attributes \\ %{}) do
    base = Map.merge(%{status: "rejected", code: code}, attributes)

    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> Map.put(base, :operation_id, operation_id)
      :error -> base
    end
  end
end
