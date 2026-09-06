defmodule GroupStay.Operations do
  @moduledoc """
  Applies the operations of a partner batch, in order, and builds the outcome
  reported for each one.

  Each operation is applied within its own transaction together with its
  idempotency record, so a rejected operation leaves domain state unchanged
  while its rejection is durably remembered, and processing continues with
  the next operation.

  Ordering rules shared by every operation addressed to an existing group:

    * group existence is resolved first (`group_not_found`);
    * an `expected_revision` mismatch is rejected next (`stale_revision`);
    * an inactive group is rejected after that (`group_not_active`);
    * only then are the operation's own domain rules evaluated.

  Operations that address a group through a payment identifier — reductions
  and chargebacks — resolve the group from the original payment and follow
  the same revision contract. Rejected operations never increment the
  group's revision. Every applied operation addressed to an existing group
  increments the revision exactly once, even when it does not change the
  group's visible booking fields.

  Cancellation policy versions are fixed when a group is opened: a flexible
  group booked before 2027-01-01 keeps a 14-day cancellation window, one
  booked on or after 2027-01-01 uses a 30-day window, and advance purchase
  remains non-refundable. A refundable cancellation settles the cash portion
  as a cash refund, or as hotel credit worth 110% of that cash when
  `refund_method` is `hotel_credit`. Credit applied to a group is redeemed
  into its deposit and restored to its original lots on a refundable
  cancellation.

  Room-level accounting attributes every unit of funding to the active room
  it fills, in the rooms' original order. Cancelling rooms settles only their
  allocations; reducing a payment removes its held cash in reverse fill
  order; a chargeback reverses all cash of one durably recorded payment
  except any portion already recorded as reduced, reclassifying its settled
  history and revoking the credit entitlement its conversion created.

  A deposit transfer moves held funding between two active groups of the
  same guest without moving money through a provider: it withdraws from the
  source's active rooms in reverse allocation order, fills the destination's
  active rooms in their original order preserving draw order, and settles,
  revalues, and changes no ledger total. Reductions and chargebacks follow a
  payment's allocations wherever they currently fund rooms, across all
  groups. An applied operation increments the revision of every group whose
  state it changes, and always the group it is addressed to.

  Every operation carrying a partner `operation_id` is durably idempotent.
  The first operation received for an identifier is processed normally and
  remembered together with its result; the idempotency record and the domain
  changes commit in the same database transaction. A later operation with
  the same identifier and an equivalent payload (JSON object key order is not
  significant) returns the exact original result without reading or changing
  current domain state, while a different payload is rejected with
  `operation_id_conflict` and never replaces the original record. A handled
  rejection leaves domain state unchanged but commits its idempotency record.
  An unexpected exception rolls back the current operation, is not
  remembered, and aborts the whole batch.

  A `start_finance_reporting` operation durably starts the daily finance
  report: it addresses no group, guards no revision, and its applied result
  contains only the operation id, the status, and `starts_on`. The first
  applied start fixes the opening position on `starts_on`; a different start
  operation is rejected with `reporting_already_started`. Operations
  processed after reporting starts record their finance movements at the
  later of their `occurred_on` and `starts_on`, so a later submission can
  change an earlier open report. Rejected operations leave no reporting
  movement, and a durable retry never reports one twice.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Allocations
  alias GroupStay.Credits
  alias GroupStay.Credits.CreditLot
  alias GroupStay.Finance
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  @operation_types ~w(
    open_group
    record_cash_payment
    reschedule_group
    cancel_group
    apply_hotel_credit
    cancel_rooms
    reduce_cash_payment
    charge_back_payment
    transfer_deposit
    start_finance_reporting
  )

  @group_addressed_types ~w(
    open_group
    record_cash_payment
    reschedule_group
    cancel_group
    apply_hotel_credit
    cancel_rooms
  )

  @payment_addressed_types ~w(reduce_cash_payment charge_back_payment)

  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)
  @flexible_deposit_percent 20
  @max_commit_attempts 5

  @doc """
  Runs every operation in the batch, in array order, and returns one result
  per operation in the same order. An operation observes the changes made by
  earlier operations in the same batch.
  """
  @spec run([map()]) :: [map()]
  def run(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Fetches the result durably remembered for an operation identifier, or
  `:error` when no operation was ever committed under it.
  """
  @spec fetch_result(String.t()) :: {:ok, map()} | :error
  def fetch_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      %OperationRecord{result: result} -> {:ok, result}
      nil -> :error
    end
  end

  @doc """
  Reconciles one durably recorded, applied cash payment: the current
  disposition of its cash across held, refunded, retained, converted,
  reduced, and charged-back cents. Reading a statement never changes state.
  """
  @spec fetch_payment_statement(String.t()) ::
          {:ok, map()} | {:error, :operation_not_found | :payment_not_reconcilable}
  def fetch_payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %OperationRecord{} = record ->
        if payment_record?(record) do
          {:ok, payment_statement(record)}
        else
          {:error, :payment_not_reconcilable}
        end
    end
  end

  # Once any funding of a cash payment has participated in a deposit
  # transfer, its statement also reports the cash still held per group; its
  # dispositions are read from that payment's allocation rows across every
  # group its funding currently occupies.
  defp payment_statement(%OperationRecord{funding_transferred: true} = record) do
    recorded_cents = record.payload["amount_cents"]

    disposition = Allocations.payment_disposition_across_groups(record.operation_id)

    %{
      "payment_operation_id" => record.operation_id,
      "original_group_id" => record.payload["group_id"],
      "recorded_cents" => recorded_cents,
      "held_cents" => disposition.held,
      "refunded_cents" => disposition.refunded,
      "retained_cents" => disposition.retained,
      "converted_to_credit_cents" => disposition.converted,
      "reduced_cents" => disposition.reduced,
      "charged_back_cents" => disposition.charged_back,
      "held_by_group" => Allocations.held_cash_by_group(record.operation_id)
    }
  end

  defp payment_statement(%OperationRecord{} = record) do
    recorded_cents = record.payload["amount_cents"]
    {:ok, group} = Groups.fetch_group(record.payload["group_id"])

    disposition = Allocations.payment_disposition(group, record.operation_id, recorded_cents)

    %{
      "payment_operation_id" => record.operation_id,
      "original_group_id" => record.payload["group_id"],
      "recorded_cents" => recorded_cents,
      "held_cents" => disposition.held,
      "refunded_cents" => disposition.refunded,
      "retained_cents" => disposition.retained,
      "converted_to_credit_cents" => disposition.converted,
      "reduced_cents" => disposition.reduced,
      "charged_back_cents" => disposition.charged_back
    }
  end

  # Durable idempotency. The first operation received for an operation_id is
  # processed normally and remembered; a later operation with the same
  # identifier returns the exact original result when its payload is
  # equivalent, and is rejected with operation_id_conflict otherwise.
  # Operations that cannot be identified by a string operation_id are simply
  # processed and not remembered.
  defp apply_operation(operation) when is_map(operation) do
    case operation["operation_id"] do
      operation_id when is_binary(operation_id) ->
        remember_operation(operation_id, operation)

      _ ->
        process(operation)
    end
  end

  defp apply_operation(operation), do: process(operation)

  defp remember_operation(operation_id, operation) do
    case commit_operation(operation_id, operation, 0) do
      {:ok, result} -> result
      {:error, :operation_id_conflict} -> reject(operation, "operation_id_conflict")
    end
  end

  # The idempotency record and the domain changes of an operation commit in
  # the same database transaction. Concurrent retries of one identifier race
  # on the unique operation_id index, so the loser rolls back its own domain
  # changes and commits nothing, then re-reads the winner's record: the
  # effects of the operation are applied at most once.
  defp commit_operation(operation_id, operation, attempt) when attempt < @max_commit_attempts do
    Repo.transaction(fn ->
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        nil ->
          remember_first_operation(operation_id, operation)

        %OperationRecord{} = record ->
          if record.payload == operation do
            record.result
          else
            Repo.rollback(:operation_id_conflict)
          end
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, :operation_id_conflict} ->
        {:error, :operation_id_conflict}

      {:error, :operation_id_taken} ->
        commit_operation(operation_id, operation, attempt + 1)
    end
  end

  defp commit_operation(operation_id, _operation, _attempt) do
    raise "operation record for #{operation_id} could not be committed after #{@max_commit_attempts} attempts"
  end

  # Processes the first operation received for its identifier and stores the
  # audit record of the submission together with its outcome. An unexpected
  # exception propagates: it rolls the transaction back and is not remembered.
  defp remember_first_operation(operation_id, operation) do
    result = process(operation)

    %OperationRecord{}
    |> change(%{
      operation_id: operation_id,
      type: operation_type(operation),
      payload: operation,
      result: result
    })
    |> unique_constraint(:operation_id)
    |> Repo.insert()
    |> case do
      {:ok, _record} ->
        result

      {:error, %Ecto.Changeset{errors: errors}} = failure ->
        if unique_operation_id_error?(errors) do
          # A concurrent retry committed this identifier first.
          Repo.rollback(:operation_id_taken)
        else
          raise "operation #{operation_id} could not be remembered: #{inspect(failure)}"
        end
    end
  end

  defp operation_type(operation) do
    case operation["type"] do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp unique_operation_id_error?(errors) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} when is_list(opts) ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  defp process(operation) when is_map(operation) do
    case identify(operation) do
      {:ok, ctx} -> dispatch(ctx)
      {:error, code} -> reject(operation, code)
    end
  end

  defp process(operation) do
    reject(operation, "invalid_operation")
  end

  # Identification: the common fields every operation needs, then the
  # identifier through which the operation addresses the domain — a group_id
  # for group-addressed operations, a payment_operation_id for payment
  # corrections.
  defp identify(operation) do
    with {:ok, operation_id} <- identify_string(operation["operation_id"]),
         {:ok, type} <- identify_type(operation["type"]),
         {:ok, occurred_on} <- identify_date(operation["occurred_on"]) do
      ctx = %{
        operation: operation,
        operation_id: operation_id,
        type: type,
        occurred_on: occurred_on
      }

      identify_target(type, operation, ctx)
    end
  end

  defp identify_target(type, operation, ctx) when type in @group_addressed_types do
    case identify_string(operation["group_id"]) do
      {:ok, group_id} -> {:ok, Map.put(ctx, :group_id, group_id)}
      {:error, _} -> {:error, "invalid_operation"}
    end
  end

  # Starting finance reporting addresses no group and guards no revision.
  defp identify_target("start_finance_reporting", _operation, ctx), do: {:ok, ctx}

  defp identify_target(type, operation, ctx) when type in @payment_addressed_types do
    case identify_string(operation["payment_operation_id"]) do
      {:ok, payment_operation_id} ->
        {:ok, Map.put(ctx, :payment_operation_id, payment_operation_id)}

      {:error, _} ->
        {:error, "invalid_operation"}
    end
  end

  defp identify_target("transfer_deposit", operation, ctx) do
    with {:ok, source_group_id} <- identify_string(operation["source_group_id"]),
         {:ok, destination_group_id} <- identify_string(operation["destination_group_id"]) do
      {:ok,
       ctx
       |> Map.put(:source_group_id, source_group_id)
       |> Map.put(:destination_group_id, destination_group_id)}
    else
      {:error, _} -> {:error, "invalid_operation"}
    end
  end

  defp identify_string(value) when is_binary(value), do: {:ok, value}
  defp identify_string(_), do: {:error, "invalid_operation"}

  defp identify_type(type) when type in @operation_types, do: {:ok, type}
  defp identify_type(_), do: {:error, "invalid_operation"}

  defp identify_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_operation"}
    end
  end

  defp identify_date(_), do: {:error, "invalid_operation"}

  defp dispatch(%{type: "open_group"} = ctx), do: open_group(ctx)
  defp dispatch(%{type: "record_cash_payment"} = ctx), do: record_cash_payment(ctx)
  defp dispatch(%{type: "reschedule_group"} = ctx), do: reschedule_group(ctx)
  defp dispatch(%{type: "cancel_group"} = ctx), do: cancel_group(ctx)
  defp dispatch(%{type: "apply_hotel_credit"} = ctx), do: apply_hotel_credit(ctx)
  defp dispatch(%{type: "cancel_rooms"} = ctx), do: cancel_rooms(ctx)
  defp dispatch(%{type: "reduce_cash_payment"} = ctx), do: reduce_cash_payment(ctx)
  defp dispatch(%{type: "charge_back_payment"} = ctx), do: charge_back_payment(ctx)
  defp dispatch(%{type: "transfer_deposit"} = ctx), do: transfer_deposit(ctx)
  defp dispatch(%{type: "start_finance_reporting"} = ctx), do: start_finance_reporting(ctx)

  ## start_finance_reporting

  # The first applied start operation durably starts finance reporting: the
  # financial state immediately before it is processed becomes the opening
  # position on starts_on. Operations committed earlier — including in the
  # same batch before it — are part of that opening position; operations
  # processed after it report their movements.
  defp start_finance_reporting(ctx) do
    operation = ctx.operation

    with {:ok, starts_on} <- parse_reporting_date(operation["starts_on"]),
         :ok <- ensure_reporting_not_started() do
      Finance.start_reporting(ctx.operation_id, starts_on)

      applied(ctx, %{"starts_on" => Date.to_iso8601(starts_on)})
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp parse_reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_reporting_date"}
    end
  end

  defp parse_reporting_date(_), do: {:error, "invalid_reporting_date"}

  defp ensure_reporting_not_started do
    if Finance.started?() do
      {:error, "reporting_already_started"}
    else
      :ok
    end
  end

  ## open_group

  defp open_group(ctx) do
    operation = ctx.operation

    with :ok <- require_group_absent(ctx.group_id),
         {:ok, guest_id} <- require_string(operation["guest_id"]),
         {:ok, property_id} <- require_string(operation["property_id"]),
         {:ok, arrival_on} <- stay_date(operation["arrival_on"]),
         {:ok, departure_on} <- stay_date(operation["departure_on"]),
         :ok <- ensure_at_least_one_night(arrival_on, departure_on),
         {:ok, rooms} <- parse_rooms(operation["rooms"]),
         {:ok, rate_plan} <- parse_rate_plan(operation["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)

      lodging_total_cents = nights * Enum.sum(Enum.map(rooms, & &1.nightly_rate_cents))

      rooms =
        Enum.map(rooms, fn room ->
          %{
            room
            | status: "active",
              deposit_due_cents: room_deposit_cents(room, nights, rate_plan)
          }
        end)

      deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

      group =
        %Group{}
        |> change(%{
          group_id: ctx.group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: ctx.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          credit_paid_cents: 0,
          converted_to_credit_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0,
          allocations_initialized: true
        })
        |> put_assoc(:rooms, rooms)
        |> Repo.insert!()

      applied(ctx, %{
        "group_id" => group.group_id,
        "deposit_due_cents" => group.deposit_due_cents,
        "revision" => group.revision
      })
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp require_group_absent(group_id) do
    if Groups.group_exists?(group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp require_string(value) when is_binary(value), do: {:ok, value}
  defp require_string(_), do: {:error, "invalid_operation"}

  # Dates that are present but unusable are stay problems; the stay rules are
  # evaluated as domain validation.
  defp stay_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_stay"}
    end
  end

  defp stay_date(_), do: {:error, "invalid_stay"}

  defp ensure_at_least_one_night(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp parse_rooms(value) when is_list(value) do
    case Enum.reduce_while(value, {:ok, []}, fn raw, {:ok, acc} ->
           case parse_room(raw, length(acc)) do
             {:ok, room} -> {:cont, {:ok, [room | acc]}}
             :error -> {:halt, :error}
           end
         end) do
      {:ok, rooms} ->
        rooms = Enum.reverse(rooms)
        room_ids = Enum.map(rooms, & &1.room_id)

        cond do
          rooms == [] -> {:error, "invalid_rooms"}
          room_ids != Enum.uniq(room_ids) -> {:error, "invalid_rooms"}
          true -> {:ok, rooms}
        end

      :error ->
        {:error, "invalid_rooms"}
    end
  end

  defp parse_rooms(_), do: {:error, "invalid_rooms"}

  defp parse_room(raw, position) when is_map(raw) do
    room_id = raw["room_id"]
    nightly_rate_cents = raw["nightly_rate_cents"]

    if is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents >= 0 do
      {:ok, %Room{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
    else
      :error
    end
  end

  defp parse_room(_, _), do: :error

  defp parse_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp parse_rate_plan(_), do: {:error, "invalid_rate_plan"}

  # The deposit of each room is calculated and rounded separately, then the
  # room deposits are summed for the group.
  defp room_deposit_cents(room, nights, "flexible") do
    lodging_cents = room.nightly_rate_cents * nights
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp room_deposit_cents(room, nights, "advance_purchase") do
    room.nightly_rate_cents * nights
  end

  # Rounds numerator / denominator to the nearest cent; an exact half-cent
  # rounds upward. Integer arithmetic keeps the rounding exact.
  defp round_half_up(numerator, denominator) do
    div(2 * numerator + denominator, 2 * denominator)
  end

  ## record_cash_payment

  defp record_cash_payment(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_amount(operation["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      outstanding_cents = Groups.outstanding_deposit_cents(group)

      Allocations.materialize_if_needed(group)
      rooms = Groups.active_rooms(group)

      Allocations.allocate(group, rooms, [
        %{
          kind: "cash",
          source_operation_id: ctx.operation_id,
          credit_lot_id: nil,
          amount_cents: amount_cents
        }
      ])

      group
      |> change(%{
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

      Finance.record(ctx.occurred_on, [
        %{property_id: group.property_id, classification: "received", amount_cents: amount_cents}
      ])

      applied(ctx, %{
        "group_id" => group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => outstanding_cents - amount_cents,
        "revision" => group.revision + 1
      })
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  defp parse_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp parse_amount(_), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  ## reschedule_group

  defp reschedule_group(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- stay_date(operation["new_arrival_on"]),
         :ok <- ensure_after_operation_date(new_arrival_on, ctx.occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)

      updated_group =
        group
        |> change(%{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(ctx, %{
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival_on),
        "new_departure_on" => Date.to_iso8601(new_departure_on),
        "policy_version" => Groups.policy_version(updated_group),
        "refundable_until" => updated_group |> Groups.refundable_until() |> iso_date(),
        "revision" => updated_group.revision
      })
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  defp ensure_after_operation_date(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_amount(operation["amount_cents"]),
         :ok <- ensure_credit_available(group, amount_cents, ctx.occurred_on),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      outstanding_cents = Groups.outstanding_deposit_cents(group)

      Allocations.materialize_if_needed(group)

      consumptions = Credits.consume_for_group(group, amount_cents, ctx.occurred_on)
      rooms = Groups.active_rooms(group)

      Allocations.allocate(
        group,
        rooms,
        Enum.map(consumptions, fn consumption ->
          %{
            kind: "credit",
            source_operation_id: ctx.operation_id,
            credit_lot_id: consumption.lot_id,
            amount_cents: consumption.amount_cents
          }
        end)
      )

      group
      |> change(%{
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        credit_paid_cents: group.credit_paid_cents + amount_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

      applied(ctx, %{
        "group_id" => group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => outstanding_cents - amount_cents,
        "revision" => group.revision + 1
      })
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  defp ensure_credit_available(group, amount_cents, occurred_on) do
    if Credits.available_cents(group.guest_id, occurred_on) >= amount_cents do
      :ok
    else
      {:error, "insufficient_credit"}
    end
  end

  ## cancel_group and cancel_rooms

  defp cancel_group(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- parse_refund_method(operation["refund_method"]) do
      cond do
        Groups.refundable?(group, ctx.occurred_on) ->
          full_cancellation(ctx, group, refund_method)

        refund_method == "hotel_credit" ->
          # Hotel credit is not a way around a non-refundable policy.
          reject(operation, "refund_method_not_available")

        true ->
          full_cancellation(ctx, group, "cash")
      end
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  # A full cancellation settles the remaining active rooms — rooms already
  # cancelled by an earlier room-level cancellation were settled then — and
  # otherwise follows the cancellation contract.
  defp full_cancellation(ctx, group, refund_method) do
    Allocations.materialize_if_needed(group)
    rooms = Groups.active_rooms(group)
    settlement = settle_rooms(ctx, group, rooms, refund_method)

    cancel_room_rows(rooms)

    group
    |> change(%{
      status: "cancelled",
      deposit_due_cents: 0,
      deposit_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: group.refunded_cents + settlement.refunded_cents,
      retained_cents: group.retained_cents + settlement.retained_cents,
      converted_to_credit_cents: group.converted_to_credit_cents + settlement.converted_cents,
      revision: group.revision + 1
    })
    |> Repo.update!()

    applied(ctx, %{
      "group_id" => group.group_id,
      "refunded_cents" => settlement.refunded_cents,
      "retained_cents" => settlement.retained_cents,
      "credit_issued_cents" => settlement.credit_issued_cents,
      "revision" => group.revision + 1
    })
  end

  defp cancel_rooms(ctx) do
    operation = ctx.operation

    with {:ok, group} <- fetch_group(ctx.group_id),
         :ok <- check_expected_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- parse_refund_method(operation["refund_method"]),
         {:ok, rooms} <- parse_room_selection(group, operation["room_ids"]) do
      cond do
        Groups.refundable?(group, ctx.occurred_on) ->
          cancel_selected_rooms(ctx, group, rooms, refund_method)

        refund_method == "hotel_credit" ->
          reject(operation, "refund_method_not_available")

        true ->
          cancel_selected_rooms(ctx, group, rooms, "cash")
      end
    else
      {:error, code} -> reject(operation, code)
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  # All supplied room identifiers must identify distinct, active rooms in
  # the group; otherwise the complete operation is rejected.
  defp parse_room_selection(group, room_ids) when is_list(room_ids) do
    rooms = Groups.rooms_for_group(group)

    active_by_room_id =
      Map.new(rooms, fn room -> {room.room_id, room} end)

    cond do
      room_ids == [] ->
        {:error, "invalid_rooms"}

      Enum.any?(room_ids, &(not is_binary(&1))) ->
        {:error, "invalid_rooms"}

      Enum.uniq(room_ids) != room_ids ->
        {:error, "invalid_rooms"}

      Enum.any?(room_ids, fn room_id ->
        case Map.fetch(active_by_room_id, room_id) do
          {:ok, %Room{status: "active"}} -> false
          _ -> true
        end
      end) ->
        {:error, "invalid_rooms"}

      true ->
        {:ok,
         room_ids |> Enum.map(&Map.fetch!(active_by_room_id, &1)) |> Enum.sort_by(& &1.position)}
    end
  end

  defp parse_room_selection(_group, _room_ids), do: {:error, "invalid_rooms"}

  defp cancel_selected_rooms(ctx, group, rooms, refund_method) do
    Allocations.materialize_if_needed(group)
    settlement = settle_rooms(ctx, group, rooms, refund_method)

    cancel_room_rows(rooms)

    selected_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

    remaining_active =
      group
      |> Groups.rooms_for_group()
      |> Enum.count(&(&1.status == "active"))

    group
    |> change(%{
      status: if(remaining_active == 0, do: "cancelled", else: group.status),
      deposit_due_cents: group.deposit_due_cents - selected_due_cents,
      deposit_paid_cents:
        group.deposit_paid_cents - settlement.cash_total_cents - settlement.credit_total_cents,
      credit_paid_cents: group.credit_paid_cents - settlement.credit_total_cents,
      refunded_cents: group.refunded_cents + settlement.refunded_cents,
      retained_cents: group.retained_cents + settlement.retained_cents,
      converted_to_credit_cents: group.converted_to_credit_cents + settlement.converted_cents,
      revision: group.revision + 1
    })
    |> Repo.update!()

    applied(ctx, %{
      "group_id" => group.group_id,
      "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
      "refunded_cents" => settlement.refunded_cents,
      "retained_cents" => settlement.retained_cents,
      "credit_issued_cents" => settlement.credit_issued_cents,
      "revision" => group.revision + 1
    })
  end

  defp cancel_room_rows(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(%{status: "cancelled"})
      |> Repo.update!()
    end)
  end

  # Omitting refund_method means cash, preserving existing callers.
  defp parse_refund_method(nil), do: {:ok, "cash"}

  defp parse_refund_method(refund_method) when refund_method in @refund_methods,
    do: {:ok, refund_method}

  defp parse_refund_method(_), do: {:error, "invalid_operation"}

  # Settles the allocated cash and credit of the given rooms using the same
  # date, policy, refund method, bonus, and restoration rules as a full
  # cancellation. The hotel-credit bonus is computed once on the rooms'
  # combined cash amount. Other rooms and their allocations are unchanged.
  defp settle_rooms(ctx, group, rooms, refund_method) do
    rows = Allocations.held_rows_for_rooms(group, rooms)
    cash_rows = Enum.filter(rows, &(&1.kind == "cash"))
    credit_rows = Enum.filter(rows, &(&1.kind == "credit"))

    cash_total_cents = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    credit_total_cents = Enum.sum(Enum.map(credit_rows, & &1.amount_cents))

    credit_by_lot =
      credit_rows
      |> Enum.group_by(& &1.credit_lot_id)
      |> Enum.map(fn {lot_id, lot_rows} ->
        {Repo.get!(CreditLot, lot_id), Enum.sum(Enum.map(lot_rows, & &1.amount_cents))}
      end)

    refundable = Groups.refundable?(group, ctx.occurred_on)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      cond do
        refundable and refund_method == "hotel_credit" and cash_total_cents > 0 ->
          lot =
            Credits.issue_lot(group.guest_id, ctx.operation_id, cash_total_cents, ctx.occurred_on)

          Allocations.set_state(cash_rows, "converted", lot.id)
          {0, 0, cash_total_cents, lot.remaining_cents}

        refundable and refund_method == "hotel_credit" ->
          {0, 0, 0, 0}

        refundable ->
          Allocations.set_state(cash_rows, "refunded")
          {cash_total_cents, 0, 0, 0}

        true ->
          Allocations.set_state(cash_rows, "retained")
          {0, cash_total_cents, 0, 0}
      end

    restorations =
      if refundable do
        Credits.restore_amounts(credit_by_lot, ctx.occurred_on)
      else
        []
      end

    if refundable do
      Allocations.set_state(credit_rows, "restored")
    else
      Allocations.set_state(credit_rows, "consumed")
    end

    Credits.remove_applications(group, credit_by_lot)

    record_settlement_movements(
      ctx,
      group,
      refundable,
      refund_method,
      cash_total_cents,
      credit_total_cents,
      credit_issued_cents,
      restorations
    )

    %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      converted_cents: converted_cents,
      credit_issued_cents: credit_issued_cents,
      cash_total_cents: cash_total_cents,
      credit_total_cents: credit_total_cents
    }
  end

  # The finance movements of a settlement: the cash side follows the settled
  # cash to the settling group's property; the credit side reports issued
  # lots, credit consumed by a non-refundable settlement, and restorations
  # absorbed by a shortfall or expiring immediately.
  defp record_settlement_movements(
         ctx,
         group,
         refundable,
         refund_method,
         cash_total_cents,
         credit_total_cents,
         credit_issued_cents,
         restorations
       ) do
    cash_classification =
      cond do
        refundable and refund_method == "hotel_credit" -> "converted_to_credit"
        refundable -> "refunded"
        true -> "retained"
      end

    restoration_movements =
      Enum.flat_map(restorations, fn restoration ->
        [
          %{
            property_id: nil,
            classification: "absorbed",
            amount_cents: restoration.absorbed_cents
          },
          %{property_id: nil, classification: "expired", amount_cents: restoration.expired_cents}
        ]
      end)

    movements = [
      %{
        property_id: group.property_id,
        classification: cash_classification,
        amount_cents: cash_total_cents
      },
      %{property_id: nil, classification: "issued", amount_cents: credit_issued_cents},
      %{
        property_id: nil,
        classification: "consumed",
        amount_cents: if(refundable, do: 0, else: credit_total_cents)
      }
      | restoration_movements
    ]

    Finance.record(ctx.occurred_on, movements)
  end

  ## reduce_cash_payment

  defp reduce_cash_payment(ctx) do
    operation = ctx.operation

    with {:ok, record} <- fetch_payment_record(ctx.payment_operation_id) do
      if payment_record?(record) do
        {:ok, group} = fetch_group(record.payload["group_id"])

        case check_revision_for_derived_group(operation, group) do
          :ok ->
            reduce_recorded_payment(ctx, group, record)

          {:error, code, extra} ->
            reject(operation, code, extra)
        end
      else
        # A non-payment operation or a rejected payment can never accept a
        # positive reduction.
        reject(operation, "payment_not_reducible")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp reduce_recorded_payment(ctx, group, record) do
    operation = ctx.operation
    recorded_cents = record.payload["amount_cents"]

    held_cents =
      Allocations.held_cash_for_payment(group, ctx.payment_operation_id, recorded_cents)

    cond do
      held_cents == 0 ->
        reject(operation, "payment_not_reducible", %{"group_id" => group.group_id})

      true ->
        case parse_amount(operation["amount_cents"]) do
          {:error, _} ->
            reject(operation, "invalid_amount", %{"group_id" => group.group_id})

          {:ok, amount_cents} ->
            if amount_cents > held_cents do
              reject(operation, "reduction_exceeds_held_cash", %{"group_id" => group.group_id})
            else
              apply_reduce(ctx, group, amount_cents)
            end
        end
    end
  end

  # A reduction follows the payment's allocations wherever they currently
  # fund rooms, removing held cash in reverse creation order across all
  # groups. Every group whose funding state changes increments its revision,
  # as does the addressed original payment group in any case.
  defp apply_reduce(ctx, group, amount_cents) do
    Allocations.materialize_if_needed(group)

    removed_by_group = Allocations.reduce_held(ctx.payment_operation_id, amount_cents)
    removed_in_group = Map.get(removed_by_group, group.id, 0)

    # The reduction follows the payment's held cash to the properties where it
    # is currently held, not the payment's original property.
    reduced_movements =
      Enum.map(removed_by_group, fn {affected_id, removed} ->
        affected = Repo.get!(Group, affected_id)

        affected
        |> change(%{
          deposit_paid_cents: affected.deposit_paid_cents - removed,
          cash_reduced_cents:
            if(affected.id == group.id,
              do: affected.cash_reduced_cents + amount_cents,
              else: affected.cash_reduced_cents
            ),
          revision: affected.revision + 1
        })
        |> Repo.update!()

        %{property_id: affected.property_id, classification: "reduced", amount_cents: removed}
      end)

    Finance.record(ctx.occurred_on, reduced_movements)

    unless Map.has_key?(removed_by_group, group.id) do
      group
      |> change(%{
        cash_reduced_cents: group.cash_reduced_cents + amount_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()
    end

    applied(ctx, %{
      "payment_operation_id" => ctx.payment_operation_id,
      "group_id" => group.group_id,
      "amount_cents" => amount_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group) + removed_in_group,
      "revision" => group.revision + 1
    })
  end

  ## charge_back_payment

  defp charge_back_payment(ctx) do
    operation = ctx.operation

    with {:ok, record} <- fetch_payment_record(ctx.payment_operation_id) do
      if payment_record?(record) do
        {:ok, group} = fetch_group(record.payload["group_id"])

        case check_revision_for_derived_group(operation, group) do
          :ok ->
            recorded_cents = record.payload["amount_cents"]

            if chargeable?(group, ctx.payment_operation_id, recorded_cents) do
              apply_charge_back(ctx, group, record)
            else
              reject(operation, "payment_not_chargeable", %{"group_id" => group.group_id})
            end

          {:error, code, extra} ->
            reject(operation, code, extra)
        end
      else
        reject(operation, "payment_not_chargeable")
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  # A payment is not chargeable when it has already been charged back or has
  # been fully reduced. Funding carried over from an earlier release can have
  # neither history until it is materialized.
  defp chargeable?(_group, operation_id, recorded_cents) do
    rows = Allocations.cash_rows_for_payment(operation_id)

    charged_back? = Enum.any?(rows, &(&1.state == "charged_back"))
    reduced_cents = rows |> states_sum("reduced")

    not charged_back? and reduced_cents < recorded_cents
  end

  # A chargeback follows the payment's allocations wherever they currently
  # fund rooms, reclassifying every remaining disposition across all groups.
  # Every group whose funding state changes increments its revision, as does
  # the addressed original payment group in any case.
  defp apply_charge_back(ctx, group, record) do
    Allocations.materialize_if_needed(group)

    rows = Allocations.cash_rows_for_payment(ctx.payment_operation_id)
    recorded_cents = record.payload["amount_cents"]

    held_rows = Enum.filter(rows, &(&1.state == "held"))
    refunded_rows = Enum.filter(rows, &(&1.state == "refunded"))
    retained_rows = Enum.filter(rows, &(&1.state == "retained"))
    converted_rows = Enum.filter(rows, &(&1.state == "converted"))
    reduced_cents = states_sum(rows, "reduced")

    # Revoke the credit entitlement the payment's conversions created. The
    # entitlements telescope over all contributions to each lot, so
    # contributions already charged back are still counted. A portion taken
    # from a lot that had already expired left the liability through that
    # lot's expiry and counts with it, not as a revocation.
    posting_date = Finance.posting_date(ctx.occurred_on)

    revoked_cents =
      converted_rows
      |> Enum.map(& &1.credit_lot_id)
      |> Enum.uniq()
      |> Enum.map(fn lot_id ->
        lot = Repo.get!(CreditLot, lot_id)
        entitlement_cents = payment_entitlement_for_lot(lot_id, ctx.payment_operation_id)

        Credits.revoke_entitlement(lot, entitlement_cents, posting_date).revoked_cents
      end)
      |> Enum.sum()

    Allocations.set_state(held_rows, "charged_back")
    Allocations.set_state(refunded_rows, "charged_back")
    Allocations.set_state(retained_rows, "charged_back")
    Allocations.set_state(converted_rows, "charged_back")

    charged_back_cents = recorded_cents - reduced_cents

    moved_by_group =
      (held_rows ++ refunded_rows ++ retained_rows ++ converted_rows)
      |> Enum.group_by(& &1.group_id)

    # The chargeback follows the payment's cash to the properties where it is
    # held or where it was settled; reversed refunds, retentions, and
    # conversions report negative movements together with charged-back cash.
    charge_back_movements =
      Enum.flat_map(moved_by_group, fn {affected_id, affected_rows} ->
        affected = Repo.get!(Group, affected_id)

        held = affected_rows |> states_sum("held")
        refunded = affected_rows |> states_sum("refunded")
        retained = affected_rows |> states_sum("retained")
        converted = affected_rows |> states_sum("converted")

        affected
        |> change(%{
          deposit_paid_cents: affected.deposit_paid_cents - held,
          refunded_cents: affected.refunded_cents - refunded,
          retained_cents: affected.retained_cents - retained,
          converted_to_credit_cents: affected.converted_to_credit_cents - converted,
          cash_charged_back_cents:
            if(affected.id == group.id,
              do: affected.cash_charged_back_cents + charged_back_cents,
              else: affected.cash_charged_back_cents
            ),
          revision: affected.revision + 1
        })
        |> Repo.update!()

        [
          %{
            property_id: affected.property_id,
            classification: "charged_back",
            amount_cents: held + refunded + retained + converted
          },
          %{
            property_id: affected.property_id,
            classification: "refunded",
            amount_cents: -refunded
          },
          %{
            property_id: affected.property_id,
            classification: "retained",
            amount_cents: -retained
          },
          %{
            property_id: affected.property_id,
            classification: "converted_to_credit",
            amount_cents: -converted
          }
        ]
      end)

    Finance.record(ctx.occurred_on, [
      %{property_id: nil, classification: "revoked", amount_cents: revoked_cents}
      | charge_back_movements
    ])

    unless Map.has_key?(moved_by_group, group.id) do
      group
      |> change(%{
        cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()
    end

    held_in_group =
      case Map.fetch(moved_by_group, group.id) do
        {:ok, affected_rows} -> states_sum(affected_rows, "held")
        :error -> 0
      end

    applied(ctx, %{
      "payment_operation_id" => ctx.payment_operation_id,
      "group_id" => group.group_id,
      "charged_back_cents" => charged_back_cents,
      "outstanding_deposit_cents" => Groups.outstanding_deposit_cents(group) + held_in_group,
      "revision" => group.revision + 1
    })
  end

  defp states_sum(rows, state) do
    rows
    |> Enum.filter(&(&1.state == state))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  # The entitlement of one payment within a credit lot: the standard 10%
  # bonus value of the settled cash through that payment, minus the bonus
  # value through the preceding contribution, with the standard half-up
  # rounding applied to both running totals. The entitlements telescope
  # exactly to the issued lot.
  defp payment_entitlement_for_lot(lot_id, payment_operation_id) do
    Allocations.converted_contributions_for_lot(lot_id)
    |> Enum.reduce(%{entitlement: 0, cumulative: 0, bonus: 0}, fn contribution, acc ->
      cumulative = acc.cumulative + contribution.amount_cents
      bonus = round_half_up(cumulative * 110, 100)

      entitlement =
        if contribution.source_operation_id == payment_operation_id,
          do: bonus - acc.bonus,
          else: acc.entitlement

      %{entitlement: entitlement, cumulative: cumulative, bonus: bonus}
    end)
    |> Map.fetch!(:entitlement)
  end

  ## transfer_deposit

  # Moves held funding between two active groups of the same guest without
  # moving money through a provider. Ordering: source existence, destination
  # existence, source revision, destination revision, then the transfer
  # rules — same group or different guests, either group inactive, the
  # amount, the source's held funding, the destination's outstanding deposit.
  defp transfer_deposit(ctx) do
    operation = ctx.operation

    with {:ok, source} <- fetch_group_for_transfer(ctx.source_group_id),
         {:ok, destination} <- fetch_group_for_transfer(ctx.destination_group_id),
         :ok <- check_transfer_revision(operation, source, "expected_revision"),
         :ok <- check_transfer_revision(operation, destination, "destination_expected_revision") do
      cond do
        source.id == destination.id or source.guest_id != destination.guest_id ->
          reject(operation, "invalid_transfer")

        source.status != "active" ->
          reject(operation, "group_not_active", %{"group_id" => source.group_id})

        destination.status != "active" ->
          reject(operation, "group_not_active", %{"group_id" => destination.group_id})

        true ->
          case parse_amount(operation["amount_cents"]) do
            {:error, _} ->
              reject(operation, "invalid_amount")

            {:ok, amount_cents} ->
              cond do
                amount_cents > source.deposit_paid_cents ->
                  reject(operation, "transfer_exceeds_held_funding")

                amount_cents > Groups.outstanding_deposit_cents(destination) ->
                  reject(operation, "transfer_exceeds_outstanding")

                true ->
                  apply_transfer(ctx, source, destination, amount_cents)
              end
          end
      end
    else
      {:error, code, extra} -> reject(operation, code, extra)
    end
  end

  defp fetch_group_for_transfer(group_id) do
    case Groups.fetch_group(group_id) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, "group_not_found", %{"group_id" => group_id}}
    end
  end

  # A transfer guards each group's revision separately: `expected_revision`
  # addresses the source, `destination_expected_revision` the destination.
  defp check_transfer_revision(operation, group, key) do
    case Map.fetch(operation, key) do
      :error ->
        :ok

      {:ok, expected_revision} ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, "stale_revision",
           %{
             "group_id" => group.group_id,
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end
    end
  end

  # A transfer settles and revalues nothing: it computes no credit bonus,
  # resumes no expiry, and changes no ledger total. It only changes which
  # active rooms hold the funding; every moved allocation keeps its
  # provenance.
  defp apply_transfer(ctx, source, destination, amount_cents) do
    Allocations.materialize_if_needed(source)
    Allocations.materialize_if_needed(destination)

    moved = Allocations.withdraw_held(source, amount_cents)

    Allocations.allocate(destination, Groups.active_rooms(destination), moved)

    moved
    |> Enum.filter(&(&1.kind == "cash" and is_binary(&1.source_operation_id)))
    |> Enum.map(& &1.source_operation_id)
    |> Enum.uniq()
    |> mark_funding_transferred()

    credit_by_lot =
      moved
      |> Enum.filter(&(&1.kind == "credit"))
      |> Enum.reduce([], fn unit, acc ->
        case List.keyfind(acc, unit.credit_lot_id, 0) do
          nil ->
            [{unit.credit_lot_id, unit.amount_cents} | acc]

          {lot_id, amount} ->
            List.keyreplace(acc, lot_id, 0, {lot_id, amount + unit.amount_cents})
        end
      end)

    Credits.move_applications(source, destination, credit_by_lot)

    credit_moved = credit_by_lot |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    # A transfer reports movements at both ends: out of the source group's
    # property and into the destination group's property, in equal amounts.
    Finance.record(ctx.occurred_on, [
      %{
        property_id: source.property_id,
        classification: "transferred_out",
        amount_cents: amount_cents
      },
      %{
        property_id: destination.property_id,
        classification: "transferred_in",
        amount_cents: amount_cents
      }
    ])

    source
    |> change(%{
      deposit_paid_cents: source.deposit_paid_cents - amount_cents,
      credit_paid_cents: source.credit_paid_cents - credit_moved,
      revision: source.revision + 1
    })
    |> Repo.update!()

    destination
    |> change(%{
      deposit_paid_cents: destination.deposit_paid_cents + amount_cents,
      credit_paid_cents: destination.credit_paid_cents + credit_moved,
      revision: destination.revision + 1
    })
    |> Repo.update!()

    applied(ctx, %{
      "source_group_id" => source.group_id,
      "destination_group_id" => destination.group_id,
      "amount_cents" => amount_cents,
      "source_outstanding_deposit_cents" =>
        Groups.outstanding_deposit_cents(source) + amount_cents,
      "destination_outstanding_deposit_cents" =>
        Groups.outstanding_deposit_cents(destination) - amount_cents,
      "source_revision" => source.revision + 1,
      "destination_revision" => destination.revision + 1
    })
  end

  # Once any funding of a cash payment has participated in a transfer, the
  # payment's statement reports its held cash group by group.
  defp mark_funding_transferred([]), do: :ok

  defp mark_funding_transferred(payment_operation_ids) do
    Repo.update_all(
      from(r in OperationRecord, where: r.operation_id in ^payment_operation_ids),
      set: [funding_transferred: true]
    )

    :ok
  end

  ## Shared helpers

  defp fetch_group(group_id) do
    case Groups.fetch_group(group_id) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, "group_not_found"}
    end
  end

  defp fetch_payment_record(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil -> {:error, "operation_not_found"}
      %OperationRecord{} = record -> {:ok, record}
    end
  end

  # A durable record addressing a payment correction: an applied cash
  # payment whose group can be derived from its payload.
  defp payment_record?(%OperationRecord{} = record) do
    record.type == "record_cash_payment" and record.result["status"] == "applied" and
      is_binary(record.payload["group_id"])
  end

  defp check_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected_revision} ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, "stale_revision",
           %{
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end
    end
  end

  # Operations that address a group through a payment identifier report the
  # derived group in their revision rejections.
  defp check_revision_for_derived_group(operation, group) do
    case check_expected_revision(operation, group) do
      :ok ->
        :ok

      {:error, code, extra} ->
        {:error, code, Map.put(extra, "group_id", group.group_id)}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_), do: {:error, "group_not_active"}

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp applied(ctx, fields) do
    Map.merge(%{"operation_id" => ctx.operation_id, "status" => "applied"}, fields)
  end

  defp reject(operation, code, extra \\ %{}) do
    result = %{"status" => "rejected", "code" => code}

    result =
      if is_map(operation) do
        result
        |> maybe_put("operation_id", operation["operation_id"])
        |> maybe_put("group_id", operation["group_id"])
      else
        result
      end

    Map.merge(result, extra)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
