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

  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.GroupCreditApplication
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
  Renders a group for the API.
  """
  def group_json(%Group{} = group) do
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
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_applied_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

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
  Cash and credit totals across all groups as of the given date. Only cash that
  was actually paid appears in the cash totals; credit liability counts available
  credit plus credit currently applied to active groups.
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
      "credit_liability_cents" => credit_liability(on)
    }
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
       when kind in [:record_cash_payment, :reschedule_group, :cancel_group, :apply_hotel_credit] do
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

  defp apply_group_operation(:record_cash_payment, operation_id, cmd, group) do
    amount_cents = cmd.raw["amount_cents"]

    if usable_amount?(amount_cents) do
      outstanding_before = outstanding_deposit(group)

      if amount_cents > outstanding_before do
        reject(operation_id, "payment_exceeds_outstanding", group.group_id)
      else
        revision = group.revision + 1

        group
        |> change(
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: group.cash_paid_cents + amount_cents,
          revision: revision
        )
        |> Repo.update!()

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

  defp apply_group_operation(:cancel_group, operation_id, cmd, group) do
    if not refundable?(group, cmd.occurred_on) and cmd.refund_method == "hotel_credit" do
      reject(operation_id, "refund_method_not_available", group.group_id)
    else
      settle_cancellation(operation_id, cmd, group)
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

  # A flexible reservation is refundable when the cancellation happens on or
  # before its policy's refundable-until date.
  defp refundable?(%Group{rate_plan: "advance_purchase"}, _on), do: false

  defp refundable?(group, on), do: Date.compare(on, refundable_until(group)) != :gt

  defp settle_cancellation(operation_id, cmd, group) do
    refundable? = refundable?(group, cmd.occurred_on)
    cash_cents = group.cash_paid_cents
    credit_issued_cents = credit_issued_for(cmd, group)

    {refunded_cents, retained_cents, converted_cents} =
      cond do
        refundable? and cmd.refund_method == "cash" -> {cash_cents, 0, 0}
        refundable? -> {0, 0, cash_cents}
        true -> {0, cash_cents, 0}
      end

    release_applications(group.id, restore?: refundable?)

    if credit_issued_cents > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        issued_on: cmd.occurred_on,
        expires_on: Date.add(cmd.occurred_on, @credit_availability_days + 1)
      })
    end

    revision = group.revision + 1

    group
    |> change(
      status: "cancelled",
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      converted_to_credit_cents: converted_cents,
      revision: revision
    )
    |> Repo.update!()

    applied(operation_id, %{
      "group_id" => group.group_id,
      "refunded_cents" => refunded_cents,
      "retained_cents" => retained_cents,
      "credit_issued_cents" => credit_issued_cents,
      "revision" => revision
    })
  end

  # A hotel-credit settlement converts the cash-funded portion into a lot worth
  # 110% of that cash; other settlements issue no credit.
  defp credit_issued_for(%{refund_method: "hotel_credit"} = cmd, group) do
    if refundable?(group, cmd.occurred_on),
      do: percent_half_up(group.cash_paid_cents, 100 + @credit_bonus_percent),
      else: 0
  end

  defp credit_issued_for(_cmd, _group), do: 0

  defp consume_lots_and_apply(operation_id, cmd, group, amount_cents) do
    lots = available_lots(group.guest_id, cmd.occurred_on)
    available_cents = Enum.sum(Enum.map(lots, & &1.remaining_cents))

    if available_cents < amount_cents do
      reject(operation_id, "insufficient_credit", group.group_id)
    else
      take_lots(lots, amount_cents, group.id)
      outstanding_before = outstanding_deposit(group)
      revision = group.revision + 1

      group
      |> change(
        deposit_paid_cents: group.deposit_paid_cents + amount_cents,
        credit_applied_cents: group.credit_applied_cents + amount_cents,
        revision: revision
      )
      |> Repo.update!()

      applied(operation_id, %{
        "group_id" => group.group_id,
        "amount_cents" => amount_cents,
        "outstanding_deposit_cents" => outstanding_before - amount_cents,
        "revision" => revision
      })
    end
  end

  # Consumes lots in expiry order, recording which lots funded the group so a
  # later refundable cancellation can restore them.
  defp take_lots(_lots, taken, _group_db_id) when taken <= 0, do: :ok

  defp take_lots([lot | rest], taken, group_db_id) do
    amount = min(taken, lot.remaining_cents)

    from(l in CreditLot, where: l.id == ^lot.id)
    |> Repo.update_all(set: [remaining_cents: lot.remaining_cents - amount])

    Repo.insert!(%GroupCreditApplication{
      group_id: group_db_id,
      credit_lot_id: lot.id,
      amount_cents: amount
    })

    take_lots(rest, taken - amount, group_db_id)
  end

  # Returns applied credit to its original lots (a refundable cancellation), or
  # consumes it for good (a non-refundable one).
  defp release_applications(group_db_id, restore?: restore?) do
    applications =
      from(a in GroupCreditApplication, where: a.group_id == ^group_db_id)
      |> Repo.all()

    if restore? do
      Enum.each(applications, fn application ->
        from(l in CreditLot, where: l.id == ^application.credit_lot_id)
        |> Repo.update_all(inc: [remaining_cents: application.amount_cents])
      end)
    end

    from(a in GroupCreditApplication, where: a.group_id == ^group_db_id)
    |> Repo.delete_all()
  end

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
