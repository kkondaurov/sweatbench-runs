defmodule GroupStay.Operations.ReduceCashPayment do
  @moduledoc """
  Records a provider correction against a durably recorded, applied cash
  payment from a `reduce_cash_payment` operation.

  Only cash from that payment that is still held on active rooms can be
  reduced; refunded, retained, or converted cash is settled history and never
  moves through this operation. Held allocations are removed in reverse fill
  order, reopening the addressed group's outstanding deposit by the removed
  amount. Successive reductions compose against the payment's remaining held
  cash.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.FinanceReporting
  alias GroupStay.Operations
  alias GroupStay.Operations.Record, as: OperationRecord
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  import Ecto.Query

  @required_fields [:operation_id, :payment_operation_id, :amount_cents]

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, @required_fields),
         true <- is_binary(fields.payment_operation_id) do
      process(operation, fields)
    else
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp process(operation, fields) do
    case Repo.transaction(fn ->
           record = Repo.get_by(OperationRecord, operation_id: fields.payment_operation_id)
           reduce(operation, record, fields.amount_cents)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp reduce(operation, nil, _amount_cents) do
    Operations.rejected(operation, "operation_not_found")
  end

  defp reduce(operation, _record, amount_cents)
       when not (is_integer(amount_cents) and amount_cents > 0) do
    Operations.rejected(operation, "invalid_amount")
  end

  defp reduce(operation, record, amount_cents) do
    case payment_group(record) do
      :payment_not_reducible ->
        Operations.rejected(operation, "payment_not_reducible")

      :group_not_found ->
        Operations.rejected(operation, "group_not_found")

      {:ok, group, _recorded} ->
        with :ok <- Operations.guard_existing_group(operation, group) do
          apply_reduction(operation, record, group, amount_cents)
        else
          {:rejected, result} -> result
        end
    end
  end

  defp payment_group(record) do
    with true <- record.type == "record_cash_payment",
         {:ok, group_id, recorded} <- decode_applied_payment(record) do
      case Repo.get_by(Group, group_id: group_id) do
        %Group{} = group -> {:ok, group, recorded}
        nil -> :group_not_found
      end
    else
      _ -> :payment_not_reducible
    end
  end

  defp decode_applied_payment(record) do
    case Jason.decode!(record.result) do
      %{"status" => "applied", "group_id" => group_id, "amount_cents" => recorded}
      when is_integer(recorded) ->
        {:ok, group_id, recorded}

      _ ->
        :payment_not_reducible
    end
  end

  defp apply_reduction(operation, record, group, amount_cents) do
    held = RoomAccounting.held_cash_cents(record.operation_id)

    cond do
      held == 0 ->
        Operations.rejected(operation, "payment_not_reducible")

      amount_cents > held ->
        Operations.rejected(operation, "reduction_exceeds_held_cash")

      true ->
        affected = RoomAccounting.remove_held_cash(record.operation_id, amount_cents)

        Enum.each(affected, &RoomAccounting.sync_group_columns(&1.group_id))

        properties = property_map(affected)

        FinanceReporting.record_cash(
          operation,
          Enum.map(affected, fn removed ->
            %{
              property_id: Map.fetch!(properties, removed.group_id),
              classification: "reduced",
              amount_cents: removed.amount_cents
            }
          end)
        )

        group = RoomAccounting.bump_revision(group.id)

        affected
        |> Enum.reject(&(&1.group_id == group.id))
        |> Enum.each(&RoomAccounting.bump_revision(&1.group_id))

        Operations.applied(operation,
          payment_operation_id: record.operation_id,
          group_id: group.group_id,
          amount_cents: amount_cents,
          outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents,
          revision: group.revision
        )
    end
  end

  defp property_map(affected) do
    group_ids = Enum.map(affected, & &1.group_id)

    Repo.all(from g in Group, where: g.id in ^group_ids)
    |> Map.new(fn group -> {group.id, group.property_id} end)
  end
end
