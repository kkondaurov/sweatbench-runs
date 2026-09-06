defmodule GroupStay.Operations.CancelGroup do
  @moduledoc """
  Cancels a group from a `cancel_group` operation.

  Cancellation refundability follows the group's policy version, which is
  fixed when the group is opened. A refundable cancellation refunds cash (or,
  when `refund_method: "hotel_credit"` is requested, converts it into a credit
  lot worth 110% of the cash) and restores any applied hotel credit to its
  original lots. Non-refundable cancellations retain cash and consume applied
  credit. The unpaid deposit stops being due.
  """

  alias GroupStay.Credit.CreditApplication
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Operations
  alias GroupStay.Policy
  alias GroupStay.Repo

  import Ecto.Query

  @required_fields [:operation_id, :group_id, :occurred_on]
  @refund_methods ["cash", "hotel_credit"]

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
    with :ok <- Operations.guard_group(operation, group),
         {:ok, refund_method} <- validate_refund_method(operation["refund_method"]),
         :ok <- assert_method_available(group, refund_method, occurred_on) do
      settle(operation, group, occurred_on, refund_method)
    else
      {:rejected, result} ->
        result

      :refund_method_not_available ->
        Operations.rejected(operation, "refund_method_not_available")
    end
  end

  defp validate_refund_method(nil), do: {:ok, "cash"}

  defp validate_refund_method(method) when method in @refund_methods, do: {:ok, method}

  defp validate_refund_method(_method), do: :refund_method_not_available

  defp assert_method_available(group, "hotel_credit", occurred_on) do
    policy = Policy.for_group(group)

    if Policy.refundable?(policy, group.arrival_on, occurred_on) do
      :ok
    else
      :refund_method_not_available
    end
  end

  defp assert_method_available(_group, _method, _occurred_on), do: :ok

  defp settle(operation, group, occurred_on, refund_method) do
    policy = Policy.for_group(group)
    refundable = Policy.refundable?(policy, group.arrival_on, occurred_on)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      if refundable do
        restore_credit(group, occurred_on)
        settle_refundable(operation, group, occurred_on, refund_method)
      else
        consume_credit(group)
        {0, group.cash_paid_cents, 0, 0}
      end

    revision = group.revision + 1

    {1, nil} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [
          status: "cancelled",
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: group.refunded_cents + refunded_cents,
          retained_cents: group.retained_cents + retained_cents,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents,
          revision: revision
        ]
      )

    Operations.applied(operation,
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents,
      revision: revision
    )
  end

  defp settle_refundable(_operation, group, _occurred_on, "cash") do
    {group.cash_paid_cents, 0, 0, 0}
  end

  defp settle_refundable(operation, group, occurred_on, "hotel_credit") do
    cash = group.cash_paid_cents

    issued =
      if cash > 0 do
        bonus = div(cash + 5, 10)
        total = cash + bonus

        {:ok, _lot} =
          Repo.insert(%CreditLot{
            guest_id: group.guest_id,
            source_operation_id: operation["operation_id"],
            expires_on: Date.add(occurred_on, 365),
            remaining_cents: total
          })

        total
      else
        0
      end

    {0, 0, cash, issued}
  end

  defp applications_for(group) do
    Repo.all(from a in CreditApplication, where: a.group_id == ^group.id)
  end

  defp restore_credit(group, occurred_on) do
    applications = applications_for(group)

    if applications != [] do
      lot_ids = Enum.map(applications, & &1.lot_id)
      lots = Repo.all(from l in CreditLot, where: l.id in ^lot_ids)

      lots_by_id = Map.new(lots, &{&1.id, &1})

      applications
      |> Enum.group_by(& &1.lot_id)
      |> Enum.each(fn {lot_id, lot_applications} ->
        amount = Enum.reduce(lot_applications, 0, &(&1.amount_cents + &2))
        lot = Map.fetch!(lots_by_id, lot_id)

        if Date.compare(lot.expires_on, occurred_on) != :lt do
          Repo.update_all(
            from(l in CreditLot, where: l.id == ^lot_id),
            inc: [remaining_cents: amount]
          )
        end
      end)
    end

    delete_applications(group)
  end

  defp consume_credit(group) do
    delete_applications(group)
  end

  defp delete_applications(group) do
    Repo.delete_all(from a in CreditApplication, where: a.group_id == ^group.id)
  end
end
