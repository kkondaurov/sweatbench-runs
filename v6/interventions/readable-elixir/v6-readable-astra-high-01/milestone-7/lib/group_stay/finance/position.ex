defmodule GroupStay.Finance.Position do
  @moduledoc """
  Transient financial positions used to journal an operation's actual effects.

  Cash stays attributed to the group where it is held or settled. Credit is
  compared per lot, including its deposits across all groups. Captures are scoped
  to affected groups and their guests, and run inside the operation transaction.
  No submitted operation is replayed to reconstruct financial history.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Accounting.CashAllocation
  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Reservations.Group

  def all, do: capture(Repo.all(Group), Repo.all(Lot))

  def for_operation(operation) do
    ids = operation |> group_ids() |> Enum.filter(&is_binary/1) |> Enum.uniq()
    capture(Repo.all(from g in Group, where: g.group_id in ^ids))
  end

  defp group_ids(%{"type" => "transfer_deposit"} = operation),
    do: [operation["source_group_id"], operation["destination_group_id"]]

  defp group_ids(%{"type" => type} = operation)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    case operation["payment_operation_id"] do
      payment_id when is_binary(payment_id) ->
        Repo.all(
          from a in CashAllocation,
            where: a.payment_operation_id == ^payment_id,
            distinct: true,
            select: a.group_id
        )

      _ ->
        []
    end
  end

  defp group_ids(operation), do: [operation["group_id"]]

  def refresh(position) do
    ids = Map.keys(position.groups)
    capture(Repo.all(from g in Group, where: g.group_id in ^ids))
  end

  defp capture(groups) do
    guests = groups |> Enum.map(& &1.guest_id) |> Enum.uniq()
    lots = Repo.all(from l in Lot, where: l.guest_id in ^guests)
    capture(groups, lots)
  end

  defp capture(groups, lots) do
    lot_ids = Enum.map(lots, & &1.id)

    applied =
      Repo.all(
        from a in Allocation,
          where: a.credit_lot_id in ^lot_ids,
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, sum(a.amount_cents)}
      )
      |> Map.new()

    %{
      groups: Map.new(groups, &{&1.group_id, &1}),
      lots:
        Map.new(lots, fn lot ->
          {lot.id,
           %{
             remaining: lot.remaining_cents,
             applied: Map.get(applied, lot.id, 0),
             clawback: lot.unrecovered_clawback_cents,
             expires_on: lot.expires_on
           }}
        end)
    }
  end

  def liability(lot, on) do
    lot.applied + if(Date.compare(lot.expires_on, on) == :lt, do: 0, else: lot.remaining)
  end
end
