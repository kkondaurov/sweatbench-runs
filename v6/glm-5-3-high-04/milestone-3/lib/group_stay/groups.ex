defmodule GroupStay.Groups do
  @moduledoc """
  The group-deposit domain.

  Partner gateways submit batches of reservation and payment operations. This
  context applies each operation in order, reports the outcome of every one,
  and keeps the deposit records needed by support and finance.

  Deposits can be funded with cash or with hotel credit. Hotel credit is issued
  as lots, for example when a refundable cancellation is settled as credit
  instead of a cash refund, and applied lots are tracked so their credit can be
  restored if the group is later cancelled while refundable.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Credit.Application, as: CreditApplication
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @known_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20

  @policy_cutoff_date ~D[2027-01-01]
  @policy_window_days %{"flex-14" => 14, "flex-30" => 30}
  @advance_policy_version "advance-nonrefundable"

  @refund_methods ~w(cash hotel_credit)
  @credit_bonus_percent 10
  # Credit is available through the day 365 days after cancellation and expires
  # the following day.
  @credit_validity_days 365
  @credit_expiry_day_offset @credit_validity_days + 1

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
  """
  def fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, render_group(Repo.preload(group, :rooms))}
    end
  end

  @doc """
  Finance totals for cash held on active reservations, cash moved out of them
  by cancellation settlements, and the outstanding hotel-credit liability.

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
        "record_cash_payment" -> record_cash_payment(op, operation_id)
        "reschedule_group" -> reschedule_group(op, operation_id, occurred_on)
        "cancel_group" -> cancel_group(op, operation_id, occurred_on)
        "apply_hotel_credit" -> apply_hotel_credit(op, operation_id, occurred_on)
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

      lodging_total_cents = Enum.sum_by(rooms, &(&1.nightly_rate_cents * nights))

      deposit_due_cents =
        case rate_plan do
          "advance_purchase" -> lodging_total_cents
          "flexible" -> Enum.sum_by(rooms, &flexible_room_deposit(&1.nightly_rate_cents * nights))
        end

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
        deposit_due_cents: deposit_due_cents
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          rooms
          |> Enum.with_index()
          |> Enum.each(fn {room, index} ->
            Repo.insert!(%Room{
              room_id: room.room_id,
              nightly_rate_cents: room.nightly_rate_cents,
              position: index,
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

  # 20% of the room's lodging amount, rounded to the nearest cent with an
  # exact half-cent rounding upward.
  defp flexible_room_deposit(lodging_cents) do
    div(lodging_cents * @flexible_deposit_percent + 50, 100)
  end

  # record_cash_payment

  defp record_cash_payment(op, operation_id) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      new_revision = group.revision + 1
      new_paid = group.deposit_paid_cents + amount_cents

      Repo.update!(change(group, deposit_paid_cents: new_paid, revision: new_revision))

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => group.deposit_due_cents - new_paid,
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
      refundable? = refundable?(group, occurred_on)
      cash_cents = group.deposit_paid_cents - group.credit_paid_cents

      {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
        settle_cancellation(
          group,
          refundable?,
          refund_method,
          cash_cents,
          operation_id,
          occurred_on
        )

      settle_applied_credit(group, refundable?, occurred_on)

      new_revision = group.revision + 1

      Repo.update!(
        change(group,
          status: "cancelled",
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          cash_converted_cents: converted_cents,
          revision: new_revision
        )
      )

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

  defp settle_cancellation(_group, true, "cash", cash_cents, _operation_id, _occurred_on),
    do: {cash_cents, 0, 0, 0}

  defp settle_cancellation(_group, false, "cash", cash_cents, _operation_id, _occurred_on),
    do: {0, cash_cents, 0, 0}

  defp settle_cancellation(group, true, "hotel_credit", cash_cents, operation_id, occurred_on)
       when cash_cents > 0 do
    lot_cents = with_bonus(cash_cents)

    Repo.insert!(%Lot{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: lot_cents,
      expires_on: Date.add(occurred_on, @credit_expiry_day_offset)
    })

    {0, 0, cash_cents, lot_cents}
  end

  defp settle_cancellation(
         _group,
         true,
         "hotel_credit",
         _cash_cents,
         _operation_id,
         _occurred_on
       ),
       do: {0, 0, 0, 0}

  # Restores applied credit to its original lots on a refundable cancellation,
  # or consumes it on a non-refundable one. Credit restored to a lot that has
  # already expired on the cancellation date expires immediately instead of
  # becoming available again.
  defp settle_applied_credit(group, true, occurred_on) do
    Repo.all(from a in CreditApplication, where: a.group_id == ^group.id, preload: [:credit_lot])
    |> Enum.each(fn application ->
      lot = application.credit_lot

      if Date.compare(lot.expires_on, occurred_on) == :gt do
        Repo.update!(change(lot, remaining_cents: lot.remaining_cents + application.amount_cents))
      end

      Repo.delete!(application)
    end)
  end

  defp settle_applied_credit(group, false, _occurred_on) do
    Repo.delete_all(from a in CreditApplication, where: a.group_id == ^group.id)
  end

  # 110% of the cash, rounded to the nearest cent with an exact half-cent
  # rounding upward.
  defp with_bonus(cash_cents) do
    div(cash_cents * (100 + @credit_bonus_percent) + 50, 100)
  end

  # apply_hotel_credit

  defp apply_hotel_credit(op, operation_id, occurred_on) do
    with {:ok, group_id} <- require_id(op, "group_id"),
         {:ok, group} <- fetch_group_record(group_id),
         :ok <- check_revision(op, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- validate_amount(op["amount_cents"]),
         :ok <- ensure_credit_available(group.guest_id, amount_cents, occurred_on),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      consume_credit(group, amount_cents, occurred_on)

      new_revision = group.revision + 1
      new_paid = group.deposit_paid_cents + amount_cents

      Repo.update!(
        change(group,
          deposit_paid_cents: new_paid,
          credit_paid_cents: group.credit_paid_cents + amount_cents,
          revision: new_revision
        )
      )

      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "applied",
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => group.deposit_due_cents - new_paid,
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

  # Consumes lots by earliest expiry, then by source_operation_id for equal
  # expiries. Expiry is evaluated as of the operation's `occurred_on`.
  defp consume_credit(group, amount_cents, as_on) do
    group.guest_id
    |> usable_lots(as_on)
    |> Enum.reduce_while(amount_cents, fn lot, left ->
      take = min(left, lot.remaining_cents)

      if take > 0 do
        Repo.update!(change(lot, remaining_cents: lot.remaining_cents - take))

        Repo.insert!(%CreditApplication{
          group_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: take
        })
      end

      if left - take <= 0, do: {:halt, 0}, else: {:cont, left - take}
    end)
  end

  defp usable_lots(guest_id, as_on) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
  end

  # Credit liability is the credit still owed to guests: unexpired lot
  # balances plus credit currently applied to active groups (whose expiry is
  # paused while it funds the group).
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

  defp check_revision(op, group) do
    case op do
      %{"expected_revision" => expected} when expected != nil ->
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
    rooms =
      group.rooms
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&%{"room_id" => &1.room_id, "nightly_rate_cents" => &1.nightly_rate_cents})

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
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.deposit_paid_cents - group.credit_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  defp render_date(nil), do: nil
  defp render_date(date), do: Date.to_iso8601(date)

  defp outstanding_deposit_cents(%{status: "cancelled"}), do: 0

  defp outstanding_deposit_cents(group),
    do: group.deposit_due_cents - group.deposit_paid_cents
end
