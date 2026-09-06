defmodule GroupStay.Bookings do
  import Ecto.Query

  alias GroupStay.Bookings.{
    CashAllocation,
    CashSource,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    Room
  }

  alias GroupStay.Repo

  @operation_types ~w(
    open_group
    record_cash_payment
    apply_hotel_credit
    reschedule_group
    cancel_group
    cancel_rooms
    reduce_cash_payment
    charge_back_payment
  )
  @payment_operations ~w(reduce_cash_payment charge_back_payment)
  @max_sqlite_integer 9_223_372_036_854_775_807
  @new_policy_date ~D[2027-01-01]

  def process_batch(operations), do: Enum.map(operations, &process_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    {:ok, group} =
      Repo.transaction(fn ->
        case Repo.get(Group, group_id) do
          nil -> nil
          group -> Repo.preload(group, :rooms)
        end
      end)

    group
  end

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_payment_statement(operation_id) when is_binary(operation_id) do
    {:ok, statement} =
      Repo.transaction(fn ->
        case Repo.get_by(Operation, operation_id: operation_id) do
          nil -> :not_found
          operation -> payment_statement(operation)
        end
      end)

    statement
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    {refunded, retained, converted, reduced, charged_back} =
      CashSource
      |> select(
        [s],
        {s.refunded_cents, s.retained_cents, s.converted_to_credit_cents, s.reduced_cents,
         s.charged_back_cents}
      )
      |> Repo.all()
      |> Enum.reduce({0, 0, 0, 0, 0}, fn {a, b, c, d, e}, {ta, tb, tc, td, te} ->
        {ta + a, tb + b, tc + c, td + d, te + e}
      end)

    %{
      cash_held_cents: sum_values(CashAllocation, :amount_cents),
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      cash_reduced_cents: reduced,
      cash_charged_back_cents: charged_back,
      credit_liability_cents: credit_liability(on),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  def guest_credit(guest_id, on) do
    lots =
      CreditLot
      |> where([l], l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on)
      |> order_by([l], asc: l.expires_on, asc: l.source_operation_id, asc: l.id)
      |> Repo.all()

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
    }
  end

  def read_date(nil), do: {:ok, Date.utc_today()}

  def read_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def read_date(_value), do: :error

  def serialize_group(group) do
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
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      {:ok, result} =
        Repo.transaction(
          fn -> replay_or_process(operation) end,
          mode: :immediate
        )

      result
    else
      reject(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: reject(nil, "invalid_operation")

  defp replay_or_process(operation) do
    operation_id = operation["operation_id"]

    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> process_and_remember(operation)
      stored -> replay(stored, operation)
    end
  end

  defp process_and_remember(operation) do
    result =
      try do
        process_new_operation(operation)
      catch
        {:operation_rejected, code, fields} -> reject(operation["operation_id"], code, fields)
      end

    operation_type = if is_binary(operation["type"]), do: operation["type"]

    stored =
      %Operation{}
      |> Operation.changeset(%{
        operation_id: operation["operation_id"],
        operation_type: operation_type,
        submission: operation,
        result: result
      })
      |> Repo.insert!()

    if operation_type == "record_cash_payment" and result[:status] == "applied" do
      CashSource
      |> where([s], s.payment_operation_id == ^operation["operation_id"])
      |> Repo.update_all(set: [funding_order: stored.id])
    end

    result
  end

  defp process_new_operation(operation) do
    type = Map.get(operation, "type")

    cond do
      type not in @operation_types ->
        reject_current("invalid_operation")

      not required_keys?(operation, required_keys(type)) ->
        reject_current("invalid_operation")

      type == "open_group" ->
        open_group(operation)

      type in @payment_operations ->
        update_payment(operation)

      true ->
        update_group(operation)
    end
  end

  defp replay(%Operation{submission: submission, result: result}, operation) do
    if submission === operation,
      do: result,
      else: reject(operation["operation_id"], "operation_id_conflict")
  end

  defp required_keys("open_group") do
    ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
  end

  defp required_keys(type) when type in ["record_cash_payment", "apply_hotel_credit"] do
    ~w(operation_id type occurred_on group_id amount_cents)
  end

  defp required_keys("reschedule_group") do
    ~w(operation_id type occurred_on group_id new_arrival_on)
  end

  defp required_keys("cancel_group"), do: ~w(operation_id type occurred_on group_id)

  defp required_keys("cancel_rooms"),
    do: ~w(operation_id type occurred_on group_id room_ids)

  defp required_keys("reduce_cash_payment"),
    do: ~w(operation_id type occurred_on payment_operation_id amount_cents)

  defp required_keys("charge_back_payment"),
    do: ~w(operation_id type occurred_on payment_operation_id)

  defp required_keys?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))

  defp open_group(operation) do
    operation_id = operation["operation_id"]
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      if Repo.get(Group, group_id), do: reject_current("group_already_exists")

      with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
           {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
           {:ok, departure_on} <- parse_date(operation["departure_on"]),
           :ok <- validate_stay(arrival_on, departure_on),
           :ok <- validate_rate_plan(operation["rate_plan"]),
           {:ok, rooms} <- validate_rooms(operation["rooms"]),
           :ok <- validate_open_identifiers(operation),
           {:ok, rooms, lodging_total, deposit_due} <-
             calculate_rooms(
               rooms,
               Date.diff(departure_on, arrival_on),
               operation["rate_plan"]
             ) do
        attrs = %{
          group_id: group_id,
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          policy_version: policy_version(operation["rate_plan"], booked_on),
          status: "active",
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          rooms: rooms,
          revision: 1
        }

        case %Group{} |> Group.create_changeset(attrs) |> Repo.insert() do
          {:ok, _group} ->
            applied(operation_id, %{
              group_id: group_id,
              deposit_due_cents: deposit_due,
              revision: 1
            })

          {:error, changeset} ->
            if changeset.errors[:group_id],
              do: reject_current("group_already_exists"),
              else: reject_current("invalid_operation")
        end
      else
        {:error, code} -> reject_current(code)
      end
    else
      reject_current("invalid_operation")
    end
  end

  defp update_group(operation) do
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      case Repo.get(Group, group_id) do
        nil -> reject_current("group_not_found")
        group -> check_revision_and_apply(group, operation)
      end
    else
      reject_current("invalid_operation")
    end
  end

  defp update_payment(operation) do
    payment_operation_id = operation["payment_operation_id"]

    if valid_identifier?(payment_operation_id) do
      case Repo.get_by(Operation, operation_id: payment_operation_id) do
        nil ->
          reject_current("operation_not_found")

        payment ->
          with {:ok, source} <- reducible_source(payment, operation["type"]) do
            group = Repo.get!(Group, source.group_id)
            check_revision_and_apply(group, operation, source)
          else
            {:error, code} -> reject_current(code)
          end
      end
    else
      reject_current("invalid_operation")
    end
  end

  defp reducible_source(operation, type) do
    rejection =
      if type == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    if operation.operation_type == "record_cash_payment" and
         operation.result["status"] == "applied" do
      case Repo.get_by(CashSource, payment_operation_id: operation.operation_id) do
        nil -> {:error, rejection}
        source -> {:ok, source}
      end
    else
      {:error, rejection}
    end
  end

  defp check_revision_and_apply(group, operation, source \\ nil) do
    case expected_revision(operation) do
      :none -> apply_to_group(group, operation, source)
      {:ok, revision} when revision == group.revision -> apply_to_group(group, operation, source)
      {:ok, revision} -> reject_current("stale_revision", stale_fields(group, revision))
      :invalid -> reject_current("invalid_operation")
    end
  end

  defp expected_revision(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :none
      {:ok, revision} when is_integer(revision) -> {:ok, revision}
      {:ok, _revision} -> :invalid
    end
  end

  defp stale_fields(group, expected_revision) do
    %{
      group_id: group.group_id,
      expected_revision: expected_revision,
      actual_revision: group.revision
    }
  end

  defp apply_to_group(group, operation, source) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      case operation["type"] do
        "record_cash_payment" -> record_cash_payment(group, operation)
        "apply_hotel_credit" -> apply_hotel_credit(group, operation, occurred_on)
        "reschedule_group" -> reschedule_group(group, operation, occurred_on)
        "cancel_group" -> cancel_group(group, operation, occurred_on)
        "cancel_rooms" -> cancel_rooms(group, operation, occurred_on)
        "reduce_cash_payment" -> reduce_cash_payment(group, source, operation)
        "charge_back_payment" -> charge_back_payment(group, source, operation)
      end
    else
      {:error, _code} -> reject_current("invalid_operation")
    end
  end

  defp record_cash_payment(group, operation) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        reject_current("group_not_active")

      not positive_integer?(amount) ->
        reject_current("invalid_amount")

      amount > outstanding(group) ->
        reject_current("payment_exceeds_outstanding")

      true ->
        source =
          %CashSource{}
          |> CashSource.changeset(%{
            group_id: group.group_id,
            payment_operation_id: operation["operation_id"],
            recorded_cents: amount
          })
          |> Repo.insert!()

        allocate_cash(source, group.group_id, amount)
        revision = group.revision + 1
        new_paid = group.deposit_paid_cents + amount

        update_group!(group, %{
          deposit_paid_cents: new_paid,
          cash_paid_cents: group.cash_paid_cents + amount,
          revision: revision
        })

        applied(operation["operation_id"], %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - new_paid,
          revision: revision
        })
    end
  end

  defp apply_hotel_credit(group, operation, occurred_on) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        reject_current("group_not_active")

      not positive_integer?(amount) ->
        reject_current("invalid_amount")

      amount > outstanding(group) ->
        reject_current("payment_exceeds_outstanding")

      true ->
        lots = available_credit_lots(group.guest_id, occurred_on)

        if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
          reject_current("insufficient_credit")
        end

        allocate_credit(lots, group.group_id, operation["operation_id"], amount)
        revision = group.revision + 1
        new_paid = group.deposit_paid_cents + amount

        update_group!(group, %{
          deposit_paid_cents: new_paid,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: revision
        })

        applied(operation["operation_id"], %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: group.deposit_due_cents - new_paid,
          revision: revision
        })
    end
  end

  defp reschedule_group(group, operation, occurred_on) do
    if group.status != "active" do
      reject_current("group_not_active")
    end

    case parse_date(operation["new_arrival_on"]) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          shift = Date.diff(new_arrival_on, group.arrival_on)
          new_departure_on = Date.add(group.departure_on, shift)
          revision = group.revision + 1

          update_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: revision
          })

          updated_group = %{group | arrival_on: new_arrival_on}

          applied(operation["operation_id"], %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            policy_version: policy_version(group),
            refundable_until: refundable_until(updated_group),
            revision: revision
          })
        else
          reject_current("invalid_stay")
        end

      _ ->
        reject_current("invalid_stay")
    end
  end

  defp cancel_group(group, operation, occurred_on) do
    if group.status == "active" do
      settle_rooms(group, active_rooms(group.group_id), operation, occurred_on, :group)
    else
      reject_current("group_not_active")
    end
  end

  defp cancel_rooms(group, operation, occurred_on) do
    if group.status != "active", do: reject_current("group_not_active")

    room_ids = operation["room_ids"]

    unless is_list(room_ids) and room_ids != [] and
             Enum.all?(room_ids, &valid_identifier?/1) and
             length(Enum.uniq(room_ids)) == length(room_ids) do
      reject_current("invalid_rooms")
    end

    rooms =
      Room
      |> where([r], r.group_id == ^group.group_id and r.room_id in ^room_ids)
      |> order_by([r], asc: r.position)
      |> Repo.all()

    if length(rooms) != length(room_ids) or Enum.any?(rooms, &(&1.status != "active")) do
      reject_current("invalid_rooms")
    end

    settle_rooms(group, rooms, operation, occurred_on, :rooms)
  end

  defp settle_rooms(group, rooms, operation, occurred_on, result_type) do
    refund_method = Map.get(operation, "refund_method", "cash")
    refundable = refundable?(group, occurred_on)

    cond do
      refund_method not in ["cash", "hotel_credit"] ->
        reject_current("invalid_operation")

      refund_method == "hotel_credit" and not refundable ->
        reject_current("refund_method_not_available")

      true ->
        room_ids = Enum.map(rooms, & &1.id)
        cash_by_source = cash_for_rooms(room_ids)

        {refunded, retained, converted, credit_issued} =
          settle_cash(
            cash_by_source,
            group,
            operation,
            occurred_on,
            refundable,
            refund_method
          )

        settle_credit(room_ids, occurred_on, refundable)
        delete_cash_allocations(room_ids)
        cancel_room_records(rooms)

        revision = group.revision + 1
        group_attrs = active_group_totals(group.group_id)

        update_group!(
          group,
          Map.merge(group_attrs, %{
            refunded_cents: group.refunded_cents + refunded,
            retained_cents: group.retained_cents + retained,
            cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
            revision: revision
          })
        )

        fields = %{
          group_id: group.group_id,
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: credit_issued,
          revision: revision
        }

        fields =
          if result_type == :rooms,
            do: Map.put(fields, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
            else: fields

        applied(operation["operation_id"], fields)
    end
  end

  defp settle_cash(cash_by_source, group, operation, occurred_on, true, "hotel_credit") do
    principal = Enum.sum(Enum.map(cash_by_source, &elem(&1, 1)))
    credit_issued = principal + rounded_percentage(principal, 10)

    if credit_issued > 0 do
      lot =
        %CreditLot{}
        |> CreditLot.changeset(%{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          remaining_cents: credit_issued,
          expires_on: Date.add(occurred_on, 365)
        })
        |> Repo.insert!()

      cash_by_source
      |> Enum.sort_by(fn {source, _amount} -> {source.funding_order || 0, source.id} end)
      |> Enum.reduce({0, 0}, fn {source, amount}, {principal_so_far, entitlement_so_far} ->
        next_principal = principal_so_far + amount
        next_entitlement = next_principal + rounded_percentage(next_principal, 10)

        %CreditEntitlement{}
        |> CreditEntitlement.changeset(%{
          credit_lot_id: lot.id,
          cash_source_id: source.id,
          principal_cents: amount,
          entitlement_cents: next_entitlement - entitlement_so_far
        })
        |> Repo.insert!()

        update_cash_source!(source, %{
          converted_to_credit_cents: source.converted_to_credit_cents + amount
        })

        {next_principal, next_entitlement}
      end)
    end

    {0, 0, principal, credit_issued}
  end

  defp settle_cash(cash_by_source, _group, _operation, _occurred_on, true, "cash") do
    total = classify_cash(cash_by_source, :refunded_cents)
    {total, 0, 0, 0}
  end

  defp settle_cash(cash_by_source, _group, _operation, _occurred_on, false, "cash") do
    total = classify_cash(cash_by_source, :retained_cents)
    {0, total, 0, 0}
  end

  defp classify_cash(cash_by_source, field) do
    Enum.reduce(cash_by_source, 0, fn {source, amount}, total ->
      update_cash_source!(source, %{field => Map.fetch!(source, field) + amount})
      total + amount
    end)
  end

  defp reduce_cash_payment(group, source, operation) do
    held = held_cash(source.id)
    amount = operation["amount_cents"]

    cond do
      held == 0 ->
        reject_current("payment_not_reducible")

      not positive_integer?(amount) ->
        reject_current("invalid_amount")

      amount > held ->
        reject_current("reduction_exceeds_held_cash")

      true ->
        remove_cash_allocations(source.id, amount)

        update_cash_source!(source, %{reduced_cents: source.reduced_cents + amount})
        revision = group.revision + 1
        attrs = active_group_totals(group.group_id) |> Map.put(:revision, revision)
        updated = update_group!(group, attrs)

        applied(operation["operation_id"], %{
          payment_operation_id: source.payment_operation_id,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(updated),
          revision: revision
        })
    end
  end

  defp charge_back_payment(group, source, operation) do
    chargeable = source.recorded_cents - source.reduced_cents

    if chargeable <= 0 or source.charged_back_cents > 0 do
      reject_current("payment_not_chargeable")
    end

    remove_cash_allocations(source.id, held_cash(source.id))
    revoke_credit_entitlements(source.id)

    update_cash_source!(source, %{
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      charged_back_cents: source.charged_back_cents + chargeable
    })

    revision = group.revision + 1

    attrs =
      group.group_id
      |> active_group_totals()
      |> Map.merge(%{
        refunded_cents: group.refunded_cents - source.refunded_cents,
        retained_cents: group.retained_cents - source.retained_cents,
        cash_converted_to_credit_cents:
          group.cash_converted_to_credit_cents - source.converted_to_credit_cents,
        revision: revision
      })

    updated = update_group!(group, attrs)

    applied(operation["operation_id"], %{
      payment_operation_id: source.payment_operation_id,
      group_id: group.group_id,
      charged_back_cents: chargeable,
      outstanding_deposit_cents: outstanding(updated),
      revision: revision
    })
  end

  defp revoke_credit_entitlements(source_id) do
    CreditEntitlement
    |> where([e], e.cash_source_id == ^source_id)
    |> order_by([e], asc: e.id)
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      amount = entitlement.entitlement_cents - entitlement.revoked_cents

      if amount > 0 do
        lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
        removed = min(lot.remaining_cents, amount)

        lot
        |> CreditLot.changeset(%{
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - removed
        })
        |> Repo.update!()

        entitlement
        |> CreditEntitlement.changeset(%{revoked_cents: entitlement.entitlement_cents})
        |> Repo.update!()
      end
    end)
  end

  defp payment_statement(operation) do
    if operation.operation_type == "record_cash_payment" and
         operation.result["status"] == "applied" do
      source = Repo.get_by!(CashSource, payment_operation_id: operation.operation_id)

      {:ok,
       %{
         payment_operation_id: source.payment_operation_id,
         original_group_id: source.group_id,
         recorded_cents: source.recorded_cents,
         held_cents: held_cash(source.id),
         refunded_cents: source.refunded_cents,
         retained_cents: source.retained_cents,
         converted_to_credit_cents: source.converted_to_credit_cents,
         reduced_cents: source.reduced_cents,
         charged_back_cents: source.charged_back_cents
       }}
    else
      :not_reconcilable
    end
  end

  defp allocate_cash(source, group_id, amount) do
    group_id
    |> room_funding_plan(amount)
    |> Enum.each(fn {room, room_amount} ->
      %CashAllocation{}
      |> CashAllocation.changeset(%{
        cash_source_id: source.id,
        room_id: room.id,
        amount_cents: room_amount
      })
      |> Repo.insert!()

      update_room!(room, %{cash_paid_cents: room.cash_paid_cents + room_amount})
    end)
  end

  defp allocate_credit(lots, group_id, operation_id, amount) do
    room_plan = room_funding_plan(group_id, amount)
    consume_credit_plan(lots, room_plan, group_id, operation_id)
  end

  defp consume_credit_plan(_lots, [], _group_id, _operation_id), do: :ok

  defp consume_credit_plan([lot | lots], [{room, room_amount} | rooms], group_id, operation_id) do
    consumed = min(lot.remaining_cents, room_amount)

    lot
    |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - consumed})
    |> Repo.update!()

    %CreditAllocation{}
    |> CreditAllocation.changeset(%{
      credit_lot_id: lot.id,
      group_id: group_id,
      room_id: room.id,
      funding_operation_id: operation_id,
      amount_cents: consumed
    })
    |> Repo.insert!()

    update_room!(room, %{credit_paid_cents: room.credit_paid_cents + consumed})

    next_lots =
      if consumed == lot.remaining_cents,
        do: lots,
        else: [%{lot | remaining_cents: lot.remaining_cents - consumed} | lots]

    next_rooms =
      if consumed == room_amount,
        do: rooms,
        else: [
          {%{room | credit_paid_cents: room.credit_paid_cents + consumed}, room_amount - consumed}
          | rooms
        ]

    consume_credit_plan(next_lots, next_rooms, group_id, operation_id)
  end

  defp room_funding_plan(group_id, amount) do
    rooms = active_rooms(group_id)

    {plan, remaining} =
      Enum.reduce(rooms, {[], amount}, fn room, {plan, needed} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        allocated = min(capacity, needed)
        plan = if allocated > 0, do: plan ++ [{room, allocated}], else: plan
        {plan, needed - allocated}
      end)

    if remaining != 0, do: raise("funding allocation exceeded active room deposits")
    plan
  end

  defp cash_for_rooms(room_ids) do
    CashAllocation
    |> where([a], a.room_id in ^room_ids)
    |> join(:inner, [a], s in assoc(a, :cash_source))
    |> order_by([_a, s], asc_nulls_first: s.funding_order, asc: s.id)
    |> select([a, s], {s, a.amount_cents})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {source, amounts} -> {source, Enum.sum(amounts)} end)
  end

  defp settle_credit(room_ids, occurred_on, refundable) do
    CreditAllocation
    |> where([a], a.room_id in ^room_ids)
    |> order_by([a], asc: a.id)
    |> Repo.all()
    |> Enum.each(fn allocation ->
      if refundable do
        restore_credit(allocation.credit_lot_id, allocation.amount_cents, occurred_on)
      end

      Repo.delete!(allocation)
    end)
  end

  defp restore_credit(lot_id, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    restored = amount - absorbed

    remaining =
      if Date.compare(lot.expires_on, occurred_on) == :lt,
        do: lot.remaining_cents,
        else: lot.remaining_cents + restored

    lot
    |> CreditLot.changeset(%{
      remaining_cents: remaining,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    })
    |> Repo.update!()
  end

  defp delete_cash_allocations(room_ids) do
    CashAllocation |> where([a], a.room_id in ^room_ids) |> Repo.delete_all()
  end

  defp cancel_room_records(rooms) do
    Enum.each(rooms, fn room ->
      update_room!(room, %{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
    end)
  end

  defp remove_cash_allocations(_source_id, 0), do: :ok

  defp remove_cash_allocations(source_id, amount) do
    allocations =
      CashAllocation
      |> where([a], a.cash_source_id == ^source_id)
      |> join(:inner, [a], r in assoc(a, :room))
      |> order_by([a, r], desc: r.position, desc: a.id)
      |> select([a, _r], a)
      |> Repo.all()

    remaining =
      Enum.reduce_while(allocations, amount, fn allocation, needed ->
        removed = min(allocation.amount_cents, needed)
        room = Repo.get!(Room, allocation.room_id)
        update_room!(room, %{cash_paid_cents: room.cash_paid_cents - removed})

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation
          |> CashAllocation.changeset(%{amount_cents: allocation.amount_cents - removed})
          |> Repo.update!()
        end

        if removed == needed, do: {:halt, 0}, else: {:cont, needed - removed}
      end)

    if remaining != 0, do: raise("cash allocation balance is inconsistent")
  end

  defp held_cash(source_id) do
    CashAllocation
    |> where([a], a.cash_source_id == ^source_id)
    |> select([a], sum(a.amount_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp active_rooms(group_id) do
    Room
    |> where([r], r.group_id == ^group_id and r.status == "active")
    |> order_by([r], asc: r.position, asc: r.id)
    |> Repo.all()
  end

  defp active_group_totals(group_id) do
    rooms = active_rooms(group_id)
    cash = Enum.sum(Enum.map(rooms, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(rooms, & &1.credit_paid_cents))

    %{
      status: if(rooms == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.sum(Enum.map(rooms, & &1.lodging_total_cents)),
      deposit_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }
  end

  defp credit_liability(on) do
    available =
      CreditLot
      |> where([l], l.remaining_cents > 0 and l.expires_on >= ^on)
      |> select([l], l.remaining_cents)
      |> Repo.all()
      |> Enum.sum()

    applied =
      CreditAllocation
      |> join(:inner, [a], r in Room, on: r.id == a.room_id)
      |> where([_a, r], r.status == "active")
      |> select([a, _r], a.amount_cents)
      |> Repo.all()
      |> Enum.sum()

    available + applied
  end

  defp credit_shortfall do
    CreditLot
    |> where([l], l.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      applied =
        CreditAllocation
        |> where([a], a.credit_lot_id == ^lot.id)
        |> join(:inner, [a], r in Room, on: r.id == a.room_id)
        |> where([_a, r], r.status == "active")
        |> select([a, _r], sum(a.amount_cents))
        |> Repo.one()
        |> Kernel.||(0)

      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp sum_values(schema, field_name) do
    schema
    |> select([row], field(row, ^field_name))
    |> Repo.all()
    |> Enum.sum()
  end

  defp reject_current(code, fields \\ %{}), do: throw({:operation_rejected, code, fields})

  defp update_group!(group, attrs) do
    group |> Group.update_changeset(attrs) |> Repo.update!()
  end

  defp update_room!(room, attrs) do
    room |> Room.changeset(attrs) |> Repo.update!()
  end

  defp update_cash_source!(source, attrs) do
    source |> CashSource.changeset(attrs) |> Repo.update!()
  end

  defp validate_open_identifiers(operation) do
    if valid_identifier?(operation["guest_id"]) and valid_identifier?(operation["property_id"]),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"], do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    normalized =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn
        {%{"room_id" => room_id, "nightly_rate_cents" => rate}, position}
        when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(rate) and rate > 0 and
               rate <= @max_sqlite_integer ->
          %{room_id: room_id, nightly_rate_cents: rate, position: position}

        _ ->
          :invalid
      end)

    room_ids = Enum.map(normalized, &if(is_map(&1), do: &1.room_id, else: nil))

    if :invalid in normalized or length(Enum.uniq(room_ids)) != length(room_ids),
      do: {:error, "invalid_rooms"},
      else: {:ok, normalized}
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp calculate_rooms(rooms, nights, rate_plan) do
    rooms =
      Enum.map(rooms, fn room ->
        lodging = room.nightly_rate_cents * nights

        deposit =
          if rate_plan == "advance_purchase", do: lodging, else: rounded_percentage(lodging, 20)

        Map.merge(room, %{
          status: "active",
          lodging_total_cents: lodging,
          deposit_due_cents: deposit,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      end)

    lodging_total = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
    deposit_due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

    if Enum.all?(rooms, &(&1.lodging_total_cents <= @max_sqlite_integer)) and
         lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer,
       do: {:ok, rooms, lodging_total, deposit_due},
       else: {:error, "invalid_rooms"}
  end

  defp policy_version(%Group{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(%Group{} = group), do: policy_version(group.rate_plan, group.booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @new_policy_date) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14) |> Date.to_iso8601()
      "flex-30" -> Date.add(group.arrival_on, -30) |> Date.to_iso8601()
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case policy_version(group) do
      "flex-14" -> Date.compare(occurred_on, Date.add(group.arrival_on, -14)) != :gt
      "flex-30" -> Date.compare(occurred_on, Date.add(group.arrival_on, -30)) != :gt
      "advance-nonrefundable" -> false
    end
  end

  defp available_credit_lots(guest_id, occurred_on) do
    CreditLot
    |> where(
      [l],
      l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred_on
    )
    |> order_by([l], asc: l.expires_on, asc: l.source_operation_id, asc: l.id)
    |> Repo.all()
  end

  defp rounded_percentage(amount, percentage), do: div(amount * percentage + 50, 100)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp outstanding(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding(%Group{}), do: 0

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp applied(operation_id, fields) do
    fields |> Map.put(:operation_id, operation_id) |> Map.put(:status, "applied")
  end

  defp reject(operation_id, code, fields \\ %{}) do
    fields
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "rejected")
    |> Map.put(:code, code)
  end
end
