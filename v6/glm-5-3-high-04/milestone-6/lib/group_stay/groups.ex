defmodule GroupStay.Groups do
  @moduledoc """
  The group-deposit domain.

  Partner gateways submit batches of reservation and payment operations. This
  context applies each operation in order, reports the outcome of every one,
  and keeps the deposit records needed by support and finance.

  Deposits are funded with cash or with hotel credit. Funding fills the
  active rooms' deposits in their original order, one room at a time, and is
  attributed room by room and payment by payment so selected rooms can be
  settled, recorded cash can be reduced, and payments can be charged back.
  Hotel credit is issued as lots, for example when a refundable cancellation
  is settled as credit instead of a cash refund, and applied lots are tracked
  so their credit can be restored if the group is later cancelled while
  refundable.

  Part of an applied deposit can move between two active groups of the same
  guest with a deposit transfer. The moved funding keeps its provenance —
  cash keeps its payment identity and credit keeps its lot — so later
  settlements, reductions, and chargebacks follow it wherever it currently
  funds rooms.

  Finance reporting starts once, with a `start_finance_reporting`
  operation. From then on every applied operation records signed finance
  movements (see `GroupStay.Finance`) posted on the later of its
  `occurred_on` and the reporting start date, and the daily finance report
  explains how held cash and hotel-credit liability moved on each day.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Credit.Lot
  alias GroupStay.Finance
  alias GroupStay.Groups.Accounting
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.PaymentRecord
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @known_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit start_finance_reporting)
  @rate_plans ~w(flexible advance_purchase)

  @policy_cutoff_date ~D[2027-01-01]
  @policy_window_days %{"flex-14" => 14, "flex-30" => 30}
  @advance_policy_version "advance-nonrefundable"

  @refund_methods ~w(cash hotel_credit)

  @doc """
  Applies a partner batch. Operations are processed in array order and each
  one observes changes made by earlier operations in the same batch.

  Every operation carrying a usable `operation_id` is durably idempotent: its
  result is remembered on first submission and an exact retry receives the
  original result without reading or changing current domain state. Reusing an
  identifier with a different payload is rejected with
  `operation_id_conflict`. An unexpected exception rolls back the current
  operation, is not remembered, and aborts the batch.

  Returns `{:ok, results}` with one result per operation, or
  `{:error, :invalid_batch}` when the payload has no operations array.
  """
  def process_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def process_batch(_other), do: {:error, :invalid_batch}

  @doc """
  Fetches the remembered result of an operation by its partner identifier.

  Returns `{:ok, result}` with the exact result returned for the first
  submission, or `{:error, :operation_not_found}` when the identifier was
  never durably recorded.
  """
  def fetch_operation(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      %Operation{} = record -> {:ok, Jason.decode!(record.result)}
    end
  end

  @doc """
  Fetches a group by its partner identifier, rendered for the read API.

  Rooms appear in their original order with their lodging and deposit
  amounts and the cash and credit funding them; the group's lodging, due,
  paid, and outstanding totals describe the active rooms only.
  """
  def fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, render_group(group)}
    end
  end

  @doc """
  The reconciliation statement of one durably recorded, applied cash payment.

  Returns `{:ok, statement}` with the current disposition of cash from that
  payment, `{:error, :operation_not_found}` when no durable operation record
  exists, or `{:error, :payment_not_reconcilable}` when the record exists but
  is not an applied cash payment. Reading a statement never changes state.
  """
  def payment_statement(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %Operation{} = record ->
        if Accounting.applied_cash_payment?(record) do
          {:ok, Accounting.statement(record)}
        else
          {:error, :payment_not_reconcilable}
        end
    end
  end

  @doc """
  Finance totals for cash held on active reservations, cash moved out of them
  by cancellation settlements and provider corrections, and the outstanding
  hotel-credit liability.

  Expiry is reported as of `as_on`.
  """
  def ledger_totals(as_on \\ Date.utc_today()) do
    %{
      "cash_held_cents" =>
        Repo.one(
          from g in Group,
            where: g.status == "active",
            select: coalesce(sum(g.deposit_paid_cents - g.credit_paid_cents), 0)
        ),
      "cash_refunded_cents" =>
        Repo.one(from g in Group, select: coalesce(sum(g.refunded_cents), 0)),
      "cash_retained_cents" =>
        Repo.one(from g in Group, select: coalesce(sum(g.retained_cents), 0)),
      "cash_converted_to_credit_cents" =>
        Repo.one(from g in Group, select: coalesce(sum(g.cash_converted_cents), 0)),
      "cash_reduced_cents" =>
        Repo.one(from p in PaymentRecord, select: coalesce(sum(p.reduced_cents), 0)),
      "cash_charged_back_cents" =>
        Repo.one(from p in PaymentRecord, select: coalesce(sum(p.charged_back_cents), 0)),
      "credit_shortfall_cents" => Accounting.credit_shortfall_cents(),
      "credit_liability_cents" => credit_liability_cents(as_on)
    }
  end

  @doc """
  Credit available to a guest as of `as_on`, rendered for the read API.

  Expired and exhausted lots are omitted. Lots are ordered by `expires_on`,
  then by `source_operation_id`.
  """
  def guest_credit(guest_id, as_on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from l in Lot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum_by(lots, & &1.remaining_cents),
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

  @doc """
  Resolves the optional `on=YYYY-MM-DD` read parameter to a date, defaulting
  to the current UTC date.
  """
  def resolve_as_on(nil), do: {:ok, Date.utc_today()}

  def resolve_as_on(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  def resolve_as_on(_), do: {:error, :invalid_date}

  # Batch processing

  # Each operation runs in one immediate transaction so that domain changes
  # and the idempotency record commit together; concurrent retries of the
  # same identifier therefore have at-most-once effects. A handled rejection
  # rolls the transaction back, leaving domain state unchanged, and its
  # idempotency record is then committed on its own.
  defp process_operation(op) when is_map(op) do
    operation_id = op["operation_id"]

    if is_binary(operation_id) and String.trim(operation_id) != "" do
      case Repo.transaction(fn -> apply_remembered(op, operation_id) end, mode: :immediate) do
        {:ok, result} ->
          result

        {:error, {:rejected, result}} ->
          remember(op, operation_id, result)
          result

        {:error, :operation_id_conflict} ->
          rejected(operation_id, "operation_id_conflict")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_other), do: rejected(nil, "invalid_operation")

  defp apply_remembered(op, operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        case apply_operation(op, operation_id) do
          {:ok, result} ->
            remember(op, operation_id, result)
            result

          {:error, code} ->
            Repo.rollback({:rejected, rejected(operation_id, code)})

          {:error, code, extra} ->
            Repo.rollback({:rejected, rejected(operation_id, code, extra)})
        end

      %Operation{} = record ->
        if record.payload == canonical_json(op) do
          Jason.decode!(record.result)
        else
          Repo.rollback(:operation_id_conflict)
        end
    end
  end

  defp remember(op, operation_id, result) do
    Repo.insert!(%Operation{
      operation_id: operation_id,
      type: remember_type(op["type"]),
      payload: canonical_json(op),
      result: Jason.encode!(result)
    })
  end

  defp apply_operation(op, operation_id) do
    with :ok <- ensure_known_type(op),
         {:ok, occurred_on} <- parse_date(op["occurred_on"], :invalid_operation) do
      case op["type"] do
        "open_group" -> open_group(op, operation_id, occurred_on)
        "record_cash_payment" -> record_cash_payment(op, operation_id, occurred_on)
        "reschedule_group" -> reschedule_group(op, operation_id, occurred_on)
        "cancel_group" -> cancel_group(op, operation_id, occurred_on)
        "apply_hotel_credit" -> apply_hotel_credit(op, operation_id, occurred_on)
        "cancel_rooms" -> cancel_rooms(op, operation_id, occurred_on)
        "reduce_cash_payment" -> reduce_cash_payment(op, operation_id, occurred_on)
        "charge_back_payment" -> charge_back_payment(op, operation_id, occurred_on)
        "transfer_deposit" -> transfer_deposit(op, operation_id, occurred_on)
        "start_finance_reporting" -> start_finance_reporting(op, operation_id)
      end
    end
  end

  defp ensure_known_type(%{"type" => type}) when type in @known_types, do: :ok
  defp ensure_known_type(_op), do: {:error, :invalid_operation}

  # The audit record retains the operation's type; non-binary type values are
  # only part of the retained submission.
  defp remember_type(type) when is_binary(type), do: type
  defp remember_type(_type), do: nil

  # Canonical JSON of a decoded payload: object key order is irrelevant, array
  # order and values are significant.
  defp canonical_json(value) when is_map(value) do
    inner =
      value
      |> Enum.map(fn {key, entry} -> Jason.encode!(key) <> ":" <> canonical_json(entry) end)
      |> Enum.sort()
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp rejected(operation_id, code, extra \\ %{}) do
    Map.merge(
      %{"operation_id" => operation_id, "status" => "rejected", "code" => code},
      extra
    )
  end

  # open_group

  defp open_group(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, guest_id} <- require_id(op, "guest_id"),
         {:ok, property_id} <- require_id(op, "property_id"),
         :ok <- ensure_group_is_new(group_id),
         {:ok, arrival_on} <- parse_date(op["arrival_on"], :invalid_stay),
         {:ok, departure_on} <- parse_date(op["departure_on"], :invalid_stay),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(op["rooms"]),
         {:ok, rate_plan} <- validate_rate_plan(op["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)

      room_deposits =
        Enum.map(rooms, &Accounting.room_deposit_cents(&1.nightly_rate_cents * nights, rate_plan))

      lodging_total_cents = Enum.sum_by(rooms, &(&1.nightly_rate_cents * nights))
      deposit_due_cents = Enum.sum(room_deposits)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, occurred_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        allocations_ready: true
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          rooms
          |> Enum.zip(room_deposits)
          |> Enum.with_index()
          |> Enum.each(fn {{room, deposit_due_cents}, index} ->
            Repo.insert!(%Room{
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: index,
              status: "active",
              deposit_due_cents: deposit_due_cents,
              group_id: group.id
            })
          end)

          {:ok,
           %{
             "operation_id" => operation_id,
             "status" => "applied",
             "group_id" => group_id,
             "deposit_due_cents" => deposit_due_cents,
             "revision" => 1
           }}

        {:error, _changeset} ->
          {:error, :group_already_exists}
      end
    end
  end

  defp ensure_group_is_new(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rooms(raw_rooms) when is_list(raw_rooms) and raw_rooms != [] do
    raw_rooms
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case validate_room(raw, acc) do
        {:ok, room} -> {:cont, {:ok, [room | acc]}}
        {:error, :invalid_rooms} -> {:halt, {:error, :invalid_rooms}}
      end
    end)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      {:error, :invalid_rooms} = error -> error
    end
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp validate_room(raw, accepted) do
    with true <- is_map(raw),
         room_id when is_binary(room_id) and room_id != "" <- raw["room_id"],
         rate when is_integer(rate) and rate >= 0 <- raw["nightly_rate_cents"],
         false <- Enum.any?(accepted, &(&1.room_id == room_id)) do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
    else
      _ -> {:error, :invalid_rooms}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_), do: {:error, :invalid_rate_plan}

  # record_cash_payment

  defp record_cash_payment(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      group = Accounting.materialize!(group)
      Accounting.insert_payment_record!(group, operation_id, amount_cents)
      Accounting.allocate_cash!(group, operation_id, amount_cents)
      Finance.record_cash_payment!(group.property_id, operation_id, amount_cents, occurred_on)
      group = Accounting.refresh_group_totals!(group)
      new_revision = group.revision + 1

      Repo.update!(change(group, revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit_cents(group),
         "revision" => new_revision
       }}
    end
  end

  defp validate_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp validate_amount(_), do: {:error, :invalid_amount}

  defp ensure_within_outstanding(group, amount_cents) do
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    if amount_cents <= outstanding do
      :ok
    else
      {:error, :payment_exceeds_outstanding}
    end
  end

  # reschedule_group

  defp reschedule_group(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- parse_date(op["new_arrival_on"], :invalid_stay),
         :ok <- ensure_after(new_arrival_on, occurred_on) do
      shift_days = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift_days)
      new_refundable_until = refundable_until(%{group | arrival_on: new_arrival_on})
      new_revision = group.revision + 1

      Repo.update!(
        change(group,
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: new_revision
        )
      )

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "policy_version" => group.policy_version,
         "refundable_until" => render_date(new_refundable_until),
         "revision" => new_revision
       }}
    end
  end

  defp ensure_after(date, reference_date) do
    if Date.compare(date, reference_date) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  # cancel_group

  defp cancel_group(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- validate_refund_method(op["refund_method"]),
         :ok <- ensure_refund_method_available(refund_method, group, occurred_on) do
      group = Accounting.materialize!(group)
      refundable? = refundable?(group, occurred_on)

      {group, refunded_cents, retained_cents, _converted_cents, credit_issued_cents, effects} =
        Accounting.settle_rooms!(
          group,
          Accounting.active_rooms(group),
          refundable?,
          refund_method,
          operation_id,
          occurred_on
        )

      Finance.record_settlement!(group.property_id, operation_id, effects, occurred_on)

      group = Accounting.refresh_group_totals!(group)
      new_revision = group.revision + 1

      Repo.update!(change(group, status: "cancelled", revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => new_revision
       }}
    end
  end

  # cancel_rooms

  defp cancel_rooms(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, rooms} <- validate_room_selection(group, op["room_ids"]),
         {:ok, refund_method} <- validate_refund_method(op["refund_method"]),
         :ok <- ensure_refund_method_available(refund_method, group, occurred_on) do
      group = Accounting.materialize!(group)
      refundable? = refundable?(group, occurred_on)

      # The selected rooms settle in the group's original room order,
      # regardless of the order supplied by the caller.
      ordered_rooms = Enum.sort_by(rooms, & &1.position)

      {group, refunded_cents, retained_cents, _converted_cents, credit_issued_cents, effects} =
        Accounting.settle_rooms!(
          group,
          ordered_rooms,
          refundable?,
          refund_method,
          operation_id,
          occurred_on
        )

      Finance.record_settlement!(group.property_id, operation_id, effects, occurred_on)

      group = Accounting.refresh_group_totals!(group)
      new_revision = group.revision + 1

      new_status =
        if Accounting.active_rooms(group) == [], do: "cancelled", else: group.status

      Repo.update!(change(group, status: new_status, revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "cancelled_room_ids" => Enum.map(ordered_rooms, & &1.room_id),
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => new_revision
       }}
    end
  end

  # All supplied room identifiers must identify distinct, active rooms in
  # the group.
  defp validate_room_selection(group, room_ids)
       when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &is_binary/1) and
         length(Enum.uniq(room_ids)) == length(room_ids) do
      rooms = Repo.all(from r in Room, where: r.group_id == ^group.id)
      by_room_id = Map.new(rooms, &{&1.room_id, &1})

      selected = Enum.map(room_ids, &Map.get(by_room_id, &1))

      if Enum.all?(selected, &is_struct(&1, Room)) and
           Enum.all?(selected, &Accounting.room_active?(&1, group)) do
        {:ok, selected}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_room_selection(_group, _room_ids), do: {:error, :invalid_rooms}

  defp validate_refund_method(nil), do: {:ok, "cash"}

  defp validate_refund_method(refund_method) when refund_method in @refund_methods,
    do: {:ok, refund_method}

  defp validate_refund_method(_), do: {:error, :invalid_operation}

  # Hotel credit is not a way around a non-refundable policy.
  defp ensure_refund_method_available("hotel_credit", group, occurred_on) do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, :refund_method_not_available}
    end
  end

  defp ensure_refund_method_available(_refund_method, _group, _occurred_on), do: :ok

  # apply_hotel_credit

  defp apply_hotel_credit(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_credit_available(group.guest_id, amount_cents, occurred_on),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      group = Accounting.materialize!(group)
      Accounting.allocate_credit!(group, operation_id, amount_cents, occurred_on)
      group = Accounting.refresh_group_totals!(group)
      new_revision = group.revision + 1

      Repo.update!(change(group, revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit_cents(group),
         "revision" => new_revision
       }}
    end
  end

  defp ensure_credit_available(guest_id, amount_cents, as_on) do
    if amount_cents <= credit_available(guest_id, as_on) do
      :ok
    else
      {:error, :insufficient_credit}
    end
  end

  defp credit_available(guest_id, as_on) do
    Repo.one(
      from l in Lot,
        where: l.guest_id == ^guest_id and l.expires_on > ^as_on,
        select: coalesce(sum(l.remaining_cents), 0)
    )
  end

  # reduce_cash_payment

  defp reduce_cash_payment(op, operation_id, occurred_on) do
    with {:ok, target_id} <- require_id(op, "payment_operation_id"),
         {:ok, target} <- fetch_operation_record(target_id),
         {:ok, group} <- payment_target_group(target),
         :ok <- check_revision(op, group),
         :ok <- ensure_reducible(target),
         {:ok, amount_cents} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_held(target, amount_cents) do
      group = Accounting.materialize!(group)
      {group, removed_per_property} = Accounting.reduce_payment!(group, target_id, amount_cents)

      Finance.record_reduction!(removed_per_property, target_id, operation_id, occurred_on)

      new_revision = group.revision + 1

      Repo.update!(change(group, revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "payment_operation_id" => target_id,
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit_cents(group),
         "revision" => new_revision
       }}
    end
  end

  # The addressed group is the original payment's group; a target that is
  # not an applied cash payment has no group to check.
  defp payment_target_group(target) do
    if Accounting.applied_cash_payment?(target) do
      fetch_group_record(Accounting.payment_group_id(target))
    else
      {:ok, nil}
    end
  end

  defp fetch_operation_record(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      %Operation{} = record -> {:ok, record}
    end
  end

  # A target that can never accept a positive reduction: a non-payment
  # operation, a rejected payment, or an applied payment with no held cash
  # remaining.
  defp ensure_reducible(target) do
    if Accounting.applied_cash_payment?(target) and Accounting.payment_held_cents(target) > 0 do
      :ok
    else
      {:error, :payment_not_reducible}
    end
  end

  defp ensure_within_held(target, amount_cents) do
    if amount_cents <= Accounting.payment_held_cents(target) do
      :ok
    else
      {:error, :reduction_exceeds_held_cash}
    end
  end

  # charge_back_payment

  defp charge_back_payment(op, operation_id, occurred_on) do
    with {:ok, target_id} <- require_id(op, "payment_operation_id"),
         {:ok, target} <- fetch_operation_record(target_id),
         {:ok, group} <- payment_target_group(target),
         :ok <- check_revision(op, group),
         :ok <- ensure_chargeable(target) do
      group = Accounting.materialize!(group)

      # The dispositions reversed by the chargeback, captured before it
      # reclassifies them.
      {refunded_cents, retained_cents, converted_cents, _reduced_cents, _charged_back_cents} =
        Accounting.payment_dispositions(target)

      {group, charged_back_cents, held_removed, entitlement_removals} =
        Accounting.charge_back!(group, target_id)

      Finance.record_chargeback!(
        group.property_id,
        target_id,
        operation_id,
        %{
          held_removed: held_removed,
          entitlement_removals: entitlement_removals,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          converted_cents: converted_cents
        },
        occurred_on
      )

      new_revision = group.revision + 1

      Repo.update!(change(group, revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "payment_operation_id" => target_id,
         "group_id" => group.group_id,
         "charged_back_cents" => charged_back_cents,
         "outstanding_deposit_cents" => outstanding_deposit_cents(group),
         "revision" => new_revision
       }}
    end
  end

  # A record that exists but is not an applied cash payment, a payment that
  # has been fully reduced, or a payment already charged back.
  defp ensure_chargeable(target) do
    if Accounting.applied_cash_payment?(target) do
      {_, _, _, reduced_cents, charged_back_cents} = Accounting.payment_dispositions(target)
      amount_cents = Jason.decode!(target.result)["amount_cents"]

      if charged_back_cents > 0 or reduced_cents >= amount_cents do
        {:error, :payment_not_chargeable}
      else
        :ok
      end
    else
      {:error, :payment_not_chargeable}
    end
  end

  # transfer_deposit

  # Moves part of the applied deposit between two active groups of the same
  # guest without moving money through a provider. Source existence is
  # resolved first, then destination existence; after both exist, the source
  # revision is checked and then the destination revision, before the
  # transfer rules.
  defp transfer_deposit(op, operation_id, occurred_on) do
    with {:ok, source_group_id} <- require_id(op, "source_group_id"),
         {:ok, destination_group_id} <- require_id(op, "destination_group_id"),
         {:ok, source} <- fetch_transfer_group(source_group_id),
         {:ok, destination} <- fetch_transfer_group(destination_group_id),
         :ok <- check_revision(op, source),
         :ok <- check_revision(op, destination, "destination_expected_revision"),
         :ok <- ensure_transferable(source, destination),
         :ok <- ensure_transfer_active(source),
         :ok <- ensure_transfer_active(destination),
         {:ok, amount_cents} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_enough_held_funding(source, amount_cents),
         :ok <- ensure_transfer_within_outstanding(destination, amount_cents) do
      source = Accounting.materialize!(source)
      destination = Accounting.materialize!(destination)

      {source, destination, transferred_cash_cents} =
        Accounting.transfer!(source, destination, amount_cents)

      Finance.record_transfer!(
        source.property_id,
        destination.property_id,
        operation_id,
        transferred_cash_cents,
        occurred_on
      )

      source_revision = source.revision + 1
      destination_revision = destination.revision + 1

      Repo.update!(change(source, revision: source_revision))
      Repo.update!(change(destination, revision: destination_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "source_group_id" => source.group_id,
         "destination_group_id" => destination.group_id,
         "amount_cents" => amount_cents,
         "source_outstanding_deposit_cents" => outstanding_deposit_cents(source),
         "destination_outstanding_deposit_cents" => outstanding_deposit_cents(destination),
         "source_revision" => source_revision,
         "destination_revision" => destination_revision
       }}
    end
  end

  defp fetch_transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found, %{"group_id" => group_id}}
      group -> {:ok, group}
    end
  end

  # The groups must be distinct and belong to the same guest.
  defp ensure_transferable(source, destination) do
    if source.group_id != destination.group_id and source.guest_id == destination.guest_id do
      :ok
    else
      {:error, :invalid_transfer}
    end
  end

  defp ensure_transfer_active(group) do
    if group.status == "active" do
      :ok
    else
      {:error, :group_not_active, %{"group_id" => group.group_id}}
    end
  end

  # Held funding is the cash and hotel credit currently allocated to the
  # source's active rooms.
  defp ensure_enough_held_funding(source, amount_cents) do
    if amount_cents <= source.deposit_paid_cents do
      :ok
    else
      {:error, :transfer_exceeds_held_funding}
    end
  end

  defp ensure_transfer_within_outstanding(destination, amount_cents) do
    outstanding = destination.deposit_due_cents - destination.deposit_paid_cents

    if amount_cents <= outstanding do
      :ok
    else
      {:error, :transfer_exceeds_outstanding}
    end
  end

  # start_finance_reporting

  # The durable reporting inception point. It does not address a group and
  # has no revision guard: the first applied start operation enables
  # reporting, and the financial state immediately before it is processed
  # becomes the opening position on starts_on.
  defp start_finance_reporting(op, operation_id) do
    with {:ok, starts_on} <- parse_date(op["starts_on"], :invalid_reporting_date),
         :ok <- ensure_reporting_not_started() do
      Finance.start_reporting!(starts_on)

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "starts_on" => Date.to_iso8601(starts_on)
       }}
    end
  end

  defp ensure_reporting_not_started do
    if Finance.reporting_started?() do
      {:error, :reporting_already_started}
    else
      :ok
    end
  end

  # Credit liability is the credit still owed to guests: unexpired lot
  # balances plus credit currently applied to active groups (whose expiry is
  # paused while it funds the group), including credit covered by a current
  # shortfall.
  defp credit_liability_cents(as_on) do
    lot_cents =
      Repo.one(
        from l in Lot,
          where: l.expires_on > ^as_on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.credit_paid_cents), 0)
      )

    lot_cents + applied_cents
  end

  # Shared helpers

  defp fetch_group_record(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_revision(op, group, key \\ "expected_revision")

  defp check_revision(_op, nil, _key), do: :ok

  defp check_revision(op, group, key) do
    case op do
      %{^key => expected} when expected != nil ->
        if expected == group.revision do
          :ok
        else
          {:error, :stale_revision,
           %{
             "group_id" => group.group_id,
             "expected_revision" => expected,
             "actual_revision" => group.revision
           }}
        end

      _ ->
        :ok
    end
  end

  defp ensure_active(group) do
    if group.status == "active", do: :ok, else: {:error, :group_not_active}
  end

  defp require_id(op, key) do
    case op[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp parse_date(value, error_code) do
    case value do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, error_code}
        end

      _ ->
        {:error, error_code}
    end
  end

  # Policy versions

  defp policy_version("advance_purchase", _booked_on), do: @advance_policy_version

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff_date) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable?(group, occurred_on) do
    case @policy_window_days[group.policy_version] do
      nil -> false
      window -> Date.diff(group.arrival_on, occurred_on) >= window
    end
  end

  defp refundable_until(%{policy_version: @advance_policy_version}), do: nil

  defp refundable_until(group),
    do: Date.add(group.arrival_on, -@policy_window_days[group.policy_version])

  # Read rendering

  defp render_group(group) do
    rooms = Accounting.room_views(group)
    active_rooms = Enum.filter(rooms, &(&1["status"] == "active"))

    lodging_total_cents = Enum.sum_by(active_rooms, & &1["lodging_total_cents"])
    deposit_due_cents = Enum.sum_by(active_rooms, & &1["deposit_due_cents"])
    cash_paid_cents = Enum.sum_by(active_rooms, & &1["cash_paid_cents"])
    credit_paid_cents = Enum.sum_by(active_rooms, & &1["credit_paid_cents"])

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => group |> refundable_until() |> render_date(),
      "status" => group.status,
      "rooms" => rooms,
      "lodging_total_cents" => lodging_total_cents,
      "deposit_due_cents" => deposit_due_cents,
      "deposit_paid_cents" => cash_paid_cents + credit_paid_cents,
      "cash_paid_cents" => cash_paid_cents,
      "credit_paid_cents" => credit_paid_cents,
      "outstanding_deposit_cents" =>
        if(group.status == "cancelled",
          do: 0,
          else: deposit_due_cents - cash_paid_cents - credit_paid_cents
        )
    }
  end

  defp render_date(nil), do: nil
  defp render_date(date), do: Date.to_iso8601(date)

  defp outstanding_deposit_cents(%{status: "cancelled"}), do: 0

  defp outstanding_deposit_cents(group),
    do: group.deposit_due_cents - group.deposit_paid_cents
end
