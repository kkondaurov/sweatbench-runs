defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order and owns reservation deposit accounting.

  Operations owns the transaction and durable retry result. Domain validation
  and accounting below run only for a previously unseen operation identifier.
  """
  alias GroupStay.{Credit, Finance, Ledger, Operations, Payments, Repo}
  alias GroupStay.Finance.Journal

  alias GroupStay.Reservations.{
    Booking,
    Cancellation,
    CancellationPolicy,
    DepositTransfer,
    Group,
    RoomAccounting
  }

  @required_fields %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "apply_hotel_credit" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => [],
    "cancel_rooms" => ~w(room_ids),
    "reduce_cash_payment" => ~w(amount_cents),
    "charge_back_payment" => [],
    "transfer_deposit" => ~w(amount_cents),
    "start_finance_reporting" => []
  }

  def get_group(id), do: Repo.get(Group, id)

  def ledger(on \\ Date.utc_today()), do: Ledger.totals(on)

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  defp process(operation) do
    Operations.execute(operation, fn -> apply_operation(operation) end)
  end

  defp apply_operation(operation) do
    with :ok <- identify_operation(operation) do
      case operation["type"] do
        "start_finance_reporting" ->
          Finance.start(operation)

        "open_group" ->
          open_group(operation)

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          correct_payment(operation)

        "transfer_deposit" ->
          transfer_deposit(operation)

        _ ->
          with {:ok, group} <- fetch_group(operation["group_id"]),
               :ok <- check_revision(group, operation),
               {:ok, occurred_on} <- operation_data(operation),
               :ok <- active(group) do
            update_group(group, operation, occurred_on)
          end
      end
    end
  end

  defp identify_operation(operation) when is_map(operation) do
    target_fields =
      case operation["type"] do
        "start_finance_reporting" ->
          []

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          ["payment_operation_id"]

        "transfer_deposit" ->
          ["source_group_id", "destination_group_id"]

        _ ->
          ["group_id"]
      end

    if Map.has_key?(@required_fields, operation["type"]) and
         Enum.all?(["operation_id" | target_fields], &identifier?(operation[&1])) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp identify_operation(_), do: {:error, "invalid_operation"}

  defp operation_data(operation) do
    fields = Map.fetch!(@required_fields, operation["type"])

    with true <- Enum.all?(fields, &Map.has_key?(operation, &1)),
         {:ok, date} <- Booking.date(operation["occurred_on"]) do
      {:ok, date}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp identifier?(value), do: is_binary(value) and value != ""

  defp open_group(operation) do
    with {:ok, booked_on} <- operation_data(operation),
         true <- Enum.all?(~w(guest_id property_id), &identifier?(operation[&1])),
         nil <- get_group(operation["group_id"]),
         {:ok, group} <- Booking.build(operation, booked_on) do
      group = Repo.insert!(group)
      {:ok, %{group_id: group.group_id, deposit_due_cents: group.deposit_due_cents, revision: 1}}
    else
      %Group{} -> {:error, "group_already_exists"}
      false -> {:error, "invalid_operation"}
      {:error, code} -> {:error, code}
    end
  end

  defp fetch_group(id) do
    case get_group(id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp check_revision(group, operation, field \\ "expected_revision") do
    if Map.has_key?(operation, field) and
         operation[field] !== group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation[field],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: {:error, "group_not_active"}

  defp update_group(group, %{"type" => type} = operation, date)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    amount = operation["amount_cents"]
    outstanding = Group.outstanding_deposit(group)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > outstanding ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        with :ok <- apply_funding(group, operation, amount, date) do
          persist(
            group,
            RoomAccounting.changes(group),
            %{amount_cents: amount, outstanding_deposit_cents: outstanding - amount}
          )
        end
    end
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation, date) do
    with {:ok, arrival} <- Booking.date(operation["new_arrival_on"]),
         :gt <- Date.compare(arrival, date),
         {:ok, departure} <- shifted_departure(group, arrival) do
      persist(group, %{arrival_on: arrival, departure_on: departure}, %{
        new_arrival_on: arrival,
        new_departure_on: departure,
        policy_version: group.policy_version,
        refundable_until: CancellationPolicy.refundable_until(%{group | arrival_on: arrival})
      })
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp update_group(group, %{"type" => type} = operation, date)
       when type in ["cancel_group", "cancel_rooms"] do
    with {:ok, changes, result} <-
           Cancellation.settle(group, operation, date, Journal.context(operation)) do
      persist(group, changes, result)
    end
  end

  defp apply_funding(group, %{"type" => "record_cash_payment"} = operation, _amount, _date) do
    Payments.record(group, operation, Journal.context(operation))
    :ok
  end

  defp apply_funding(group, %{"type" => "apply_hotel_credit"} = operation, amount, date) do
    with {:ok, allocations} <-
           Credit.apply_to_group(group, amount, date, Journal.context(operation)) do
      Enum.each(allocations, fn {lot_id, cents} ->
        RoomAccounting.fund(group, cents, %{credit_lot_id: lot_id})
      end)

      :ok
    end
  end

  defp correct_payment(operation) do
    code =
      if operation["type"] == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    with {:ok, payment} <- Payments.fetch_target(operation["payment_operation_id"], code),
         {:ok, group} <- fetch_group(payment.original_group_id),
         :ok <- check_revision(group, operation),
         {:ok, _date} <- operation_data(operation) do
      payment_correction(payment, group, operation)
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source} <- fetch_transfer_group(operation["source_group_id"]),
         {:ok, destination} <- fetch_transfer_group(operation["destination_group_id"]),
         :ok <- check_revision(source, operation),
         :ok <- check_revision(destination, operation, "destination_expected_revision"),
         {:ok, _date} <- operation_data(operation) do
      DepositTransfer.apply(
        source,
        destination,
        operation["amount_cents"],
        Journal.context(operation)
      )
    end
  end

  defp fetch_transfer_group(id) do
    case fetch_group(id) do
      {:error, code} -> {:error, %{code: code, group_id: id}}
      found -> found
    end
  end

  defp payment_correction(payment, group, %{"type" => "reduce_cash_payment"} = operation),
    do: Payments.reduce(payment, group, operation["amount_cents"], Journal.context(operation))

  defp payment_correction(payment, group, %{"type" => "charge_back_payment"} = operation),
    do: Payments.charge_back(payment, group, Journal.context(operation))

  defp shifted_departure(group, arrival) do
    arrival
    |> Date.add(Date.diff(group.departure_on, group.arrival_on))
    |> Date.to_iso8601()
    |> Booking.date()
  rescue
    ArgumentError -> {:error, "invalid_stay"}
  end

  defp persist(group, changes, result) do
    revision = group.revision + 1
    group |> Ecto.Changeset.change(Map.put(changes, :revision, revision)) |> Repo.update!()
    {:ok, Map.merge(result, %{group_id: group.group_id, revision: revision})}
  end
end
