defmodule GroupStay.Operations do
  @moduledoc false

  alias GroupStay.CanonicalJson
  alias GroupStay.Credits
  alias GroupStay.Deposits
  alias GroupStay.Finance
  alias GroupStay.Funding
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Operations.Record
  alias GroupStay.Payments
  alias GroupStay.Policy
  alias GroupStay.Repo

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_one/1)
  end

  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, Jason.decode!(record.result)}
    end
  end

  defp apply_one(op) do
    case durable_id(op) do
      {:ok, operation_id} -> apply_durable(op, operation_id)
      :skip -> reject(op, "invalid_operation")
    end
  end

  defp durable_id(%{"operation_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp durable_id(_), do: :skip

  defp apply_durable(op, operation_id) do
    case Repo.transaction(fn -> run_durable(op, operation_id) end, mode: :immediate) do
      {:ok, result} ->
        result

      {:error, :duplicate_operation} ->
        replay_committed(op, operation_id)
    end
  end

  defp run_durable(op, operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      %Record{} = record ->
        replay_or_conflict(record, op)

      nil ->
        maybe_fault!(op)
        result = execute(op)
        encoded = Jason.encode!(stringify_keys(result))

        case insert_record(operation_id, op, encoded) do
          :ok -> Jason.decode!(encoded)
          :duplicate -> Repo.rollback(:duplicate_operation)
        end
    end
  end

  defp replay_committed(op, operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      %Record{} = record ->
        replay_or_conflict(record, op)

      nil ->
        raise "duplicate operation #{operation_id} was not committed"
    end
  end

  defp replay_or_conflict(%Record{} = record, op) do
    if record.submission == CanonicalJson.encode(op) do
      Jason.decode!(record.result)
    else
      reject(op, "operation_id_conflict")
    end
  end

  defp execute(op) do
    if common_fields?(op) do
      dispatch(op)
    else
      reject(op, "invalid_operation")
    end
  end

  defp start_finance_reporting(op) do
    case parse_starts_on(op) do
      {:ok, starts_on} ->
        case Finance.begin!(op["operation_id"], starts_on) do
          :ok ->
            applied(op, %{starts_on: Date.to_iso8601(starts_on)})

          {:error, :already_started} ->
            reject(op, "reporting_already_started")
        end

      :error ->
        reject(op, "invalid_reporting_date")
    end
  end

  defp parse_starts_on(%{"starts_on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_starts_on(_), do: :error

  if Mix.env() == :test do
    defp maybe_fault!(op) do
      case Application.get_env(:group_stay, :operation_fault) do
        fun when is_function(fun, 1) -> fun.(op)
        _ -> :ok
      end
    end
  else
    defp maybe_fault!(_op), do: :ok
  end

  defp insert_record(operation_id, op, encoded_result) do
    changeset =
      Record.changeset(%Record{}, %{
        operation_id: operation_id,
        type: submitted_type(op),
        submission: CanonicalJson.encode(op),
        result: encoded_result
      })

    try do
      case Repo.insert(changeset) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          if duplicate?(changeset), do: :duplicate, else: raise(insert_error(changeset))
      end
    rescue
      e in Ecto.ConstraintError ->
        if e.type == :unique, do: :duplicate, else: reraise(e, __STACKTRACE__)
    end
  end

  defp duplicate?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp insert_error(changeset) do
    "failed to record operation: #{inspect(changeset.errors)}"
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp dispatch(%{"type" => "open_group"} = op), do: open_group(op)
  defp dispatch(%{"type" => "record_cash_payment"} = op), do: record_cash_payment(op)
  defp dispatch(%{"type" => "apply_hotel_credit"} = op), do: apply_hotel_credit(op)
  defp dispatch(%{"type" => "reschedule_group"} = op), do: reschedule_group(op)
  defp dispatch(%{"type" => "cancel_group"} = op), do: cancel_group(op)
  defp dispatch(%{"type" => "cancel_rooms"} = op), do: cancel_rooms(op)
  defp dispatch(%{"type" => "reduce_cash_payment"} = op), do: reduce_cash_payment(op)
  defp dispatch(%{"type" => "charge_back_payment"} = op), do: charge_back_payment(op)
  defp dispatch(%{"type" => "transfer_deposit"} = op), do: transfer_deposit(op)
  defp dispatch(%{"type" => "start_finance_reporting"} = op), do: start_finance_reporting(op)
  defp dispatch(op), do: reject(op, "invalid_operation")

  defp common_fields?(%{
         "type" => type,
         "operation_id" => operation_id,
         "occurred_on" => occurred_on
       })
       when is_binary(type) and type != "" and is_binary(operation_id) and operation_id != "" and
              is_binary(occurred_on) do
    match?({:ok, _}, Date.from_iso8601(occurred_on))
  end

  defp common_fields?(_), do: false

  defp open_group(op) do
    with {:ok, attrs} <- parse_open_shape(op),
         :ok <- validate_rate_plan(attrs.rate_plan),
         {:ok, stay} <- parse_stay(attrs),
         :ok <- validate_rooms(attrs.rooms),
         {:ok, group} <- persist_open(attrs, stay) do
      applied(op, %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      })
    else
      {:error, code} -> reject(op, code)
    end
  end

  defp parse_open_shape(op) do
    with {:ok, group_id} <- fetch_string(op, "group_id"),
         {:ok, guest_id} <- fetch_string(op, "guest_id"),
         {:ok, property_id} <- fetch_string(op, "property_id"),
         {:ok, booked_on} <- fetch_date(op, "occurred_on"),
         {:ok, arrival_on} <- fetch_string(op, "arrival_on"),
         {:ok, departure_on} <- fetch_string(op, "departure_on"),
         {:ok, rate_plan} <- fetch_string(op, "rate_plan"),
         {:ok, rooms} <- fetch_rooms(op) do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp validate_rate_plan("flexible"), do: :ok
  defp validate_rate_plan("advance_purchase"), do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp parse_stay(%{arrival_on: arrival_raw, departure_on: departure_raw}) do
    with {:ok, arrival} <- Date.from_iso8601(arrival_raw),
         {:ok, departure} <- Date.from_iso8601(departure_raw),
         nights when nights >= 1 <- Date.diff(departure, arrival) do
      {:ok, %{arrival: arrival, departure: departure, nights: nights}}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms(rooms) do
    ids = Enum.map(rooms, & &1.room_id)

    cond do
      rooms == [] -> {:error, "invalid_rooms"}
      Enum.any?(rooms, &(&1.nightly_rate_cents < 0)) -> {:error, "invalid_rooms"}
      length(ids) != length(Enum.uniq(ids)) -> {:error, "invalid_rooms"}
      true -> :ok
    end
  end

  defp persist_open(attrs, stay) do
    quote = Deposits.quote(attrs.rooms, stay.nights, attrs.rate_plan)

    Groups.create(
      %{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        booked_on: attrs.booked_on,
        arrival_on: stay.arrival,
        departure_on: stay.departure,
        rate_plan: attrs.rate_plan,
        lodging_total_cents: quote.lodging_total_cents,
        deposit_due_cents: quote.deposit_due_cents
      },
      attrs.rooms
    )
  end

  defp record_cash_payment(op) do
    with_group(op, fn group ->
      case payment_amount(op, group) do
        {:ok, amount} -> apply_payment(op, group, amount)
        {:error, code} -> {:reject, reject(op, code)}
      end
    end)
  end

  defp apply_payment(op, group, amount) do
    :ok = Funding.allocate_cash!(group, op["operation_id"], amount)
    Finance.record_receipt!(occurred_on!(op), group.property_id, amount, op["operation_id"])
    updated = Groups.refresh!(group)

    {:ok,
     applied(op, %{
       group_id: updated.group_id,
       amount_cents: amount,
       outstanding_deposit_cents: Groups.outstanding(updated),
       revision: updated.revision
     })}
  end

  defp apply_hotel_credit(op) do
    with_group(op, fn group ->
      with {:ok, amount} <- payment_amount(op, group),
           {:ok, draws} <- Credits.consume(group.guest_id, group, amount, occurred_on!(op)) do
        Finance.record_applications!(occurred_on!(op), draws, op["operation_id"])
        updated = Groups.refresh!(group)

        {:ok,
         applied(op, %{
           group_id: updated.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: Groups.outstanding(updated),
           revision: updated.revision
         })}
      else
        {:error, :insufficient_credit} ->
          {:reject, reject(op, "insufficient_credit")}

        {:error, code} when is_binary(code) ->
          {:reject, reject(op, code)}
      end
    end)
  end

  defp payment_amount(op, group) do
    amount = Map.get(op, "amount_cents")

    cond do
      group.status != "active" ->
        {:error, "group_not_active"}

      not Map.has_key?(op, "amount_cents") or is_nil(amount) ->
        {:error, "invalid_operation"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > Groups.outstanding(group) ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        {:ok, amount}
    end
  end

  defp reschedule_group(op) do
    with_group(op, fn group ->
      if group.status != "active" do
        {:reject, reject(op, "group_not_active")}
      else
        apply_reschedule(op, group)
      end
    end)
  end

  defp apply_reschedule(op, group) do
    with {:ok, new_arrival} <- fetch_new_arrival(op),
         :ok <- ensure_after_operation(new_arrival, occurred_on!(op)),
         {:ok, new_departure} <- shift_departure(group, new_arrival),
         {:ok, updated} <- Groups.reschedule(group, new_arrival, new_departure) do
      policy = Policy.for_group(updated)

      {:ok,
       applied(op, %{
         group_id: updated.group_id,
         new_arrival_on: Date.to_iso8601(updated.arrival_on),
         new_departure_on: Date.to_iso8601(updated.departure_on),
         policy_version: policy.version,
         refundable_until: iso8601(policy.refundable_until),
         revision: updated.revision
       })}
    else
      {:error, :invalid_operation} -> {:reject, reject(op, "invalid_operation")}
      {:error, :invalid_stay} -> {:reject, reject(op, "invalid_stay")}
    end
  end

  defp fetch_new_arrival(%{"new_arrival_on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_stay}
    end
  end

  defp fetch_new_arrival(_), do: {:error, :invalid_operation}

  defp ensure_after_operation(new_arrival, occurred_on) do
    if Date.compare(new_arrival, occurred_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp shift_departure(group, new_arrival) do
    shift = Date.diff(new_arrival, group.arrival_on)

    try do
      {:ok, Date.add(group.departure_on, shift)}
    rescue
      ArgumentError -> {:error, :invalid_stay}
    end
  end

  defp cancel_group(op) do
    with_group(op, fn group ->
      if group.status != "active" do
        {:reject, reject(op, "group_not_active")}
      else
        apply_cancel(op, group)
      end
    end)
  end

  defp apply_cancel(op, group) do
    occurred_on = occurred_on!(op)

    with {:ok, method} <- parse_refund_method(op),
         :ok <- ensure_refund_method(group, occurred_on, method) do
      rooms = Funding.active_rooms(group)
      {settlement, updated} = settle_selected(op, group, rooms, method)

      {:ok,
       applied(op, %{
         group_id: updated.group_id,
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: updated.revision
       })}
    else
      {:error, code} -> {:reject, reject(op, code)}
    end
  end

  defp cancel_rooms(op) do
    with_group(op, fn group ->
      if group.status != "active" do
        {:reject, reject(op, "group_not_active")}
      else
        apply_cancel_rooms(op, group)
      end
    end)
  end

  defp apply_cancel_rooms(op, group) do
    with {:ok, requested} <- fetch_room_ids(op),
         {:ok, rooms} <- select_rooms(group, requested),
         {:ok, method} <- parse_refund_method(op),
         :ok <- ensure_refund_method(group, occurred_on!(op), method) do
      {settlement, updated} = settle_selected(op, group, rooms, method)

      {:ok,
       applied(op, %{
         group_id: updated.group_id,
         cancelled_room_ids: Enum.map(rooms, & &1.room_id),
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: updated.revision
       })}
    else
      {:error, code} -> {:reject, reject(op, code)}
    end
  end

  defp settle_selected(op, group, rooms, method) do
    occurred_on = occurred_on!(op)
    room_ids = Enum.map(rooms, & &1.id)
    cash = Funding.held_cash_total(room_ids)
    applied_credit = applied_credit_total(room_ids)
    settlement = settlement_for(cash, group, occurred_on, method)

    lot =
      if settlement.credit_issued_cents > 0 do
        Credits.issue_lot!(
          group.guest_id,
          op["operation_id"],
          settlement.credit_issued_cents,
          occurred_on
        )
      end

    :ok = Funding.reclassify_held!(room_ids, cash_disposition(settlement), lot && lot.id)

    restore =
      if settlement.restore_credit do
        Credits.restore_rooms!(group, room_ids, occurred_on)
      else
        Credits.drop_rooms!(room_ids)
        nil
      end

    Finance.record_settlement!(
      occurred_on,
      group.property_id,
      settlement,
      lot,
      applied_credit,
      restore,
      op["operation_id"]
    )

    :ok = Funding.cancel_rooms!(room_ids)
    remaining = Funding.active_rooms(group)
    status = if remaining == [], do: "cancelled", else: group.status

    updated =
      Groups.refresh!(group, %{
        status: status,
        refunded_cents: group.refunded_cents + settlement.refunded_cents,
        retained_cents: group.retained_cents + settlement.retained_cents,
        cash_converted_cents: group.cash_converted_cents + settlement.cash_converted_cents
      })

    {settlement, updated}
  end

  defp applied_credit_total(room_ids) do
    room_ids
    |> Credits.applied_by_room()
    |> Map.values()
    |> Enum.sum()
  end

  defp cash_disposition(%{cash_converted_cents: amount}) when amount > 0, do: "converted"
  defp cash_disposition(%{refunded_cents: amount}) when amount > 0, do: "refunded"
  defp cash_disposition(%{retained_cents: amount}) when amount > 0, do: "retained"
  defp cash_disposition(_settlement), do: nil

  defp fetch_room_ids(op) do
    case Map.fetch(op, "room_ids") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, nil} ->
        {:error, "invalid_operation"}

      {:ok, ids} when is_list(ids) ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
          {:ok, ids}
        else
          {:error, "invalid_rooms"}
        end

      {:ok, _} ->
        {:error, "invalid_operation"}
    end
  end

  defp select_rooms(group, requested) do
    rooms = Funding.all_rooms(group)
    known = MapSet.new(Enum.map(rooms, & &1.room_id))

    active =
      rooms
      |> Enum.filter(&(&1.status == "active"))
      |> MapSet.new(& &1.room_id)

    cond do
      requested == [] ->
        {:error, "invalid_rooms"}

      length(requested) != length(Enum.uniq(requested)) ->
        {:error, "invalid_rooms"}

      not Enum.all?(requested, &MapSet.member?(known, &1)) ->
        {:error, "invalid_rooms"}

      not Enum.all?(requested, &MapSet.member?(active, &1)) ->
        {:error, "invalid_rooms"}

      true ->
        wanted = MapSet.new(requested)
        {:ok, Enum.filter(rooms, &MapSet.member?(wanted, &1.room_id))}
    end
  end

  defp reduce_cash_payment(op) do
    with {:ok, payment_operation_id} <- fetch_string(op, "payment_operation_id"),
         :ok <- require_amount_field(op) do
      reduce_payment(op, payment_operation_id)
    else
      _ -> reject(op, "invalid_operation")
    end
  end

  defp require_amount_field(op) do
    case Map.fetch(op, "amount_cents") do
      {:ok, amount} when not is_nil(amount) -> :ok
      _ -> :error
    end
  end

  defp reduce_payment(op, payment_operation_id) do
    case Payments.lookup_applied_cash(payment_operation_id) do
      :not_found ->
        reject(op, "operation_not_found")

      :not_applicable ->
        reject(op, "payment_not_reducible")

      {:ok, payment} ->
        apply_to_group(op, payment.group_id, fn group ->
          reduce_applied(op, group, payment)
        end)
    end
  end

  defp reduce_applied(op, group, payment) do
    amount = op["amount_cents"]
    held = Funding.held_for_operation(payment.operation_id)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:reject, reject(op, "invalid_amount")}

      held == 0 ->
        {:reject, reject(op, "payment_not_reducible")}

      amount > held ->
        {:reject, reject(op, "reduction_exceeds_held_cash")}

      true ->
        affected = Funding.reduce_held!(payment.operation_id, amount)
        Finance.record_reductions!(occurred_on!(op), affected, op["operation_id"])
        updated = refresh_touched!(group, Enum.map(affected, & &1.group_id))

        {:ok,
         applied(op, %{
           payment_operation_id: payment.operation_id,
           group_id: updated.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: Groups.outstanding(updated),
           revision: updated.revision
         })}
    end
  end

  defp charge_back_payment(op) do
    case fetch_string(op, "payment_operation_id") do
      {:ok, payment_operation_id} -> charge_loaded(op, payment_operation_id)
      _ -> reject(op, "invalid_operation")
    end
  end

  defp charge_loaded(op, payment_operation_id) do
    case Payments.lookup_applied_cash(payment_operation_id) do
      :not_found ->
        reject(op, "operation_not_found")

      :not_applicable ->
        reject(op, "payment_not_chargeable")

      {:ok, payment} ->
        apply_to_group(op, payment.group_id, fn group ->
          charge_applied(op, group, payment)
        end)
    end
  end

  defp charge_applied(op, group, payment) do
    cond do
      Funding.charged_back?(payment.operation_id) or
          Funding.chargeable_cents(payment.operation_id) == 0 ->
        {:reject, reject(op, "payment_not_chargeable")}

      true ->
        moved = Funding.charge_back!(payment.operation_id)

        Enum.each(moved.clawbacks, fn {lot_id, entitlement} ->
          removed = Credits.clawback!(lot_id, entitlement)
          Finance.record_revoke!(occurred_on!(op), lot_id, removed, op["operation_id"])
        end)

        Finance.record_chargeback!(occurred_on!(op), moved.per_group, op["operation_id"])
        updated = refresh_chargeback!(group, moved.per_group)

        {:ok,
         applied(op, %{
           payment_operation_id: payment.operation_id,
           group_id: updated.group_id,
           charged_back_cents: moved.charged_back_cents,
           outstanding_deposit_cents: Groups.outstanding(updated),
           revision: updated.revision
         })}
    end
  end

  defp transfer_deposit(op) do
    with {:ok, source_id} <- fetch_string(op, "source_group_id"),
         {:ok, destination_id} <- fetch_string(op, "destination_group_id") do
      transfer_between(op, source_id, destination_id)
    else
      _ -> reject(op, "invalid_operation")
    end
  end

  defp transfer_between(op, source_id, destination_id) do
    case Groups.get_by_group_id(source_id) do
      nil ->
        reject_group(op, "group_not_found", source_id)

      source ->
        case Groups.get_by_group_id(destination_id) do
          nil ->
            reject_group(op, "group_not_found", destination_id)

          destination ->
            transfer_loaded(op, source, destination)
        end
    end
  end

  defp transfer_loaded(op, source, destination) do
    with :ok <- revision_gate(op, source),
         :ok <- revision_gate(op, destination, "destination_expected_revision") do
      case transfer_rules(op, source, destination) do
        {:ok, result} -> result
        {:reject, result} -> result
      end
    else
      {:reject, result} -> result
    end
  end

  defp transfer_rules(op, source, destination) do
    amount = Map.get(op, "amount_cents")

    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:reject, reject(op, "invalid_transfer")}

      source.status != "active" ->
        {:reject, reject_group(op, "group_not_active", source.group_id)}

      destination.status != "active" ->
        {:reject, reject_group(op, "group_not_active", destination.group_id)}

      not Map.has_key?(op, "amount_cents") or is_nil(amount) ->
        {:reject, reject(op, "invalid_operation")}

      not is_integer(amount) or amount <= 0 ->
        {:reject, reject(op, "invalid_amount")}

      amount > Funding.held_funding(source) ->
        {:reject, reject(op, "transfer_exceeds_held_funding")}

      amount > Funding.available_deposit(destination) ->
        {:reject, reject(op, "transfer_exceeds_outstanding")}

      true ->
        cash = Funding.transfer_held!(source, destination, amount)

        Finance.record_transfer!(
          occurred_on!(op),
          source.property_id,
          destination.property_id,
          cash,
          op["operation_id"]
        )

        source = Groups.refresh!(source)
        destination = Groups.refresh!(destination)

        {:ok,
         applied(op, %{
           source_group_id: source.group_id,
           destination_group_id: destination.group_id,
           amount_cents: amount,
           source_outstanding_deposit_cents: Groups.outstanding(source),
           destination_outstanding_deposit_cents: Groups.outstanding(destination),
           source_revision: source.revision,
           destination_revision: destination.revision
         })}
    end
  end

  defp refresh_touched!(addressed, group_ids) do
    group_ids
    |> Enum.uniq()
    |> Enum.reject(&(&1 == addressed.id))
    |> Enum.each(fn id -> Groups.refresh!(Repo.get!(Group, id)) end)

    Groups.refresh!(addressed)
  end

  defp refresh_chargeback!(addressed, per_group) do
    per_group
    |> Enum.reject(fn {id, _deltas} -> id == addressed.id end)
    |> Enum.each(fn {id, deltas} ->
      group = Repo.get!(Group, id)
      Groups.refresh!(group, counter_delta(group, deltas))
    end)

    Groups.refresh!(addressed, counter_delta(addressed, Map.get(per_group, addressed.id, %{})))
  end

  defp counter_delta(group, deltas) do
    %{
      refunded_cents: group.refunded_cents - Map.get(deltas, :refunded_cents, 0),
      retained_cents: group.retained_cents - Map.get(deltas, :retained_cents, 0),
      cash_converted_cents: group.cash_converted_cents - Map.get(deltas, :converted_cents, 0)
    }
  end

  defp parse_refund_method(op) do
    case Map.fetch(op, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, nil} -> {:ok, "cash"}
      {:ok, "cash"} -> {:ok, "cash"}
      {:ok, "hotel_credit"} -> {:ok, "hotel_credit"}
      {:ok, _} -> {:error, "invalid_operation"}
    end
  end

  defp ensure_refund_method(_group, _occurred_on, "cash"), do: :ok

  defp ensure_refund_method(group, occurred_on, "hotel_credit") do
    if Policy.refundable?(group, occurred_on) do
      :ok
    else
      {:error, "refund_method_not_available"}
    end
  end

  defp settlement_for(cash, group, occurred_on, method) do
    refundable = Policy.refundable?(group, occurred_on)

    cond do
      refundable and method == "hotel_credit" ->
        %{
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_cents: cash,
          credit_issued_cents: Credits.issued_amount(cash),
          restore_credit: true
        }

      refundable ->
        %{
          refunded_cents: cash,
          retained_cents: 0,
          cash_converted_cents: 0,
          credit_issued_cents: 0,
          restore_credit: true
        }

      true ->
        %{
          refunded_cents: 0,
          retained_cents: cash,
          cash_converted_cents: 0,
          credit_issued_cents: 0,
          restore_credit: false
        }
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%Date{} = date), do: Date.to_iso8601(date)

  defp with_group(op, fun) do
    case op["group_id"] do
      group_id when is_binary(group_id) and group_id != "" ->
        apply_to_group(op, group_id, fun)

      _ ->
        reject(op, "invalid_operation")
    end
  end

  defp apply_to_group(op, group_id, fun) do
    case Groups.get_by_group_id(group_id) do
      nil ->
        reject(op, "group_not_found")

      group ->
        case revision_gate(op, group) do
          :ok ->
            case fun.(group) do
              {:ok, result} -> result
              {:reject, result} -> result
            end

          {:reject, result} ->
            result
        end
    end
  end

  defp revision_gate(op, group, key \\ "expected_revision") do
    case Map.fetch(op, key) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        {:reject, stale(op, group, expected)}

      {:ok, _} ->
        {:reject, reject(op, "invalid_operation")}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_date(map, key) do
    with {:ok, raw} <- fetch_string(map, key),
         {:ok, date} <- Date.from_iso8601(raw) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp fetch_rooms(%{"rooms" => rooms}) when is_list(rooms) do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, acc} ->
      case parse_room(room) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  defp fetch_rooms(_), do: :error

  defp parse_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) do
    {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
  end

  defp parse_room(_), do: :error

  defp occurred_on!(%{"occurred_on" => raw}) do
    {:ok, date} = Date.from_iso8601(raw)
    date
  end

  defp applied(op, fields) do
    Map.merge(%{operation_id: op["operation_id"], status: "applied"}, fields)
  end

  defp reject(op, code) do
    %{operation_id: operation_id(op), status: "rejected", code: code}
  end

  defp reject_group(op, code, group_id) do
    Map.put(reject(op, code), :group_id, group_id)
  end

  defp stale(op, group, expected) do
    %{
      operation_id: operation_id(op),
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: expected,
      actual_revision: group.revision
    }
  end

  defp operation_id(%{"operation_id" => id}), do: id
  defp operation_id(_), do: nil
end
