defmodule GroupStay.Operations.ApplyHotelCredit do
  @moduledoc """
  Applies hotel credit from an `apply_hotel_credit` operation to an active
  group's outstanding deposit.

  Credit is consumed from the guest's lots by earliest expiry and then
  source operation id. Lots are evaluated against the operation's
  `occurred_on` date. The consumed amounts are recorded per lot so they can be
  restored if the group is later cancelled while still refundable.
  """

  alias GroupStay.Credit.CreditApplication
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.FinanceReporting
  alias GroupStay.Operations
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting

  import Ecto.Query

  @required_fields [:operation_id, :group_id, :occurred_on, :amount_cents]

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
           apply_to_group(operation, group, fields.amount_cents, occurred_on)
         end) do
      {:ok, result} -> result
      _ -> Operations.rejected(operation, "invalid_operation")
    end
  end

  defp apply_to_group(operation, group, amount_cents, occurred_on) do
    with :ok <- Operations.guard_group(operation, group),
         :ok <- validate_amount(amount_cents, group),
         {:ok, lots} <- claimable_lots(group, amount_cents, occurred_on) do
      apply_credit(operation, group, amount_cents, lots)
    else
      {:rejected, result} -> result
      {:invalid, code} -> Operations.rejected(operation, code)
    end
  end

  defp validate_amount(amount_cents, group) do
    cond do
      not is_integer(amount_cents) or amount_cents <= 0 ->
        {:invalid, "invalid_amount"}

      amount_cents > outstanding(group) ->
        {:invalid, "payment_exceeds_outstanding"}

      true ->
        :ok
    end
  end

  defp outstanding(group) do
    group.deposit_due_cents - group.cash_paid_cents - group.credit_paid_cents
  end

  defp claimable_lots(group, amount_cents, occurred_on) do
    lots =
      CreditLot
      |> where([lot], lot.guest_id == ^group.guest_id)
      |> where([lot], lot.expires_on >= ^occurred_on)
      |> where([lot], lot.remaining_cents > 0)
      |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
      |> Repo.all()

    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available >= amount_cents do
      {:ok, lots}
    else
      {:invalid, "insufficient_credit"}
    end
  end

  defp apply_credit(operation, group, amount_cents, lots) do
    takes = plan_takes(lots, amount_cents)

    active_rooms =
      Repo.all(
        from r in Room,
          where: r.group_id == ^group.id and r.status == "active",
          order_by: [asc: r.position]
      )

    RoomAccounting.allocate(
      group.id,
      active_rooms,
      Enum.map(takes, fn {lot, take} ->
        %{
          kind: "credit",
          amount_cents: take,
          payment_operation_id: operation["operation_id"],
          lot_id: lot.id
        }
      end)
    )

    Enum.each(takes, fn {lot, take} ->
      {1, nil} =
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot.id),
          inc: [remaining_cents: -take]
        )

      {:ok, _application} =
        Repo.insert(%CreditApplication{
          lot_id: lot.id,
          group_id: group.id,
          amount_cents: take
        })
    end)

    FinanceReporting.record_credit(
      operation,
      Enum.map(takes, fn {lot, take} ->
        %{lot_id: lot.id, classification: "pool_apply", amount_cents: -take}
      end)
    )

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

  defp plan_takes(lots, needed) do
    Enum.reduce_while(lots, {[], needed}, fn lot, {takes, needed} ->
      if needed <= 0 do
        {:halt, {takes, needed}}
      else
        take = min(lot.remaining_cents, needed)
        {:cont, {[{lot, take} | takes], needed - take}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
