defmodule GroupStay.Payments do
  @moduledoc false

  alias GroupStay.Funding
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  def lookup_applied_cash(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> :not_found
      record -> decode_applied_cash(record)
    end
  end

  def fetch_statement(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil ->
        {:error, :not_found}

      record ->
        case decode_applied_cash(record) do
          {:ok, payment} -> {:ok, statement(payment)}
          :not_applicable -> {:error, :not_reconcilable}
        end
    end
  end

  defp decode_applied_cash(record) do
    with true <- record.type == "record_cash_payment",
         {:ok, data} <- Jason.decode(record.result),
         "applied" <- data["status"],
         group_id when is_binary(group_id) and group_id != "" <- data["group_id"],
         amount when is_integer(amount) and amount > 0 <- data["amount_cents"] do
      {:ok, %{operation_id: record.operation_id, group_id: group_id, amount_cents: amount}}
    else
      _ -> :not_applicable
    end
  end

  defp statement(payment) do
    amounts = Funding.dispositions(payment.operation_id)

    statement = %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group_id,
      recorded_cents: payment.amount_cents,
      held_cents: amounts["held"],
      refunded_cents: amounts["refunded"],
      retained_cents: amounts["retained"],
      converted_to_credit_cents: amounts["converted"],
      reduced_cents: amounts["reduced"],
      charged_back_cents: amounts["charged_back"]
    }

    if Funding.transfer_participated?(payment.operation_id) do
      Map.put(statement, :held_by_group, Funding.held_by_group(payment.operation_id))
    else
      statement
    end
  end
end
