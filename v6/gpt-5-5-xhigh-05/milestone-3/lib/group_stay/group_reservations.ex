defmodule GroupStay.GroupReservations do
  import Ecto.Query

  alias GroupStay.GroupReservations.GroupReservation
  alias GroupStay.GroupReservations.HotelCreditApplication
  alias GroupStay.GroupReservations.HotelCreditLot
  alias GroupStay.GroupReservations.PartnerOperation
  alias GroupStay.Repo

  @active_status "active"
  @cancelled_status "cancelled"
  @flexible_rate_plan "flexible"
  @advance_purchase_rate_plan "advance_purchase"

  @cash_refund_method "cash"
  @hotel_credit_refund_method "hotel_credit"

  @flex_14_policy_version "flex-14"
  @flex_30_policy_version "flex-30"
  @advance_policy_version "advance-nonrefundable"
  @flex_30_cutover ~D[2027-01-01]

  def submit_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def submit_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) do
    GroupReservation
    |> Repo.get_by(group_id: group_id)
    |> Repo.preload(:rooms)
  end

  def group_payload(nil), do: nil

  def group_payload(%GroupReservation{} = group) do
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
      policy_version: policy_version,
      refundable_until: nullable_date(refundable_until(group, policy_version)),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: total_deposit_paid_cents(group),
      cash_paid_cents: cash_paid_cents(group),
      credit_paid_cents: credit_paid_cents(group),
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def ledger_totals(on_date \\ Date.utc_today()) do
    active_cash_query =
      from group in GroupReservation,
        where: group.status == ^@active_status,
        select: coalesce(sum(group.deposit_paid_cents), 0)

    refunded_query =
      from group in GroupReservation,
        select: coalesce(sum(group.refunded_cents), 0)

    retained_query =
      from group in GroupReservation,
        select: coalesce(sum(group.retained_cents), 0)

    converted_query =
      from group in GroupReservation,
        select: coalesce(sum(group.cash_converted_to_credit_cents), 0)

    %{
      cash_held_cents: Repo.one(active_cash_query),
      cash_refunded_cents: Repo.one(refunded_query),
      cash_retained_cents: Repo.one(retained_query),
      cash_converted_to_credit_cents: Repo.one(converted_query),
      credit_liability_cents: credit_liability_cents(on_date)
    }
  end

  def guest_credit_payload(guest_id, on_date \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: sum_field(lots, :remaining_cents),
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

  def get_operation_result(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> stored_result(operation)
    end
  end

  defp process_operation(operation) when is_map(operation) do
    case required_string(operation, "operation_id") do
      {:ok, operation_id} ->
        {:ok, result} =
          Repo.transaction(fn ->
            process_idempotent_operation(operation, operation_id)
          end)

        result

      :invalid_operation ->
        rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejection(nil, "invalid_operation")

  defp process_idempotent_operation(operation, operation_id) do
    payload_json = canonical_json(operation)

    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil ->
        remember_and_apply_operation(operation, operation_id, payload_json)

      partner_operation ->
        replay_or_reject_conflict(partner_operation, operation_id, payload_json)
    end
  end

  defp remember_and_apply_operation(operation, operation_id, payload_json) do
    attrs = %{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload_json: payload_json
    }

    case Repo.insert(PartnerOperation.create_changeset(%PartnerOperation{}, attrs)) do
      {:ok, partner_operation} ->
        result = apply_operation(operation)
        result_json = canonical_json(result)

        partner_operation
        |> PartnerOperation.result_changeset(%{result_json: result_json})
        |> Repo.update!()

        result

      {:error, changeset} ->
        if changeset_error?(changeset, :operation_id) do
          partner_operation = Repo.get_by!(PartnerOperation, operation_id: operation_id)
          replay_or_reject_conflict(partner_operation, operation_id, payload_json)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp replay_or_reject_conflict(partner_operation, operation_id, payload_json) do
    if partner_operation.payload_json == payload_json do
      stored_result(partner_operation)
    else
      rejection(operation_id, "operation_id_conflict")
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: with_existing_group(operation, &record_cash_payment(operation, &1))

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: with_existing_group(operation, &apply_hotel_credit(operation, &1))

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: with_existing_group(operation, &reschedule_group(operation, &1))

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: with_existing_group(operation, &cancel_group(operation, &1))

  defp apply_operation(operation), do: rejection(operation_id(operation), "invalid_operation")

  defp open_group(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, rate_plan} <- required_string(operation, "rate_plan"),
         :ok <- ensure_group_id_available(group_id),
         {:ok, booked_on} <- required_date(operation, "occurred_on"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay?(arrival_on, departure_on),
         {:ok, rooms} <- required_rooms(operation),
         {:ok, deposit_calculator} <- deposit_calculator(rate_plan) do
      night_count = Date.diff(departure_on, arrival_on)

      rooms_with_totals =
        Enum.map(rooms, fn room ->
          lodging_total = night_count * room.nightly_rate_cents
          Map.put(room, :lodging_total_cents, lodging_total)
        end)

      lodging_total_cents = sum_field(rooms_with_totals, :lodging_total_cents)
      deposit_due_cents = sum_deposits(rooms_with_totals, deposit_calculator)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version_for(rate_plan, booked_on),
        status: @active_status,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1,
        rooms:
          Enum.map(rooms, fn room ->
            %{
              position: room.position,
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents
            }
          end)
      }

      case Repo.insert(GroupReservation.create_changeset(%GroupReservation{}, attrs)) do
        {:ok, group} ->
          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            deposit_due_cents: group.deposit_due_cents,
            revision: group.revision
          }

        {:error, changeset} ->
          if changeset_error?(changeset, :group_id) do
            rejection(operation_id, "group_already_exists")
          else
            rejection(operation_id, "invalid_operation")
          end
      end
    else
      :group_already_exists -> rejection(operation_id(operation), "group_already_exists")
      :invalid_rate_plan -> rejection(operation_id(operation), "invalid_rate_plan")
      :invalid_rooms -> rejection(operation_id(operation), "invalid_rooms")
      :invalid_stay -> rejection(operation_id(operation), "invalid_stay")
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp record_cash_payment(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, amount_cents} <- required_integer(operation, "amount_cents"),
         :ok <- valid_payment_amount?(amount_cents),
         :ok <- payment_within_outstanding?(group, amount_cents) do
      new_outstanding = outstanding_deposit_cents(group) - amount_cents

      {:ok, updated_group} =
        Repo.update(
          GroupReservation.update_changeset(group, %{
            deposit_paid_cents: cash_paid_cents(group) + amount_cents,
            revision: group.revision + 1
          })
        )

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: new_outstanding,
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_amount -> rejection(operation_id, "invalid_amount")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :payment_exceeds_outstanding -> rejection(operation_id, "payment_exceeds_outstanding")
    end
  end

  defp apply_hotel_credit(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- required_integer(operation, "amount_cents"),
         :ok <- valid_payment_amount?(amount_cents),
         :ok <- payment_within_outstanding?(group, amount_cents),
         {:ok, lots} <- credit_lots_covering(group.guest_id, amount_cents, occurred_on) do
      consume_credit_lots(group, lots, amount_cents)

      {:ok, updated_group} =
        Repo.update(
          GroupReservation.update_changeset(group, %{
            credit_paid_cents: credit_paid_cents(group) + amount_cents,
            revision: group.revision + 1
          })
        )

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit_cents(group) - amount_cents,
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :insufficient_credit -> rejection(operation_id, "insufficient_credit")
      :invalid_amount -> rejection(operation_id, "invalid_amount")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
      :payment_exceeds_outstanding -> rejection(operation_id, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- new_arrival_after_occurrence?(new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      {:ok, updated_group} =
        Repo.update(
          GroupReservation.update_changeset(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          })
        )

      policy_version = policy_version(updated_group)

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
        new_departure_on: Date.to_iso8601(updated_group.departure_on),
        policy_version: policy_version,
        refundable_until: nullable_date(refundable_until(updated_group, policy_version)),
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
    end
  end

  defp cancel_group(operation, %GroupReservation{} = group) do
    operation_id = operation_id(operation)

    with :ok <- active_group?(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- refund_method_available?(group, occurred_on, refund_method) do
      refundable? = refundable_cancellation?(group, occurred_on)

      {refunded_cents, retained_cents, converted_cash_cents, credit_issued_cents} =
        cash_settlement(group, refund_method, refundable?)

      settle_applied_credit(group, occurred_on, refundable?)
      issue_hotel_credit(group, operation_id, occurred_on, credit_issued_cents)

      {:ok, updated_group} =
        Repo.update(
          GroupReservation.update_changeset(group, %{
            status: @cancelled_status,
            refunded_cents: group.refunded_cents + refunded_cents,
            retained_cents: group.retained_cents + retained_cents,
            cash_converted_to_credit_cents:
              group.cash_converted_to_credit_cents + converted_cash_cents,
            revision: group.revision + 1
          })
        )

      %{
        operation_id: operation_id,
        status: "applied",
        group_id: updated_group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: updated_group.revision
      }
    else
      :group_not_active -> rejection(operation_id, "group_not_active")
      :invalid_operation -> rejection(operation_id, "invalid_operation")
      :invalid_stay -> rejection(operation_id, "invalid_stay")
      :refund_method_not_available -> rejection(operation_id, "refund_method_not_available")
    end
  end

  defp with_existing_group(operation, callback) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case get_group(group_id) do
        nil ->
          rejection(operation_id, "group_not_found")

        group ->
          case expected_revision(operation) do
            {:ok, nil} ->
              callback.(group)

            {:ok, expected_revision} when expected_revision == group.revision ->
              callback.(group)

            {:ok, expected_revision} ->
              %{
                operation_id: operation_id,
                status: "rejected",
                code: "stale_revision",
                group_id: group_id,
                expected_revision: expected_revision,
                actual_revision: group.revision
              }

            :invalid_operation ->
              rejection(operation_id, "invalid_operation")
          end
      end
    else
      :invalid_operation -> rejection(operation_id(operation), "invalid_operation")
    end
  end

  defp ensure_group_id_available(group_id) do
    if Repo.exists?(from group in GroupReservation, where: group.group_id == ^group_id) do
      :group_already_exists
    else
      :ok
    end
  end

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :invalid_operation
    end
  end

  defp required_integer(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> :invalid_amount
      :error -> :invalid_operation
    end
  end

  defp required_date(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> :invalid_stay
        end

      {:ok, _value} ->
        :invalid_stay

      :error ->
        :invalid_operation
    end
  end

  defp valid_stay?(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      :invalid_stay
    end
  end

  defp new_arrival_after_occurrence?(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      :invalid_stay
    end
  end

  defp required_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      {:ok, rooms} when is_list(rooms) ->
        normalize_rooms(rooms)

      {:ok, _rooms} ->
        :invalid_rooms

      :error ->
        :invalid_operation
    end
  end

  defp normalize_rooms([]), do: :invalid_rooms

  defp normalize_rooms(rooms) do
    normalized =
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {room, position}, acc ->
        case normalize_room(room, position) do
          {:ok, normalized_room} -> {:cont, [normalized_room | acc]}
          :invalid_rooms -> {:halt, :invalid_rooms}
        end
      end)

    case normalized do
      :invalid_rooms ->
        :invalid_rooms

      normalized_rooms ->
        rooms_in_original_order = Enum.reverse(normalized_rooms)
        room_ids = Enum.map(rooms_in_original_order, & &1.room_id)

        if length(Enum.uniq(room_ids)) == length(room_ids) do
          {:ok, rooms_in_original_order}
        else
          :invalid_rooms
        end
    end
  end

  defp normalize_room(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    {:ok, %{position: position, room_id: room_id, nightly_rate_cents: nightly_rate_cents}}
  end

  defp normalize_room(_room, _position), do: :invalid_rooms

  defp deposit_calculator(@flexible_rate_plan), do: {:ok, &flexible_deposit_cents/1}
  defp deposit_calculator(@advance_purchase_rate_plan), do: {:ok, & &1}
  defp deposit_calculator(_rate_plan), do: :invalid_rate_plan

  defp flexible_deposit_cents(lodging_total_cents) do
    rounded_percentage_cents(lodging_total_cents, 20)
  end

  defp credit_bonus_cents(cash_cents) do
    rounded_percentage_cents(cash_cents, 10)
  end

  defp rounded_percentage_cents(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
  end

  defp sum_deposits(rooms, deposit_calculator) do
    Enum.reduce(rooms, 0, fn room, total ->
      total + deposit_calculator.(room.lodging_total_cents)
    end)
  end

  defp sum_field(records, field) do
    Enum.reduce(records, 0, fn record, total -> total + Map.fetch!(record, field) end)
  end

  defp active_group?(%GroupReservation{status: @active_status}), do: :ok
  defp active_group?(_group), do: :group_not_active

  defp valid_payment_amount?(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: :ok

  defp valid_payment_amount?(_amount_cents), do: :invalid_amount

  defp payment_within_outstanding?(group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      :payment_exceeds_outstanding
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", @cash_refund_method) do
      @cash_refund_method -> {:ok, @cash_refund_method}
      @hotel_credit_refund_method -> {:ok, @hotel_credit_refund_method}
      _value -> :invalid_operation
    end
  end

  defp refund_method_available?(group, occurred_on, @hotel_credit_refund_method) do
    if refundable_cancellation?(group, occurred_on) do
      :ok
    else
      :refund_method_not_available
    end
  end

  defp refund_method_available?(_group, _occurred_on, @cash_refund_method), do: :ok

  defp cash_settlement(group, @cash_refund_method, true) do
    {cash_paid_cents(group), 0, 0, 0}
  end

  defp cash_settlement(group, @hotel_credit_refund_method, true) do
    credit_issued_cents = cash_paid_cents(group) + credit_bonus_cents(cash_paid_cents(group))

    {0, 0, cash_paid_cents(group), credit_issued_cents}
  end

  defp cash_settlement(group, _refund_method, false) do
    {0, cash_paid_cents(group), 0, 0}
  end

  defp issue_hotel_credit(_group, _operation_id, _occurred_on, 0), do: :ok

  defp issue_hotel_credit(group, operation_id, occurred_on, credit_issued_cents) do
    %HotelCreditLot{}
    |> HotelCreditLot.changeset(%{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: credit_issued_cents,
      expires_on: Date.add(occurred_on, 365)
    })
    |> Repo.insert!()

    :ok
  end

  defp settle_applied_credit(group, occurred_on, true) do
    group
    |> applied_credit_applications()
    |> Enum.group_by(& &1.hotel_credit_lot_id)
    |> Enum.each(fn {_lot_id, applications} ->
      amount_cents = sum_field(applications, :amount_cents)
      lot = hd(applications).hotel_credit_lot

      if Date.compare(lot.expires_on, occurred_on) != :lt do
        lot
        |> HotelCreditLot.changeset(%{remaining_cents: lot.remaining_cents + amount_cents})
        |> Repo.update!()
      end
    end)

    :ok
  end

  defp settle_applied_credit(_group, _occurred_on, false), do: :ok

  defp credit_lots_covering(guest_id, amount_cents, on_date) do
    lots = available_credit_lots(guest_id, on_date)

    if sum_field(lots, :remaining_cents) >= amount_cents do
      {:ok, lots}
    else
      :insufficient_credit
    end
  end

  defp consume_credit_lots(group, lots, amount_cents) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining_cents ->
      amount_from_lot = min(lot.remaining_cents, remaining_cents)

      if amount_from_lot > 0 do
        lot
        |> HotelCreditLot.changeset(%{remaining_cents: lot.remaining_cents - amount_from_lot})
        |> Repo.update!()

        %HotelCreditApplication{}
        |> HotelCreditApplication.changeset(%{
          group_reservation_id: group.id,
          hotel_credit_lot_id: lot.id,
          amount_cents: amount_from_lot
        })
        |> Repo.insert!()
      end

      case remaining_cents - amount_from_lot do
        0 -> {:halt, 0}
        next_remaining_cents -> {:cont, next_remaining_cents}
      end
    end)

    :ok
  end

  defp available_credit_lots(guest_id, on_date) do
    HotelCreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on >= ^on_date)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
    |> Repo.all()
  end

  defp applied_credit_applications(group) do
    group
    |> Repo.preload(credit_applications: :hotel_credit_lot)
    |> Map.fetch!(:credit_applications)
  end

  defp credit_liability_cents(on_date) do
    available_credit_query =
      from lot in HotelCreditLot,
        where: lot.remaining_cents > 0,
        where: lot.expires_on >= ^on_date,
        select: coalesce(sum(lot.remaining_cents), 0)

    active_applied_credit_query =
      from application in HotelCreditApplication,
        join: group in assoc(application, :group_reservation),
        where: group.status == ^@active_status,
        select: coalesce(sum(application.amount_cents), 0)

    Repo.one(available_credit_query) + Repo.one(active_applied_credit_query)
  end

  defp refundable_cancellation?(%GroupReservation{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred_on, date) != :gt
    end
  end

  defp policy_version(%GroupReservation{policy_version: policy_version})
       when policy_version in [
              @flex_14_policy_version,
              @flex_30_policy_version,
              @advance_policy_version
            ],
       do: policy_version

  defp policy_version(%GroupReservation{} = group) do
    policy_version_for(group.rate_plan, group.booked_on)
  end

  defp policy_version_for(@flexible_rate_plan, booked_on) do
    if Date.compare(booked_on, @flex_30_cutover) == :lt do
      @flex_14_policy_version
    else
      @flex_30_policy_version
    end
  end

  defp policy_version_for(@advance_purchase_rate_plan, _booked_on), do: @advance_policy_version

  defp refundable_until(group), do: refundable_until(group, policy_version(group))

  defp refundable_until(group, @flex_14_policy_version), do: Date.add(group.arrival_on, -14)
  defp refundable_until(group, @flex_30_policy_version), do: Date.add(group.arrival_on, -30)
  defp refundable_until(_group, @advance_policy_version), do: nil

  defp nullable_date(nil), do: nil
  defp nullable_date(%Date{} = date), do: Date.to_iso8601(date)

  defp outstanding_deposit_cents(%GroupReservation{status: @cancelled_status}), do: 0

  defp outstanding_deposit_cents(%GroupReservation{} = group) do
    group.deposit_due_cents - total_deposit_paid_cents(group)
  end

  defp total_deposit_paid_cents(%GroupReservation{} = group) do
    cash_paid_cents(group) + credit_paid_cents(group)
  end

  defp cash_paid_cents(%GroupReservation{deposit_paid_cents: nil}), do: 0
  defp cash_paid_cents(%GroupReservation{deposit_paid_cents: cents}), do: cents

  defp credit_paid_cents(%GroupReservation{credit_paid_cents: nil}), do: 0
  defp credit_paid_cents(%GroupReservation{credit_paid_cents: cents}), do: cents

  defp expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> :invalid_operation
      :error -> {:ok, nil}
    end
  end

  defp stored_result(%PartnerOperation{result_json: result_json}) when is_binary(result_json) do
    Jason.decode!(result_json, keys: :atoms)
  end

  defp canonical_json(value) when is_map(value) do
    fields =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(",", fn {key, field_value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(field_value)
      end)

    "{" <> fields <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    items = Enum.map_join(value, ",", &canonical_json/1)
    "[" <> items <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _value -> nil
    end
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp rejection(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: code}
  end

  defp changeset_error?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end
end
