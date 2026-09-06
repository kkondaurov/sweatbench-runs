defmodule GroupStay do
  @moduledoc """
  GroupStay keeps the contexts that define your domain and business logic.

  Funding is recorded twice on purpose: group and room aggregates make the
  read API inexpensive, while allocation rows preserve the exact history
  needed for reductions, chargebacks, and room settlements.
  """

  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    Group,
    Operation,
    Repo,
    Room
  }

  @valid_rate_plans ["flexible", "advance_purchase"]
  @active_status "active"
  @cancelled_status "cancelled"
  @room_active "active"
  @room_cancelled "cancelled"
  @held "held"
  @reduced "reduced"
  @charged_back "charged_back"
  @policy_cutover ~D[2027-01-01]
  @pending_result_json ~s({"status":"pending"})

  @doc "Applies one partner operation and durably remembers its result by operation id."
  def apply_operation(operation) when is_map(operation) do
    if valid_operation_id?(operation) do
      # The unique operation_id index is the cross-process arbiter; this lock
      # also keeps same-node domain checks and writes from contending.
      :global.trans({__MODULE__, :operations}, fn ->
        run_transaction(fn -> apply_durable_operation(operation) end)
      end)
    else
      {:error, rejection(operation, "invalid_operation")}
    end
  end

  def apply_operation(operation), do: {:error, rejection(operation, "invalid_operation")}

  @doc "Returns the stored result for an operation or `:operation_not_found`."
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      %Operation{result_json: result_json} -> {:ok, Jason.decode!(result_json)}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  @doc "Returns a serialized group or `:group_not_found`."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.transaction(fn ->
           case Repo.get(Group, group_id) do
             nil ->
               {:error, :group_not_found}

             group ->
               group = ensure_room_accounting!(group)
               {:ok, serialize_group(group)}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  @doc "Returns credit available to a guest as of the supplied UTC date."
  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots = available_credit_lots(guest_id, as_of)

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

  @doc "Returns the finance totals as of the supplied UTC date."
  def ledger_totals(as_of \\ Date.utc_today()) do
    Repo.transaction(fn ->
      Repo.all(Group) |> Enum.each(&ensure_room_accounting!/1)

      cash_totals =
        Repo.all(
          from allocation in CashAllocation,
            group_by: allocation.disposition,
            select: {allocation.disposition, coalesce(sum(allocation.amount_cents), 0)}
        )
        |> Map.new()

      %{
        cash_held_cents: Map.get(cash_totals, @held, 0),
        cash_refunded_cents: Map.get(cash_totals, "refunded", 0),
        cash_retained_cents: Map.get(cash_totals, "retained", 0),
        cash_converted_to_credit_cents: Map.get(cash_totals, "converted", 0),
        cash_reduced_cents: Map.get(cash_totals, @reduced, 0),
        cash_charged_back_cents: Map.get(cash_totals, @charged_back, 0),
        credit_liability_cents: credit_liability_cents(as_of),
        credit_shortfall_cents: credit_shortfall_cents()
      }
    end)
    |> case do
      {:ok, totals} -> totals
      {:error, reason} -> raise reason
    end
  end

  @doc false
  def backfill_room_accounting! do
    Repo.all(Group) |> Enum.each(&ensure_room_accounting!/1)
    :ok
  end

  @doc false
  def backfill_allocation_order! do
    operation_order =
      Repo.all(from operation in Operation, select: {operation.operation_id, operation.id})
      |> Map.new()

    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.allocation_sequence == 0,
          order_by: allocation.id
      )
      |> Enum.map(&{:cash, &1})

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.allocation_sequence == 0,
          order_by: allocation.id
      )
      |> Enum.map(&{:credit, &1})

    cash_allocations
    |> Kernel.++(credit_allocations)
    |> Enum.sort_by(fn
      {:cash, allocation} -> allocation_order_key(:cash, allocation, operation_order)
      {:credit, allocation} -> allocation_order_key(:credit, allocation, operation_order)
    end)
    |> Enum.reduce(next_allocation_sequence!() - 1, fn {_kind, allocation}, sequence ->
      sequence = sequence + 1

      allocation
      |> Ecto.Changeset.change(allocation_sequence: sequence)
      |> Repo.update!()

      sequence
    end)

    :ok
  end

  @doc "Returns the current disposition of one durably recorded cash payment."
  def payment_reconciliation(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> reconcile_payment_operation(operation)
    end
  end

  def payment_reconciliation(_payment_operation_id), do: {:error, :operation_not_found}

  defp reconcile_payment_operation(%Operation{} = operation) do
    result = Jason.decode!(operation.result_json)

    if operation.operation_type != "record_cash_payment" or result["status"] != "applied" do
      {:error, :payment_not_reconcilable}
    else
      group_id = result["group_id"]

      case Repo.get(Group, group_id) do
        nil ->
          {:error, :payment_not_reconcilable}

        _group ->
          dispositions = cash_dispositions_for_payment(operation.operation_id)

          amounts = [
            Map.get(dispositions, @held, 0),
            Map.get(dispositions, "refunded", 0),
            Map.get(dispositions, "retained", 0),
            Map.get(dispositions, "converted", 0),
            Map.get(dispositions, @reduced, 0),
            Map.get(dispositions, @charged_back, 0)
          ]

          if Enum.sum(amounts) == result["amount_cents"] and
               Map.keys(dispositions)
               |> Enum.all?(
                 &(&1 in [@held, "refunded", "retained", "converted", @reduced, @charged_back])
               ) do
            payment = %{
              "payment_operation_id" => operation.operation_id,
              "original_group_id" => group_id,
              "recorded_cents" => result["amount_cents"],
              "held_cents" => Map.get(dispositions, @held, 0),
              "refunded_cents" => Map.get(dispositions, "refunded", 0),
              "retained_cents" => Map.get(dispositions, "retained", 0),
              "converted_to_credit_cents" => Map.get(dispositions, "converted", 0),
              "reduced_cents" => Map.get(dispositions, @reduced, 0),
              "charged_back_cents" => Map.get(dispositions, @charged_back, 0)
            }

            if payment_has_transferred_funding?(operation.operation_id) do
              {:ok, Map.put(payment, "held_by_group", held_cash_by_group(operation.operation_id))}
            else
              {:ok, payment}
            end
          else
            {:error, :payment_not_reconcilable}
          end
      end
    end
  end

  defp cash_dispositions_for_payment(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        group_by: allocation.disposition,
        select: {allocation.disposition, coalesce(sum(allocation.amount_cents), 0)}
    )
    |> Map.new()
  end

  defp payment_has_transferred_funding?(payment_operation_id) do
    Repo.exists?(
      from allocation in CashAllocation,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.transferred == true
    )
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.disposition == @held,
        group_by: allocation.group_id,
        order_by: allocation.group_id,
        select: {allocation.group_id, coalesce(sum(allocation.amount_cents), 0)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp credit_liability_cents(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.issued_on <= ^as_of and lot.expires_on > ^as_of,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          join: lot in CreditLot,
          on: lot.id == allocation.credit_lot_id,
          where:
            allocation.status == "active" and group.status == @active_status and
              lot.issued_on <= ^as_of,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp credit_shortfall_cents do
    Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, total ->
      applied =
        Repo.one(
          from allocation in CreditAllocation,
            join: group in Group,
            on: group.group_id == allocation.group_id,
            where:
              allocation.credit_lot_id == ^lot.id and allocation.status == "active" and
                group.status == @active_status,
            select: coalesce(sum(allocation.amount_cents), 0)
        )

      total + min(lot.unrecovered_clawback_cents || 0, applied)
    end)
  end

  defp run_transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_durable_operation(operation) do
    payload_json = Jason.encode!(operation)

    case claim_operation(operation, payload_json) do
      {:existing, existing} ->
        replay_or_conflict(existing, operation)

      :claimed ->
        result = with_domain_savepoint(fn -> apply_domain_operation(operation) end)
        persist_operation_result!(operation["operation_id"], result)
        result
    end
  end

  defp claim_operation(operation, payload_json) do
    attrs = %{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      payload_json: payload_json,
      result_json: @pending_result_json
    }

    case Repo.insert_all(Operation, [attrs],
           on_conflict: :nothing,
           conflict_target: [:operation_id]
         ) do
      {1, _} -> :claimed
      {0, _} -> {:existing, Repo.get_by!(Operation, operation_id: operation["operation_id"])}
    end
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _type -> nil
    end
  end

  defp replay_or_conflict(operation_record, operation) do
    if equivalent_payload?(operation_record.payload_json, operation) do
      {:ok, Jason.decode!(operation_record.result_json)}
    else
      {:error, rejection(operation, "operation_id_conflict")}
    end
  end

  defp equivalent_payload?(stored_payload_json, operation) do
    Jason.decode!(stored_payload_json) === Jason.decode!(Jason.encode!(operation))
  end

  defp persist_operation_result!(operation_id, {status, result}) when status in [:ok, :error] do
    operation = Repo.get_by!(Operation, operation_id: operation_id)

    operation
    |> Ecto.Changeset.change(result_json: Jason.encode!(result))
    |> Repo.update!()

    {status, result}
  end

  defp with_domain_savepoint(fun) do
    savepoint = "group_stay_domain_operation"
    Ecto.Adapters.SQL.query!(Repo, "SAVEPOINT #{savepoint}")

    case fun.() do
      {:ok, _result} = result ->
        Ecto.Adapters.SQL.query!(Repo, "RELEASE SAVEPOINT #{savepoint}")
        result

      {:error, _result} = result ->
        Ecto.Adapters.SQL.query!(Repo, "ROLLBACK TO SAVEPOINT #{savepoint}")
        Ecto.Adapters.SQL.query!(Repo, "RELEASE SAVEPOINT #{savepoint}")
        result
    end
  end

  defp apply_domain_operation(operation) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> update_group(operation, :payment)
      "reschedule_group" -> update_group(operation, :reschedule)
      "cancel_group" -> update_group(operation, :cancel)
      "cancel_rooms" -> update_group(operation, :cancel_rooms)
      "apply_hotel_credit" -> update_group(operation, :hotel_credit)
      "transfer_deposit" -> transfer_deposit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      _type -> {:error, rejection(operation, "invalid_operation")}
    end
  end

  defp open_group(operation) do
    with :ok <- require_identifier(operation, "group_id"),
         :ok <- ensure_group_does_not_exist(operation["group_id"], operation),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], "invalid_operation", operation),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay", operation),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay", operation),
         :ok <- validate_stay(arrival_on, departure_on, operation),
         :ok <- validate_open_identifiers(operation),
         :ok <- validate_rate_plan(operation["rate_plan"], operation),
         {:ok, rooms} <- normalize_rooms(operation["rooms"], arrival_on, departure_on, operation),
         {:ok, group} <- insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "deposit_due_cents" => group.deposit_due_cents,
         "revision" => group.revision
       }}
    end
  end

  defp update_group(operation, kind) do
    with {:ok, group} <- existing_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- validate_active(group, operation),
         result <- apply_group_update(group, operation, kind) do
      result
    end
  end

  defp apply_group_update(group, operation, :payment) do
    with :ok <- validate_occurred_on(operation),
         :ok <- validate_amount(operation["amount_cents"], operation),
         :ok <- validate_payment_amount(group, operation["amount_cents"], operation),
         :ok <- allocate_cash(group, operation["amount_cents"], operation["operation_id"]),
         updated_group <- sync_group_totals!(group.group_id),
         {:ok, updated_group} <- increment_group(updated_group, %{}, operation) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => operation["amount_cents"],
         "outstanding_deposit_cents" => outstanding_deposit(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp apply_group_update(group, operation, :reschedule) do
    with :ok <- validate_occurred_on(operation),
         {:ok, new_arrival_on} <-
           parse_date(operation["new_arrival_on"], "invalid_stay", operation),
         :ok <- validate_rescheduled_arrival(new_arrival_on, operation["occurred_on"], operation),
         new_departure_on <-
           Date.add(group.departure_on, Date.diff(new_arrival_on, group.arrival_on)),
         {:ok, updated_group} <-
           increment_group(
             group,
             %{arrival_on: new_arrival_on, departure_on: new_departure_on},
             operation
           ) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
         "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
         "policy_version" => effective_policy_version(updated_group),
         "refundable_until" => refundable_until(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp apply_group_update(group, operation, :hotel_credit) do
    with {:ok, occurred_on} <-
           parse_date(operation["occurred_on"], "invalid_operation", operation),
         :ok <- validate_amount(operation["amount_cents"], operation),
         :ok <- validate_payment_amount(group, operation["amount_cents"], operation),
         :ok <- allocate_credit(group, operation["amount_cents"], occurred_on, operation),
         updated_group <- sync_group_totals!(group.group_id),
         {:ok, updated_group} <- increment_group(updated_group, %{}, operation) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => operation["amount_cents"],
         "outstanding_deposit_cents" => outstanding_deposit(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp apply_group_update(group, operation, :cancel) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay", operation),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- validate_refund_method_available(group, refund_method, occurred_on, operation),
         {:ok, selected_rooms} <- active_rooms_for_group(group.group_id),
         {:ok, updated_group, settlement} <-
           settle_selected_rooms(group, selected_rooms, occurred_on, refund_method, operation) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "refunded_cents" => settlement.refunded_cents,
         "retained_cents" => settlement.retained_cents,
         "credit_issued_cents" => settlement.credit_issued_cents,
         "revision" => updated_group.revision
       }}
    end
  end

  defp apply_group_update(group, operation, :cancel_rooms) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay", operation),
         {:ok, selected_rooms} <-
           selected_active_rooms(group.group_id, operation["room_ids"], operation),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- validate_refund_method_available(group, refund_method, occurred_on, operation),
         {:ok, updated_group, settlement} <-
           settle_selected_rooms(group, selected_rooms, occurred_on, refund_method, operation) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "group_id" => group.group_id,
         "cancelled_room_ids" => Enum.map(selected_rooms, & &1.room_id),
         "refunded_cents" => settlement.refunded_cents,
         "retained_cents" => settlement.retained_cents,
         "credit_issued_cents" => settlement.credit_issued_cents,
         "revision" => updated_group.revision
       }}
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source} <- transfer_group(operation, "source_group_id"),
         {:ok, destination} <- transfer_group(operation, "destination_group_id"),
         :ok <- check_transfer_revision(source, operation, "expected_revision"),
         :ok <-
           check_transfer_revision(
             destination,
             operation,
             "destination_expected_revision"
           ),
         :ok <- validate_transfer_groups(source, destination, operation),
         :ok <- validate_transfer_active(source, operation),
         :ok <- validate_transfer_active(destination, operation),
         :ok <- validate_amount(operation["amount_cents"], operation),
         source_held <- held_funding_cents(source.group_id),
         :ok <- validate_transfer_held(source_held, operation),
         :ok <-
           validate_transfer_outstanding(
             outstanding_deposit(destination),
             operation
           ),
         :ok <- move_deposit_funding(source.group_id, destination, operation),
         source_group <- sync_group_totals!(source.group_id),
         destination_group <- sync_group_totals!(destination.group_id),
         {:ok, source_group} <- increment_group(source_group, %{}, operation),
         {:ok, destination_group} <- increment_group(destination_group, %{}, operation) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "source_group_id" => source.group_id,
         "destination_group_id" => destination.group_id,
         "amount_cents" => operation["amount_cents"],
         "source_outstanding_deposit_cents" => outstanding_deposit(source_group),
         "destination_outstanding_deposit_cents" => outstanding_deposit(destination_group),
         "source_revision" => source_group.revision,
         "destination_revision" => destination_group.revision
       }}
    end
  end

  defp transfer_group(operation, field) do
    group_id = Map.get(operation, field)

    cond do
      not valid_identifier?(group_id) ->
        {:error, rejection(operation, "invalid_operation")}

      true ->
        case Repo.get(Group, group_id) do
          nil -> {:error, rejection(operation, "group_not_found", %{"group_id" => group_id})}
          group -> {:ok, ensure_room_accounting!(group)}
        end
    end
  end

  defp check_transfer_revision(group, operation, field) do
    if Map.has_key?(operation, field) and operation[field] != group.revision do
      {:error,
       rejection(operation, "stale_revision", %{
         "group_id" => group.group_id,
         "expected_revision" => operation[field],
         "actual_revision" => group.revision
       })}
    else
      :ok
    end
  end

  defp validate_transfer_groups(source, destination, operation) do
    if source.group_id == destination.group_id or source.guest_id != destination.guest_id do
      {:error, rejection(operation, "invalid_transfer")}
    else
      :ok
    end
  end

  defp validate_transfer_active(%Group{status: @active_status}, _operation), do: :ok

  defp validate_transfer_active(group, operation) do
    {:error, rejection(operation, "group_not_active", %{"group_id" => group.group_id})}
  end

  defp held_funding_cents(group_id) do
    cash =
      Repo.one(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.disposition == @held and
              room.status == @room_active,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    credit =
      Repo.one(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.status == "active" and
              room.status == @room_active,
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    cash + credit
  end

  defp validate_transfer_held(held_cents, operation) do
    if operation["amount_cents"] <= held_cents do
      :ok
    else
      {:error, rejection(operation, "transfer_exceeds_held_funding")}
    end
  end

  defp validate_transfer_outstanding(outstanding_cents, operation) do
    if operation["amount_cents"] <= outstanding_cents do
      :ok
    else
      {:error, rejection(operation, "transfer_exceeds_outstanding")}
    end
  end

  defp move_deposit_funding(source_group_id, destination, operation) do
    source_allocations = held_funding_allocations(source_group_id)
    destination_rooms = active_rooms(destination.group_id)

    used =
      Map.new(destination_rooms, fn room ->
        {room.room_id, room.cash_paid_cents + room.credit_paid_cents}
      end)

    {remaining, _used} =
      Enum.reduce_while(source_allocations, {operation["amount_cents"], used}, fn allocation,
                                                                                  {remaining,
                                                                                   used} ->
        amount = min(remaining, allocation.amount_cents)
        used = move_funding_allocation(allocation, amount, destination, destination_rooms, used)
        remaining = remaining - amount

        if remaining == 0,
          do: {:halt, {remaining, used}},
          else: {:cont, {remaining, used}}
      end)

    if remaining == 0,
      do: :ok,
      else: {:error, rejection(operation, "transfer_exceeds_held_funding")}
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == @room_active,
        order_by: room.position
    )
  end

  defp held_funding_allocations(group_id) do
    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.disposition == @held and
              room.status == @room_active,
          order_by: allocation.id
      )
      |> Enum.map(fn allocation ->
        %{
          kind: :cash,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          allocation_sequence: allocation.allocation_sequence || 0,
          allocation_id: allocation.id
        }
      end)

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.status == "active" and
              room.status == @room_active,
          order_by: allocation.id
      )
      |> Enum.map(fn allocation ->
        %{
          kind: :credit,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          allocation_sequence: allocation.allocation_sequence || 0,
          allocation_id: allocation.id
        }
      end)

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(
      fn allocation ->
        {allocation.allocation_sequence, allocation.allocation_id,
         if(allocation.kind == :cash, do: 0, else: 1)}
      end,
      :desc
    )
  end

  defp move_funding_allocation(_allocation, 0, _destination, _rooms, used), do: used

  defp move_funding_allocation(allocation, amount, destination, rooms, used) do
    {used, remaining} =
      Enum.reduce_while(rooms, {used, amount}, fn room, {used, remaining} ->
        capacity = room.deposit_due_cents - Map.get(used, room.room_id, 0)
        moved = min(max(capacity, 0), remaining)

        if moved > 0 do
          insert_moved_funding(allocation, destination, room, moved)
          used = Map.update!(used, room.room_id, &(&1 + moved))
          remaining = remaining - moved

          if remaining == 0,
            do: {:halt, {used, remaining}},
            else: {:cont, {used, remaining}}
        else
          {:cont, {used, remaining}}
        end
      end)

    if remaining > 0, do: raise("transfer destination accounting overflow")
    remove_source_funding(allocation, amount)
    used
  end

  defp insert_moved_funding(%{kind: :cash, allocation: allocation}, destination, room, amount) do
    insert_cash_allocation!(%{
      group_id: destination.group_id,
      room_id: room.room_id,
      payment_operation_id: allocation.payment_operation_id,
      amount_cents: amount,
      disposition: @held,
      transferred: true
    })
  end

  defp insert_moved_funding(%{kind: :credit, allocation: allocation}, destination, room, amount) do
    insert_credit_allocation!(%{
      group_id: destination.group_id,
      credit_lot_id: allocation.credit_lot_id,
      amount_cents: amount,
      room_id: room.room_id,
      operation_id: allocation.operation_id,
      status: "active"
    })
  end

  defp remove_source_funding(%{kind: :cash, allocation: allocation}, amount) do
    remove_allocation_amount(allocation, amount)
  end

  defp remove_source_funding(%{kind: :credit, allocation: allocation}, amount) do
    remove_allocation_amount(allocation, amount)
  end

  defp remove_allocation_amount(allocation, amount) do
    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end
  end

  defp existing_group(operation) do
    group_id = Map.get(operation, "group_id")

    cond do
      not valid_identifier?(group_id) ->
        {:error, rejection(operation, "invalid_operation")}

      true ->
        case Repo.get(Group, group_id) do
          nil -> {:error, rejection(operation, "group_not_found")}
          group -> {:ok, ensure_room_accounting!(group)}
        end
    end
  end

  defp check_expected_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       rejection(operation, "stale_revision", %{
         "group_id" => group.group_id,
         "expected_revision" => operation["expected_revision"],
         "actual_revision" => group.revision
       })}
    else
      :ok
    end
  end

  defp maybe_check_expected_revision(nil, _operation), do: :ok

  defp maybe_check_expected_revision(group, operation),
    do: check_expected_revision(group, operation)

  defp validate_active(%Group{status: @active_status}, _operation), do: :ok
  defp validate_active(_group, operation), do: {:error, rejection(operation, "group_not_active")}

  defp validate_occurred_on(operation) do
    case parse_date(Map.get(operation, "occurred_on"), "invalid_operation", operation) do
      {:ok, _date} -> :ok
      error -> error
    end
  end

  defp validate_amount(amount, _operation) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_amount, operation), do: {:error, rejection(operation, "invalid_amount")}

  defp validate_payment_amount(group, amount, operation) do
    if amount <= outstanding_deposit(group) do
      :ok
    else
      {:error, rejection(operation, "payment_exceeds_outstanding")}
    end
  end

  defp validate_rescheduled_arrival(new_arrival_on, occurred_on, operation) do
    case parse_date(occurred_on, "invalid_stay", operation) do
      {:ok, occurred_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          :ok
        else
          {:error, rejection(operation, "invalid_stay")}
        end

      error ->
        error
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _method -> {:error, rejection(operation, "invalid_refund_method")}
    end
  end

  defp validate_refund_method_available(group, "hotel_credit", occurred_on, operation) do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, rejection(operation, "refund_method_not_available")}
    end
  end

  defp validate_refund_method_available(_group, "cash", _occurred_on, _operation), do: :ok

  defp selected_active_rooms(group_id, room_ids, operation) when is_list(room_ids) do
    if room_ids == [] or Enum.uniq(room_ids) != room_ids or
         Enum.any?(room_ids, &(not valid_identifier?(&1))) do
      {:error, rejection(operation, "invalid_rooms")}
    else
      rooms =
        Repo.all(from room in Room, where: room.group_id == ^group_id, order_by: room.position)

      selected = Enum.filter(rooms, &(&1.room_id in room_ids))

      if length(selected) != length(room_ids) or Enum.any?(selected, &(&1.status != @room_active)) do
        {:error, rejection(operation, "invalid_rooms")}
      else
        {:ok, selected}
      end
    end
  end

  defp selected_active_rooms(_group_id, _room_ids, operation),
    do: {:error, rejection(operation, "invalid_rooms")}

  defp active_rooms_for_group(group_id) do
    {:ok,
     Repo.all(
       from room in Room,
         where: room.group_id == ^group_id and room.status == @room_active,
         order_by: room.position
     )}
  end

  defp settle_selected_rooms(group, selected_rooms, occurred_on, refund_method, operation) do
    refundable = refundable?(group, occurred_on)
    room_ids = Enum.map(selected_rooms, & &1.room_id)

    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.group_id == ^group.group_id and allocation.room_id in ^room_ids and
              allocation.disposition == @held,
          order_by: [asc: allocation.id]
      )

    cash_amount = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    cash_disposition = cash_disposition(refundable, refund_method)

    Enum.each(cash_allocations, fn allocation ->
      allocation
      |> Ecto.Changeset.change(disposition: cash_disposition)
      |> Repo.update!()
    end)

    credit_allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where:
            allocation.group_id == ^group.group_id and allocation.room_id in ^room_ids and
              allocation.status == "active",
          order_by: [asc: allocation.id]
      )

    Enum.each(credit_allocations, fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable do
        restore_credit_to_lot!(lot, allocation.amount_cents, occurred_on)
        update_credit_allocation_status!(allocation, "restored")
      else
        update_credit_allocation_status!(allocation, "consumed")
      end
    end)

    credit_issued_cents =
      if refundable and refund_method == "hotel_credit" do
        issue_credit_lot(group, occurred_on, operation, cash_allocations)
      else
        0
      end

    Enum.each(selected_rooms, fn room ->
      room
      |> Ecto.Changeset.change(status: @room_cancelled)
      |> Repo.update!()
    end)

    all_rooms_cancelled =
      not Repo.exists?(
        from room in Room, where: room.group_id == ^group.group_id and room.status == @room_active
      )

    updated_group = sync_group_totals!(group.group_id)

    attrs =
      %{
        status: if(all_rooms_cancelled, do: @cancelled_status, else: @active_status),
        cash_refunded_cents:
          updated_group.cash_refunded_cents +
            if(cash_disposition == "refunded", do: cash_amount, else: 0),
        cash_retained_cents:
          updated_group.cash_retained_cents +
            if(cash_disposition == "retained", do: cash_amount, else: 0)
      }

    with {:ok, incremented_group} <- increment_group(updated_group, attrs, operation) do
      {:ok, incremented_group,
       %{
         refunded_cents: if(cash_disposition == "refunded", do: cash_amount, else: 0),
         retained_cents: if(cash_disposition == "retained", do: cash_amount, else: 0),
         credit_issued_cents: credit_issued_cents
       }}
    end
  end

  defp cash_disposition(true, "cash"), do: "refunded"
  defp cash_disposition(true, "hotel_credit"), do: "converted"
  defp cash_disposition(false, _refund_method), do: "retained"

  defp reduce_cash_payment(operation) do
    with {:ok, target} <- find_target_operation(operation),
         {:ok, group} <- target_group(target, operation),
         :ok <- maybe_check_expected_revision(group, operation),
         :ok <- validate_amount(operation["amount_cents"], operation),
         :ok <- validate_cash_payment_target(target, "payment_not_reducible", operation),
         held_cents <- held_cash_for_payment(target.operation_id),
         :ok <- validate_reduction_available(held_cents, operation),
         {:ok, changed_group_ids} <-
           remove_held_cash(target.operation_id, operation["amount_cents"], @reduced),
         {:ok, updated_groups} <-
           sync_and_increment_groups([group.group_id | changed_group_ids], operation),
         updated_group <- Map.fetch!(updated_groups, group.group_id) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "payment_operation_id" => target.operation_id,
         "group_id" => group.group_id,
         "amount_cents" => operation["amount_cents"],
         "outstanding_deposit_cents" => outstanding_deposit(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, target} <- find_target_operation(operation),
         {:ok, group} <- target_group(target, operation),
         :ok <- maybe_check_expected_revision(group, operation),
         :ok <- validate_cash_payment_target(target, "payment_not_chargeable", operation),
         chargeable_cents <- chargeable_cash_for_payment(target.operation_id),
         :ok <- validate_chargeable(chargeable_cents, operation),
         {:ok, changed_group_ids} <- move_payment_cash_to_chargeback(target.operation_id),
         :ok <- revoke_payment_credit_entitlements(target.operation_id),
         {:ok, updated_groups} <-
           sync_and_increment_groups([group.group_id | changed_group_ids], operation),
         updated_group <- Map.fetch!(updated_groups, group.group_id) do
      {:ok,
       %{
         "operation_id" => operation["operation_id"],
         "status" => "applied",
         "payment_operation_id" => target.operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => chargeable_cents,
         "outstanding_deposit_cents" => outstanding_deposit(updated_group),
         "revision" => updated_group.revision
       }}
    end
  end

  defp find_target_operation(operation) do
    payment_operation_id = operation["payment_operation_id"]

    if valid_identifier?(payment_operation_id) do
      case Repo.get_by(Operation, operation_id: payment_operation_id) do
        nil -> {:error, rejection(operation, "operation_not_found")}
        target -> {:ok, target}
      end
    else
      {:error, rejection(operation, "operation_not_found")}
    end
  end

  defp target_group(%Operation{} = target, operation) do
    payload = Jason.decode!(target.payload_json)
    result = Jason.decode!(target.result_json)
    group_id = result["group_id"] || payload["group_id"]

    if valid_identifier?(group_id) do
      case Repo.get(Group, group_id) do
        nil -> {:error, rejection(operation, "group_not_found", %{"group_id" => group_id})}
        group -> {:ok, ensure_room_accounting!(group)}
      end
    else
      {:error, rejection(operation, "payment_not_reducible")}
    end
  end

  defp validate_cash_payment_target(%Operation{} = target, code, operation) do
    result = Jason.decode!(target.result_json)

    if target.operation_type == "record_cash_payment" and result["status"] == "applied" do
      :ok
    else
      {:error, rejection(operation, code)}
    end
  end

  defp held_cash_for_payment(payment_operation_id) do
    Repo.one(
      from allocation in CashAllocation,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.disposition == @held,
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp chargeable_cash_for_payment(payment_operation_id) do
    Repo.one(
      from allocation in CashAllocation,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.disposition in [@held, "refunded", "retained", "converted"],
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp validate_reduction_available(0, operation),
    do: {:error, rejection(operation, "payment_not_reducible")}

  defp validate_reduction_available(held_cents, operation) do
    if operation["amount_cents"] <= held_cents do
      :ok
    else
      {:error, rejection(operation, "reduction_exceeds_held_cash")}
    end
  end

  defp validate_chargeable(0, operation),
    do: {:error, rejection(operation, "payment_not_chargeable")}

  defp validate_chargeable(_chargeable_cents, _operation), do: :ok

  defp remove_held_cash(payment_operation_id, amount_cents, disposition) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              allocation.disposition == @held,
          order_by: [desc: allocation.id]
      )

    {remaining, changed_group_ids} =
      Enum.reduce_while(allocations, {amount_cents, MapSet.new()}, fn allocation,
                                                                      {remaining,
                                                                       changed_group_ids} ->
        removed = min(remaining, allocation.amount_cents)

        if removed == allocation.amount_cents do
          allocation
          |> Ecto.Changeset.change(disposition: disposition)
          |> Repo.update!()
        else
          allocation
          |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - removed)
          |> Repo.update!()

          insert_cash_allocation!(%{
            group_id: allocation.group_id,
            room_id: allocation.room_id,
            payment_operation_id: allocation.payment_operation_id,
            amount_cents: removed,
            disposition: disposition,
            transferred: allocation.transferred
          })
        end

        remaining = remaining - removed
        changed_group_ids = MapSet.put(changed_group_ids, allocation.group_id)

        if remaining == 0,
          do: {:halt, {remaining, changed_group_ids}},
          else: {:cont, {remaining, changed_group_ids}}
      end)

    if remaining == 0,
      do: {:ok, MapSet.to_list(changed_group_ids)},
      else: {:error, :not_enough_cash}
  end

  defp move_payment_cash_to_chargeback(payment_operation_id) do
    allocations =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              allocation.disposition in [@held, "refunded", "retained", "converted"]
      )

    changed_group_ids =
      allocations
      |> Enum.filter(&(&1.disposition == @held))
      |> Enum.map(& &1.group_id)
      |> MapSet.new()

    Enum.each(allocations, fn allocation ->
      allocation
      |> Ecto.Changeset.change(disposition: @charged_back)
      |> Repo.update!()
    end)

    {:ok, MapSet.to_list(changed_group_ids)}
  end

  defp revoke_payment_credit_entitlements(payment_operation_id) do
    Repo.all(
      from entitlement in CreditEntitlement,
        where: entitlement.payment_operation_id == ^payment_operation_id,
        order_by: [asc: entitlement.id]
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.credit_amount_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          (lot.unrecovered_clawback_cents || 0) + entitlement.credit_amount_cents - removed
      )
      |> Repo.update!()
    end)

    :ok
  end

  defp allocate_cash(group, amount_cents, operation_id) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id and room.status == @room_active,
          order_by: room.position
      )

    {remaining, _} =
      Enum.reduce_while(rooms, {amount_cents, :ok}, fn room, {remaining, :ok} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        allocation_amount = min(max(capacity, 0), remaining)

        if allocation_amount > 0 do
          insert_cash_allocation!(%{
            group_id: group.group_id,
            room_id: room.room_id,
            payment_operation_id: operation_id,
            amount_cents: allocation_amount,
            disposition: @held
          })
        end

        remaining = remaining - allocation_amount
        if remaining == 0, do: {:halt, {remaining, :ok}}, else: {:cont, {remaining, :ok}}
      end)

    if remaining == 0,
      do: :ok,
      else: {:error, rejection(%{"operation_id" => operation_id}, "payment_exceeds_outstanding")}
  end

  defp allocate_credit(group, amount_cents, occurred_on, operation) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id and room.status == @room_active,
          order_by: room.position
      )

    {demands, remaining} =
      Enum.reduce_while(rooms, {[], amount_cents}, fn room, {demands, remaining} ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(max(capacity, 0), remaining)

        if amount == 0 do
          {:cont, {demands, remaining}}
        else
          remaining = remaining - amount

          if remaining == 0 do
            {:halt, {[{room.room_id, amount} | demands], remaining}}
          else
            {:cont, {[{room.room_id, amount} | demands], remaining}}
          end
        end
      end)

    demands = Enum.reverse(demands)
    lots = available_credit_lots(group.guest_id, occurred_on)

    if remaining != 0 or Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      {:error, rejection(operation, "insufficient_credit")}
    else
      specs = credit_allocation_specs(demands, lots, [])

      Enum.each(specs, fn %{lot: lot, room_id: room_id, amount_cents: amount} ->
        update_credit_lot!(lot, lot.remaining_cents - amount)

        insert_credit_allocation!(%{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: amount,
          room_id: room_id,
          operation_id: operation["operation_id"],
          status: "active"
        })
      end)

      :ok
    end
  end

  defp credit_allocation_specs([], _lots, specs), do: Enum.reverse(specs)

  defp credit_allocation_specs([{room_id, room_amount} | demands], lots, specs) do
    {new_lots, specs} = consume_credit_for_room(room_id, room_amount, lots, specs)
    credit_allocation_specs(demands, new_lots, specs)
  end

  defp consume_credit_for_room(_room_id, 0, lots, specs), do: {lots, specs}

  defp consume_credit_for_room(room_id, room_amount, [%CreditLot{} = lot | lots], specs) do
    amount = min(room_amount, lot.remaining_cents)
    specs = [%{lot: lot, room_id: room_id, amount_cents: amount} | specs]
    remaining_room_amount = room_amount - amount
    remaining_lot = %{lot | remaining_cents: lot.remaining_cents - amount}
    remaining_lots = if remaining_lot.remaining_cents > 0, do: [remaining_lot | lots], else: lots

    if remaining_room_amount == 0 do
      {remaining_lots, specs}
    else
      consume_credit_for_room(room_id, remaining_room_amount, remaining_lots, specs)
    end
  end

  defp issue_credit_lot(group, occurred_on, operation, cash_allocations) do
    cash_amount = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))
    amount = cash_amount + percentage_amount(cash_amount, 10)

    if amount > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: operation["operation_id"],
          remaining_cents: amount,
          expires_on: Date.add(occurred_on, 366),
          cash_converted_cents: cash_amount,
          issued_on: occurred_on,
          unrecovered_clawback_cents: 0
        })

      cash_allocations
      |> cash_contributors()
      |> add_credit_entitlements(lot.id)
    end

    amount
  end

  defp cash_contributors(cash_allocations) do
    {contributors, _seen} =
      Enum.reduce(cash_allocations, {[], %{}}, fn allocation, {contributors, seen} ->
        key = allocation.payment_operation_id

        case Map.fetch(seen, key) do
          {:ok, index} ->
            {List.update_at(contributors, index, fn {id, amount} ->
               {id, amount + allocation.amount_cents}
             end), seen}

          :error ->
            {contributors ++ [{key, allocation.amount_cents}],
             Map.put(seen, key, length(contributors))}
        end
      end)

    contributors
  end

  defp add_credit_entitlements(contributors, lot_id) do
    Enum.reduce(contributors, {0, 0}, fn {payment_operation_id, cash_amount},
                                         {prior_cash, prior_value} ->
      current_cash = prior_cash + cash_amount
      current_value = current_cash + percentage_amount(current_cash, 10)
      credit_amount = current_value - prior_value

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot_id,
        payment_operation_id: payment_operation_id,
        cash_amount_cents: cash_amount,
        credit_amount_cents: credit_amount
      })

      {current_cash, current_value}
    end)

    :ok
  end

  defp restore_credit_to_lot!(lot, amount_cents, occurred_on) do
    unrecovered_clawback = lot.unrecovered_clawback_cents || 0
    absorbed = min(unrecovered_clawback, amount_cents)
    unrecovered = unrecovered_clawback - absorbed
    excess = amount_cents - absorbed

    available =
      if excess > 0 and credit_available_on?(lot.expires_on, occurred_on), do: excess, else: 0

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents + available,
      unrecovered_clawback_cents: unrecovered
    )
    |> Repo.update!()
  end

  defp update_credit_allocation_status!(allocation, status) do
    allocation
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^as_of and
            lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp credit_available_on?(expires_on, on), do: Date.compare(expires_on, on) == :gt

  defp update_credit_lot!(lot, remaining_cents) do
    lot
    |> Ecto.Changeset.change(remaining_cents: remaining_cents)
    |> Repo.update!()
  end

  defp insert_cash_allocation!(attrs) do
    attrs =
      if transfer_columns_available?() do
        attrs
        |> Map.put_new(:transferred, false)
        |> Map.put_new(:allocation_sequence, next_allocation_sequence!())
      else
        attrs
      end

    %CashAllocation{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  defp insert_credit_allocation!(attrs) do
    attrs =
      if transfer_columns_available?() do
        Map.put_new(attrs, :allocation_sequence, next_allocation_sequence!())
      else
        attrs
      end

    %CreditAllocation{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  defp transfer_columns_available? do
    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, "PRAGMA table_info(cash_allocations)")
    Enum.any?(rows, fn [_cid, name | _rest] -> name == "transferred" end)
  end

  defp next_allocation_sequence! do
    cash_max =
      Repo.one(from allocation in CashAllocation, select: max(allocation.allocation_sequence))

    credit_max =
      Repo.one(from allocation in CreditAllocation, select: max(allocation.allocation_sequence))

    max(cash_max || 0, credit_max || 0) + 1
  end

  defp allocation_order_key(:cash, allocation, operation_order) do
    allocation_order_key(allocation.payment_operation_id, allocation.id, 0, operation_order)
  end

  defp allocation_order_key(:credit, allocation, operation_order) do
    allocation_order_key(allocation.operation_id, allocation.id, 1, operation_order)
  end

  defp allocation_order_key(nil, row_id, kind, _operation_order), do: {0, 0, kind, row_id}

  defp allocation_order_key(operation_id, row_id, kind, operation_order) do
    {1, Map.get(operation_order, operation_id, 0), kind, row_id}
  end

  defp increment_group(group, attrs, operation) do
    changes =
      attrs
      |> Map.put(:revision, group.revision + 1)
      |> then(&Ecto.Changeset.change(group, &1))

    case Repo.update(changes) do
      {:ok, updated_group} -> {:ok, updated_group}
      {:error, _changeset} -> {:error, rejection(operation, "invalid_operation")}
    end
  end

  defp sync_and_increment_groups(group_ids, operation) do
    Enum.reduce_while(Enum.uniq(group_ids), {:ok, %{}}, fn group_id, {:ok, groups} ->
      group = sync_group_totals!(group_id)

      case increment_group(group, %{}, operation) do
        {:ok, updated_group} ->
          {:cont, {:ok, Map.put(groups, group_id, updated_group)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp ensure_group_does_not_exist(group_id, operation) do
    if Repo.exists?(from group in Group, where: group.group_id == ^group_id) do
      {:error, rejection(operation, "group_already_exists")}
    else
      :ok
    end
  end

  defp validate_open_identifiers(operation) do
    if valid_identifier?(Map.get(operation, "guest_id")) and
         valid_identifier?(Map.get(operation, "property_id")) do
      :ok
    else
      {:error, rejection(operation, "invalid_operation")}
    end
  end

  defp validate_rate_plan(rate_plan, _operation) when rate_plan in @valid_rate_plans, do: :ok

  defp validate_rate_plan(_rate_plan, operation),
    do: {:error, rejection(operation, "invalid_rate_plan")}

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on, operation) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, rejection(operation, "invalid_stay")}
    end
  end

  defp normalize_rooms(rooms, arrival_on, departure_on, operation) when is_list(rooms) do
    if rooms == [] do
      {:error, rejection(operation, "invalid_rooms")}
    else
      nights = Date.diff(departure_on, arrival_on)

      Enum.reduce_while(Enum.with_index(rooms), {:ok, [], MapSet.new()}, fn
        {room, position}, {:ok, normalized, seen_ids} when is_map(room) ->
          room_id = Map.get(room, "room_id")
          nightly_rate_cents = Map.get(room, "nightly_rate_cents")

          cond do
            not valid_identifier?(room_id) ->
              {:halt, {:error, rejection(operation, "invalid_rooms")}}

            MapSet.member?(seen_ids, room_id) ->
              {:halt, {:error, rejection(operation, "invalid_rooms")}}

            not (is_integer(nightly_rate_cents) and nightly_rate_cents > 0) ->
              {:halt, {:error, rejection(operation, "invalid_rooms")}}

            true ->
              room_data = %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                lodging_amount_cents: nights * nightly_rate_cents
              }

              {:cont, {:ok, [room_data | normalized], MapSet.put(seen_ids, room_id)}}
          end

        {_room, _position}, _acc ->
          {:halt, {:error, rejection(operation, "invalid_rooms")}}
      end)
      |> case do
        {:ok, normalized, _seen_ids} -> {:ok, Enum.reverse(normalized)}
        error -> error
      end
    end
  end

  defp normalize_rooms(_rooms, _arrival_on, _departure_on, operation),
    do: {:error, rejection(operation, "invalid_rooms")}

  defp insert_group(operation, booked_on, arrival_on, departure_on, rooms) do
    rate_plan = operation["rate_plan"]
    policy_version = policy_for(rate_plan, booked_on)
    lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_amount_cents))

    deposit_due_cents =
      Enum.sum(Enum.map(rooms, &deposit_for(&1.lodging_amount_cents, rate_plan)))

    group_attrs = %{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      policy_version: policy_version,
      status: @active_status,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      revision: 1,
      room_accounting_initialized: true
    }

    case Repo.insert(struct(Group, group_attrs)) do
      {:ok, group} ->
        Enum.each(rooms, fn room ->
          Repo.insert!(%Room{
            group_id: group.group_id,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            position: room.position,
            lodging_amount_cents: room.lodging_amount_cents,
            deposit_due_cents: deposit_for(room.lodging_amount_cents, rate_plan),
            status: @room_active,
            cash_paid_cents: 0,
            credit_paid_cents: 0
          })
        end)

        {:ok, group}

      {:error, _changeset} ->
        {:error, rejection(operation, "group_already_exists")}
    end
  end

  defp deposit_for(lodging_amount_cents, "flexible"),
    do: percentage_amount(lodging_amount_cents, 20)

  defp deposit_for(lodging_amount_cents, "advance_purchase"), do: lodging_amount_cents
  defp percentage_amount(amount, percentage), do: div(amount * percentage + 50, 100)

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp effective_policy_version(%Group{
         policy_version: nil,
         rate_plan: rate_plan,
         booked_on: booked_on
       }),
       do: policy_for(rate_plan, booked_on)

  defp effective_policy_version(%Group{policy_version: policy_version}), do: policy_version
  defp policy_window("flex-14"), do: 14
  defp policy_window("flex-30"), do: 30
  defp policy_window(_policy_version), do: nil

  defp refundable?(group, occurred_on) do
    case policy_window(effective_policy_version(group)) do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp refundable_until(group) do
    case policy_window(effective_policy_version(group)) do
      nil -> nil
      window -> group.arrival_on |> Date.add(-window) |> Date.to_iso8601()
    end
  end

  defp parse_date(value, error_code, operation) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, rejection(operation, error_code)}
    end
  end

  defp parse_date(_value, error_code, operation), do: {:error, rejection(operation, error_code)}
  defp valid_operation_id?(operation), do: valid_identifier?(Map.get(operation, "operation_id"))

  defp require_identifier(operation, field) do
    if valid_identifier?(Map.get(operation, field)),
      do: :ok,
      else: {:error, rejection(operation, "invalid_operation")}
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp outstanding_deposit(%Group{status: @active_status} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding_deposit(_group), do: 0

  defp sync_group_totals!(group_id) do
    rooms =
      Repo.all(from room in Room, where: room.group_id == ^group_id, order_by: room.position)

    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(
        cash_paid_cents: room_cash_paid(room),
        credit_paid_cents: room_credit_paid(room)
      )
      |> Repo.update!()
    end)

    active_rooms = Enum.filter(rooms, &(&1.status == @room_active))
    lodging_total = Enum.sum(Enum.map(active_rooms, & &1.lodging_amount_cents))
    deposit_due = Enum.sum(Enum.map(active_rooms, & &1.deposit_due_cents))
    cash_paid = Enum.sum(Enum.map(active_rooms, &room_cash_paid(&1)))
    credit_paid = Enum.sum(Enum.map(active_rooms, &room_credit_paid(&1)))
    group = Repo.get!(Group, group_id)

    group
    |> Ecto.Changeset.change(
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: cash_paid + credit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid
    )
    |> Repo.update!()
  end

  defp room_cash_paid(%Room{status: @room_active} = room) do
    Repo.one(
      from allocation in CashAllocation,
        where:
          allocation.group_id == ^room.group_id and allocation.room_id == ^room.room_id and
            allocation.disposition == @held,
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp room_cash_paid(%Room{} = room) do
    Repo.one(
      from allocation in CashAllocation,
        where:
          allocation.group_id == ^room.group_id and allocation.room_id == ^room.room_id and
            allocation.disposition != @reduced,
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp room_credit_paid(%Room{status: @room_active} = room) do
    Repo.one(
      from allocation in CreditAllocation,
        where:
          allocation.group_id == ^room.group_id and allocation.room_id == ^room.room_id and
            allocation.status == "active",
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp room_credit_paid(%Room{} = room) do
    Repo.one(
      from allocation in CreditAllocation,
        where: allocation.group_id == ^room.group_id and allocation.room_id == ^room.room_id,
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room, where: room.group_id == ^group.group_id, order_by: room.position
      )
      |> Enum.map(fn room ->
        %{
          "room_id" => room.room_id,
          "nightly_rate_cents" => room.nightly_rate_cents,
          "status" => room.status,
          "lodging_amount_cents" => room.lodging_amount_cents,
          "deposit_due_cents" => room.deposit_due_cents,
          "cash_paid_cents" => room.cash_paid_cents,
          "credit_paid_cents" => room.credit_paid_cents
        }
      end)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => effective_policy_version(group),
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "rooms" => rooms,
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group),
      "revision" => group.revision
    }
  end

  defp ensure_room_accounting!(%Group{room_accounting_initialized: true} = group), do: group

  defp ensure_room_accounting!(%Group{} = group) do
    if current_room_allocations?(group.group_id) do
      preserve_current_room_accounting!(group)
    else
      rebuild_room_accounting!(group)
    end
  end

  defp current_room_allocations?(group_id) do
    Repo.exists?(from allocation in CashAllocation, where: allocation.group_id == ^group_id) or
      Repo.exists?(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group_id and not is_nil(allocation.room_id)
      )
  end

  defp preserve_current_room_accounting!(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Repo.all(from room in Room, where: room.group_id == ^group.group_id, order_by: room.position)
    |> Enum.each(fn room ->
      room
      |> Ecto.Changeset.change(
        lodging_amount_cents: nights * room.nightly_rate_cents,
        deposit_due_cents: deposit_for(nights * room.nightly_rate_cents, group.rate_plan),
        status:
          if(room.status in [@room_active, @room_cancelled],
            do: room.status,
            else: if(group.status == @cancelled_status, do: @room_cancelled, else: @room_active)
          )
      )
      |> Repo.update!()
    end)

    group
    |> Ecto.Changeset.change(room_accounting_initialized: true)
    |> Repo.update!()
    |> then(&sync_group_totals!(&1.group_id))
  end

  defp rebuild_room_accounting!(group) do
    rooms =
      Repo.all(
        from room in Room, where: room.group_id == ^group.group_id, order_by: room.position
      )

    nights = Date.diff(group.departure_on, group.arrival_on)

    rooms =
      Enum.map(rooms, fn room ->
        lodging_amount = nights * room.nightly_rate_cents
        deposit_due = deposit_for(lodging_amount, group.rate_plan)
        status = if group.status == @cancelled_status, do: @room_cancelled, else: @room_active

        room
        |> Ecto.Changeset.change(
          lodging_amount_cents: lodging_amount,
          deposit_due_cents: deposit_due,
          status: status,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        )
        |> Repo.update!()
      end)

    cash_total = group.cash_paid_cents || group.deposit_paid_cents || 0
    durable_operations = durable_funding_operations(group.group_id)

    durable_cash =
      durable_operations
      |> Enum.filter(&(&1.type == "record_cash_payment"))
      |> Enum.sum_by(& &1.amount_cents)

    durable_credit =
      durable_operations
      |> Enum.filter(&(&1.type == "apply_hotel_credit"))
      |> Enum.sum_by(& &1.amount_cents)

    if durable_cash > cash_total, do: raise("durable cash exceeds recorded cash")

    legacy_cash = max(cash_total - durable_cash, 0)
    cash_buckets = legacy_cash_buckets(group, cash_total)
    used = Map.new(rooms, &{&1.room_id, 0})

    {used, cash_buckets} =
      allocate_cash_block_v2(group, rooms, legacy_cash, nil, cash_buckets, used)

    credit_rows =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id,
          order_by: [asc: allocation.id],
          select: %{
            credit_lot_id: allocation.credit_lot_id,
            amount_cents: allocation.amount_cents,
            status: allocation.status
          }
      )

    credit_source_total = Enum.sum(Enum.map(credit_rows, & &1.amount_cents))

    if group.status == @active_status and credit_source_total < durable_credit,
      do: raise("durable credit exceeds recorded credit")

    legacy_credit = max(credit_source_total - durable_credit, 0)

    credit_blocks =
      [{nil, legacy_credit}] ++
        Enum.map(durable_operations, fn operation ->
          {operation.operation_id,
           if(operation.type == "apply_hotel_credit", do: operation.amount_cents, else: 0)}
        end)

    {credit_segments, _remaining_credit_rows} = split_credit_rows_v2(credit_rows, credit_blocks)

    Repo.delete_all(
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id
    )

    used =
      allocate_credit_segments_v2(
        group,
        rooms,
        Enum.filter(credit_segments, &is_nil(&1.operation_id)),
        used
      )

    {used, _cash_buckets} =
      Enum.reduce(durable_operations, {used, cash_buckets}, fn operation, {used, buckets} ->
        if operation.type == "record_cash_payment" do
          allocate_cash_block_v2(
            group,
            rooms,
            operation.amount_cents,
            operation.operation_id,
            buckets,
            used
          )
        else
          operation_segments =
            Enum.filter(credit_segments, &(&1.operation_id == operation.operation_id))

          {allocate_credit_segments_v2(group, rooms, operation_segments, used), buckets}
        end
      end)

    _ = used
    backfill_legacy_credit_entitlements!(group)

    group =
      group
      |> Ecto.Changeset.change(room_accounting_initialized: true)
      |> Repo.update!()

    sync_group_totals!(group.group_id)
  end

  defp durable_funding_operations(group_id) do
    Repo.all(from operation in Operation, order_by: [asc: operation.id])
    |> Enum.flat_map(fn operation ->
      payload = Jason.decode!(operation.payload_json)
      result = Jason.decode!(operation.result_json)

      if operation.operation_type in ["record_cash_payment", "apply_hotel_credit"] and
           result["status"] == "applied" and result["group_id"] == group_id do
        [
          %{
            operation_id: operation.operation_id,
            type: operation.operation_type,
            amount_cents: result["amount_cents"] || payload["amount_cents"] || 0
          }
        ]
      else
        []
      end
    end)
  end

  defp legacy_cash_buckets(%Group{status: @active_status}, cash_total),
    do: %{"held" => cash_total}

  defp legacy_cash_buckets(group, cash_total) do
    refunded = min(group.cash_refunded_cents || 0, cash_total)
    retained = min(group.cash_retained_cents || 0, cash_total - refunded)

    %{
      "refunded" => refunded,
      "retained" => retained,
      "converted" => max(cash_total - refunded - retained, 0)
    }
  end

  defp allocate_cash_block_v2(_group, _rooms, 0, _payment_operation_id, buckets, used),
    do: {used, buckets}

  defp allocate_cash_block_v2(group, rooms, amount, payment_operation_id, buckets, used) do
    Enum.reduce_while(rooms, {used, buckets, amount}, fn room, {used, buckets, remaining} ->
      capacity = room.deposit_due_cents - Map.get(used, room.room_id, 0)
      take = min(max(capacity, 0), remaining)

      {buckets, _remaining_room} =
        insert_cash_parts_v2(group, room, take, payment_operation_id, buckets)

      used = Map.update!(used, room.room_id, &(&1 + take))
      remaining = remaining - take

      if remaining == 0,
        do: {:halt, {used, buckets, remaining}},
        else: {:cont, {used, buckets, remaining}}
    end)
    |> then(fn {used, buckets, remaining} ->
      if remaining > 0, do: raise("room accounting cash exceeds room deposits")
      {used, buckets}
    end)
  end

  defp insert_cash_parts_v2(_group, _room, 0, _payment_operation_id, buckets), do: {buckets, 0}

  defp insert_cash_parts_v2(group, room, amount, payment_operation_id, buckets) do
    {disposition, available} =
      case Enum.find_value(["held", "refunded", "retained", "converted"], fn disposition ->
             case Map.get(buckets, disposition, 0) do
               value when value > 0 -> {disposition, value}
               _ -> nil
             end
           end) do
        nil -> raise("room accounting cash remainder has no disposition")
        value -> value
      end

    take = min(amount, available)

    insert_cash_allocation!(%{
      group_id: group.group_id,
      room_id: room.room_id,
      payment_operation_id: payment_operation_id,
      amount_cents: take,
      disposition: disposition
    })

    buckets = Map.update(buckets, disposition, 0, &max(&1 - take, 0))
    remaining = amount - take

    if remaining == 0 do
      {buckets, 0}
    else
      insert_cash_parts_v2(group, room, remaining, payment_operation_id, buckets)
    end
  end

  defp split_credit_rows_v2(rows, blocks), do: split_credit_rows_v2(rows, blocks, [])

  defp split_credit_rows_v2(rows, [], segments), do: {segments, rows}

  defp split_credit_rows_v2(rows, [{operation_id, amount} | blocks], segments) do
    {rows, new_segments} = consume_credit_rows_v2(rows, amount, operation_id, [])
    split_credit_rows_v2(rows, blocks, segments ++ Enum.reverse(new_segments))
  end

  defp consume_credit_rows_v2(rows, 0, _operation_id, segments), do: {rows, segments}
  defp consume_credit_rows_v2([], _amount, _operation_id, segments), do: {[], segments}

  defp consume_credit_rows_v2([row | rows], amount, operation_id, segments) do
    take = min(row.amount_cents, amount)

    segments = [
      %{
        credit_lot_id: row.credit_lot_id,
        amount_cents: take,
        operation_id: operation_id,
        status: row.status || "active"
      }
      | segments
    ]

    if take == row.amount_cents do
      consume_credit_rows_v2(rows, amount - take, operation_id, segments)
    else
      {[Map.put(row, :amount_cents, row.amount_cents - take) | rows], segments}
    end
  end

  defp allocate_credit_segments_v2(_group, _rooms, [], used), do: used

  defp allocate_credit_segments_v2(group, rooms, [segment | segments], used) do
    {used, remaining} =
      Enum.reduce_while(rooms, {used, segment.amount_cents}, fn room, {used, remaining} ->
        capacity = room.deposit_due_cents - Map.get(used, room.room_id, 0)
        take = min(max(capacity, 0), remaining)

        if take > 0 do
          insert_credit_allocation!(%{
            group_id: group.group_id,
            credit_lot_id: segment.credit_lot_id,
            amount_cents: take,
            room_id: room.room_id,
            operation_id: segment.operation_id,
            status: segment.status
          })
        end

        used = Map.update!(used, room.room_id, &(&1 + take))
        remaining = remaining - take

        if remaining == 0,
          do: {:halt, {used, remaining}},
          else: {:cont, {used, remaining}}
      end)

    if remaining > 0, do: raise("room accounting credit exceeds room deposits")
    allocate_credit_segments_v2(group, rooms, segments, used)
  end

  defp backfill_legacy_credit_entitlements!(group) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^group.guest_id and lot.cash_converted_cents > 0,
          order_by: [asc: lot.id]
      )
      |> Enum.filter(&legacy_lot_for_group?(&1, group))

    converted_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group.group_id and allocation.disposition == "converted",
          order_by: [asc: allocation.id],
          select: %{
            group_id: allocation.group_id,
            room_id: allocation.room_id,
            payment_operation_id: allocation.payment_operation_id,
            amount_cents: allocation.amount_cents,
            disposition: allocation.disposition
          }
      )

    Enum.reduce(lots, converted_allocations, fn lot, allocations ->
      already_backfilled? =
        Repo.exists?(
          from entitlement in CreditEntitlement, where: entitlement.credit_lot_id == ^lot.id
        )

      if already_backfilled? do
        allocations
      else
        {selected, remaining} = take_cash_allocations(allocations, lot.cash_converted_cents, [])

        if selected != [] do
          if Enum.sum(Enum.map(selected, & &1.amount_cents)) < lot.cash_converted_cents,
            do: raise("legacy credit entitlement exceeds converted cash")

          selected
          |> cash_contributors()
          |> add_credit_entitlements(lot.id)
        else
          raise("legacy credit entitlement has no converted cash allocation")
        end

        remaining
      end
    end)

    :ok
  end

  defp legacy_lot_for_group?(lot, group) do
    case Repo.get_by(Operation, operation_id: lot.source_operation_id) do
      %Operation{operation_type: "cancel_group", payload_json: payload_json} ->
        Jason.decode!(payload_json)["group_id"] == group.group_id

      _operation ->
        false
    end
  end

  defp take_cash_allocations([], _amount, selected), do: {Enum.reverse(selected), []}

  defp take_cash_allocations(allocations, 0, selected),
    do: {Enum.reverse(selected), allocations}

  defp take_cash_allocations([allocation | allocations], amount, selected) do
    take = min(allocation.amount_cents, amount)
    selected_allocation = %{allocation | amount_cents: take}
    remaining_amount = amount - take

    if take == allocation.amount_cents do
      take_cash_allocations(allocations, remaining_amount, [selected_allocation | selected])
    else
      remaining_allocation = %{allocation | amount_cents: allocation.amount_cents - take}

      take_cash_allocations([remaining_allocation | allocations], remaining_amount, [
        selected_allocation | selected
      ])
    end
  end

  defp rejection(operation, code, extra \\ %{}) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    %{
      "operation_id" => operation_id,
      "status" => "rejected",
      "code" => code
    }
    |> Map.merge(extra)
  end
end
