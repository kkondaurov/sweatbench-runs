defmodule GroupStay.Reservations do
  @moduledoc """
  Owns group bookings, revision checks, and deposit mutations.

  `GroupStay.Operations` provides the transaction and durable retry boundary.
  Within that transaction, revision checks and balance changes observe the same
  state, even when different HTTP requests update the same group concurrently.
  """

  import Ecto.Query

  alias GroupStay.{Credits, Finance, Payments, Repo}

  alias GroupStay.Reservations.{
    Cancellation,
    CancellationPolicy,
    Group,
    Operation,
    Pricing,
    Room,
    RoomAccounting
  }

  @doc "Applies each operation in array order and returns its partner-facing result."
  defdelegate apply_batch(operations), to: GroupStay.Operations

  @doc "Fetches a booking with rooms in their original order, or returns nil."
  def get_group(group_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(Group, group_id) do
          nil -> nil
          group -> %{group | rooms: RoomAccounting.rooms(group)}
        end
      end)

    result
  end

  @doc false
  # Called only inside GroupStay.Operations' transaction and domain savepoint.
  def apply_operation(%Operation{type: "open_group"} = operation), do: open_group(operation)

  def apply_operation(%Operation{type: "transfer_deposit"} = operation) do
    params = operation.params

    with {:ok, source} <- fetch_transfer_group(params["source_group_id"]),
         {:ok, destination} <- fetch_transfer_group(params["destination_group_id"]),
         :ok <- check_revision(source, params),
         :ok <- check_revision(destination, params, "destination_expected_revision"),
         :ok <- compatible_transfer(source, destination),
         :ok <- identify_group_error(require_active(source), source.group_id),
         :ok <- identify_group_error(require_active(destination), destination.group_id),
         {:ok, _on} <- Operation.date(params["occurred_on"], "invalid_operation"),
         :ok <- Operation.require_fields(params, ["amount_cents"]),
         {:ok, amount} <- payment_amount(params["amount_cents"]),
         :ok <- transfer_capacity(source, destination, amount) do
      RoomAccounting.transfer!(source, destination, amount, operation)
      source = persist_update!(source, RoomAccounting.totals(source))
      destination = persist_update!(destination, RoomAccounting.totals(destination))

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: amount,
         source_outstanding_deposit_cents: Group.outstanding_deposit_cents(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit_cents(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  def apply_operation(%Operation{type: type} = operation)
      when type in ["reduce_cash_payment", "charge_back_payment"] do
    error =
      if type == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    with {:ok, payment} <- Payments.fetch(operation.params["payment_operation_id"], error),
         {:ok, group} <- fetch_group(payment.result["group_id"]),
         :ok <- check_revision(group, operation.params),
         {:ok, occurred_on} <-
           Operation.date(operation.params["occurred_on"], "invalid_operation") do
      correct_payment(group, payment, %{operation | group_id: group.group_id}, occurred_on)
    end
  end

  def apply_operation(%Operation{} = operation) do
    with {:ok, group} <- fetch_group(operation.group_id),
         :ok <- check_revision(group, operation.params),
         :ok <- require_active(group),
         {:ok, occurred_on} <-
           Operation.date(operation.params["occurred_on"], "invalid_operation") do
      update_group(group, operation, occurred_on)
    end
  end

  defp open_group(operation) do
    params = operation.params

    with :ok <- require_new_group(operation.group_id),
         :ok <-
           Operation.require_fields(
             params,
             ~w(guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         :ok <- validate_booking_identifiers(params),
         {:ok, booked_on} <- Operation.date(params["occurred_on"], "invalid_operation"),
         {:ok, arrival_on} <- Operation.date(params["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- Operation.date(params["departure_on"], "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(params["rate_plan"]),
         {:ok, price} <-
           Pricing.quote(params["rooms"], Date.diff(departure_on, arrival_on), rate_plan) do
      group =
        Repo.insert!(%Group{
          group_id: operation.group_id,
          guest_id: params["guest_id"],
          property_id: params["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: CancellationPolicy.version(rate_plan, booked_on),
          lodging_total_cents: price.lodging_total_cents,
          deposit_due_cents: price.deposit_due_cents,
          rooms: rooms(params["rooms"])
        })

      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    end
  end

  defp update_group(group, %Operation{type: "record_cash_payment"} = operation, occurred_on) do
    with :ok <- Operation.require_fields(operation.params, ["amount_cents"]),
         {:ok, amount} <- payment_amount(operation.params["amount_cents"]),
         :ok <- within_outstanding(group, amount) do
      RoomAccounting.allocate_cash!(group, operation, amount)
      group = persist_update!(group, RoomAccounting.totals(group))

      Finance.record!(operation, occurred_on, :payment, amount)

      {:ok, payment_result(group, amount)}
    end
  end

  defp update_group(group, %Operation{type: "apply_hotel_credit"} = operation, occurred_on) do
    with :ok <- Operation.require_fields(operation.params, ["amount_cents"]),
         {:ok, amount} <- payment_amount(operation.params["amount_cents"]),
         :ok <- within_outstanding(group, amount),
         :ok <- Credits.apply_to_group(group, operation, amount, occurred_on) do
      group = persist_update!(group, RoomAccounting.totals(group))

      {:ok, payment_result(group, amount)}
    end
  end

  defp update_group(group, %Operation{type: "reschedule_group"} = operation, occurred_on) do
    with :ok <- Operation.require_fields(operation.params, ["new_arrival_on"]),
         {:ok, arrival_on} <- Operation.date(operation.params["new_arrival_on"], "invalid_stay"),
         :ok <- validate_stay(occurred_on, arrival_on),
         {:ok, departure_on} <- shifted_departure(group, arrival_on) do
      group = persist_update!(group, arrival_on: arrival_on, departure_on: departure_on)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: Date.to_iso8601(arrival_on),
         new_departure_on: Date.to_iso8601(departure_on),
         policy_version: group.policy_version,
         refundable_until: CancellationPolicy.refundable_until(group),
         revision: group.revision
       }}
    end
  end

  defp update_group(group, %Operation{type: type} = operation, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    with {:ok, rooms} <- cancellation_rooms(group, operation),
         {:ok, settlement} <- Cancellation.settle(group, rooms, operation, occurred_on) do
      ids = Enum.map(rooms, & &1.id)
      Repo.update_all(from(room in Room, where: room.id in ^ids), set: [status: :cancelled])

      changes = RoomAccounting.totals(group)

      changes =
        if RoomAccounting.active_rooms(group) == [],
          do: Keyword.merge(changes, status: :cancelled, cancelled_on: occurred_on),
          else: changes

      group = persist_update!(group, changes)

      settlement =
        if type == "cancel_rooms",
          do: Map.put(settlement, :cancelled_room_ids, Enum.map(rooms, & &1.room_id)),
          else: settlement

      {:ok, Map.merge(settlement, %{group_id: group.group_id, revision: group.revision})}
    end
  end

  defp cancellation_rooms(group, %Operation{type: "cancel_group"}),
    do: {:ok, RoomAccounting.active_rooms(group)}

  defp cancellation_rooms(group, operation) do
    with :ok <- Operation.require_fields(operation.params, ["room_ids"]) do
      select_rooms(group, operation.params["room_ids"])
    end
  end

  defp select_rooms(group, ids) do
    rooms = RoomAccounting.active_rooms(group)

    if is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
         Enum.all?(ids, fn id -> Enum.any?(rooms, &(&1.room_id === id)) end) do
      {:ok, Enum.filter(rooms, &(&1.room_id in ids))}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp correct_payment(group, payment, %Operation{type: "reduce_cash_payment"} = operation, on) do
    held = Payments.dispositions(payment).held

    with :ok <- require_positive_balance(held, "payment_not_reducible"),
         :ok <- Operation.require_fields(operation.params, ["amount_cents"]),
         {:ok, amount} <- payment_amount(operation.params["amount_cents"]),
         :ok <- within_held(amount, held) do
      affected_groups = Payments.reduce!(payment, amount, operation)
      Finance.record!(operation, on, :reduction, amount)
      group = refresh_funding!(group, affected_groups)
      {:ok, Map.put(payment_result(group, amount), :payment_operation_id, payment.operation_id)}
    end
  end

  defp correct_payment(group, payment, %Operation{type: "charge_back_payment"} = operation, on) do
    amounts = Payments.dispositions(payment)
    chargeable = payment.result["amount_cents"] - amounts.reduced - amounts.charged_back

    with :ok <- require_positive_balance(chargeable, "payment_not_chargeable") do
      {amount, affected_groups} = Payments.charge_back!(payment, operation)
      Finance.record!(operation, on, :chargeback, amount)
      group = refresh_funding!(group, affected_groups)

      {:ok,
       %{
         payment_operation_id: payment.operation_id,
         group_id: group.group_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  # Corrections guard only the original payment group, but refresh and advance
  # every group whose held funding changed. The addressed group advances once
  # even if all its payment's cash has moved away or has already been settled.
  defp refresh_funding!(addressed, affected_groups) do
    affected_groups
    |> MapSet.delete(addressed.group_id)
    |> Enum.each(fn id ->
      group = Repo.get!(Group, id)
      persist_update!(group, RoomAccounting.totals(group))
    end)

    persist_update!(addressed, RoomAccounting.totals(addressed))
  end

  defp fetch_transfer_group(group_id),
    do: identify_group_error(fetch_group(group_id), group_id)

  defp identify_group_error({:error, code}, group_id),
    do: {:error, %{code: code, group_id: group_id}}

  defp identify_group_error(result, _group_id), do: result

  defp compatible_transfer(source, destination) do
    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: {:error, "invalid_transfer"},
      else: :ok
  end

  defp transfer_capacity(source, destination, amount) do
    cond do
      amount > source.deposit_paid_cents ->
        {:error, "transfer_exceeds_held_funding"}

      amount > Group.outstanding_deposit_cents(destination) ->
        {:error, "transfer_exceeds_outstanding"}

      true ->
        :ok
    end
  end

  defp require_positive_balance(amount, _error) when amount > 0, do: :ok
  defp require_positive_balance(_amount, error), do: {:error, error}

  defp within_held(amount, held) when amount <= held, do: :ok
  defp within_held(_amount, _held), do: {:error, "reduction_exceeds_held_cash"}

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
      revision: group.revision
    }
  end

  defp persist_update!(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp fetch_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp require_new_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :ok
      _group -> {:error, "group_already_exists"}
    end
  end

  defp check_revision(group, params, key \\ "expected_revision") do
    case Map.fetch(params, key) do
      {:ok, expected} when expected !== group.revision ->
        {:error,
         %{
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}

      _ ->
        :ok
    end
  end

  defp require_active(%Group{status: :active}), do: :ok
  defp require_active(_group), do: {:error, "group_not_active"}

  defp validate_booking_identifiers(params) do
    if Operation.identifier?(params["guest_id"]) and Operation.identifier?(params["property_id"]),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp shifted_departure(group, arrival_on) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    if nights <= Date.diff(~D[9999-12-31], arrival_on),
      do: {:ok, Date.add(arrival_on, nights)},
      else: {:error, "invalid_stay"}
  end

  defp rate_plan("flexible"), do: {:ok, :flexible}
  defp rate_plan("advance_purchase"), do: {:ok, :advance_purchase}
  defp rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp rooms(params) do
    params
    |> Enum.with_index()
    |> Enum.map(fn {room, position} ->
      %Room{
        room_id: room["room_id"],
        nightly_rate_cents: room["nightly_rate_cents"],
        position: position
      }
    end)
  end

  defp payment_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp payment_amount(_amount), do: {:error, "invalid_amount"}

  defp within_outstanding(group, amount) do
    if amount <= Group.outstanding_deposit_cents(group),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end
end
