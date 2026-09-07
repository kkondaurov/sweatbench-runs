defmodule GroupStay.Reservations do
  @moduledoc """
  The boundary for partner operations and group-deposit reads.

  A batch is deliberately not one database transaction: every operation gets
  its own transaction so its durable receipt and domain effects are atomic,
  while earlier operations remain visible to later entries in the same batch.
  A handled rejection commits only its receipt.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashAllocation,
    CashFunding,
    Credit,
    FinanceReporting,
    Group,
    OperationProcessor,
    PartnerOperation
  }

  @doc "Processes partner operations in their submitted order."
  def process_operations(operations) when is_list(operations) do
    Enum.map(operations, &OperationProcessor.process/1)
  end

  @doc "Returns a group with rooms in the original partner order."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def fetch_group(_group_id), do: {:error, :group_not_found}

  @doc "Returns the exact result durably recorded for a partner operation."
  def fetch_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, operation.result}
    end
  end

  def fetch_operation_result(_operation_id), do: {:error, :operation_not_found}

  @doc "Returns the current seven-way disposition of one durable cash payment."
  def fetch_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      %PartnerOperation{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(CashFunding, payment_operation_id: payment_operation_id) do
          nil -> {:error, :payment_not_reconcilable}
          funding -> {:ok, payment_statement(funding)}
        end

      _operation ->
        {:error, :payment_not_reconcilable}
    end
  end

  def fetch_payment(_payment_operation_id), do: {:error, :operation_not_found}

  @doc "Returns cash and hotel-credit balances as of the supplied date."
  def ledger_totals(on \\ Date.utc_today()) do
    cash_totals =
      Repo.one(
        from funding in CashFunding,
          select: %{
            cash_held_cents: coalesce(sum(funding.held_cents), 0),
            cash_refunded_cents: coalesce(sum(funding.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(funding.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(funding.converted_to_credit_cents), 0),
            cash_reduced_cents: coalesce(sum(funding.reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(funding.charged_back_cents), 0)
          }
      )

    cash_totals
    |> Map.put(:credit_liability_cents, Credit.liability_cents(on))
    |> Map.put(:credit_shortfall_cents, Credit.shortfall_cents())
  end

  @doc "Returns one guest's unexpired, available hotel credit as of a date."
  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id),
    do: Credit.available_credit(guest_id, on)

  @doc "Returns the open daily finance report for one reporting date."
  def daily_finance_report(date), do: FinanceReporting.daily_report(date)

  defp payment_statement(funding) do
    statement = %{
      payment_operation_id: funding.payment_operation_id,
      original_group_id: funding.group_id,
      recorded_cents: funding.recorded_cents,
      held_cents: funding.held_cents,
      refunded_cents: funding.refunded_cents,
      retained_cents: funding.retained_cents,
      converted_to_credit_cents: funding.converted_to_credit_cents,
      reduced_cents: funding.reduced_cents,
      charged_back_cents: funding.charged_back_cents
    }

    if funding.participated_in_transfer do
      Map.put(statement, :held_by_group, held_cash_by_group(funding.id))
    else
      statement
    end
  end

  defp held_cash_by_group(cash_funding_id) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.cash_funding_id == ^cash_funding_id,
        join: room in assoc(allocation, :room),
        where: room.status == "active",
        group_by: room.group_id,
        order_by: room.group_id,
        select: %{
          group_id: room.group_id,
          amount_cents: sum(allocation.amount_cents)
        }
    )
  end
end
