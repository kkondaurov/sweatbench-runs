defmodule GroupStay.Operations.RecordCashPayment do
  @moduledoc """
  Applies cash from a `record_cash_payment` operation to an active group's
  outstanding deposit. The amount must be a positive integer of cents and must
  not exceed the outstanding deposit.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  import Ecto.Query

  @required_fields [:operation_id, :group_id, :occurred_on, :amount_cents]

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, @required_fields),
         true <- is_binary(fields.group_id),
         {:ok, _occurred_on} <- Operations.parse_date(fields.occurred_on) do
      process(operation, fields)
    else
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp process(operation, fields) do
    case Repo.transaction(fn ->
           group = Repo.get_by(Group, group_id: fields.group_id)
           apply_to_group(operation, group, fields.amount_cents)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp apply_to_group(operation, group, amount_cents) do
    with :ok <- Operations.guard_group(operation, group),
         :ok <- validate_amount(amount_cents, group) do
      apply_payment(operation, group, amount_cents)
    else
      {:rejected, result} -> result
      {:invalid, code} -> Operations.rejected(operation, code)
    end
  end

  defp validate_amount(amount_cents, group) do
    cond do
      not is_integer(amount_cents) or amount_cents <= 0 ->
        {:invalid, "invalid_amount"}

      amount_cents > group.deposit_due_cents - group.deposit_paid_cents ->
        {:invalid, "payment_exceeds_outstanding"}

      true ->
        :ok
    end
  end

  defp apply_payment(operation, group, amount_cents) do
    rooms = active_rooms(group)

    RoomAccounting.allocate(group.id, rooms, [
      %{
        kind: "cash",
        amount_cents: amount_cents,
        payment_operation_id: operation["operation_id"],
        lot_id: nil
      }
    ])

    RoomAccounting.sync_group_columns(group.id)

    group = Repo.get!(Group, group.id)
    outstanding = group.deposit_due_cents - group.deposit_paid_cents
    revision = group.revision + 1

    {1, nil} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [revision: revision]
      )

    Operations.applied(operation,
      group_id: group.group_id,
      amount_cents: amount_cents,
      outstanding_deposit_cents: outstanding,
      revision: revision
    )
  end

  defp active_rooms(group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id and r.status == "active",
        order_by: [asc: r.position]
    )
  end
end
