defmodule GroupStay.Groups do
  @moduledoc """
  Applies partner operations to group reservations and reads their deposit state.

  Each operation is applied in its own database transaction together with its
  idempotency record, so a rejected operation leaves the data exactly as it was,
  retries return the original result, and later operations in a batch are
  unaffected.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query, only: [from: 2]

  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.CashPayment
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.GroupCreditApplication
  alias GroupStay.Groups.LotEntitlement
  alias GroupStay.Groups.OperationRecord
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @flex_14_cutoff ~D[2027-01-01]
  @refund_notice_days 14
  @extended_refund_notice_days 30
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_availability_days 365
  @refund_methods ~w(cash hotel_credit)

  # -- Applying operations ---------------------------------------------------

  @doc """
  Applies each operation in array order and returns one result map per operation.
  """
  def apply_operations(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc """
  Applies a single partner operation exactly once per `operation_id`.

  The first submission for an identifier is processed normally and its result,
  applied or rejected, is remembered in the same transaction as any domain
  changes. An identical resubmission (JSON object key order is irrelevant; array
  order and values are significant) returns the stored result verbatim without
  touching current domain state. A different payload under the same identifier
  is rejected with `operation_id_conflict` and leaves the original record
  intact. Operations without a usable identifier are processed but not
  remembered. An unexpected exception rolls the whole attempt back and is never
  remembered as a result, so it aborts the request with `500` and the gateway
  may retry the batch.
  """
  def apply_operation(operation) when is_map(operation) do
    case recordable_id(Map.get(operation, "operation_id")) do
      {:ok, operation_id} -> apply_durably(operation, operation_id)
      :error -> transact(fn -> compute_result(operation) end)
    end
  end

  def apply_operation(_operation), do: reject(nil, "invalid_operation")

  # Idempotent application. Lookup, domain changes, and the idempotency insert
  # share one transaction. Handled rejections return their result without
  # writing domain state, so the record commits while the data stays as it was.
  # Concurrent retries commit at most once: the loser of a race hits the unique
  # index, rolls back entirely, and its batch retry replays the winner's stored
  # result.
  defp apply_durably(operation, operation_id) do
    submission = canonical_form(operation)

    transact(fn ->
      case Repo.get_by(OperationRecord, operation_id: operation_id) do
        %OperationRecord{submission: stored_submission} = record
        when stored_submission == submission ->
          record.result

        %OperationRecord{} ->
          reject(operation_id, "operation_id_conflict")

        nil ->
          result = compute_result(operation)

          Repo.insert!(%OperationRecord{
            operation_id: operation_id,
            type: operation_type(operation),
            submission: submission,
            result: result
          })

          result
      end
    end)
  end

  # Objects compare irrespective of key order; arrays keep their order and values.
  defp canonical_form(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {key, canonical_form(value)} end)
  end

  defp canonical_form(list) when is_list(list), do: Enum.map(list, &canonical_form/1)
  defp canonical_form(value), do: value

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp recordable_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp recordable_id(_id), do: :error

  @doc """
  Returns the stored result for an operation identifier.
  """
  def get_operation_result(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record.result}
    end
  end

  @doc """
  Returns the current disposition of one durably recorded cash payment.

  Reading a statement never changes state. Funding without a durable operation
  identity has no statement.
  """
  def get_payment_statement(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, :not_found}

      %OperationRecord{} ->
        case Repo.get_by(CashPayment, operation_id: payment_operation_id) do
          nil -> {:error, :not_reconcilable}
          payment -> {:ok, payment_statement_json(Repo.preload(payment, :group))}
        end
    end
  end

  defp payment_statement_json(%CashPayment{} = payment) do
    base = %{
      "payment_operation_id" => payment.operation_id,
      "original_group_id" => payment.group.group_id,
      "recorded_cents" => payment.amount_cents,
      "held_cents" => payment.held_cents,
      "refunded_cents" => payment.refunded_cents,
      "retained_cents" => payment.retained_cents,
      "converted_to_credit_cents" => payment.converted_to_credit_cents,
      "reduced_cents" => payment.reduced_cents,
      "charged_back_cents" => payment.charged_back_cents
    }

    # Once any funding from the payment has participated in a transfer, the
    # statement reports its held cash per group, ordered by group identifier.
    if payment.transferred do
      Map.put(base, "held_by_group", held_by_group(payment.operation_id))
    else
      base
    end
  end

  defp held_by_group(payment_operation_id) do
    from(a in Allocation,
      join: g in Group,
      on: g.id == a.group_id,
      where: a.payment_operation_id == ^payment_operation_id and a.kind == "cash",
      group_by: g.group_id,
      order_by: [asc: g.group_id],
      select: {g.group_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Enum.flat_map(fn
      {group_id, amount} when amount > 0 -> [%{"group_id" => group_id, "amount_cents" => amount}]
      _empty -> []
    end)
  end

  # -- Reading ----------------------------------------------------------------

  @doc """
  Fetches a group by its partner identifier.
  """
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  @doc """
  Renders a group for the API. Totals describe active rooms only.
  """
  def group_json(%Group{} = group) do
    paid_by_room = room_paid(group)

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "policy_version" => policy_version(group),
      "refundable_until" => maybe_date(refundable_until(group)),
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          paid = Map.get(paid_by_room, room.room_id, %{cash: 0, credit: 0})

          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents,
            "status" => room_status(room),
            "lodging_cents" => room_lodging(group, room),
            "deposit_due_cents" => room_deposit_due(group, room),
            "cash_paid_cents" => paid.cash,
            "credit_paid_cents" => paid.credit
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_applied_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp room_paid(group) do
    from(a in Allocation,
      where: a.group_id == ^group.id,
      select: {a.room_id, a.kind, a.amount_cents}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {room_id, kind, amount}, acc ->
      key = if kind == "cash", do: :cash, else: :credit

      entry =
        acc
        |> Map.get(room_id, %{cash: 0, credit: 0})
        |> Map.update!(key, &(&1 + amount))

      Map.put(acc, room_id, entry)
    end)
  end

  defp nights(%Group{} = group), do: Date.diff(group.departure_on, group.arrival_on)

  defp room_lodging(group, room), do: room.nightly_rate_cents * nights(group)
  defp room_deposit_due(group, room), do: room_deposit(room_lodging(group, room), group.rate_plan)

  # Rooms stored before this release have no embedded status; they were
  # necessarily still active.
  defp room_status(%Room{status: status}) when is_binary(status), do: status
  defp room_status(_room), do: "active"

  defp active_rooms(group), do: Enum.filter(group.rooms, &(room_status(&1) == "active"))

  # A group's policy version is implied by its rate plan and its original booking
  # date, both of which never change, so groups created before this release read
  # with the policy their booking date implies.
  defp policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  defp policy_version(%Group{booked_on: booked_on}) do
    if Date.compare(booked_on, @flex_14_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp cancellation_window_days(%Group{rate_plan: "advance_purchase"}), do: nil

  defp cancellation_window_days(%Group{booked_on: booked_on}) do
    if Date.compare(booked_on, @flex_14_cutoff) == :lt,
      do: @refund_notice_days,
      else: @extended_refund_notice_days
  end

  # The last cancellation date that is still refundable; `nil` for advance purchase.
  defp refundable_until(%Group{rate_plan: "advance_purchase"}), do: nil

  defp refundable_until(group),
    do: Date.add(group.arrival_on, -cancellation_window_days(group))

  defp maybe_date(nil), do: nil
  defp maybe_date(date), do: Date.to_iso8601(date)

  @doc """
  Cash, credit, and clawback totals across all groups as of the given date.

  Recorded cash partitions into held, refunded, retained, converted, reduced,
  and charged-back amounts. Credit liability counts available credit plus
  credit currently applied to active groups; `credit_shortfall_cents` is the
  part of applied credit whose entitlement was revoked by a chargeback.
  """
  def ledger_json(on \\ Date.utc_today()) do
    {held, refunded, retained, converted} =
      from(g in Group,
        select:
          {g.status, g.cash_paid_cents, g.refunded_cents, g.retained_cents,
           g.converted_to_credit_cents}
      )
      |> Repo.all()
      |> Enum.reduce({0, 0, 0, 0}, fn
        {"active", paid, refunded, retained, converted}, {held, r, t, c} ->
          {held + paid, r + refunded, t + retained, c + converted}

        {_cancelled, _paid, refunded, retained, converted}, {held, r, t, c} ->
          {held, r + refunded, t + retained, c + converted}
      end)

    %{
      "cash_held_cents" => held,
      "cash_refunded_cents" => refunded,
      "cash_retained_cents" => retained,
      "cash_converted_to_credit_cents" => converted,
      "cash_reduced_cents" => payment_disposition_sum(:reduced_cents),
      "cash_charged_back_cents" => payment_disposition_sum(:charged_back_cents),
      "credit_shortfall_cents" => credit_shortfall(),
      "credit_liability_cents" => credit_liability(on)
    }
  end

  defp payment_disposition_sum(field) do
    from(cp in CashPayment, select: sum(field(cp, ^field)))
    |> Repo.one()
    |> Kernel.||(0)
  end

  # Per lot, the lesser of its unrecovered clawback and the credit from that
  # lot still applied to active groups.
  defp credit_shortfall do
    from(e in LotEntitlement,
      group_by: e.credit_lot_id,
      select: {e.credit_lot_id, sum(e.unrecovered_clawback_cents)}
    )
    |> Repo.all()
    |> Enum.reduce(0, fn {lot_id, unrecovered}, acc ->
      applied =
        from(a in GroupCreditApplication,
          join: g in Group,
          on: g.id == a.group_id,
          where: a.credit_lot_id == ^lot_id and g.status == "active",
          select: sum(a.amount_cents)
        )
        |> Repo.one()
        |> Kernel.||(0)

      acc + min(unrecovered, applied)
    end)
  end

  @doc """
  Available hotel credit lots for a guest as of the given date.

  Lots are ordered by expiry, then by source operation identifier. Expired and
  exhausted lots are omitted.
  """
  def guest_credit_json(guest_id, on) do
    lots = available_lots(guest_id, on)

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

  defp credit_liability(on) do
    available =
      from(l in CreditLot, where: l.expires_on > ^on, select: l.remaining_cents)
      |> Repo.all()
      |> Enum.sum()

    applied_to_active =
      from(a in GroupCreditApplication,
        join: g in Group,
        on: g.id == a.group_id,
        where: g.status == "active",
        select: a.amount_cents
      )
      |> Repo.all()
      |> Enum.sum()

    available + applied_to_active
  end

  defp available_lots(guest_id, on) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  # -- Parsing ------------------------------------------------------------------
  #
  # Parsing rejects only operations missing data needed to identify or route them
  # (`invalid_operation`). Domain rules are evaluated later so that group existence
  # and revision checks take precedence as documented. Every failure raised here is
  # a handled rejection; unexpected exceptions from execution propagate and abort
  # the request without being remembered.

  defp compute_result(operation) do
    case parse(operation) do
      {:apply, _kind, _operation_id, _cmd} = command ->
        case execute(command) do
          {:error, rejection} -> rejection
          result -> result
        end

      {:error, rejection} ->
        rejection
    end
  end

  defp parse(%{"type" => "open_group"} = operation) do
    with :ok <-
           require_fields(
             operation,
             ~w(occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         {:ok, identifiers} <- identifiers(operation),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :open_group, operation["operation_id"],
       Map.merge(identifiers, %{occurred_on: occurred_on, raw: operation})}
    end
  end

  defp parse(%{"type" => "record_cash_payment"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id amount_cents)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :record_cash_payment, operation["operation_id"],
       %{group_id: group_id, occurred_on: occurred_on, raw: operation}}
    end
  end

  defp parse(%{"type" => "reschedule_group"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id new_arrival_on)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :reschedule_group, operation["operation_id"],
       %{group_id: group_id, occurred_on: occurred_on, raw: operation}}
    end
  end

  defp parse(%{"type" => "cancel_group"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, refund_method} <- refund_method(operation) do
      {:apply, :cancel_group, operation["operation_id"],
       %{
         group_id: group_id,
         occurred_on: occurred_on,
         refund_method: refund_method,
         raw: operation
       }}
    end
  end

  defp parse(%{"type" => "apply_hotel_credit"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id amount_cents)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :apply_hotel_credit, operation["operation_id"],
       %{group_id: group_id, occurred_on: occurred_on, raw: operation}}
    end
  end

  defp parse(%{"type" => "cancel_rooms"} = operation) do
    with :ok <- require_fields(operation, ~w(occurred_on group_id room_ids)),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, refund_method} <- refund_method(operation) do
      {:apply, :cancel_rooms, operation["operation_id"],
       %{
         group_id: group_id,
         occurred_on: occurred_on,
         refund_method: refund_method,
         raw: operation
       }}
    end
  end

  defp parse(%{"type" => "transfer_deposit"} = operation) do
    with :ok <-
           require_fields(
             operation,
             ~w(occurred_on source_group_id destination_group_id amount_cents)
           ),
         {:ok, source_group_id} <- identifier(operation, "source_group_id"),
         {:ok, destination_group_id} <- identifier(operation, "destination_group_id"),
         {:ok, occurred_on} <- operation_date(operation) do
      {:apply, :transfer_deposit, operation["operation_id"],
       %{
         source_group_id: source_group_id,
         destination_group_id: destination_group_id,
         occurred_on: occurred_on,
         raw: operation
       }}
    end
  end

  defp parse(%{"type" => "reduce_cash_payment"} = operation) do
    with :ok <- require_fields(operation, ~w(payment_operation_id amount_cents)),
         {:ok, payment_operation_id} <- identifier(operation, "payment_operation_id") do
      {:apply, :reduce_cash_payment, operation["operation_id"],
       %{payment_operation_id: payment_operation_id, raw: operation}}
    end
  end

  defp parse(%{"type" => "charge_back_payment"} = operation) do
    with :ok <- require_fields(operation, ~w(payment_operation_id)),
         {:ok, payment_operation_id} <- identifier(operation, "payment_operation_id") do
      {:apply, :charge_back_payment, operation["operation_id"],
       %{payment_operation_id: payment_operation_id, raw: operation}}
    end
  end

  defp parse(operation),
    do: {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}

  defp refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in @refund_methods -> {:ok, method}
      _other -> {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}
    end
  end

  # -- Execution --------------------------------------------------------------

  defp execute({:apply, :open_group, operation_id, cmd}) do
    raw = cmd.raw

    with {:ok, arrival_on} <- stay_date(operation_id, cmd.group_id, raw["arrival_on"]),
         {:ok, departure_on} <- stay_date(operation_id, cmd.group_id, raw["departure_on"]),
         :ok <- stay_order(operation_id, cmd.group_id, arrival_on, departure_on),
         {:ok, rooms} <- rooms(operation_id, cmd.group_id, raw["rooms"]),
         :ok <- rate_plan(operation_id, cmd.group_id, raw["rate_plan"]) do
      if Repo.exists?(from g in Group, where: g.group_id == ^cmd.group_id) do
        reject(operation_id, "group_already_exists", cmd.group_id)
      else
        group =
          new_group(%{
            group_id: cmd.group_id,
            guest_id: cmd.guest_id,
            property_id: cmd.property_id,
            occurred_on: cmd.occurred_on,
            arrival_on: arrival_on,
            departure_on: departure_on,
            rate_plan: raw["rate_plan"],
            rooms: rooms
          })

        Repo.insert!(group)

        applied(operation_id, %{
          "group_id" => group.group_id,
          "deposit_due_cents" => group.deposit_due_cents,
          "revision" => group.revision
        })
      end
    end
  end

  defp execute({:apply, kind, operation_id, cmd})
       when kind in [
              :record_cash_payment,
              :reschedule_group,
              :cancel_group,
              :cancel_rooms,
              :apply_hotel_credit
            ] do
    raw = cmd.raw
    group = Repo.get_by(Group, group_id: cmd.group_id)

    cond do
      is_nil(group) ->
        reject(operation_id, "group_not_found", cmd.group_id)

      stale_revision?(group, raw["expected_revision"]) ->
        reject(operation_id, "stale_revision", cmd.group_id,
          expected_revision: raw["expected_revision"],
          actual_revision: group.revision
        )

      group.status != "active" ->
        reject(operation_id, "group_not_active", cmd.group_id)

      true ->
        apply_group_operation(kind, operation_id, cmd, group)
    end
  end

  # A transfer resolves source existence, then destination existence, then the
  # source revision and the destination revision, before the transfer rules.
  defp execute({:apply, :transfer_deposit, operation_id, cmd}) do
    raw = cmd.raw
    amount_cents = raw["amount_cents"]

    source = Repo.get_by(Group, group_id: cmd.source_group_id)

    destination =
      if cmd.source_group_id == cmd.destination_group_id,
        do: source,
        else: Repo.get_by(Group, group_id: cmd.destination_group_id)

    cond do
      is_nil(source) ->
        reject(operation_id, "group_not_found", cmd.source_group_id)

      is_nil(destination) ->
        reject(operation_id, "group_not_found", cmd.destination_group_id)

      stale_revision?(source, raw["expected_revision"]) ->
        reject(operation_id, "stale_revision", source.group_id,
          expected_revision: raw["expected_revision"],
          actual_revision: source.revision
        )

      stale_revision?(destination, raw["destination_expected_revision"]) ->
        reject(operation_id, "stale_revision", destination.group_id,
          expected_revision: raw["destination_expected_revision"],
          actual_revision: destination.revision
        )

      source.id == destination.id or source.guest_id != destination.guest_id ->
        reject(operation_id, "invalid_transfer")

      source.status != "active" ->
        reject(operation_id, "group_not_active", source.group_id)

      destination.status != "active" ->
        reject(operation_id, "group_not_active", destination.group_id)

      not usable_amount?(amount_cents) ->
        reject(operation_id, "invalid_amount", source.group_id)

      held_funding(source) < amount_cents ->
        reject(operation_id, "transfer_exceeds_held_funding", source.group_id)

      outstanding_deposit(destination) < amount_cents ->
        reject(operation_id, "transfer_exceeds_outstanding", destination.group_id)

      true ->
        transfer_held_funding(operation_id, source, destination, amount_cents)
    end
  end

  # Payment-addressed operations derive their group from the stored payment.
  defp execute({:apply, kind, operation_id, cmd})
       when kind in [:reduce_cash_payment, :charge_back_payment] do
    target_id = cmd.payment_operation_id

    if durable_record_missing?(target_id) do
      reject(operation_id, "operation_not_found")
    else
      payment = Repo.get_by(CashPayment, operation_id: target_id)

      cond do
        reducible?(payment) == false and kind == :reduce_cash_payment ->
          reject(operation_id, "payment_not_reducible")

        chargeable?(payment) == false and kind == :charge_back_payment ->
          reject(operation_id, "payment_not_chargeable")

        true ->
          group = Repo.get(Group, payment.group_id)
          expected_revision = cmd.raw["expected_revision"]

          if stale_revision?(group, expected_revision) do
            reject(operation_id, "stale_revision", group.group_id,
              expected_revision: expected_revision,
              actual_revision: group.revision
            )
          else
            apply_payment_operation(kind, operation_id, cmd, payment, group)
          end
      end
    end
  end

  defp durable_record_missing?(operation_id),
    do: is_nil(Repo.get_by(OperationRecord, operation_id: operation_id))

  # Only cash still held on active rooms can be reduced.
  defp reducible?(%CashPayment{held_cents: held}), do: held > 0
  defp reducible?(nil), do: false

  # A chargeback reverses every disposition except already-reduced cash.
  defp chargeable?(nil), do: false

  defp chargeable?(%CashPayment{} = payment) do
    payment.held_cents + payment.refunded_cents + payment.retained_cents +
      payment.converted_to_credit_cents > 0
  end

  defp apply_group_operation(:record_cash_payment, operation_id, cmd, group) do
    amount_cents = cmd.raw["amount_cents"]

    if usable_amount?(amount_cents) do
      outstanding_before = outstanding_deposit(group)

      if amount_cents > outstanding_before do
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)
      else
        Repo.insert!(%CashPayment{
          operation_id: operation_id,
          group_id: group.id,
          amount_cents: amount_cents,
          held_cents: amount_cents
        })

        fund_active_rooms(
          group,
          %{
            kind: "cash",
            payment_operation_id: operation_id,
            credit_lot_id: nil
          },
          amount_cents
        )

        revision = group.revision + 1

        update_group(group,
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: group.cash_paid_cents + amount_cents,
          revision: revision
        )

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding_before - amount_cents,
          "revision" => revision
        })
      end
    else
      reject(operation_id, "invalid_amount", group.group_id)
    end
  end

  defp apply_group_operation(:reschedule_group, operation_id, cmd, group) do
    with {:ok, new_arrival_on} <-
           stay_date(operation_id, group.group_id, cmd.raw["new_arrival_on"]),
         :ok <- move_after(operation_id, group.group_id, new_arrival_on, cmd.occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, nights)
      revision = group.revision + 1

      # The policy version is fixed at opening; only the refundable date follows
      # the moved arrival.
      group =
        group
        |> change(arrival_on: new_arrival_on, departure_on: new_departure_on, revision: revision)
        |> Repo.update!()

      applied(operation_id, %{
        "group_id" => group.group_id,
        "new_arrival_on" => Date.to_iso8601(new_arrival_on),
        "new_departure_on" => Date.to_iso8601(new_departure_on),
        "policy_version" => policy_version(group),
        "refundable_until" => maybe_date(refundable_until(group)),
        "revision" => revision
      })
    end
  end

  defp apply_group_operation(:apply_hotel_credit, operation_id, cmd, group) do
    amount_cents = cmd.raw["amount_cents"]

    cond do
      not usable_amount?(amount_cents) ->
        reject(operation_id, "invalid_amount", group.group_id)

      amount_cents > outstanding_deposit(group) ->
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)

      true ->
        consume_lots_and_apply(operation_id, cmd, group, amount_cents)
    end
  end

  defp apply_group_operation(:cancel_group, operation_id, cmd, group) do
    if not refundable?(group, cmd.occurred_on) and cmd.refund_method == "hotel_credit" do
      reject(operation_id, "refund_method_not_available", group.group_id)
    else
      room_ids = Enum.map(active_rooms(group), & &1.room_id)
      settlement = settle_rooms(operation_id, cmd, group, room_ids)

      applied(operation_id, %{
        "group_id" => group.group_id,
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => settlement.revision
      })
    end
  end

  defp apply_group_operation(:cancel_rooms, operation_id, cmd, group) do
    with {:ok, room_ids} <- selected_room_ids(operation_id, group, cmd.raw["room_ids"]),
         :ok <-
           if(not refundable?(group, cmd.occurred_on) and cmd.refund_method == "hotel_credit",
             do: {:error, reject(operation_id, "refund_method_not_available", group.group_id)},
             else: :ok
           ) do
      settlement = settle_rooms(operation_id, cmd, group, room_ids)

      cancelled_room_ids =
        group.rooms
        |> Enum.filter(&(&1.room_id in settlement.cancelled_room_ids))
        |> Enum.map(& &1.room_id)

      applied(operation_id, %{
        "group_id" => group.group_id,
        "cancelled_room_ids" => cancelled_room_ids,
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => settlement.revision
      })
    end
  end

  # All supplied identifiers must name distinct, active rooms of the group.
  defp selected_room_ids(operation_id, group, room_ids) do
    active_ids = MapSet.new(active_rooms(group), & &1.room_id)

    valid? =
      is_list(room_ids) and room_ids != [] and
        Enum.all?(room_ids, &is_binary/1) and
        length(Enum.uniq(room_ids)) == length(room_ids) and
        Enum.all?(room_ids, &MapSet.member?(active_ids, &1))

    if valid?,
      do: {:ok, room_ids},
      else: {:error, reject(operation_id, "invalid_rooms", group.group_id)}
  end

  defp apply_payment_operation(:reduce_cash_payment, operation_id, cmd, payment, group) do
    amount_cents = cmd.raw["amount_cents"]

    cond do
      not usable_amount?(amount_cents) ->
        reject(operation_id, "invalid_amount", group.group_id)

      amount_cents > payment.held_cents ->
        reject(operation_id, "reduction_exceeds_held_cash", group.group_id)

      true ->
        # Remove held allocations belonging to the target payment in reverse
        # fill order across all groups; the outstanding deposit reopens by the
        # amount removed in each affected group.
        removed_by_group = remove_held_allocations(payment.operation_id, amount_cents)

        from(cp in CashPayment, where: cp.operation_id == ^payment.operation_id)
        |> Repo.update_all(
          set: [
            held_cents: payment.held_cents - amount_cents,
            reduced_cents: payment.reduced_cents + amount_cents
          ]
        )

        reopen_groups(Map.delete(removed_by_group, group.id))
        original = reopen_group(group.id, Map.get(removed_by_group, group.id, 0))

        applied(operation_id, %{
          "payment_operation_id" => payment.operation_id,
          "group_id" => original.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding_deposit(original),
          "revision" => original.revision
        })
    end
  end

  defp apply_payment_operation(:charge_back_payment, operation_id, _cmd, payment, group) do
    charged_back =
      payment.held_cents + payment.refunded_cents + payment.retained_cents +
        payment.converted_to_credit_cents

    cash_allocations =
      from(a in Allocation,
        where: a.payment_operation_id == ^payment.operation_id and a.kind == "cash"
      )
      |> Repo.all()

    removed_by_group =
      Enum.reduce(cash_allocations, %{}, fn alloc, acc ->
        Map.update(acc, alloc.group_id, alloc.amount_cents, &(&1 + alloc.amount_cents))
      end)

    Repo.delete_all(
      from(a in Allocation,
        where: a.payment_operation_id == ^payment.operation_id and a.kind == "cash"
      )
    )

    clawback_entitlements(payment.operation_id)

    from(cp in CashPayment, where: cp.operation_id == ^payment.operation_id)
    |> Repo.update_all(
      set: [
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: payment.charged_back_cents + charged_back
      ]
    )

    # Every group whose held funding was removed reopens its deposit and
    # increments its revision; the addressed original payment group always does.
    {held_on_original, other_groups} = Map.pop(removed_by_group, group.id, 0)

    reopen_groups(other_groups)

    paid = max(group.deposit_paid_cents - held_on_original, 0)

    original =
      update_group(group,
        deposit_paid_cents: paid,
        cash_paid_cents: group.cash_paid_cents - held_on_original,
        refunded_cents: max(group.refunded_cents - payment.refunded_cents, 0),
        retained_cents: max(group.retained_cents - payment.retained_cents, 0),
        converted_to_credit_cents:
          max(group.converted_to_credit_cents - payment.converted_to_credit_cents, 0),
        revision: group.revision + 1
      )

    applied(operation_id, %{
      "payment_operation_id" => payment.operation_id,
      "group_id" => original.group_id,
      "charged_back_cents" => charged_back,
      "outstanding_deposit_cents" => outstanding_deposit(original),
      "revision" => original.revision
    })
  end

  # An applied operation increments the revision of every group whose state it
  # changes, even groups the request does not guard. `amount` is the funding
  # removed from that group's active rooms by the same operation.
  defp reopen_group(group_db_id, amount) do
    group = Repo.get!(Group, group_db_id)
    paid = max(group.deposit_paid_cents - amount, 0)

    update_group(group,
      deposit_paid_cents: paid,
      cash_paid_cents: group.cash_paid_cents - amount,
      revision: group.revision + 1
    )
  end

  defp reopen_groups(removed_by_group) do
    Map.new(removed_by_group, fn {group_db_id, amount} ->
      {group_db_id, reopen_group(group_db_id, amount)}
    end)
  end

  # Removes up to `amount` of a payment's held allocations in reverse fill
  # order across all groups; returns how much was removed per group.
  defp remove_held_allocations(payment_operation_id, amount) do
    from(a in Allocation,
      where: a.payment_operation_id == ^payment_operation_id and a.kind == "cash",
      order_by: [desc: a.id]
    )
    |> Repo.all()
    |> Enum.reduce_while({amount, %{}}, fn alloc, {left, removed} ->
      taken = min(left, alloc.amount_cents)

      if taken >= alloc.amount_cents do
        Repo.delete!(alloc)
      else
        alloc
        |> change(amount_cents: alloc.amount_cents - taken)
        |> Repo.update!()
      end

      removed = Map.update(removed, alloc.group_id, taken, &(&1 + taken))

      if left - taken > 0, do: {:cont, {left - taken, removed}}, else: {:halt, {:done, removed}}
    end)
    |> elem(1)
  end

  # Revokes each entitlement the payment holds on issued credit lots: recover
  # what the lot's remaining balance can cover; the rest becomes that lot's
  # unrecovered clawback.
  defp clawback_entitlements(payment_operation_id) do
    from(e in LotEntitlement,
      where: e.payment_operation_id == ^payment_operation_id,
      order_by: [asc: e.id]
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      recovered = min(max(lot.remaining_cents, 0), entitlement.entitled_cents)

      from(l in CreditLot, where: l.id == ^lot.id)
      |> Repo.update_all(inc: [remaining_cents: -recovered])

      entitlement
      |> change(
        unrecovered_clawback_cents:
          entitlement.unrecovered_clawback_cents + entitlement.entitled_cents - recovered
      )
      |> Repo.update!()
    end)

    :ok
  end

  # A flexible reservation is refundable when the cancellation happens on or
  # before its policy's refundable-until date.
  defp refundable?(%Group{rate_plan: "advance_purchase"}, _on), do: false

  defp refundable?(group, on), do: Date.compare(on, refundable_until(group)) != :gt

  # Settles the selected rooms' allocated cash and credit using the group's
  # cancellation policy: cash is refunded, retained, or converted per the
  # refund method; applied credit is restored or consumed; unpaid deposit for
  # the selected rooms ceases to be due.
  defp settle_rooms(operation_id, cmd, group, room_ids) do
    refundable = refundable?(group, cmd.occurred_on)

    allocations =
      from(a in Allocation, where: a.group_id == ^group.id and a.room_id in ^room_ids)
      |> Repo.all()

    cash_allocations = Enum.filter(allocations, &(&1.kind == "cash"))
    credit_allocations = Enum.filter(allocations, &(&1.kind == "credit"))

    cash_total = sum_amounts(cash_allocations)
    credit_total = sum_amounts(credit_allocations)

    {refunded_cents, retained_cents, converted_cents} =
      cond do
        refundable and cmd.refund_method == "cash" -> {cash_total, 0, 0}
        refundable -> {0, 0, cash_total}
        true -> {0, cash_total, 0}
      end

    move_payment_dispositions(cash_allocations, refunded_cents, retained_cents, converted_cents)

    credit_issued_cents =
      if refundable and cmd.refund_method == "hotel_credit" and cash_total > 0 do
        contributors = funding_contributors(cash_allocations)
        bonus = percent_half_up(cash_total, 100 + @credit_bonus_percent)

        lot =
          Repo.insert!(%CreditLot{
            guest_id: group.guest_id,
            source_operation_id: operation_id,
            remaining_cents: bonus,
            issued_on: cmd.occurred_on,
            expires_on: Date.add(cmd.occurred_on, @credit_availability_days + 1)
          })

        insert_entitlements(lot, contributors)
        bonus
      else
        0
      end

    settle_credit(group, credit_allocations, refundable, cmd.occurred_on)

    Repo.delete_all(
      from(a in Allocation, where: a.group_id == ^group.id and a.room_id in ^room_ids)
    )

    cancel_group_rooms(group, room_ids, %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      converted_cents: converted_cents,
      cash_total: cash_total,
      credit_total: credit_total
    })
    |> Map.merge(%{credit_issued_cents: credit_issued_cents, revision: group.revision + 1})
  end

  # Each payment's settled held cash moves to the settlement's disposition.
  defp move_payment_dispositions(cash_allocations, refunded, retained, _converted) do
    disposition_field =
      cond do
        refunded > 0 -> :refunded_cents
        retained > 0 -> :retained_cents
        true -> :converted_to_credit_cents
      end

    cash_allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn
      {nil, _allocs} ->
        :ok

      {payment_operation_id, allocs} ->
        amount = sum_amounts(allocs)

        from(cp in CashPayment, where: cp.operation_id == ^payment_operation_id)
        |> Repo.update_all(inc: [{disposition_field, amount}, held_cents: -amount])
    end)
  end

  # Contributors to a conversion, in room-accounting funding order with the
  # unattributed senior block first.
  defp funding_contributors(cash_allocations) do
    cash_allocations
    |> Enum.sort_by(&{&1.position, &1.id})
    |> Enum.reduce([], fn alloc, acc ->
      case acc do
        [{payment_operation_id, running} | rest]
        when payment_operation_id == alloc.payment_operation_id ->
          [{payment_operation_id, running + alloc.amount_cents} | rest]

        _acc ->
          [{alloc.payment_operation_id, alloc.amount_cents} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Each contributor's entitlement telescopes: the rounded bonus value of the
  # settled cash through it minus the bonus value through its predecessor. The
  # entitlements telescope exactly to the issued lot.
  defp insert_entitlements(lot, contributors) do
    Enum.reduce(contributors, 0, fn {payment_operation_id, principal}, run ->
      bonus_percent = 100 + @credit_bonus_percent

      entitled =
        percent_half_up(run + principal, bonus_percent) - percent_half_up(run, bonus_percent)

      if is_binary(payment_operation_id) and entitled > 0 do
        Repo.insert!(%LotEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          principal_cents: principal,
          entitled_cents: entitled
        })
      end

      run + principal
    end)

    :ok
  end

  # Applied credit returns to its original lots (a refundable settlement) or is
  # consumed for good (a non-refundable one). The group's application rows for
  # each lot are reduced by the settled amounts either way.
  defp settle_credit(group, credit_allocations, restore?, on) do
    credit_allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, allocs} ->
      amount = sum_amounts(allocs)

      if restore? do
        lot = Repo.get!(CreditLot, lot_id)
        restore_to_lot(lot, amount, on)
      end

      release_application(group.id, lot_id, amount)
    end)
  end

  # Credit returning to a lot extinguishes unrecovered clawback before any
  # amount becomes available; only an excess then becomes available or expires
  # under the existing rules.
  defp restore_to_lot(lot, amount, on) do
    clawbacks =
      from(e in LotEntitlement,
        where: e.credit_lot_id == ^lot.id and e.unrecovered_clawback_cents > 0,
        order_by: [asc: e.id]
      )
      |> Repo.all()

    restored_available =
      Enum.reduce(clawbacks, amount, fn entitlement, left ->
        absorbed = min(entitlement.unrecovered_clawback_cents, left)

        entitlement
        |> change(unrecovered_clawback_cents: entitlement.unrecovered_clawback_cents - absorbed)
        |> Repo.update!()

        left - absorbed
      end)

    if restored_available > 0 and Date.compare(lot.expires_on, on) == :gt do
      from(l in CreditLot, where: l.id == ^lot.id)
      |> Repo.update_all(inc: [remaining_cents: restored_available])
    end
  end

  defp release_application(group_db_id, lot_id, amount) do
    applications =
      from(a in GroupCreditApplication,
        where: a.group_id == ^group_db_id and a.credit_lot_id == ^lot_id,
        order_by: [asc: a.inserted_at]
      )
      |> Repo.all()

    Enum.reduce_while(applications, amount, fn application, left ->
      taken = min(application.amount_cents, left)

      if taken >= application.amount_cents do
        Repo.delete!(application)
      else
        application
        |> change(amount_cents: application.amount_cents - taken)
        |> Repo.update!()
      end

      if left - taken > 0, do: {:cont, left - taken}, else: {:halt, :done}
    end)

    :ok
  end

  defp cancel_group_rooms(group, room_ids, totals) do
    cancelled = MapSet.new(room_ids)
    cancel_room? = fn room -> MapSet.member?(cancelled, room.room_id) end

    updated_rooms =
      Enum.map(group.rooms, fn room ->
        if cancel_room?.(room), do: %{room | status: "cancelled"}, else: room
      end)

    deposit_due_subtotal =
      Enum.sum(
        Enum.map(group.rooms, fn room ->
          if cancel_room?.(room), do: room_deposit_due(group, room), else: 0
        end)
      )

    lodging_subtotal =
      Enum.sum(
        Enum.map(group.rooms, fn room ->
          if cancel_room?.(room), do: room_lodging(group, room), else: 0
        end)
      )

    status =
      if Enum.any?(updated_rooms, &(room_status(&1) == "active")), do: "active", else: "cancelled"

    revision = group.revision + 1

    # Totals describe active rooms. Once the last active room settles, the
    # remaining balances stay as they stood: an accounting fact of the booking
    # whose unpaid deposit is no longer due and whose held cash is no longer
    # counted as held.
    active_fields =
      if status == "active" do
        [
          lodging_total_cents: group.lodging_total_cents - lodging_subtotal,
          deposit_due_cents: group.deposit_due_cents - deposit_due_subtotal,
          deposit_paid_cents:
            max(group.deposit_paid_cents - totals.cash_total - totals.credit_total, 0),
          cash_paid_cents: group.cash_paid_cents - totals.cash_total,
          credit_applied_cents: group.credit_applied_cents - totals.credit_total
        ]
      else
        []
      end

    update_group(
      group,
      Enum.concat([
        [
          rooms: updated_rooms,
          status: status,
          refunded_cents: group.refunded_cents + totals.refunded_cents,
          retained_cents: group.retained_cents + totals.retained_cents,
          converted_to_credit_cents: group.converted_to_credit_cents + totals.converted_cents,
          revision: revision
        ],
        active_fields
      ])
    )

    %{
      cancelled_room_ids: room_ids,
      refunded_cents: totals.refunded_cents,
      retained_cents: totals.retained_cents,
      revision: revision
    }
  end

  defp consume_lots_and_apply(operation_id, cmd, group, amount_cents) do
    lots = available_lots(group.guest_id, cmd.occurred_on)
    available_cents = Enum.sum(Enum.map(lots, & &1.remaining_cents))

    if available_cents < amount_cents do
      reject(operation_id, "insufficient_credit", group.group_id)
    else
      take_lots(lots, amount_cents, group)
      outstanding_before = outstanding_deposit(group)
      revision = group.revision + 1

      update_group(group,
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        credit_applied_cents: group.credit_applied_cents + amount_cents,
        revision: revision
      )

      applied(operation_id, %{
        "group_id" => group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => outstanding_before - amount_cents,
        "revision" => revision
      })
    end
  end

  # Consumes lots in expiry order, recording which lots funded the group so a
  # later refundable cancellation can restore them, and allocates the credit
  # across the active rooms' deposits.
  defp take_lots(_lots, taken, _group) when taken <= 0, do: :ok

  defp take_lots([lot | rest], taken, group) do
    amount = min(taken, lot.remaining_cents)

    if amount > 0 do
      from(l in CreditLot, where: l.id == ^lot.id)
      |> Repo.update_all(set: [remaining_cents: lot.remaining_cents - amount])

      Repo.insert!(%GroupCreditApplication{
        group_id: group.id,
        credit_lot_id: lot.id,
        amount_cents: amount
      })

      fund_active_rooms(
        group,
        %{
          kind: "credit",
          payment_operation_id: nil,
          credit_lot_id: lot.id
        },
        amount
      )

      take_lots(rest, taken - amount, group)
    else
      take_lots(rest, taken, group)
    end
  end

  # -- Funding allocation --------------------------------------------------------

  # Moves held funding between two active groups of the same guest: draws from
  # the source's allocations most recently created first regardless of kind,
  # refills the destination's active rooms in their original order preserving
  # the draw order, and keeps every moved unit's provenance. Nothing settles or
  # revalues; only the room-level holding changes.
  defp transfer_held_funding(operation_id, source, destination, amount_cents) do
    allocations =
      from(a in Allocation,
        where: a.group_id == ^source.id,
        order_by: [desc: a.position, desc: a.id]
      )
      |> Repo.all()

    {chunks, _left} = draw_allocations(allocations, amount_cents)

    Enum.each(chunks, fn {alloc, taken} ->
      remove_from_allocation(alloc, taken)

      fund_active_rooms(
        destination,
        %{
          kind: alloc.kind,
          payment_operation_id: alloc.payment_operation_id,
          credit_lot_id: alloc.credit_lot_id
        },
        taken
      )

      cond do
        alloc.kind == "credit" and is_binary(alloc.credit_lot_id) ->
          move_credit_application(source, destination, alloc.credit_lot_id, taken)

        alloc.kind == "cash" and is_binary(alloc.payment_operation_id) ->
          mark_payment_transferred(alloc.payment_operation_id)

        true ->
          :ok
      end
    end)

    cash_moved =
      chunks
      |> Enum.filter(fn {alloc, _taken} -> alloc.kind == "cash" end)
      |> sum_chunks()

    credit_moved = amount_cents - cash_moved

    source_revision = source.revision + 1
    destination_revision = destination.revision + 1

    source =
      update_group(source,
        deposit_paid_cents: source.deposit_paid_cents - amount_cents,
        cash_paid_cents: source.cash_paid_cents - cash_moved,
        credit_applied_cents: source.credit_applied_cents - credit_moved,
        revision: source_revision
      )

    destination =
      update_group(destination,
        deposit_paid_cents: destination.deposit_paid_cents + amount_cents,
        cash_paid_cents: destination.cash_paid_cents + cash_moved,
        credit_applied_cents: destination.credit_applied_cents + credit_moved,
        revision: destination_revision
      )

    applied(operation_id, %{
      "source_group_id" => source.group_id,
      "destination_group_id" => destination.group_id,
      "amount_cents" => amount_cents,
      "source_outstanding_deposit_cents" => outstanding_deposit(source),
      "destination_outstanding_deposit_cents" => outstanding_deposit(destination),
      "source_revision" => source_revision,
      "destination_revision" => destination_revision
    })
  end

  # Cash and hotel credit currently allocated to the group's active rooms.
  defp held_funding(group) do
    from(a in Allocation, where: a.group_id == ^group.id, select: sum(a.amount_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp draw_allocations(allocations, amount), do: draw_allocations(allocations, amount, [])

  defp draw_allocations(_allocations, left, chunks) when left <= 0,
    do: {Enum.reverse(chunks), left}

  defp draw_allocations([], left, chunks), do: {Enum.reverse(chunks), left}

  defp draw_allocations([alloc | rest], left, chunks) do
    taken = min(left, alloc.amount_cents)
    draw_allocations(rest, left - taken, [{alloc, taken} | chunks])
  end

  defp sum_chunks(chunks), do: Enum.sum(Enum.map(chunks, fn {_alloc, taken} -> taken end))

  defp remove_from_allocation(%{amount_cents: amount} = alloc, taken) when taken >= amount,
    do: Repo.delete!(alloc)

  defp remove_from_allocation(alloc, taken),
    do: alloc |> change(amount_cents: alloc.amount_cents - taken) |> Repo.update!()

  # Applied credit moving between groups carries its application record along,
  # so the destination restores it to the same original lot on settlement.
  defp move_credit_application(source, destination, lot_id, amount) do
    release_application(source.id, lot_id, amount)

    case Repo.get_by(GroupCreditApplication, group_id: destination.id, credit_lot_id: lot_id) do
      nil ->
        Repo.insert!(%GroupCreditApplication{
          group_id: destination.id,
          credit_lot_id: lot_id,
          amount_cents: amount
        })

      application ->
        application
        |> change(amount_cents: application.amount_cents + amount)
        |> Repo.update!()
    end

    :ok
  end

  defp mark_payment_transferred(payment_operation_id) do
    from(cp in CashPayment, where: cp.operation_id == ^payment_operation_id)
    |> Repo.update_all(set: [transferred: true])

    :ok
  end

  # Allocates a funding unit across the active rooms' deposits in the rooms'
  # original order, filling one room's deposit before moving to the next.
  defp fund_active_rooms(group, unit_attrs, amount_cents) do
    allocated = allocated_by_room(group.id)

    balances =
      Enum.map(active_rooms(group), fn room ->
        paid = Map.get(allocated, room.room_id, 0)
        %{room_id: room.room_id, outstanding: max(room_deposit_due(group, room) - paid, 0)}
      end)

    position = next_position(group.id)
    {rows, _remaining} = fill_room_balances(balances, amount_cents)

    Enum.each(rows, fn {room_id, taken} ->
      Repo.insert!(%Allocation{
        group_id: group.id,
        room_id: room_id,
        kind: unit_attrs.kind,
        position: position,
        amount_cents: taken,
        payment_operation_id: unit_attrs.payment_operation_id,
        credit_lot_id: unit_attrs.credit_lot_id
      })
    end)

    :ok
  end

  defp allocated_by_room(group_id) do
    from(a in Allocation,
      where: a.group_id == ^group_id,
      select: {a.room_id, a.amount_cents}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {room_id, amount}, acc ->
      Map.update(acc, room_id, amount, &(&1 + amount))
    end)
  end

  # Funding units allocate in operation-processing order within the group.
  defp next_position(group_id) do
    from(a in Allocation, where: a.group_id == ^group_id, select: max(a.position))
    |> Repo.one()
    |> Kernel.||(-1)
    |> Kernel.+(1)
  end

  defp fill_room_balances(balances, amount, taken \\ [])

  defp fill_room_balances([], _amount, taken), do: {Enum.reverse(taken), []}

  defp fill_room_balances([room | rest], amount, taken) do
    taken_from_room = min(max(amount, 0), room.outstanding)

    {rows, remaining} =
      if taken_from_room > 0 do
        fill_room_balances(rest, amount - taken_from_room, [
          {room.room_id, taken_from_room} | taken
        ])
      else
        fill_room_balances(rest, amount, taken)
      end

    {rows,
     [
       %{room_id: room.room_id, outstanding: room.outstanding - taken_from_room} | remaining
     ]}
  end

  defp sum_amounts(allocations),
    do: Enum.sum(Enum.map(allocations, & &1.amount_cents))

  defp update_group(group, fields), do: group |> change(fields) |> Repo.update!()

  # -- Group construction -------------------------------------------------------

  defp new_group(fields) do
    nights = Date.diff(fields.departure_on, fields.arrival_on)

    lodging_total_cents =
      fields.rooms
      |> Enum.map(&(&1.nightly_rate_cents * nights))
      |> Enum.sum()

    deposit_due_cents =
      fields.rooms
      |> Enum.map(&room_deposit(&1.nightly_rate_cents * nights, fields.rate_plan))
      |> Enum.sum()

    %Group{
      group_id: fields.group_id,
      guest_id: fields.guest_id,
      property_id: fields.property_id,
      rate_plan: fields.rate_plan,
      status: "active",
      revision: 1,
      booked_on: fields.occurred_on,
      arrival_on: fields.arrival_on,
      departure_on: fields.departure_on,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      rooms: fields.rooms
    }
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp room_deposit(lodging_cents, "flexible"),
    do: percent_half_up(lodging_cents, @flexible_deposit_percent)

  # Rounds amount * percent / 100 to the nearest cent; an exact half-cent rounds up.
  defp percent_half_up(amount_cents, percent) do
    div(amount_cents * percent * 2 + 100, 200)
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  # -- Validation helpers ---------------------------------------------------------

  defp stale_revision?(_group, nil), do: false
  defp stale_revision?(group, expected_revision), do: expected_revision != group.revision

  defp require_fields(operation, fields) do
    if Enum.any?(fields, &is_nil(Map.get(operation, &1))) do
      {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}
    else
      :ok
    end
  end

  defp identifiers(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, guest_id} <- identifier(operation, "guest_id"),
         {:ok, property_id} <- identifier(operation, "property_id") do
      {:ok, %{group_id: group_id, guest_id: guest_id, property_id: property_id}}
    end
  end

  defp identifier(operation, field) do
    case Map.get(operation, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}
    end
  end

  defp operation_date(operation) do
    case date_value(Map.get(operation, "occurred_on")) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, reject(Map.get(operation, "operation_id"), "invalid_operation")}
    end
  end

  defp stay_date(operation_id, group_id, value) do
    case date_value(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, reject(operation_id, "invalid_stay", group_id)}
    end
  end

  defp date_value(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp date_value(_value), do: :error

  defp stay_order(operation_id, group_id, arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt do
      :ok
    else
      {:error, reject(operation_id, "invalid_stay", group_id)}
    end
  end

  defp move_after(operation_id, group_id, new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, reject(operation_id, "invalid_stay", group_id)}
    end
  end

  defp rooms(operation_id, group_id, rooms) when is_list(rooms) do
    parsed_rooms = Enum.map(rooms, &parse_room/1)
    room_ids = Enum.map(parsed_rooms, fn room -> room && room.room_id end)

    unique_room_ids? = length(Enum.uniq(room_ids)) == length(room_ids)

    if parsed_rooms != [] and not Enum.any?(parsed_rooms, &is_nil/1) and unique_room_ids? do
      {:ok, parsed_rooms}
    else
      {:error, reject(operation_id, "invalid_rooms", group_id)}
    end
  end

  defp rooms(operation_id, group_id, _other),
    do: {:error, reject(operation_id, "invalid_rooms", group_id)}

  defp parse_room(room) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate_cents = room["nightly_rate_cents"]

    if is_binary(room_id) and room_id != "" and usable_amount?(nightly_rate_cents) do
      %Room{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
    end
  end

  defp parse_room(_room), do: nil

  defp rate_plan(_operation_id, _group_id, rate_plan) when rate_plan in @rate_plans, do: :ok

  defp rate_plan(operation_id, group_id, _other),
    do: {:error, reject(operation_id, "invalid_rate_plan", group_id)}

  defp usable_amount?(amount_cents),
    do: is_integer(amount_cents) and not is_boolean(amount_cents) and amount_cents > 0

  # -- Result helpers ---------------------------------------------------------------

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, outcome} -> outcome
      {:error, rejection} -> rejection
    end
  end

  defp applied(operation_id, fields) do
    Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)
  end

  defp reject(operation_id, code, group_id \\ nil, extra \\ []) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    |> maybe_put_group_id(group_id)
    |> Map.merge(Map.new(extra))
  end

  defp maybe_put_group_id(result, nil), do: result
  defp maybe_put_group_id(result, group_id), do: Map.put(result, "group_id", group_id)
end
