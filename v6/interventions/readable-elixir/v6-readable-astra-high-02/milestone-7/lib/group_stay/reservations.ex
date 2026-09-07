defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations and exposes reservation and finance records.

  Each operation has its own transaction. SQLite's immediate transactions acquire the
  write lock before reading a revision, keeping revision checks and balance changes
  atomic across concurrent requests and service processes. Handled rejections commit
  only their audit record and allow the batch to continue. Unexpected exceptions roll
  back the operation and abort the batch, leaving earlier commits available for retry.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [put_change: 3]

  alias GroupStay.{FinanceReporting, Repo}

  alias GroupStay.Reservations.{
    DepositTransfers,
    Group,
    HotelCredit,
    Operation,
    OperationRecord,
    Payments,
    RoomAccounting
  }

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_payment(operation_id), do: Payments.statement(operation_id)

  def get_operation(operation_id), do: OperationRecord.get_result(operation_id)

  def get_group(group_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(Group, group_id) do
          nil -> {:error, "group_not_found"}
          group -> {:ok, %{group | rooms: RoomAccounting.rooms(group)}}
        end
      end)

    result
  end

  def guest_credit(guest_id, on \\ Date.utc_today()), do: HotelCredit.balance(guest_id, on)

  @doc """
  Totals cash settlements and credit liability in one database snapshot. Credit
  funding active deposits remains a liability even after its original expiry.
  The date filters expiry only; it does not replay historical operations.
  """
  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        totals =
          Repo.one(
            from group in Group,
              select: %{
                cash_held_cents:
                  coalesce(sum(group.deposit_paid_cents - group.credit_paid_cents), 0),
                cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
                cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
                cash_converted_to_credit_cents:
                  coalesce(sum(group.cash_converted_to_credit_cents), 0),
                credit_liability_cents: coalesce(sum(group.credit_paid_cents), 0),
                cash_reduced_cents: coalesce(sum(group.cash_reduced_cents), 0),
                cash_charged_back_cents: coalesce(sum(group.cash_charged_back_cents), 0)
              }
          )

        totals
        |> Map.update!(:credit_liability_cents, &(&1 + HotelCredit.available_liability(on)))
        |> Map.put(:credit_shortfall_cents, HotelCredit.current_shortfall())
      end)

    totals
  end

  defp apply_operation(operation) do
    OperationRecord.run(operation, fn -> process_operation(operation) end)
  end

  defp process_operation(operation) do
    outcome =
      with :ok <- Operation.validate(operation) do
        execute(operation, FinanceReporting.context(operation))
      end

    operation_id = if is_map(operation), do: operation["operation_id"], else: nil
    base = %{operation_id: operation_id}

    case outcome do
      {:ok, result} ->
        result = Map.new(result, fn {key, value} -> {key, json_value(value)} end)
        Map.merge(base, Map.put(result, :status, "applied"))

      {:error, code} ->
        Map.merge(base, %{status: "rejected", code: code})

      {:error, code, details} ->
        Map.merge(base, Map.merge(details, %{status: "rejected", code: code}))
    end
  end

  # Results use JSON values on both first submission and durable replay.
  defp json_value(%Date{} = date), do: Date.to_iso8601(date)
  defp json_value(value), do: value

  defp execute(%{"type" => "start_finance_reporting"} = operation, _reporting) do
    with {:ok, _date} <- operation_date(operation), do: FinanceReporting.start(operation)
  end

  defp execute(%{"type" => "close_finance_period"} = operation, _reporting) do
    with {:ok, _date} <- operation_date(operation), do: FinanceReporting.close(operation)
  end

  defp execute(%{"type" => "open_group"} = operation, _reporting) do
    if Repo.get(Group, operation["group_id"]) do
      {:error, "group_already_exists"}
    else
      with {:ok, occurred_on} <- operation_date(operation),
           {:ok, changeset, result} <- Group.open(operation, occurred_on) do
        group = Repo.insert!(changeset)
        applied(group, result)
      end
    end
  end

  defp execute(%{"type" => type} = operation, reporting)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    error =
      if type == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    with {:ok, payment} <- Payments.find(operation["payment_operation_id"], error),
         {:ok, group} <- find_group(payment.result["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, _date} <- operation_date(operation),
         {:ok, changeset, result} <- correct_payment(group, payment, operation, reporting) do
      group = changeset |> put_change(:revision, group.revision + 1) |> Repo.update!()
      applied(group, result)
    end
  end

  defp execute(%{"type" => "transfer_deposit"} = operation, reporting) do
    with {:ok, source} <- find_transfer_group(operation["source_group_id"]),
         {:ok, destination} <- find_transfer_group(operation["destination_group_id"]),
         :ok <- check_revision(source, operation),
         :ok <- check_revision(destination, destination_guard(operation)),
         {:ok, _date} <- operation_date(operation) do
      DepositTransfers.transfer(source, destination, operation["amount_cents"], reporting)
    end
  end

  defp execute(operation, reporting) do
    with {:ok, group} <- find_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         :ok <- active(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, changeset, result} <- change_group(group, operation, occurred_on, reporting) do
      group = changeset |> put_change(:revision, group.revision + 1) |> Repo.update!()
      applied(group, result)
    end
  end

  defp correct_payment(group, payment, %{"type" => "reduce_cash_payment"} = operation, reporting),
    do: Payments.reduce(group, payment, operation["amount_cents"], reporting)

  defp correct_payment(group, payment, %{"type" => "charge_back_payment"}, reporting),
    do: Payments.charge_back(group, payment, reporting)

  defp find_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp find_transfer_group(group_id) do
    case find_group(group_id) do
      {:error, code} -> {:error, code, %{group_id: group_id}}
      found -> found
    end
  end

  defp destination_guard(%{"destination_expected_revision" => expected}),
    do: %{"expected_revision" => expected}

  defp destination_guard(_), do: %{}

  defp check_revision(group, %{"expected_revision" => expected})
       when expected !== group.revision do
    {:error, "stale_revision",
     %{group_id: group.group_id, expected_revision: expected, actual_revision: group.revision}}
  end

  defp check_revision(_, _), do: :ok

  defp active(%Group{status: :active}), do: :ok
  defp active(_), do: {:error, "group_not_active"}

  defp operation_date(operation) do
    case Operation.date(operation["occurred_on"]) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_operation"}
    end
  end

  defp change_group(group, %{"type" => "record_cash_payment"} = operation, _date, reporting) do
    with {:ok, changeset, result} <- Group.pay(group, operation["amount_cents"]) do
      RoomAccounting.allocate(group, operation["amount_cents"],
        payment_operation_id: operation["operation_id"]
      )

      FinanceReporting.cash(
        reporting,
        group.property_id,
        "received_cents",
        operation["amount_cents"]
      )

      {:ok, changeset, result}
    end
  end

  defp change_group(group, %{"type" => "reschedule_group"} = operation, date, _reporting),
    do: Group.reschedule(group, operation["new_arrival_on"], date)

  defp change_group(group, %{"type" => "apply_hotel_credit"} = operation, date, reporting),
    do: HotelCredit.apply_to_group(group, operation["amount_cents"], date, reporting)

  defp change_group(group, %{"type" => type} = operation, date, reporting)
       when type in ["cancel_group", "cancel_rooms"],
       do: RoomAccounting.cancel(group, operation, date, reporting)

  defp applied(group, result),
    do: {:ok, Map.merge(result, %{group_id: group.group_id, revision: group.revision})}
end
