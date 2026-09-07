defmodule GroupStay.Credits do
  @moduledoc """
  Owns hotel-credit lots and their allocation to active group deposits.

  Available credit is consumed by contractual expiry order. Allocations retain
  the originating lot so refundable cancellations can restore the exact credit
  promise, including its original expiry date.
  """

  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditLot}
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @spec available_credit(String.t(), Date.t()) :: %{
          available_cents: non_neg_integer(),
          lots: list()
        }
  def available_credit(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  @spec liability_cents(Date.t()) :: non_neg_integer()
  def liability_cents(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: sum(lot.remaining_cents)
      ) || 0

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == :active,
          select: sum(allocation.amount_cents)
      ) || 0

    available + applied
  end

  @doc "Consumes unexpired lots and records their contribution to a group."
  @spec apply_to_group(Group.t(), pos_integer(), Date.t()) :: :ok | {:error, :insufficient_credit}
  def apply_to_group(group, amount_cents, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      {:error, :insufficient_credit}
    else
      consume_lots(lots, amount_cents, group.group_id)
    end
  end

  @doc "Creates the 110% credit promise for cash converted at cancellation."
  @spec issue_for_cash(Group.t(), String.t(), pos_integer(), Date.t()) :: pos_integer()
  def issue_for_cash(group, source_operation_id, cash_cents, occurred_on) do
    credit_cents = cash_cents + round_percentage(cash_cents, 10)

    %CreditLot{}
    |> CreditLot.creation_changeset(%{
      guest_id: group.guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: credit_cents,
      expires_on: Date.add(occurred_on, 365)
    })
    |> Repo.insert!()

    credit_cents
  end

  @doc """
  Settles credit currently funding a group.

  Refundable cancellations restore allocations whose original expiry has not
  passed. All other allocations are consumed and stop contributing to the
  liability.
  """
  @spec settle_group(Group.t(), boolean(), Date.t()) :: :ok
  def settle_group(group, refundable?, occurred_on) do
    allocations =
      Repo.all(
        from allocation in CreditAllocation,
          where: allocation.group_id == ^group.group_id,
          group_by: allocation.credit_lot_id,
          select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )

    if refundable? do
      Enum.each(allocations, fn {lot_id, amount_cents} ->
        lot = Repo.get!(CreditLot, lot_id)

        if not Date.after?(occurred_on, lot.expires_on) do
          Repo.update_all(
            from(credit_lot in CreditLot, where: credit_lot.id == ^lot_id),
            inc: [remaining_cents: amount_cents]
          )
        end
      end)
    end

    Repo.delete_all(
      from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id
    )

    :ok
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp consume_lots(_lots, 0, _group_id), do: :ok

  defp consume_lots([lot | rest], amount_cents, group_id) do
    consumed_cents = min(lot.remaining_cents, amount_cents)

    {updated_lots, _returning} =
      Repo.update_all(
        from(credit_lot in CreditLot,
          where: credit_lot.id == ^lot.id and credit_lot.remaining_cents >= ^consumed_cents
        ),
        inc: [remaining_cents: -consumed_cents]
      )

    if updated_lots == 1 do
      %CreditAllocation{}
      |> CreditAllocation.changeset(%{
        group_id: group_id,
        credit_lot_id: lot.id,
        amount_cents: consumed_cents
      })
      |> Repo.insert!()

      consume_lots(rest, amount_cents - consumed_cents, group_id)
    else
      {:error, :insufficient_credit}
    end
  end

  # Integer cents with exact half cents rounded upward.
  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)
end
