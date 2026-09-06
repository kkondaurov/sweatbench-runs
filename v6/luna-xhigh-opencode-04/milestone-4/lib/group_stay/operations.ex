defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditLot,
    CreditLotContribution,
    Group,
    LedgerEntry,
    OperationRecord,
    PaymentAccounting,
    Repo,
    Room
  }

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

  @disposition_kinds ~w(refunded retained converted_to_credit)

  @spec process_batch([map()]) :: [map()]
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec get_group(String.t()) :: {:ok, map()} | :error
  def get_group(group_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(Group, group_id: group_id) do
             nil ->
               :error

             group ->
               ensure_group_accounting(group)
               group = Repo.get!(Group, group.id)
               rooms = rooms_for(group.id)
               render_group(group, rooms)
           end
         end) do
      {:ok, result} ->
        case result do
          :error -> :error
          group -> {:ok, group}
        end

      {:error, _reason} ->
        :error
    end
  end

  @doc false
  def backfill_all_groups do
    Repo.all(Group)
    |> Enum.each(fn group ->
      case Repo.transaction(fn -> ensure_group_accounting(group) end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> raise "room accounting backfill failed: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @spec get_operation(String.t()) :: {:ok, map()} | :error
  def get_operation(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> :error
      record -> {:ok, record.result}
    end
  end

  @spec get_payment_reconciliation(String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_reconcilable}
  def get_payment_reconciliation(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :not_found}

      %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"} = result} ->
        case Repo.get_by(PaymentAccounting, payment_operation_id: payment_operation_id) do
          nil ->
            {:ok, legacy_payment_reconciliation(result, payment_operation_id)}

          accounting ->
            {:ok,
             %{
               "payment_operation_id" => payment_operation_id,
               "original_group_id" => result["group_id"],
               "recorded_cents" => accounting.recorded_cents,
               "held_cents" => accounting.held_cents,
               "refunded_cents" => accounting.refunded_cents,
               "retained_cents" => accounting.retained_cents,
               "converted_to_credit_cents" => accounting.converted_to_credit_cents,
               "reduced_cents" => accounting.reduced_cents,
               "charged_back_cents" => accounting.charged_back_cents
             }}
        end

      _record ->
        {:error, :not_reconcilable}
    end
  end

  defp legacy_payment_reconciliation(result, payment_operation_id) do
    recorded = result["amount_cents"] || 0

    disposition =
      case Repo.get_by(Group, group_id: result["group_id"]) do
        %Group{} = group ->
          dispositions =
            durable_funding_records(group.group_id)
            |> Enum.filter(&(&1.type == "record_cash_payment"))
            |> then(&backfilled_dispositions(group, &1))

          Map.get(dispositions, payment_operation_id, %{})

        nil ->
          %{}
      end

    %{
      "payment_operation_id" => payment_operation_id,
      "original_group_id" => result["group_id"],
      "recorded_cents" => recorded,
      "held_cents" => Map.get(disposition, :held, if(disposition == %{}, do: recorded, else: 0)),
      "refunded_cents" => Map.get(disposition, :refunded, 0),
      "retained_cents" => Map.get(disposition, :retained, 0),
      "converted_to_credit_cents" => Map.get(disposition, :converted_to_credit, 0),
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  @spec credit_for_guest(String.t(), Date.t()) :: map()
  def credit_for_guest(guest_id, as_of) do
    lots = available_credit_lots(guest_id, as_of)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  @spec parse_report_date(term()) :: {:ok, Date.t()} | {:error, :invalid_date}
  def parse_report_date(nil), do: {:ok, Date.utc_today()}

  def parse_report_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def parse_report_date(_value), do: {:error, :invalid_date}

  @spec ledger_totals(Date.t()) :: map()
  def ledger_totals(as_of) do
    legacy_totals =
      Repo.all(
        from entry in LedgerEntry,
          group_by: entry.kind,
          select: {entry.kind, sum(entry.amount_cents)}
      )
      |> Map.new(fn {kind, amount} -> {kind, amount || 0} end)

    account_totals =
      Repo.one(
        from accounting in PaymentAccounting,
          select: %{
            recorded: sum(accounting.recorded_cents),
            held: sum(accounting.held_cents),
            refunded: sum(accounting.refunded_cents),
            retained: sum(accounting.retained_cents),
            converted: sum(accounting.converted_to_credit_cents),
            reduced: sum(accounting.reduced_cents),
            charged_back: sum(accounting.charged_back_cents)
          }
      ) || %{}

    backfilled_totals =
      Repo.one(
        from accounting in PaymentAccounting,
          where: accounting.backfilled == true,
          select: %{
            recorded: sum(accounting.recorded_cents),
            refunded: sum(accounting.backfilled_refunded_cents),
            retained: sum(accounting.backfilled_retained_cents),
            converted: sum(accounting.backfilled_converted_to_credit_cents)
          }
      ) || %{}

    account_recorded = Map.get(backfilled_totals, :recorded, 0) || 0
    legacy_recorded = max(Map.get(legacy_totals, "held", 0) - account_recorded, 0)

    refunded = Map.get(account_totals, :refunded, 0) || 0
    retained = Map.get(account_totals, :retained, 0) || 0
    converted = Map.get(account_totals, :converted, 0) || 0
    reduced = Map.get(account_totals, :reduced, 0) || 0
    charged_back = Map.get(account_totals, :charged_back, 0) || 0

    legacy_refunded =
      max(
        Map.get(legacy_totals, "refunded", 0) - (Map.get(backfilled_totals, :refunded, 0) || 0),
        0
      )

    legacy_retained =
      max(
        Map.get(legacy_totals, "retained", 0) - (Map.get(backfilled_totals, :retained, 0) || 0),
        0
      )

    legacy_converted =
      max(
        Map.get(legacy_totals, "converted_to_credit", 0) -
          (Map.get(backfilled_totals, :converted, 0) || 0),
        0
      )

    legacy_reduced =
      max(
        Map.get(legacy_totals, "reduced", 0) - (Map.get(backfilled_totals, :reduced, 0) || 0),
        0
      )

    legacy_charged_back =
      max(
        Map.get(legacy_totals, "charged_back", 0) -
          (Map.get(backfilled_totals, :charged_back, 0) || 0),
        0
      )

    %{
      "cash_held_cents" =>
        (Map.get(account_totals, :held, 0) || 0) +
          max(
            legacy_recorded - legacy_refunded - legacy_retained - legacy_converted -
              legacy_reduced - legacy_charged_back,
            0
          ),
      "cash_refunded_cents" => refunded + legacy_refunded,
      "cash_retained_cents" => retained + legacy_retained,
      "cash_converted_to_credit_cents" => converted + legacy_converted,
      "cash_reduced_cents" => reduced + legacy_reduced,
      "cash_charged_back_cents" => charged_back + legacy_charged_back,
      "credit_liability_cents" => credit_liability(as_of),
      "credit_shortfall_cents" => credit_shortfall()
    }
  end

  def ledger_totals, do: ledger_totals(Date.utc_today())

  defp process_operation(operation) when not is_map(operation) do
    rejection(operation, "invalid_operation")
  end

  defp process_operation(operation) do
    case Repo.transaction(
           fn ->
             if valid_identifier(Map.get(operation, "operation_id")) do
               process_durable_operation(operation)
             else
               process_operation_once(operation)
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
    end
  end

  defp process_durable_operation(operation) do
    operation_id = operation["operation_id"]

    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        result = process_operation_once(operation)

        Repo.insert!(%OperationRecord{
          operation_id: operation_id,
          type: operation_type(operation["type"]),
          payload: operation,
          result: result
        })

        result

      %OperationRecord{payload: payload, result: result} when payload === operation ->
        result

      _record ->
        rejection(operation, "operation_id_conflict")
    end
  end

  defp process_operation_once(operation) do
    case Map.get(operation, "type") do
      "open_group" -> process_open_group(operation)
      type when type in @operation_types -> process_existing(operation, type)
      _ -> rejection(operation, "invalid_operation")
    end
  end

  defp process_open_group(operation) do
    with :ok <- validate_common_fields(operation),
         {:ok, group_id} <- required_identifier(operation, "group_id"),
         {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms, lodging_total, deposit_due} <-
           validate_rooms(operation["rooms"], arrival_on, departure_on, rate_plan) do
      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      }

      insert_group(operation, attrs, rooms)
    else
      {:error, code} -> rejection(operation, code)
    end
  end

  defp insert_group(operation, attrs, rooms) do
    case Repo.get_by(Group, group_id: attrs.group_id) do
      nil ->
        group = Repo.insert!(struct(Group, attrs))

        Enum.each(rooms, fn room ->
          Repo.insert!(%Room{
            group_id: group.id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position,
            status: "active",
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          })
        end)

        %{
          "operation_id" => operation["operation_id"],
          "status" => "applied",
          "group_id" => group.group_id,
          "deposit_due_cents" => group.deposit_due_cents,
          "revision" => group.revision
        }

      _group ->
        rejection(operation, "group_already_exists", %{"group_id" => attrs.group_id})
    end
  end

  defp process_existing(operation, type)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    apply_payment_operation(operation, type)
  end

  defp process_existing(operation, type) do
    case required_identifier(operation, "group_id") do
      {:ok, group_id} ->
        apply_existing(operation, type, group_id)

      {:error, code} ->
        rejection(operation, code)
    end
  end

  defp apply_existing(operation, type, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        rejection(operation, "group_not_found", %{"group_id" => group_id})

      group ->
        case stale_revision(operation, group) do
          :ok ->
            case prevalidate_existing(operation, type, group) do
              :ok ->
                ensure_group_accounting(group)
                group = Repo.get!(Group, group.id)
                apply_existing_with_revision(operation, type, group)

              {:error, code} ->
                rejection(operation, code, %{"group_id" => group.group_id})
            end

          {:error, result} ->
            result
        end
    end
  end

  defp apply_existing_with_revision(operation, type, group) do
    with :ok <- validate_existing_fields(operation, type),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      case type do
        "record_cash_payment" -> apply_cash_payment(operation, group)
        "apply_hotel_credit" -> apply_hotel_credit(operation, group, occurred_on)
        "reschedule_group" -> apply_reschedule(operation, group, occurred_on)
        "cancel_group" -> apply_cancellation(operation, group, occurred_on)
        "cancel_rooms" -> apply_room_cancellation(operation, group, occurred_on)
      end
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp prevalidate_existing(operation, "record_cash_payment", group) do
    with :ok <- validate_existing_fields(operation, "record_cash_payment"),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- aggregate_outstanding(group) do
      :ok
    else
      {:error, code} -> {:error, code}
      _ -> {:error, "payment_exceeds_outstanding"}
    end
  end

  defp prevalidate_existing(operation, "apply_hotel_credit", group) do
    with :ok <- validate_existing_fields(operation, "apply_hotel_credit"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- aggregate_outstanding(group),
         lots <- available_credit_lots(group.guest_id, occurred_on),
         {:ok, _allocations} <- allocate_credit(lots, amount) do
      :ok
    else
      {:error, code} -> {:error, code}
      _ -> {:error, "payment_exceeds_outstanding"}
    end
  end

  defp prevalidate_existing(operation, "reschedule_group", group) do
    with :ok <- validate_existing_fields(operation, "reschedule_group"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_reschedule_date(new_arrival_on, occurred_on) do
      :ok
    else
      {:error, code} -> {:error, code}
    end
  end

  defp prevalidate_existing(operation, "cancel_group", group) do
    with :ok <- validate_existing_fields(operation, "cancel_group"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation) do
      if refundable?(group, occurred_on) or refund_method == "cash",
        do: :ok,
        else: {:error, "refund_method_not_available"}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp prevalidate_existing(operation, "cancel_rooms", group) do
    with :ok <- validate_existing_fields(operation, "cancel_rooms"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation),
         {:ok, _rooms} <- selected_rooms(group, operation["room_ids"]) do
      if refundable?(group, occurred_on) or refund_method == "cash",
        do: :ok,
        else: {:error, "refund_method_not_available"}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp aggregate_outstanding(group),
    do: max((group.deposit_due_cents || 0) - (group.deposit_paid_cents || 0), 0)

  defp apply_cash_payment(operation, group) do
    with :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- outstanding_deposit(group) do
      allocate_cash_to_rooms(group, amount, operation["operation_id"])
      new_revision = group.revision + 1

      accounting = %PaymentAccounting{
        payment_operation_id: operation["operation_id"],
        group_id: group.id,
        recorded_cents: amount,
        held_cents: amount,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      }

      Repo.insert!(accounting)
      updated_group = update_group_revision(group, new_revision)

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => new_revision
      }
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})

      _ ->
        rejection(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})
    end
  end

  defp apply_hotel_credit(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, amount} <- usable_payment_amount(operation["amount_cents"]),
         outstanding when amount <= outstanding <- outstanding_deposit(group),
         lots <- available_credit_lots(group.guest_id, occurred_on),
         {:ok, allocations} <- allocate_credit(lots, amount) do
      Enum.each(allocations, fn {lot, allocated} ->
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - allocated))
      end)

      allocate_credit_to_rooms(group, allocations, operation["operation_id"])
      new_revision = group.revision + 1
      updated_group = update_group_revision(group, new_revision)

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => new_revision
      }
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})

      _ ->
        rejection(operation, "payment_exceeds_outstanding", %{"group_id" => group.group_id})
    end
  end

  defp apply_reschedule(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- validate_reschedule_date(new_arrival_on, occurred_on) do
      day_shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, day_shift)
      new_revision = group.revision + 1

      Repo.update!(
        Ecto.Changeset.change(group,
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: new_revision
        )
      )

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival_on),
        "new_departure_on" => Date.to_iso8601(new_departure_on),
        "revision" => new_revision
      }
      |> Map.merge(policy_fields(%{group | arrival_on: new_arrival_on}))
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp apply_cancellation(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation) do
      refundable? = refundable?(group, occurred_on)

      if refundable? or refund_method == "cash" do
        active_rooms = Enum.filter(rooms_for(group.id), &(&1.status == "active"))

        settle_rooms(
          operation,
          group,
          active_rooms,
          occurred_on,
          refund_method,
          refundable?,
          false
        )
      else
        rejection(operation, "refund_method_not_available", %{"group_id" => group.group_id})
      end
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp apply_room_cancellation(operation, group, occurred_on) do
    with :ok <- active_group(group),
         {:ok, refund_method} <- cancellation_refund_method(operation),
         {:ok, rooms} <- selected_rooms(group, operation["room_ids"]) do
      refundable? = refundable?(group, occurred_on)

      if refundable? or refund_method == "cash" do
        settle_rooms(operation, group, rooms, occurred_on, refund_method, refundable?, true)
      else
        rejection(operation, "refund_method_not_available", %{"group_id" => group.group_id})
      end
    else
      {:error, code} ->
        rejection(operation, code, %{"group_id" => group.group_id})
    end
  end

  defp settle_rooms(operation, group, rooms, occurred_on, refund_method, refundable?, selected?) do
    room_ids = MapSet.new(Enum.map(rooms, & &1.id))

    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.group_id == ^group.id and allocation.room_id in ^MapSet.to_list(room_ids),
          order_by: [asc: allocation.id]
      )

    cash_by_source =
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {source, allocations} ->
        {source, Enum.sum(Enum.map(allocations, & &1.amount_cents))}
      end)

    Enum.each(cash_allocations, fn allocation -> Repo.delete!(allocation) end)

    rooms
    |> Enum.each(fn room ->
      amount =
        cash_allocations
        |> Enum.filter(&(&1.room_id == room.id))
        |> Enum.sum_by(& &1.amount_cents)

      if amount > 0 do
        Repo.update!(
          Ecto.Changeset.change(room, cash_paid_cents: max(room.cash_paid_cents - amount, 0))
        )
      end
    end)

    {ledger_kind, refunded, retained} =
      cond do
        refundable? and refund_method == "hotel_credit" -> {"converted_to_credit", 0, 0}
        refundable? -> {"refunded", Enum.sum(Enum.map(cash_by_source, &elem(&1, 1))), 0}
        true -> {"retained", 0, Enum.sum(Enum.map(cash_by_source, &elem(&1, 1)))}
      end

    Enum.each(cash_by_source, fn {source, amount} ->
      settle_cash_source(source, group, amount, ledger_kind)
    end)

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where:
            allocation.group_id == ^group.id and allocation.room_id in ^MapSet.to_list(room_ids),
          order_by: [asc: allocation.id]
      )

    Enum.each(credit_allocations, fn allocation -> Repo.delete!(allocation) end)

    credit_allocations
    |> Enum.group_by(& &1.room_id)
    |> Enum.each(fn {room_id, allocations} ->
      room = Repo.get!(Room, room_id)
      amount = Enum.sum(Enum.map(allocations, & &1.amount_cents))

      Repo.update!(
        Ecto.Changeset.change(room, credit_paid_cents: max(room.credit_paid_cents - amount, 0))
      )
    end)

    if refundable? do
      credit_allocations
      |> Enum.group_by(& &1.credit_lot_id)
      |> Enum.each(fn {lot_id, allocations} ->
        restore_credit_amount(
          Repo.get!(CreditLot, lot_id),
          Enum.sum(Enum.map(allocations, & &1.amount_cents)),
          occurred_on
        )
      end)
    end

    Enum.each(rooms, fn room ->
      Repo.update!(Ecto.Changeset.change(room, status: "cancelled"))
    end)

    credit_issued =
      if refundable? and refund_method == "hotel_credit" do
        issue_credit_lot(
          group,
          operation["operation_id"],
          occurred_on,
          Enum.sum(Enum.map(cash_by_source, &elem(&1, 1))),
          cash_by_source
        )
      else
        0
      end

    new_revision = group.revision + 1

    status =
      if Enum.any?(rooms_for(group.id), &(&1.status == "active")), do: "active", else: "cancelled"

    updated_group =
      group
      |> Ecto.Changeset.change(status: status, revision: new_revision)
      |> Repo.update!()

    refreshed_group = refresh_group_totals(updated_group)

    result = %{
      "operation_id" => operation["operation_id"],
      "status" => "applied",
      "group_id" => group.group_id,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "credit_issued_cents" => credit_issued,
      "revision" => new_revision
    }

    if selected? do
      Map.put(result, "cancelled_room_ids", room_ids_in_original_order(group.id, rooms))
    else
      result
    end
    |> Map.put("revision", refreshed_group.revision)
  end

  defp settle_cash_source(nil, group, amount, kind) do
    if amount > 0 do
      Repo.insert!(%LedgerEntry{group_id: group.id, kind: kind, amount_cents: amount})
    end
  end

  defp settle_cash_source(source, _group, amount, kind) do
    if amount > 0 do
      accounting = Repo.get_by!(PaymentAccounting, payment_operation_id: source)

      Repo.update!(
        Ecto.Changeset.change(accounting,
          held_cents: accounting.held_cents - amount,
          refunded_cents: accounting.refunded_cents + if(kind == "refunded", do: amount, else: 0),
          retained_cents: accounting.retained_cents + if(kind == "retained", do: amount, else: 0),
          converted_to_credit_cents:
            accounting.converted_to_credit_cents +
              if(kind == "converted_to_credit", do: amount, else: 0)
        )
      )
    end
  end

  defp apply_payment_operation(operation, type) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id") do
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          rejection(operation, "operation_not_found")

        record ->
          apply_payment_operation_to_record(operation, type, payment_operation_id, record)
      end
    else
      {:error, code} -> rejection(operation, code)
    end
  end

  defp apply_payment_operation_to_record(operation, type, payment_operation_id, record) do
    case result_group_id(record) do
      {:ok, group_id} ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            rejection(operation, target_error(type, record))

          group ->
            case stale_revision(operation, group) do
              {:error, result} ->
                result

              :ok ->
                with :ok <- validate_existing_fields(operation, type),
                     {:ok, _occurred_on} <- parse_date(operation["occurred_on"]) do
                  case prevalidate_payment_target(operation, type, record, group) do
                    :ok ->
                      ensure_group_accounting(group)
                      group = Repo.get!(Group, group.id)

                      with {:ok, accounting} <-
                             payment_for_operation(record, payment_operation_id, type) do
                        case type do
                          "reduce_cash_payment" ->
                            reduce_cash_payment(operation, group, accounting)

                          "charge_back_payment" ->
                            charge_back_payment(operation, group, accounting)
                        end
                      else
                        {:error, code} -> rejection(operation, code, target_group_extra(group))
                      end

                    {:error, code} ->
                      rejection(operation, code, target_group_extra(group))
                  end
                else
                  {:error, code} -> rejection(operation, code, target_group_extra(group))
                end
            end
        end

      {:error, _code} ->
        rejection(operation, target_error(type, record))
    end
  end

  defp result_group_id(%OperationRecord{result: %{"group_id" => group_id}})
       when is_binary(group_id) and byte_size(group_id) > 0,
       do: {:ok, group_id}

  defp result_group_id(_record), do: {:error, "operation_not_found"}

  defp reducible_payment(
         %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"}},
         id
       ) do
    case Repo.get_by(PaymentAccounting, payment_operation_id: id) do
      nil -> {:error, "payment_not_reducible"}
      accounting when accounting.held_cents > 0 -> {:ok, accounting}
      _accounting -> {:error, "payment_not_reducible"}
    end
  end

  defp reducible_payment(_record, _id), do: {:error, "payment_not_reducible"}

  defp payment_for_operation(record, id, "reduce_cash_payment"),
    do: reducible_payment(record, id)

  defp payment_for_operation(record, id, "charge_back_payment") do
    case record do
      %OperationRecord{type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(PaymentAccounting, payment_operation_id: id) do
          nil ->
            {:error, "payment_not_chargeable"}

          accounting ->
            if accounting.charged_back_cents > 0 or
                 accounting.recorded_cents == accounting.reduced_cents do
              {:error, "payment_not_chargeable"}
            else
              {:ok, accounting}
            end
        end

      _ ->
        {:error, "payment_not_chargeable"}
    end
  end

  defp target_error("reduce_cash_payment", _record), do: "payment_not_reducible"
  defp target_error("charge_back_payment", _record), do: "payment_not_chargeable"

  defp prevalidate_payment_target(operation, "reduce_cash_payment", record, group) do
    cond do
      not applied_cash_payment?(record) ->
        {:error, "payment_not_reducible"}

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        {:error, "invalid_amount"}

      group.status != "active" ->
        {:error, "payment_not_reducible"}

      operation["amount_cents"] > (record.result["amount_cents"] || 0) ->
        {:error, "reduction_exceeds_held_cash"}

      true ->
        :ok
    end
  end

  defp prevalidate_payment_target(_operation, "charge_back_payment", record, _group) do
    if applied_cash_payment?(record), do: :ok, else: {:error, "payment_not_chargeable"}
  end

  defp applied_cash_payment?(%OperationRecord{
         type: "record_cash_payment",
         result: %{"status" => "applied"}
       }),
       do: true

  defp applied_cash_payment?(_record), do: false

  defp reduce_cash_payment(operation, group, accounting) do
    amount = operation["amount_cents"]

    cond do
      not (is_integer(amount) and amount > 0) ->
        rejection(operation, "invalid_amount", target_group_extra(group))

      amount > accounting.held_cents ->
        rejection(operation, "reduction_exceeds_held_cash", target_group_extra(group))

      true ->
        remove_cash_for_payment(group, accounting.payment_operation_id, amount)

        Repo.update!(
          Ecto.Changeset.change(accounting,
            held_cents: accounting.held_cents - amount,
            reduced_cents: accounting.reduced_cents + amount
          )
        )

        updated_group = update_group_revision(group, group.revision + 1)

        %{
          "operation_id" => operation["operation_id"],
          "status" => "applied",
          "payment_operation_id" => accounting.payment_operation_id,
          "group_id" => group.group_id,
          "amount_cents" => amount,
          "outstanding_deposit_cents" => outstanding_deposit(updated_group),
          "revision" => updated_group.revision
        }
    end
  end

  defp charge_back_payment(operation, group, accounting) do
    amount =
      accounting.held_cents + accounting.refunded_cents + accounting.retained_cents +
        accounting.converted_to_credit_cents

    if amount <= 0 or accounting.charged_back_cents > 0 or
         accounting.recorded_cents == accounting.reduced_cents do
      rejection(operation, "payment_not_chargeable", target_group_extra(group))
    else
      remove_cash_for_payment(group, accounting.payment_operation_id, accounting.held_cents)
      revoke_credit_entitlement(accounting.payment_operation_id)

      Repo.update!(
        Ecto.Changeset.change(accounting,
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: accounting.charged_back_cents + amount
        )
      )

      updated_group = update_group_revision(group, group.revision + 1)

      %{
        "operation_id" => operation["operation_id"],
        "status" => "applied",
        "payment_operation_id" => accounting.payment_operation_id,
        "group_id" => group.group_id,
        "charged_back_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      }
    end
  end

  defp remove_cash_for_payment(_group, _payment_operation_id, 0), do: :ok

  defp remove_cash_for_payment(group, payment_operation_id, amount) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where:
            allocation.group_id == ^group.id and
              allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: room.position, desc: allocation.id]
      )

    {_remaining, _} =
      Enum.reduce_while(allocations, {amount, :ok}, fn allocation, {remaining, :ok} ->
        removed = min(remaining, allocation.amount_cents)
        room = Repo.get!(Room, allocation.room_id)

        if removed == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update!(
            Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - removed)
          )
        end

        Repo.update!(Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents - removed))

        if removed == remaining do
          {:halt, {0, :ok}}
        else
          {:cont, {remaining - removed, :ok}}
        end
      end)

    :ok
  end

  defp revoke_credit_entitlement(payment_operation_id) do
    Repo.all(
      from contribution in CreditLotContribution,
        where: contribution.payment_operation_id == ^payment_operation_id,
        order_by: [asc: contribution.id]
    )
    |> Enum.each(fn contribution ->
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      available = min(lot.remaining_cents, contribution.entitlement_cents)
      unrecovered = contribution.entitlement_cents - available

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - available,
          unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + unrecovered
        )
      )
    end)
  end

  defp stale_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} when expected_revision == group.revision ->
        :ok

      {:ok, expected_revision} ->
        {:error,
         rejection(operation, "stale_revision", %{
           "group_id" => group.group_id,
           "expected_revision" => expected_revision,
           "actual_revision" => group.revision
         })}
    end
  end

  defp validate_common_fields(operation) do
    if valid_identifier(operation["operation_id"]) and is_binary(operation["occurred_on"]) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_existing_fields(operation, "record_cash_payment") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "amount_cents") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "reschedule_group") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "new_arrival_on") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "apply_hotel_credit") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "amount_cents") do
      :ok
    end
  end

  defp validate_existing_fields(operation, "cancel_group") do
    with :ok <- validate_common_fields(operation),
         :ok <- validate_refund_method(operation) do
      :ok
    end
  end

  defp validate_existing_fields(operation, "cancel_rooms") do
    with :ok <- validate_common_fields(operation),
         :ok <- require_field(operation, "room_ids"),
         :ok <- validate_refund_method(operation) do
      :ok
    end
  end

  defp validate_existing_fields(operation, type)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    with :ok <- validate_common_fields(operation),
         :ok <-
           if(type == "reduce_cash_payment",
             do: require_field(operation, "amount_cents"),
             else: :ok
           ) do
      :ok
    end
  end

  defp require_field(operation, field) do
    if Map.has_key?(operation, field), do: :ok, else: {:error, "invalid_operation"}
  end

  defp validate_refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> :ok
      {:ok, method} when method in ["cash", "hotel_credit"] -> :ok
      _ -> {:error, "invalid_operation"}
    end
  end

  defp cancellation_refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, field) do
    if valid_identifier(operation[field]) do
      {:ok, operation[field]}
    else
      {:error, "invalid_operation"}
    end
  end

  defp valid_identifier(value), do: is_binary(value) and byte_size(value) > 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_reschedule_date(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"],
    do: {:ok, rate_plan}

  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms, arrival_on, departure_on, rate_plan) when is_list(rooms) do
    if rooms == [] do
      {:error, "invalid_rooms"}
    else
      nights = Date.diff(departure_on, arrival_on)

      rooms
      |> Enum.with_index()
      |> Enum.reduce_while({[], 0, MapSet.new()}, fn {room, position},
                                                     {valid_rooms, lodging_total, room_ids} ->
        with {:ok, room_id} <- room_identifier(room),
             false <- MapSet.member?(room_ids, room_id),
             {:ok, nightly_rate_cents} <- nightly_rate(room) do
          lodging = nights * nightly_rate_cents
          deposit = deposit_for(lodging, rate_plan)

          {:cont,
           {[{room_id, nightly_rate_cents, position, deposit} | valid_rooms],
            lodging_total + lodging, MapSet.put(room_ids, room_id)}}
        else
          true -> {:halt, {:error, "invalid_rooms"}}
          {:error, _reason} -> {:halt, {:error, "invalid_rooms"}}
        end
      end)
      |> case do
        {valid_rooms, lodging_total, _room_ids} ->
          rooms =
            valid_rooms
            |> Enum.reverse()
            |> Enum.map(fn {room_id, nightly_rate_cents, position, deposit_due_cents} ->
              %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                deposit_due_cents: deposit_due_cents
              }
            end)

          deposit_due =
            Enum.sum(Enum.map(valid_rooms, fn {_id, _rate, _position, deposit} -> deposit end))

          {:ok, rooms, lodging_total, deposit_due}

        {:error, code} ->
          {:error, code}
      end
    end
  end

  defp validate_rooms(_rooms, _arrival_on, _departure_on, _rate_plan),
    do: {:error, "invalid_rooms"}

  defp room_identifier(room) when is_map(room), do: required_identifier(room, "room_id")
  defp room_identifier(_room), do: {:error, "invalid_rooms"}

  defp nightly_rate(room) when is_map(room) do
    case room["nightly_rate_cents"] do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp deposit_for(lodging, "advance_purchase"), do: lodging
  defp deposit_for(lodging, "flexible"), do: div(lodging * 20 + 50, 100)

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(_group), do: {:error, "group_not_active"}

  defp usable_payment_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp usable_payment_amount(_amount), do: {:error, "invalid_amount"}

  defp available_credit_lots(guest_id, occurred_on) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on > ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp allocate_credit(lots, amount) do
    {remaining, allocations} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {remaining, allocations} ->
        allocated = min(remaining, lot.remaining_cents)

        if allocated == remaining do
          {:halt, {0, [{lot, allocated} | allocations]}}
        else
          {:cont, {remaining - allocated, [{lot, allocated} | allocations]}}
        end
      end)

    if remaining == 0 do
      {:ok, Enum.reverse(allocations)}
    else
      {:error, "insufficient_credit"}
    end
  end

  defp allocate_cash_to_rooms(group, amount, payment_operation_id) do
    {remaining, _rooms} =
      Enum.reduce_while(active_rooms_for(group.id), {amount, :ok}, fn room, {remaining, :ok} ->
        capacity = room_capacity(room)
        allocated = min(remaining, capacity)

        if allocated > 0 do
          Repo.update!(
            Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents + allocated)
          )

          Repo.insert!(%CashAllocation{
            group_id: group.id,
            room_id: room.id,
            payment_operation_id: payment_operation_id,
            amount_cents: allocated
          })
        end

        if allocated == remaining do
          {:halt, {0, :ok}}
        else
          {:cont, {remaining - allocated, :ok}}
        end
      end)

    if remaining != 0, do: raise(ArgumentError, "funding exceeds room capacity")
    :ok
  end

  defp allocate_credit_to_rooms(group, allocations, funding_operation_id) do
    Enum.reduce(allocations, :ok, fn {lot, amount}, :ok ->
      {remaining, _} =
        Enum.reduce_while(active_rooms_for(group.id), {amount, :ok}, fn room, {remaining, :ok} ->
          capacity = room_capacity(room)
          allocated = min(remaining, capacity)

          if allocated > 0 do
            Repo.update!(
              Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + allocated)
            )

            Repo.insert!(%CreditAllocation{
              group_id: group.id,
              room_id: room.id,
              credit_lot_id: lot.id,
              funding_operation_id: funding_operation_id,
              amount_cents: allocated
            })
          end

          if allocated == remaining do
            {:halt, {0, :ok}}
          else
            {:cont, {remaining - allocated, :ok}}
          end
        end)

      if remaining != 0, do: raise(ArgumentError, "credit exceeds room capacity")
      :ok
    end)
  end

  defp selected_rooms(group, room_ids) when is_list(room_ids) do
    if room_ids == [] or Enum.any?(room_ids, &(not valid_identifier(&1))) or
         MapSet.size(MapSet.new(room_ids)) != length(room_ids) do
      {:error, "invalid_rooms"}
    else
      rooms = rooms_for(group.id)

      selected =
        Enum.filter(rooms, fn room -> room.room_id in room_ids and room.status == "active" end)

      if length(selected) == length(room_ids) do
        {:ok, selected}
      else
        {:error, "invalid_rooms"}
      end
    end
  end

  defp selected_rooms(_group, _room_ids), do: {:error, "invalid_rooms"}

  defp room_ids_in_original_order(_group_id, rooms), do: Enum.map(rooms, & &1.room_id)

  defp restore_credit_amount(lot, amount, occurred_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents || 0)
    excess = amount - absorbed

    remaining =
      if excess > 0 and Date.compare(lot.expires_on, occurred_on) == :gt do
        lot.remaining_cents + excess
      else
        lot.remaining_cents
      end

    Repo.update!(
      Ecto.Changeset.change(lot,
        remaining_cents: remaining,
        unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed
      )
    )
  end

  defp issue_credit_lot(_group, _source_operation_id, _occurred_on, 0, _sources), do: 0

  defp issue_credit_lot(group, source_operation_id, occurred_on, cash_paid, sources) do
    credit_issued = credit_value(cash_paid)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 366),
        unrecovered_clawback_cents: 0
      })

    sources
    |> sort_funding_sources()
    |> Enum.reduce({0, 0}, fn {payment_operation_id, principal}, {prior_cash, prior_value} ->
      current_cash = prior_cash + principal
      current_value = credit_value(current_cash)
      entitlement = current_value - prior_value

      if principal > 0 do
        Repo.insert!(%CreditLotContribution{
          credit_lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          principal_cents: principal,
          entitlement_cents: entitlement
        })
      end

      {current_cash, current_value}
    end)

    credit_issued
  end

  defp credit_value(cash), do: cash + div(cash * 10 + 50, 100)

  defp sort_funding_sources(sources) do
    records =
      Repo.all(from record in OperationRecord, select: {record.operation_id, record.id})
      |> Map.new()

    Enum.sort_by(sources, fn {source, _amount} ->
      case source do
        nil -> {0, 0, ""}
        _ -> {1, Map.get(records, source, 1_000_000_000), source}
      end
    end)
  end

  defp rooms_for(group_id) do
    Repo.all(from room in Room, where: room.group_id == ^group_id, order_by: [asc: room.position])
  end

  defp active_rooms_for(group_id), do: Enum.filter(rooms_for(group_id), &(&1.status == "active"))

  defp room_capacity(%Room{status: "active"} = room),
    do: max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

  defp room_capacity(_room), do: 0

  defp refresh_group_totals(group) do
    rooms = Enum.filter(rooms_for(group.id), &(&1.status == "active"))
    lodging_total = Enum.sum(Enum.map(rooms, &room_lodging(&1, group)))
    deposit_due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))
    cash_paid = Enum.sum(Enum.map(rooms, & &1.cash_paid_cents))
    credit_paid = Enum.sum(Enum.map(rooms, & &1.credit_paid_cents))

    attrs = [
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: cash_paid + credit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid
    ]

    Repo.update!(Ecto.Changeset.change(group, attrs))
  end

  defp room_lodging(room, group),
    do: Date.diff(group.departure_on, group.arrival_on) * room.nightly_rate_cents

  defp outstanding_deposit(group) do
    rooms = Enum.filter(rooms_for(group.id), &(&1.status == "active"))
    Enum.sum(Enum.map(rooms, &room_capacity/1))
  end

  defp update_group_revision(group, revision) do
    group = refresh_group_totals(group)
    Repo.update!(Ecto.Changeset.change(group, revision: revision))
  end

  defp target_group_extra(group), do: %{"group_id" => group.group_id}

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
          select: sum(lot.remaining_cents)
      ) || 0

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          where: group.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    available + applied
  end

  defp credit_shortfall do
    Repo.all(
      from lot in CreditLot,
        join: allocation in CreditAllocation,
        on: allocation.credit_lot_id == lot.id,
        join: group in Group,
        on: group.id == allocation.group_id,
        where: group.status == "active",
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select: {lot.unrecovered_clawback_cents, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {unrecovered, applied} -> min(unrecovered || 0, applied || 0) end)
    |> Enum.sum()
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_details(group) do
    case group.policy_version do
      "flex-14" ->
        {"flex-14", 14}

      "flex-30" ->
        {"flex-30", 30}

      "advance-nonrefundable" ->
        {"advance-nonrefundable", nil}

      _ ->
        case policy_version(group.rate_plan, group.booked_on) do
          "advance-nonrefundable" -> {"advance-nonrefundable", nil}
          version -> {version, if(version == "flex-14", do: 14, else: 30)}
        end
    end
  end

  defp policy_fields(group) do
    {version, window} = policy_details(group)

    %{
      "policy_version" => version,
      "refundable_until" =>
        if(window, do: Date.to_iso8601(Date.add(group.arrival_on, -window)), else: nil)
    }
  end

  defp refundable?(group, occurred_on) do
    {_version, window} = policy_details(group)
    is_integer(window) and Date.diff(group.arrival_on, occurred_on) >= window
  end

  defp render_group(group, rooms) do
    active_rooms = Enum.filter(rooms, &(&1.status == "active"))

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "revision" => group.revision,
      "rooms" =>
        Enum.map(rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents,
            "lodging_total_cents" => room_lodging(room, group),
            "status" => room.status,
            "deposit_due_cents" => room.deposit_due_cents,
            "cash_paid_cents" => if(room.status == "active", do: room.cash_paid_cents, else: 0),
            "credit_paid_cents" =>
              if(room.status == "active", do: room.credit_paid_cents, else: 0)
          }
        end),
      "lodging_total_cents" => Enum.sum(Enum.map(active_rooms, &room_lodging(&1, group))),
      "deposit_due_cents" => Enum.sum(Enum.map(active_rooms, & &1.deposit_due_cents)),
      "deposit_paid_cents" =>
        Enum.sum(Enum.map(active_rooms, &(&1.cash_paid_cents + &1.credit_paid_cents))),
      "cash_paid_cents" => Enum.sum(Enum.map(active_rooms, & &1.cash_paid_cents)),
      "credit_paid_cents" => Enum.sum(Enum.map(active_rooms, & &1.credit_paid_cents)),
      "outstanding_deposit_cents" => Enum.sum(Enum.map(active_rooms, &room_capacity/1))
    }
    |> Map.merge(policy_fields(group))
  end

  defp ensure_group_accounting(group) do
    records = durable_funding_records(group.group_id)
    durable_cash = Enum.filter(records, &(&1.type == "record_cash_payment"))
    backfilled_dispositions = backfilled_dispositions(group, durable_cash)

    Enum.each(records, fn record ->
      if record.type == "record_cash_payment" do
        amount = record.result["amount_cents"] || 0

        unless Repo.get_by(PaymentAccounting, payment_operation_id: record.operation_id) do
          disposition = Map.get(backfilled_dispositions, record.operation_id, %{})

          Repo.insert!(%PaymentAccounting{
            payment_operation_id: record.operation_id,
            group_id: group.id,
            backfilled: true,
            recorded_cents: amount,
            held_cents:
              Map.get(disposition, :held, if(group.status == "active", do: amount, else: 0)),
            refunded_cents: Map.get(disposition, :refunded, 0),
            retained_cents: Map.get(disposition, :retained, 0),
            converted_to_credit_cents: Map.get(disposition, :converted_to_credit, 0),
            backfilled_refunded_cents: Map.get(disposition, :refunded, 0),
            backfilled_retained_cents: Map.get(disposition, :retained, 0),
            backfilled_converted_to_credit_cents: Map.get(disposition, :converted_to_credit, 0),
            reduced_cents: 0,
            charged_back_cents: 0
          })
        end
      end
    end)

    durable_credit = Enum.filter(records, &(&1.type == "apply_hotel_credit"))
    group_cash = group.cash_paid_cents || group.deposit_paid_cents || 0
    group_credit = group.credit_paid_cents || 0
    durable_cash_total = Enum.sum(Enum.map(durable_cash, &(&1.result["amount_cents"] || 0)))
    durable_credit_total = Enum.sum(Enum.map(durable_credit, &(&1.result["amount_cents"] || 0)))
    legacy_cash = max(group_cash - durable_cash_total, 0)
    legacy_credit = max(group_credit - durable_credit_total, 0)

    existing_credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.id and is_nil(allocation.room_id),
          order_by: [asc: allocation.id]
      )

    credit_fragments =
      if group.status != "active" or existing_credit_allocations == [] do
        []
      else
        categories =
          ([{nil, legacy_credit}] ++
             Enum.map(durable_credit, fn record ->
               {record.operation_id, record.result["amount_cents"] || 0}
             end))
          |> Enum.filter(fn {_source, amount} -> amount > 0 end)

        prepare_existing_credit_fragments(existing_credit_allocations, categories)
      end

    if group.status == "active" and legacy_cash > 0 and not legacy_cash_allocated?(group.id) do
      allocate_cash_to_rooms(group, legacy_cash, nil)
    end

    {legacy_fragments, durable_fragments} = Enum.split_while(credit_fragments, &is_nil(&1.source))
    allocate_credit_fragments(group, legacy_fragments)

    Enum.reduce(records, durable_fragments, fn record, remaining_fragments ->
      case record.type do
        "record_cash_payment" ->
          accounting = Repo.get_by!(PaymentAccounting, payment_operation_id: record.operation_id)

          if accounting.held_cents > 0 and not payment_allocated?(group.id, record.operation_id) do
            allocate_cash_to_rooms(group, accounting.held_cents, record.operation_id)
          end

          remaining_fragments

        "apply_hotel_credit" ->
          {fragments, rest} =
            Enum.split_while(remaining_fragments, &(&1.source == record.operation_id))

          allocate_credit_fragments(group, fragments)
          rest
      end
    end)

    backfill_credit_contributions(group, durable_cash)

    :ok
  end

  defp durable_funding_records(group_id) do
    Repo.all(from record in OperationRecord, order_by: [asc: record.id])
    |> Enum.filter(fn record ->
      record.result["group_id"] == group_id and
        record.result["status"] == "applied" and
        record.type in ["record_cash_payment", "apply_hotel_credit"]
    end)
  end

  defp backfilled_dispositions(%Group{status: "active"}, durable_cash) do
    Map.new(durable_cash, fn record ->
      {record.operation_id, %{held: record.result["amount_cents"] || 0}}
    end)
  end

  defp backfilled_dispositions(group, durable_cash) do
    totals =
      Repo.all(
        from entry in LedgerEntry,
          where: entry.group_id == ^group.id,
          group_by: entry.kind,
          select: {entry.kind, sum(entry.amount_cents)}
      )
      |> Map.new(fn {kind, amount} -> {kind, amount || 0} end)

    durable_total = Enum.sum(Enum.map(durable_cash, &(&1.result["amount_cents"] || 0)))
    legacy_cash = max(Map.get(totals, "held", 0) - durable_total, 0)
    {_legacy_assignment, remaining} = consume_dispositions(totals, legacy_cash)

    {assignments, _remaining} =
      Enum.reduce(durable_cash, {%{}, remaining}, fn record, {assignments, remaining} ->
        amount = record.result["amount_cents"] || 0
        {assignment, next_remaining} = consume_dispositions(remaining, amount)
        {Map.put(assignments, record.operation_id, assignment), next_remaining}
      end)

    assignments
  end

  defp consume_dispositions(totals, amount) do
    Enum.reduce(@disposition_kinds, {%{}, totals, amount}, fn kind,
                                                              {assignment, totals, remaining} ->
      taken = min(remaining, Map.get(totals, kind, 0))

      {
        Map.put(assignment, disposition_field(kind), taken),
        Map.put(totals, kind, Map.get(totals, kind, 0) - taken),
        remaining - taken
      }
    end)
    |> then(fn {assignment, totals, _remaining} -> {assignment, totals} end)
  end

  defp disposition_field("converted_to_credit"), do: :converted_to_credit
  defp disposition_field(kind), do: String.to_atom(kind)

  defp backfill_credit_contributions(%Group{status: "active"}, _durable_cash), do: :ok

  defp backfill_credit_contributions(group, durable_cash) do
    cancellation_ids =
      Repo.all(from record in OperationRecord, order_by: [asc: record.id])
      |> Enum.filter(fn record ->
        record.type in ["cancel_group", "cancel_rooms"] and
          record.result["group_id"] == group.group_id and
          record.result["status"] == "applied" and
          (record.result["credit_issued_cents"] || 0) > 0
      end)
      |> Enum.map(& &1.operation_id)

    case Repo.all(
           from lot in CreditLot,
             where: lot.source_operation_id in ^cancellation_ids,
             order_by: [asc: lot.id]
         ) do
      [] ->
        :ok

      [lot | _] ->
        unless Repo.exists?(
                 from contribution in CreditLotContribution,
                   where: contribution.credit_lot_id == ^lot.id
               ) do
          dispositions = backfilled_dispositions(group, durable_cash)

          ledger_converted =
            Repo.one(
              from entry in LedgerEntry,
                where: entry.group_id == ^group.id and entry.kind == "converted_to_credit",
                select: sum(entry.amount_cents)
            ) || 0

          durable_converted =
            Enum.sum(
              Enum.map(durable_cash, fn record ->
                Map.get(Map.get(dispositions, record.operation_id, %{}), :converted_to_credit, 0)
              end)
            )

          sources =
            [
              {nil, max(ledger_converted - durable_converted, 0)}
              | Enum.map(durable_cash, fn record ->
                  {record.operation_id,
                   Map.get(
                     Map.get(dispositions, record.operation_id, %{}),
                     :converted_to_credit,
                     0
                   )}
                end)
            ]
            |> Enum.filter(fn {_source, amount} -> amount > 0 end)

          add_credit_lot_contributions(lot, sources)
        end
    end
  end

  defp add_credit_lot_contributions(_lot, []), do: :ok

  defp add_credit_lot_contributions(lot, sources) do
    sources
    |> sort_funding_sources()
    |> Enum.reduce({0, 0}, fn {payment_operation_id, principal}, {prior_cash, prior_value} ->
      current_cash = prior_cash + principal
      current_value = credit_value(current_cash)

      Repo.insert!(%CreditLotContribution{
        credit_lot_id: lot.id,
        payment_operation_id: payment_operation_id,
        principal_cents: principal,
        entitlement_cents: current_value - prior_value
      })

      {current_cash, current_value}
    end)

    :ok
  end

  defp legacy_cash_allocated?(group_id) do
    Repo.exists?(
      from allocation in CashAllocation,
        where: allocation.group_id == ^group_id and is_nil(allocation.payment_operation_id)
    )
  end

  defp payment_allocated?(group_id, payment_operation_id) do
    Repo.exists?(
      from allocation in CashAllocation,
        where:
          allocation.group_id == ^group_id and
            allocation.payment_operation_id == ^payment_operation_id
    )
  end

  defp prepare_existing_credit_fragments(allocations, categories) do
    fragments = build_credit_fragments(allocations, categories)
    Enum.each(allocations, &Repo.delete!/1)
    fragments
  end

  defp build_credit_fragments(allocations, categories) do
    {fragments, _remaining} =
      Enum.reduce(categories, {[], allocations}, fn {source, amount}, {fragments, remaining} ->
        {taken, next_remaining} = take_credit_fragments(remaining, source, amount, [])
        {fragments ++ taken, next_remaining}
      end)

    fragments
  end

  defp take_credit_fragments(allocations, _source, 0, fragments),
    do: {Enum.reverse(fragments), allocations}

  defp take_credit_fragments([], _source, _amount, fragments),
    do: {Enum.reverse(fragments), []}

  defp take_credit_fragments([allocation | allocations], source, amount, fragments) do
    taken = min(amount, allocation.amount_cents)

    fragment = %{
      source: source,
      credit_lot_id: allocation.credit_lot_id,
      amount: taken
    }

    remaining_allocation = allocation.amount_cents - taken

    next_allocations =
      if remaining_allocation > 0 do
        [%{allocation | amount_cents: remaining_allocation} | allocations]
      else
        allocations
      end

    take_credit_fragments(next_allocations, source, amount - taken, [fragment | fragments])
  end

  defp allocate_credit_fragments(group, fragments) do
    Enum.each(fragments, fn %{source: source, credit_lot_id: lot_id, amount: amount} ->
      {remaining, _} =
        Enum.reduce_while(active_rooms_for(group.id), {amount, :ok}, fn room, {remaining, :ok} ->
          allocated = min(remaining, room_capacity(room))

          if allocated > 0 do
            Repo.update!(
              Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + allocated)
            )

            Repo.insert!(%CreditAllocation{
              group_id: group.id,
              room_id: room.id,
              credit_lot_id: lot_id,
              funding_operation_id: source,
              amount_cents: allocated
            })
          end

          if allocated == remaining do
            {:halt, {0, :ok}}
          else
            {:cont, {remaining - allocated, :ok}}
          end
        end)

      if remaining != 0, do: raise(ArgumentError, "legacy credit exceeds room capacity")
    end)
  end

  defp rejection(operation, code, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id(operation),
        "status" => "rejected",
        "code" => code
      },
      extra
    )
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil

  defp operation_type(type) when is_binary(type), do: type
  defp operation_type(_type), do: nil
end
