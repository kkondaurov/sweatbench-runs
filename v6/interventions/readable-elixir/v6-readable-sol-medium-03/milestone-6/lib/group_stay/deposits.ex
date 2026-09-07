defmodule GroupStay.Deposits do
  @moduledoc """
  Owns group reservations and their room-level deposit accounting.

  Partner operations run in separate transactions through `OperationJournal`, preserving ordered
  batch visibility while coupling every domain change to its durable receipt. Funding is kept as
  ordered room allocations: cash retains its payment identity and hotel credit retains its source
  lot. Those links are the basis for selected-room settlement and later provider corrections.
  """

  import Ecto.Query
  alias Ecto.Changeset

  alias GroupStay.Deposits.{
    AllocationOrder,
    CashAllocation,
    CashSettlement,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    FundingTransfer,
    LedgerEntry,
    OperationJournal,
    OperationRecord,
    PaymentDisposition,
    Policy,
    Room
  }

  alias GroupStay.Repo
  alias GroupStay.Finance

  @rate_plans ~w(flexible advance_purchase)

  @doc "Processes partner operations in order, committing each handled operation separately."
  def process_operations(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

  @doc "Returns the exact result durably recorded for an operation."
  def get_operation_result(operation_id), do: OperationJournal.get_result(operation_id)

  @doc "Returns a group with rooms and their funding allocations in original room order."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, rooms: [:cash_allocations, :credit_allocations])}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  @doc "Returns the current exhaustive cash dispositions for an applied durable payment."
  def get_payment(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      _ -> payment_statement(operation_id)
    end
  end

  def get_payment(_), do: {:error, :operation_not_found}

  @doc "Returns an open daily finance report at or after the reporting inception date."
  def daily_finance_report(date), do: Finance.daily_report(date)

  defp payment_statement(operation_id) do
    case Repo.get_by(PaymentDisposition, payment_operation_id: operation_id) do
      nil ->
        {:error, :payment_not_reconcilable}

      payment ->
        group = Repo.get!(Group, payment.group_id)

        statement = %{
          payment_operation_id: payment.payment_operation_id,
          original_group_id: group.group_id,
          recorded_cents: payment.recorded_cents,
          held_cents: payment.held_cents,
          refunded_cents: payment.refunded_cents,
          retained_cents: payment.retained_cents,
          converted_to_credit_cents: payment.converted_to_credit_cents,
          reduced_cents: payment.reduced_cents,
          charged_back_cents: payment.charged_back_cents
        }

        {:ok,
         if(payment.participated_in_transfer,
           do: Map.put(statement, :held_by_group, held_cash_by_group(operation_id)),
           else: statement
         )}
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from a in CashAllocation,
        join: g in assoc(a, :group),
        where: a.payment_operation_id == ^payment_operation_id,
        group_by: g.group_id,
        order_by: g.group_id,
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  @doc "Returns cash classifications and credit liability as of a reporting date."
  def ledger(on \\ Date.utc_today()) do
    entries = Repo.all(from e in LedgerEntry, select: {e.kind, e.amount_cents})

    total = fn kinds ->
      entries |> Enum.filter(&(elem(&1, 0) in kinds)) |> Enum.sum_by(&elem(&1, 1))
    end

    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      ) || 0

    allocated =
      Repo.one(
        from a in CreditAllocation,
          join: r in assoc(a, :room),
          where: r.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      ) || 0

    %{
      cash_held_cents:
        total.(["cash_payment"]) -
          total.([
            "refund",
            "retention",
            "credit_conversion",
            "cash_reduction",
            "chargeback_held"
          ]),
      cash_refunded_cents: total.(["refund"]) - total.(["chargeback_refund"]),
      cash_retained_cents: total.(["retention"]) - total.(["chargeback_retention"]),
      cash_converted_to_credit_cents:
        total.(["credit_conversion"]) - total.(["chargeback_conversion"]),
      cash_reduced_cents: total.(["cash_reduction"]),
      cash_charged_back_cents:
        total.([
          "chargeback_held",
          "chargeback_refund",
          "chargeback_retention",
          "chargeback_conversion"
        ]),
      credit_liability_cents: available + allocated,
      credit_shortfall_cents: credit_shortfall()
    }
  end

  defp credit_shortfall do
    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.sum_by(fn lot ->
      min(
        lot.unrecovered_clawback_cents,
        Repo.one(
          from a in CreditAllocation,
            join: r in assoc(a, :room),
            where: a.credit_lot_id == ^lot.id and r.status == "active",
            select: coalesce(sum(a.amount_cents), 0)
        ) || 0
      )
    end)
  end

  @doc "Returns a guest's unexpired available credit lots in consumption order."
  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    %{guest_id: guest_id, available_cents: Enum.sum_by(lots, & &1.remaining_cents), lots: lots}
  end

  @doc "Calculates the still-unfunded requirement of an active group."
  def outstanding_deposit(%Group{status: "active"} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  def outstanding_deposit(%Group{}), do: 0

  @doc "Sums the cash and credit allocations currently attached to a room."
  def room_amounts(room),
    do: %{
      cash_paid_cents: Enum.sum_by(room.cash_allocations, & &1.amount_cents),
      credit_paid_cents: Enum.sum_by(room.credit_allocations, & &1.amount_cents)
    }

  defp process_operation(operation) when is_map(operation) do
    id = operation["operation_id"]

    if valid_identifier?(id),
      do:
        OperationJournal.process(
          operation,
          fn -> apply_operation(operation) end,
          &format_result(id, &1)
        ),
      else: format_result(id, {:error, :invalid_operation})
  end

  defp process_operation(_), do: format_result(nil, {:error, :invalid_operation})

  defp apply_operation(%{"type" => "open_group"} = op), do: open_group(op)

  defp apply_operation(%{"type" => "record_cash_payment"} = op),
    do: update_existing(op, &record_cash_payment/2)

  defp apply_operation(%{"type" => "reschedule_group"} = op),
    do: update_existing(op, &reschedule_group/2)

  defp apply_operation(%{"type" => "cancel_group"} = op), do: update_existing(op, &cancel_group/2)
  defp apply_operation(%{"type" => "cancel_rooms"} = op), do: update_existing(op, &cancel_rooms/2)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = op),
    do: update_existing(op, &apply_hotel_credit/2)

  defp apply_operation(%{"type" => "reduce_cash_payment"} = op),
    do: update_payment(op, :reduction)

  defp apply_operation(%{"type" => "charge_back_payment"} = op),
    do: update_payment(op, :chargeback)

  defp apply_operation(%{"type" => "transfer_deposit"} = op), do: transfer_deposit(op)

  defp apply_operation(%{"type" => "start_finance_reporting"} = op),
    do: start_finance_reporting(op)

  defp apply_operation(_), do: {:error, :invalid_operation}

  defp start_finance_reporting(op) do
    with {:ok, starts_on} <- parse_date(op["starts_on"], :invalid_reporting_date),
         {:ok, _start} <- Finance.start(starts_on),
         do: {:ok, %{starts_on: starts_on}}
  end

  defp open_group(op) do
    with {:ok, attrs} <- open_attributes(op),
         false <- Repo.exists?(from g in Group, where: g.group_id == ^attrs.group_id),
         {:ok, group} <- insert_group(attrs) do
      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    else
      true -> {:error, :group_already_exists}
      {:error, %Changeset{}} -> {:error, :group_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_attributes(op) do
    cond do
      not Enum.all?(~w(group_id guest_id property_id), &valid_identifier?(op[&1])) ->
        {:error, :invalid_operation}

      not Enum.all?(
        ~w(occurred_on arrival_on departure_on rooms rate_plan),
        &Map.has_key?(op, &1)
      ) ->
        {:error, :invalid_operation}

      true ->
        build_open_attributes(op)
    end
  end

  defp build_open_attributes(op) do
    with {:ok, booked} <- parse_date(op["occurred_on"], :invalid_stay),
         {:ok, arrival} <- parse_date(op["arrival_on"], :invalid_stay),
         {:ok, departure} <- parse_date(op["departure_on"], :invalid_stay),
         :ok <- validate_stay(arrival, departure),
         :ok <- validate_rate_plan(op["rate_plan"]),
         {:ok, input_rooms} <- validate_rooms(op["rooms"]) do
      rooms =
        Enum.map(input_rooms, fn room ->
          lodging = room.nightly_rate_cents * Date.diff(departure, arrival)

          Map.merge(room, %{
            status: "active",
            lodging_total_cents: lodging,
            deposit_due_cents:
              if(op["rate_plan"] == "flexible",
                do: rounded_percentage(lodging, 20),
                else: lodging
              )
          })
        end)

      {:ok,
       %{
         group_id: op["group_id"],
         guest_id: op["guest_id"],
         property_id: op["property_id"],
         booked_on: booked,
         arrival_on: arrival,
         departure_on: departure,
         rate_plan: op["rate_plan"],
         policy_version: Policy.version(op["rate_plan"], booked),
         rooms: rooms,
         lodging_total_cents: Enum.sum_by(rooms, & &1.lodging_total_cents),
         deposit_due_cents: Enum.sum_by(rooms, & &1.deposit_due_cents)
       }}
    end
  end

  defp insert_group(attrs) do
    rooms = Enum.with_index(attrs.rooms, &Map.put(&1, :position, &2))

    %Group{}
    |> Changeset.cast(attrs |> Map.delete(:rooms) |> Map.put(:rooms, rooms), [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> Changeset.put_change(:status, "active")
    |> Changeset.put_change(:revision, 1)
    |> Changeset.cast_assoc(:rooms,
      with: fn room, params ->
        Changeset.cast(room, params, [
          :room_id,
          :nightly_rate_cents,
          :position,
          :status,
          :lodging_total_cents,
          :deposit_due_cents
        ])
      end
    )
    |> Changeset.unique_constraint(:group_id)
    |> Repo.insert()
  end

  defp update_existing(op, fun) do
    if valid_identifier?(op["group_id"]) do
      case Repo.get_by(Group, group_id: op["group_id"]) do
        nil -> {:error, :group_not_found}
        group -> check_revision_then_update(group, op, fun)
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp update_payment(op, kind) do
    id = op["payment_operation_id"]

    if valid_identifier?(id) do
      case Repo.get_by(OperationRecord, operation_id: id) do
        nil ->
          {:error, :operation_not_found}

        _ ->
          case Repo.get_by(PaymentDisposition, payment_operation_id: id) do
            nil ->
              {:error,
               if(kind == :reduction, do: :payment_not_reducible, else: :payment_not_chargeable)}

            payment ->
              check_revision_then_update(Repo.get!(Group, payment.group_id), op, fn group,
                                                                                    operation ->
                apply_payment_update(kind, payment, group, operation)
              end)
          end
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp check_revision_then_update(group, op, fun) do
    case Map.fetch(op, "expected_revision") do
      {:ok, expected} when is_integer(expected) and expected !== group.revision ->
        {:error, {:stale_revision, group.group_id, expected, group.revision}}

      {:ok, expected} when is_integer(expected) ->
        apply_complete_operation(op, group, fun)

      :error ->
        apply_complete_operation(op, group, fun)

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp apply_complete_operation(op, group, fun),
    do: if(structurally_complete?(op), do: fun.(group, op), else: {:error, :invalid_operation})

  defp structurally_complete?(%{"type" => type} = op)
       when type in ~w(record_cash_payment apply_hotel_credit reduce_cash_payment),
       do: Map.has_key?(op, "occurred_on") and Map.has_key?(op, "amount_cents")

  defp structurally_complete?(%{"type" => "reschedule_group"} = op),
    do: Map.has_key?(op, "occurred_on") and Map.has_key?(op, "new_arrival_on")

  defp structurally_complete?(%{"type" => "cancel_rooms"} = op),
    do: Map.has_key?(op, "occurred_on") and Map.has_key?(op, "room_ids")

  defp structurally_complete?(%{"type" => type} = op)
       when type in ~w(cancel_group charge_back_payment), do: Map.has_key?(op, "occurred_on")

  defp structurally_complete?(%{"type" => "transfer_deposit"} = op),
    do:
      Map.has_key?(op, "occurred_on") and Map.has_key?(op, "source_group_id") and
        Map.has_key?(op, "destination_group_id") and Map.has_key?(op, "amount_cents")

  defp structurally_complete?(_), do: false

  defp record_cash_payment(group, op) do
    with {:ok, date} <- parse_date(op["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, amount} <- payment_amount(op),
         true <- amount <= outstanding_deposit(group),
         :ok <- insert_fact(group, op, date, "cash_payment", amount),
         :ok <- allocate_cash(group, op["operation_id"], amount),
         {:ok, _} <- insert_payment(group, op["operation_id"], amount),
         :ok <- Finance.record_cash(op, group.property_id, "received", amount),
         {:ok, updated} <- update_group_totals(group) do
      {:ok,
       %{
         group_id: updated.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: outstanding_deposit(updated),
         revision: updated.revision
       }}
    else
      false -> {:error, :payment_exceeds_outstanding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_payment(group, id, amount),
    do:
      %PaymentDisposition{}
      |> Changeset.cast(
        %{
          group_id: group.id,
          payment_operation_id: id,
          recorded_cents: amount,
          held_cents: amount
        },
        [:group_id, :payment_operation_id, :recorded_cents, :held_cents]
      )
      |> Repo.insert()

  defp allocate_cash(group, payment_id, amount),
    do:
      allocate_to_rooms(group, amount, fn room, used ->
        %CashAllocation{}
        |> Changeset.cast(
          %{
            group_id: group.id,
            room_id: room.id,
            payment_operation_id: payment_id,
            amount_cents: used,
            allocation_order: AllocationOrder.next()
          },
          [:group_id, :room_id, :payment_operation_id, :amount_cents, :allocation_order]
        )
        |> Repo.insert()
      end)

  defp reschedule_group(group, op) do
    with {:ok, date} <- parse_date(op["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, arrival} <- parse_date(op["new_arrival_on"], :invalid_stay),
         true <- Date.after?(arrival, date),
         {:ok, updated} <-
           group
           |> Changeset.change(
             arrival_on: arrival,
             departure_on: Date.add(group.departure_on, Date.diff(arrival, group.arrival_on)),
             revision: group.revision + 1
           )
           |> Repo.update() do
      {:ok,
       %{
         group_id: updated.group_id,
         new_arrival_on: updated.arrival_on,
         new_departure_on: updated.departure_on,
         policy_version: updated.policy_version,
         refundable_until: Policy.refundable_until(updated),
         revision: updated.revision
       }}
    else
      false -> {:error, :invalid_stay}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_hotel_credit(group, op) do
    with {:ok, date} <- parse_date(op["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, amount} <- payment_amount(op),
         true <- amount <= outstanding_deposit(group),
         {:ok, lots} <- sufficient_credit(group.guest_id, date, amount),
         :ok <- allocate_credit(group, lots, op, amount),
         {:ok, updated} <- update_group_totals(group) do
      {:ok,
       %{
         group_id: updated.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: outstanding_deposit(updated),
         revision: updated.revision
       }}
    else
      false -> {:error, :payment_exceeds_outstanding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allocate_credit(group, lots, operation, amount) do
    with {:ok, lot_uses} <- consume_lots(lots, amount) do
      intersect_uses(room_uses(group, amount), lot_uses)
      |> Enum.reduce_while(:ok, fn {room, lot, used}, :ok ->
        case %CreditAllocation{}
             |> Changeset.cast(
               %{
                 group_id: group.id,
                 room_id: room.id,
                 credit_lot_id: lot.id,
                 operation_id: operation["operation_id"],
                 amount_cents: used,
                 allocation_order: AllocationOrder.next()
               },
               [
                 :group_id,
                 :room_id,
                 :credit_lot_id,
                 :operation_id,
                 :amount_cents,
                 :allocation_order
               ]
             )
             |> Repo.insert() do
          {:ok, _} -> {:cont, :ok}
          {:error, e} -> {:halt, {:error, e}}
        end
      end)
      |> case do
        :ok -> record_available_credit_uses(operation, lot_uses)
        error -> error
      end
    end
  end

  defp record_available_credit_uses(operation, lot_uses) do
    Enum.reduce_while(lot_uses, :ok, fn {lot, amount}, :ok ->
      case Finance.change_available_credit(operation, lot.id, -amount) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp transfer_deposit(op) do
    with :ok <- validate_transfer_identifiers(op),
         {:ok, source} <- fetch_transfer_group(op["source_group_id"]),
         {:ok, destination} <- fetch_transfer_group(op["destination_group_id"]),
         :ok <- check_named_revision(source, op, "expected_revision"),
         :ok <- check_named_revision(destination, op, "destination_expected_revision"),
         true <- structurally_complete?(op),
         {:ok, _date} <- parse_date(op["occurred_on"], :invalid_operation),
         :ok <- validate_transfer_groups(source, destination),
         {:ok, amount} <- payment_amount(op),
         :ok <- validate_transfer_capacity(source, destination, amount),
         {:ok, moved} <- FundingTransfer.move(source, destination, amount),
         :ok <- Finance.record_cash(op, source.property_id, "transferred_out", moved.cash_cents),
         :ok <-
           Finance.record_cash(op, destination.property_id, "transferred_in", moved.cash_cents),
         {:ok, updated} <- update_group_totals([source.id, destination.id]) do
      source = Map.fetch!(updated, source.id)
      destination = Map.fetch!(updated, destination.id)

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: amount,
         source_outstanding_deposit_cents: outstanding_deposit(source),
         destination_outstanding_deposit_cents: outstanding_deposit(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    else
      false ->
        {:error, :invalid_operation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_transfer_identifiers(op) do
    if valid_identifier?(op["source_group_id"]) and valid_identifier?(op["destination_group_id"]),
      do: :ok,
      else: {:error, :invalid_operation}
  end

  defp fetch_transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, {:group_not_found, group_id}}
      group -> {:ok, group}
    end
  end

  defp check_named_revision(group, op, key) do
    case Map.fetch(op, key) do
      {:ok, expected} when is_integer(expected) and expected != group.revision ->
        {:error, {:stale_revision, group.group_id, expected, group.revision}}

      {:ok, expected} when is_integer(expected) ->
        :ok

      :error ->
        :ok

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp validate_transfer_groups(source, destination) do
    cond do
      source.id == destination.id or source.guest_id != destination.guest_id ->
        {:error, :invalid_transfer}

      source.status != "active" ->
        {:error, {:group_not_active, source.group_id}}

      destination.status != "active" ->
        {:error, {:group_not_active, destination.group_id}}

      true ->
        :ok
    end
  end

  defp validate_transfer_capacity(source, destination, amount) do
    cond do
      amount > source.deposit_paid_cents -> {:error, :transfer_exceeds_held_funding}
      amount > outstanding_deposit(destination) -> {:error, :transfer_exceeds_outstanding}
      true -> :ok
    end
  end

  defp cancel_group(group, op) do
    with :ok <- active(group) do
      settle_rooms(
        group,
        Repo.all(
          from r in Room,
            where: r.group_id == ^group.id and r.status == "active",
            order_by: r.position
        ),
        op,
        true
      )
    end
  end

  defp cancel_rooms(group, op) do
    with :ok <- active(group),
         {:ok, rooms} <- selected_rooms(group, op["room_ids"]),
         do: settle_rooms(group, rooms, op, false)
  end

  defp selected_rooms(_group, ids) when not is_list(ids), do: {:error, :invalid_rooms}

  defp selected_rooms(group, ids) do
    if ids != [] and Enum.all?(ids, &valid_identifier?/1) and Enum.uniq(ids) == ids do
      rooms =
        Repo.all(
          from r in Room,
            where: r.group_id == ^group.id and r.room_id in ^ids,
            order_by: r.position
        )

      if length(rooms) == length(ids) and Enum.all?(rooms, &(&1.status == "active")),
        do: {:ok, rooms},
        else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp settle_rooms(group, rooms, op, full?) do
    with {:ok, date} <- parse_date(op["occurred_on"], :invalid_operation),
         {:ok, method} <- refund_method(op),
         refundable = Policy.refundable?(group, date),
         :ok <- refund_method_available(method, refundable),
         {:ok, settlement} <- settle_room_cash(group, rooms, op, date, refundable, method),
         :ok <- settle_room_credit(rooms, op, date, refundable),
         :ok <- cancel_room_rows(rooms),
         {:ok, updated} <- update_group_totals(group) do
      result = %{
        group_id: updated.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated.revision
      }

      {:ok,
       if(full?,
         do: result,
         else: Map.put(result, :cancelled_room_ids, Enum.map(rooms, & &1.room_id))
       )}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_room_cash(group, rooms, op, date, refundable, method) do
    ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.room_id in ^ids,
          order_by: a.allocation_order
      )

    amount = Enum.sum_by(allocations, & &1.amount_cents)

    {kind, refunded, retained} =
      cond do
        refundable and method == "hotel_credit" -> {"credit_conversion", 0, 0}
        refundable -> {"refund", amount, 0}
        true -> {"retention", 0, amount}
      end

    with :ok <- insert_fact(group, op, date, kind, amount),
         :ok <- move_payment_dispositions(group, allocations, kind),
         :ok <- Finance.record_cash(op, group.property_id, finance_cash_kind(kind), amount),
         {:ok, issued} <-
           maybe_issue_credit(group, op, date, method, refundable, allocations, amount) do
      Repo.delete_all(from a in CashAllocation, where: a.room_id in ^ids)
      {:ok, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}}
    end
  end

  defp move_payment_dispositions(group, allocations, kind) do
    field =
      %{
        "refund" => :refunded_cents,
        "retention" => :retained_cents,
        "credit_conversion" => :converted_to_credit_cents
      }[kind]

    allocations
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.reduce_while(:ok, fn {id, rows}, :ok ->
      amount = Enum.sum_by(rows, & &1.amount_cents)
      payment = Repo.get_by!(PaymentDisposition, payment_operation_id: id)
      changes = %{field => Map.fetch!(payment, field), held_cents: payment.held_cents - amount}
      changes = Map.update!(changes, field, &(&1 + amount))

      with {:ok, _} <- payment |> Changeset.change(changes) |> Repo.update(),
           {:ok, _} <-
             %CashSettlement{}
             |> Changeset.cast(
               %{
                 payment_operation_id: id,
                 group_id: group.id,
                 kind: kind,
                 amount_cents: amount
               },
               [:payment_operation_id, :group_id, :kind, :amount_cents]
             )
             |> Repo.insert() do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp finance_cash_kind("refund"), do: "refunded"
  defp finance_cash_kind("retention"), do: "retained"
  defp finance_cash_kind("credit_conversion"), do: "converted_to_credit"

  defp maybe_issue_credit(_, _, _, _, _, _, 0), do: {:ok, 0}

  defp maybe_issue_credit(group, op, date, "hotel_credit", true, allocations, amount) do
    issued = amount + rounded_percentage(amount, 10)

    with {:ok, lot} <- issue_credit(group.guest_id, op["operation_id"], date, issued),
         :ok <- create_entitlements(lot, allocations),
         :ok <- Finance.record_credit(op, "issued", issued),
         :ok <- record_issued_availability(op, lot, issued),
         do: {:ok, issued}
  end

  defp maybe_issue_credit(_, _, _, _, _, _, _), do: {:ok, 0}

  defp create_entitlements(lot, allocations) do
    allocations
    |> Enum.chunk_by(& &1.payment_operation_id)
    |> Enum.map(fn rows ->
      {hd(rows).payment_operation_id, Enum.sum_by(rows, & &1.amount_cents)}
    end)
    |> Enum.reduce_while({:ok, 0}, fn {payment_id, principal}, {:ok, prior} ->
      next = prior + principal
      credit = next + rounded_percentage(next, 10) - prior - rounded_percentage(prior, 10)

      case %CreditEntitlement{}
           |> Changeset.cast(
             %{
               credit_lot_id: lot.id,
               payment_operation_id: payment_id,
               principal_cents: principal,
               credit_cents: credit
             },
             [:credit_lot_id, :payment_operation_id, :principal_cents, :credit_cents]
           )
           |> Repo.insert() do
        {:ok, _} -> {:cont, {:ok, next}}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp record_issued_availability(op, lot, issued) do
    if Finance.credit_available_on_posting?(op, lot.expires_on) do
      Finance.change_available_credit(op, lot.id, issued)
    else
      Finance.record_credit(op, "expired", issued)
    end
  end

  defp settle_room_credit(rooms, op, date, refundable) do
    ids = Enum.map(rooms, & &1.id)

    Repo.all(from a in CreditAllocation, where: a.room_id in ^ids, preload: [:credit_lot])
    |> Enum.reduce_while(:ok, fn allocation, :ok ->
      with :ok <- settle_credit_allocation(allocation, op, date, refundable),
           {:ok, _} <- Repo.delete(allocation),
           do: {:cont, :ok},
           else: ({:error, e} -> {:halt, {:error, e}})
    end)
  end

  defp settle_credit_allocation(allocation, op, _date, false),
    do: Finance.record_credit(op, "consumed", allocation.amount_cents)

  defp settle_credit_allocation(allocation, op, date, true),
    do: restore_credit(allocation.credit_lot, allocation.amount_cents, op, date)

  defp restore_credit(lot, amount, op, date) do
    lot = Repo.get!(CreditLot, lot.id)
    absorbed = min(lot.unrecovered_clawback_cents, amount)
    available = amount - absorbed

    remaining =
      if Date.after?(date, lot.expires_on),
        do: lot.remaining_cents,
        else: lot.remaining_cents + available

    with {:ok, _} <-
           lot
           |> Changeset.change(
             remaining_cents: remaining,
             unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
           )
           |> Repo.update(),
         :ok <- Finance.record_credit(op, "absorbed", absorbed),
         :ok <- record_restored_credit(op, lot, available) do
      :ok
    end
  end

  defp record_restored_credit(op, lot, available) do
    if Finance.credit_available_on_posting?(op, lot.expires_on) do
      Finance.change_available_credit(op, lot.id, available)
    else
      Finance.record_credit(op, "expired", available)
    end
  end

  defp cancel_room_rows(rooms),
    do:
      Enum.reduce_while(rooms, :ok, fn room, :ok ->
        case room |> Changeset.change(status: "cancelled") |> Repo.update() do
          {:ok, _} -> {:cont, :ok}
          {:error, e} -> {:halt, {:error, e}}
        end
      end)

  defp apply_payment_update(:reduction, payment, group, op),
    do: reduce_payment(payment, group, op)

  defp apply_payment_update(:chargeback, payment, group, op), do: charge_back(payment, group, op)

  defp reduce_payment(payment, group, op) do
    with {:ok, date} <- parse_date(op["occurred_on"], :invalid_operation),
         {:ok, amount} <- payment_amount(op),
         :ok <- reducible(payment, amount),
         {:ok, removed} <- remove_held(payment.payment_operation_id, amount),
         {:ok, _} <-
           payment
           |> Changeset.change(
             held_cents: payment.held_cents - amount,
             reduced_cents: payment.reduced_cents + amount
           )
           |> Repo.update(),
         :ok <- insert_fact(group, op, date, "cash_reduction", amount),
         :ok <- record_cash_by_group(op, "reduced", removed),
         {:ok, updated_groups} <- update_group_totals([group.id | Map.keys(removed)]),
         updated = Map.fetch!(updated_groups, group.id) do
      {:ok,
       %{
         payment_operation_id: payment.payment_operation_id,
         group_id: updated.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: outstanding_deposit(updated),
         revision: updated.revision
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reducible(%{held_cents: 0}, _), do: {:error, :payment_not_reducible}

  defp reducible(payment, amount) when amount > payment.held_cents,
    do: {:error, :reduction_exceeds_held_cash}

  defp reducible(_, _), do: :ok

  defp charge_back(payment, group, op) do
    chargeable = payment.recorded_cents - payment.reduced_cents - payment.charged_back_cents

    with {:ok, date} <- parse_date(op["occurred_on"], :invalid_operation),
         true <- chargeable > 0,
         {:ok, removed} <-
           remove_held(payment.payment_operation_id, payment.held_cents),
         :ok <- chargeback_facts(group, op, date, payment),
         :ok <- record_chargeback_cash(op, removed, payment.payment_operation_id),
         :ok <- revoke_entitlements(payment.payment_operation_id, op),
         {:ok, _} <-
           payment
           |> Changeset.change(
             held_cents: 0,
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             charged_back_cents: payment.charged_back_cents + chargeable
           )
           |> Repo.update(),
         {:ok, updated_groups} <- update_group_totals([group.id | Map.keys(removed)]),
         updated = Map.fetch!(updated_groups, group.id) do
      {:ok,
       %{
         payment_operation_id: payment.payment_operation_id,
         group_id: updated.group_id,
         charged_back_cents: chargeable,
         outstanding_deposit_cents: outstanding_deposit(updated),
         revision: updated.revision
       }}
    else
      false -> {:error, :payment_not_chargeable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_held(_, 0), do: {:ok, %{}}

  defp remove_held(payment_id, amount) do
    Repo.all(
      from a in CashAllocation,
        where: a.payment_operation_id == ^payment_id,
        order_by: [desc: a.allocation_order]
    )
    |> Enum.reduce_while({amount, %{}}, fn allocation, {left, groups} ->
      used = min(allocation.amount_cents, left)

      result =
        if used == allocation.amount_cents,
          do: Repo.delete(allocation),
          else:
            allocation
            |> Changeset.change(amount_cents: allocation.amount_cents - used)
            |> Repo.update()

      case result do
        {:ok, _} ->
          groups = Map.update(groups, allocation.group_id, used, &(&1 + used))

          if left == used,
            do: {:halt, {0, groups}},
            else: {:cont, {left - used, groups}}

        {:error, e} ->
          {:halt, {:error, e}}
      end
    end)
    |> case do
      {0, groups} -> {:ok, groups}
      {:error, e} -> {:error, e}
      _ -> {:error, :payment_not_reducible}
    end
  end

  defp chargeback_facts(group, op, date, payment) do
    [
      {"chargeback_held", payment.held_cents},
      {"chargeback_refund", payment.refunded_cents},
      {"chargeback_retention", payment.retained_cents},
      {"chargeback_conversion", payment.converted_to_credit_cents}
    ]
    |> Enum.reduce_while(:ok, fn {kind, amount}, :ok ->
      case insert_fact(group, op, date, kind, amount) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp revoke_entitlements(payment_id, op) do
    Repo.all(
      from e in CreditEntitlement,
        where: e.payment_operation_id == ^payment_id and e.revoked_cents < e.credit_cents,
        order_by: e.id
    )
    |> Enum.reduce_while(:ok, fn entitlement, :ok ->
      amount = entitlement.credit_cents - entitlement.revoked_cents
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      available = min(lot.remaining_cents, amount)

      with {:ok, _} <-
             lot
             |> Changeset.change(
               remaining_cents: lot.remaining_cents - available,
               unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount - available
             )
             |> Repo.update(),
           {:ok, _} <-
             entitlement
             |> Changeset.change(revoked_cents: entitlement.credit_cents)
             |> Repo.update(),
           :ok <- Finance.change_available_credit(op, lot.id, -available),
           :ok <-
             Finance.record_credit(
               op,
               "revoked",
               if(Finance.credit_available_on_posting?(op, lot.expires_on),
                 do: available,
                 else: 0
               )
             ),
           do: {:cont, :ok},
           else: ({:error, e} -> {:halt, {:error, e}})
    end)
  end

  defp record_cash_by_group(op, kind, amounts) do
    Enum.reduce_while(amounts, :ok, fn {group_id, amount}, :ok ->
      property_id = Repo.get!(Group, group_id).property_id

      case Finance.record_cash(op, property_id, kind, amount) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp record_chargeback_cash(op, held_by_group, payment_id) do
    with :ok <- record_cash_by_group(op, "charged_back", held_by_group) do
      Repo.all(
        from s in CashSettlement,
          where: s.payment_operation_id == ^payment_id and s.charged_back_cents < s.amount_cents,
          preload: [:group]
      )
      |> Enum.reduce_while(:ok, fn settlement, :ok ->
        amount = settlement.amount_cents - settlement.charged_back_cents
        reversal_kind = finance_cash_kind(settlement.kind)

        with :ok <- Finance.record_cash(op, settlement.group.property_id, reversal_kind, -amount),
             :ok <- Finance.record_cash(op, settlement.group.property_id, "charged_back", amount),
             {:ok, _} <-
               settlement
               |> Changeset.change(charged_back_cents: settlement.amount_cents)
               |> Repo.update() do
          {:cont, :ok}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp update_group_totals(%Group{} = group), do: recompute_group_totals(group)

  defp update_group_totals(group_ids) when is_list(group_ids) do
    group_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn group_id, {:ok, updated} ->
      case Group |> Repo.get!(group_id) |> recompute_group_totals() do
        {:ok, group} -> {:cont, {:ok, Map.put(updated, group.id, group)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp recompute_group_totals(group) do
    rooms = Repo.all(from r in Room, where: r.group_id == ^group.id and r.status == "active")
    ids = Enum.map(rooms, & &1.id)
    cash = allocation_sum(CashAllocation, ids)
    credit = allocation_sum(CreditAllocation, ids)

    group
    |> Changeset.change(
      status: if(ids == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.sum_by(rooms, & &1.lodging_total_cents),
      deposit_due_cents: Enum.sum_by(rooms, & &1.deposit_due_cents),
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      revision: group.revision + 1
    )
    |> Repo.update()
  end

  defp allocation_sum(_, []), do: 0

  defp allocation_sum(schema, ids),
    do:
      Repo.one(
        from a in schema, where: a.room_id in ^ids, select: coalesce(sum(a.amount_cents), 0)
      ) || 0

  defp allocate_to_rooms(group, amount, insert) do
    room_uses(group, amount)
    |> Enum.reduce_while(:ok, fn {room, used}, :ok ->
      case insert.(room, used) do
        {:ok, _} -> {:cont, :ok}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  defp room_uses(group, amount) do
    {uses, _} =
      Repo.all(
        from r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          order_by: r.position,
          preload: [:cash_allocations, :credit_allocations]
      )
      |> Enum.reduce_while({[], amount}, fn room, {uses, left} ->
        paid =
          Enum.sum_by(room.cash_allocations, & &1.amount_cents) +
            Enum.sum_by(room.credit_allocations, & &1.amount_cents)

        used = min(max(room.deposit_due_cents - paid, 0), left)
        next = if used > 0, do: [{room, used} | uses], else: uses
        if left == used, do: {:halt, {next, 0}}, else: {:cont, {next, left - used}}
      end)

    Enum.reverse(uses)
  end

  defp sufficient_credit(guest, date, amount) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest and l.remaining_cents > 0 and l.expires_on >= ^date,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    if Enum.sum_by(lots, & &1.remaining_cents) >= amount,
      do: {:ok, lots},
      else: {:error, :insufficient_credit}
  end

  defp consume_lots(lots, amount) do
    Enum.reduce_while(lots, {[], amount}, fn lot, {uses, left} ->
      used = min(lot.remaining_cents, left)

      case lot
           |> Changeset.change(remaining_cents: lot.remaining_cents - used)
           |> Repo.update() do
        {:ok, updated} ->
          if left == used,
            do: {:halt, {:ok, Enum.reverse([{updated, used} | uses])}},
            else: {:cont, {[{updated, used} | uses], left - used}}

        {:error, e} ->
          {:halt, {:error, e}}
      end
    end)
  end

  defp intersect_uses(rooms, lots), do: intersect_uses(rooms, lots, [])
  defp intersect_uses([], _, acc), do: Enum.reverse(acc)
  defp intersect_uses(_, [], acc), do: Enum.reverse(acc)

  defp intersect_uses([{room, ra} | rooms], [{lot, la} | lots], acc) do
    used = min(ra, la)
    next_rooms = if ra == used, do: rooms, else: [{room, ra - used} | rooms]
    next_lots = if la == used, do: lots, else: [{lot, la - used} | lots]
    intersect_uses(next_rooms, next_lots, [{room, lot, used} | acc])
  end

  defp refund_method(op) do
    case Map.get(op, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _ -> {:error, :invalid_operation}
    end
  end

  defp refund_method_available("hotel_credit", false), do: {:error, :refund_method_not_available}
  defp refund_method_available(_, _), do: :ok

  defp issue_credit(guest, source, date, amount),
    do:
      %CreditLot{}
      |> Changeset.cast(
        %{
          guest_id: guest,
          source_operation_id: source,
          remaining_cents: amount,
          expires_on: Date.add(date, 365)
        },
        [:guest_id, :source_operation_id, :remaining_cents, :expires_on]
      )
      |> Repo.insert()

  defp rounded_percentage(amount, percent), do: div(amount * percent + 50, 100)

  defp payment_amount(op) do
    case op["amount_cents"] do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp insert_fact(_, _, _, _, 0), do: :ok

  defp insert_fact(group, op, date, kind, amount) do
    case %LedgerEntry{}
         |> Changeset.cast(
           %{
             group_id: group.id,
             operation_id: op["operation_id"],
             occurred_on: date,
             kind: kind,
             amount_cents: amount
           },
           [:group_id, :operation_id, :occurred_on, :kind, :amount_cents]
         )
         |> Repo.insert() do
      {:ok, _} -> :ok
      {:error, e} -> {:error, e}
    end
  end

  defp validate_stay(arrival, departure),
    do: if(Date.before?(arrival, departure), do: :ok, else: {:error, :invalid_stay})

  defp validate_rate_plan(plan),
    do: if(plan in @rate_plans, do: :ok, else: {:error, :invalid_rate_plan})

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          valid_identifier?(id) and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    ids = Enum.map(rooms, & &1["room_id"])

    if valid and Enum.uniq(ids) == ids,
      do:
        {:ok,
         Enum.map(rooms, &%{room_id: &1["room_id"], nightly_rate_cents: &1["nightly_rate_cents"]})},
      else: {:error, :invalid_rooms}
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp parse_date(value, error) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, error}
    end
  end

  defp parse_date(_, error), do: {:error, error}
  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: {:error, :group_not_active}
  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp format_result(id, {:ok, fields}),
    do: fields |> Map.put(:operation_id, id) |> Map.put(:status, "applied")

  defp format_result(id, {:error, {:stale_revision, group_id, expected, actual}}),
    do: %{
      operation_id: id,
      status: "rejected",
      code: "stale_revision",
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    }

  defp format_result(id, {:error, {code, group_id}})
       when code in [:group_not_found, :group_not_active],
       do: %{
         operation_id: id,
         status: "rejected",
         code: Atom.to_string(code),
         group_id: group_id
       }

  defp format_result(id, {:error, %Changeset{}}),
    do: format_result(id, {:error, :invalid_operation})

  defp format_result(id, {:error, code}),
    do: %{operation_id: id, status: "rejected", code: Atom.to_string(code)}
end
