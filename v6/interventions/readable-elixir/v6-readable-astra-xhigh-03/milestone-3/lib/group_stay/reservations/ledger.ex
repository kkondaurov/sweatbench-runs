defmodule GroupStay.Reservations.Ledger do
  @moduledoc """
  A consistent snapshot of cash dispositions and outstanding credit liability.

  The optional date controls expiry of current unredeemed balances, rather than
  replaying historical operations. Credit in active deposits has no expiry.
  A single query keeps cash and credit from different commits from being mixed.
  Subtotals are combined in Elixir so cross-group sums cannot overflow SQLite.
  """
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashEntry, CreditLot, Group}

  def totals(on) do
    available =
      from lot in CreditLot,
        where: lot.expires_on >= ^on and lot.remaining_cents > 0,
        select: {"credit_liability", lot.remaining_cents}

    applied =
      from group in Group,
        where: group.status == :active and group.credit_paid_cents > 0,
        select: {"credit_liability", group.credit_paid_cents}

    totals =
      Repo.all(
        from entry in CashEntry,
          group_by: [entry.group_id, entry.kind],
          select: {type(entry.kind, :string), sum(entry.amount_cents)},
          union_all: ^available,
          union_all: ^applied
      )
      |> Enum.reduce(%{}, fn {kind, amount}, totals ->
        Map.update(totals, kind, amount, &(&1 + amount))
      end)

    payments = Map.get(totals, "payment", 0)
    refunds = Map.get(totals, "refund", 0)
    retentions = Map.get(totals, "retention", 0)
    conversions = Map.get(totals, "credit_conversion", 0)

    %{
      cash_held_cents: payments - refunds - retentions - conversions,
      cash_refunded_cents: refunds,
      cash_retained_cents: retentions,
      cash_converted_to_credit_cents: conversions,
      credit_liability_cents: Map.get(totals, "credit_liability", 0)
    }
  end
end
