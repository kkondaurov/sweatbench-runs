defmodule GroupStay.Deposits do
  @moduledoc """
  Group deposit records and the partner operations that maintain them.

  Every partner operation runs inside its own transaction, together with the
  durable idempotency record for its `operation_id`: a handled rejection
  commits its record while leaving domain state unchanged, and an unexpected
  exception rolls the operation back without remembering it. The batch
  continues with the next operation after a handled rejection.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Deposits.{CreditApplication, CreditLot, Group, Operation, Room}
  alias GroupStay.Repo

  @busy_retry_attempts 20
  @busy_retry_sleep 25

  @operation_types ~w[open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit]
  @rate_plans ~w[flexible advance_purchase]
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @policy_cutoff ~D[2027-01-01]
  @refund_methods ~w[cash hotel_credit]

  @doc """
  Applies a batch of raw partner operations in order, returning one result
  map per operation.
  """
  def submit(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @doc """
  Returns `{:ok, result}` for a stored operation or `{:error, :not_found}`.
  """
  def get_operation(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :not_found}
      operation -> {:ok, Jason.decode!(operation.result)}
    end
  end

  @doc "Returns `{:ok, props}` for an existing group or `{:error, :not_found}`."
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, render_group(group)}
    end
  end

  @doc """
  Returns the finance totals. Expiry-dependent totals are evaluated as of
  `on`, which defaults to the current UTC date.
  """
  def ledger(on \\ nil) do
    %{
      cash_held_cents:
        Repo.aggregate(where(Group, [g], g.status == "active"), :sum, :cash_paid_cents) || 0,
      cash_refunded_cents: Repo.aggregate(Group, :sum, :refunded_cents) || 0,
      cash_retained_cents: Repo.aggregate(Group, :sum, :retained_cents) || 0,
      cash_converted_to_credit_cents:
        Repo.aggregate(Group, :sum, :cash_converted_to_credit_cents) || 0,
      credit_liability_cents: credit_liability_cents(on || Date.utc_today())
    }
  end

  @doc """
  Returns a guest's available credit lots as of `on`, which defaults to the
  current UTC date. Expired and exhausted lots are omitted.
  """
  def guest_credit(guest_id, on \\ nil) do
    on = on || Date.utc_today()

    lots =
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()
      |> Enum.map(fn lot ->
        %{
          source_operation_id: lot.source_operation_id,
          remaining_cents: lot.remaining_cents,
          expires_on: lot.expires_on
        }
      end)

    available_cents = Enum.reduce(lots, 0, fn lot, total -> lot.remaining_cents + total end)

    %{guest_id: guest_id, available_cents: available_cents, lots: lots}
  end

  defp submit_operation(raw) do
    submit_with_retries(raw, operation_id_of(raw), @busy_retry_attempts)
  end

  defp submit_with_retries(raw, operation_id, attempts) do
    case Repo.transaction(fn -> tracked_apply(raw, operation_id) end) do
      {:ok, result} ->
        result

      {:error, exception} ->
        if retryable_locked?(exception) and attempts > 0 do
          Process.sleep(@busy_retry_sleep)
          submit_with_retries(raw, operation_id, attempts - 1)
        else
          raise exception
        end
    end
  end

  defp retryable_locked?(%Exqlite.Error{} = error) do
    message = Exception.message(error) |> String.downcase()
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp retryable_locked?(_), do: false

  # Operations without an identifier cannot be made idempotent; they follow
  # the plain apply path.
  defp tracked_apply(raw, nil), do: apply_operation(raw)

  defp tracked_apply(raw, operation_id) do
    case insert_claim(raw, operation_id) do
      {:ok, claim} ->
        result = apply_operation(raw)

        claim
        |> Operation.result_changeset(%{result: Jason.encode!(result)})
        |> Repo.update!()

        result

      :claimed_by_another ->
        replay_or_conflict(raw, operation_id)
    end
  end

  # The claim insert is the first statement of the transaction, so SQLite
  # serializes concurrent claims on the unique operation_id index: exactly one
  # transaction can ever apply an identifier, and everyone else replays it.
  defp insert_claim(raw, operation_id) do
    changeset =
      Operation.claim_changeset(%{
        operation_id: operation_id,
        type: raw_type(raw),
        payload: Jason.encode!(raw),
        result: "pending"
      })

    case Repo.insert(changeset) do
      {:ok, claim} -> {:ok, claim}
      {:error, _changeset} -> :claimed_by_another
    end
  rescue
    Ecto.ConstraintError -> :claimed_by_another
  end

  defp replay_or_conflict(raw, operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{} = operation -> replay(operation, raw)
      nil -> raise "lost an idempotency claim but #{operation_id} has no durable record"
    end
  end

  defp replay(operation, raw) do
    if equivalent_payload?(operation.payload, raw) do
      Jason.decode!(operation.result)
    else
      %{operation_id: operation.operation_id, status: "rejected", code: "operation_id_conflict"}
    end
  end

  defp equivalent_payload?(stored_payload, raw) do
    stored_payload
    |> Jason.decode!()
    |> canonical() == canonical(raw)
  end

  # JSON object key order is insignificant; array order and values are not.
  defp canonical(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical(nested)} end)
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp raw_type(raw) do
    case Map.get(raw, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp apply_operation(raw) do
    case decode_operation(raw) do
      {:ok, op} -> apply_decoded(op)
      {:error, code} -> rejected_raw(raw, code)
    end
  end

  defp apply_decoded(%{type: "open_group"} = op), do: apply_open(op)
  defp apply_decoded(%{type: "record_cash_payment"} = op), do: apply_payment(op)
  defp apply_decoded(%{type: "reschedule_group"} = op), do: apply_reschedule(op)
  defp apply_decoded(%{type: "cancel_group"} = op), do: apply_cancel(op)
  defp apply_decoded(%{type: "apply_hotel_credit"} = op), do: apply_credit(op)

  ## Operation decoding (structure -> invalid_operation)

  defp decode_operation(raw) when is_map(raw) do
    with {:ok, type} <- type_of(raw),
         {:ok, operation_id} <- string_field(raw, "operation_id"),
         {:ok, occurred_on} <- occurred_on_of(raw) do
      base = %{operation_id: operation_id, occurred_on: occurred_on}

      case type do
        "open_group" -> decode_open(raw, base)
        "record_cash_payment" -> decode_payment(raw, base)
        "reschedule_group" -> decode_reschedule(raw, base)
        "cancel_group" -> decode_cancel(raw, base)
        "apply_hotel_credit" -> decode_credit(raw, base)
      end
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_operation(_), do: {:error, "invalid_operation"}

  defp decode_open(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         {:ok, guest_id} <- string_field(raw, "guest_id"),
         {:ok, property_id} <- string_field(raw, "property_id"),
         {:ok, rate_plan} <- string_field(raw, "rate_plan"),
         {:ok, arrival_on} <- string_field(raw, "arrival_on"),
         {:ok, departure_on} <- string_field(raw, "departure_on"),
         {:ok, rooms} <- rooms_field(raw) do
      {:ok,
       Map.merge(base, %{
         type: "open_group",
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         rate_plan: rate_plan,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rooms: rooms
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_payment(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         :ok <- amount_present?(raw),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "record_cash_payment",
         group_id: group_id,
         amount_cents: Map.get(raw, "amount_cents"),
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_credit(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         :ok <- amount_present?(raw),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "apply_hotel_credit",
         group_id: group_id,
         amount_cents: Map.get(raw, "amount_cents"),
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_reschedule(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         {:ok, new_arrival_on} <- string_field(raw, "new_arrival_on"),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "reschedule_group",
         group_id: group_id,
         new_arrival_on: new_arrival_on,
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_cancel(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         {:ok, refund_method} <- refund_method_of(raw),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "cancel_group",
         group_id: group_id,
         refund_method: refund_method,
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp type_of(raw) do
    case Map.fetch(raw, "type") do
      {:ok, type} when type in @operation_types -> {:ok, type}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp string_field(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp occurred_on_of(raw) do
    case Map.fetch(raw, "occurred_on") do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_operation"}
        end

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp amount_present?(raw) do
    if Map.has_key?(raw, "amount_cents"), do: :ok, else: {:error, "invalid_operation"}
  end

  defp optional_revision(raw) do
    case Map.fetch(raw, "expected_revision") do
      :error -> {:ok, nil}
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp refund_method_of(raw) do
    case Map.fetch(raw, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, method} when method in @refund_methods -> {:ok, method}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp rooms_field(raw) do
    case raw do
      %{"rooms" => rooms} when is_list(rooms) ->
        normalize_rooms(rooms)

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp normalize_rooms(rooms) do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, acc} ->
      case normalize_room(room) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_room(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and is_integer(rate) do
    {:ok, %{room_id: room_id, nightly_rate_cents: rate}}
  end

  defp normalize_room(_), do: {:error, "invalid_operation"}

  ## open_group

  defp apply_open(op) do
    with :ok <- ensure_group_unknown(op.group_id),
         {:ok, {arrival, departure, nights}} <- stay_dates(op),
         :ok <- validate_rooms(op.rooms),
         :ok <- validate_rate_plan(op.rate_plan) do
      {lodging_total, deposit_due} = compute_amounts(op.rooms, nights, op.rate_plan)

      group =
        Repo.insert!(%Group{
          group_id: op.group_id,
          guest_id: op.guest_id,
          property_id: op.property_id,
          booked_on: op.occurred_on,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op.rate_plan,
          status: "active",
          revision: 1,
          lodging_total_cents: lodging_total,
          deposit_due_cents: deposit_due,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          outstanding_deposit_cents: deposit_due,
          refunded_cents: 0,
          retained_cents: 0,
          cash_converted_to_credit_cents: 0
        })

      Enum.each(op.rooms, fn room ->
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents
        })
      end)

      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:error, code} -> rejected(op, code)
    end
  end

  defp ensure_group_unknown(group_id) do
    if Repo.get_by(Group, group_id: group_id),
      do: {:error, "group_already_exists"},
      else: :ok
  end

  defp stay_dates(op) do
    with {:ok, arrival} <- Date.from_iso8601(op.arrival_on),
         {:ok, departure} <- Date.from_iso8601(op.departure_on) do
      nights = Date.diff(departure, arrival)

      if nights >= 1,
        do: {:ok, {arrival, departure, nights}},
        else: {:error, "invalid_stay"}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp validate_rooms([]), do: {:error, "invalid_rooms"}

  defp validate_rooms(rooms) do
    ids = Enum.map(rooms, & &1.room_id)

    cond do
      length(Enum.uniq(ids)) != length(ids) -> {:error, "invalid_rooms"}
      Enum.any?(rooms, &(&1.nightly_rate_cents < 0)) -> {:error, "invalid_rooms"}
      true -> :ok
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp compute_amounts(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_total, deposit_total} ->
      lodging = nights * room.nightly_rate_cents
      {lodging_total + lodging, deposit_total + room_deposit(lodging, rate_plan)}
    end)
  end

  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp room_deposit(lodging, "flexible"),
    do: percent_round_half_up(lodging, @flexible_deposit_percent)

  # Percentage calculations round to the nearest cent; an exact half-cent rounds
  # upward. Implemented with integer arithmetic so it cannot drift on floats.
  defp percent_round_half_up(amount, percent) do
    numerator = amount * percent

    if rem(numerator, 100) * 2 >= 100,
      do: div(numerator, 100) + 1,
      else: div(numerator, 100)
  end

  ## Cancellation policy

  defp policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  defp policy_version(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp cancellation_window(%Group{rate_plan: "advance_purchase"}), do: nil

  defp cancellation_window(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: 14, else: 30
  end

  defp refundable_until_for(group, arrival_on) do
    case cancellation_window(group) do
      nil -> nil
      window -> Date.add(arrival_on, -window)
    end
  end

  defp refundable?(%Group{rate_plan: "flexible"} = group, occurred_on) do
    Date.diff(group.arrival_on, occurred_on) >= cancellation_window(group)
  end

  defp refundable?(%Group{}, _occurred_on), do: false

  ## record_cash_payment

  defp apply_payment(op) do
    case find_group(op) do
      {:error, code} ->
        rejected(op, code)

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             :ok <- validate_amount(op.amount_cents),
             :ok <- validate_outstanding(group, op.amount_cents) do
          changes = %{
            deposit_paid_cents: group.deposit_paid_cents + op.amount_cents,
            cash_paid_cents: group.cash_paid_cents + op.amount_cents,
            outstanding_deposit_cents: group.outstanding_deposit_cents - op.amount_cents,
            revision: group.revision + 1
          }

          update_group(group, changes)

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            amount_cents: op.amount_cents,
            outstanding_deposit_cents: changes.outstanding_deposit_cents,
            revision: changes.revision
          }
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_), do: {:error, "invalid_amount"}

  defp validate_outstanding(%Group{outstanding_deposit_cents: outstanding}, amount)
       when amount <= outstanding do
    :ok
  end

  defp validate_outstanding(_, _), do: {:error, "payment_exceeds_outstanding"}

  ## reschedule_group

  defp apply_reschedule(op) do
    case find_group(op) do
      {:error, code} ->
        rejected(op, code)

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             {:ok, new_arrival} <- resolvable_new_arrival(op.new_arrival_on, op.occurred_on) do
          shift = Date.diff(new_arrival, group.arrival_on)
          new_departure = Date.add(group.departure_on, shift)
          revision = group.revision + 1
          policy = policy_version(group)
          refundable_until = refundable_until_for(group, new_arrival)

          update_group(group, %{
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: revision
          })

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            new_arrival_on: new_arrival,
            new_departure_on: new_departure,
            policy_version: policy,
            refundable_until: refundable_until,
            revision: revision
          }
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp resolvable_new_arrival(value, occurred_on) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         :gt <- Date.compare(date, occurred_on) do
      {:ok, date}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp resolvable_new_arrival(_, _), do: {:error, "invalid_stay"}

  ## cancel_group

  defp apply_cancel(op) do
    case find_group(op) do
      {:error, code} ->
        rejected(op, code)

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             :ok <- refund_method_available?(group, op) do
          cancel_group(group, op)
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp refund_method_available?(_group, %{refund_method: "cash"}), do: :ok

  defp refund_method_available?(group, %{refund_method: "hotel_credit"} = op) do
    if refundable?(group, op.occurred_on),
      do: :ok,
      else: {:error, "refund_method_not_available"}
  end

  defp cancel_group(group, op) do
    refundable = refundable?(group, op.occurred_on)
    cash = group.cash_paid_cents
    revision = group.revision + 1

    {refunded, retained, converted, issued} =
      cond do
        refundable and op.refund_method == "hotel_credit" ->
          {0, 0, cash, credit_amount(cash)}

        refundable ->
          {cash, 0, 0, 0}

        true ->
          {0, cash, 0, 0}
      end

    if converted > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: op.operation_id,
        remaining_cents: issued,
        expires_on: Date.add(op.occurred_on, 366)
      })
    end

    settle_credit_applications(group, op.occurred_on, refundable)

    update_group(group, %{
      status: "cancelled",
      outstanding_deposit_cents: 0,
      refunded_cents: refunded,
      retained_cents: retained,
      cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
      revision: revision
    })

    %{
      operation_id: op.operation_id,
      status: "applied",
      group_id: group.group_id,
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: issued,
      revision: revision
    }
  end

  # Hotel credit is worth 110% of the funded cash; the 10% bonus follows the
  # standard rounding rule.
  defp credit_amount(cash), do: cash + percent_round_half_up(cash, @credit_bonus_percent)

  defp settle_credit_applications(group, occurred_on, refundable) do
    applications =
      from(a in CreditApplication, where: a.group_id == ^group.id, preload: [:credit_lot])
      |> Repo.all()

    Enum.each(applications, fn application ->
      lot = application.credit_lot

      # A refundable cancellation returns applied credit to its original lot
      # unless that lot has already expired, in which case the restored amount
      # expires immediately instead of becoming available again.
      if refundable and Date.compare(lot.expires_on, occurred_on) == :gt do
        update_lot(lot, %{remaining_cents: lot.remaining_cents + application.amount_cents})
      end

      Repo.delete!(application)
    end)
  end

  ## apply_hotel_credit

  defp apply_credit(op) do
    case find_group(op) do
      {:error, code} ->
        rejected(op, code)

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             :ok <- validate_amount(op.amount_cents),
             :ok <- validate_outstanding(group, op.amount_cents),
             {:ok, consumed} <- consume_lots(group, op.amount_cents, op.occurred_on) do
          apply_consumed(group, op, consumed)
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp consume_lots(group, amount, occurred_on) do
    lots =
      from(l in CreditLot,
        where:
          l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
            l.expires_on > ^occurred_on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

    available = Enum.reduce(lots, 0, fn lot, total -> lot.remaining_cents + total end)

    if available < amount do
      {:error, "insufficient_credit"}
    else
      {consumed, _remaining} =
        Enum.reduce(lots, {[], amount}, fn lot, {consumed, remaining} ->
          taken = min(lot.remaining_cents, remaining)
          {[{lot, taken} | consumed], remaining - taken}
        end)

      {:ok, Enum.reverse(consumed)}
    end
  end

  defp apply_consumed(group, op, consumed) do
    Enum.each(consumed, fn {lot, taken} ->
      if taken > 0 do
        update_lot(lot, %{remaining_cents: lot.remaining_cents - taken})

        Repo.insert!(%CreditApplication{
          group_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: taken
        })
      end
    end)

    changes = %{
      deposit_paid_cents: group.deposit_paid_cents + op.amount_cents,
      credit_paid_cents: group.credit_paid_cents + op.amount_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents - op.amount_cents,
      revision: group.revision + 1
    }

    update_group(group, changes)

    %{
      operation_id: op.operation_id,
      status: "applied",
      group_id: group.group_id,
      amount_cents: op.amount_cents,
      outstanding_deposit_cents: changes.outstanding_deposit_cents,
      revision: changes.revision
    }
  end

  ## Shared domain helpers

  defp find_group(op) do
    case Repo.get_by(Group, group_id: op.group_id) do
      nil -> {:error, "group_not_found"}
      group -> group
    end
  end

  defp check_revision(%Group{}, %{expected_revision: nil}), do: :ok
  defp check_revision(%Group{revision: revision}, %{expected_revision: revision}), do: :ok

  defp check_revision(%Group{revision: actual}, %{expected_revision: expected}),
    do: {:stale, expected, actual}

  defp require_active(%Group{status: "active"}), do: :ok
  defp require_active(_), do: {:error, "group_not_active"}

  defp update_group(%Group{} = group, changes) do
    group
    |> Changeset.change(changes)
    |> Repo.update!()
  end

  defp update_lot(%CreditLot{} = lot, changes) do
    lot
    |> Changeset.change(changes)
    |> Repo.update!()
  end

  ## Results

  defp rejected(op, code) do
    %{operation_id: op.operation_id, status: "rejected", code: code}
  end

  defp stale_rejected(op, group, expected, actual) do
    %{
      operation_id: op.operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group.group_id,
      expected_revision: expected,
      actual_revision: actual
    }
  end

  defp rejected_raw(raw, code) do
    %{operation_id: operation_id_of(raw), status: "rejected", code: code}
  end

  defp operation_id_of(%{"operation_id" => id}) when is_binary(id), do: id
  defp operation_id_of(_), do: nil

  ## Reads

  defp render_group(group) do
    rooms =
      from(r in Room, where: r.group_id == ^group.id, order_by: [asc: r.id])
      |> Repo.all()
      |> Enum.map(&%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents})

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      status: group.status,
      policy_version: policy_version(group),
      refundable_until: refundable_until_for(group, group.arrival_on),
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.outstanding_deposit_cents
    }
  end

  defp credit_liability_cents(on) do
    available =
      Repo.aggregate(
        where(CreditLot, [l], l.remaining_cents > 0 and l.expires_on > ^on),
        :sum,
        :remaining_cents
      ) || 0

    applied =
      from(a in CreditApplication,
        join: g in Group,
        on: g.id == a.group_id,
        where: g.status == "active",
        select: sum(a.amount_cents)
      )
      |> Repo.one()

    available + (applied || 0)
  end
end
