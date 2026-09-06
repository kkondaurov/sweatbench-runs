defmodule GroupStay.Reservations do
  @moduledoc """
  Domain operations for partner-managed group reservations.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditApplication, CreditLot, Group, PartnerOperation, Room}

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
        credit_liability_cents:
          available_credit_liability_cents(on) + active_credit_application_total_cents()
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

  defp apply_operation(%{"type" => "reschedule_group"} = operation) do
    with_existing_group(operation, fn group -> reschedule_group(operation, group) end)
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
         :ok <- insert_rooms(group, rooms) do
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
         :ok <- ensure_payment_fits(operation, group, amount_cents, outstanding) do
      updated =
        group
        |> change(
          deposit_paid_cents: deposit_paid_cents(group) + amount_cents,
          cash_paid_cents: cents(group.cash_paid_cents) + amount_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

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
         :ok <- consume_credit_lots(group, lots, amount_cents) do
      updated =
        group
        |> change(
          deposit_paid_cents: deposit_paid_cents(group) + amount_cents,
          credit_paid_cents: cents(group.credit_paid_cents) + amount_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

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
        cancellation_settlement(operation, group, refund_method, refundable, occurred_on)

      settle_credit_applications(group, occurred_on, refundable)

      updated =
        group
        |> change(
          status: @cancelled,
          cash_refunded_cents: cents(group.cash_refunded_cents) + settlement.refunded_cents,
          cash_retained_cents: cents(group.cash_retained_cents) + settlement.retained_cents,
          cash_converted_to_credit_cents:
            cents(group.cash_converted_to_credit_cents) +
              settlement.cash_converted_to_credit_cents,
          revision: group.revision + 1
        )
        |> Repo.update!()

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

  defp consume_credit_lots(group, lots, amount_cents) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining_cents ->
      if remaining_cents == 0 do
        {:halt, 0}
      else
        consumed_cents = min(lot.remaining_cents, remaining_cents)

        lot
        |> change(remaining_cents: lot.remaining_cents - consumed_cents)
        |> Repo.update!()

        Repo.insert!(%CreditApplication{
          reservation_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: consumed_cents,
          active: true
        })

        {:cont, remaining_cents - consumed_cents}
      end
    end)

    :ok
  end

  defp settle_credit_applications(group, occurred_on, true) do
    group
    |> active_credit_applications()
    |> Enum.each(fn application ->
      if Date.compare(application.credit_lot.expires_on, occurred_on) == :gt do
        CreditLot
        |> where(id: ^application.credit_lot_id)
        |> Repo.update_all(inc: [remaining_cents: application.amount_cents])
      end

      application
      |> change(active: false)
      |> Repo.update!()
    end)
  end

  defp settle_credit_applications(group, _occurred_on, false) do
    group
    |> active_credit_applications()
    |> Enum.each(fn application ->
      application
      |> change(active: false)
      |> Repo.update!()
    end)
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

    Enum.reduce(rooms, %{lodging_total_cents: 0, deposit_due_cents: 0}, fn room, totals ->
      lodging_cents = room.nightly_rate_cents * nights
      deposit_cents = deposit_for_room(lodging_cents, rate_plan)

      %{
        lodging_total_cents: totals.lodging_total_cents + lodging_cents,
        deposit_due_cents: totals.deposit_due_cents + deposit_cents
      }
    end)
  end

  defp deposit_for_room(lodging_cents, @flexible), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for_room(lodging_cents, @advance_purchase), do: lodging_cents

  defp cancellation_settlement(operation, group, @hotel_credit, true, occurred_on) do
    credit_issued_cents = credit_issued_cents(cents(group.cash_paid_cents))

    if credit_issued_cents > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id(operation),
        remaining_cents: credit_issued_cents,
        expires_on: credit_expires_on(occurred_on)
      })
    end

    %{
      refunded_cents: 0,
      retained_cents: 0,
      credit_issued_cents: credit_issued_cents,
      cash_converted_to_credit_cents: cents(group.cash_paid_cents)
    }
  end

  defp cancellation_settlement(_operation, group, @cash, true, _occurred_on) do
    %{
      refunded_cents: cents(group.cash_paid_cents),
      retained_cents: 0,
      credit_issued_cents: 0,
      cash_converted_to_credit_cents: 0
    }
  end

  defp cancellation_settlement(_operation, group, @cash, false, _occurred_on) do
    %{
      refunded_cents: 0,
      retained_cents: cents(group.cash_paid_cents),
      credit_issued_cents: 0,
      cash_converted_to_credit_cents: 0
    }
  end

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
        position: position
      })
    end)

    :ok
  end

  defp present_group(group) do
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
            nightly_rate_cents: room.nightly_rate_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: deposit_paid_cents(group),
      cash_paid_cents: cents(group.cash_paid_cents),
      credit_paid_cents: cents(group.credit_paid_cents),
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  defp outstanding_deposit_cents(%Group{status: @active} = group) do
    max(group.deposit_due_cents - deposit_paid_cents(group), 0)
  end

  defp outstanding_deposit_cents(%Group{}), do: 0

  defp deposit_paid_cents(group) do
    cents(group.cash_paid_cents) + cents(group.credit_paid_cents)
  end

  defp available_credit_lots(guest_id, on) do
    CreditLot
    |> where([lot], lot.guest_id == ^guest_id)
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp active_credit_applications(group) do
    CreditApplication
    |> where([application], application.reservation_id == ^group.id)
    |> where([application], application.active == true)
    |> preload(:credit_lot)
    |> Repo.all()
  end

  defp available_credit_liability_cents(on) do
    CreditLot
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on > ^on)
    |> select([lot], coalesce(sum(lot.remaining_cents), 0))
    |> Repo.one()
  end

  defp active_credit_application_total_cents do
    CreditApplication
    |> join(:inner, [application], group in Group, on: application.reservation_id == group.id)
    |> where([application, group], application.active == true and group.status == @active)
    |> select([application, _group], coalesce(sum(application.amount_cents), 0))
    |> Repo.one()
  end

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
