defmodule GroupStay.Deposits do
  @moduledoc """
  Group deposit records and the partner operations that maintain them.

  Every partner operation runs inside its own transaction, together with the
  durable idempotency record for its `operation_id`: a handled rejection
  commits its record while leaving domain state unchanged, and an unexpected
  exception rolls the operation back without remembering it. The batch
  continues with the next operation after a handled rejection.

  Funds are tracked at room level. Cash allocations and credit applications
  fill active rooms in their original order, and every group money total is
  derived from the active rooms' allocations, so the group, room, ledger,
  and payment-reconciliation views all report the same disposition of cash.
  """

  import Ecto.Query

  alias Ecto.Changeset

  alias GroupStay.Deposits.{
    CashAllocation,
    CreditApplication,
    CreditLot,
    CreditLotFunding,
    FinanceClose,
    FinanceMovement,
    FinanceOpening,
    FinanceReportDay,
    FinanceReporting,
    Group,
    Operation,
    Room
  }

  alias GroupStay.Repo

  @busy_retry_attempts 20
  @busy_retry_sleep 25

  @operation_types ~w[
    open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit
    cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit
    start_finance_reporting close_finance_period
  ]
  @rate_plans ~w[flexible advance_purchase]
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @policy_cutoff ~D[2027-01-01]
  @refund_methods ~w[cash hotel_credit]

  @finance_cash_kinds ~w[
    received transferred_in transferred_out refunded retained converted reduced
    charged_back
  ]
  @finance_credit_kinds ~w[issued expired consumed revoked absorbed]

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
    dispositions =
      from(c in CashAllocation,
        group_by: c.disposed,
        select: {c.disposed, coalesce(sum(c.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      cash_held_cents: Map.get(dispositions, nil, 0),
      cash_refunded_cents: Map.get(dispositions, "refunded", 0),
      cash_retained_cents: Map.get(dispositions, "retained", 0),
      cash_converted_to_credit_cents: Map.get(dispositions, "converted", 0),
      cash_reduced_cents: Map.get(dispositions, "reduced", 0),
      cash_charged_back_cents: Map.get(dispositions, "charged_back", 0),
      credit_shortfall_cents: credit_shortfall_cents(),
      credit_liability_cents: credit_liability_cents(on || Date.utc_today())
    }
  end

  @doc """
  Returns the daily finance report for `date`, or `{:error, :not_available}`
  when reporting has not started or `date` precedes `starts_on`.

  A close publishes every report through its cutoff: those days are returned
  as raw JSON fragments of the text frozen when the close committed, so their
  `data` value is byte-for-byte stable across later operations, later closes,
  and process restarts. Later days are computed live.
  """
  def daily_finance_report(date) do
    case Repo.one(FinanceReporting) do
      nil ->
        {:error, :not_available}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :not_available}
        else
          case Repo.get_by(FinanceReportDay, report_date: date) do
            nil ->
              {:ok, build_finance_report(date, reporting, "open")}

            frozen ->
              {:ok,
               %Jason.Fragment{
                 encode: fn _opts -> frozen.data end
               }}
          end
        end
    end
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

  @doc """
  Returns the current disposition statement for one durably recorded, applied
  cash payment, or `{:error, :not_found}` / `{:error, :not_reconcilable}`.
  """
  def get_payment_statement(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        {:error, :not_found}

      operation ->
        result = Jason.decode!(operation.result)

        if operation.type == "record_cash_payment" and result["status"] == "applied" do
          rows =
            from(c in CashAllocation,
              where: c.payment_operation_id == ^payment_operation_id,
              group_by: c.disposed,
              select: {c.disposed, coalesce(sum(c.amount_cents), 0)}
            )
            |> Repo.all()
            |> Map.new()

          recorded_cents = rows |> Map.values() |> Enum.sum()

          statement =
            %{
              payment_operation_id: payment_operation_id,
              original_group_id: result["group_id"],
              recorded_cents: recorded_cents,
              held_cents: Map.get(rows, nil, 0),
              refunded_cents: Map.get(rows, "refunded", 0),
              retained_cents: Map.get(rows, "retained", 0),
              converted_to_credit_cents: Map.get(rows, "converted", 0),
              reduced_cents: Map.get(rows, "reduced", 0),
              charged_back_cents: Map.get(rows, "charged_back", 0)
            }

          # Once any cash from a payment has participated in a transfer the
          # statement reports where its held cash currently funds rooms.
          if operation.involved_in_transfer do
            held_by_group =
              from(c in CashAllocation,
                join: g in Group,
                on: g.id == c.group_id,
                where: c.payment_operation_id == ^payment_operation_id and is_nil(c.disposed),
                group_by: g.group_id,
                order_by: [asc: g.group_id],
                select: {g.group_id, coalesce(sum(c.amount_cents), 0)}
              )
              |> Repo.all()
              |> Enum.map(fn {group_id, amount_cents} ->
                %{group_id: group_id, amount_cents: amount_cents}
              end)

            {:ok, Map.put(statement, :held_by_group, held_by_group)}
          else
            {:ok, statement}
          end
        else
          {:error, :not_reconcilable}
        end
    end
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
  defp apply_decoded(%{type: "cancel_rooms"} = op), do: apply_cancel_rooms(op)
  defp apply_decoded(%{type: "reduce_cash_payment"} = op), do: apply_reduce(op)
  defp apply_decoded(%{type: "charge_back_payment"} = op), do: apply_charge_back(op)
  defp apply_decoded(%{type: "transfer_deposit"} = op), do: apply_transfer(op)
  defp apply_decoded(%{type: "start_finance_reporting"} = op), do: apply_start(op)
  defp apply_decoded(%{type: "close_finance_period"} = op), do: apply_close(op)

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
        "cancel_rooms" -> decode_cancel_rooms(raw, base)
        "reduce_cash_payment" -> decode_reduce(raw, base)
        "charge_back_payment" -> decode_charge_back(raw, base)
        "transfer_deposit" -> decode_transfer(raw, base)
        "start_finance_reporting" -> decode_start(raw, base)
        "close_finance_period" -> decode_close(raw, base)
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

  defp decode_cancel_rooms(raw, base) do
    with {:ok, group_id} <- string_field(raw, "group_id"),
         {:ok, room_ids} <- room_ids_field(raw),
         {:ok, refund_method} <- refund_method_of(raw),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "cancel_rooms",
         group_id: group_id,
         room_ids: room_ids,
         refund_method: refund_method,
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_reduce(raw, base) do
    with {:ok, payment_operation_id} <- string_field(raw, "payment_operation_id"),
         :ok <- amount_present?(raw),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "reduce_cash_payment",
         payment_operation_id: payment_operation_id,
         amount_cents: Map.get(raw, "amount_cents"),
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_charge_back(raw, base) do
    with {:ok, payment_operation_id} <- string_field(raw, "payment_operation_id"),
         {:ok, expected_revision} <- optional_revision(raw) do
      {:ok,
       Map.merge(base, %{
         type: "charge_back_payment",
         payment_operation_id: payment_operation_id,
         expected_revision: expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_transfer(raw, base) do
    with {:ok, source_group_id} <- string_field(raw, "source_group_id"),
         {:ok, destination_group_id} <- string_field(raw, "destination_group_id"),
         :ok <- amount_present?(raw),
         {:ok, expected_revision} <- optional_revision(raw),
         {:ok, destination_expected_revision} <-
           optional_revision(raw, "destination_expected_revision") do
      {:ok,
       Map.merge(base, %{
         type: "transfer_deposit",
         source_group_id: source_group_id,
         destination_group_id: destination_group_id,
         amount_cents: Map.get(raw, "amount_cents"),
         expected_revision: expected_revision,
         destination_expected_revision: destination_expected_revision
       })}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp decode_start(raw, base) do
    case Map.fetch(raw, "starts_on") do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            {:ok, Map.merge(base, %{type: "start_finance_reporting", starts_on: date})}

          _ ->
            {:error, "invalid_reporting_date"}
        end

      _ ->
        {:error, "invalid_reporting_date"}
    end
  end

  defp decode_close(raw, base) do
    case Map.fetch(raw, "period_end_on") do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            {:ok, Map.merge(base, %{type: "close_finance_period", period_end_on: date})}

          _ ->
            {:error, "invalid_period"}
        end

      _ ->
        {:error, "invalid_period"}
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

  defp optional_revision(raw, key \\ "expected_revision") do
    case Map.fetch(raw, key) do
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

  defp room_ids_field(raw) do
    case Map.fetch(raw, "room_ids") do
      {:ok, room_ids} when is_list(room_ids) ->
        if Enum.all?(room_ids, &is_binary/1),
          do: {:ok, room_ids},
          else: {:error, "invalid_operation"}

      _ ->
        {:error, "invalid_operation"}
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
      deposit_due =
        op.rooms
        |> Enum.map(fn room ->
          room_deposit(nights * room.nightly_rate_cents, op.rate_plan)
        end)
        |> Enum.sum()

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
          revision: 1
        })

      Enum.each(op.rooms, fn room ->
        Repo.insert!(%Room{
          group_id: group.id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: "active",
          deposit_due_cents: room_deposit(nights * room.nightly_rate_cents, op.rate_plan)
        })
      end)

      %{
        operation_id: op.operation_id,
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: deposit_due,
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
          allocate_funding(group.id, op.amount_cents, fn room, take ->
            Repo.insert!(%CashAllocation{
              group_id: group.id,
              room_id: room.id,
              payment_operation_id: op.operation_id,
              amount_cents: take
            })
          end)

          record_movements(op, [
            %{kind: "received", property_id: group.property_id, amount_cents: op.amount_cents}
          ])

          revision = group.revision + 1
          update_group(group, %{revision: revision})

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            amount_cents: op.amount_cents,
            outstanding_deposit_cents: outstanding_of(group.id),
            revision: revision
          }
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_), do: {:error, "invalid_amount"}

  defp validate_outstanding(group, amount) do
    if amount <= outstanding_of(group.id),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end

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

  ## cancel_group and cancel_rooms

  defp apply_cancel(op) do
    case find_group(op) do
      {:error, code} ->
        rejected(op, code)

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             :ok <- refund_method_available?(group, op) do
          {room_ids, _room_codes} = active_room_id_lists(group.id)
          {refunded, retained, issued} = settle_rooms(group, op, room_ids)
          revision = group.revision + 1

          update_group(group, %{status: "cancelled", revision: revision})

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            refunded_cents: refunded,
            retained_cents: retained,
            credit_issued_cents: issued,
            revision: revision
          }
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp apply_cancel_rooms(op) do
    case find_group(op) do
      {:error, code} ->
        rejected(op, code)

      group ->
        with :ok <- check_revision(group, op),
             :ok <- require_active(group),
             :ok <- validate_room_selection(group.id, op.room_ids),
             :ok <- refund_method_available?(group, op) do
          {room_ids, room_codes} = selected_room_id_lists(group.id, op.room_ids)
          {refunded, retained, issued} = settle_rooms(group, op, room_ids)

          revision = group.revision + 1
          status = if active_room_count(group.id) > 0, do: "active", else: "cancelled"
          update_group(group, %{status: status, revision: revision})

          %{
            operation_id: op.operation_id,
            status: "applied",
            group_id: group.group_id,
            cancelled_room_ids: room_codes,
            refunded_cents: refunded,
            retained_cents: retained,
            credit_issued_cents: issued,
            revision: revision
          }
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp validate_room_selection(group_id, room_ids) do
    cond do
      room_ids == [] -> {:error, "invalid_rooms"}
      length(Enum.uniq(room_ids)) != length(room_ids) -> {:error, "invalid_rooms"}
      true -> validate_rooms_active(group_id, room_ids)
    end
  end

  # Every supplied identifier must name a distinct active room of this group.
  defp validate_rooms_active(group_id, room_ids) do
    active_ids =
      from(r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        select: r.room_id
      )
      |> Repo.all()
      |> MapSet.new()

    if Enum.all?(room_ids, &MapSet.member?(active_ids, &1)),
      do: :ok,
      else: {:error, "invalid_rooms"}
  end

  # Returns the selected rooms' database ids together with the caller-supplied
  # room ids in the group's original room order.
  defp selected_room_id_lists(group_id, room_ids) do
    from(r in Room,
      where: r.group_id == ^group_id and r.status == "active" and r.room_id in ^room_ids,
      order_by: [asc: r.id],
      select: {r.id, r.room_id}
    )
    |> Repo.all()
    |> Enum.unzip()
  end

  defp active_room_id_lists(group_id) do
    from(r in Room,
      where: r.group_id == ^group_id and r.status == "active",
      order_by: [asc: r.id],
      select: {r.id, r.room_id}
    )
    |> Repo.all()
    |> Enum.unzip()
  end

  defp active_room_count(group_id) do
    from(r in Room, where: r.group_id == ^group_id and r.status == "active", select: count(r.id))
    |> Repo.one()
  end

  defp refund_method_available?(_group, %{refund_method: "cash"}), do: :ok

  defp refund_method_available?(group, %{refund_method: "hotel_credit"} = op) do
    if refundable?(group, op.occurred_on),
      do: :ok,
      else: {:error, "refund_method_not_available"}
  end

  # Settles the selected rooms' held cash and applied credit under the same
  # policy, refund method, bonus, and restoration rules as a full cancellation.
  defp settle_rooms(group, op, room_ids) do
    refundable = refundable?(group, op.occurred_on)

    rooms =
      from(r in Room,
        where: r.group_id == ^group.id and r.status == "active" and r.id in ^room_ids,
        order_by: [asc: r.id]
      )
      |> Repo.all()

    cash_rows =
      from(c in CashAllocation,
        where: c.group_id == ^group.id and is_nil(c.disposed) and c.room_id in ^room_ids,
        order_by: [asc: c.id]
      )
      |> Repo.all()

    cash = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))

    {refunded, retained, converted, issued} =
      cond do
        refundable and op.refund_method == "hotel_credit" ->
          {0, 0, cash, credit_amount(cash)}

        refundable ->
          {cash, 0, 0, 0}

        true ->
          {0, cash, 0, 0}
      end

    disposition =
      cond do
        converted > 0 -> "converted"
        refundable -> "refunded"
        true -> "retained"
      end

    Enum.each(cash_rows, fn row -> update_cash(row, %{disposed: disposition}) end)

    lot =
      if converted > 0 do
        lot =
          Repo.insert!(%CreditLot{
            guest_id: group.guest_id,
            source_operation_id: op.operation_id,
            remaining_cents: issued,
            expires_on: Date.add(op.occurred_on, 366),
            unrecovered_clawback_cents: 0
          })

        create_funding(lot, cash_rows)
        lot
      end

    {consumed, absorbed, expired_immediately, restores} =
      settle_credit(group, room_ids, op.occurred_on, refundable)

    movements =
      cash_movements(cash, disposition, group) ++
        issued_movements(lot, issued, op) ++
        credit_settlement_movements(consumed, absorbed, expired_immediately, restores)

    record_movements(op, movements)

    Enum.each(rooms, fn room -> update_room(room, %{status: "cancelled"}) end)

    {refunded, retained, issued}
  end

  defp cash_movements(0, _disposition, _group), do: []

  defp cash_movements(cash, disposition, group) do
    [%{kind: disposition, property_id: group.property_id, amount_cents: cash}]
  end

  # Issuing a lot raises the credit liability by its full value and adds the
  # same amount to the lot's remaining balance. A lot that is already expired
  # at its posting date (an extremely backdated conversion) is issued and
  # expired on the same day so the liability effect nets to zero.
  defp issued_movements(nil, _issued, _op), do: []

  defp issued_movements(lot, issued, op) do
    movements = [
      %{
        kind: "issued",
        property_id: nil,
        amount_cents: issued,
        lot_id: lot.id,
        remaining_delta_cents: issued
      }
    ]

    case reporting_posting(op) do
      nil ->
        movements

      posting ->
        if Date.compare(lot.expires_on, posting) == :gt,
          do: movements,
          else: movements ++ [%{kind: "expired", property_id: nil, amount_cents: issued}]
    end
  end

  defp credit_settlement_movements(consumed, absorbed, expired_immediately, restores) do
    movements =
      if consumed > 0,
        do: [%{kind: "consumed", property_id: nil, amount_cents: consumed}],
        else: []

    movements =
      if absorbed > 0,
        do: movements ++ [%{kind: "absorbed", property_id: nil, amount_cents: absorbed}],
        else: movements

    movements =
      if expired_immediately > 0,
        do:
          movements ++ [%{kind: "expired", property_id: nil, amount_cents: expired_immediately}],
        else: movements

    movements ++
      Enum.map(restores, fn {lot_id, excess} ->
        %{
          kind: "credit_restored",
          property_id: nil,
          amount_cents: 0,
          lot_id: lot_id,
          remaining_delta_cents: excess
        }
      end)
  end

  # Hotel credit is worth 110% of the funded cash; the 10% bonus follows the
  # standard rounding rule.
  defp credit_amount(cash), do: cash + percent_round_half_up(cash, @credit_bonus_percent)

  # Records each funding source's telescoping entitlement on the new lot in
  # room-accounting funding order: the unattributed senior block first, then
  # durable payments in commit order.
  defp create_funding(lot, cash_rows) do
    sources = cash_rows |> Enum.map(& &1.payment_operation_id) |> Enum.uniq()

    {_running_total, _previous_value} =
      Enum.reduce(sources, {0, 0}, fn source, {running_total, previous_value} ->
        amount =
          cash_rows
          |> Enum.filter(&(&1.payment_operation_id == source))
          |> Enum.map(& &1.amount_cents)
          |> Enum.sum()

        running_total = running_total + amount
        value = credit_amount(running_total)
        entitlement = value - previous_value

        Repo.insert!(%CreditLotFunding{
          credit_lot_id: lot.id,
          payment_operation_id: source,
          cash_cents: amount,
          entitlement_cents: entitlement
        })

        {running_total, value}
      end)
  end

  # Settles the selected rooms' applied credit. Returns the reporting
  # effects: consumed liability (non-refundable), clawback absorption,
  # immediately-expired restorations, and per-lot remaining-balance gains.
  defp settle_credit(group, room_ids, occurred_on, refundable) do
    applications =
      from(a in CreditApplication,
        where: a.group_id == ^group.id and a.room_id in ^room_ids,
        preload: [:credit_lot]
      )
      |> Repo.all()

    result =
      if refundable do
        # A refundable cancellation returns applied credit to its original lot
        # unless that lot has already expired, in which case the restored amount
        # expires immediately instead of becoming available again. Credit
        # returning to a shortfalled lot first extinguishes the lot's
        # unrecovered clawback: only the excess becomes available or expires.
        # Restorations are aggregated per lot so several rooms sharing one lot
        # cannot overwrite each other's update.
        applications
        |> Enum.group_by(& &1.credit_lot_id)
        |> Enum.reduce({0, 0, []}, fn {_lot_id, lot_applications},
                                      {absorbed_total, expired_total, restores} ->
          lot = List.first(lot_applications).credit_lot
          amount = Enum.sum(Enum.map(lot_applications, & &1.amount_cents))

          absorbed = min(lot.unrecovered_clawback_cents, amount)
          excess = amount - absorbed

          changes = %{unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed}

          changes =
            if excess > 0 and Date.compare(lot.expires_on, occurred_on) == :gt do
              Map.put(changes, :remaining_cents, lot.remaining_cents + excess)
            else
              changes
            end

          update_lot(lot, changes)

          expired_extra =
            if excess > 0 and Date.compare(lot.expires_on, occurred_on) != :gt,
              do: excess,
              else: 0

          restored =
            if excess > 0 and Date.compare(lot.expires_on, occurred_on) == :gt,
              do: [{lot.id, excess}],
              else: []

          {absorbed_total + absorbed, expired_total + expired_extra, restores ++ restored}
        end)
        |> then(fn {absorbed, expired, restores} -> {0, absorbed, expired, restores} end)
      else
        consumed = Enum.sum(Enum.map(applications, & &1.amount_cents))
        {consumed, 0, 0, []}
      end

    Enum.each(applications, fn application -> Repo.delete!(application) end)

    result
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
    entries =
      consumed
      |> Enum.filter(fn {_lot, taken} -> taken > 0 end)
      |> Enum.map(fn {lot, taken} ->
        %{
          kind: "credit_applied",
          property_id: nil,
          amount_cents: 0,
          lot_id: lot.id,
          remaining_delta_cents: -taken
        }
      end)

    Enum.each(consumed, fn {lot, taken} ->
      if taken > 0 do
        update_lot(lot, %{remaining_cents: lot.remaining_cents - taken})

        allocate_funding(group.id, taken, fn room, piece ->
          Repo.insert!(%CreditApplication{
            group_id: group.id,
            credit_lot_id: lot.id,
            room_id: room.id,
            amount_cents: piece
          })
        end)
      end
    end)

    # Applying credit moves liability from available to applied: no finance
    # movement column, only the lot's remaining-balance delta.
    record_movements(op, entries)

    revision = group.revision + 1
    update_group(group, %{revision: revision})

    %{
      operation_id: op.operation_id,
      status: "applied",
      group_id: group.group_id,
      amount_cents: op.amount_cents,
      outstanding_deposit_cents: outstanding_of(group.id),
      revision: revision
    }
  end

  ## reduce_cash_payment

  defp apply_reduce(op) do
    case applied_cash_payment_group(op.payment_operation_id, "payment_not_reducible") do
      {:error, code} ->
        rejected(op, code)

      {:ok, group} ->
        with :ok <- check_revision(group, op),
             :ok <- validate_amount(op.amount_cents) do
          held_rows = held_rows_of(op.payment_operation_id)
          held = Enum.sum(Enum.map(held_rows, & &1.amount_cents))

          cond do
            held == 0 ->
              rejected(op, "payment_not_reducible")

            op.amount_cents > held ->
              rejected(op, "reduction_exceeds_held_cash")

            true ->
              # Held allocations from one payment can now span several
              # groups after transfers. Every group whose held funding is
              # reduced increments its revision; the addressed original
              # payment group always does.
              related_group_ids =
                held_rows |> Enum.map(& &1.group_id) |> Enum.uniq()

              properties =
                related_group_ids
                |> Map.new(fn group_id -> {group_id, property_of(group_id)} end)

              {_remaining, reduced_entries} =
                reduce_held_rows(held_rows, op.amount_cents, properties)

              record_movements(
                op,
                Enum.map(reduced_entries, fn {property_id, take} ->
                  %{kind: "reduced", property_id: property_id, amount_cents: take}
                end)
              )

              revision = bump_group_revisions(group, related_group_ids)

              %{
                operation_id: op.operation_id,
                status: "applied",
                payment_operation_id: op.payment_operation_id,
                group_id: group.group_id,
                amount_cents: op.amount_cents,
                outstanding_deposit_cents: outstanding_of(group.id),
                revision: revision
              }
          end
        else
          {:error, code} -> rejected(op, code)
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  # Removes held allocations in reverse fill order, reporting how much each
  # property's held cash was reduced.
  defp reduce_held_rows(rows, amount, properties) do
    Enum.reduce_while(rows, {amount, []}, fn row, {remaining, entries} ->
      if remaining <= 0 do
        {:halt, {0, entries}}
      else
        take = min(row.amount_cents, remaining)

        if take == row.amount_cents do
          update_cash(row, %{disposed: "reduced"})
        else
          update_cash(row, %{amount_cents: row.amount_cents - take})

          Repo.insert!(%CashAllocation{
            group_id: row.group_id,
            room_id: row.room_id,
            payment_operation_id: row.payment_operation_id,
            amount_cents: take,
            disposed: "reduced"
          })
        end

        entry = if take > 0, do: [{Map.fetch!(properties, row.group_id), take}], else: []
        {:cont, {remaining - take, entries ++ entry}}
      end
    end)
  end

  ## charge_back_payment

  defp apply_charge_back(op) do
    case applied_cash_payment_group(op.payment_operation_id, "payment_not_chargeable") do
      {:error, code} ->
        rejected(op, code)

      {:ok, group} ->
        with :ok <- check_revision(group, op) do
          rows = payment_rows(op.payment_operation_id)

          cond do
            Enum.any?(rows, &(&1.disposed == "charged_back")) ->
              rejected(op, "payment_not_chargeable")

            Enum.all?(rows, &(&1.disposed == "reduced")) ->
              rejected(op, "payment_not_chargeable")

            true ->
              charge_back(group, op, rows)
          end
        else
          {:stale, expected, actual} -> stale_rejected(op, group, expected, actual)
        end
    end
  end

  defp charge_back(group, op, rows) do
    # Everything except previously reduced cash moves to charged back.
    remaining = Enum.reject(rows, &(&1.disposed == "reduced"))
    charged_back_cents = Enum.sum(Enum.map(remaining, & &1.amount_cents))

    movements = charge_back_movements(remaining)
    posting = reporting_posting(op)

    Enum.each(remaining, fn row -> update_cash(row, %{disposed: "charged_back"}) end)

    movements = movements ++ revoke_credit_entitlements(op.payment_operation_id, posting)

    record_movements(op, movements)

    # Held cash may now fund rooms in other groups after transfers; removing
    # it reopens their outstanding, so each of those groups increments its
    # revision as well as the addressed original payment group.
    related_group_ids =
      rows
      |> Enum.filter(&is_nil(&1.disposed))
      |> Enum.map(& &1.group_id)
      |> Enum.uniq()

    revision = bump_group_revisions(group, related_group_ids)

    %{
      operation_id: op.operation_id,
      status: "applied",
      payment_operation_id: op.payment_operation_id,
      group_id: group.group_id,
      charged_back_cents: charged_back_cents,
      outstanding_deposit_cents: outstanding_of(group.id),
      revision: revision
    }
  end

  # Reclassification follows the affected cash to the property where it is
  # held or where it was settled: the charged-back amount lands on that
  # property and the reversed disposition reports the opposite sign there.
  defp charge_back_movements(rows) do
    Enum.flat_map(rows, fn row ->
      property_id = property_of(row.group_id)

      charged_back = [
        %{kind: "charged_back", property_id: property_id, amount_cents: row.amount_cents}
      ]

      reversed =
        case row.disposed do
          "refunded" ->
            [%{kind: "refunded", property_id: property_id, amount_cents: -row.amount_cents}]

          "retained" ->
            [%{kind: "retained", property_id: property_id, amount_cents: -row.amount_cents}]

          "converted" ->
            [%{kind: "converted", property_id: property_id, amount_cents: -row.amount_cents}]

          _ ->
            []
        end

      charged_back ++ reversed
    end)
  end

  # Removes this payment's entitlement from every lot it funded. What cannot
  # be removed from the lot's remaining balance becomes unrecovered clawback.
  # Credit that already expired at the posting date is fully unrecoverable:
  # its liability has already left through expiry, so its remaining balance
  # is left untouched and the revocation reports no movement.
  defp revoke_credit_entitlements(payment_operation_id, posting) do
    funding =
      from(f in CreditLotFunding,
        where: f.payment_operation_id == ^payment_operation_id,
        preload: [:credit_lot]
      )
      |> Repo.all()

    Enum.flat_map(funding, fn funding ->
      lot = funding.credit_lot
      alive = is_nil(posting) or Date.compare(lot.expires_on, posting) == :gt
      removable = if alive, do: min(funding.entitlement_cents, lot.remaining_cents), else: 0

      update_lot(lot, %{
        remaining_cents: lot.remaining_cents - removable,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + (funding.entitlement_cents - removable)
      })

      [
        %{
          kind: "revoked",
          property_id: nil,
          amount_cents: removable,
          lot_id: lot.id,
          remaining_delta_cents: -removable
        }
      ]
    end)
  end

  ## transfer_deposit

  defp apply_transfer(op) do
    source = Repo.get_by(Group, group_id: op.source_group_id)
    destination = Repo.get_by(Group, group_id: op.destination_group_id)

    cond do
      is_nil(source) ->
        rejected_transfer(op, %{code: "group_not_found", group_id: op.source_group_id})

      is_nil(destination) ->
        rejected_transfer(op, %{code: "group_not_found", group_id: op.destination_group_id})

      true ->
        apply_transfer_between(source, destination, op)
    end
  end

  defp apply_transfer_between(source, destination, op) do
    # Existence was resolved for both groups first. The source revision is
    # checked before the destination revision, and both are checked before
    # the transfer rules themselves.
    case check_revision(source, %{expected_revision: op.expected_revision}) do
      {:stale, expected, actual} ->
        stale_rejected(op, source, expected, actual)

      :ok ->
        case check_revision(destination, %{expected_revision: op.destination_expected_revision}) do
          {:stale, expected, actual} ->
            stale_rejected(op, destination, expected, actual)

          :ok ->
            case transfer_preconditions(source, destination, op.amount_cents) do
              :ok -> move_transfer(source, destination, op)
              {:error, attrs} -> rejected_transfer(op, attrs)
            end
        end
    end
  end

  defp transfer_preconditions(source, destination, amount) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, %{code: "invalid_transfer"}}

      source.status != "active" ->
        {:error, %{code: "group_not_active", group_id: source.group_id}}

      destination.status != "active" ->
        {:error, %{code: "group_not_active", group_id: destination.group_id}}

      validate_amount(amount) != :ok ->
        {:error, %{code: "invalid_amount"}}

      amount > held_funding_cents(source.id) ->
        {:error, %{code: "transfer_exceeds_held_funding"}}

      amount > outstanding_of(destination.id) ->
        {:error, %{code: "transfer_exceeds_outstanding"}}

      true ->
        :ok
    end
  end

  defp held_funding_cents(group_id) do
    cash =
      from(c in CashAllocation,
        where: c.group_id == ^group_id and is_nil(c.disposed),
        select: coalesce(sum(c.amount_cents), 0)
      )
      |> Repo.one()

    credit =
      from(a in CreditApplication,
        where: a.group_id == ^group_id,
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one()

    cash + credit
  end

  # Moves held funding without settling or revaluing it: each allocation row
  # keeps its provenance (payment operation identity or credit lot) and simply
  # changes which active room it funds. Held cash draws from the most recently
  # created allocations first, regardless of funding kind, and the destination's
  # rooms fill in their original order, preserving the order the units were
  # drawn in.
  defp move_transfer(source, destination, op) do
    involved =
      Enum.reduce(
        source_units(source.id),
        {op.amount_cents, [], destination_rooms(destination.id), []},
        fn
          _unit, {remaining, involved, _rooms, entries} when remaining <= 0 ->
            {0, involved, [], entries}

          unit, {remaining, involved, rooms, entries} ->
            take = min(unit.amount_cents, remaining)

            if take > 0 do
              {updated_rooms, involved} = place_unit(unit, take, rooms, destination, involved)
              entries = transfer_entries(unit, take, source, destination, entries)
              {remaining - take, involved, updated_rooms, entries}
            else
              {remaining, involved, rooms, entries}
            end
        end
      )
      |> then(fn {_remaining, involved, _rooms, entries} ->
        record_movements(op, Enum.reverse(entries))
        involved
      end)

    mark_involved_payments(involved)

    source_revision = source.revision + 1
    destination_revision = destination.revision + 1
    update_group(source, %{revision: source_revision})
    update_group(destination, %{revision: destination_revision})

    %{
      operation_id: op.operation_id,
      status: "applied",
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: op.amount_cents,
      source_outstanding_deposit_cents: outstanding_of(source.id),
      destination_outstanding_deposit_cents: outstanding_of(destination.id),
      source_revision: source_revision,
      destination_revision: destination_revision
    }
  end

  # The source group's held funding, most recently allocated first: cash
  # allocations and credit applications together, ordered by creation time.
  # The unattributed senior block allocated cash before credit, so credit is
  # treated as the later of the two when creation timestamps tie.
  defp source_units(group_id) do
    cash =
      from(c in CashAllocation, where: c.group_id == ^group_id and is_nil(c.disposed))
      |> Repo.all()
      |> Enum.map(fn row -> %{kind: :cash, row: row, amount_cents: row.amount_cents} end)

    credit =
      from(a in CreditApplication, where: a.group_id == ^group_id)
      |> Repo.all()
      |> Enum.map(fn row -> %{kind: :credit, row: row, amount_cents: row.amount_cents} end)

    Enum.sort(cash ++ credit, &allocation_newer?/2)
  end

  defp allocation_newer?(a, b) do
    case NaiveDateTime.compare(a.row.inserted_at, b.row.inserted_at) do
      :gt ->
        true

      :lt ->
        false

      :eq ->
        cond do
          kind_rank(a) > kind_rank(b) -> true
          kind_rank(a) < kind_rank(b) -> false
          true -> a.row.id > b.row.id
        end
    end
  end

  defp kind_rank(%{kind: :cash}), do: 0
  defp kind_rank(%{kind: :credit}), do: 1

  # Only held cash moves the finance report: a transfer records equal
  # transferred-out and transferred-in amounts on the source and destination
  # properties. Moved hotel credit stays applied and changes no total.
  defp transfer_entries(%{kind: :cash}, take, source, destination, entries) do
    entries ++
      [
        %{kind: "transferred_out", property_id: source.property_id, amount_cents: take},
        %{kind: "transferred_in", property_id: destination.property_id, amount_cents: take}
      ]
  end

  defp transfer_entries(%{kind: :credit}, _take, _source, _destination, entries), do: entries

  # Destination rooms in their original order, each with its remaining deposit
  # capacity: per-room deposit due minus the cash and credit already held.
  defp destination_rooms(group_id) do
    rooms =
      from(r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: [asc: r.id]
      )
      |> Repo.all()

    paid = paid_by_room(group_id)

    Enum.map(rooms, fn room ->
      details = Map.get(paid, room.id, %{cash: 0, credit: 0})
      cap = max((room.deposit_due_cents || 0) - details.cash - details.credit, 0)
      {room, cap}
    end)
  end

  # Places one drawn unit into the destination, filling its rooms in original
  # order. Returns the rooms with their updated capacities and the payments
  # whose held cash participated in this transfer.
  defp place_unit(%{kind: :cash} = unit, take, rooms, destination, involved) do
    {updated_rooms, pieces} = split_destination(take, rooms)

    if pieces == [] do
      {updated_rooms, involved}
    else
      involved = maybe_involve(unit.row.payment_operation_id, involved)

      if take == unit.amount_cents do
        [{first_room_id, first_amount} | rest_pieces] = pieces
        move_allocation_in_place(unit.row, destination.id, first_room_id, first_amount)

        Enum.each(rest_pieces, fn {room_id, piece} ->
          insert_cash_allocation(destination.id, room_id, unit.row.payment_operation_id, piece)
        end)
      else
        update_allocation_amount(unit.row, unit.row.amount_cents - take)

        Enum.each(pieces, fn {room_id, piece} ->
          insert_cash_allocation(destination.id, room_id, unit.row.payment_operation_id, piece)
        end)
      end

      {updated_rooms, involved}
    end
  end

  defp place_unit(%{kind: :credit} = unit, take, rooms, destination, involved) do
    {updated_rooms, pieces} = split_destination(take, rooms)

    if pieces == [] do
      {updated_rooms, involved}
    else
      if take == unit.amount_cents do
        [{first_room_id, first_amount} | rest_pieces] = pieces
        move_allocation_in_place(unit.row, destination.id, first_room_id, first_amount)

        Enum.each(rest_pieces, fn {room_id, piece} ->
          insert_credit_application(destination.id, room_id, unit.row.credit_lot_id, piece)
        end)
      else
        update_allocation_amount(unit.row, unit.row.amount_cents - take)

        Enum.each(pieces, fn {room_id, piece} ->
          insert_credit_application(destination.id, room_id, unit.row.credit_lot_id, piece)
        end)
      end

      {updated_rooms, involved}
    end
  end

  # Splits `amount` across the destination rooms in their original order,
  # reducing each room's capacity by the piece it takes.
  defp split_destination(amount, rooms) do
    {updated_rooms, {pieces, _remaining}} =
      Enum.map_reduce(rooms, {[], amount}, fn {room, cap}, {pieces, remaining} ->
        take = min(cap, remaining)
        pieces = if take > 0, do: [{room.id, take} | pieces], else: pieces
        {{room, cap - take}, {pieces, remaining - take}}
      end)

    {updated_rooms, Enum.reverse(pieces)}
  end

  # A fully drawn unit keeps its identity but funds the destination now; its
  # allocation timestamp moves forward so later transfers see it as the most
  # recently created allocation on its new group.
  defp move_allocation_in_place(row, group_id, room_id, amount) do
    changes = %{group_id: group_id, room_id: room_id, amount_cents: amount}

    changes
    |> Map.put(:inserted_at, NaiveDateTime.utc_now())
    |> then(&allocation_changeset(row, &1))
    |> Repo.update!()
  end

  defp update_allocation_amount(row, amount) do
    allocation_changeset(row, %{amount_cents: amount})
    |> Repo.update!()
  end

  defp allocation_changeset(%CashAllocation{} = row, changes),
    do: Changeset.change(row, changes)

  defp allocation_changeset(%CreditApplication{} = row, changes),
    do: Changeset.change(row, changes)

  defp insert_cash_allocation(group_id, room_id, payment_operation_id, amount) do
    Repo.insert!(%CashAllocation{
      group_id: group_id,
      room_id: room_id,
      payment_operation_id: payment_operation_id,
      amount_cents: amount
    })
  end

  defp insert_credit_application(group_id, room_id, credit_lot_id, amount) do
    Repo.insert!(%CreditApplication{
      group_id: group_id,
      room_id: room_id,
      credit_lot_id: credit_lot_id,
      amount_cents: amount
    })
  end

  defp maybe_involve(nil, involved), do: involved
  defp maybe_involve(payment_operation_id, involved), do: [payment_operation_id | involved]

  defp mark_involved_payments(ids) do
    ids
    |> Enum.uniq()
    |> case do
      [] ->
        :ok

      ids ->
        from(o in Operation,
          where: o.operation_id in ^ids and o.type == "record_cash_payment"
        )
        |> Repo.update_all(set: [involved_in_transfer: true])

        :ok
    end
  end

  defp rejected_transfer(op, attrs) do
    base = %{operation_id: op.operation_id, status: "rejected", code: attrs.code}

    case Map.fetch(attrs, :group_id) do
      {:ok, group_id} -> Map.put(base, :group_id, group_id)
      :error -> base
    end
  end

  ## Payment-targeting shared helpers

  # Resolves a payment_operation_id to the group addressed by its original
  # payment. Returns `notification_code` when no durable record exists.
  defp applied_cash_payment_group(payment_operation_id, notification_code) do
    operation = Repo.get_by(Operation, operation_id: payment_operation_id)

    result =
      if operation do
        Jason.decode!(operation.result)
      end

    cond do
      is_nil(operation) ->
        {:error, "operation_not_found"}

      operation.type != "record_cash_payment" or not is_map(result) or
          result["status"] != "applied" ->
        {:error, notification_code}

      true ->
        case Repo.get_by(Group, group_id: result["group_id"]) do
          nil -> {:error, notification_code}
          group -> {:ok, group}
        end
    end
  end

  defp held_rows_of(payment_operation_id) do
    from(c in CashAllocation,
      where: c.payment_operation_id == ^payment_operation_id and is_nil(c.disposed),
      order_by: [desc: c.inserted_at, desc: c.id]
    )
    |> Repo.all()
  end

  defp payment_rows(payment_operation_id) do
    from(c in CashAllocation,
      where: c.payment_operation_id == ^payment_operation_id,
      order_by: [asc: c.id]
    )
    |> Repo.all()
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

  # Increments the addressed group's revision exactly once, plus the revision
  # of every related group whose state changed without double-incrementing the
  # addressed group. Returns the addressed group's new revision.
  defp bump_group_revisions(%Group{} = group, related_group_ids) do
    revision = group.revision + 1
    update_group(group, %{revision: revision})

    Enum.each(related_group_ids, fn group_id ->
      if group_id != group.id do
        related = Repo.get!(Group, group_id)
        update_group(related, %{revision: related.revision + 1})
      end
    end)

    revision
  end

  defp update_group(%Group{} = group, changes) do
    group
    |> Changeset.change(changes)
    |> Repo.update!()
  end

  defp update_room(%Room{} = room, changes) do
    room
    |> Changeset.change(changes)
    |> Repo.update!()
  end

  defp update_lot(%CreditLot{} = lot, changes) do
    lot
    |> Changeset.change(changes)
    |> Repo.update!()
  end

  defp update_cash(%CashAllocation{} = row, changes) do
    row
    |> Changeset.change(changes)
    |> Repo.update!()
  end

  ## Room-level allocation

  defp active_room_query(group_id) do
    from(r in Room,
      where: r.group_id == ^group_id and r.status == "active",
      order_by: [asc: r.id]
    )
  end

  # Distributes one funding amount across the active rooms in their original
  # order, filling each room's remaining deposit before moving to the next.
  defp allocate_funding(group_id, amount, insert) do
    rooms = active_room_query(group_id) |> Repo.all()
    paid = paid_by_room(group_id)

    Enum.reduce_while(rooms, amount, fn room, remaining ->
      if remaining <= 0 do
        {:halt, remaining}
      else
        details = Map.get(paid, room.id, %{cash: 0, credit: 0})
        cap = max((room.deposit_due_cents || 0) - details.cash - details.credit, 0)
        take = min(cap, remaining)

        if take > 0 do
          insert.(room, take)
        end

        {:cont, remaining - take}
      end
    end)
  end

  # Cash and credit currently funding each room, keyed by room id.
  defp paid_by_room(group_id) do
    cash =
      from(c in CashAllocation,
        where: c.group_id == ^group_id and is_nil(c.disposed),
        group_by: c.room_id,
        select: {c.room_id, coalesce(sum(c.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    credit =
      from(a in CreditApplication,
        where: a.group_id == ^group_id,
        group_by: a.room_id,
        select: {a.room_id, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    cash
    |> Map.keys()
    |> Kernel.++(Map.keys(credit))
    |> Enum.uniq()
    |> Map.new(fn room_id ->
      {room_id, %{cash: Map.get(cash, room_id, 0), credit: Map.get(credit, room_id, 0)}}
    end)
  end

  defp outstanding_of(group_id) do
    rooms = active_room_query(group_id) |> Repo.all()
    paid = paid_by_room(group_id)
    due = Enum.sum(Enum.map(rooms, &(&1.deposit_due_cents || 0)))

    held =
      Enum.reduce(rooms, 0, fn room, total ->
        details = Map.get(paid, room.id, %{cash: 0, credit: 0})
        total + details.cash + details.credit
      end)

    due - held
  end

  defp credit_shortfall_cents do
    applied =
      from(a in CreditApplication,
        join: g in Group,
        on: g.id == a.group_id,
        where: g.status == "active",
        group_by: a.credit_lot_id,
        select: {a.credit_lot_id, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    from(l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, Map.get(applied, lot.id, 0))
    end)
  end

  ## Finance reporting

  # The first applied start operation enables reporting. The financial state
  # immediately before it is processed becomes the opening position on
  # `starts_on`: operations before the start in the same batch are already
  # part of it because the snapshot happens inside this operation.
  defp apply_start(op) do
    if reporting_started?() do
      rejected(op, "reporting_already_started")
    else
      snapshot_reporting(op)

      %{
        operation_id: op.operation_id,
        status: "applied",
        starts_on: Date.to_iso8601(op.starts_on)
      }
    end
  end

  defp reporting_started?() do
    Repo.exists?(from(r in FinanceReporting))
  end

  defp snapshot_reporting(op) do
    Repo.insert!(%FinanceReporting{
      starts_on: op.starts_on,
      opening_liability_cents: credit_liability_cents(op.starts_on)
    })

    from(c in CashAllocation,
      join: g in Group,
      on: g.id == c.group_id,
      where: is_nil(c.disposed),
      group_by: g.property_id,
      select: {g.property_id, coalesce(sum(c.amount_cents), 0)}
    )
    |> Repo.all()
    |> Enum.each(fn {property_id, amount_cents} ->
      Repo.insert!(%FinanceOpening{
        property_id: property_id,
        opening_held_cents: amount_cents
      })
    end)
  end

  # A close publishes every report through `period_end_on`. It applies only
  # after reporting started, when the cutoff is on or after `starts_on`, and
  # when it advances the latest successful close; anything else is an
  # `invalid_period` rejection. Freezing the covered days inside this
  # operation's transaction keeps later operations, later closes, and process
  # restarts from ever changing a published report.
  defp apply_close(op) do
    case close_validation(op) do
      {:ok, period_end_on} ->
        freeze_reports_through(period_end_on)

        Repo.insert!(%FinanceClose{
          period_end_on: period_end_on,
          operation_id: op.operation_id
        })

        %{
          operation_id: op.operation_id,
          status: "applied",
          period_end_on: Date.to_iso8601(period_end_on)
        }

      {:error, code} ->
        rejected(op, code)
    end
  end

  defp close_validation(op) do
    case Repo.one(FinanceReporting) do
      nil ->
        {:error, "invalid_period"}

      reporting ->
        latest = latest_close_cutoff()

        cond do
          Date.compare(op.period_end_on, reporting.starts_on) == :lt ->
            {:error, "invalid_period"}

          not is_nil(latest) and Date.compare(op.period_end_on, latest) != :gt ->
            {:error, "invalid_period"}

          true ->
            {:ok, op.period_end_on}
        end
    end
  end

  defp freeze_reports_through(period_end_on) do
    reporting = Repo.one!(FinanceReporting)

    frozen =
      from(d in FinanceReportDay, select: d.report_date)
      |> Repo.all()
      |> MapSet.new()

    reporting.starts_on
    |> Date.range(period_end_on)
    |> Enum.each(fn date ->
      unless MapSet.member?(frozen, date) do
        report = build_finance_report(date, reporting, "closed")

        Repo.insert!(%FinanceReportDay{
          report_date: date,
          data: Jason.encode!(report)
        })
      end
    end)
  end

  defp latest_close_cutoff do
    from(c in FinanceClose, select: max(c.period_end_on))
    |> Repo.one()
  end

  # Durable movement journaling. Nothing is recorded before reporting has
  # started: every previously committed operation is folded into the opening
  # position instead. Once reporting has started the posting date is fixed
  # when the operation commits; a movement posting after the day the operation
  # naturally belongs to carries the `late` flag so reports can list it under
  # `late_adjustments`.
  defp record_movements(op, entries) do
    case posting_context(op) do
      nil ->
        :ok

      context ->
        late = Date.compare(context.posting, context.natural) == :gt

        Enum.each(entries, fn entry ->
          amount = Map.fetch!(entry, :amount_cents)

          if amount != 0 or Map.get(entry, :remaining_delta_cents, 0) != 0 do
            Repo.insert!(%FinanceMovement{
              posting_date: context.posting,
              property_id: Map.get(entry, :property_id),
              kind: Map.fetch!(entry, :kind),
              amount_cents: amount,
              lot_id: Map.get(entry, :lot_id),
              remaining_delta_cents: Map.get(entry, :remaining_delta_cents),
              operation_id: op.operation_id,
              late: late
            })
          end
        end)
    end
  end

  # The posting day an operation reports on: max(occurred_on, starts_on, the
  # first open day after the latest close at the moment it commits). The
  # `natural` day is where the operation would post without any close, and
  # decides whether its movements are late adjustments.
  defp posting_context(op) do
    case Repo.one(FinanceReporting) do
      nil ->
        nil

      reporting ->
        natural = later_date(op.occurred_on, reporting.starts_on)

        first_open =
          case latest_close_cutoff() do
            nil -> nil
            cutoff -> Date.add(cutoff, 1)
          end

        posting =
          if is_nil(first_open), do: natural, else: later_date(natural, first_open)

        %{posting: posting, natural: natural}
    end
  end

  defp reporting_posting(op) do
    case posting_context(op) do
      nil -> nil
      context -> context.posting
    end
  end

  defp later_date(a, b) do
    if Date.compare(a, b) == :lt, do: b, else: a
  end

  defp property_of(group_id) do
    Repo.get!(Group, group_id).property_id
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

  # The report for one day shows the opening position at the start of that
  # day, the day's movements, and the closing position. The snapshot taken by
  # `start_finance_reporting` anchors the opening of `starts_on`; every later
  # day opens at the previous day's closing. Movements are therefore per-day
  # signed amounts, and a chargeback reversing an earlier refund reports a
  # negative `refunded_cents` next to a positive `charged_back_cents`.
  defp build_finance_report(date, reporting, status) do
    openings =
      from(o in FinanceOpening)
      |> Repo.all()
      |> Map.new(fn opening -> {opening.property_id, opening.opening_held_cents} end)

    prior =
      from(m in FinanceMovement,
        where:
          m.posting_date < ^date and m.kind in ^@finance_cash_kinds and
            not is_nil(m.property_id),
        group_by: [m.property_id, m.kind],
        select: {m.property_id, m.kind, coalesce(sum(m.amount_cents), 0)}
      )
      |> Repo.all()

    day =
      from(m in FinanceMovement,
        where:
          m.posting_date == ^date and m.kind in ^@finance_cash_kinds and
            not is_nil(m.property_id) and not m.late,
        group_by: [m.property_id, m.kind],
        select: {m.property_id, m.kind, coalesce(sum(m.amount_cents), 0)}
      )
      |> Repo.all()

    late =
      from(m in FinanceMovement,
        where:
          m.posting_date == ^date and m.kind in ^@finance_cash_kinds and
            not is_nil(m.property_id) and m.late,
        group_by: [m.property_id, m.kind],
        select: {m.property_id, m.kind, coalesce(sum(m.amount_cents), 0)}
      )
      |> Repo.all()

    property_ids =
      openings
      |> Map.keys()
      |> Kernel.++(Enum.map(prior, &elem(&1, 0)))
      |> Kernel.++(Enum.map(day, &elem(&1, 0)))
      |> Kernel.++(Enum.map(late, &elem(&1, 0)))
      |> Enum.uniq()

    cash =
      property_ids
      |> Enum.map(fn property_id ->
        prior_sums = kind_sums(prior, property_id)
        day_sums = kind_sums(day, property_id)
        late_sums = kind_sums(late, property_id)
        opening = Map.get(openings, property_id, 0) + cash_delta(prior_sums)
        closing = opening + cash_delta(day_sums) + cash_delta(late_sums)

        {property_id, opening, day_sums, late_sums, closing}
      end)
      |> Enum.filter(fn {_property_id, opening, day_sums, late_sums, closing} ->
        opening != 0 or closing != 0 or
          Enum.any?(day_sums, fn {_kind, amount} -> amount != 0 end) or
          Enum.any?(late_sums, fn {_kind, amount} -> amount != 0 end)
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property_id, opening, day_sums, _late_sums, closing} ->
        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: cash_movements_map(day_sums),
          closing_held_cents: closing
        }
      end)

    late_cash =
      property_ids
      |> Enum.map(fn property_id -> {property_id, kind_sums(late, property_id)} end)
      |> Enum.filter(fn {_property_id, sums} ->
        Enum.any?(sums, fn {_kind, amount} -> amount != 0 end)
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property_id, sums} ->
        %{property_id: property_id, movements: cash_movements_map(sums)}
      end)

    {credit, late_credit} = build_credit_report(date, reporting)

    %{
      date: date,
      status: status,
      cash: cash,
      late_adjustments: %{cash: late_cash, credit: late_credit},
      credit: credit
    }
  end

  defp cash_movements_map(sums) do
    %{
      received_cents: sums["received"],
      transferred_in_cents: sums["transferred_in"],
      transferred_out_cents: sums["transferred_out"],
      refunded_cents: sums["refunded"],
      retained_cents: sums["retained"],
      converted_to_credit_cents: sums["converted"],
      reduced_cents: sums["reduced"],
      charged_back_cents: sums["charged_back"]
    }
  end

  defp kind_sums(rows, property_id) do
    sums =
      rows
      |> Enum.filter(&(elem(&1, 0) == property_id))
      |> Map.new(fn {_property_id, kind, amount} -> {kind, amount} end)

    Map.new(@finance_cash_kinds, fn kind -> {kind, Map.get(sums, kind, 0)} end)
  end

  # Held cash changes by received and transferred-in amounts minus every
  # amount that leaves: refunded, retained, converted, reduced, charged back.
  defp cash_delta(sums) do
    sums["received"] + sums["transferred_in"] - sums["transferred_out"] -
      sums["refunded"] - sums["retained"] - sums["converted"] - sums["reduced"] -
      sums["charged_back"]
  end

  defp build_credit_report(date, reporting) do
    day =
      from(m in FinanceMovement,
        where:
          m.posting_date == ^date and m.kind in ^@finance_credit_kinds and
            is_nil(m.property_id) and not m.late,
        group_by: m.kind,
        select: {m.kind, coalesce(sum(m.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    late =
      from(m in FinanceMovement,
        where:
          m.posting_date == ^date and m.kind in ^@finance_credit_kinds and
            is_nil(m.property_id) and m.late,
        group_by: m.kind,
        select: {m.kind, coalesce(sum(m.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    prior =
      from(m in FinanceMovement,
        where:
          m.posting_date < ^date and m.kind in ^@finance_credit_kinds and
            is_nil(m.property_id),
        group_by: m.kind,
        select: {m.kind, coalesce(sum(m.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    issued_day = Map.get(day, "issued", 0)
    consumed_day = Map.get(day, "consumed", 0)
    revoked_day = Map.get(day, "revoked", 0)
    absorbed_day = Map.get(day, "absorbed", 0)

    prior_expired =
      Map.get(prior, "expired", 0) + natural_expiry_before(date, reporting.starts_on)

    expired_day = Map.get(day, "expired", 0) + natural_expiry_on(date, reporting.starts_on)

    opening =
      reporting.opening_liability_cents + Map.get(prior, "issued", 0) - prior_expired -
        Map.get(prior, "consumed", 0) - Map.get(prior, "revoked", 0) -
        Map.get(prior, "absorbed", 0)

    late_issued = Map.get(late, "issued", 0)
    late_expired = Map.get(late, "expired", 0)
    late_consumed = Map.get(late, "consumed", 0)
    late_revoked = Map.get(late, "revoked", 0)
    late_absorbed = Map.get(late, "absorbed", 0)

    closing =
      opening + issued_day - expired_day - consumed_day - revoked_day - absorbed_day +
        late_issued - late_expired - late_consumed - late_revoked - late_absorbed

    credit = %{
      opening_liability_cents: opening,
      movements: %{
        issued_cents: issued_day,
        expired_cents: expired_day,
        consumed_cents: consumed_day,
        revoked_cents: revoked_day,
        absorbed_cents: absorbed_day
      },
      closing_liability_cents: closing
    }

    late_credit = %{
      issued_cents: late_issued,
      expired_cents: late_expired,
      consumed_cents: late_consumed,
      revoked_cents: late_revoked,
      absorbed_cents: late_absorbed
    }

    {credit, late_credit}
  end

  # Credit that remains unused through its `expires_on` expires on the
  # following date. The amount expired is the lot's remaining balance on that
  # date, reconstructed from its current balance minus every remaining-balance
  # delta journaled after the expiry date. Lots that expired before reporting
  # started never contributed to the opening position and are ignored.
  defp natural_expiry_on(date, starts_on) do
    expiry_base = Date.add(date, -1)

    if Date.compare(expiry_base, starts_on) == :lt do
      0
    else
      from(l in CreditLot, where: l.expires_on == ^expiry_base)
      |> Repo.all()
      |> Enum.reduce(0, fn lot, total -> total + remaining_at(lot, date) end)
    end
  end

  defp natural_expiry_before(date, starts_on) do
    upper = Date.add(date, -2)

    if Date.compare(upper, starts_on) == :lt do
      0
    else
      from(l in CreditLot,
        where: l.expires_on >= ^starts_on and l.expires_on <= ^upper
      )
      |> Repo.all()
      |> Enum.reduce(0, fn lot, total ->
        total + remaining_at(lot, Date.add(lot.expires_on, 1))
      end)
    end
  end

  defp remaining_at(lot, expiry_date) do
    future =
      from(m in FinanceMovement,
        where:
          m.lot_id == ^lot.id and not is_nil(m.remaining_delta_cents) and
            m.posting_date > ^expiry_date,
        select: coalesce(sum(m.remaining_delta_cents), 0)
      )
      |> Repo.one()

    lot.remaining_cents - future
  end

  defp render_group(group) do
    rooms =
      from(r in Room, where: r.group_id == ^group.id, order_by: [asc: r.id])
      |> Repo.all()

    paid = paid_by_room(group.id)
    active = Enum.filter(rooms, &(&1.status == "active"))
    nights = Date.diff(group.departure_on, group.arrival_on)

    lodging_total = nights * Enum.sum(Enum.map(active, & &1.nightly_rate_cents))
    deposit_due = Enum.sum(Enum.map(active, &(&1.deposit_due_cents || 0)))

    {cash_paid, credit_paid} =
      Enum.reduce(active, {0, 0}, fn room, {cash_total, credit_total} ->
        details = Map.get(paid, room.id, %{cash: 0, credit: 0})
        {cash_total + details.cash, credit_total + details.credit}
      end)

    room_maps =
      Enum.map(rooms, fn room ->
        details = Map.get(paid, room.id, %{cash: 0, credit: 0})

        %{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: room.status,
          deposit_due_cents: room.deposit_due_cents,
          cash_paid_cents: details.cash,
          credit_paid_cents: details.credit
        }
      end)

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
      rooms: room_maps,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      deposit_paid_cents: cash_paid + credit_paid,
      cash_paid_cents: cash_paid,
      credit_paid_cents: credit_paid,
      outstanding_deposit_cents: deposit_due - cash_paid - credit_paid
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
