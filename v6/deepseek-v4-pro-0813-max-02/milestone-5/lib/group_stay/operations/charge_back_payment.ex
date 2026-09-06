defmodule GroupStay.Operations.ChargeBackPayment do
  @moduledoc """
  Reverses all cash from one durably recorded cash payment from a
  `charge_back_payment` operation, except any portion already recorded as
  reduced.

  Every remaining disposition of the payment is reclassified as charged-back
  cash: held allocations leave the rooms in reverse fill order (reopening
  their outstanding deposit), refunded and retained portions move across
  without reversing the historical refund or retention, and converted
  principal moves across while its credit entitlement is revoked from the
  lot it created. A payment can be charged back whether its group is active
  or cancelled.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Operations
  alias GroupStay.Operations.Record, as: OperationRecord
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  @required_fields [:operation_id, :payment_operation_id]

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
           charge_back(operation, record)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp charge_back(operation, nil) do
    Operations.rejected(operation, "operation_not_found")
  end

  defp charge_back(operation, record) do
    case payment_group(record) do
      :payment_not_chargeable ->
        Operations.rejected(operation, "payment_not_chargeable")

      :group_not_found ->
        Operations.rejected(operation, "group_not_found")

      {:ok, group} ->
        with :ok <- Operations.guard_existing_group(operation, group) do
          apply_charge_back(operation, record, group)
        else
          {:rejected, result} -> result
        end
    end
  end

  defp payment_group(record) do
    with true <- record.type == "record_cash_payment",
         {:ok, group_id, recorded} <- decode_applied_payment(record) do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          :group_not_found

        group ->
          already_charged = RoomAccounting.charged_back_cents(record.operation_id) > 0
          fully_reduced = RoomAccounting.reduced_cents(record.operation_id) >= recorded

          if already_charged or fully_reduced do
            :payment_not_chargeable
          else
            {:ok, group}
          end
      end
    else
      _ -> :payment_not_chargeable
    end
  end

  defp decode_applied_payment(record) do
    case Jason.decode!(record.result) do
      %{"status" => "applied", "group_id" => group_id, "amount_cents" => recorded}
      when is_integer(recorded) ->
        {:ok, group_id, recorded}

      _ ->
        :payment_not_chargeable
    end
  end

  defp apply_charge_back(operation, record, group) do
    charged_back = RoomAccounting.charge_back(record.operation_id)

    affected = Enum.uniq([group.id | charged_back.affected_group_ids])

    Enum.each(affected, &RoomAccounting.sync_group_columns/1)
    Enum.each(affected, &RoomAccounting.bump_revision/1)

    group = Repo.get!(Group, group.id)

    Operations.applied(operation,
      payment_operation_id: record.operation_id,
      group_id: group.group_id,
      charged_back_cents: charged_back.charged_back_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents,
      revision: group.revision
    )
  end
end
