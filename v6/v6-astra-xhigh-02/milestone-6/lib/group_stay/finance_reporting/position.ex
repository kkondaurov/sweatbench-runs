defmodule GroupStay.FinanceReporting.Position do
  @moduledoc false
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.PartnerOperations.Operation
  alias GroupStay.Reservations.{CreditLot, Group, RoomAllocation}

  # Take positions inside the partner operation's transaction. Cash is grouped
  # by its current owner, so transfers and subsequent corrections keep the same
  # property attribution as room accounting and payment statements.
  def read(guest_id \\ :all) do
    groups =
      if guest_id == :all, do: Group, else: from(g in Group, where: g.guest_id == ^guest_id)

    lots =
      if guest_id == :all,
        do: CreditLot,
        else: from(l in CreditLot, where: l.guest_id == ^guest_id)

    properties = Map.new(Repo.all(from g in groups, select: {g.group_id, g.property_id}))

    allocations =
      Repo.all(
        from a in RoomAllocation, join: g in ^groups, on: a.group_id == g.group_id, select: a
      )

    cash =
      allocations
      |> Enum.filter(&is_nil(&1.credit_lot_id))
      |> Enum.reduce(%{}, fn a, totals ->
        key = {a.group_id, a.disposition}
        Map.update(totals, key, a.amount_cents, &(&1 + a.amount_cents))
      end)

    credit =
      allocations
      |> Enum.reject(&is_nil(&1.credit_lot_id))
      |> Enum.group_by(& &1.credit_lot_id)

    lots =
      Map.new(Repo.all(lots), fn lot ->
        balances =
          credit
          |> Map.get(lot.id, [])
          |> Enum.reduce(%{}, fn a, totals ->
            Map.update(totals, a.disposition, a.amount_cents, &(&1 + a.amount_cents))
          end)

        {lot.id,
         %{
           remaining: lot.remaining_cents,
           applied: Map.get(balances, "held", 0),
           consumed: Map.get(balances, "consumed", 0),
           clawback: lot.unrecovered_clawback_cents,
           expires_on: lot.expires_on
         }}
      end)

    %{properties: properties, cash: cash, lots: lots}
  end

  # All transfers preserve guest ownership, including subsequent payment
  # corrections. Limit per-operation reads to that guest's accounting history;
  # only inception needs a company-wide position. Malformed identifiers must
  # still reach the existing domain validation without causing query cast errors.
  def guest_for(operation) do
    group_id =
      case operation["type"] do
        "transfer_deposit" ->
          operation["source_group_id"]

        type when type in ~w(reduce_cash_payment charge_back_payment) ->
          case find(Operation, :operation_id, operation["payment_operation_id"]) do
            nil -> nil
            record -> record.result["group_id"]
          end

        _ ->
          operation["group_id"]
      end

    case find(Group, :group_id, group_id) do
      nil -> ""
      group -> group.guest_id
    end
  end

  defp find(schema, field, value) when is_binary(value), do: Repo.get_by(schema, [{field, value}])
  defp find(_, _, _), do: nil

  def opening(position, on) do
    cash =
      Enum.reduce(position.cash, %{}, fn
        {{group_id, "held"}, amount}, totals ->
          property = Map.fetch!(position.properties, group_id)
          Map.update(totals, property, amount, &(&1 + amount))

        _, totals ->
          totals
      end)

    credit =
      position.lots
      |> Map.values()
      |> Enum.map(&liability(&1, on))
      |> Enum.sum()

    %{"cash" => cash, "credit" => credit}
  end

  def liability(lot, on) do
    lot.applied + if(Date.compare(lot.expires_on, on) == :lt, do: 0, else: lot.remaining)
  end
end
