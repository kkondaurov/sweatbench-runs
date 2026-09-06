defmodule GroupStay.Operations.CancelGroup do
  @moduledoc """
  Cancels a group from a `cancel_group` operation.

  A flexible reservation cancelled at least 14 calendar days before arrival
  refunds all cash already paid. Flexible reservations cancelled later and all
  advance-purchase reservations are non-refundable and retain paid cash. The
  unpaid deposit simply stops being due.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Operations
  alias GroupStay.Repo

  import Ecto.Query

  @required_fields [:operation_id, :group_id, :occurred_on]

  @spec apply(map()) :: map()
  def apply(operation) do
    with {:ok, fields} <- Operations.require_fields(operation, @required_fields),
         true <- is_binary(fields.group_id),
         {:ok, occurred_on} <- Operations.parse_date(fields.occurred_on) do
      process(operation, fields, occurred_on)
    else
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp process(operation, fields, occurred_on) do
    case Repo.transaction(fn ->
           group = Repo.get_by(Group, group_id: fields.group_id)
           apply_to_group(operation, group, occurred_on)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp apply_to_group(operation, group, occurred_on) do
    with :ok <- Operations.guard_group(operation, group) do
      apply_cancellation(operation, group, occurred_on)
    else
      {:rejected, result} -> result
    end
  end

  defp apply_cancellation(operation, group, occurred_on) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

    refunded_cents = if refundable, do: group.deposit_paid_cents, else: 0
    retained_cents = if refundable, do: 0, else: group.deposit_paid_cents
    revision = group.revision + 1

    {1, nil} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [
          status: "cancelled",
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          refunded_cents: group.refunded_cents + refunded_cents,
          retained_cents: group.retained_cents + retained_cents,
          revision: revision
        ]
      )

    Operations.applied(operation,
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      revision: revision
    )
  end
end
