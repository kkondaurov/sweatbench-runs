defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and reports one result per operation.

  Every operation runs in its own transaction together with its durable
  idempotency record: applied operations commit their domain changes and
  handled rejections commit nothing but the record. The first request for an
  `operation_id` is processed normally; equivalent later submissions replay the
  stored result without touching domain state, and different payloads are
  rejected with `operation_id_conflict`.

  Funding is tracked per room: every cash payment and hotel-credit application
  fills the active rooms' deposits in the rooms' original order, leaving
  allocation rows that cancellations settle, reductions remove, and
  chargebacks reclassify. Deposit transfers move those allocations between
  active groups of the same guest without changing any ledger total.
  """

  import Ecto.Query

  alias GroupStay.{CanonicalJSON, Groups, Money, Policy, Repo, Reporting}
  alias GroupStay.Credit.{CreditEntitlement, CreditLot}
  alias GroupStay.Groups.{Group, Room, RoomAllocation}
  alias GroupStay.Operations.OperationRecord

  @deposit_percent 20
  @bonus_percent 10
  @addressed_types ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms)
  @payment_derived_types ~w(reduce_cash_payment charge_back_payment)
  @refund_methods ~w(cash hotel_credit)
  @chargeable_dispositions ~w(held refunded retained converted)
  @max_record_attempts 3

  @doc """
  Applies a list of operations sequentially, returning one result per
  operation in the same order.
  """
  def apply_batch(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &apply_operation/1)}
  end

  @doc """
  Fetches the durable record for an operation identifier, or `nil`.
  """
  def get_record(operation_id) do
    Repo.get_by(OperationRecord, operation_id: operation_id)
  end

  @doc """
  Builds the reconciliation view of one durably recorded, applied cash
  payment: the current disposition of every cent it recorded. Returns
  `:not_found` when no record exists and `:not_reconcilable` when the record
  is not an applied cash payment. Reading a statement never changes state.
  """
  def reconcile_payment(payment_operation_id) do
    case get_record(payment_operation_id) do
      nil ->
        :not_found

      record ->
        result = Jason.decode!(record.result)

        if record.type == "record_cash_payment" and result["status"] == "applied" do
          dispositions =
            Repo.all(
              from a in RoomAllocation,
                where: a.kind == "cash" and a.payment_operation_id == ^payment_operation_id,
                group_by: a.disposition,
                select: {a.disposition, sum(a.amount_cents)}
            )
            |> Map.new()

          statement = %{
            payment_operation_id: payment_operation_id,
            original_group_id: result["group_id"],
            recorded_cents: result["amount_cents"],
            held_cents: Map.get(dispositions, "held", 0),
            refunded_cents: Map.get(dispositions, "refunded", 0),
            retained_cents: Map.get(dispositions, "retained", 0),
            converted_to_credit_cents: Map.get(dispositions, "converted", 0),
            reduced_cents: Map.get(dispositions, "reduced", 0),
            charged_back_cents: Map.get(dispositions, "charged_back", 0)
          }

          # Once any of the payment's cash has moved through a transfer, the
          # statement breaks its held cash down by group forever, even when
          # nothing held remains (an empty list then).
          if participated_in_transfer?(payment_operation_id) do
            {:ok, Map.put(statement, :held_by_group, held_by_group(payment_operation_id))}
          else
            {:ok, statement}
          end
        else
          :not_reconcilable
        end
    end
  end

  @doc """
  Applies a single operation. Returns a result map whose `status` is
  `"applied"` or `"rejected"`. Operations without a usable `operation_id`
  are rejected and remembered nowhere, because there is no key to store.
  """
  def apply_operation(operation) when is_map(operation) do
    case required_string(operation, "operation_id") do
      {:ok, operation_id} -> apply_idempotent(operation, operation_id)
      :error -> dispatch(operation)
    end
  end

  def apply_operation(operation) do
    reject_result(operation, "invalid_operation")
  end

  ## idempotency

  defp apply_idempotent(operation, operation_id) do
    canonical = CanonicalJSON.encode(operation)

    case get_record(operation_id) do
      nil -> process_and_record(operation, operation_id, canonical, 1)
      record -> replay_or_conflict(record, canonical, operation)
    end
  end

  defp replay_or_conflict(record, canonical, operation) do
    if record.payload == canonical do
      Jason.decode!(record.result)
    else
      reject_result(operation, "operation_id_conflict")
    end
  end

  defp process_and_record(operation, operation_id, canonical, attempt) do
    outcome =
      Repo.transaction(fn ->
        result = dispatch(operation)

        case store_record(operation_id, operation["type"], canonical, result) do
          {:ok, _record} ->
            result

          {:error, changeset} ->
            if unique_violation?(changeset) do
              Repo.rollback(:concurrent_record)
            else
              Repo.rollback({:unexpected, changeset})
            end
        end
      end)

    case outcome do
      {:ok, result} ->
        result

      {:error, :concurrent_record} ->
        # A concurrent request recorded this operation first. Replay its
        # stored result or report the payload conflict.
        case get_record(operation_id) do
          nil when attempt < @max_record_attempts ->
            process_and_record(operation, operation_id, canonical, attempt + 1)

          nil ->
            raise "operation record for #{operation_id} vanished after a conflict"

          record ->
            replay_or_conflict(record, canonical, operation)
        end

      {:error, {:unexpected, changeset}} ->
        raise "could not store the idempotency record for #{operation_id}: " <>
                inspect(changeset)
    end
  end

  defp store_record(operation_id, type, canonical, result) do
    %{
      operation_id: operation_id,
      type: type,
      payload: canonical,
      result: Jason.encode!(result)
    }
    |> OperationRecord.changeset()
    |> Repo.insert()
  end

  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {"has already been taken", _}} -> true
      _ -> false
    end)
  end

  ## dispatch

  defp dispatch(operation) when is_map(operation) do
    with {:ok, operation_id} <- required_string(operation, "operation_id"),
         {:ok, type} <- required_string(operation, "type"),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]) do
      apply_typed(operation, operation_id, type, occurred_on)
    else
      :error -> reject_result(operation, "invalid_operation")
    end
  end

  defp apply_typed(operation, operation_id, "open_group", occurred_on) do
    open_group(operation, operation_id, occurred_on)
  end

  defp apply_typed(operation, operation_id, "start_finance_reporting", _occurred_on) do
    start_finance_reporting(operation, operation_id)
  end

  defp apply_typed(operation, operation_id, "transfer_deposit", occurred_on) do
    transfer_deposit(operation, operation_id, occurred_on)
  end

  defp apply_typed(operation, operation_id, type, occurred_on)
       when type in @addressed_types do
    with_addressed_group(operation, operation_id, type, occurred_on)
  end

  defp apply_typed(operation, operation_id, type, occurred_on)
       when type in @payment_derived_types do
    with_payment_record(operation, operation_id, type, occurred_on)
  end

  defp apply_typed(operation, _operation_id, _unknown_type, _occurred_on) do
    reject_result(operation, "invalid_operation")
  end

  ## open_group

  defp open_group(operation, operation_id, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         :ok <- group_missing?(Groups.get_group(group_id)),
         {:ok, rate_plan} <- valid_rate_plan(operation["rate_plan"]),
         {:ok, arrival_on, departure_on} <- valid_stay(operation),
         {:ok, rooms} <- valid_rooms(operation["rooms"]) do
      create_group(operation, %{
        operation_id: operation_id,
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        rate_plan: rate_plan,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rooms: rooms
      })
    else
      :error -> reject_result(operation, "invalid_operation", operation_id)
      {:reject, code} -> reject_result(operation, code, operation_id)
    end
  end

  defp create_group(operation, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms_attrs =
      attrs.rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        lodging = nights * room["nightly_rate_cents"]

        deposit_due =
          case attrs.rate_plan do
            "flexible" -> Money.percent_of(lodging, @deposit_percent)
            "advance_purchase" -> lodging
          end

        %{
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"],
          status: "active",
          deposit_due_cents: deposit_due
        }
      end)

    lodging_total_cents =
      Enum.sum(for room <- attrs.rooms, do: nights * room["nightly_rate_cents"])

    deposit_due_cents = Enum.sum(Enum.map(rooms_attrs, & &1.deposit_due_cents))

    {policy_version, _window} = Policy.for_plan(attrs.rate_plan, attrs.booked_on)

    changeset =
      Group.create_changeset(%{
        group_id: attrs.group_id,
        guest_id: attrs.guest_id,
        property_id: attrs.property_id,
        rate_plan: attrs.rate_plan,
        status: "active",
        booked_on: attrs.booked_on,
        arrival_on: attrs.arrival_on,
        departure_on: attrs.departure_on,
        revision: 1,
        policy_version: policy_version,
        refundable_until: Policy.refundable_until(policy_version, attrs.arrival_on),
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0,
        rooms: rooms_attrs
      })

    case Repo.insert(changeset) do
      {:ok, group} ->
        apply_result(operation, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, _changeset} ->
        reject_result(operation, "invalid_operation", attrs.operation_id)
    end
  end

  ## start_finance_reporting

  # Enables finance reporting from `starts_on`; the financial state
  # immediately before this operation becomes the opening position. Does not
  # address a group and is never revision-guarded.
  defp start_finance_reporting(operation, operation_id) do
    case parse_date(operation["starts_on"]) do
      {:ok, starts_on} ->
        case Reporting.state() do
          nil ->
            Reporting.start_reporting(starts_on)

            apply_result(operation, %{starts_on: starts_on})

          _started ->
            reject_result(operation, "reporting_already_started", operation_id)
        end

      :error ->
        reject_result(operation, "invalid_reporting_date", operation_id)
    end
  end

  ## operations addressed to an existing group

  defp with_addressed_group(operation, operation_id, type, occurred_on) do
    with {:ok, group_id} <- required_string(operation, "group_id") do
      case Groups.get_group(group_id) do
        nil ->
          reject_result(operation, "group_not_found", operation_id)

        group ->
          case revision_ok?(operation, group) do
            :ok ->
              apply_addressed(operation, operation_id, type, occurred_on, group)

            {:error, stale} ->
              reject_result(operation, "stale_revision", operation_id, stale)
          end
      end
    else
      :error -> reject_result(operation, "invalid_operation", operation_id)
    end
  end

  ## operations deriving their group from a payment record

  defp with_payment_record(operation, operation_id, type, occurred_on) do
    with {:ok, payment_operation_id} <- required_string(operation, "payment_operation_id") do
      case get_record(payment_operation_id) do
        nil ->
          reject_result(operation, "operation_not_found", operation_id)

        record ->
          stored_result = Jason.decode!(record.result)
          not_applicable = not_applicable_code(type)

          if record.type == "record_cash_payment" and stored_result["status"] == "applied" do
            group = Groups.get_group(stored_result["group_id"])

            if group == nil do
              reject_result(operation, "group_not_found", operation_id)
            else
              case revision_ok?(operation, group) do
                :ok ->
                  apply_payment_scoped(operation, operation_id, type, occurred_on, group, record)

                {:error, stale} ->
                  reject_result(operation, "stale_revision", operation_id, stale)
              end
            end
          else
            reject_result(operation, not_applicable, operation_id)
          end
      end
    else
      :error -> reject_result(operation, "invalid_operation", operation_id)
    end
  end

  defp not_applicable_code("reduce_cash_payment"), do: "payment_not_reducible"
  defp not_applicable_code("charge_back_payment"), do: "payment_not_chargeable"

  defp revision_ok?(operation, group, key \\ "expected_revision") do
    case Map.get(operation, key) do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:error,
         %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}
    end
  end

  defp apply_addressed(operation, op_id, "record_cash_payment", occurred_on, group) do
    record_payment(operation, op_id, occurred_on, group)
  end

  defp apply_addressed(operation, op_id, "apply_hotel_credit", occurred_on, group) do
    apply_credit(operation, op_id, occurred_on, group)
  end

  defp apply_addressed(operation, op_id, "reschedule_group", occurred_on, group) do
    reschedule(operation, op_id, occurred_on, group)
  end

  defp apply_addressed(operation, op_id, "cancel_group", occurred_on, group) do
    cancel(operation, op_id, occurred_on, group)
  end

  defp apply_addressed(operation, op_id, "cancel_rooms", occurred_on, group) do
    cancel_rooms(operation, op_id, occurred_on, group)
  end

  defp apply_payment_scoped(operation, op_id, "reduce_cash_payment", occurred_on, group, record) do
    reduce_cash(operation, op_id, occurred_on, group, record)
  end

  defp apply_payment_scoped(operation, op_id, "charge_back_payment", occurred_on, group, record) do
    charge_back(operation, op_id, occurred_on, group, record)
  end

  ## transfer_deposit

  # Moves held funding between two active groups of the same guest. Source
  # existence resolves first, then destination existence, then the source
  # revision guard, then the destination guard, before any transfer rule runs.
  defp transfer_deposit(operation, operation_id, occurred_on) do
    with {:ok, source_group_id} <- required_string(operation, "source_group_id") do
      case Groups.get_group(source_group_id) do
        nil ->
          reject_result(operation, "group_not_found", operation_id, %{group_id: source_group_id})

        source ->
          transfer_destination(operation, operation_id, source, occurred_on)
      end
    else
      :error -> reject_result(operation, "invalid_operation", operation_id)
    end
  end

  defp transfer_destination(operation, operation_id, source, occurred_on) do
    with {:ok, destination_group_id} <- required_string(operation, "destination_group_id") do
      case Groups.get_group(destination_group_id) do
        nil ->
          reject_result(operation, "group_not_found", operation_id, %{
            group_id: destination_group_id
          })

        destination ->
          transfer_guards(operation, operation_id, source, destination, occurred_on)
      end
    else
      :error -> reject_result(operation, "invalid_operation", operation_id)
    end
  end

  defp transfer_guards(operation, operation_id, source, destination, occurred_on) do
    case revision_ok?(operation, source) do
      :ok ->
        case revision_ok?(operation, destination, "destination_expected_revision") do
          :ok -> apply_transfer(operation, operation_id, source, destination, occurred_on)
          {:error, stale} -> reject_result(operation, "stale_revision", operation_id, stale)
        end

      {:error, stale} ->
        reject_result(operation, "stale_revision", operation_id, stale)
    end
  end

  defp apply_transfer(operation, operation_id, source, destination, occurred_on) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        reject_result(operation, "invalid_transfer", operation_id)

      source.status != "active" ->
        reject_result(operation, "group_not_active", operation_id, %{group_id: source.group_id})

      destination.status != "active" ->
        reject_result(
          operation,
          "group_not_active",
          operation_id,
          %{group_id: destination.group_id}
        )

      not usable_amount?(operation["amount_cents"]) ->
        reject_result(operation, "invalid_amount", operation_id)

      true ->
        amount = operation["amount_cents"]

        cond do
          amount > held_funding(source) ->
            reject_result(operation, "transfer_exceeds_held_funding", operation_id)

          amount > Groups.outstanding(destination) ->
            reject_result(operation, "transfer_exceeds_outstanding", operation_id)

          true ->
            execute_transfer(operation, operation_id, source, destination, amount, occurred_on)
        end
    end
  end

  # A transfer settles or revalues nothing and changes no ledger total; it
  # only reassigns which active rooms hold the funding. Every moved
  # allocation keeps provenance: cash keeps its payment identifier, credit
  # keeps its original lot. The report records only moved cash, matching by
  # in/out totals per property.
  defp execute_transfer(operation, _operation_id, source, destination, amount, occurred_on) do
    draws = draw_units(held_units(source), amount)

    apply_transfer_draws(draws, active_rooms(destination))

    cash_events(draws, source, destination, occurred_on)

    bump_group_revision!(source)
    bump_group_revision!(destination)

    source = Repo.reload(source) |> Repo.preload(:rooms)
    destination = Repo.reload(destination) |> Repo.preload(:rooms)

    apply_result(operation, %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: Groups.outstanding(source),
      destination_outstanding_deposit_cents: Groups.outstanding(destination),
      source_revision: source.revision,
      destination_revision: destination.revision
    })
  end

  # Cash moved between the two properties exits the source and enters the
  # destination. Credit moved has no report column. Transfers are recorded
  # even when both groups sit at the one property: in and out show there.
  defp cash_events(draws, source, destination, occurred_on) do
    moved =
      draws
      |> Enum.filter(fn {allocation, _take} -> allocation.kind == "cash" end)
      |> Enum.sum_by(fn {_allocation, take} -> take end)

    Reporting.record_events(occurred_on, [
      %{
        scope: "cash",
        classification: "transferred_out",
        property_id: source.property_id,
        amount_cents: moved
      },
      %{
        scope: "cash",
        classification: "transferred_in",
        property_id: destination.property_id,
        amount_cents: moved
      }
    ])
  end

  # Every group whose state changes increments its revision, always including
  # the addressed group.
  defp bump_group_revision!(group) do
    group
    |> Group.changeset(%{revision: group.revision + 1})
    |> Repo.update!()
  end

  # All held allocations on the group's active rooms, across cash and credit,
  # in reverse allocation order: the most recently created slice first.
  defp held_units(group) do
    room_ids = Enum.map(active_rooms(group), & &1.id)

    Repo.all(
      from a in RoomAllocation,
        where: a.room_id in ^room_ids and a.disposition == "held",
        order_by: [desc: a.id]
    )
  end

  defp held_funding(group) do
    group
    |> held_units()
    |> Enum.sum_by(& &1.amount_cents)
  end

  # Draws up to `amount` from the allocations, most recent first, and
  # preserves that drawing order for the destination fill.
  defp draw_units(allocations, amount) do
    {draws, _} =
      Enum.reduce_while(allocations, {[], amount}, fn allocation, {acc, left} ->
        if left <= 0 do
          {:halt, {acc, left}}
        else
          take = min(allocation.amount_cents, left)
          {:cont, {[{allocation, take} | acc], left - take}}
        end
      end)

    Enum.reverse(draws)
  end

  defp apply_transfer_draws(draws, destination_rooms) do
    Enum.reduce(draws, destination_rooms, fn {allocation, take}, rooms ->
      fill_from_draw(rooms, allocation, take)
    end)
  end

  # One drawn unit fills the destination's active rooms in their original
  # order, splitting across rooms when the first room's remaining deposit is
  # smaller than the unit.
  defp fill_from_draw(rooms, allocation, amount) do
    Enum.map_reduce(rooms, {allocation, amount}, fn room, {alloc, left} ->
      remaining = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      take = min(remaining, left)

      if take > 0 do
        {updated_room, updated_alloc} = move_into_room(alloc, take, room)
        {updated_room, {updated_alloc, left - take}}
      else
        {room, {alloc, left}}
      end
    end)
    |> elem(0)
  end

  # Moves one unit into one destination room: decrements the source room,
  # moves (or splits) the allocation keeping provenance, and increments the
  # destination room counter. Returns both updated rooms plus the source
  # allocation remainder, so a unit spanning rooms keeps moving.
  defp move_into_room(allocation, take, destination_room) do
    source_room = Repo.get!(Room, allocation.room_id)
    adjust_room_paid!(source_room, allocation.kind, -take)

    updated_allocation =
      if take == allocation.amount_cents do
        allocation
        |> RoomAllocation.changeset(%{
          room_id: destination_room.id,
          position: destination_room.position,
          transferred: true
        })
        |> Repo.update!()
      else
        updated =
          allocation
          |> RoomAllocation.changeset(%{amount_cents: allocation.amount_cents - take})
          |> Repo.update!()

        %RoomAllocation{}
        |> RoomAllocation.changeset(%{
          room_id: destination_room.id,
          kind: allocation.kind,
          amount_cents: take,
          disposition: allocation.disposition,
          payment_operation_id: allocation.payment_operation_id,
          credit_lot_id: allocation.credit_lot_id,
          position: destination_room.position,
          transferred: true
        })
        |> Repo.insert!()

        updated
      end

    {adjust_room_paid!(destination_room, allocation.kind, take), updated_allocation}
  end

  defp adjust_room_paid!(room, kind, delta) do
    attrs =
      case kind do
        "cash" -> %{cash_paid_cents: room.cash_paid_cents + delta}
        "credit" -> %{credit_paid_cents: room.credit_paid_cents + delta}
      end

    room
    |> Room.changeset(attrs)
    |> Repo.update!()
  end

  ## record_cash_payment

  defp record_payment(operation, operation_id, occurred_on, group) do
    cond do
      group.status != "active" ->
        reject_result(operation, "group_not_active", operation_id)

      not usable_amount?(operation["amount_cents"]) ->
        reject_result(operation, "invalid_amount", operation_id)

      operation["amount_cents"] > Groups.outstanding(group) ->
        reject_result(operation, "payment_exceeds_outstanding", operation_id)

      true ->
        amount = operation["amount_cents"]

        changeset =
          Group.changeset(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            fill_rooms(active_rooms(updated), amount, "cash", operation_id, nil)
            updated = Repo.reload(updated) |> Repo.preload(:rooms)

            record_event(occurred_on, "cash", "received", amount, group.property_id)

            apply_result(operation, %{
              group_id: updated.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: Groups.outstanding(updated),
              revision: updated.revision
            })

          {:error, _changeset} ->
            reject_result(operation, "invalid_operation", operation_id)
        end
    end
  end

  # Funding fills the group's active rooms in their original order, one
  # room's deposit before the next, leaving an allocation row per slice.
  defp fill_rooms(rooms, amount, kind, source, lot_id) do
    Enum.map_reduce(rooms, amount, fn room, left ->
      remaining = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
      take = min(remaining, left)

      if take > 0 do
        insert_allocation!(room, kind, take, source, lot_id)
        {update_room_paid!(room, kind, take), left - take}
      else
        {room, left}
      end
    end)
    |> elem(0)
  end

  defp insert_allocation!(room, kind, amount, source, lot_id) do
    %RoomAllocation{}
    |> RoomAllocation.changeset(%{
      room_id: room.id,
      kind: kind,
      amount_cents: amount,
      disposition: "held",
      payment_operation_id: source,
      credit_lot_id: lot_id,
      position: room.position
    })
    |> Repo.insert!()
  end

  defp update_room_paid!(room, kind, amount) do
    attrs =
      case kind do
        "cash" -> %{cash_paid_cents: room.cash_paid_cents + amount}
        "credit" -> %{credit_paid_cents: room.credit_paid_cents + amount}
      end

    room
    |> Room.changeset(attrs)
    |> Repo.update!()
  end

  ## apply_hotel_credit

  # Splits credit application into a pure sufficiency check (which may reject
  # before anything is written) followed by the group update; the mutating
  # consumption runs only once the group update succeeded.
  defp apply_credit(operation, operation_id, occurred_on, group) do
    cond do
      group.status != "active" ->
        reject_result(operation, "group_not_active", operation_id)

      not usable_amount?(operation["amount_cents"]) ->
        reject_result(operation, "invalid_amount", operation_id)

      operation["amount_cents"] > Groups.outstanding(group) ->
        reject_result(operation, "payment_exceeds_outstanding", operation_id)

      true ->
        amount = operation["amount_cents"]

        case usable_lots(group, occurred_on, amount) do
          :insufficient_credit ->
            reject_result(operation, "insufficient_credit", operation_id)

          {:ok, lots} ->
            changeset =
              Group.changeset(group, %{
                deposit_paid_cents: group.deposit_paid_cents + amount,
                credit_paid_cents: group.credit_paid_cents + amount,
                revision: group.revision + 1
              })

            case Repo.update(changeset) do
              {:ok, updated} ->
                consume_credit_lots(updated, lots, amount)
                updated = Repo.reload(updated) |> Repo.preload(:rooms)

                apply_result(operation, %{
                  group_id: updated.group_id,
                  amount_cents: amount,
                  outstanding_deposit_cents: Groups.outstanding(updated),
                  revision: updated.revision
                })

              {:error, _changeset} ->
                reject_result(operation, "invalid_operation", operation_id)
            end
        end
    end
  end

  # Checks that the guest's unexpired lots as of `occurred_on` can cover
  # `amount`. Consumption order is earliest expiry, then
  # `source_operation_id`.
  defp usable_lots(group, occurred_on, amount) do
    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
              l.expires_on >= ^occurred_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      :insufficient_credit
    else
      {:ok, lots}
    end
  end

  # Decrements the lots and records exactly which of them funded which room,
  # so the amounts can be restored to their original lots on a refundable
  # cancellation. Unexpected failures raise, aborting the whole transaction.
  defp consume_credit_lots(group, lots, amount) do
    Enum.reduce(lots, {amount, active_rooms(group)}, fn lot, {needed, rooms} ->
      take = min(lot.remaining_cents, needed)

      if take > 0 do
        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - take})
        |> Repo.update!()

        rooms = fill_rooms(rooms, take, "credit", nil, lot.id)
        {needed - take, rooms}
      else
        {needed, rooms}
      end
    end)
  end

  ## reschedule_group

  defp reschedule(operation, operation_id, occurred_on, group) do
    with {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      if group.status == "active" do
        shift_days = Date.diff(new_arrival, group.arrival_on)
        new_departure = Date.add(group.departure_on, shift_days)
        refundable_until = Policy.refundable_until(group.policy_version, new_arrival)

        changeset =
          Group.changeset(group, %{
            arrival_on: new_arrival,
            departure_on: new_departure,
            refundable_until: refundable_until,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            apply_result(operation, %{
              group_id: updated.group_id,
              new_arrival_on: updated.arrival_on,
              new_departure_on: updated.departure_on,
              policy_version: updated.policy_version,
              refundable_until: updated.refundable_until,
              revision: updated.revision
            })

          {:error, _changeset} ->
            reject_result(operation, "invalid_operation", operation_id)
        end
      else
        reject_result(operation, "group_not_active", operation_id)
      end
    else
      _ -> reject_result(operation, "invalid_stay", operation_id)
    end
  end

  ## cancel_group and cancel_rooms

  defp cancel(operation, operation_id, occurred_on, group) do
    cond do
      group.status != "active" ->
        reject_result(operation, "group_not_active", operation_id)

      not valid_refund_method?(operation["refund_method"]) ->
        reject_result(operation, "invalid_operation", operation_id)

      true ->
        method = effective_refund_method(operation["refund_method"])
        refundable = Policy.refundable?(group, occurred_on)

        if method == "hotel_credit" and not refundable do
          reject_result(operation, "refund_method_not_available", operation_id)
        else
          settle_cancellation(
            operation,
            operation_id,
            occurred_on,
            group,
            active_rooms(group),
            method,
            refundable
          )
        end
    end
  end

  defp cancel_rooms(operation, operation_id, occurred_on, group) do
    cond do
      group.status != "active" ->
        reject_result(operation, "group_not_active", operation_id)

      not valid_refund_method?(operation["refund_method"]) ->
        reject_result(operation, "invalid_operation", operation_id)

      not valid_room_selection?(operation["room_ids"]) ->
        reject_result(operation, "invalid_rooms", operation_id)

      true ->
        method = effective_refund_method(operation["refund_method"])
        refundable = Policy.refundable?(group, occurred_on)
        selected = selected_active_rooms(group, operation["room_ids"])

        if selected == nil do
          reject_result(operation, "invalid_rooms", operation_id)
        else
          if method == "hotel_credit" and not refundable do
            reject_result(operation, "refund_method_not_available", operation_id)
          else
            settle_cancellation(
              operation,
              operation_id,
              occurred_on,
              group,
              selected,
              method,
              refundable
            )
          end
        end
    end
  end

  # `room_ids` must name distinct rooms that are present and active in the
  # group.
  defp valid_room_selection?(room_ids) when is_list(room_ids) and room_ids != [] do
    Enum.all?(room_ids, &is_binary/1) and
      length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp valid_room_selection?(_room_ids), do: false

  # Looks up the selected rooms in the group's original order. Rooms that are
  # not active members are not a valid selection and raise the caller's
  # rejection earlier; remaining lookups resolve.
  defp selected_active_rooms(group, room_ids) do
    active = active_rooms(group)
    by_id = Map.new(active, &{&1.room_id, &1})

    ordered =
      for room_id <- room_ids, Map.has_key?(by_id, room_id) do
        Map.fetch!(by_id, room_id)
      end

    if length(ordered) == length(room_ids) do
      ordered
    else
      nil
    end
  end

  # Settles the selected rooms: their allocated cash is refunded, retained,
  # or converted per policy and refund method, and their allocated credit is
  # restored or consumed. Unpaid deposit for those rooms ceases to be due.
  defp settle_cancellation(operation, operation_id, occurred_on, group, rooms, method, refundable) do
    settled_cash = held_cash_cents(rooms)
    cash_sources = cash_sources(rooms)

    credit_issued =
      if refundable and method == "hotel_credit" do
        bonus_value(settled_cash)
      else
        0
      end

    {refunded, retained, converted, disposition} =
      cond do
        not refundable -> {0, settled_cash, 0, "retained"}
        method == "hotel_credit" -> {0, 0, settled_cash, "converted"}
        true -> {settled_cash, 0, 0, "refunded"}
      end

    changeset =
      Group.changeset(group, %{
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
        revision: group.revision + 1,
        status: next_status(group, rooms)
      })

    case Repo.update(changeset) do
      {:ok, updated} ->
        posting = posting_of(occurred_on)

        settle_cash_allocations(rooms, disposition)

        lot =
          if converted > 0 do
            issue_credit_lot(updated, operation_id, occurred_on, cash_sources, credit_issued)
          end

        credit_events = settle_credit_allocations(rooms, occurred_on, posting, refundable)

        events =
          [
            %{
              scope: "cash",
              classification: report_classification(disposition),
              property_id: group.property_id,
              amount_cents: settled_cash
            },
            %{
              scope: "credit",
              classification: "issued",
              amount_cents: credit_issued,
              credit_lot_id: lot && lot.id
            },
            %{
              scope: "credit",
              classification: expired_classification(lot, credit_issued, posting),
              amount_cents: credit_issued,
              credit_lot_id: lot && lot.id,
              lot_expires_on: lot && lot.expires_on
            }
          ] ++ credit_events

        Reporting.record_events(occurred_on, events)

        cancel_room_rows!(rooms)
        group = Repo.reload(updated) |> Repo.preload(:rooms)

        apply_result(operation, %{
          group_id: group.group_id,
          cancelled_room_ids: cancelled_room_ids(group, rooms),
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: credit_issued,
          revision: group.revision
        })
        |> drop_unless_cancel_rooms(operation, :cancelled_room_ids)

      {:error, _changeset} ->
        reject_result(operation, "invalid_operation", operation_id)
    end
  end

  # full cancellation returns its original contract; only cancel_rooms
  # reports the settled room identifiers.
  defp drop_unless_cancel_rooms(result, operation, key) do
    if operation["type"] == "cancel_rooms" do
      result
    else
      Map.delete(result, key)
    end
  end

  defp cancelled_room_ids(group, settled_rooms) do
    settled_positions = MapSet.new(Enum.map(settled_rooms, & &1.position))

    group.rooms
    |> Enum.filter(fn room -> MapSet.member?(settled_positions, room.position) end)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.room_id)
  end

  defp next_status(group, settled_rooms) do
    settled_positions = MapSet.new(Enum.map(settled_rooms, & &1.position))

    remaining_active =
      group.rooms
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.reject(&MapSet.member?(settled_positions, &1.position))

    if remaining_active == [], do: "cancelled", else: "active"
  end

  defp settle_cash_allocations(rooms, disposition) do
    for allocation <- held_allocations(rooms, "cash") do
      allocation
      |> RoomAllocation.changeset(%{disposition: disposition})
      |> Repo.update!()
    end
  end

  # Issues the bonus hotel-credit lot for a converted settlement and records
  # each contributing payment's entitlement within the lot, in allocation
  # order with the unattributed senior block first. Entitlements telescope
  # exactly to the issued lot value. Returns the inserted lot.
  defp issue_credit_lot(group, operation_id, occurred_on, cash_sources, credit_issued) do
    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        expires_on: Date.add(occurred_on, 365),
        remaining_cents: credit_issued
      })
      |> Repo.insert!()

    insert_entitlements(lot, cash_sources)

    lot
  end

  defp insert_entitlements(lot, sources_with_cash) do
    {_running, entitlements} =
      Enum.reduce(sources_with_cash, {0, []}, fn {source, cash}, {running, acc} ->
        new_running = running + cash
        delta = bonus_value(new_running) - bonus_value(running)
        {new_running, [{source, delta} | acc]}
      end)

    Enum.each(Enum.reverse(entitlements), fn {source, delta} ->
      %CreditEntitlement{}
      |> CreditEntitlement.changeset(%{
        credit_lot_id: lot.id,
        payment_operation_id: source,
        entitlement_cents: delta
      })
      |> Repo.insert!()
    end)
  end

  # Held cash allocations grouped by payment identifier, ordered with the
  # unattributed senior block (nil) first and recorded identifiers by their
  # durable commit order.
  defp cash_sources(rooms) do
    allocations = held_allocations(rooms, "cash")

    totals =
      allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {source, rows} -> {source, Enum.sum_by(rows, & &1.amount_cents)} end)

    record_ids =
      Repo.all(
        from r in OperationRecord,
          where: r.operation_id in ^Enum.map(allocations, & &1.payment_operation_id),
          select: {r.operation_id, r.id}
      )
      |> Map.new()

    Enum.sort_by(totals, fn {source, _cash} ->
      case source do
        nil -> {0, 0}
        op_id -> {1, Map.get(record_ids, op_id, 0)}
      end
    end)
  end

  # Held cash moves to exactly one cash classification: refunds and
  # retentions keep their names, conversions report as converted to credit.
  defp report_classification("converted"), do: "converted_to_credit"
  defp report_classification(disposition), do: disposition

  # On a refundable cancellation the applied credit returns to its original
  # lots. Returning credit first absorbs any of the lot's unrecovered
  # clawback; the excess becomes available, unless the lot's expiry has
  # already passed on the reporting posting date, in which case that excess
  # reports as expired instead. Non-refundable cancellations consume the
  # applied credit.
  defp settle_credit_allocations(rooms, occurred_on, posting, refundable) do
    Enum.flat_map(held_allocations(rooms, "credit"), fn allocation ->
      events =
        if refundable do
          restore_credit(allocation, occurred_on, posting)
        else
          [
            %{
              scope: "credit",
              classification: "consumed",
              amount_cents: allocation.amount_cents,
              credit_lot_id: allocation.credit_lot_id
            }
          ]
        end

      allocation
      |> RoomAllocation.changeset(%{disposition: "settled"})
      |> Repo.update!()

      events
    end)
  end

  # Restores one refundable credit allocation, mutating the lot by the
  # operation's occurred_on and returning the report events for the same
  # slice. The absorbed part and any posting-time-expired excess leave the
  # liability; the rest silently becomes available again.
  defp restore_credit(allocation, occurred_on, posting) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(allocation.amount_cents, lot.unrecovered_clawback_cents)
    excess = allocation.amount_cents - absorbed

    remaining_gain =
      if Date.compare(lot.expires_on, occurred_on) != :lt, do: excess, else: 0

    lot
    |> CreditLot.changeset(%{
      remaining_cents: lot.remaining_cents + remaining_gain,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    })
    |> Repo.update!()

    [
      %{
        scope: "credit",
        classification: "absorbed",
        amount_cents: absorbed,
        credit_lot_id: lot.id
      },
      %{
        scope: "credit",
        classification: expired_classification(lot, excess, posting),
        amount_cents: excess,
        credit_lot_id: lot.id,
        lot_expires_on: lot.expires_on
      }
    ]
  end

  # Whether the restored excess expired on the reporting posting date.
  defp expired_classification(_lot, _excess, nil), do: nil
  defp expired_classification(nil, _excess, _posting), do: nil

  defp expired_classification(lot, _excess, posting) do
    if Date.compare(lot.expires_on, posting) == :lt, do: "expired", else: nil
  end

  defp cancel_room_rows!(rooms) do
    Enum.each(rooms, fn room ->
      room
      |> Room.changeset(%{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
      |> Repo.update!()
    end)
  end

  defp valid_refund_method?(nil), do: true
  defp valid_refund_method?(method) when is_binary(method), do: method in @refund_methods
  defp valid_refund_method?(_method), do: false

  defp effective_refund_method(nil), do: "cash"
  defp effective_refund_method(method), do: method

  ## reduce_cash_payment

  defp reduce_cash(operation, operation_id, occurred_on, group, record) do
    held = held_cash_for_payment(record.operation_id)

    cond do
      held == 0 ->
        reject_result(operation, "payment_not_reducible", operation_id)

      not usable_amount?(operation["amount_cents"]) ->
        reject_result(operation, "invalid_amount", operation_id)

      operation["amount_cents"] > held ->
        reject_result(operation, "reduction_exceeds_held_cash", operation_id)

      true ->
        amount = operation["amount_cents"]

        removed = reduce_held_allocations(record.operation_id, amount)

        changeset =
          Group.changeset(group, %{
            cash_reduced_cents: group.cash_reduced_cents + amount,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            bump_other_group_revisions!(Enum.map(removed, & &1.room_id), group.id)

            record_by_property(occurred_on, "reduced", removed)
            updated = Repo.reload(updated) |> Repo.preload(:rooms)

            apply_result(operation, %{
              payment_operation_id: record.operation_id,
              group_id: updated.group_id,
              amount_cents: amount,
              outstanding_deposit_cents: Groups.outstanding(updated),
              revision: updated.revision
            })

          {:error, _changeset} ->
            reject_result(operation, "invalid_operation", operation_id)
        end
    end
  end

  # Removes held allocations belonging to the target payment in reverse
  # allocation order (most recently created slice first), across every group
  # they currently fund. Returns the removed slices, each with its room id
  # and the property the cash sat at.
  defp reduce_held_allocations(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from a in RoomAllocation,
          where:
            a.payment_operation_id == ^payment_operation_id and a.kind == "cash" and
              a.disposition == "held",
          order_by: [desc: a.id]
      )

    Enum.reduce(allocations, {amount, []}, fn allocation, {left, removed} ->
      if left <= 0 do
        {left, removed}
      else
        take = min(allocation.amount_cents, left)
        split_allocation(allocation, take, "reduced")

        room = Repo.get!(Room, allocation.room_id) |> Repo.preload(:group)

        room
        |> Room.changeset(%{cash_paid_cents: room.cash_paid_cents - take})
        |> Repo.update!()

        {left - take,
         [%{room_id: room.id, property_id: room.group.property_id, amount_cents: take} | removed]}
      end
    end)
    |> elem(1)
  end

  # Marks `take` of the allocation's cash removed by shrinking the held row
  # and adding a successor row in the new disposition (or reclassifying the
  # whole row when nothing remains).
  defp split_allocation(allocation, take, disposition) do
    remaining = allocation.amount_cents - take

    if remaining == 0 do
      allocation
      |> RoomAllocation.changeset(%{disposition: disposition})
      |> Repo.update!()
    else
      allocation
      |> RoomAllocation.changeset(%{amount_cents: remaining})
      |> Repo.update!()

      %RoomAllocation{}
      |> RoomAllocation.changeset(%{
        room_id: allocation.room_id,
        kind: allocation.kind,
        amount_cents: take,
        disposition: disposition,
        payment_operation_id: allocation.payment_operation_id,
        credit_lot_id: allocation.credit_lot_id,
        position: allocation.position,
        transferred: allocation.transferred
      })
      |> Repo.insert!()
    end
  end

  # Reductions and chargebacks follow allocations across groups: any group
  # with touched rooms other than the addressed original-payment group
  # increments its own revision, without being guarded by this operation.
  defp bump_other_group_revisions!(room_ids, addressed_group_pk) do
    addressed =
      from r in Room,
        where: r.id in ^room_ids,
        select: r.group_id,
        distinct: true

    Enum.each(Repo.all(addressed), fn group_pk ->
      if group_pk != addressed_group_pk do
        group = Repo.get!(Group, group_pk)

        group
        |> Group.changeset(%{revision: group.revision + 1})
        |> Repo.update!()
      end
    end)
  end

  ## charge_back_payment

  defp charge_back(operation, operation_id, occurred_on, group, record) do
    chargeable = chargeable_for_payment(record.operation_id)

    cond do
      chargeable == 0 ->
        reject_result(operation, "payment_not_chargeable", operation_id)

      true ->
        amount = chargeable

        slices = charge_back_allocations(record.operation_id)
        revocations = revoke_entitlements(record.operation_id)

        changeset =
          Group.changeset(group, %{
            cash_charged_back_cents: group.cash_charged_back_cents + amount,
            revision: group.revision + 1
          })

        case Repo.update(changeset) do
          {:ok, updated} ->
            bump_other_group_revisions!(Enum.map(slices, & &1.room_id), group.id)

            Reporting.record_events(
              occurred_on,
              charged_back_events(slices) ++ revocation_events(revocations)
            )

            updated = Repo.reload(updated) |> Repo.preload(:rooms)

            apply_result(operation, %{
              payment_operation_id: record.operation_id,
              group_id: updated.group_id,
              charged_back_cents: amount,
              outstanding_deposit_cents: Groups.outstanding(updated),
              revision: updated.revision
            })

          {:error, _changeset} ->
            reject_result(operation, "invalid_operation", operation_id)
        end
    end
  end

  # One positive charged-back event per property the payment's cash sits at,
  # plus the negative reversal of each settled classification it emptied.
  defp charged_back_events(slices) do
    reversals =
      for slice <- slices, slice.old_disposition != "held" do
        %{
          scope: "cash",
          classification: report_classification(slice.old_disposition),
          property_id: slice.property_id,
          amount_cents: -slice.amount_cents
        }
      end

    charged =
      slices
      |> Enum.group_by(& &1.property_id, & &1.amount_cents)
      |> Enum.map(fn {property_id, amounts} ->
        %{
          scope: "cash",
          classification: "charged_back",
          property_id: property_id,
          amount_cents: Enum.sum(amounts)
        }
      end)

    reversals ++ charged
  end

  defp revocation_events(revocations) do
    Enum.map(revocations, fn revocation ->
      %{
        scope: "credit",
        classification: "revoked",
        amount_cents: revocation.removed_cents,
        credit_lot_id: revocation.credit_lot_id,
        lot_expires_on: revocation.lot_expires_on
      }
    end)
  end

  # Reverses every remaining disposition of the target payment: held
  # allocations are removed, settled cash is reclassified, and converted
  # principal revokes the credit entitlements it created. Returns one slice
  # per allocation with its room id, property, former disposition, and
  # amount.
  defp charge_back_allocations(payment_operation_id) do
    payment_allocations(payment_operation_id, @chargeable_dispositions)
    |> Enum.map(fn allocation ->
      old_disposition = allocation.disposition

      if old_disposition == "held" do
        room = Repo.get!(Room, allocation.room_id)

        room
        |> Room.changeset(%{cash_paid_cents: room.cash_paid_cents - allocation.amount_cents})
        |> Repo.update!()
      end

      allocation
      |> RoomAllocation.changeset(%{disposition: "charged_back"})
      |> Repo.update!()

      %{
        room_id: allocation.room_id,
        property_id: property_of_room(allocation.room_id),
        old_disposition: old_disposition,
        amount_cents: allocation.amount_cents
      }
    end)
  end

  # Removes each of the payment's entitlements from its lot's remaining
  # balance first; entitlement that cannot be removed becomes that lot's
  # unrecovered clawback. Returns the lots affected with what the report can
  # treat as revoked.
  defp revoke_entitlements(payment_operation_id) do
    entitlements =
      Repo.all(
        from e in CreditEntitlement, where: e.payment_operation_id == ^payment_operation_id
      )

    Enum.map(entitlements, fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(entitlement.entitlement_cents, lot.remaining_cents)

      lot
      |> CreditLot.changeset(%{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.entitlement_cents - removed
      })
      |> Repo.update!()

      %{
        credit_lot_id: lot.id,
        lot_expires_on: lot.expires_on,
        removed_cents: removed
      }
    end)
  end

  defp property_of_room(room_id) do
    room = Repo.get(Room, room_id) |> Repo.preload(:group)
    room.group.property_id
  end

  ## shared allocation queries

  # The reporting posting date for an operation, or `nil` when reporting has
  # not started (in which case nothing records movements).
  defp posting_of(occurred_on) do
    case Reporting.state() do
      nil ->
        nil

      %{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    end
  end

  # Convenience wrapper recording one cash movement for this operation.
  defp record_event(occurred_on, scope, classification, amount, property_id) do
    Reporting.record_events(occurred_on, [
      %{
        scope: scope,
        classification: classification,
        property_id: property_id,
        amount_cents: amount
      }
    ])
  end

  # Aggregates removed slices by property into one movement event per
  # property (the payment's cash follows where it currently sits).
  defp record_by_property(occurred_on, classification, slices) do
    slices
    |> Enum.group_by(& &1.property_id, & &1.amount_cents)
    |> Enum.map(fn {property_id, amounts} ->
      %{
        scope: "cash",
        classification: classification,
        property_id: property_id,
        amount_cents: Enum.sum(amounts)
      }
    end)
    |> then(fn events -> Reporting.record_events(occurred_on, events) end)
  end

  # Whether any of this payment's cash has ever moved through a transfer.
  # Marked rows keep the flag even after settlement, so the statement keeps
  # its `held_by_group` field once transfers have occurred.
  defp participated_in_transfer?(payment_operation_id) do
    Repo.exists?(
      from a in RoomAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.transferred == true
    )
  end

  # The payment's held cash grouped by the group currently holding it,
  # ordered by partner group identifier; groups with no held cash omitted.
  defp held_by_group(payment_operation_id) do
    Repo.all(
      from a in RoomAllocation,
        join: r in Room,
        on: a.room_id == r.id,
        join: g in Group,
        on: r.group_id == g.id,
        where:
          a.payment_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.disposition == "held",
        group_by: g.group_id,
        order_by: [asc: g.group_id],
        select: %{group_id: g.group_id, amount_cents: sum(a.amount_cents)}
    )
  end

  defp held_allocations(rooms, kind) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from a in RoomAllocation,
        where: a.room_id in ^room_ids and a.kind == ^kind and a.disposition == "held",
        order_by: [asc: a.id]
    )
  end

  defp held_cash_cents(rooms) do
    rooms
    |> held_allocations("cash")
    |> Enum.sum_by(& &1.amount_cents)
  end

  defp held_cash_for_payment(payment_operation_id) do
    Repo.one(
      from a in RoomAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.disposition == "held",
        select: sum(a.amount_cents)
    ) || 0
  end

  defp chargeable_for_payment(payment_operation_id) do
    Repo.one(
      from a in RoomAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.disposition in @chargeable_dispositions,
        select: sum(a.amount_cents)
    ) || 0
  end

  defp payment_allocations(payment_operation_id, dispositions) do
    Repo.all(
      from a in RoomAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and a.kind == "cash" and
            a.disposition in ^dispositions
    )
  end

  defp active_rooms(group), do: Enum.filter(group.rooms, &(&1.status == "active"))

  ## validation helpers

  defp group_missing?(nil), do: :ok
  defp group_missing?(_group), do: {:reject, "group_already_exists"}

  defp valid_rate_plan(rate_plan) when rate_plan in ~w(flexible advance_purchase) do
    {:ok, rate_plan}
  end

  defp valid_rate_plan(_rate_plan), do: {:reject, "invalid_rate_plan"}

  defp valid_stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.diff(departure_on, arrival_on) >= 1 do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:reject, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &usable_room?/1) and unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      {:reject, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:reject, "invalid_rooms"}

  defp usable_room?(room) when is_map(room) do
    is_binary(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] > 0
  end

  defp usable_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(ids) == length(Enum.uniq(ids))
  end

  defp usable_amount?(amount), do: is_integer(amount) and amount > 0

  defp bonus_value(amount), do: amount + Money.percent_of(amount, @bonus_percent)

  defp required_string(map, key) when is_map(map) do
    case map do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp required_string(_map, _key), do: :error

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_date(_value), do: :error

  ## result helpers

  defp apply_result(operation, fields) do
    %{status: "applied"}
    |> put_optional(:operation_id, operation["operation_id"])
    |> Map.merge(fields)
  end

  defp reject_result(operation, code, operation_id \\ nil, extra \\ %{}) do
    %{status: "rejected", code: code}
    |> put_optional(:operation_id, operation_id || operation_value(operation, "operation_id"))
    |> Map.merge(extra)
    |> put_optional_group(operation)
  end

  defp operation_value(operation, key) when is_map(operation), do: Map.get(operation, key)
  defp operation_value(_operation, _key), do: nil

  defp put_optional_group(result, operation) do
    if is_map(operation) do
      put_optional(result, :group_id, Map.get(operation, "group_id"))
    else
      result
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
