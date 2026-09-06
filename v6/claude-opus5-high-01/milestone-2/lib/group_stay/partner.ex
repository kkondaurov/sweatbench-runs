defmodule GroupStay.Partner do
  @moduledoc """
  Applies partner operations to group reservations.

  Operations are applied in the order they arrive. Each one runs in its own
  transaction, so a rejected operation leaves the database exactly as it was and
  processing continues with the next operation.
  """

  alias GroupStay.Partner.Params
  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.Reservations.Group

  @types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group)
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

  defp process_operation(params) when is_map(params) do
    operation_id =
      case Params.string(params, "operation_id") do
        {:ok, operation_id} -> operation_id
        :error -> nil
      end

    case run(params) do
      {:ok, applied} ->
        applied
        |> Map.put(:operation_id, operation_id)
        |> Map.put(:status, "applied")

      {:error, rejection} ->
        rejection
        |> Map.put(:operation_id, operation_id)
        |> Map.put(:status, "rejected")
    end
  end

  defp process_operation(_params) do
    %{operation_id: nil, status: "rejected", code: "invalid_operation"}
  end

  defp run(params) do
    Repo.transaction(fn ->
      case dispatch(params) do
        {:ok, applied} -> applied
        {:error, rejection} -> Repo.rollback(rejection)
      end
    end)
  end

  defp dispatch(params) do
    with {:ok, operation_id} <- Params.string(params, "operation_id"),
         {:ok, type} when type in @types <- Params.string(params, "type"),
         {:ok, occurred_on} <- Params.date(params, "occurred_on") do
      apply_operation(type, params, occurred_on, operation_id)
    else
      _ -> invalid_operation()
    end
  end

  defp apply_operation("open_group", params, occurred_on, _operation_id),
    do: open_group_operation(params, occurred_on)

  defp apply_operation("record_cash_payment", params, _occurred_on, _operation_id),
    do: record_cash_payment_operation(params)

  defp apply_operation("apply_hotel_credit", params, occurred_on, _operation_id),
    do: apply_hotel_credit_operation(params, occurred_on)

  defp apply_operation("reschedule_group", params, occurred_on, _operation_id),
    do: reschedule_group_operation(params, occurred_on)

  defp apply_operation("cancel_group", params, occurred_on, operation_id),
    do: cancel_group_operation(params, occurred_on, operation_id)

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
         true <- unique_room_ids?(rooms) do
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

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, fn {room_id, _rate} -> room_id end)
    length(Enum.uniq(room_ids)) == length(room_ids)
  end

  # --- record_cash_payment ------------------------------------------------

  defp record_cash_payment_operation(params) do
    with_group(params, fn group ->
      with :ok <- ensure_active(group),
           {:ok, amount_cents} <- fetch_amount(params),
           :ok <- ensure_within_outstanding(group, amount_cents) do
        {:ok, group} = Reservations.record_cash_payment(group, amount_cents)

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

  defp apply_hotel_credit_operation(params, occurred_on) do
    with_group(params, fn group ->
      with :ok <- ensure_active(group),
           {:ok, amount_cents} <- fetch_amount(params),
           :ok <- ensure_within_outstanding(group, amount_cents),
           {:ok, group} <- Reservations.apply_hotel_credit(group, amount_cents, occurred_on) do
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

  # --- cancel_group -------------------------------------------------------

  defp cancel_group_operation(params, occurred_on, operation_id) do
    with_group(params, fn group ->
      with :ok <- ensure_active(group),
           {:ok, refund_method} <- fetch_refund_method(params),
           :ok <- ensure_refund_method_available(group, refund_method, occurred_on) do
        {:ok, group, settlement} =
          Reservations.cancel(group, occurred_on, refund_method, operation_id)

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

  # --- shared -------------------------------------------------------------

  # Resolves the group named by the operation, then compares revisions, before any
  # other domain rule is evaluated.
  defp with_group(params, fun) do
    with {:ok, group_id} <- Params.string(params, "group_id"),
         {:ok, expected_revision} <- Params.optional_integer(params, "expected_revision") do
      case Reservations.get_group(group_id) do
        nil -> rejection("group_not_found", group_id)
        group -> check_revision(group, expected_revision, fun)
      end
    else
      :error -> invalid_operation()
    end
  end

  defp check_revision(group, nil, fun), do: fun.(group)

  defp check_revision(group, expected_revision, fun)
       when group.revision == expected_revision,
       do: fun.(group)

  defp check_revision(group, expected_revision, _fun) do
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

  defp invalid_operation, do: {:error, %{code: "invalid_operation"}}
end
