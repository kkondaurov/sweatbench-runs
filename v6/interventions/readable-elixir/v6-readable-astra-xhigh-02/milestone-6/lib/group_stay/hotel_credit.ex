defmodule GroupStay.HotelCredit do
  @moduledoc """
  Issues, redeems, restores and revokes credit while preserving each lot's expiry.

  Credit is fungible within a lot. Entitlements identify how much a payment can
  revoke, not which payment funded a later stay. Unrecovered clawbacks absorb
  returned credit before expiry is considered. Only the portion still applied to
  active rooms is a current shortfall.

  Mutations run inside the partner operation's immediate transaction, protecting
  lots shared by several groups. Reads evaluate expiry without changing state.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.HotelCredit.{Application, Entitlement, Lot}
  alias GroupStay.Finance.Journal
  alias GroupStay.{Accounting, Repo}

  def balance(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def liability_totals(on) do
    applied = Accounting.applied_credit_by_lot()

    Enum.reduce(Repo.all(Lot), %{credit_liability_cents: 0, credit_shortfall_cents: 0}, fn lot,
                                                                                           totals ->
      held = Map.get(applied, lot.id, 0)
      available = if Date.compare(lot.expires_on, on) == :lt, do: 0, else: lot.remaining_cents

      %{
        credit_liability_cents: totals.credit_liability_cents + available + held,
        credit_shortfall_cents:
          totals.credit_shortfall_cents + min(lot.unrecovered_clawback_cents, held)
      }
    end)
  end

  @doc "The standard bonus-inclusive value, rounded half upward using integer cents."
  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def issue(_group, _operation_id, [], _on, _journal), do: 0

  def issue(group, operation_id, contributions, on, journal) do
    issued = contributions |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> bonus_value()

    lot =
      Repo.insert!(%Lot{
        source_group_id: group.group_id,
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        issued_cents: issued,
        remaining_cents: issued,
        expires_on: Date.add(on, 365)
      })

    # Running rounded totals telescope to the lot's exact issued value, even
    # when individual contributions would round differently in isolation.
    Enum.reduce(contributions, 0, fn {payment_id, cash}, preceding ->
      Repo.insert!(%Entitlement{
        cash_payment_id: payment_id,
        credit_lot_id: lot.id,
        amount_cents: bonus_value(preceding + cash) - bonus_value(preceding)
      })

      preceding + cash
    end)

    Journal.credit(journal, :issued_cents, issued)
    Journal.schedule_expiry(journal, lot, issued)
    issued
  end

  def apply_to_group(group, amount, on, journal) do
    lots = Repo.all(available_lots(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount do
      Enum.reduce_while(lots, amount, fn lot, outstanding ->
        redeemed = min(lot.remaining_cents, outstanding)
        change(lot, %{remaining_cents: lot.remaining_cents - redeemed})
        record_application(group, lot, redeemed)
        Accounting.fund(group.group_id, redeemed, credit_lot_id: lot.id)
        Journal.schedule_expiry(journal, lot, -redeemed)

        case outstanding - redeemed do
          0 -> {:halt, 0}
          remaining -> {:cont, remaining}
        end
      end)

      :ok
    else
      {:error, :insufficient_credit}
    end
  end

  def restore(allocations, on, journal) do
    allocations
    |> Enum.reject(&is_nil(&1.credit_lot_id))
    |> Enum.group_by(& &1.credit_lot_id, & &1.amount_cents)
    |> Enum.each(fn {lot_id, amounts} ->
      lot = Repo.get!(Lot, lot_id)
      amount = Enum.sum(amounts)
      absorbed = min(lot.unrecovered_clawback_cents, amount)
      excess = amount - absorbed
      restored = if Date.compare(lot.expires_on, on) == :lt, do: 0, else: excess

      # Expired excess is settled permanently, even if later operations carry an
      # earlier date. Absorbed restoration always extinguishes clawback first.
      change(lot, %{
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        remaining_cents: lot.remaining_cents + restored
      })

      Journal.credit(journal, :absorbed_cents, absorbed)
      Journal.credit(journal, :expired_cents, excess - restored)
      Journal.schedule_expiry(journal, lot, restored)
    end)
  end

  @doc "Records liability consumed by non-refundable settlement; the caller removes allocations."
  def consume(allocations, journal) do
    for allocation <- allocations, allocation.credit_lot_id do
      Journal.credit(journal, :consumed_cents, allocation.amount_cents)
    end

    :ok
  end

  def revoke(payment_id, journal) do
    Repo.all(from entitlement in Entitlement, where: entitlement.cash_payment_id == ^payment_id)
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(Lot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      change(lot, %{
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      })

      Journal.revoke(journal, lot, removed)
    end)
  end

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp change(lot, attributes), do: lot |> Changeset.change(attributes) |> Repo.update!()

  defp record_application(group, lot, amount) do
    case Repo.get_by(Application, group_id: group.group_id, credit_lot_id: lot.id) do
      nil ->
        Repo.insert!(%Application{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: amount
        })

      application ->
        application
        |> Changeset.change(amount_cents: application.amount_cents + amount)
        |> Repo.update!()
    end
  end
end
