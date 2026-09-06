defmodule GroupStay.Payments do
  @moduledoc """
  The read model for recorded cash payments and their current disposition.
  """

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Schemas.{OperationRecord, Payment}

  @doc """
  Returns the current disposition of cash from the durably recorded, applied
  cash payment named by `operation_id`.

  Returns `{:error, :operation_not_found}` when no durable operation record
  exists, and `{:error, :payment_not_reconcilable}` when the record is not an
  applied cash payment. Reading a statement never changes state.
  """
  def fetch_statement(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        case Repo.one(
               from p in Payment, where: p.operation_id == ^record.operation_id, preload: [:group]
             ) do
          nil -> {:error, :payment_not_reconcilable}
          payment -> {:ok, statement(payment)}
        end
    end
  end

  defp statement(payment) do
    %{
      payment_operation_id: payment.operation_id,
      original_group_id: payment.group.group_id,
      recorded_cents: payment.recorded_cents,
      held_cents: payment.held_cents,
      refunded_cents: payment.refunded_cents,
      retained_cents: payment.retained_cents,
      converted_to_credit_cents: payment.converted_cents,
      reduced_cents: payment.reduced_cents,
      charged_back_cents: payment.charged_back_cents
    }
  end
end
