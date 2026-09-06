defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner batch operations to group reservations.

  Each operation runs inside its own transaction. A handled rejection leaves
  domain state unchanged and commits its idempotency record; an applied
  operation commits its domain changes and its idempotency record together.
  The batch runner continues with the next operation after a rejection. An
  unexpected exception rolls back the current operation, remembers nothing,
  and aborts the HTTP request.

  `operation_id` is the durable idempotency key. The first submission of an
  identifier is processed normally and its exact result - applied or
  rejected - is remembered. An equivalent retry returns the stored result
  verbatim without consulting domain state. Reusing an identifier with a
  different payload is rejected with `operation_id_conflict` and never
  replaces the stored record.

  Every applied operation addressed to an existing group increments that
  group's revision exactly once; rejections never increment it.
  """

  alias GroupStay.{
    CreditApplication,
    CreditLot,
    CreditLotContribution,
    DurableOperation,
    FinanceJournal,
    FinanceReporting,
    Group,
    Groups,
    LegacyFunding,
    Payment,
    Policies,
    Repo,
    Room,
    RoomAccounting
  }

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]
  import Ecto.Query, only: [from: 2]

  @rate_plans ["flexible", "advance_purchase"]
  @op_types ~w(open_group record_cash_payment reschedule_group cancel_group
               apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment
               transfer_deposit start_finance_reporting)

  # Days after cancellation on which a credit lot stops being available.
  @credit_lot_lifetime_days 366

  # The bonus applied to cash converted into hotel credit, as a percent.
  @credit_bonus_percent 10

  @doc """
  Applies one operation and returns its client-facing, JSON-ready result.

  Applied results carry `"status" => "applied"` plus the fields of their
  operation type. Rejected results carry `"status" => "rejected"` and a
  stable `"code"`.
  """
  def apply_operation(%{} = op) do
    case Map.get(op, "operation_id") do
      operation_id when is_binary(operation_id) ->
        apply_durable(op, operation_id, canonical_json(op))

      other ->
        apply_untracked(op, other)
    end
  end

  def apply_operation(_not_a_map) do
    rejected_result(nil, "invalid_operation", %{})
  end

  @doc """
  Returns the stored result for an operation identifier, or `:not_found`.

  Only the stored result is returned; the retained submission and commit
  order are not exposed.
  """
  def fetch_result(operation_id) do
    case Repo.get_by(DurableOperation, operation_id: operation_id) do
      nil -> :not_found
      durable -> {:ok, Jason.decode!(durable.result_json)}
    end
  end

  @doc false
  def canonical_json(op) do
    op
    |> sort_keys_deep()
    |> Jason.encode!()
  end

  defp sort_keys_deep(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _inner} -> to_string(key) end)
    |> Map.new(fn {key, inner} -> {key, sort_keys_deep(inner)} end)
  end

  defp sort_keys_deep(value) when is_list(value), do: Enum.map(value, &sort_keys_deep/1)
  defp sort_keys_deep(value), do: value

  defp apply_durable(op, operation_id, canonical) do
    case Repo.transaction(fn -> durable_run(op, operation_id, canonical) end) do
      {:ok, {:apply, result}} -> result
      {:ok, {:stored, result}} -> result
      {:ok, {:rejected, code, meta}} -> rejected_result(operation_id, code, meta)
      {:error, {:race, canonical}} -> raced_result(operation_id, canonical)
    end
  end

  defp apply_untracked(op, operation_id) do
    case Repo.transaction(fn -> run(op) end) do
      {:ok, {:apply, result}} -> result
      {:ok, {:rejected, code, meta}} -> rejected_result(operation_id, code, meta)
    end
  end

  defp durable_run(op, operation_id, canonical) do
    case Repo.get_by(DurableOperation, operation_id: operation_id) do
      nil -> first_time(op, operation_id, canonical)
      durable -> replay(durable, canonical)
    end
  end

  defp replay(%DurableOperation{payload_json: payload, result_json: result_json}, canonical) do
    if payload == canonical do
      {:stored, Jason.decode!(result_json)}
    else
      {:rejected, "operation_id_conflict", %{}}
    end
  end

  defp first_time(op, operation_id, canonical) do
    outcome = run(op)

    changeset =
      %DurableOperation{}
      |> change(
        operation_id: operation_id,
        op_type: submitted_type(op),
        payload_json: canonical,
        result_json: encoded_outcome(outcome, operation_id)
      )
      |> unique_constraint(:operation_id)

    case Repo.insert(changeset) do
      {:ok, durable} ->
        FinanceReporting.backfill(operation_id, durable.id)
        outcome

      {:error, _changeset} ->
        # A concurrent submission committed this identifier first. This
        # transaction rolls back so its domain writes never apply; the
        # committed winner is then replayed atomically below.
        Repo.rollback({:race, canonical})
    end
  end

  defp raced_result(operation_id, canonical) do
    case Repo.get_by(DurableOperation, operation_id: operation_id) do
      %DurableOperation{payload_json: payload, result_json: result_json} ->
        if payload == canonical do
          Jason.decode!(result_json)
        else
          rejected_result(operation_id, "operation_id_conflict", %{})
        end

      nil ->
        rejected_result(operation_id, "operation_id_conflict", %{})
    end
  end

  defp encoded_outcome({:apply, result}, _operation_id), do: Jason.encode!(result)

  defp encoded_outcome({:rejected, code, meta}, operation_id) do
    Jason.encode!(rejected_result(operation_id, code, meta))
  end

  defp submitted_type(op) do
    case Map.get(op, "type") do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp rejected_result(operation_id, code, meta) do
    base =
      if is_nil(operation_id) do
        %{"status" => "rejected", "code" => code}
      else
        %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
      end

    Map.merge(base, meta)
  end

  defp reject(code), do: {:rejected, code, %{}}
  defp reject(code, meta), do: {:rejected, code, meta}

  defp run(op) do
    case common_fields(op) do
      {:ok, ctx} ->
        case ctx.type do
          "open_group" -> open_group(op, ctx)
          "record_cash_payment" -> record_cash_payment(op, ctx)
          "reschedule_group" -> reschedule_group(op, ctx)
          "cancel_group" -> cancel_group(op, ctx)
          "apply_hotel_credit" -> apply_hotel_credit(op, ctx)
          "cancel_rooms" -> cancel_rooms(op, ctx)
          "reduce_cash_payment" -> reduce_cash_payment(op, ctx)
          "charge_back_payment" -> charge_back_payment(op, ctx)
          "transfer_deposit" -> transfer_deposit(op, ctx)
          "start_finance_reporting" -> start_finance_reporting(op, ctx)
        end

      :error ->
        reject("invalid_operation")
    end
  end

  defp common_fields(op) do
    with {:ok, operation_id} <- required_string(op, "operation_id"),
         {:ok, type} <- known_type(op),
         {:ok, occurred_on} <- occurred_on(op, type) do
      {:ok, %{operation_id: operation_id, type: type, occurred_on: occurred_on}}
    else
      _ -> :error
    end
  end

  defp required_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp known_type(op) do
    case Map.get(op, "type") do
      type when type in @op_types -> {:ok, type}
      _ -> :error
    end
  end

  @date_optional_types ~w(record_cash_payment reduce_cash_payment charge_back_payment
                          transfer_deposit start_finance_reporting)

  defp occurred_on(_op, type) when type in @date_optional_types, do: {:ok, nil}

  defp occurred_on(op, _type) do
    case Map.get(op, "occurred_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> :error
        end

      _ ->
        :error
    end
  end

  ## Finance reporting plumbing

  # The reporting posting date of an operation. Once reporting has started,
  # every finance effect of an applied operation posts on the later of the
  # operation's date and `starts_on`. Operations without a required
  # `occurred_on` use the optional payload date, falling back to the day
  # they are processed.
  defp reporting_posting_date(op, ctx) do
    posting_date(%{ctx | occurred_on: ctx.occurred_on || payload_occurred_on(op)})
  end

  defp posting_date(ctx) do
    base = ctx.occurred_on || Date.utc_today()

    case FinanceReporting.starts_on() do
      nil -> base
      starts_on -> if Date.compare(base, starts_on) == :lt, do: starts_on, else: base
    end
  end

  defp payload_occurred_on(op) do
    case Map.get(op, "occurred_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _} -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end

  ## open_group

  defp open_group(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, guest_id} <- required_string(op, "guest_id"),
         {:ok, property_id} <- required_string(op, "property_id"),
         :ok <- new_group(group_id),
         {:ok, arrival_on} <- stay_date(op, "arrival_on"),
         {:ok, departure_on} <- stay_date(op, "departure_on"),
         :ok <- one_or_more_nights(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(op),
         {:ok, rooms} <- rooms(op) do
      create_group(
        ctx,
        %{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          rooms: rooms
        }
      )
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp create_group(ctx, payload) do
    nights = Date.diff(payload.departure_on, payload.arrival_on)

    deposit_due =
      Enum.reduce(payload.rooms, 0, fn room, total ->
        Groups.room_deposit(room.nightly_rate_cents, payload.rate_plan, nights) + total
      end)

    group =
      try do
        Repo.insert!(%Group{
          group_id: payload.group_id,
          guest_id: payload.guest_id,
          property_id: payload.property_id,
          booked_on: ctx.occurred_on,
          arrival_on: payload.arrival_on,
          departure_on: payload.departure_on,
          rate_plan: payload.rate_plan,
          status: "active",
          revision: 1
        })
      rescue
        Ecto.ConstraintError ->
          reject("group_already_exists")
      end

    payload.rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, index} ->
      Repo.insert!(%Room{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: index,
        status: "active"
      })
    end)

    {:apply,
     %{
       "operation_id" => ctx.operation_id,
       "status" => "applied",
       "group_id" => payload.group_id,
       "deposit_due_cents" => deposit_due,
       "revision" => 1
     }}
  end

  defp new_group(group_id) do
    if Repo.exists?(from(g in Group, where: g.group_id == ^group_id)) do
      {:reject, "group_already_exists", %{}}
    else
      :ok
    end
  end

  defp stay_date(op, key) do
    case Map.get(op, key) do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:reject, "invalid_stay", %{}}
        end

      _ ->
        {:reject, "invalid_stay", %{}}
    end
  end

  defp one_or_more_nights(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:reject, "invalid_stay", %{}}
    end
  end

  defp rate_plan(op) do
    case Map.get(op, "rate_plan") do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when value in @rate_plans ->
        {:ok, value}

      _ ->
        {:reject, "invalid_rate_plan", %{}}
    end
  end

  defp rooms(op) do
    case Map.get(op, "rooms") do
      nil ->
        {:reject, "invalid_operation", %{}}

      rooms_list when is_list(rooms_list) ->
        validate_rooms(rooms_list)

      _ ->
        {:reject, "invalid_rooms", %{}}
    end
  end

  defp validate_rooms([]), do: {:reject, "invalid_rooms", %{}}

  defp validate_rooms(rooms_list) do
    rooms_list
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn room, {:ok, rooms, seen} ->
      case normalize_room(room, seen) do
        {:ok, normalized, seen} -> {:cont, {:ok, [normalized | rooms], seen}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rooms, _seen} -> {:ok, Enum.reverse(rooms)}
      :error -> {:reject, "invalid_rooms", %{}}
    end
  end

  defp normalize_room(room, seen) when is_map(room) do
    room_id = Map.get(room, "room_id")
    rate = Map.get(room, "nightly_rate_cents")

    with true <- is_binary(room_id),
         true <- is_integer(rate) and rate > 0,
         false <- MapSet.member?(seen, room_id) do
      {:ok, %{room_id: room_id, nightly_rate_cents: rate}, MapSet.put(seen, room_id)}
    else
      _ -> :error
    end
  end

  defp normalize_room(_not_a_map, _seen), do: :error

  ## shared group plumbing

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:reject, "group_not_found", %{}}

      group ->
        LegacyFunding.ensure_forwarded(group)
        {:ok, group}
    end
  end

  defp active(%{status: "active"}), do: :ok
  defp active(_group), do: {:reject, "group_not_active", %{}}

  defp amount(op) do
    case Map.get(op, "amount_cents") do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      _ ->
        {:reject, "invalid_amount", %{}}
    end
  end

  defp check_revision(op, group) do
    case Map.get(op, "expected_revision") do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:reject, "stale_revision",
         %{
           "group_id" => group.group_id,
           "expected_revision" => expected,
           "actual_revision" => group.revision
         }}
    end
  end

  defp bump_revision(group) do
    {_count, _} =
      Repo.update_all(from(g in Group, where: g.id == ^group.id), inc: [revision: 1])

    :ok
  end

  ## record_cash_payment

  defp record_cash_payment(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- active(group),
         {:ok, amount} <- amount(op) do
      outstanding = Groups.outstanding(group)

      if amount > outstanding do
        reject("payment_exceeds_outstanding")
      else
        payment =
          Repo.insert!(%Payment{
            group_id: group.id,
            kind: "payment",
            operation_id: ctx.operation_id,
            amount_cents: amount
          })

        RoomAccounting.allocate_cash(group, payment, amount)

        FinanceReporting.record_movement(
          ctx.operation_id,
          reporting_posting_date(op, ctx),
          "received",
          group.property_id,
          amount,
          payment_id: payment.id
        )

        bump_revision(group)

        {:apply,
         %{
           "operation_id" => ctx.operation_id,
           "status" => "applied",
           "group_id" => group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => outstanding - amount,
           "revision" => group.revision + 1
         }}
      end
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  ## reschedule_group

  defp reschedule_group(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- active(group),
         {:ok, new_arrival_on} <- new_arrival(op),
         :ok <- after_operation_date(new_arrival_on, ctx.occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      {_count, _} =
        Repo.update_all(
          from(g in Group, where: g.id == ^group.id),
          set: [arrival_on: new_arrival_on, departure_on: new_departure_on],
          inc: [revision: 1]
        )

      {:apply,
       %{
         "operation_id" => ctx.operation_id,
         "status" => "applied",
         "group_id" => group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "policy_version" => Policies.policy_version(group),
         "refundable_until" => iso_date(Policies.refundable_until_for(group, new_arrival_on)),
         "revision" => group.revision + 1
       }}
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp new_arrival(op) do
    case Map.get(op, "new_arrival_on") do
      nil ->
        {:reject, "invalid_operation", %{}}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:reject, "invalid_stay", %{}}
        end

      _ ->
        {:reject, "invalid_stay", %{}}
    end
  end

  defp after_operation_date(date, operation_date) do
    if Date.compare(date, operation_date) == :gt do
      :ok
    else
      {:reject, "invalid_stay", %{}}
    end
  end

  ## cancel_group

  defp cancel_group(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- active(group),
         {:ok, refund_method} <- refund_method(op) do
      settle_selected(group, RoomAccounting.active_rooms(group), ctx, refund_method, %{}, op)
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  ## cancel_rooms

  defp cancel_rooms(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         {:ok, rooms} <- selected_rooms(op, group),
         {:ok, refund_method} <- refund_method(op) do
      settle_selected(
        group,
        rooms,
        ctx,
        refund_method,
        %{"cancelled_room_ids" => Enum.map(rooms, & &1.room_id)},
        op
      )
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp selected_rooms(op, group) do
    case Map.get(op, "room_ids") do
      nil ->
        {:reject, "invalid_operation", %{}}

      room_ids when is_list(room_ids) ->
        valid =
          room_ids != [] and
            Enum.all?(room_ids, &is_binary/1) and
            length(room_ids) == length(Enum.uniq(room_ids))

        by_room_id =
          Repo.all(from(r in Room, where: r.group_id == ^group.id))
          |> Map.new(&{&1.room_id, &1})

        selected = Enum.map(room_ids, &Map.get(by_room_id, &1))

        if valid and not Enum.any?(selected, &is_nil/1) and
             Enum.all?(selected, &(&1.status == "active")) do
          {:ok, Enum.sort_by(selected, & &1.position)}
        else
          {:reject, "invalid_rooms", %{}}
        end

      _ ->
        {:reject, "invalid_rooms", %{}}
    end
  end

  defp refund_method(op) do
    case Map.get(op, "refund_method", "cash") do
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _ -> {:reject, "invalid_operation", %{}}
    end
  end

  ## Settlement shared by cancel_group and cancel_rooms.

  defp settle_selected(group, rooms, ctx, refund_method, extra, op) do
    refundable = Policies.refundable?(group, ctx.occurred_on)

    cond do
      not refundable and refund_method == "hotel_credit" ->
        reject("refund_method_not_available")

      true ->
        room_ids = Enum.map(rooms, & &1.id)
        cash_chunks = RoomAccounting.held_cash_chunks(room_ids)
        credit_chunks = RoomAccounting.held_credit_chunks(room_ids)
        cash_total = Enum.reduce(cash_chunks, 0, fn chunk, sum -> chunk.amount_cents + sum end)
        posting = reporting_posting_date(op, ctx)

        settlement =
          settle_cash(group, ctx, refund_method, refundable, cash_chunks, cash_total, posting)

        settle_credit(credit_chunks, ctx, refundable, posting)

        RoomAccounting.mark_settled(Enum.map(cash_chunks ++ credit_chunks, & &1.id))

        Repo.update_all(
          from(r in Room, where: r.id in ^room_ids),
          set: [status: "cancelled"]
        )

        cancel_group_if_exhausted(group)
        bump_revision(group)

        {:apply,
         Map.merge(
           %{
             "operation_id" => ctx.operation_id,
             "status" => "applied",
             "group_id" => group.group_id,
             "revision" => group.revision + 1
           },
           Map.merge(extra, settlement)
         )}
    end
  end

  defp settle_cash(group, ctx, "cash", true, cash_chunks, cash_total, posting) do
    add_dispositions(cash_chunks, :refunded_cents)
    record_cash_settlement(cash_chunks, "refunded", group, ctx, posting)

    %{
      "refunded_cents" => cash_total,
      "retained_cents" => 0,
      "credit_issued_cents" => 0
    }
  end

  defp settle_cash(group, ctx, "cash", false, cash_chunks, cash_total, posting) do
    add_dispositions(cash_chunks, :retained_cents)
    record_cash_settlement(cash_chunks, "retained", group, ctx, posting)

    %{
      "refunded_cents" => 0,
      "retained_cents" => cash_total,
      "credit_issued_cents" => 0
    }
  end

  defp settle_cash(group, ctx, "hotel_credit", true, cash_chunks, cash_total, posting) do
    add_dispositions(cash_chunks, :converted_cents)
    record_cash_settlement(cash_chunks, "converted", group, ctx, posting)

    if cash_total > 0 do
      bonus = Groups.round_percent(cash_total, @credit_bonus_percent)
      issued = cash_total + bonus

      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: ctx.operation_id,
          expires_on: Date.add(ctx.occurred_on, @credit_lot_lifetime_days),
          remaining_cents: issued
        })

      record_contributions(lot, cash_chunks)

      FinanceReporting.record_credit_movement(ctx.operation_id, posting, "issued", issued, lot.id)
      FinanceReporting.record_lot_delta(ctx.operation_id, posting, lot.id, issued)

      %{
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "credit_issued_cents" => issued
      }
    else
      %{
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "credit_issued_cents" => 0
      }
    end
  end

  defp settle_cash(_group, _ctx, "hotel_credit", false, _cash_chunks, _cash_total, _posting) do
    raise "non-refundable hotel-credit settlements are rejected before settling"
  end

  # Adds the settled chunk amounts to each funding payment's disposition.
  defp add_dispositions(cash_chunks, field) do
    cash_chunks
    |> Enum.reduce(%{}, fn chunk, totals ->
      Map.update(totals, chunk.payment_id, chunk.amount_cents, &(&1 + chunk.amount_cents))
    end)
    |> Enum.each(fn {payment_id, cents} ->
      Repo.update_all(
        from(p in Payment, where: p.id == ^payment_id),
        inc: [{field, cents}]
      )
    end)
  end

  # Records the settled cash per funding payment so a later chargeback can
  # reverse the settlement at the property where it happened.
  defp record_cash_settlement(cash_chunks, kind, group, ctx, posting) do
    cash_chunks
    |> Enum.group_by(& &1.payment_id)
    |> Enum.each(fn {payment_id, chunks} ->
      total = Enum.reduce(chunks, 0, &(&1.amount_cents + &2))

      FinanceReporting.record_movement(ctx.operation_id, posting, kind, group.property_id, total,
        payment_id: payment_id
      )
    end)
  end

  # Records each funding payment's entitlement in the new credit lot, in
  # funding order (the unattributed senior block naturally comes first
  # because its allocations were created first). Entitlements telescope to
  # the lot's issued value.
  defp record_contributions(lot, cash_chunks) do
    cash_chunks
    |> Enum.chunk_by(& &1.payment_id)
    |> Enum.map(fn chunks ->
      payment = Repo.get!(Payment, hd(chunks).payment_id)
      settled = Enum.reduce(chunks, 0, &(&1.amount_cents + &2))
      {payment, settled}
    end)
    |> then(fn contributions ->
      {rows, _through} =
        Enum.map_reduce(contributions, 0, fn {payment, settled}, through ->
          next_through = through + settled
          entitlement = bonus_value(next_through) - bonus_value(through)
          row = %{payment: payment, settled: settled, entitlement: entitlement}
          {row, next_through}
        end)

      Enum.each(rows, fn row ->
        Repo.insert!(%CreditLotContribution{
          lot_id: lot.id,
          payment_id: row.payment.id,
          settled_cash_cents: row.settled,
          entitlement_cents: row.entitlement
        })
      end)
    end)
  end

  defp bonus_value(cash), do: cash + Groups.round_percent(cash, @credit_bonus_percent)

  # Refundable settlements restore applied credit to its source lots;
  # non-refundable settlements consume it. A restoration first extinguishes
  # the lot's unrecovered clawback, check before expiry: only an unexpired
  # excess becomes available again. Report movements mirror the liability
  # view: absorption and expiry decrease it, normal restoration moves
  # nothing, and non-refundable settlement is consumption.
  defp settle_credit(credit_chunks, ctx, refundable, posting) do
    Enum.each(credit_chunks, fn chunk ->
      application = Repo.get!(CreditApplication, chunk.credit_application_id)

      if refundable do
        lot = Repo.get!(CreditLot, application.lot_id)
        absorbed = min(chunk.amount_cents, lot.unrecovered_clawback_cents)
        excess = chunk.amount_cents - absorbed

        if absorbed > 0 do
          Repo.update_all(
            from(l in CreditLot, where: l.id == ^lot.id),
            inc: [unrecovered_clawback_cents: -absorbed]
          )

          FinanceReporting.record_credit_movement(
            ctx.operation_id,
            posting,
            "absorbed",
            absorbed,
            lot.id
          )
        end

        if excess > 0 and Date.compare(ctx.occurred_on, lot.expires_on) == :lt do
          Repo.update_all(
            from(l in CreditLot, where: l.id == ^lot.id),
            inc: [remaining_cents: excess]
          )

          if Date.compare(posting, lot.expires_on) != :gt do
            FinanceReporting.record_lot_delta(ctx.operation_id, posting, lot.id, excess)
          else
            FinanceReporting.record_credit_movement(
              ctx.operation_id,
              posting,
              "expired",
              excess,
              lot.id
            )
          end
        else
          FinanceReporting.record_credit_movement(
            ctx.operation_id,
            posting,
            "expired",
            excess,
            lot.id
          )
        end
      else
        FinanceReporting.record_credit_movement(
          ctx.operation_id,
          posting,
          "consumed",
          chunk.amount_cents,
          application.lot_id
        )
      end
    end)
  end

  defp cancel_group_if_exhausted(group) do
    active_rooms? =
      Repo.exists?(from(r in Room, where: r.group_id == ^group.id and r.status == "active"))

    unless active_rooms? do
      Repo.update_all(from(g in Group, where: g.id == ^group.id),
        set: [status: "cancelled"]
      )
    end

    :ok
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(op, ctx) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- check_revision(op, group),
         :ok <- active(group),
         {:ok, amount} <- amount(op),
         :ok <- sufficient_credit(group, amount, ctx.occurred_on),
         :ok <- within_outstanding(group, amount) do
      outstanding = Groups.outstanding(group)
      posting = reporting_posting_date(op, ctx)
      consume_credit(group, ctx.operation_id, amount, ctx.occurred_on, posting)
      bump_revision(group)

      {:apply,
       %{
         "operation_id" => ctx.operation_id,
         "status" => "applied",
         "group_id" => group_id,
         "amount_cents" => amount,
         "outstanding_deposit_cents" => outstanding - amount,
         "revision" => group.revision + 1
       }}
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  defp sufficient_credit(group, amount, occurred_on) do
    available =
      Repo.aggregate(
        from(l in CreditLot,
          where:
            l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
              l.expires_on > ^occurred_on
        ),
        :sum,
        :remaining_cents
      ) || 0

    if available >= amount, do: :ok, else: {:reject, "insufficient_credit", %{}}
  end

  defp within_outstanding(group, amount) do
    if amount <= Groups.outstanding(group) do
      :ok
    else
      {:reject, "payment_exceeds_outstanding", %{}}
    end
  end

  defp consume_credit(group, operation_id, amount, occurred_on, posting) do
    lots =
      Repo.all(
        from(l in CreditLot,
          where:
            l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
              l.expires_on > ^occurred_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
        )
      )

    lots
    |> take_credit(amount, [])
    |> Enum.each(fn {lot, chunk} ->
      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [remaining_cents: -chunk]
      )

      application =
        Repo.insert!(%CreditApplication{
          lot_id: lot.id,
          group_id: group.id,
          amount_cents: chunk,
          status: "applied",
          operation_id: operation_id
        })

      RoomAccounting.allocate_credit(group, application, chunk)
      FinanceReporting.record_lot_delta(operation_id, posting, lot.id, -chunk)
    end)
  end

  defp take_credit([lot | rest], need, taken) when need > 0 do
    chunk = min(need, lot.remaining_cents)
    take_credit(rest, need - chunk, [{lot, chunk} | taken])
  end

  defp take_credit(_lots, _need, taken), do: Enum.reverse(taken)

  ## reduce_cash_payment

  defp reduce_cash_payment(op, ctx) do
    with {:ok, payment_operation_id} <- required_string(op, "payment_operation_id"),
         {:ok, payment} <- durable_payment(payment_operation_id, "payment_not_reducible"),
         {:ok, group} <- group_of_payment(payment),
         :ok <- check_revision(op, group),
         {:ok, amount_cents} <- amount(op) do
      held = RoomAccounting.held_cash(payment)

      cond do
        held == 0 ->
          reject("payment_not_reducible")

        amount_cents > held ->
          reject("reduction_exceeds_held_cash")

        true ->
          removed = RoomAccounting.remove_held_cash_reverse(payment, amount_cents, "reduced")
          posting = reporting_posting_date(op, ctx)

          Repo.update_all(
            from(p in Payment, where: p.id == ^payment.id),
            inc: [reduced_cents: amount_cents]
          )

          Enum.each(removed, fn {group_id, removed_cents} ->
            property = Repo.get!(Group, group_id).property_id

            FinanceReporting.record_movement(
              ctx.operation_id,
              posting,
              "reduced",
              property,
              removed_cents,
              payment_id: payment.id
            )
          end)

          bump_revision(group)
          bump_affected_groups(group, Map.keys(removed))

          {:apply,
           %{
             "operation_id" => ctx.operation_id,
             "status" => "applied",
             "payment_operation_id" => payment_operation_id,
             "group_id" => group.group_id,
             "amount_cents" => amount_cents,
             "outstanding_deposit_cents" => Groups.outstanding(group),
             "revision" => group.revision + 1
           }}
      end
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  ## charge_back_payment

  defp charge_back_payment(op, ctx) do
    with {:ok, payment_operation_id} <- required_string(op, "payment_operation_id"),
         {:ok, payment} <- durable_payment(payment_operation_id, "payment_not_chargeable"),
         {:ok, group} <- group_of_payment(payment),
         :ok <- check_revision(op, group) do
      cond do
        payment.charged_back_cents > 0 or payment.reduced_cents >= payment.amount_cents ->
          reject("payment_not_chargeable")

        true ->
          held_by_group = RoomAccounting.void_held_cash(payment)
          posting = reporting_posting_date(op, ctx)
          remaining = payment.amount_cents - payment.reduced_cents

          Repo.update_all(
            from(p in Payment, where: p.id == ^payment.id),
            set: [
              refunded_cents: 0,
              retained_cents: 0,
              converted_cents: 0,
              charged_back_cents: remaining
            ]
          )

          Enum.each(held_by_group, fn {group_id, held_cents} ->
            property = Repo.get!(Group, group_id).property_id

            FinanceReporting.record_movement(
              ctx.operation_id,
              posting,
              "charged_back",
              property,
              held_cents,
              payment_id: payment.id
            )
          end)

          record_settlement_reversals(payment, ctx.operation_id, posting)
          revoke_entitlements(payment, ctx.operation_id, posting)
          bump_revision(group)
          bump_affected_groups(group, Map.keys(held_by_group))

          {:apply,
           %{
             "operation_id" => ctx.operation_id,
             "status" => "applied",
             "payment_operation_id" => payment_operation_id,
             "group_id" => group.group_id,
             "charged_back_cents" => remaining,
             "outstanding_deposit_cents" => Groups.outstanding(group),
             "revision" => group.revision + 1
           }}
      end
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  @reversal_kinds ~w(refunded retained converted)

  # Chargebacks reclassify a payment's earlier settlements: the historical
  # refund, retention, or conversion is not reissued, so its reported
  # movement is reversed at the property where it was settled and the same
  # amount moves to charged-back cash there.
  defp record_settlement_reversals(payment, operation_id, posting) do
    Repo.all(
      from(j in FinanceJournal,
        where: j.payment_id == ^payment.id and j.kind in @reversal_kinds
      )
    )
    |> Enum.group_by(&{&1.kind, &1.property_id})
    |> Enum.each(fn {{kind, property_id}, rows} ->
      total = Enum.reduce(rows, 0, &(&1.amount_cents + &2))

      FinanceReporting.record_movement(operation_id, posting, kind, property_id, -total,
        payment_id: payment.id
      )

      FinanceReporting.record_movement(operation_id, posting, "charged_back", property_id, total,
        payment_id: payment.id
      )
    end)
  end

  # Reverts the credit entitlement a converted payment created in each lot.
  # Amounts are removed from the lot's remaining balance first; anything
  # that cannot be removed becomes the lot's unrecovered clawback.
  defp revoke_entitlements(payment, operation_id, posting) do
    Repo.all(from(c in CreditLotContribution, where: c.payment_id == ^payment.id))
    |> Enum.each(fn contribution ->
      lot = Repo.get!(CreditLot, contribution.lot_id)
      clawback = min(contribution.entitlement_cents, lot.remaining_cents)

      Repo.update_all(
        from(l in CreditLot, where: l.id == ^lot.id),
        inc: [
          remaining_cents: -clawback,
          unrecovered_clawback_cents: contribution.entitlement_cents - clawback
        ]
      )

      FinanceReporting.record_credit_movement(operation_id, posting, "revoked", clawback, lot.id)
      FinanceReporting.record_lot_delta(operation_id, posting, lot.id, -clawback)
    end)
  end

  defp durable_payment(operation_id, not_target_code) do
    case Repo.get_by(DurableOperation, operation_id: operation_id) do
      nil ->
        {:reject, "operation_not_found", %{}}

      durable ->
        result = Jason.decode!(durable.result_json)

        if durable.op_type == "record_cash_payment" and result["status"] == "applied" do
          case Repo.get_by(Payment, operation_id: operation_id) do
            nil -> {:reject, not_target_code, %{}}
            payment -> {:ok, payment}
          end
        else
          {:reject, not_target_code, %{}}
        end
    end
  end

  defp group_of_payment(payment) do
    case Repo.get(Group, payment.group_id) do
      nil -> {:reject, "group_not_found", %{}}
      group -> {:ok, group}
    end
  end

  ## transfer_deposit

  defp transfer_deposit(op, ctx) do
    with {:ok, source_group_id} <- required_string(op, "source_group_id"),
         {:ok, destination_group_id} <- required_string(op, "destination_group_id"),
         {:ok, source} <- transfer_group(source_group_id),
         {:ok, destination} <- transfer_group(destination_group_id),
         :ok <- check_revision(op, source),
         :ok <- destination_revision_check(op, destination),
         {:ok, amount} <- amount(op) do
      cond do
        source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
          reject("invalid_transfer")

        source.status != "active" ->
          reject("group_not_active", %{"group_id" => source.group_id})

        destination.status != "active" ->
          reject("group_not_active", %{"group_id" => destination.group_id})

        RoomAccounting.held_total(source) < amount ->
          reject("transfer_exceeds_held_funding")

        Groups.outstanding(destination) < amount ->
          reject("transfer_exceeds_outstanding")

        true ->
          source_outstanding = Groups.outstanding(source)
          destination_outstanding = Groups.outstanding(destination)
          posting = reporting_posting_date(op, ctx)

          {moved_payments, moved_cash} =
            RoomAccounting.move_held_funding(source, destination, amount)

          mark_transfer_participation(moved_payments)

          FinanceReporting.record_movement(
            ctx.operation_id,
            posting,
            "transferred_out",
            source.property_id,
            moved_cash
          )

          FinanceReporting.record_movement(
            ctx.operation_id,
            posting,
            "transferred_in",
            destination.property_id,
            moved_cash
          )

          bump_revision(source)
          bump_revision(destination)

          {:apply,
           %{
             "operation_id" => ctx.operation_id,
             "status" => "applied",
             "source_group_id" => source_group_id,
             "destination_group_id" => destination_group_id,
             "amount_cents" => amount,
             "source_outstanding_deposit_cents" => source_outstanding + amount,
             "destination_outstanding_deposit_cents" => destination_outstanding - amount,
             "source_revision" => source.revision + 1,
             "destination_revision" => destination.revision + 1
           }}
      end
    else
      {:reject, code, meta} -> reject(code, meta)
      _ -> reject("invalid_operation")
    end
  end

  # Transfer group lookups resolve existence with the named group_id so a
  # rejection can name the missing group.
  defp transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        {:reject, "group_not_found", %{"group_id" => group_id}}

      group ->
        LegacyFunding.ensure_forwarded(group)
        {:ok, group}
    end
  end

  defp destination_revision_check(op, group) do
    case Map.get(op, "destination_expected_revision") do
      nil ->
        :ok

      expected when expected == group.revision ->
        :ok

      expected ->
        {:reject, "stale_revision",
         %{
           "group_id" => group.group_id,
           "expected_revision" => expected,
           "actual_revision" => group.revision
         }}
    end
  end

  defp mark_transfer_participation(payment_ids) do
    if MapSet.size(payment_ids) > 0 do
      Repo.update_all(
        from(p in Payment, where: p.id in ^MapSet.to_list(payment_ids)),
        set: [participated_in_transfer: true]
      )
    end

    :ok
  end

  ## start_finance_reporting

  # The first applied start operation enables finance reporting. It does not
  # address a group and has no revision guard. A different start operation
  # is rejected once reporting has started; a retry of the original follows
  # the durable replay rules and returns its stored applied result.
  defp start_finance_reporting(op, ctx) do
    case reporting_starts_on(op) do
      :error ->
        reject("invalid_reporting_date")

      {:ok, starts_on} ->
        case FinanceReporting.start(ctx.operation_id, starts_on) do
          {:error, :already_started} ->
            reject("reporting_already_started")

          {:ok, starts_on} ->
            {:apply,
             %{
               "operation_id" => ctx.operation_id,
               "status" => "applied",
               "starts_on" => Date.to_iso8601(starts_on)
             }}
        end
    end
  end

  defp reporting_starts_on(op) do
    case Map.get(op, "starts_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> :error
        end

      _ ->
        :error
    end
  end

  # An applied operation bumps every group whose state it changed in
  # addition to the group it is addressed to.
  defp bump_affected_groups(group, affected_group_ids) do
    Enum.each(affected_group_ids, fn group_id ->
      if group_id != group.id do
        {_count, _} =
          Repo.update_all(from(g in Group, where: g.id == ^group_id), inc: [revision: 1])
      end
    end)
  end

  defp iso_date(nil), do: nil
  defp iso_date(date), do: Date.to_iso8601(date)
end
