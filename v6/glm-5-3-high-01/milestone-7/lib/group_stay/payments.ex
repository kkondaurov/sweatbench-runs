defmodule GroupStay.Payments do
  @moduledoc """
  The read model for recorded cash payments and their current disposition.
  """

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Schemas.{Group, OperationRecord, Payment, RoomAllocation}

  @doc """
  Returns the current disposition of cash from the durably recorded, applied
  cash payment named by `operation_id`.

  Returns `{:error, :operation_not_found}` when no durable operation record
  exists, and `{:error, :payment_not_reconcilable}` when the record is not an
  applied cash payment. Reading a statement never changes state.

  Once any funding from the payment has participated in a transfer, the
  statement also reports `held_by_group`: where its held cash currently funds
  rooms, ordered by group id.
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
    statement = %{
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

    if payment.transferred,
      do: Map.put(statement, :held_by_group, held_by_group(payment)),
      else: statement
  end

  defp held_by_group(payment) do
    Repo.all(
      from a in RoomAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where:
          a.operation_id == ^payment.operation_id and a.kind == "cash" and
            a.amount_cents > 0,
        group_by: g.group_id,
        select: {g.group_id, fragment("COALESCE(SUM(?), 0)", a.amount_cents)}
    )
    |> Enum.sort_by(fn {group_id, _amount_cents} -> group_id end)
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end
end
