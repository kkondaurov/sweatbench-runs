defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order, with one transaction per operation.

  SQLite's immediate transactions acquire the write reservation before reading a
  group. Revision checks and balance changes therefore observe the same state,
  even when different HTTP requests update the same group concurrently. Rejected
  operations roll back independently; earlier batch results stay committed.
  """

  alias GroupStay.{Finance, Repo}
  alias GroupStay.Reservations.{Group, Operation, Pricing, Room}

  @doc "Applies each operation in array order and returns its partner-facing result."
  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  @doc "Fetches a booking with rooms in their original order, or returns nil."
  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  defp apply_operation(params) do
    with {:ok, operation} <- Operation.parse(params),
         {:ok, fields} <- transact(operation) do
      Operation.applied(operation, fields)
    else
      {:error, error} -> Operation.rejected(params, error)
    end
  end

  defp transact(operation) do
    Repo.transaction(
      fn ->
        case dispatch(operation) do
          {:ok, fields} -> fields
          {:error, error} -> Repo.rollback(error)
        end
      end,
      mode: :immediate
    )
  end

  defp dispatch(%Operation{type: "open_group"} = operation), do: open_group(operation)

  defp dispatch(operation) do
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
      group = persist_update!(group, deposit_paid_cents: group.deposit_paid_cents + amount)
      Finance.record!(operation, occurred_on, :payment, amount)

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
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
         revision: group.revision
       }}
    end
  end

  defp update_group(group, %Operation{type: "cancel_group"} = operation, occurred_on) do
    refundable? = group.rate_plan == :flexible and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable?, do: group.deposit_paid_cents, else: 0
    retained = if refundable?, do: 0, else: group.deposit_paid_cents

    group =
      persist_update!(group,
        status: :cancelled,
        cancelled_on: occurred_on,
        deposit_due_cents: 0,
        deposit_paid_cents: 0
      )

    Finance.record!(operation, occurred_on, :refund, refunded)
    Finance.record!(operation, occurred_on, :retention, retained)

    {:ok,
     %{
       group_id: group.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       revision: group.revision
     }}
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

  defp check_revision(group, %{"expected_revision" => expected})
       when expected !== group.revision do
    {:error,
     %{
       code: "stale_revision",
       group_id: group.group_id,
       expected_revision: expected,
       actual_revision: group.revision
     }}
  end

  defp check_revision(_group, _params), do: :ok

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
