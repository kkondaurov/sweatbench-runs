defmodule GroupStay.Partner do
  @moduledoc """
  Applies partner operations to group reservations.

  Operations are applied in the order they arrive. Each one runs in its own
  transaction, so a rejected operation leaves the domain exactly as it was and
  processing continues with the next operation.

  `operation_id` makes that work idempotent. The first submission of an
  identifier is applied and remembered along with the result it returned; a later
  submission of the same payload replays that result without reading or changing
  domain state, and the same identifier carrying a different payload is refused.
  A remembered payment is also the handle a later correction or chargeback
  addresses, and neither of those ever rewrites the payment's stored result.
  """

  alias GroupStay.Finance
  alias GroupStay.Operations
  alias GroupStay.Partner.Params
  alias GroupStay.Payments
  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.Reservations.Group

  @types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group
            cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit
            start_finance_reporting)
  @refund_methods ~w(cash hotel_credit)

  @doc """
  Processes a partner batch body.

  Returns `{:ok, results}` with one result per operation, in order, or
  `{:error, :invalid_batch}` when the body carries no operations array.
  """
  def process_batch(%{"operations" => operations}) when is_list(operations) do
    {:ok, Enum.map(operations, &process_operation/1)}
  end

  def process_batch(_params), do: {:error, :invalid_batch}

  # An operation that does not name itself cannot be remembered, so it is rejected
  # without ever reaching the domain.
  defp process_operation(params) when is_map(params) do
    case Params.string(params, "operation_id") do
      {:ok, operation_id} -> process_identified(operation_id, params)
      :error -> unidentified_rejection()
    end
  end

  defp process_operation(_params), do: unidentified_rejection()

  defp unidentified_rejection do
    %{operation_id: nil, status: "rejected", code: "invalid_operation"}
  end

  defp process_identified(operation_id, params) do
    case Operations.fetch(operation_id) do
      {:ok, record} -> replay(record, operation_id, params)
      :error -> execute(operation_id, params)
    end
  end

  # A retry is answered from the record alone: current domain state, including
  # revisions, is never consulted.
  defp replay(record, operation_id, params) do
    if Operations.same_request?(record, params) do
      record.result
    else
      %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
    end
  end

  # An applied operation and its record commit together, so an attempt that loses
  # the race for an identifier loses its domain changes with it. A rejection has
  # no domain changes to keep, so its record commits on its own afterwards.
  defp execute(operation_id, params) do
    Repo.transaction(fn ->
      case dispatch(params, operation_id) do
        {:ok, applied} ->
          result = finish(applied, operation_id, "applied")

          case Operations.remember(operation_id, params, result) do
            {:ok, _record} -> result
            {:error, _changeset} -> Repo.rollback(:identifier_taken)
          end

        {:error, rejection} ->
          Repo.rollback({:rejected, finish(rejection, operation_id, "rejected")})
      end
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, {:rejected, result}} ->
        case Operations.remember(operation_id, params, result) do
          {:ok, _record} -> result
          {:error, _changeset} -> process_identified(operation_id, params)
        end

      # Whichever attempt recorded the identifier first owns the answer.
      {:error, :identifier_taken} ->
        process_identified(operation_id, params)
    end
  end

  defp finish(fields, operation_id, status) do
    fields
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, status)
  end

  defp dispatch(params, operation_id) do
    case Params.string(params, "type") do
      {:ok, type} when type in @types -> dispatch_type(type, params, operation_id)
      _ -> invalid_operation()
    end
  end

  # Every operation that reaches a group happens on a date. Starting finance
  # reporting names its own date instead, so it does not need one.
  defp dispatch_type("start_finance_reporting", params, operation_id),
    do: start_finance_reporting_operation(params, operation_id)

  defp dispatch_type(type, params, operation_id) do
    case Params.date(params, "occurred_on") do
      {:ok, occurred_on} -> apply_operation(type, params, occurred_on, operation_id)
      :error -> invalid_operation()
    end
  end

  defp apply_operation("open_group", params, occurred_on, _operation_id),
    do: open_group_operation(params, occurred_on)

  defp apply_operation("record_cash_payment", params, occurred_on, operation_id),
    do: record_cash_payment_operation(params, occurred_on, operation_id)

  defp apply_operation("apply_hotel_credit", params, occurred_on, operation_id),
    do: apply_hotel_credit_operation(params, occurred_on, operation_id)

  defp apply_operation("reschedule_group", params, occurred_on, _operation_id),
    do: reschedule_group_operation(params, occurred_on)

  defp apply_operation("cancel_group", params, occurred_on, operation_id),
    do: cancel_group_operation(params, occurred_on, operation_id)

  defp apply_operation("cancel_rooms", params, occurred_on, operation_id),
    do: cancel_rooms_operation(params, occurred_on, operation_id)

  defp apply_operation("reduce_cash_payment", params, occurred_on, _operation_id),
    do: reduce_cash_payment_operation(params, occurred_on)

  defp apply_operation("charge_back_payment", params, occurred_on, _operation_id),
    do: charge_back_payment_operation(params, occurred_on)

  defp apply_operation("transfer_deposit", params, occurred_on, _operation_id),
    do: transfer_deposit_operation(params, occurred_on)

  # --- open_group ---------------------------------------------------------

  defp open_group_operation(params, occurred_on) do
    with {:ok, group_id} <- Params.string(params, "group_id"),
         {:ok, guest_id} <- Params.string(params, "guest_id"),
         {:ok, property_id} <- Params.string(params, "property_id") do
      open_group(params, occurred_on, group_id, guest_id, property_id)
    else
      :error -> invalid_operation()
    end
  end

  defp open_group(params, occurred_on, group_id, guest_id, property_id) do
    with :ok <- ensure_unused_group_id(group_id),
         {:ok, rate_plan} <- fetch_rate_plan(params),
         {:ok, arrival_on, departure_on} <- fetch_stay(params),
         {:ok, rooms} <- fetch_rooms(params) do
      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan
      }

      case Reservations.open_group(attrs, rooms) do
        {:ok, group} ->
          {:ok,
           %{
             group_id: group.group_id,
             deposit_due_cents: group.deposit_due_cents,
             revision: group.revision
           }}

        # Everything else was validated above, so the only way the insert fails is
        # the unique index catching a group opened concurrently.
        {:error, _changeset} ->
          rejection("group_already_exists", group_id)
      end
    else
      {:error, code} -> rejection(code, group_id)
    end
  end

  defp ensure_unused_group_id(group_id) do
    if Reservations.group_exists?(group_id), do: {:error, "group_already_exists"}, else: :ok
  end

  defp fetch_rate_plan(params) do
    with {:ok, rate_plan} <- Params.string(params, "rate_plan"),
         true <- rate_plan in Group.rate_plans() do
      {:ok, rate_plan}
    else
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp fetch_stay(params) do
    with {:ok, arrival_on} <- Params.date(params, "arrival_on"),
         {:ok, departure_on} <- Params.date(params, "departure_on"),
         true <- Date.after?(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp fetch_rooms(params) do
    with rooms when is_list(rooms) and rooms != [] <- Map.get(params, "rooms"),
         {:ok, rooms} <- fetch_each_room(rooms),
         true <- unique?(Enum.map(rooms, fn {room_id, _rate} -> room_id end)) do
      {:ok, rooms}
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp fetch_each_room(rooms) do
    rooms
    |> Enum.reduce_while({:ok, []}, fn room, {:ok, acc} ->
      with true <- is_map(room),
           {:ok, room_id} <- Params.string(room, "room_id"),
           {:ok, rate} when rate >= 0 <- Params.integer(room, "nightly_rate_cents") do
        {:cont, {:ok, [{room_id, rate} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      :error -> :error
    end
  end

  defp unique?(values), do: length(Enum.uniq(values)) == length(values)

  # --- record_cash_payment ------------------------------------------------

  defp record_cash_payment_operation(params, occurred_on, operation_id) do
    with_group(params, fn group ->
      with :ok <- ensure_active(group),
           {:ok, amount_cents} <- fetch_amount(params),
           :ok <- ensure_within_outstanding(group, amount_cents) do
        {:ok, group} =
          Reservations.record_cash_payment(group, amount_cents, operation_id, occurred_on)

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
           revision: group.revision
         }}
      else
        {:error, code} -> rejection(code, group.group_id)
      end
    end)
  end

  defp fetch_amount(params) do
    case Params.integer(params, "amount_cents") do
      {:ok, amount_cents} when amount_cents > 0 -> {:ok, amount_cents}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents > Group.outstanding_deposit_cents(group) do
      {:error, "payment_exceeds_outstanding"}
    else
      :ok
    end
  end

  # --- apply_hotel_credit -------------------------------------------------

  defp apply_hotel_credit_operation(params, occurred_on, operation_id) do
    with_group(params, fn group ->
      with :ok <- ensure_active(group),
           {:ok, amount_cents} <- fetch_amount(params),
           :ok <- ensure_within_outstanding(group, amount_cents),
           {:ok, group} <-
             Reservations.apply_hotel_credit(group, amount_cents, occurred_on, operation_id) do
        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
           revision: group.revision
         }}
      else
        {:error, code} -> rejection(code, group.group_id)
      end
    end)
  end

  # --- reschedule_group ---------------------------------------------------

  defp reschedule_group_operation(params, occurred_on) do
    with_group(params, fn group ->
      with :ok <- ensure_active(group),
           {:ok, new_arrival_on} <- fetch_new_arrival(params, occurred_on) do
        {:ok, group} = Reservations.reschedule(group, new_arrival_on)

        {:ok,
         %{
           group_id: group.group_id,
           new_arrival_on: Date.to_iso8601(group.arrival_on),
           new_departure_on: Date.to_iso8601(group.departure_on),
           policy_version: group.policy_version,
           refundable_until: iso_date(Group.refundable_until(group)),
           revision: group.revision
         }}
      else
        {:error, code} -> rejection(code, group.group_id)
      end
    end)
  end

  defp fetch_new_arrival(params, occurred_on) do
    with {:ok, new_arrival_on} <- Params.date(params, "new_arrival_on"),
         true <- Date.after?(new_arrival_on, occurred_on) do
      {:ok, new_arrival_on}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  # --- cancel_group and cancel_rooms --------------------------------------

  defp cancel_group_operation(params, occurred_on, operation_id) do
    with_group(params, fn group ->
      with {:ok, rooms, refund_method} <- prepare_cancellation(group, params, occurred_on) do
        {:ok, group, settlement} =
          Reservations.cancel_rooms(group, rooms, occurred_on, refund_method, operation_id)

        {:ok,
         %{
           group_id: group.group_id,
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: group.revision
         }}
      else
        {:error, code} -> rejection(code, group.group_id)
      end
    end)
  end

  defp cancel_rooms_operation(params, occurred_on, operation_id) do
    with_group(params, fn group ->
      with {:ok, active_rooms, refund_method} <-
             prepare_cancellation(group, params, occurred_on),
           {:ok, rooms} <- select_rooms(params, active_rooms) do
        {:ok, group, settlement} =
          Reservations.cancel_rooms(group, rooms, occurred_on, refund_method, operation_id)

        {:ok,
         %{
           group_id: group.group_id,
           cancelled_room_ids: Enum.map(rooms, & &1.room_id),
           refunded_cents: settlement.refunded_cents,
           retained_cents: settlement.retained_cents,
           credit_issued_cents: settlement.credit_issued_cents,
           revision: group.revision
         }}
      else
        {:error, code} -> rejection(code, group.group_id)
      end
    end)
  end

  # Both cancellations answer to the group's status and its refund method before
  # they look at anything else, and both settle only rooms that are still active.
  defp prepare_cancellation(group, params, occurred_on) do
    with :ok <- ensure_active(group),
         {:ok, refund_method} <- fetch_refund_method(params),
         :ok <- ensure_refund_method_available(group, refund_method, occurred_on) do
      {:ok, Reservations.active_rooms(group), refund_method}
    end
  end

  # Omitting the method means cash, so callers written before hotel credit existed
  # keep working. A method GroupStay cannot settle with is not available.
  defp fetch_refund_method(params) do
    case Map.get(params, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in @refund_methods -> {:ok, method}
      _ -> {:error, "refund_method_not_available"}
    end
  end

  defp ensure_refund_method_available(_group, "cash", _occurred_on), do: :ok

  # Hotel credit is not a way around a non-refundable policy.
  defp ensure_refund_method_available(group, "hotel_credit", occurred_on) do
    if Group.refundable?(group, occurred_on),
      do: :ok,
      else: {:error, "refund_method_not_available"}
  end

  # Every named room must be a distinct room the group still holds. The selection
  # comes back in the group's own room order, whatever order it was supplied in.
  defp select_rooms(params, active_rooms) do
    with room_ids when is_list(room_ids) and room_ids != [] <- Map.get(params, "room_ids"),
         true <- unique?(room_ids),
         selected = Enum.filter(active_rooms, &(&1.room_id in room_ids)),
         true <- length(selected) == length(room_ids) do
      {:ok, selected}
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  # --- reduce_cash_payment and charge_back_payment ------------------------

  defp reduce_cash_payment_operation(params, occurred_on) do
    with_payment(params, "payment_not_reducible", fn target, group ->
      with :ok <- ensure_reducible(target),
           {:ok, amount_cents} <- fetch_amount(params),
           :ok <- ensure_within_held_cash(target, amount_cents) do
        {:ok, group} =
          Reservations.reduce_cash_payment(
            group,
            target.payment_operation_id,
            amount_cents,
            occurred_on
          )

        {:ok,
         %{
           payment_operation_id: target.payment_operation_id,
           group_id: group.group_id,
           amount_cents: amount_cents,
           outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
           revision: group.revision
         }}
      else
        {:error, code} ->
          payment_rejection(code, target.payment_operation_id, group.group_id)
      end
    end)
  end

  defp charge_back_payment_operation(params, occurred_on) do
    with_payment(params, "payment_not_chargeable", fn target, group ->
      with :ok <- ensure_chargeable(target) do
        {:ok, group, charged_back_cents} =
          Reservations.charge_back_payment(group, target.payment_operation_id, occurred_on)

        {:ok,
         %{
           payment_operation_id: target.payment_operation_id,
           group_id: group.group_id,
           charged_back_cents: charged_back_cents,
           outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
           revision: group.revision
         }}
      else
        {:error, code} ->
          payment_rejection(code, target.payment_operation_id, group.group_id)
      end
    end)
  end

  # Cash a cancellation has already settled is history: only cash still held on
  # active rooms can be corrected downwards.
  defp ensure_reducible(target) do
    if Payments.held_cash_cents(target) > 0, do: :ok, else: {:error, "payment_not_reducible"}
  end

  defp ensure_within_held_cash(target, amount_cents) do
    if amount_cents > Payments.held_cash_cents(target),
      do: {:error, "reduction_exceeds_held_cash"},
      else: :ok
  end

  defp ensure_chargeable(target) do
    if Payments.chargeable_cents(target) > 0,
      do: :ok,
      else: {:error, "payment_not_chargeable"}
  end

  # --- transfer_deposit ---------------------------------------------------

  defp transfer_deposit_operation(params, occurred_on) do
    with {:ok, source_id} <- Params.string(params, "source_group_id"),
         {:ok, destination_id} <- Params.string(params, "destination_group_id"),
         {:ok, expected} <- Params.optional_integer(params, "expected_revision"),
         {:ok, destination_expected} <-
           Params.optional_integer(params, "destination_expected_revision") do
      transfer_deposit(
        params,
        occurred_on,
        source_id,
        destination_id,
        expected,
        destination_expected
      )
    else
      :error -> invalid_operation()
    end
  end

  # Both groups are resolved, the source first, and both revision guards are
  # compared before any rule about the funding itself.
  defp transfer_deposit(
         params,
         occurred_on,
         source_id,
         destination_id,
         expected,
         destination_expected
       ) do
    with {:ok, source} <- fetch_group(source_id),
         {:ok, destination} <- fetch_group(destination_id),
         :ok <- compare_revision(source, expected),
         :ok <- compare_revision(destination, destination_expected),
         :ok <- ensure_transferable(source, destination),
         {:ok, amount_cents} <- fetch_amount(params),
         :ok <- ensure_within_held_funding(source, amount_cents),
         :ok <- ensure_within_destination_outstanding(destination, amount_cents) do
      {:ok, source, destination} =
        Reservations.transfer_deposit(source, destination, amount_cents, occurred_on)

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: amount_cents,
         source_outstanding_deposit_cents: Group.outstanding_deposit_cents(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit_cents(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      {:error, code} -> {:error, %{code: code}}
    end
  end

  # Funding only moves between two different active reservations of one guest.
  defp ensure_transferable(source, destination) do
    cond do
      source.group_id == destination.group_id -> {:error, %{code: "invalid_transfer"}}
      source.guest_id != destination.guest_id -> {:error, %{code: "invalid_transfer"}}
      not Group.active?(source) -> not_active(source)
      not Group.active?(destination) -> not_active(destination)
      true -> :ok
    end
  end

  defp not_active(group), do: {:error, %{code: "group_not_active", group_id: group.group_id}}

  defp ensure_within_held_funding(source, amount_cents) do
    if amount_cents > Reservations.held_funding_cents(source),
      do: {:error, %{code: "transfer_exceeds_held_funding"}},
      else: :ok
  end

  defp ensure_within_destination_outstanding(destination, amount_cents) do
    if amount_cents > Group.outstanding_deposit_cents(destination),
      do: {:error, %{code: "transfer_exceeds_outstanding"}},
      else: :ok
  end

  # --- start_finance_reporting --------------------------------------------

  # Reporting starts once. The position everything already committed leaves
  # behind becomes the opening position on `starts_on`, so the operation itself
  # neither addresses a group nor posts a movement of its own.
  defp start_finance_reporting_operation(params, operation_id) do
    with {:ok, starts_on} <- fetch_starts_on(params),
         :ok <- start_reporting(starts_on, operation_id) do
      {:ok, %{starts_on: Date.to_iso8601(starts_on)}}
    else
      {:error, code} -> {:error, %{code: code}}
    end
  end

  defp fetch_starts_on(params) do
    case Params.date(params, "starts_on") do
      {:ok, starts_on} -> {:ok, starts_on}
      :error -> {:error, "invalid_reporting_date"}
    end
  end

  defp start_reporting(starts_on, operation_id) do
    case Finance.start(starts_on, operation_id) do
      {:ok, _reporting} -> :ok
      {:error, :already_started} -> {:error, "reporting_already_started"}
    end
  end

  # --- shared -------------------------------------------------------------

  # Resolves the group named by the operation, then compares revisions, before any
  # other domain rule is evaluated.
  defp with_group(params, fun) do
    with {:ok, group_id} <- Params.string(params, "group_id"),
         {:ok, expected_revision} <- Params.optional_integer(params, "expected_revision") do
      case fetch_group(group_id) do
        {:ok, group} -> check_revision(group, expected_revision, fun)
        {:error, rejection} -> {:error, rejection}
      end
    else
      :error -> invalid_operation()
    end
  end

  defp fetch_group(group_id) do
    case Reservations.get_group(group_id) do
      nil -> {:error, %{code: "group_not_found", group_id: group_id}}
      group -> {:ok, group}
    end
  end

  # A correction addresses a payment rather than a group, so the payment is
  # resolved first and the group it funded is the one whose revision is compared.
  defp with_payment(params, unusable_code, fun) do
    with {:ok, payment_operation_id} <- Params.string(params, "payment_operation_id"),
         {:ok, expected_revision} <- Params.optional_integer(params, "expected_revision") do
      case Payments.fetch_target(payment_operation_id) do
        {:ok, target} -> with_payment_group(target, expected_revision, fun)
        {:error, :not_found} -> payment_rejection("operation_not_found", payment_operation_id)
        {:error, :not_a_payment} -> payment_rejection(unusable_code, payment_operation_id)
      end
    else
      :error -> invalid_operation()
    end
  end

  defp with_payment_group(target, expected_revision, fun) do
    case Reservations.get_group(target.group_id) do
      nil ->
        payment_rejection("group_not_found", target.payment_operation_id, target.group_id)

      group ->
        check_revision(group, expected_revision, &fun.(target, &1))
    end
  end

  defp check_revision(group, expected_revision, fun) do
    case compare_revision(group, expected_revision) do
      :ok -> fun.(group)
      {:error, rejection} -> {:error, rejection}
    end
  end

  # An absent guard is unconditional; a present one is a precondition on the
  # group it names, checked before any other domain rule.
  defp compare_revision(_group, nil), do: :ok

  defp compare_revision(%Group{revision: revision}, revision), do: :ok

  defp compare_revision(group, expected_revision) do
    {:error,
     %{
       code: "stale_revision",
       group_id: group.group_id,
       expected_revision: expected_revision,
       actual_revision: group.revision
     }}
  end

  defp ensure_active(group) do
    if Group.active?(group), do: :ok, else: {:error, "group_not_active"}
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp rejection(code, group_id), do: {:error, %{code: code, group_id: group_id}}

  defp payment_rejection(code, payment_operation_id),
    do: {:error, %{code: code, payment_operation_id: payment_operation_id}}

  defp payment_rejection(code, payment_operation_id, group_id),
    do: {:error, %{code: code, payment_operation_id: payment_operation_id, group_id: group_id}}

  defp invalid_operation, do: {:error, %{code: "invalid_operation"}}
end
