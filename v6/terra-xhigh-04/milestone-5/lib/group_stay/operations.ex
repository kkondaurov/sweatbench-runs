defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{Credits, Groups, PartnerOperations, RoomAccounting}
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @active "active"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)
  def process_batch(_operations), do: []

  def process(operation) when is_map(operation) do
    case operation_id(operation) do
      {:ok, operation_id} -> process_idempotently(operation, operation_id)
      :error -> process_domain(operation)
    end
  end

  def process(_operation), do: %{status: "rejected", code: "invalid_operation"}

  def get_result(operation_id) do
    case PartnerOperations.get(operation_id) do
      nil -> :error
      operation -> {:ok, operation.result}
    end
  end

  def payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    with record when not is_nil(record) <- PartnerOperations.get(payment_operation_id),
         {:ok, group_id, recorded_cents} <- applied_cash_payment(record) do
      {:ok,
       RoomAccounting.payment_statement(payment_operation_id)
       |> Map.merge(%{
         payment_operation_id: payment_operation_id,
         original_group_id: group_id,
         recorded_cents: recorded_cents
       })}
    else
      nil -> :error
      {:error, :not_reducible} -> {:error, :not_reconcilable}
    end
  end

  def payment_statement(_payment_operation_id), do: :error

  defp process_idempotently(operation, operation_id) do
    canonical_payload = canonical_json(operation)

    case transaction(fn ->
           case PartnerOperations.get(operation_id) do
             nil ->
               result = process_domain(operation)

               case PartnerOperations.record(%{
                      operation_id: operation_id,
                      operation_type: operation_type(operation),
                      payload: operation,
                      canonical_payload: canonical_payload,
                      result: result
                    }) do
                 {:ok, _record} -> result
                 {:error, changeset} -> retry_or_raise(changeset, :operation_id)
               end

             record ->
               if record.canonical_payload == canonical_payload do
                 record.result
               else
                 rejected(operation, "operation_id_conflict")
               end
           end
         end) do
      :retry -> process_idempotently(operation, operation_id)
      result -> result
    end
  end

  defp process_domain(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp process_domain(%{"type" => "record_cash_payment"} = operation),
    do: existing_group(operation, &record_cash_payment/3)

  defp process_domain(%{"type" => "reschedule_group"} = operation),
    do: existing_group(operation, &reschedule_group/3)

  defp process_domain(%{"type" => "cancel_group"} = operation),
    do: existing_group(operation, &cancel_group/3)

  defp process_domain(%{"type" => "apply_hotel_credit"} = operation),
    do: existing_group(operation, &apply_hotel_credit/3)

  defp process_domain(%{"type" => "cancel_rooms"} = operation),
    do: existing_group(operation, &cancel_rooms/3)

  defp process_domain(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp process_domain(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp process_domain(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp process_domain(operation), do: rejected(operation, "invalid_operation")

  defp open_group(operation) do
    with {:ok, common} <- common(operation),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, payload} <- open_payload(operation, common) do
      case Groups.get(group_id) do
        {:ok, _group} ->
          rejected(operation, "group_already_exists")

        :error ->
          case Groups.create(payload.group, payload.rooms) do
            {:ok, group} ->
              applied(operation, %{
                group_id: group.group_id,
                deposit_due_cents: group.deposit_due_cents,
                revision: group.revision
              })

            {:error, changeset} ->
              if unique_group_id_error?(changeset),
                do: rejected(operation, "group_already_exists"),
                else: raise(changeset)
          end
      end
    else
      :error -> rejected(operation, "invalid_operation")
      {:error, code} -> rejected(operation, code)
    end
  end

  defp existing_group(operation, handler) do
    case required_string(operation, "group_id") do
      :error ->
        rejected(operation, "invalid_operation")

      {:ok, group_id} ->
        case Groups.get(group_id) do
          :error ->
            rejected(operation, "group_not_found")

          {:ok, group} ->
            case ensure_expected_revision(operation, group) do
              :ok ->
                case common(operation) do
                  {:ok, %{occurred_on: occurred_on}} -> handler.(operation, group, occurred_on)
                  :error -> rejected(operation, "invalid_operation")
                end

              {:error, result} ->
                result
            end
        end
    end
  end

  defp record_cash_payment(operation, group, _occurred_on) do
    with true <- group.status == @active,
         {:ok, amount_cents} <- positive_integer(operation, "amount_cents") do
      outstanding = outstanding_deposit(group)

      if amount_cents <= outstanding do
        RoomAccounting.allocate_cash!(group, operation["operation_id"], amount_cents)

        case Groups.refresh_totals(group) do
          {:ok, updated_group} ->
            applied(operation, %{
              group_id: updated_group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents: outstanding_deposit(updated_group),
              revision: updated_group.revision
            })

          {:error, changeset} ->
            retry_or_raise(changeset)
        end
      else
        rejected(operation, "payment_exceeds_outstanding")
      end
    else
      false -> rejected(operation, "group_not_active")
      :error -> rejected(operation, "invalid_amount")
    end
  end

  defp reschedule_group(operation, group, occurred_on) do
    with true <- group.status == @active,
         {:ok, new_arrival_on} <- date(operation, "new_arrival_on"),
         :gt <- Date.compare(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      case Groups.update(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on}) do
        {:ok, updated_group} ->
          applied(operation, %{
            group_id: updated_group.group_id,
            new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
            new_departure_on: Date.to_iso8601(updated_group.departure_on),
            policy_version: policy_version(updated_group),
            refundable_until: refundable_until(updated_group),
            revision: updated_group.revision
          })

        {:error, changeset} ->
          retry_or_raise(changeset)
      end
    else
      false -> rejected(operation, "group_not_active")
      :error -> rejected(operation, "invalid_stay")
      _ -> rejected(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation, group, occurred_on) do
    with true <- group.status == @active,
         {:ok, refund_method} <- refund_method(operation) do
      settle_rooms(operation, group, occurred_on, refund_method, active_rooms(group), :group)
    else
      false -> rejected(operation, "group_not_active")
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp cancel_rooms(operation, group, occurred_on) do
    with true <- group.status == @active,
         {:ok, rooms} <- selected_active_rooms(operation, group) do
      case refund_method(operation) do
        {:ok, refund_method} ->
          settle_rooms(operation, group, occurred_on, refund_method, rooms, :rooms)

        :error ->
          rejected(operation, "invalid_operation")
      end
    else
      false -> rejected(operation, "group_not_active")
      :error -> rejected(operation, "invalid_rooms")
    end
  end

  defp apply_hotel_credit(operation, group, occurred_on) do
    with true <- group.status == @active,
         {:ok, amount_cents} <- positive_integer(operation, "amount_cents") do
      outstanding = outstanding_deposit(group)

      if amount_cents > outstanding do
        rejected(operation, "payment_exceeds_outstanding")
      else
        case Credits.consume!(group, amount_cents, occurred_on) do
          :ok ->
            case Groups.refresh_totals(group) do
              {:ok, updated_group} ->
                applied(operation, %{
                  group_id: updated_group.group_id,
                  amount_cents: amount_cents,
                  outstanding_deposit_cents: outstanding_deposit(updated_group),
                  revision: updated_group.revision
                })

              {:error, changeset} ->
                retry_or_raise(changeset)
            end

          {:error, :insufficient_credit} ->
            rejected(operation, "insufficient_credit")
        end
      end
    else
      false -> rejected(operation, "group_not_active")
      :error -> rejected(operation, "invalid_amount")
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, _operation_id} <- required_string(operation, "operation_id"),
         {:ok, source_group_id} <- required_string(operation, "source_group_id"),
         {:ok, destination_group_id} <- required_string(operation, "destination_group_id") do
      case Groups.get(source_group_id) do
        :error ->
          rejected(operation, "group_not_found", %{group_id: source_group_id})

        {:ok, source_group} ->
          case Groups.get(destination_group_id) do
            :error ->
              rejected(operation, "group_not_found", %{group_id: destination_group_id})

            {:ok, destination_group} ->
              with :ok <- ensure_expected_revision(operation, source_group),
                   :ok <-
                     ensure_expected_revision(
                       operation,
                       destination_group,
                       "destination_expected_revision"
                     ) do
                transfer_between_groups(operation, source_group, destination_group)
              else
                {:error, result} -> result
              end
          end
      end
    else
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp transfer_between_groups(operation, source_group, destination_group) do
    cond do
      source_group.status != @active ->
        rejected(operation, "group_not_active", %{group_id: source_group.group_id})

      destination_group.status != @active ->
        rejected(operation, "group_not_active", %{group_id: destination_group.group_id})

      source_group.id == destination_group.id or
          source_group.guest_id != destination_group.guest_id ->
        rejected(operation, "invalid_transfer")

      not match?({:ok, _}, positive_integer(operation, "amount_cents")) ->
        rejected(operation, "invalid_amount")

      true ->
        {:ok, amount_cents} = positive_integer(operation, "amount_cents")

        cond do
          amount_cents > RoomAccounting.held_funding_cents(source_group) ->
            rejected(operation, "transfer_exceeds_held_funding")

          amount_cents > outstanding_deposit(destination_group) ->
            rejected(operation, "transfer_exceeds_outstanding")

          true ->
            RoomAccounting.transfer_held_funding!(source_group, destination_group, amount_cents)

            with {:ok, updated_source_group} <- Groups.refresh_totals(source_group),
                 {:ok, updated_destination_group} <- Groups.refresh_totals(destination_group) do
              applied(operation, %{
                source_group_id: updated_source_group.group_id,
                destination_group_id: updated_destination_group.group_id,
                amount_cents: amount_cents,
                source_outstanding_deposit_cents: outstanding_deposit(updated_source_group),
                destination_outstanding_deposit_cents:
                  outstanding_deposit(updated_destination_group),
                source_revision: updated_source_group.revision,
                destination_revision: updated_destination_group.revision
              })
            else
              {:error, changeset} -> retry_or_raise(changeset)
            end
        end
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         record when not is_nil(record) <- PartnerOperations.get(payment_operation_id),
         {:ok, group_id, _recorded_cents} <- applied_cash_payment(record),
         {:ok, group} <- Groups.get(group_id),
         :ok <- ensure_expected_revision(operation, group),
         {:ok, amount_cents} <- positive_integer(operation, "amount_cents") do
      held_cents = RoomAccounting.held_cash_for_payment(payment_operation_id)

      cond do
        held_cents == 0 ->
          rejected(operation, "payment_not_reducible")

        amount_cents > held_cents ->
          rejected(operation, "reduction_exceeds_held_cash")

        true ->
          {_removed_cents, affected_group_ids} =
            RoomAccounting.reduce_payment!(payment_operation_id, amount_cents)

          {:ok, updated_group} = refresh_changed_groups(group, affected_group_ids)

          applied(operation, %{
            payment_operation_id: payment_operation_id,
            group_id: updated_group.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding_deposit(updated_group),
            revision: updated_group.revision
          })
      end
    else
      :error -> rejected(operation, "invalid_operation")
      nil -> rejected(operation, "operation_not_found")
      {:error, :not_reducible} -> rejected(operation, "payment_not_reducible")
      {:error, result} when is_map(result) -> result
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id"),
         record when not is_nil(record) <- PartnerOperations.get(payment_operation_id),
         {:ok, group_id, _recorded_cents} <- applied_cash_payment(record),
         {:ok, group} <- Groups.get(group_id),
         :ok <- ensure_expected_revision(operation, group) do
      {charged_back_cents, affected_group_ids} =
        RoomAccounting.charge_back_payment!(payment_operation_id)

      if charged_back_cents == 0 do
        rejected(operation, "payment_not_chargeable")
      else
        Credits.revoke_payment_entitlements!(payment_operation_id)

        {:ok, updated_group} = refresh_changed_groups(group, affected_group_ids)

        applied(operation, %{
          payment_operation_id: payment_operation_id,
          group_id: updated_group.group_id,
          charged_back_cents: charged_back_cents,
          outstanding_deposit_cents: outstanding_deposit(updated_group),
          revision: updated_group.revision
        })
      end
    else
      :error -> rejected(operation, "invalid_operation")
      nil -> rejected(operation, "operation_not_found")
      {:error, :not_reducible} -> rejected(operation, "payment_not_chargeable")
      {:error, result} when is_map(result) -> result
    end
  end

  defp settle_rooms(operation, group, occurred_on, refund_method, rooms, kind) do
    refundable = refundable?(group, occurred_on)

    if refund_method == "hotel_credit" and not refundable do
      rejected(operation, "refund_method_not_available")
    else
      held_cash_cents = RoomAccounting.held_cash_for_rooms(rooms)

      {credit_issued_cents, credit_lot} =
        if refundable and refund_method == "hotel_credit" do
          Credits.issue!(group.guest_id, operation["operation_id"], held_cash_cents, occurred_on)
        else
          {0, nil}
        end

      {cash_disposition, refunded_cents, retained_cents, converted_cents} =
        case {refundable, refund_method} do
          {true, "cash"} -> {"refunded", held_cash_cents, 0, 0}
          {true, "hotel_credit"} -> {"converted", 0, 0, held_cash_cents}
          {false, "cash"} -> {"retained", 0, held_cash_cents, 0}
        end

      {_settled_cash, cash_allocations} =
        RoomAccounting.settle_rooms_cash!(rooms, cash_disposition, credit_lot && credit_lot.id)

      if refundable do
        Credits.restore_rooms_credit!(rooms, occurred_on)
      else
        Credits.consume_rooms_credit!(rooms)
      end

      if credit_lot do
        Credits.record_entitlements!(credit_lot, cash_allocations)
      end

      room_ids = Enum.map(rooms, & &1.id)

      Repo.update_all(
        from(room in Room, where: room.id in ^room_ids),
        set: [status: "cancelled"]
      )

      attrs = %{
        status: if(Groups.active_room_count(group.id) == 0, do: "cancelled", else: @active),
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents
      }

      case Groups.refresh_totals(group, attrs) do
        {:ok, updated_group} ->
          result = %{
            group_id: updated_group.group_id,
            refunded_cents: refunded_cents,
            retained_cents: retained_cents,
            credit_issued_cents: credit_issued_cents,
            revision: updated_group.revision
          }

          result =
            if kind == :rooms,
              do: Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
              else: result

          applied(operation, result)

        {:error, changeset} ->
          retry_or_raise(changeset)
      end
    end
  end

  defp active_rooms(group), do: Enum.filter(group.rooms, &(&1.status == @active))

  defp selected_active_rooms(operation, group) do
    case Map.get(operation, "room_ids") do
      room_ids when is_list(room_ids) and room_ids != [] ->
        valid_ids = Enum.all?(room_ids, &(is_binary(&1) and byte_size(&1) > 0))

        selected =
          group.rooms
          |> Enum.filter(&(&1.room_id in room_ids))

        if valid_ids and length(room_ids) == length(Enum.uniq(room_ids)) and
             length(selected) == length(room_ids) and Enum.all?(selected, &(&1.status == @active)) do
          {:ok, selected}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp applied_cash_payment(record) do
    result = record.result

    if record.operation_type == "record_cash_payment" and
         result_value(result, :status) == "applied" and
         is_binary(result_value(result, :group_id)) and
         is_integer(result_value(result, :amount_cents)) do
      {:ok, result_value(result, :group_id), result_value(result, :amount_cents)}
    else
      {:error, :not_reducible}
    end
  end

  defp result_value(result, key), do: Map.get(result, Atom.to_string(key), Map.get(result, key))

  defp open_payload(operation, %{occurred_on: booked_on}) do
    with {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, arrival_on} <- opening_date(operation, "arrival_on"),
         {:ok, departure_on} <- opening_date(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation),
         {:ok, group_id} <- required_string(operation, "group_id") do
      nights = Date.diff(departure_on, arrival_on)

      room_totals =
        Enum.map(rooms, fn room ->
          lodging_cents = room.nightly_rate_cents * nights
          Map.put(room, :lodging_cents, lodging_cents)
        end)

      deposit_due_cents =
        Enum.reduce(room_totals, 0, fn room, total ->
          total + deposit_for(room.lodging_cents, rate_plan)
        end)

      {:ok,
       %{
         group: %{
           group_id: group_id,
           guest_id: guest_id,
           property_id: property_id,
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: rate_plan,
           policy_version: policy_version_for(rate_plan, booked_on),
           lodging_total_cents: Enum.sum(Enum.map(room_totals, & &1.lodging_cents)),
           deposit_due_cents: deposit_due_cents
         },
         rooms:
           Enum.map(room_totals, fn room ->
             %{
               room_id: room.room_id,
               nightly_rate_cents: room.nightly_rate_cents,
               status: @active,
               lodging_total_cents: room.lodging_cents,
               deposit_due_cents: deposit_for(room.lodging_cents, rate_plan),
               cash_paid_cents: 0,
               credit_paid_cents: 0
             }
           end)
       }}
    else
      false -> {:error, "invalid_stay"}
      :error -> {:error, "invalid_operation"}
      {:error, _} = error -> error
    end
  end

  defp common(operation) do
    with {:ok, _operation_id} <- required_string(operation, "operation_id"),
         {:ok, occurred_on} <- date(operation, "occurred_on") do
      {:ok, %{occurred_on: occurred_on}}
    else
      :error -> :error
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, "invalid_operation"}
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      {:ok, _} -> {:error, "invalid_rate_plan"}
    end
  end

  defp opening_date(operation, field) do
    with {:ok, value} <- Map.fetch(operation, field),
         true <- is_binary(value) and byte_size(value) > 0,
         {:ok, parsed_date} <- Date.from_iso8601(value) do
      {:ok, parsed_date}
    else
      :error -> {:error, "invalid_operation"}
      false -> {:error, "invalid_stay"}
      {:error, _} -> {:error, "invalid_stay"}
    end
  end

  defp rooms(operation) do
    case Map.fetch(operation, "rooms") do
      :error -> {:error, "invalid_operation"}
      {:ok, rooms} -> rooms_value(rooms)
    end
  end

  defp rooms_value(rooms) when is_list(rooms) and rooms != [] do
    parsed_rooms =
      Enum.map(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}
        when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(nightly_rate_cents) and
               nightly_rate_cents > 0 ->
          {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}}

        _ ->
          :error
      end)

    with true <- Enum.all?(parsed_rooms, &match?({:ok, _}, &1)),
         parsed_rooms <- Enum.map(parsed_rooms, fn {:ok, room} -> room end),
         room_ids <- Enum.map(parsed_rooms, & &1.room_id),
         true <- length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok, parsed_rooms}
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp rooms_value(_rooms), do: {:error, "invalid_rooms"}

  defp required_string(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp positive_integer(operation, field) do
    case Map.get(operation, field) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp date(operation, field) do
    with {:ok, value} <- required_string(operation, field),
         {:ok, parsed_date} <- Date.from_iso8601(value) do
      {:ok, parsed_date}
    else
      _ -> :error
    end
  end

  defp ensure_expected_revision(operation, group, field \\ "expected_revision") do
    if Map.has_key?(operation, field) and Map.get(operation, field) != group.revision do
      {:error,
       rejected(operation, "stale_revision", %{
         group_id: group.group_id,
         expected_revision: Map.get(operation, field),
         actual_revision: group.revision
       })}
    else
      :ok
    end
  end

  defp refundable?(group, occurred_on) do
    case policy_version(group) do
      @flex_14 -> Date.compare(occurred_on, Date.add(group.arrival_on, -14)) in [:lt, :eq]
      @flex_30 -> Date.compare(occurred_on, Date.add(group.arrival_on, -30)) in [:lt, :eq]
      @advance_nonrefundable -> false
    end
  end

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: @flex_14, else: @flex_30
  end

  defp policy_version(%{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(group), do: policy_version_for(group.rate_plan, group.booked_on)

  defp refundable_until(group) do
    case policy_version(group) do
      @flex_14 -> group.arrival_on |> Date.add(-14) |> Date.to_iso8601()
      @flex_30 -> group.arrival_on |> Date.add(-30) |> Date.to_iso8601()
      @advance_nonrefundable -> nil
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _ -> :error
    end
  end

  defp deposit_for(lodging_cents, @flexible), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, @advance_purchase), do: lodging_cents

  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp refresh_changed_groups(addressed_group, affected_group_ids) do
    group_ids =
      affected_group_ids
      |> MapSet.new()
      |> MapSet.put(addressed_group.id)
      |> MapSet.to_list()

    updated_groups =
      Enum.reduce(group_ids, %{}, fn group_id, groups ->
        group =
          if group_id == addressed_group.id do
            addressed_group
          else
            case Groups.get_by_id(group_id) do
              {:ok, group} -> group
              :error -> Repo.rollback(:retry)
            end
          end

        case Groups.refresh_totals(group) do
          {:ok, updated_group} -> Map.put(groups, group_id, updated_group)
          {:error, changeset} -> retry_or_raise(changeset)
        end
      end)

    {:ok, Map.fetch!(updated_groups, addressed_group.id)}
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation, attrs),
    do: Map.merge(%{operation_id: operation["operation_id"], status: "applied"}, attrs)

  defp rejected(operation, code, attrs \\ %{}) do
    base = %{status: "rejected", code: code}

    base =
      if is_binary(operation["operation_id"]),
        do: Map.put(base, :operation_id, operation["operation_id"]),
        else: base

    Map.merge(base, attrs)
  end

  defp operation_id(%{"operation_id" => operation_id}) when is_binary(operation_id),
    do: {:ok, operation_id}

  defp operation_id(_operation), do: :error

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp canonical_json(value) when is_map(value) do
    fields =
      value
      |> Enum.map(fn {key, nested_value} -> {to_string(key), canonical_json(nested_value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> nested_value
      end)

    "{" <> fields <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp retry_or_raise(changeset, retry_field \\ :revision) do
    if Keyword.has_key?(changeset.errors, retry_field),
      do: Repo.rollback(:retry),
      else: raise(changeset)
  end

  defp unique_group_id_error?(changeset), do: Keyword.has_key?(changeset.errors, :group_id)
end
