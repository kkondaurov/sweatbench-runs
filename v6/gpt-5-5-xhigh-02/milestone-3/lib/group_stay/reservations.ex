defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{AppliedHotelCredit, CreditLot, Group, PartnerOperation, Room}

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @cash "cash"
  @hotel_credit "hotel_credit"
  @flex_14 "flex-14"
  @flex_30 "flex-30"
  @advance_nonrefundable "advance-nonrefundable"
  @policy_cutover ~D[2027-01-01]

  def submit_partner_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &apply_operation/1)}
  end

  def submit_partner_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> where([group], group.group_id == ^group_id)
    |> preload_rooms()
    |> Repo.one()
  end

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      %PartnerOperation{result: result} -> result
    end
  end

  def ledger_totals(on_date \\ Date.utc_today()) do
    active_totals =
      from(group in Group,
        where: group.status == @active,
        select: coalesce(sum(group.cash_paid_cents), 0)
      )
      |> Repo.one()

    refunded_totals =
      from(group in Group,
        select: coalesce(sum(group.refunded_cents), 0)
      )
      |> Repo.one()

    retained_totals =
      from(group in Group,
        select: coalesce(sum(group.retained_cents), 0)
      )
      |> Repo.one()

    converted_totals =
      from(group in Group,
        select: coalesce(sum(group.cash_converted_to_credit_cents), 0)
      )
      |> Repo.one()

    available_credit_totals =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^on_date,
        select: coalesce(sum(lot.remaining_cents), 0)
      )
      |> Repo.one()

    active_applied_credit_totals =
      from(applied_credit in AppliedHotelCredit,
        join: group in assoc(applied_credit, :group),
        where: group.status == @active,
        select: coalesce(sum(applied_credit.amount_cents), 0)
      )
      |> Repo.one()

    %{
      cash_held_cents: active_totals,
      cash_refunded_cents: refunded_totals,
      cash_retained_cents: retained_totals,
      cash_converted_to_credit_cents: converted_totals,
      credit_liability_cents: available_credit_totals + active_applied_credit_totals
    }
  end

  def serialize_group(%Group{} = group) do
    policy_version = group_policy_version(group)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      policy_version: policy_version,
      refundable_until: serialize_date(refundable_until(group, policy_version)),
      rooms: Enum.map(group.rooms, &serialize_room/1),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid_cents(group),
      credit_paid_cents: credit_paid_cents(group),
      outstanding_deposit_cents: outstanding_deposit_cents(group)
    }
  end

  def guest_credit(guest_id, on_date) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &serialize_credit_lot/1)
    }
  end

  def report_date_from_params(%{"on" => on_date}) when is_binary(on_date) do
    case Date.from_iso8601(on_date) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def report_date_from_params(%{"on" => _on_date}), do: {:error, :invalid_date}

  def report_date_from_params(_params), do: {:ok, Date.utc_today()}

  defp serialize_room(%Room{} = room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents
    }
  end

  defp serialize_credit_lot(%CreditLot{} = credit_lot) do
    %{
      source_operation_id: credit_lot.source_operation_id,
      remaining_cents: credit_lot.remaining_cents,
      expires_on: Date.to_iso8601(credit_lot.expires_on)
    }
  end

  defp apply_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case reserve_operation(operation) do
          {:new, partner_operation} ->
            result =
              operation
              |> apply_domain_operation()
              |> normalize_json()

            partner_operation
            |> PartnerOperation.result_changeset(%{result: result})
            |> Repo.update!()

            result

          {:stored, result} ->
            result

          :conflict ->
            reject(operation_id, :operation_id_conflict)

          {:invalid, result} ->
            result
        end
      end)

    result
  end

  defp apply_operation(operation) do
    reject(operation_id_from(operation), :invalid_operation)
  end

  defp reserve_operation(operation) do
    payload = normalize_json(operation)

    attrs = %{
      operation_id: operation["operation_id"],
      operation_type: operation_type_from(operation),
      payload: payload
    }

    case Repo.insert(PartnerOperation.create_changeset(%PartnerOperation{}, attrs),
           mode: :savepoint
         ) do
      {:ok, partner_operation} ->
        {:new, partner_operation}

      {:error, changeset} ->
        if has_unique_operation_error?(changeset) do
          resolve_existing_operation(operation, payload)
        else
          {:invalid, reject(operation["operation_id"], :invalid_operation)}
        end
    end
  end

  defp resolve_existing_operation(operation, payload) do
    case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
      %PartnerOperation{payload: ^payload, result: result} when not is_nil(result) ->
        {:stored, result}

      %PartnerOperation{payload: ^payload, result: nil} ->
        raise "operation #{operation["operation_id"]} has no stored result"

      %PartnerOperation{} ->
        :conflict

      nil ->
        raise "operation #{operation["operation_id"]} conflicted without a stored record"
    end
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "open_group"} = operation
       )
       when is_binary(operation_id) do
    operation_result(open_group(operation))
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "record_cash_payment"} = operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           :ok <- require_common_operation_date(operation),
           {:ok, amount_cents} <- fetch_payment_amount_value(operation),
           :ok <- ensure_usable_payment_amount(operation, amount_cents),
           :ok <- ensure_payment_within_outstanding(operation, group, amount_cents) do
        apply_cash_payment(operation, group, amount_cents)
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "apply_hotel_credit"} = operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, amount_cents} <- fetch_payment_amount_value(operation),
           :ok <- ensure_usable_payment_amount(operation, amount_cents),
           :ok <- ensure_payment_within_outstanding(operation, group, amount_cents),
           {:ok, credit_lots} <-
             fetch_covering_credit_lots(operation, group.guest_id, amount_cents, occurred_on) do
        apply_hotel_credit(operation, group, amount_cents, credit_lots)
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "reschedule_group"} = operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, new_arrival_on} <- fetch_date(operation, "new_arrival_on", :invalid_stay),
           :ok <- ensure_new_arrival_after_operation(operation, new_arrival_on, occurred_on) do
        reschedule_group(operation, group, new_arrival_on)
      end
    )
  end

  defp apply_domain_operation(
         %{"operation_id" => operation_id, "type" => "cancel_group"} = operation
       )
       when is_binary(operation_id) do
    operation_result(
      with {:ok, group} <- fetch_addressed_group(operation),
           :ok <- check_expected_revision(operation, group),
           :ok <- ensure_active(operation, group),
           {:ok, occurred_on} <- fetch_operation_date(operation),
           {:ok, refund_method} <- fetch_refund_method(operation),
           :ok <- ensure_refund_method_available(operation, group, occurred_on, refund_method) do
        cancel_group(operation, group, occurred_on, refund_method)
      end
    )
  end

  defp apply_domain_operation(operation) do
    reject(operation_id_from(operation), :invalid_operation)
  end

  defp operation_result({:ok, result}), do: result
  defp operation_result({:error, result}), do: result

  defp open_group(operation) do
    with {:ok, group_id} <- fetch_string(operation, "group_id"),
         {:ok, guest_id} <- fetch_string(operation, "guest_id"),
         {:ok, property_id} <- fetch_string(operation, "property_id"),
         {:ok, booked_on} <- fetch_operation_date(operation),
         {:ok, arrival_on} <- fetch_date(operation, "arrival_on", :invalid_stay),
         {:ok, departure_on} <- fetch_date(operation, "departure_on", :invalid_stay),
         :ok <- ensure_valid_stay(operation, arrival_on, departure_on),
         {:ok, rate_plan} <- fetch_rate_plan(operation),
         {:ok, rooms} <- build_rooms(operation, arrival_on, departure_on, rate_plan),
         :ok <- ensure_group_available(operation, group_id) do
      lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_amount_cents))
      deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
      policy_version = policy_version_for(rate_plan, booked_on)

      group_attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: @active,
        revision: 1,
        policy_version: policy_version,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0
      }

      case Repo.insert(Group.changeset(%Group{}, group_attrs), mode: :savepoint) do
        {:ok, group} ->
          insert_rooms(group, rooms)

          {:ok,
           %{
             operation_id: operation["operation_id"],
             status: "applied",
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}

        {:error, changeset} ->
          if has_unique_group_error?(changeset) do
            {:error, reject(operation["operation_id"], :group_already_exists)}
          else
            {:error, reject(operation["operation_id"], :invalid_operation)}
          end
      end
    end
  end

  defp apply_cash_payment(operation, group, amount_cents) do
    new_paid_cents = group.deposit_paid_cents + amount_cents
    new_cash_paid_cents = cash_paid_cents(group) + amount_cents
    revision = group.revision + 1

    group
    |> Group.changeset(%{
      deposit_paid_cents: new_paid_cents,
      cash_paid_cents: new_cash_paid_cents,
      revision: revision
    })
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
           revision: updated_group.revision
         }}

      {:error, _changeset} ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp apply_hotel_credit(operation, group, amount_cents, credit_lots) do
    new_paid_cents = group.deposit_paid_cents + amount_cents
    new_credit_paid_cents = credit_paid_cents(group) + amount_cents
    revision = group.revision + 1

    with :ok <- consume_credit_lots(operation, group, credit_lots, amount_cents) do
      updated_group =
        group
        |> Group.changeset(%{
          deposit_paid_cents: new_paid_cents,
          credit_paid_cents: new_credit_paid_cents,
          revision: revision
        })
        |> Repo.update!()

      {:ok,
       %{
         operation_id: operation["operation_id"],
         status: "applied",
         group_id: updated_group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding_deposit_cents(updated_group),
         revision: updated_group.revision
       }}
    end
  end

  defp reschedule_group(operation, group, new_arrival_on) do
    stay_length_days = Date.diff(group.departure_on, group.arrival_on)
    new_departure_on = Date.add(new_arrival_on, stay_length_days)
    revision = group.revision + 1

    group
    |> Group.changeset(%{
      arrival_on: new_arrival_on,
      departure_on: new_departure_on,
      revision: revision
    })
    |> Repo.update()
    |> case do
      {:ok, updated_group} ->
        policy_version = group_policy_version(updated_group)

        {:ok,
         %{
           operation_id: operation["operation_id"],
           status: "applied",
           group_id: updated_group.group_id,
           new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
           new_departure_on: Date.to_iso8601(updated_group.departure_on),
           policy_version: policy_version,
           refundable_until: serialize_date(refundable_until(updated_group, policy_version)),
           revision: updated_group.revision
         }}

      {:error, _changeset} ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp cancel_group(operation, group, occurred_on, refund_method) do
    settlement = cancellation_settlement(group, occurred_on, refund_method)
    revision = group.revision + 1

    attrs = %{
      status: @cancelled,
      revision: revision,
      refunded_cents: group.refunded_cents + settlement.refunded_cents,
      retained_cents: group.retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.cash_converted_to_credit_cents
    }

    with :ok <-
           maybe_restore_applied_credit(group, occurred_on, settlement.refundable?),
         {:ok, _credit_lot} <-
           maybe_issue_credit_lot(operation, group, settlement.credit_issued_cents, occurred_on) do
      updated_group = group |> Group.changeset(attrs) |> Repo.update!()

      {:ok,
       %{
         operation_id: operation["operation_id"],
         status: "applied",
         group_id: updated_group.group_id,
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: updated_group.revision
       }}
    end
  end

  defp cancellation_settlement(group, occurred_on, @cash) do
    if refundable?(group, occurred_on) do
      %{
        refundable?: true,
        refunded_cents: cash_paid_cents(group),
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        credit_issued_cents: 0
      }
    else
      %{
        refundable?: false,
        refunded_cents: 0,
        retained_cents: cash_paid_cents(group),
        cash_converted_to_credit_cents: 0,
        credit_issued_cents: 0
      }
    end
  end

  defp cancellation_settlement(group, occurred_on, @hotel_credit) do
    credit_issued_cents = credit_issued_cents(cash_paid_cents(group))

    %{
      refundable?: refundable?(group, occurred_on),
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: cash_paid_cents(group),
      credit_issued_cents: credit_issued_cents
    }
  end

  defp maybe_issue_credit_lot(_operation, _group, 0, _occurred_on), do: {:ok, nil}

  defp maybe_issue_credit_lot(operation, group, credit_issued_cents, occurred_on) do
    credit_lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        issued_on: occurred_on,
        original_cents: credit_issued_cents,
        remaining_cents: credit_issued_cents,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert!()

    {:ok, credit_lot}
  end

  defp maybe_restore_applied_credit(_group, _occurred_on, false), do: :ok

  defp maybe_restore_applied_credit(group, occurred_on, true) do
    group
    |> applied_credit_for_group()
    |> Enum.reduce_while(:ok, fn applied_credit, :ok ->
      credit_lot = applied_credit.credit_lot

      if Date.compare(credit_lot.expires_on, occurred_on) == :lt do
        {:cont, :ok}
      else
        credit_lot
        |> CreditLot.changeset(%{
          remaining_cents: credit_lot.remaining_cents + applied_credit.amount_cents
        })
        |> Repo.update!()

        {:cont, :ok}
      end
    end)
  end

  defp applied_credit_for_group(group) do
    AppliedHotelCredit
    |> where([applied_credit], applied_credit.group_pk_id == ^group.id)
    |> join(:inner, [applied_credit], credit_lot in assoc(applied_credit, :credit_lot))
    |> order_by([_applied_credit, credit_lot],
      asc: credit_lot.expires_on,
      asc: credit_lot.source_operation_id
    )
    |> preload([_applied_credit, credit_lot], credit_lot: credit_lot)
    |> Repo.all()
  end

  defp insert_rooms(group, rooms) do
    Enum.each(rooms, fn room_attrs ->
      attrs = Map.put(room_attrs, :group_pk_id, group.id)

      %Room{}
      |> Room.changeset(attrs)
      |> Repo.insert!()
    end)
  end

  defp consume_credit_lots(operation, group, credit_lots, amount_cents) do
    remaining_amount =
      Enum.reduce_while(credit_lots, amount_cents, fn credit_lot, amount_left ->
        cond do
          amount_left == 0 ->
            {:halt, 0}

          credit_lot.remaining_cents == 0 ->
            {:cont, amount_left}

          true ->
            amount_to_apply = min(amount_left, credit_lot.remaining_cents)

            credit_lot
            |> CreditLot.changeset(%{
              remaining_cents: credit_lot.remaining_cents - amount_to_apply
            })
            |> Repo.update!()

            %AppliedHotelCredit{}
            |> AppliedHotelCredit.changeset(%{
              group_pk_id: group.id,
              hotel_credit_lot_id: credit_lot.id,
              amount_cents: amount_to_apply
            })
            |> Repo.insert!()

            {:cont, amount_left - amount_to_apply}
        end
      end)

    case remaining_amount do
      0 -> :ok
      _amount_left -> {:error, reject(operation["operation_id"], :insufficient_credit)}
    end
  end

  defp fetch_addressed_group(operation) do
    with {:ok, group_id} <- fetch_string(operation, "group_id") do
      case get_group(group_id) do
        nil -> {:error, reject(operation["operation_id"], :group_not_found)}
        group -> {:ok, group}
      end
    end
  end

  defp check_expected_revision(operation, %Group{} = group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:error,
         %{
           operation_id: operation["operation_id"],
           status: "rejected",
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected_revision,
           actual_revision: group.revision
         }}
    end
  end

  defp require_common_operation_date(operation) do
    case fetch_operation_date(operation) do
      {:ok, _date} -> :ok
      {:error, result} -> {:error, result}
    end
  end

  defp fetch_operation_date(operation) do
    fetch_date(operation, "occurred_on", :invalid_operation)
  end

  defp fetch_date(operation, key, code) do
    case fetch_string(operation, key) do
      {:ok, value} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, reject(operation["operation_id"], code)}
        end

      {:error, result} ->
        {:error, result}
    end
  end

  defp fetch_string(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp fetch_rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      {:ok, @flexible} -> {:ok, @flexible}
      {:ok, @advance_purchase} -> {:ok, @advance_purchase}
      _ -> {:error, reject(operation["operation_id"], :invalid_rate_plan)}
    end
  end

  defp fetch_refund_method(operation) do
    case Map.get(operation, "refund_method", @cash) do
      @cash -> {:ok, @cash}
      @hotel_credit -> {:ok, @hotel_credit}
      _refund_method -> {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp build_rooms(operation, arrival_on, departure_on, rate_plan) do
    with {:ok, rooms} when is_list(rooms) and rooms != [] <- Map.fetch(operation, "rooms"),
         true <- unique_room_ids?(rooms),
         nights when nights > 0 <- Date.diff(departure_on, arrival_on) do
      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, built_rooms} ->
        case build_room(room, position, nights, rate_plan) do
          {:ok, built_room} -> {:cont, {:ok, [built_room | built_rooms]}}
          :error -> {:halt, {:error, reject(operation["operation_id"], :invalid_rooms)}}
        end
      end)
      |> case do
        {:ok, built_rooms} -> {:ok, Enum.reverse(built_rooms)}
        error -> error
      end
    else
      _ -> {:error, reject(operation["operation_id"], :invalid_rooms)}
    end
  end

  defp build_room(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position,
         nights,
         rate_plan
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    lodging_amount_cents = nightly_rate_cents * nights

    {:ok,
     %{
       room_id: room_id,
       position: position,
       nightly_rate_cents: nightly_rate_cents,
       lodging_amount_cents: lodging_amount_cents,
       deposit_due_cents: room_deposit_due_cents(lodging_amount_cents, rate_plan)
     }}
  end

  defp build_room(_room, _position, _nights, _rate_plan), do: :error

  defp unique_room_ids?(rooms) do
    room_ids =
      Enum.map(rooms, fn
        %{"room_id" => room_id} when is_binary(room_id) and room_id != "" -> room_id
        _room -> nil
      end)

    Enum.all?(room_ids, &is_binary/1) and Enum.uniq(room_ids) == room_ids
  end

  defp room_deposit_due_cents(lodging_amount_cents, @flexible) do
    round_half_up(lodging_amount_cents, 20, 100)
  end

  defp room_deposit_due_cents(lodging_amount_cents, @advance_purchase), do: lodging_amount_cents

  defp round_half_up(amount, numerator, denominator) do
    div(amount * numerator + div(denominator, 2), denominator)
  end

  defp ensure_group_available(operation, group_id) do
    case Repo.exists?(from(group in Group, where: group.group_id == ^group_id)) do
      true -> {:error, reject(operation["operation_id"], :group_already_exists)}
      false -> :ok
    end
  end

  defp ensure_valid_stay(operation, arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) > 0 do
      :ok
    else
      {:error, reject(operation["operation_id"], :invalid_stay)}
    end
  end

  defp ensure_active(_operation, %Group{status: @active}), do: :ok

  defp ensure_active(operation, _group),
    do: {:error, reject(operation["operation_id"], :group_not_active)}

  defp fetch_payment_amount_value(operation) do
    case Map.fetch(operation, "amount_cents") do
      {:ok, amount_cents} ->
        {:ok, amount_cents}

      :error ->
        {:error, reject(operation["operation_id"], :invalid_operation)}
    end
  end

  defp ensure_usable_payment_amount(_operation, amount_cents)
       when is_integer(amount_cents) and amount_cents > 0 do
    :ok
  end

  defp ensure_usable_payment_amount(operation, _amount_cents) do
    {:error, reject(operation["operation_id"], :invalid_amount)}
  end

  defp ensure_payment_within_outstanding(operation, group, amount_cents) do
    if amount_cents <= outstanding_deposit_cents(group) do
      :ok
    else
      {:error, reject(operation["operation_id"], :payment_exceeds_outstanding)}
    end
  end

  defp fetch_covering_credit_lots(operation, guest_id, amount_cents, occurred_on) do
    credit_lots = available_credit_lots(guest_id, occurred_on)

    if Enum.sum(Enum.map(credit_lots, & &1.remaining_cents)) >= amount_cents do
      {:ok, credit_lots}
    else
      {:error, reject(operation["operation_id"], :insufficient_credit)}
    end
  end

  defp ensure_new_arrival_after_operation(operation, new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, reject(operation["operation_id"], :invalid_stay)}
    end
  end

  defp ensure_refund_method_available(operation, group, occurred_on, @hotel_credit) do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, reject(operation["operation_id"], :refund_method_not_available)}
    end
  end

  defp ensure_refund_method_available(_operation, _group, _occurred_on, @cash), do: :ok

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refundable_until(group), do: refundable_until(group, group_policy_version(group))

  defp refundable_until(group, @flex_14), do: Date.add(group.arrival_on, -14)
  defp refundable_until(group, @flex_30), do: Date.add(group.arrival_on, -30)
  defp refundable_until(_group, @advance_nonrefundable), do: nil

  defp policy_version_for(@advance_purchase, _booked_on), do: @advance_nonrefundable

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt do
      @flex_14
    else
      @flex_30
    end
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when policy_version in [@flex_14, @flex_30, @advance_nonrefundable] do
    policy_version
  end

  defp group_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}) do
    policy_version_for(rate_plan, booked_on)
  end

  defp credit_issued_cents(cash_cents), do: cash_cents + round_half_up(cash_cents, 10, 100)

  defp cash_paid_cents(%Group{cash_paid_cents: nil, deposit_paid_cents: deposit_paid_cents}) do
    deposit_paid_cents
  end

  defp cash_paid_cents(%Group{} = group), do: group.cash_paid_cents

  defp credit_paid_cents(%Group{credit_paid_cents: nil}), do: 0
  defp credit_paid_cents(%Group{} = group), do: group.credit_paid_cents

  defp outstanding_deposit_cents(%Group{status: @cancelled}), do: 0

  defp outstanding_deposit_cents(%Group{} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(%Date{} = date), do: Date.to_iso8601(date)

  defp available_credit_lots(guest_id, on_date) do
    CreditLot
    |> where(
      [credit_lot],
      credit_lot.guest_id == ^guest_id and credit_lot.remaining_cents > 0 and
        credit_lot.issued_on <= ^on_date and credit_lot.expires_on >= ^on_date
    )
    |> order_by([credit_lot],
      asc: credit_lot.expires_on,
      asc: credit_lot.source_operation_id,
      asc: credit_lot.id
    )
    |> Repo.all()
  end

  defp reject(operation_id, code) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: to_string(code)
    }
  end

  defp operation_id_from(%{"operation_id" => operation_id}), do: operation_id
  defp operation_id_from(_operation), do: nil

  defp operation_type_from(%{"type" => operation_type}) when is_binary(operation_type) do
    operation_type
  end

  defp operation_type_from(_operation), do: nil

  defp normalize_json(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp preload_rooms(queryable) do
    from(group in queryable,
      preload: [rooms: ^from(room in Room, order_by: room.position)]
    )
  end

  defp has_unique_group_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_message, options}} -> options[:constraint] == :unique
      _error -> false
    end)
  end

  defp has_unique_operation_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {_message, options}} -> options[:constraint] == :unique
      _error -> false
    end)
  end
end
