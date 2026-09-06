defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Cash.{PaymentAllocation, PaymentState}
  alias GroupStay.Credit.{Allocation, Entitlement, Lot}
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Ledger.Total
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @policy_cutover ~D[2027-01-01]
  @room_accounting_version 1

  @type result :: map()

  @spec parse_as_of(String.t() | nil) :: {:ok, Date.t()} | {:error, atom()}
  def parse_as_of(nil), do: {:ok, Date.utc_today()}

  def parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_as_of(_), do: {:error, :invalid_date}

  @spec submit_batch(list()) :: [result()]
  def submit_batch(operations) when is_list(operations),
    do: Enum.map(operations, &submit_operation/1)

  @spec get_operation(String.t()) :: result() | nil
  def get_operation(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> decode_result(record.result_json)
    end
  end

  @doc false
  def backfill_legacy_room_accounting! do
    ensure_all_room_accounting!()
  end

  @spec get_group(String.t()) :: map() | nil
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> group_response(group, rooms_for_group(group.id))
    end
  end

  @spec get_payment(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_payment(payment_operation_id) do
    Repo.transaction(
      fn ->
        case Repo.get_by(Record, operation_id: payment_operation_id) do
          nil ->
            {:error, "operation_not_found"}

          record ->
            result = decode_result(record.result_json)

            if record.operation_type != "record_cash_payment" or result[:status] != "applied" do
              {:error, "payment_not_reconcilable"}
            else
              group = Repo.get_by(Group, group_id: result[:group_id])

              if is_nil(group) do
                {:error, "payment_not_reconcilable"}
              else
                case Repo.get_by(PaymentState, payment_operation_id: payment_operation_id) do
                  nil ->
                    {:error, "payment_not_reconcilable"}

                  state ->
                    {:ok,
                     %{
                       payment_operation_id: payment_operation_id,
                       original_group_id: group.group_id,
                       recorded_cents: state.recorded_cents,
                       held_cents: state.held_cents,
                       refunded_cents: state.refunded_cents,
                       retained_cents: state.retained_cents,
                       converted_to_credit_cents: state.converted_to_credit_cents,
                       reduced_cents: state.reduced_cents,
                       charged_back_cents: state.charged_back_cents
                     }}
                end
              end
            end
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, {:ok, statement}} -> {:ok, statement}
      {:ok, {:error, code}} -> {:error, code}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_guest_credit(String.t(), Date.t()) :: map()
  def get_guest_credit(guest_id, as_of_date \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in Lot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^as_of_date,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  @spec get_ledger(Date.t()) :: map()
  def get_ledger(as_of_date \\ Date.utc_today()) do
    Repo.transaction(
      fn ->
        liability = credit_liability(as_of_date)
        shortfall = credit_shortfall()
        if as_of_date == Date.utc_today(), do: sync_credit_liability(liability, shortfall)
        ledger = Repo.get!(Total, 1)

        %{
          cash_held_cents: ledger.cash_held_cents,
          cash_refunded_cents: ledger.cash_refunded_cents,
          cash_retained_cents: ledger.cash_retained_cents,
          cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents,
          cash_reduced_cents: ledger.cash_reduced_cents,
          cash_charged_back_cents: ledger.cash_charged_back_cents,
          credit_liability_cents: liability,
          credit_shortfall_cents: shortfall
        }
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp submit_operation(operation) do
    Repo.transaction(
      fn ->
        operation_id = field(operation, "operation_id")

        if valid_operation_id?(operation_id) do
          payload_json = canonical_json(operation)

          case Repo.get_by(Record, operation_id: operation_id) do
            nil ->
              process_new_operation(operation, operation_id, payload_json)

            record when record.payload_json == payload_json ->
              decode_result(record.result_json)

            _record ->
              reject(operation_id, "operation_id_conflict")
          end
        else
          process_unidentified_operation(operation)
        end
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, result}) when is_map(result), do: result

  defp process_new_operation(operation, operation_id, payload_json) do
    case apply_operation(operation) do
      {:ok, result} ->
        sync_credit_liability()
        remember_operation!(operation, operation_id, payload_json, result)
        result

      {:error, result} ->
        remember_operation!(operation, operation_id, payload_json, result)
        result
    end
  end

  defp process_unidentified_operation(operation) do
    case apply_operation(operation) do
      {:ok, result} ->
        sync_credit_liability()
        result

      {:error, result} ->
        result
    end
  end

  defp remember_operation!(operation, operation_id, payload_json, result) do
    Repo.insert!(%Record{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload_json: payload_json,
      result_json: Jason.encode!(result)
    })
  end

  defp decode_result(result_json), do: Jason.decode!(result_json, keys: :atoms!)

  defp operation_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp canonical_json(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, nested_value} -> {json_key(key), canonical_json(nested_value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    "{" <>
      Enum.map_join(pairs, ",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> nested_value
      end) <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  defp apply_operation(operation) when not is_map(operation),
    do: {:error, reject(nil, "invalid_operation")}

  defp apply_operation(operation) do
    operation_id = field(operation, "operation_id")

    with {:ok, type} <- required_type(operation), :ok <- validate_operation_id(operation_id) do
      case type do
        "open_group" ->
          open_group(operation, operation_id)

        type
        when type in [
               "record_cash_payment",
               "reschedule_group",
               "cancel_group",
               "cancel_rooms",
               "apply_hotel_credit"
             ] ->
          apply_existing_group_operation(operation, operation_id, type)

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          apply_payment_operation(operation, operation_id, type)

        _ ->
          {:error, reject(operation_id, "invalid_operation")}
      end
    else
      _ -> {:error, reject(operation_id, "invalid_operation")}
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         nil <- Repo.get_by(Group, group_id: group_id) do
      with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
           {:ok, guest_id} <- required_identifier(operation, "guest_id"),
           {:ok, property_id} <- required_identifier(operation, "property_id"),
           {:ok, arrival_on} <- required_date(operation, "arrival_on"),
           {:ok, departure_on} <- required_date(operation, "departure_on"),
           :ok <- validate_stay(arrival_on, departure_on),
           {:ok, rate_plan} <- validate_rate_plan(field(operation, "rate_plan")),
           {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
        nights = Date.diff(departure_on, arrival_on)

        rooms =
          Enum.map(rooms, fn room ->
            lodging_cents = room.nightly_rate_cents * nights

            Map.merge(room, %{
              lodging_cents: lodging_cents,
              deposit_due_cents: deposit_due([%{lodging_cents: lodging_cents}], rate_plan)
            })
          end)

        lodging_total_cents = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
        deposit_due_cents = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))

        group = %Group{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version(rate_plan, occurred_on),
          status: @active,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          revision: 1,
          accounting_version: @room_accounting_version
        }

        case Repo.insert(group) do
          {:ok, group} ->
            Repo.insert_all(
              Room,
              Enum.map(rooms, fn room ->
                %{
                  group_id: group.id,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents,
                  position: room.position,
                  status: @active,
                  lodging_cents: room.lodging_cents,
                  deposit_due_cents: room.deposit_due_cents,
                  cash_paid_cents: 0,
                  credit_paid_cents: 0
                }
              end)
            )

            {:ok,
             applied(operation_id,
               group_id: group_id,
               deposit_due_cents: deposit_due_cents,
               revision: 1
             )}

          {:error, _changeset} ->
            {:error, reject(operation_id, "group_already_exists", group_id: group_id)}
        end
      else
        {:error, code} -> {:error, reject(operation_id, code, group_id: group_id)}
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code)}

      _group ->
        {:error,
         reject(operation_id, "group_already_exists", group_id: field(operation, "group_id"))}
    end
  end

  defp apply_existing_group_operation(operation, operation_id, type) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         group when not is_nil(group) <- Repo.get_by(Group, group_id: group_id),
         :ok <- check_expected_revision(operation, group) do
      case type do
        "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
        "reschedule_group" -> reschedule_group(operation, operation_id, group)
        "cancel_group" -> cancel_group(operation, operation_id, group)
        "cancel_rooms" -> cancel_rooms(operation, operation_id, group)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id, group)
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code, group_id: field(operation, "group_id"))}

      nil ->
        {:error, reject(operation_id, "group_not_found", group_id: field(operation, "group_id"))}
    end
  end

  defp record_cash_payment(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         {:ok, outstanding} <- payment_outstanding(group, amount_cents) do
      allocate_cash_funding(group, operation_id, amount_cents)

      Repo.insert!(%PaymentState{
        payment_operation_id: operation_id,
        group_id: group.id,
        recorded_cents: amount_cents,
        held_cents: amount_cents,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      })

      update_ledger(cash_held_cents: amount_cents)
      update_group_financials(group)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding - amount_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         {:ok, outstanding} <- payment_outstanding(group, amount_cents),
         :ok <- ensure_credit_available(group.guest_id, amount_cents, occurred_on) do
      consume_credit(group, operation_id, amount_cents, occurred_on)
      update_group_financials(group)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding - amount_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- validate_reschedule(occurred_on, new_arrival_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      update_group(group, arrival_on: new_arrival_on, departure_on: new_departure_on)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         new_arrival_on: new_arrival_on,
         new_departure_on: new_departure_on,
         policy_version: policy_version_for(group),
         refundable_until: refundable_until(group, new_arrival_on),
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation) do
      refundable = refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable do
        {:error, reject(operation_id, "refund_method_not_available", group_id: group.group_id)}
      else
        room_ids = active_rooms(group.id) |> Enum.map(& &1.room_id)

        settled =
          settle_rooms(group, operation_id, room_ids, occurred_on, refundable, refund_method)

        {:ok,
         applied(operation_id,
           group_id: group.group_id,
           refunded_cents: settled.refunded_cents,
           retained_cents: settled.retained_cents,
           credit_issued_cents: settled.credit_issued_cents,
           revision: group.revision + 1
         )}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp cancel_rooms(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, room_ids} <- selected_room_ids(operation, group.id) do
      refundable = refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable do
        {:error, reject(operation_id, "refund_method_not_available", group_id: group.group_id)}
      else
        settled =
          settle_rooms(group, operation_id, room_ids, occurred_on, refundable, refund_method)

        {:ok,
         applied(operation_id,
           group_id: group.group_id,
           cancelled_room_ids: room_ids,
           refunded_cents: settled.refunded_cents,
           retained_cents: settled.retained_cents,
           credit_issued_cents: settled.credit_issued_cents,
           revision: group.revision + 1
         )}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp settle_rooms(group, operation_id, room_ids, occurred_on, refundable, refund_method) do
    cash_allocations =
      Repo.all(
        from allocation in PaymentAllocation,
          where: allocation.group_id == ^group.id and allocation.room_id in ^room_ids,
          order_by: [asc: allocation.id]
      )

    credit_allocations =
      Repo.all(
        from allocation in Allocation,
          where: allocation.group_id == ^group.id and allocation.room_id in ^room_ids,
          order_by: [asc: allocation.id]
      )

    cash_total = sum_amount(cash_allocations)

    {refunded_cents, retained_cents, credit_issued_cents} =
      cond do
        refundable and refund_method == "cash" ->
          remove_cash_allocations!(cash_allocations, adjust_rooms?: true)
          update_cash_disposition!(cash_allocations, :refunded_cents)
          restore_credit_allocations!(credit_allocations, occurred_on)
          update_ledger_if_needed(cash_held_cents: -cash_total, cash_refunded_cents: cash_total)
          {cash_total, 0, 0}

        refundable and refund_method == "hotel_credit" ->
          remove_cash_allocations!(cash_allocations, adjust_rooms?: true)
          restore_credit_allocations!(credit_allocations, occurred_on)

          issued =
            issue_credit_for_cash(group, operation_id, cash_allocations, cash_total, occurred_on)

          {0, 0, issued}

        true ->
          remove_cash_allocations!(cash_allocations, adjust_rooms?: true)
          update_cash_disposition!(cash_allocations, :retained_cents)
          consume_credit_allocations!(credit_allocations)
          update_ledger_if_needed(cash_held_cents: -cash_total, cash_retained_cents: cash_total)
          {0, cash_total, 0}
      end

    Enum.each(active_rooms(group.id), fn room ->
      if room.room_id in room_ids,
        do: room |> Ecto.Changeset.change(status: @cancelled) |> Repo.update!()
    end)

    status = if active_rooms(group.id) == [], do: @cancelled, else: @active
    update_group_financials(group, status: status)

    %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents
    }
  end

  defp issue_credit_for_cash(_group, _operation_id, _cash_allocations, 0, _occurred_on), do: 0

  defp issue_credit_for_cash(group, operation_id, cash_allocations, cash_total, occurred_on) do
    credit_issued_cents = credit_with_bonus(cash_total)

    lot =
      create_credit_lot(
        group.guest_id,
        operation_id,
        credit_issued_cents,
        Date.add(occurred_on, 365)
      )

    contributions = cash_contributions(cash_allocations)

    Enum.reduce(contributions, 0, fn {payment_operation_id, principal_cents}, previous_cash ->
      next_cash = previous_cash + principal_cents
      entitlement_cents = credit_with_bonus(next_cash) - credit_with_bonus(previous_cash)

      if is_binary(payment_operation_id) and payment_operation_id != "" do
        Repo.insert!(%Entitlement{
          lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          entitlement_cents: entitlement_cents,
          revoked_cents: 0
        })
      end

      update_payment_state!(payment_operation_id, converted_to_credit_cents: principal_cents)
      next_cash
    end)

    update_ledger_if_needed(
      cash_held_cents: -cash_total,
      cash_converted_to_credit_cents: cash_total
    )

    credit_issued_cents
  end

  defp refund_method(operation) do
    if has_field?(operation, "refund_method") do
      case field(operation, "refund_method") do
        "cash" -> {:ok, "cash"}
        "hotel_credit" -> {:ok, "hotel_credit"}
        _ -> {:error, "invalid_refund_method"}
      end
    else
      {:ok, "cash"}
    end
  end

  defp refundable?(group, occurred_on) do
    case policy_version_for(group) do
      "flex-14" -> Date.diff(group.arrival_on, occurred_on) >= 14
      "flex-30" -> Date.diff(group.arrival_on, occurred_on) >= 30
      _ -> false
    end
  end

  defp policy_version(@advance_purchase, _booked_on), do: "advance-nonrefundable"

  defp policy_version(@flexible, booked_on),
    do: if(Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30")

  defp policy_version_for(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"], do: policy_version

  defp policy_version_for(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp refundable_until(group), do: refundable_until(group, group.arrival_on)

  defp refundable_until(group, arrival_on) do
    case policy_version_for(group) do
      "flex-14" -> Date.add(arrival_on, -14)
      "flex-30" -> Date.add(arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp credit_with_bonus(0), do: 0
  defp credit_with_bonus(cash_cents), do: cash_cents + round_half_up(cash_cents * 10, 100)

  defp ensure_credit_available(guest_id, amount_cents, occurred_on) do
    if available_credit(guest_id, occurred_on) >= amount_cents,
      do: :ok,
      else: {:error, "insufficient_credit"}
  end

  defp available_credit(guest_id, as_of_date) do
    Repo.aggregate(
      from(lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^as_of_date
      ),
      :sum,
      :remaining_cents
    ) || 0
  end

  defp consume_credit(group, operation_id, amount_cents, occurred_on) do
    Enum.reduce_while(available_credit_lots(group.guest_id, occurred_on), amount_cents, fn lot,
                                                                                           remaining ->
      amount = min(remaining, lot.remaining_cents)

      if amount > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - amount)
        |> Repo.update!()

        allocate_existing_credit_amount!(group, operation_id, lot.id, amount)
      end

      next_remaining = remaining - amount
      if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
    end)
  end

  defp available_credit_lots(guest_id, as_of_date) do
    Repo.all(
      from lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^as_of_date,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp create_credit_lot(guest_id, source_operation_id, amount_cents, expires_on) do
    Repo.insert!(%Lot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      issued_cents: amount_cents,
      unrecovered_clawback_cents: 0,
      expires_on: expires_on
    })
  end

  defp restore_credit_allocations!(allocations, occurred_on) do
    allocations
    |> Enum.group_by(& &1.lot_id)
    |> Enum.each(fn {lot_id, lot_allocations} ->
      restore_credit_lot!(Repo.get!(Lot, lot_id), sum_amount(lot_allocations), occurred_on)
    end)

    Enum.each(allocations, fn allocation ->
      decrement_room_credit!(allocation.group_id, allocation.room_id, allocation.amount_cents)
      Repo.delete!(allocation)
    end)
  end

  defp restore_credit_lot!(lot, amount_cents, occurred_on) do
    absorbed = min(amount_cents, lot.unrecovered_clawback_cents || 0)
    excess = amount_cents - absorbed

    remaining_cents =
      if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt],
        do: lot.remaining_cents + excess,
        else: lot.remaining_cents

    lot
    |> Ecto.Changeset.change(
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed
    )
    |> Repo.update!()
  end

  defp consume_credit_allocations!(allocations) do
    Enum.each(allocations, fn allocation ->
      decrement_room_credit!(allocation.group_id, allocation.room_id, allocation.amount_cents)
      Repo.delete!(allocation)
    end)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == ^@active,
        order_by: [asc: room.position]
    )
  end

  defp rooms_for_group(group_id),
    do:
      Repo.all(
        from room in Room, where: room.group_id == ^group_id, order_by: [asc: room.position]
      )

  defp allocate_cash_funding(group, payment_operation_id, amount_cents) do
    remaining =
      Enum.reduce_while(active_rooms(group.id), amount_cents, fn room, remaining ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(capacity, remaining)

        if amount > 0 do
          room
          |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + amount)
          |> Repo.update!()

          Repo.insert!(%PaymentAllocation{
            group_id: group.id,
            room_id: room.room_id,
            payment_operation_id: payment_operation_id,
            amount_cents: amount
          })
        end

        next_remaining = remaining - amount
        if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
      end)

    if remaining != 0, do: raise("cash allocation exceeded active room deposit")
    :ok
  end

  defp allocate_existing_credit_amount!(group, source_operation_id, lot_id, amount_cents) do
    remaining =
      Enum.reduce_while(active_rooms(group.id), amount_cents, fn room, remaining ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(capacity, remaining)

        if amount > 0 do
          room
          |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + amount)
          |> Repo.update!()

          Repo.insert!(%Allocation{
            group_id: group.id,
            room_id: room.room_id,
            lot_id: lot_id,
            source_operation_id: source_operation_id,
            amount_cents: amount
          })
        end

        next_remaining = remaining - amount
        if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
      end)

    if remaining != 0, do: raise("credit allocation exceeded active room deposit")
    :ok
  end

  defp payment_outstanding(group, amount_cents) do
    outstanding = active_totals(group.id).outstanding_deposit_cents

    if amount_cents <= outstanding,
      do: {:ok, outstanding},
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp remove_cash_allocations!(allocations, opts) do
    adjust_rooms? = Keyword.get(opts, :adjust_rooms?, false)

    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {payment_operation_id, grouped} ->
      amount_cents = sum_amount(grouped)

      if adjust_rooms?,
        do: Enum.each(grouped, &decrement_room_cash!(&1.group_id, &1.room_id, &1.amount_cents))

      Enum.each(grouped, &Repo.delete!/1)
      update_payment_state!(payment_operation_id, held_cents: -amount_cents)
    end)
  end

  defp update_cash_disposition!(allocations, field) do
    cash_contributions(allocations)
    |> Enum.each(fn {payment_operation_id, amount_cents} ->
      update_payment_state!(payment_operation_id, [{field, amount_cents}])
    end)
  end

  defp remove_cash_allocations_for_payment!(group_id, payment_operation_id, amount_cents) do
    allocations =
      Repo.all(
        from allocation in PaymentAllocation,
          where:
            allocation.group_id == ^group_id and
              allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: allocation.id]
      )

    remaining =
      Enum.reduce_while(allocations, amount_cents, fn allocation, remaining ->
        amount = min(remaining, allocation.amount_cents)
        decrement_room_cash!(allocation.group_id, allocation.room_id, amount)

        if amount == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation
          |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
          |> Repo.update!()
        end

        next_remaining = remaining - amount
        if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
      end)

    if remaining != 0, do: raise("cash allocation did not cover payment disposition")
    :ok
  end

  defp decrement_room_cash!(group_id, room_id, amount_cents) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    room
    |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents - amount_cents)
    |> Repo.update!()
  end

  defp decrement_room_credit!(group_id, room_id, amount_cents) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    room
    |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents - amount_cents)
    |> Repo.update!()
  end

  defp update_payment_state!(nil, _attrs), do: :ok
  defp update_payment_state!("", _attrs), do: :ok

  defp update_payment_state!(payment_operation_id, attrs) do
    state = Repo.get_by!(PaymentState, payment_operation_id: payment_operation_id)

    values =
      Enum.reduce(attrs, %{}, fn {field, delta}, acc ->
        Map.put(acc, field, Map.fetch!(state, field) + delta)
      end)

    state |> Ecto.Changeset.change(values) |> Repo.update!()
  end

  defp cash_contributions(allocations) do
    {order, amounts} =
      Enum.reduce(allocations, {[], %{}}, fn allocation, {order, amounts} ->
        payment_operation_id = allocation.payment_operation_id

        order =
          if Map.has_key?(amounts, payment_operation_id),
            do: order,
            else: order ++ [payment_operation_id]

        {order,
         Map.update(
           amounts,
           payment_operation_id,
           allocation.amount_cents,
           &(&1 + allocation.amount_cents)
         )}
      end)

    Enum.map(order, &{&1, Map.fetch!(amounts, &1)})
  end

  defp apply_payment_operation(operation, operation_id, type) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id"),
         record when not is_nil(record) <- Repo.get_by(Record, operation_id: payment_operation_id),
         {:ok, group, state} <- payment_target(record, type) do
      case check_expected_revision(operation, group) do
        :ok ->
          case type do
            "reduce_cash_payment" ->
              reduce_cash_payment(operation, operation_id, payment_operation_id, group, state)

            "charge_back_payment" ->
              charge_back_payment(operation_id, payment_operation_id, group, state)
          end

        {:error, code} ->
          {:error, reject(operation_id, code, group_id: group.group_id)}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code)}
      nil -> {:error, reject(operation_id, "operation_not_found")}
    end
  end

  defp payment_target(record, type) do
    result = decode_result(record.result_json)

    cond do
      record.operation_type != "record_cash_payment" or result[:status] != "applied" ->
        {:error, payment_error_for(type)}

      true ->
        group = Repo.get_by(Group, group_id: result[:group_id])

        if is_nil(group) do
          {:error, payment_error_for(type)}
        else
          case Repo.get_by(PaymentState, payment_operation_id: record.operation_id) do
            nil -> {:error, payment_error_for(type)}
            state -> {:ok, group, state}
          end
        end
    end
  end

  defp payment_error_for("reduce_cash_payment"), do: "payment_not_reducible"
  defp payment_error_for("charge_back_payment"), do: "payment_not_chargeable"

  defp reduce_cash_payment(operation, operation_id, payment_operation_id, group, state) do
    with {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- ensure_payment_reducible(state),
         :ok <- ensure_active(group),
         :ok <- ensure_reduction_fits(state, amount_cents) do
      remove_cash_allocations_for_payment!(group.id, payment_operation_id, amount_cents)

      update_payment_state!(payment_operation_id,
        held_cents: -amount_cents,
        reduced_cents: amount_cents
      )

      update_ledger(cash_held_cents: -amount_cents, cash_reduced_cents: amount_cents)
      update_group_financials(group)
      outstanding = active_totals(group.id).outstanding_deposit_cents

      {:ok,
       applied(operation_id,
         payment_operation_id: payment_operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding,
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp ensure_payment_reducible(%PaymentState{held_cents: held}) when held > 0, do: :ok
  defp ensure_payment_reducible(_), do: {:error, "payment_not_reducible"}

  defp ensure_reduction_fits(%PaymentState{held_cents: held}, amount_cents),
    do: if(amount_cents <= held, do: :ok, else: {:error, "reduction_exceeds_held_cash"})

  defp charge_back_payment(operation_id, payment_operation_id, group, state) do
    chargeable_cents =
      state.held_cents + state.refunded_cents + state.retained_cents +
        state.converted_to_credit_cents

    if chargeable_cents <= 0 or state.charged_back_cents > 0 do
      {:error, reject(operation_id, "payment_not_chargeable")}
    else
      if state.held_cents > 0,
        do: remove_cash_allocations_for_payment!(group.id, payment_operation_id, state.held_cents)

      revoke_payment_entitlements!(payment_operation_id)

      update_payment_state!(payment_operation_id,
        held_cents: -state.held_cents,
        refunded_cents: -state.refunded_cents,
        retained_cents: -state.retained_cents,
        converted_to_credit_cents: -state.converted_to_credit_cents,
        charged_back_cents: chargeable_cents
      )

      update_ledger_if_needed(
        cash_held_cents: -state.held_cents,
        cash_refunded_cents: -state.refunded_cents,
        cash_retained_cents: -state.retained_cents,
        cash_converted_to_credit_cents: -state.converted_to_credit_cents,
        cash_charged_back_cents: chargeable_cents
      )

      update_group_financials(group)
      outstanding = active_totals(group.id).outstanding_deposit_cents

      {:ok,
       applied(operation_id,
         payment_operation_id: payment_operation_id,
         group_id: group.group_id,
         charged_back_cents: chargeable_cents,
         outstanding_deposit_cents: outstanding,
         revision: group.revision + 1
       )}
    end
  end

  defp revoke_payment_entitlements!(payment_operation_id) do
    Repo.all(
      from entitlement in Entitlement,
        where:
          entitlement.payment_operation_id == ^payment_operation_id and
            entitlement.revoked_cents < entitlement.entitlement_cents,
        order_by: [asc: entitlement.id]
    )
    |> Enum.each(fn entitlement ->
      revocable = entitlement.entitlement_cents - entitlement.revoked_cents
      lot = Repo.get!(Lot, entitlement.lot_id)
      removable = min(lot.remaining_cents, revocable)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removable,
        unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + revocable - removable
      )
      |> Repo.update!()

      entitlement
      |> Ecto.Changeset.change(revoked_cents: entitlement.entitlement_cents)
      |> Repo.update!()
    end)
  end

  defp check_expected_revision(operation, group) do
    if has_field?(operation, "expected_revision") and
         field(operation, "expected_revision") !== group.revision do
      {:error,
       {:stale_revision,
        [
          expected_revision: field(operation, "expected_revision"),
          actual_revision: group.revision
        ]}}
    else
      :ok
    end
  end

  defp update_group_financials(group, attrs \\ []) do
    totals = active_totals(group.id)
    stored_totals = Map.drop(totals, [:outstanding_deposit_cents])

    group
    |> Ecto.Changeset.change(
      Map.merge(Map.new(attrs), Map.merge(stored_totals, %{revision: group.revision + 1}))
    )
    |> Repo.update!()
  end

  defp update_group(group, attrs),
    do:
      group
      |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
      |> Repo.update!()

  defp active_totals(group_id) do
    rooms = active_rooms(group_id)
    lodging_total_cents = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
    deposit_due_cents = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))
    cash_paid_cents = Enum.reduce(rooms, 0, &(&1.cash_paid_cents + &2))
    credit_paid_cents = Enum.reduce(rooms, 0, &(&1.credit_paid_cents + &2))

    %{
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: deposit_due_cents - cash_paid_cents - credit_paid_cents
    }
  end

  defp group_response(group, rooms) do
    totals = active_totals(group.id)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version_for(group),
      refundable_until: format_date(refundable_until(group)),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_cents: room.lodging_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
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

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp selected_room_ids(operation, group_id) do
    room_ids = field(operation, "room_ids")
    active = active_rooms(group_id)

    cond do
      not is_list(room_ids) or room_ids == [] ->
        {:error, "invalid_rooms"}

      Enum.any?(room_ids, &(not (is_binary(&1) and &1 != ""))) ->
        {:error, "invalid_rooms"}

      length(Enum.uniq(room_ids)) != length(room_ids) ->
        {:error, "invalid_rooms"}

      Enum.any?(room_ids, fn room_id -> not Enum.any?(active, &(&1.room_id == room_id)) end) ->
        {:error, "invalid_rooms"}

      true ->
        {:ok, active |> Enum.filter(&(&1.room_id in room_ids)) |> Enum.map(& &1.room_id)}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, acc} ->
      if Enum.any?(acc, &(&1.room_id == field(room, "room_id"))) do
        {:halt, {:error, "invalid_rooms"}}
      else
        with {:ok, room_id} <- required_identifier(room, "room_id"),
             {:ok, nightly_rate_cents} <- positive_amount(field(room, "nightly_rate_cents")) do
          {:cont,
           {:ok,
            [
              %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                lodging_cents: 0,
                deposit_due_cents: 0,
                status: @active,
                cash_paid_cents: 0,
                credit_paid_cents: 0
              }
              | acc
            ]}}
        else
          {:error, _} -> {:halt, {:error, "invalid_rooms"}}
        end
      end
    end)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      error -> error
    end
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp deposit_due(rooms, @flexible),
    do: Enum.reduce(rooms, 0, &(round_half_up(&1.lodging_cents * 20, 100) + &2))

  defp deposit_due(rooms, @advance_purchase), do: Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))

  defp required_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, key) when is_map(operation) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(_, _), do: {:error, "invalid_operation"}

  defp required_date(operation, key) do
    case field(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_stay"}
        end

      _ ->
        if(has_field?(operation, key),
          do: {:error, "invalid_stay"},
          else: {:error, "invalid_operation"}
        )
    end
  end

  defp validate_stay(arrival_on, departure_on),
    do: if(Date.after?(departure_on, arrival_on), do: :ok, else: {:error, "invalid_stay"})

  defp validate_reschedule(occurred_on, new_arrival_on),
    do: if(Date.after?(new_arrival_on, occurred_on), do: :ok, else: {:error, "invalid_stay"})

  defp validate_rate_plan(@flexible), do: {:ok, @flexible}
  defp validate_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp usable_amount(amount) do
    case positive_amount(amount) do
      {:ok, amount} -> {:ok, amount}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp positive_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp positive_amount(_), do: {:error, "invalid_amount"}
  defp ensure_active(%Group{status: @active}), do: :ok
  defp ensure_active(_), do: {:error, "group_not_active"}

  defp reject(operation_id, code, fields \\ [])

  defp reject(operation_id, {:stale_revision, fields}, base_fields),
    do: reject(operation_id, "stale_revision", Keyword.merge(base_fields, fields))

  defp reject(operation_id, code, fields),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))

  defp validate_operation_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_operation_id(_), do: {:error, "invalid_operation"}
  defp valid_operation_id?(value), do: validate_operation_id(value) == :ok
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp field(_, _), do: nil

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp has_field?(_, _), do: false
  defp sum_amount(items), do: Enum.reduce(items, 0, &(&1.amount_cents + &2))

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp credit_liability(as_of_date) do
    available_credit_cents =
      Repo.aggregate(
        from(lot in Lot, where: lot.remaining_cents > 0 and lot.expires_on >= ^as_of_date),
        :sum,
        :remaining_cents
      ) || 0

    applied_credit_cents =
      Repo.one(
        from allocation in Allocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: group.status == ^@active,
          select: sum(allocation.amount_cents)
      ) || 0

    available_credit_cents + applied_credit_cents
  end

  defp credit_shortfall do
    applied_by_lot =
      Repo.all(
        from allocation in Allocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: group.status == ^@active,
          group_by: allocation.lot_id,
          select: {allocation.lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    Repo.all(from lot in Lot, select: {lot.unrecovered_clawback_cents, lot.id})
    |> Enum.reduce(0, fn {unrecovered, lot_id}, total ->
      total + min(unrecovered || 0, Map.get(applied_by_lot, lot_id, 0) || 0)
    end)
  end

  defp sync_credit_liability,
    do: sync_credit_liability(credit_liability(Date.utc_today()), credit_shortfall())

  defp sync_credit_liability(liability, shortfall) do
    ledger = Repo.get!(Total, 1)

    if ledger.credit_liability_cents != liability or ledger.credit_shortfall_cents != shortfall do
      ledger
      |> Ecto.Changeset.change(
        credit_liability_cents: liability,
        credit_shortfall_cents: shortfall
      )
      |> Repo.update!()
    end
  end

  defp update_ledger(deltas) do
    ledger = Repo.get!(Total, 1)

    attrs =
      Enum.reduce(deltas, %{}, fn {field, delta}, acc ->
        Map.put(acc, field, Map.fetch!(ledger, field) + delta)
      end)

    ledger |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp update_ledger_if_needed(deltas) do
    case Enum.reject(deltas, fn {_field, delta} -> delta == 0 end) do
      [] -> :ok
      non_empty_deltas -> update_ledger(non_empty_deltas)
    end
  end

  # Existing databases can contain groups and credit allocations from before room accounting.
  # This backfill only adds provenance and room placement; it does not alter aggregate balances.
  defp ensure_all_room_accounting! do
    Repo.all(
      from group in Group,
        where:
          group.accounting_version < ^@room_accounting_version or is_nil(group.accounting_version),
        order_by: [asc: group.id]
    )
    |> Enum.each(&ensure_group_room_accounting!/1)
  end

  defp ensure_group_room_accounting!(%Group{accounting_version: @room_accounting_version} = group) do
    ensure_payment_states_for_group!(group)
    :ok
  end

  defp ensure_group_room_accounting!(group) do
    rooms = rooms_for_group(group.id)
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.each(rooms, fn room ->
      lodging_cents = room.nightly_rate_cents * nights

      room
      |> Ecto.Changeset.change(
        status: if(group.status == @active, do: @active, else: @cancelled),
        lodging_cents: lodging_cents,
        deposit_due_cents: deposit_due([%{lodging_cents: lodging_cents}], group.rate_plan),
        cash_paid_cents: 0,
        credit_paid_cents: 0
      )
      |> Repo.update!()
    end)

    if group.status == @active do
      backfill_active_group_funding!(group)
    else
      ensure_payment_states_for_group!(group)
      backfill_legacy_credit_entitlements!(group)
    end

    totals =
      if group.status == @active,
        do: Map.drop(active_totals(group.id), [:outstanding_deposit_cents]),
        else: %{
          lodging_total_cents: 0,
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        }

    group
    |> Ecto.Changeset.change(Map.merge(totals, %{accounting_version: @room_accounting_version}))
    |> Repo.update!()

    ensure_payment_states_for_group!(Repo.get!(Group, group.id))
    :ok
  end

  defp backfill_active_group_funding!(group) do
    cash_records = funding_records(group.group_id, "record_cash_payment")
    credit_records = funding_records(group.group_id, "apply_hotel_credit")

    existing_credit_rows =
      Repo.all(
        from allocation in Allocation,
          where: allocation.group_id == ^group.id,
          order_by: [asc: allocation.id]
      )

    existing_credit_total = sum_amount(existing_credit_rows)
    recorded_cash_total = Enum.reduce(cash_records, 0, &(&1.amount_cents + &2))
    recorded_credit_total = Enum.reduce(credit_records, 0, &(&1.amount_cents + &2))

    legacy_cash =
      max((group.cash_paid_cents || group.deposit_paid_cents || 0) - recorded_cash_total, 0)

    legacy_credit = max(existing_credit_total - recorded_credit_total, 0)

    classified_rows =
      classify_credit_rows(
        existing_credit_rows,
        legacy_credit,
        credit_records,
        existing_credit_total
      )

    Repo.delete_all(from allocation in Allocation, where: allocation.group_id == ^group.id)

    if legacy_cash > 0, do: allocate_cash_funding(group, nil, legacy_cash)
    insert_backfilled_credit_rows!(group, Map.get(classified_rows, nil, []))

    merge_funding_records(cash_records, credit_records)
    |> Enum.each(fn
      {:cash, record, amount_cents} ->
        allocate_cash_funding(group, record.operation_id, amount_cents)

      {:credit, record, _amount_cents} ->
        insert_backfilled_credit_rows!(group, Map.get(classified_rows, record.operation_id, []))
    end)
  end

  defp funding_records(group_id, operation_type) do
    Repo.all(
      from record in Record,
        where: record.operation_type == ^operation_type,
        order_by: [asc: record.id]
    )
    |> Enum.flat_map(fn record ->
      result = decode_result(record.result_json)

      if result[:status] == "applied" and result[:group_id] == group_id and
           is_integer(result[:amount_cents]) and result[:amount_cents] > 0,
         do: [
           %{
             operation_id: record.operation_id,
             amount_cents: result[:amount_cents],
             record: record
           }
         ],
         else: []
    end)
  end

  defp classify_credit_rows(rows, legacy_credit, credit_records, credit_total) do
    segments = [
      {nil, legacy_credit} | Enum.map(credit_records, &{&1.operation_id, &1.amount_cents})
    ]

    segments =
      if credit_total > legacy_credit + Enum.reduce(credit_records, 0, &(&1.amount_cents + &2)),
        do:
          segments ++
            [
              {nil,
               credit_total - legacy_credit -
                 Enum.reduce(credit_records, 0, &(&1.amount_cents + &2))}
            ],
        else: segments

    {classified, _segments} =
      Enum.reduce(rows, {%{}, segments}, fn row, {classified, segments} ->
        {chunks, segments} = consume_segments(row.amount_cents, row.lot_id, segments)

        classified =
          Enum.reduce(chunks, classified, fn chunk, acc ->
            Map.update(acc, chunk.source_operation_id, [chunk], &(&1 ++ [chunk]))
          end)

        {classified, segments}
      end)

    classified
  end

  defp consume_segments(0, _lot_id, segments), do: {[], segments}

  defp consume_segments(amount, lot_id, [{source_operation_id, segment_amount} | rest]) do
    consumed = min(amount, segment_amount)

    remaining_segments =
      if segment_amount == consumed,
        do: rest,
        else: [{source_operation_id, segment_amount - consumed} | rest]

    {tail, remaining_segments} =
      if amount == consumed,
        do: {[], remaining_segments},
        else: consume_segments(amount - consumed, lot_id, remaining_segments)

    {[
       Map.merge(%{lot_id: lot_id, amount_cents: consumed}, %{
         source_operation_id: source_operation_id
       })
       | tail
     ], remaining_segments}
  end

  defp consume_segments(_amount, _lot_id, []), do: {[], []}

  defp merge_funding_records(cash_records, credit_records) do
    (Enum.map(cash_records, &{:cash, &1, &1.amount_cents}) ++
       Enum.map(credit_records, &{:credit, &1, &1.amount_cents}))
    |> Enum.sort_by(fn {_kind, record, _amount} -> record.record.id end)
  end

  defp insert_backfilled_credit_rows!(_group, []), do: :ok

  defp insert_backfilled_credit_rows!(group, rows),
    do:
      Enum.each(
        rows,
        &allocate_existing_credit_amount!(
          group,
          &1.source_operation_id,
          &1.lot_id,
          &1.amount_cents
        )
      )

  defp ensure_payment_states_for_group!(group),
    do:
      Enum.each(
        funding_records(group.group_id, "record_cash_payment"),
        &ensure_payment_state!(&1.record, group)
      )

  defp backfill_legacy_credit_entitlements!(group) do
    cancellation =
      Repo.all(
        from candidate in Record,
          where: candidate.operation_type == "cancel_group",
          order_by: [desc: candidate.id]
      )
      |> Enum.find(fn candidate ->
        result = decode_result(candidate.result_json)

        result[:status] == "applied" and result[:group_id] == group.group_id and
          (result[:credit_issued_cents] || 0) > 0
      end)

    if cancellation do
      case Repo.get_by(Lot, source_operation_id: cancellation.operation_id) do
        nil ->
          :ok

        lot ->
          entitlement_query =
            from entitlement in Entitlement,
              where: entitlement.lot_id == ^lot.id

          if Repo.aggregate(entitlement_query, :count, :id) == 0 do
            payments = funding_records(group.group_id, "record_cash_payment")
            cash_total = group.cash_paid_cents || group.deposit_paid_cents || 0
            recorded_total = Enum.reduce(payments, 0, &(&1.amount_cents + &2))

            contributions = [
              {nil, max(cash_total - recorded_total, 0)}
              | Enum.map(payments, &{&1.operation_id, &1.amount_cents})
            ]

            if lot.issued_cents == 0 do
              result = decode_result(cancellation.result_json)

              lot
              |> Ecto.Changeset.change(issued_cents: result[:credit_issued_cents] || 0)
              |> Repo.update!()
            end

            Enum.reduce(contributions, 0, fn {payment_operation_id, principal_cents},
                                             previous_cash ->
              next_cash = previous_cash + principal_cents
              entitlement_cents = credit_with_bonus(next_cash) - credit_with_bonus(previous_cash)

              if is_binary(payment_operation_id) and payment_operation_id != "" do
                Repo.insert!(%Entitlement{
                  lot_id: lot.id,
                  payment_operation_id: payment_operation_id,
                  entitlement_cents: entitlement_cents,
                  revoked_cents: 0
                })
              end

              next_cash
            end)
          end
      end
    end
  end

  defp ensure_payment_state!(record, group) do
    case Repo.get_by(PaymentState, payment_operation_id: record.operation_id) do
      nil ->
        result = decode_result(record.result_json)
        recorded_cents = result[:amount_cents] || 0

        allocation_query =
          from allocation in PaymentAllocation,
            where:
              allocation.group_id == ^group.id and
                allocation.payment_operation_id == ^record.operation_id

        held_cents = Repo.aggregate(allocation_query, :sum, :amount_cents) || 0

        {refunded_cents, retained_cents, converted_to_credit_cents} =
          infer_legacy_settlement(record, group, recorded_cents, held_cents)

        Repo.insert!(%PaymentState{
          payment_operation_id: record.operation_id,
          group_id: group.id,
          recorded_cents: recorded_cents,
          held_cents: held_cents,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          converted_to_credit_cents: converted_to_credit_cents,
          reduced_cents: 0,
          charged_back_cents: 0
        })

        Repo.get_by!(PaymentState, payment_operation_id: record.operation_id)

      state ->
        state
    end
  end

  defp infer_legacy_settlement(_record, group, recorded_cents, held_cents) do
    if group.status == @active do
      {0, 0, 0}
    else
      cancellations =
        Repo.all(
          from candidate in Record,
            where: candidate.operation_type == "cancel_group",
            order_by: [desc: candidate.id]
        )

      cancellation =
        Enum.find(cancellations, fn candidate ->
          result = decode_result(candidate.result_json)
          result[:status] == "applied" and result[:group_id] == group.group_id
        end)

      result = if cancellation, do: decode_result(cancellation.result_json), else: %{}

      cond do
        result[:refunded_cents] && result[:refunded_cents] > 0 -> {recorded_cents, 0, 0}
        result[:retained_cents] && result[:retained_cents] > 0 -> {0, recorded_cents, 0}
        result[:credit_issued_cents] && result[:credit_issued_cents] > 0 -> {0, 0, recorded_cents}
        held_cents == 0 -> {0, 0, 0}
        true -> {0, 0, 0}
      end
    end
  end
end
