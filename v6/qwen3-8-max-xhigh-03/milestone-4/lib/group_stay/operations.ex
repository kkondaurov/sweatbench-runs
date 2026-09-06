defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations submitted as batches.

  Each operation runs in its own transaction. An operation carrying a valid
  `operation_id` is durably idempotent: its idempotency record commits in
  the same transaction as any domain changes, so the identifier is applied
  at most once. Applied results and handled rejections are both remembered;
  an equivalent retry returns the exact stored result without reading or
  changing current domain state, and reusing the identifier with a different
  payload is rejected with `operation_id_conflict`. An unexpected exception
  rolls back the current operation, is not remembered, and propagates to the
  caller.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit
  alias GroupStay.Credit.Entitlement
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups
  alias GroupStay.Groups.Backfill
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Groups.RoomAllocation
  alias GroupStay.Operations.Record

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @credit_bonus_percent 10

  @doc """
  Applies the operations in order and returns one result map per operation.
  """
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_one/1)
  end

  @doc """
  The stored result for `operation_id`, decoded from its durable record, or
  nil when the identifier has not been handled by this release.
  """
  def stored_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      %Record{} = record -> Jason.decode!(record.result)
    end
  end

  def stored_result(_), do: nil

  @doc """
  Canonical JSON encoding of a submitted value: object keys are sorted so
  key order is insignificant, while array order and values are preserved.
  """
  def canonical_json(value) do
    value
    |> encode_canonical()
    |> IO.iodata_to_binary()
  end

  ## idempotency

  defp apply_one(operation) when not is_map(operation) do
    invalid_operation(nil)
  end

  defp apply_one(operation) do
    case parse_identifier(Map.get(operation, "operation_id")) do
      {:ok, operation_id} -> apply_tracked(operation, operation_id)
      :error -> invalid_operation(Map.get(operation, "operation_id"))
    end
  end

  defp invalid_operation(operation_id) do
    %{operation_id: operation_id, status: "rejected", code: "invalid_operation"}
  end

  defp apply_tracked(operation, operation_id) do
    payload = canonical_json(operation)

    case Repo.transaction(fn ->
           process_tracked(operation, operation_id, payload)
         end) do
      {:ok, result} -> result
      {:error, :operation_id_taken} -> apply_tracked(operation, operation_id)
    end
  end

  defp process_tracked(operation, operation_id, payload) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> first_submission(operation, operation_id, payload)
      %Record{} = record -> replay_or_conflict(record, operation_id, payload)
    end
  end

  defp first_submission(operation, operation_id, payload) do
    result =
      case apply_operation(operation) do
        {:ok, result} -> result
        {:error, rejection} -> rejection
      end

    store_record(operation, operation_id, payload, result)
  end

  defp replay_or_conflict(record, operation_id, payload) do
    if record.payload == payload do
      Jason.decode!(record.result)
    else
      %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
    end
  end

  defp store_record(operation, operation_id, payload, result) do
    result_json = Jason.encode!(result)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    record = %Record{
      operation_id: operation_id,
      type: submitted_type(operation),
      payload: payload,
      result: result_json,
      inserted_at: now,
      updated_at: now
    }

    try do
      Repo.insert!(record)
    rescue
      # A concurrent retry committed this identifier first: roll back the
      # domain changes of this attempt and replay the committed record.
      Ecto.ConstraintError -> Repo.rollback(:operation_id_taken)
    end

    Jason.decode!(result_json)
  end

  defp submitted_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  ## canonical encoding

  defp encode_canonical(value) when is_map(value) do
    inner =
      value
      |> Enum.map(fn {key, val} -> {to_string(key), encode_canonical(val)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, val} -> [Jason.encode!(key), ?:, val] end)
      |> Enum.intersperse(?,)

    [?{, inner, ?}]
  end

  defp encode_canonical(value) when is_list(value) do
    inner =
      value
      |> Enum.map(&encode_canonical/1)
      |> Enum.intersperse(?,)

    [?[, inner, ?]]
  end

  defp encode_canonical(value), do: Jason.encode!(value)

  ## operation dispatch

  defp apply_operation(operation) do
    raw_operation_id = Map.get(operation, "operation_id")

    with {:ok, operation_id} <- parse_identifier(raw_operation_id),
         {:ok, type} <- parse_identifier(Map.get(operation, "type")),
         {:ok, occurred_on} <- parse_iso_date(Map.get(operation, "occurred_on")),
         {:ok, handler} <- handler(type) do
      handler.(operation, %{operation_id: operation_id, occurred_on: occurred_on})
    else
      _ -> reject(raw_operation_id, "invalid_operation")
    end
  end

  defp handler("open_group"), do: {:ok, &open_group/2}
  defp handler("record_cash_payment"), do: {:ok, &record_cash_payment/2}
  defp handler("reschedule_group"), do: {:ok, &reschedule_group/2}
  defp handler("cancel_group"), do: {:ok, &cancel_group/2}
  defp handler("cancel_rooms"), do: {:ok, &cancel_rooms/2}
  defp handler("apply_hotel_credit"), do: {:ok, &apply_hotel_credit/2}
  defp handler("reduce_cash_payment"), do: {:ok, &reduce_cash_payment/2}
  defp handler("charge_back_payment"), do: {:ok, &charge_back_payment/2}
  defp handler(_), do: :error

  ## open_group

  defp open_group(operation, ctx) do
    with {:ok, group_id} <- fetch_identifier(operation, "group_id"),
         {:ok, guest_id} <- fetch_identifier(operation, "guest_id"),
         {:ok, property_id} <- fetch_identifier(operation, "property_id"),
         {:ok, arrival_raw} <- fetch_present(operation, "arrival_on"),
         {:ok, departure_raw} <- fetch_present(operation, "departure_on"),
         {:ok, rate_plan} <- fetch_identifier(operation, "rate_plan"),
         {:ok, rooms_raw} <- fetch_present(operation, "rooms"),
         :ok <- ensure_group_absent(group_id),
         {:ok, arrival_on, departure_on} <- parse_stay(arrival_raw, departure_raw),
         {:ok, rooms} <- parse_rooms(rooms_raw),
         :ok <- validate_rate_plan(rate_plan) do
      create_group(ctx, group_id, %{
        guest_id: guest_id,
        property_id: property_id,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        rooms: rooms
      })
    else
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.get(Group, group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp parse_stay(arrival_raw, departure_raw) do
    with {:ok, arrival_on} <- parse_stay_date(arrival_raw),
         {:ok, departure_on} <- parse_stay_date(departure_raw),
         true <- Date.diff(departure_on, arrival_on) >= 1 do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp parse_stay_date(raw) do
    case parse_iso_date(raw) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "invalid_stay"}
    end
  end

  defp parse_rooms(rooms) when not is_list(rooms), do: {:error, "invalid_operation"}
  defp parse_rooms([]), do: {:error, "invalid_rooms"}

  defp parse_rooms(rooms) do
    parsed = Enum.map(rooms, &parse_room/1)

    if Enum.any?(parsed, &(&1 == :error)) do
      {:error, "invalid_rooms"}
    else
      room_ids = Enum.map(parsed, & &1.room_id)

      if length(Enum.uniq(room_ids)) != length(room_ids) do
        {:error, "invalid_rooms"}
      else
        {:ok, parsed}
      end
    end
  end

  defp parse_room(room) when is_map(room) do
    with room_id when is_binary(room_id) and room_id != "" <- Map.get(room, "room_id"),
         rate when is_integer(rate) and rate >= 0 <- Map.get(room, "nightly_rate_cents") do
      %{room_id: room_id, nightly_rate_cents: rate}
    else
      _ -> :error
    end
  end

  defp parse_room(_), do: :error

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp create_group(ctx, group_id, attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)
    lodging_total_cents = lodging_total_cents(attrs.rooms, nights)
    deposit_due_cents = deposit_due_cents(attrs.rate_plan, attrs.rooms, nights)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    group = %Group{
      group_id: group_id,
      guest_id: attrs.guest_id,
      property_id: attrs.property_id,
      booked_on: ctx.occurred_on,
      arrival_on: attrs.arrival_on,
      departure_on: attrs.departure_on,
      rate_plan: attrs.rate_plan,
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert!(group)

    attrs.rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      lodging_cents = room.nightly_rate_cents * nights

      Repo.insert!(%Room{
        group_id: group_id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: position,
        status: "active",
        lodging_cents: lodging_cents,
        deposit_due_cents: room_deposit_due(attrs.rate_plan, lodging_cents),
        inserted_at: now,
        updated_at: now
      })
    end)

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: group_id,
       deposit_due_cents: deposit_due_cents,
       revision: 1
     }}
  end

  defp lodging_total_cents(rooms, nights) do
    rooms
    |> Enum.map(&(&1.nightly_rate_cents * nights))
    |> Enum.sum()
  end

  defp deposit_due_cents("flexible", rooms, nights) do
    rooms
    |> Enum.map(&room_deposit_due("flexible", &1.nightly_rate_cents * nights))
    |> Enum.sum()
  end

  defp deposit_due_cents("advance_purchase", rooms, nights) do
    lodging_total_cents(rooms, nights)
  end

  defp room_deposit_due("flexible", lodging_cents),
    do: percentage(lodging_cents, @flexible_deposit_percent)

  defp room_deposit_due("advance_purchase", lodging_cents), do: lodging_cents

  @doc """
  Rounds `amount * percent / 100` to the nearest cent; an exact half-cent
  rounds upward.
  """
  def percentage(amount, percent) when is_integer(amount) and amount >= 0 do
    div(2 * amount * percent + 100, 200)
  end

  ## record_cash_payment

  defp record_cash_payment(operation, ctx) do
    with {:ok, group_id} <- fetch_identifier(operation, "group_id"),
         {:ok, amount_raw} <- fetch_present(operation, "amount_cents"),
         {:ok, group} <- fetch_backfilled_group(group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_amount(amount_raw),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      apply_payment(group, amount_cents, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp parse_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp parse_amount(_), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount) do
    if amount <= Groups.outstanding_deposit_cents(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp apply_payment(group, amount_cents, ctx) do
    deposit_paid_cents = group.deposit_paid_cents + amount_cents
    revision = group.revision + 1

    group
    |> change(deposit_paid_cents: deposit_paid_cents, revision: revision)
    |> Repo.update!()

    Groups.allocate_funding(group.group_id, [{nil, amount_cents}], ctx.operation_id)

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: group.deposit_due_cents - deposit_paid_cents,
       revision: revision
     }}
  end

  ## reschedule_group

  defp reschedule_group(operation, ctx) do
    with {:ok, group_id} <- fetch_identifier(operation, "group_id"),
         {:ok, new_arrival_raw} <- fetch_present(operation, "new_arrival_on"),
         {:ok, group} <- fetch_group(group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- parse_stay_date(new_arrival_raw),
         :ok <- validate_new_arrival(new_arrival_on, ctx.occurred_on) do
      apply_reschedule(group, new_arrival_on, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp apply_reschedule(group, new_arrival_on, ctx) do
    shift_days = Date.diff(new_arrival_on, group.arrival_on)
    new_departure_on = Date.add(group.departure_on, shift_days)
    revision = group.revision + 1
    policy_version = Groups.policy_version(group)

    group
    |> change(arrival_on: new_arrival_on, departure_on: new_departure_on, revision: revision)
    |> Repo.update!()

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: group.group_id,
       new_arrival_on: new_arrival_on,
       new_departure_on: new_departure_on,
       policy_version: policy_version,
       refundable_until: Groups.refundable_until(new_arrival_on, policy_version),
       revision: revision
     }}
  end

  ## cancel_group

  defp cancel_group(operation, ctx) do
    with {:ok, group_id} <- fetch_identifier(operation, "group_id"),
         {:ok, group} <- fetch_backfilled_group(group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group),
         {:ok, refund_method} <- parse_refund_method(operation) do
      settle_active_rooms(group, active_rooms(group.group_id), refund_method, ctx, :cancel_group)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  ## cancel_rooms

  defp cancel_rooms(operation, ctx) do
    with {:ok, group_id} <- fetch_identifier(operation, "group_id"),
         {:ok, room_ids} <- fetch_room_ids(operation),
         {:ok, group} <- fetch_backfilled_group(group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group),
         {:ok, rooms} <- fetch_selected_rooms(group.group_id, room_ids),
         {:ok, refund_method} <- parse_refund_method(operation) do
      settle_active_rooms(group, rooms, refund_method, ctx, {:cancel_rooms, rooms})
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp fetch_room_ids(operation) do
    case Map.get(operation, "room_ids") do
      room_ids when is_list(room_ids) -> {:ok, room_ids}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp fetch_selected_rooms(_group_id, []), do: {:error, "invalid_rooms"}

  defp fetch_selected_rooms(group_id, room_ids) do
    rooms = active_rooms(group_id)
    active_ids = MapSet.new(rooms, & &1.room_id)
    supplied = MapSet.new(room_ids)

    if length(Enum.uniq(room_ids)) == length(room_ids) and MapSet.subset?(supplied, active_ids) do
      {:ok, Enum.filter(rooms, &MapSet.member?(supplied, &1.room_id))}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp active_rooms(group_id) do
    Room
    |> where([r], r.group_id == ^group_id and r.status == "active")
    |> order_by([r], asc: r.position)
    |> Repo.all()
  end

  ## shared room settlement

  defp parse_refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp settle_active_rooms(group, rooms, "hotel_credit", ctx, result_kind) do
    if Groups.refundable?(group, ctx.occurred_on) do
      settle_rooms(group, rooms, "hotel_credit", ctx, result_kind)
    else
      reject(ctx.operation_id, "refund_method_not_available")
    end
  end

  defp settle_active_rooms(group, rooms, "cash", ctx, result_kind) do
    settle_rooms(group, rooms, "cash", ctx, result_kind)
  end

  defp settle_rooms(group, rooms, refund_method, ctx, result_kind) do
    refundable = Groups.refundable?(group, ctx.occurred_on)
    room_db_ids = Enum.map(rooms, & &1.id)

    allocations =
      RoomAllocation
      |> where(
        [a],
        a.group_id == ^group.group_id and a.room_id in ^room_db_ids and a.disposition == "held"
      )
      |> order_by([a], asc: a.id)
      |> Repo.all()

    {cash_rows, credit_rows} = Enum.split_with(allocations, &(&1.kind == "cash"))

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      if refundable do
        Credit.restore_allocations(credit_rows, ctx.occurred_on)

        case refund_method do
          "cash" ->
            mark_cash_settled(cash_rows, "refunded")
            {sum_amounts(cash_rows), 0, 0, 0}

          "hotel_credit" ->
            mark_cash_settled(cash_rows, "converted")
            {0, 0, sum_amounts(cash_rows), issue_converted_lot(group, cash_rows, ctx)}
        end
      else
        Credit.consume_allocations(credit_rows)
        mark_cash_settled(cash_rows, "retained")
        {0, sum_amounts(cash_rows), 0, 0}
      end

    finalize_room_settlement(
      group,
      rooms,
      refunded_cents,
      retained_cents,
      converted_cents,
      credit_issued_cents,
      sum_amounts(allocations),
      sum_amounts(credit_rows),
      ctx,
      result_kind
    )
  end

  defp mark_cash_settled(rows, disposition) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(rows, fn row ->
      row |> change(disposition: disposition, updated_at: now) |> Repo.update!()
    end)
  end

  defp finalize_room_settlement(
         group,
         rooms,
         refunded_cents,
         retained_cents,
         converted_cents,
         credit_issued_cents,
         settled_paid_cents,
         settled_credit_cents,
         ctx,
         result_kind
       ) do
    cancelled_due_cents = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))
    cancelled_lodging_cents = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
    revision = group.revision + 1

    remaining_active = length(active_rooms(group.group_id)) - length(rooms)
    status = if remaining_active == 0, do: "cancelled", else: group.status

    Enum.each(rooms, fn room ->
      room |> change(status: "cancelled") |> Repo.update!()
    end)

    group
    |> change(
      status: status,
      lodging_total_cents: group.lodging_total_cents - cancelled_lodging_cents,
      deposit_due_cents: group.deposit_due_cents - cancelled_due_cents,
      deposit_paid_cents: group.deposit_paid_cents - settled_paid_cents,
      credit_paid_cents: group.credit_paid_cents - settled_credit_cents,
      refunded_cents: group.refunded_cents + refunded_cents,
      retained_cents: group.retained_cents + retained_cents,
      converted_to_credit_cents: group.converted_to_credit_cents + converted_cents,
      revision: revision
    )
    |> Repo.update!()

    result = %{
      operation_id: ctx.operation_id,
      status: "applied",
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents,
      revision: revision
    }

    result =
      case result_kind do
        :cancel_group ->
          result

        {:cancel_rooms, cancelled_rooms} ->
          Map.put(result, :cancelled_room_ids, Enum.map(cancelled_rooms, & &1.room_id))
      end

    {:ok, result}
  end

  defp sum_amounts(rows), do: Enum.reduce(rows, 0, &(&1.amount_cents + &2))

  defp issue_converted_lot(_group, [], _ctx), do: 0

  defp issue_converted_lot(group, cash_rows, ctx) do
    cash_cents = sum_amounts(cash_rows)
    issued_cents = cash_cents + percentage(cash_cents, @credit_bonus_percent)
    lot = Credit.issue_lot(group.guest_id, ctx.operation_id, issued_cents, ctx.occurred_on)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    cash_rows
    |> Enum.map(&{&1.operation_id, &1.amount_cents})
    |> entitlements()
    |> Enum.each(fn {operation_id, amount_cents} ->
      if amount_cents > 0 do
        Repo.insert!(%Entitlement{
          lot_id: lot.id,
          operation_id: operation_id,
          amount_cents: amount_cents,
          inserted_at: now,
          updated_at: now
        })
      end
    end)

    issued_cents
  end

  # Entitlements telescope exactly to the issued lot: in funding order, each
  # contributing payment's share is the 10%-bonus value of the settled cash
  # through that payment minus the bonus value through the preceding one,
  # with both running totals rounded half-up. Unattributed senior funding
  # leads the order and advances the running totals without entitlement.
  defp entitlements(contributions) do
    contributions
    |> Enum.chunk_by(fn {operation_id, _amount} -> operation_id end)
    |> Enum.reduce({[], 0, 0}, fn chunk, {ents, running, prev_value} ->
      running = running + (chunk |> Enum.map(&elem(&1, 1)) |> Enum.sum())
      value = running + percentage(running, @credit_bonus_percent)

      ents =
        case elem(hd(chunk), 0) do
          nil -> ents
          operation_id -> [{operation_id, value - prev_value} | ents]
        end

      {ents, running, value}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(operation, ctx) do
    with {:ok, group_id} <- fetch_identifier(operation, "group_id"),
         {:ok, amount_raw} <- fetch_present(operation, "amount_cents"),
         {:ok, group} <- fetch_backfilled_group(group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- parse_amount(amount_raw),
         :ok <- ensure_within_outstanding(group, amount_cents),
         :ok <- Credit.apply_credit(group, amount_cents, ctx.occurred_on, ctx.operation_id) do
      apply_credit_payment(group, amount_cents, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp apply_credit_payment(group, amount_cents, ctx) do
    deposit_paid_cents = group.deposit_paid_cents + amount_cents
    credit_paid_cents = group.credit_paid_cents + amount_cents
    revision = group.revision + 1

    group
    |> change(
      deposit_paid_cents: deposit_paid_cents,
      credit_paid_cents: credit_paid_cents,
      revision: revision
    )
    |> Repo.update!()

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       group_id: group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: group.deposit_due_cents - deposit_paid_cents,
       revision: revision
     }}
  end

  ## reduce_cash_payment

  defp reduce_cash_payment(operation, ctx) do
    with {:ok, payment_operation_id} <- fetch_identifier(operation, "payment_operation_id"),
         {:ok, amount_raw} <- fetch_present(operation, "amount_cents"),
         {:ok, payment} <- fetch_reducible_payment(payment_operation_id),
         {:ok, group} <- fetch_backfilled_group(payment.group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         {:ok, held_rows} <- fetch_held_cash(payment_operation_id),
         {:ok, amount_cents} <- parse_amount(amount_raw),
         :ok <- ensure_within_held(held_rows, amount_cents) do
      apply_reduction(group, payment_operation_id, held_rows, amount_cents, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp fetch_reducible_payment(payment_operation_id) do
    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{type: "record_cash_payment"} = record ->
        result = Jason.decode!(record.result)

        if result["status"] == "applied" do
          {:ok, %{group_id: result["group_id"]}}
        else
          {:error, "payment_not_reducible"}
        end

      %Record{} ->
        {:error, "payment_not_reducible"}
    end
  end

  defp fetch_held_cash(payment_operation_id) do
    rows =
      RoomAllocation
      |> where(
        [a],
        a.operation_id == ^payment_operation_id and a.kind == "cash" and a.disposition == "held"
      )
      |> order_by([a], desc: a.id)
      |> Repo.all()

    if rows == [] do
      {:error, "payment_not_reducible"}
    else
      {:ok, rows}
    end
  end

  defp ensure_within_held(held_rows, amount_cents) do
    if amount_cents <= sum_amounts(held_rows) do
      :ok
    else
      {:error, "reduction_exceeds_held_cash"}
    end
  end

  defp apply_reduction(group, payment_operation_id, held_rows, amount_cents, ctx) do
    remove_held(held_rows, amount_cents)

    deposit_paid_cents = group.deposit_paid_cents - amount_cents
    revision = group.revision + 1

    group
    |> change(
      deposit_paid_cents: deposit_paid_cents,
      cash_reduced_cents: group.cash_reduced_cents + amount_cents,
      revision: revision
    )
    |> Repo.update!()

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       payment_operation_id: payment_operation_id,
       group_id: group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: group.deposit_due_cents - deposit_paid_cents,
       revision: revision
     }}
  end

  # Removes held allocations in reverse fill order, reopening the rooms'
  # outstanding deposit by the amount removed.
  defp remove_held(_rows, 0), do: :ok

  defp remove_held([row | rest], remaining_cents) do
    take = min(row.amount_cents, remaining_cents)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if take == row.amount_cents do
      row |> change(disposition: "reduced", updated_at: now) |> Repo.update!()
    else
      row |> change(amount_cents: row.amount_cents - take, updated_at: now) |> Repo.update!()

      Repo.insert!(%RoomAllocation{
        group_id: row.group_id,
        room_id: row.room_id,
        operation_id: row.operation_id,
        lot_id: row.lot_id,
        kind: row.kind,
        amount_cents: take,
        disposition: "reduced",
        inserted_at: now,
        updated_at: now
      })
    end

    remove_held(rest, remaining_cents - take)
  end

  ## charge_back_payment

  defp charge_back_payment(operation, ctx) do
    with {:ok, payment_operation_id} <- fetch_identifier(operation, "payment_operation_id"),
         {:ok, payment} <- fetch_chargeable_payment(payment_operation_id),
         {:ok, group} <- fetch_backfilled_group(payment.group_id),
         {:ok, group} <- check_revision(operation, group, ctx),
         {:ok, sums} <- fetch_chargeable_sums(payment_operation_id) do
      apply_chargeback(group, payment_operation_id, sums, ctx)
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> reject(ctx.operation_id, code)
    end
  end

  defp fetch_chargeable_payment(payment_operation_id) do
    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      %Record{type: "record_cash_payment"} = record ->
        result = Jason.decode!(record.result)

        if result["status"] == "applied" do
          {:ok, %{group_id: result["group_id"]}}
        else
          {:error, "payment_not_chargeable"}
        end

      %Record{} ->
        {:error, "payment_not_chargeable"}
    end
  end

  defp fetch_chargeable_sums(payment_operation_id) do
    sums = Groups.disposition_sums(payment_operation_id)

    chargeable =
      Map.get(sums, "held", 0) + Map.get(sums, "refunded", 0) + Map.get(sums, "retained", 0) +
        Map.get(sums, "converted", 0)

    cond do
      Map.get(sums, "charged_back", 0) > 0 -> {:error, "payment_not_chargeable"}
      chargeable == 0 -> {:error, "payment_not_chargeable"}
      true -> {:ok, sums}
    end
  end

  defp apply_chargeback(group, payment_operation_id, sums, ctx) do
    held_cents = Map.get(sums, "held", 0)
    refunded_cents = Map.get(sums, "refunded", 0)
    retained_cents = Map.get(sums, "retained", 0)
    converted_cents = Map.get(sums, "converted", 0)

    charged_back_cents =
      held_cents + refunded_cents + retained_cents + converted_cents

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    RoomAllocation
    |> where(
      [a],
      a.operation_id == ^payment_operation_id and a.kind == "cash" and
        a.disposition in ~w(held refunded retained converted)
    )
    |> Repo.update_all(set: [disposition: "charged_back", updated_at: now])

    revoke_entitlements(payment_operation_id)

    deposit_paid_cents = group.deposit_paid_cents - held_cents
    revision = group.revision + 1

    outstanding_deposit_cents =
      if group.status == "active", do: group.deposit_due_cents - deposit_paid_cents, else: 0

    group
    |> change(
      deposit_paid_cents: deposit_paid_cents,
      refunded_cents: group.refunded_cents - refunded_cents,
      retained_cents: group.retained_cents - retained_cents,
      converted_to_credit_cents: group.converted_to_credit_cents - converted_cents,
      cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents,
      revision: revision
    )
    |> Repo.update!()

    {:ok,
     %{
       operation_id: ctx.operation_id,
       status: "applied",
       payment_operation_id: payment_operation_id,
       group_id: group.group_id,
       charged_back_cents: charged_back_cents,
       outstanding_deposit_cents: outstanding_deposit_cents,
       revision: revision
     }}
  end

  # Revokes the payment's entitlement from each lot's remaining balance
  # first; any entitlement that cannot be removed becomes that lot's
  # unrecovered clawback.
  defp revoke_entitlements(payment_operation_id) do
    Entitlement
    |> where([e], e.operation_id == ^payment_operation_id)
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(Lot, entitlement.lot_id)
      revoked = min(entitlement.amount_cents, lot.remaining_cents)
      unrecovered = entitlement.amount_cents - revoked

      lot
      |> change(
        remaining_cents: lot.remaining_cents - revoked,
        clawback_cents: lot.clawback_cents + unrecovered
      )
      |> Repo.update!()

      Repo.delete!(entitlement)
    end)
  end

  ## shared helpers

  defp fetch_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  # Resolves the group and brings any pre-room-accounting funding forward
  # before the operation observes it. The group is re-read so the operation
  # sees the carried-forward state.
  defp fetch_backfilled_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        {:error, "group_not_found"}

      %Group{} ->
        Backfill.backfill_all()
        {:ok, Repo.get!(Group, group_id)}
    end
  end

  defp check_revision(operation, group, ctx) do
    case Map.get(operation, "expected_revision") do
      nil ->
        {:ok, group}

      expected ->
        if expected == group.revision do
          {:ok, group}
        else
          {:error,
           %{
             operation_id: ctx.operation_id,
             status: "rejected",
             code: "stale_revision",
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           }}
        end
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:error, "group_not_active"}

  defp fetch_identifier(operation, key) do
    case parse_identifier(Map.get(operation, key)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp fetch_present(operation, key) do
    case Map.get(operation, key) do
      nil -> {:error, "invalid_operation"}
      value -> {:ok, value}
    end
  end

  defp parse_identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp parse_identifier(_), do: :error

  defp parse_iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp parse_iso_date(_), do: :error

  defp reject(operation_id, code) do
    {:error, %{operation_id: operation_id, status: "rejected", code: code}}
  end
end
