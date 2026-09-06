defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit: the lots a guest holds, the amounts those lots have applied to
  group deposits, and the entitlement a chargeback claws back out of them.

  Applying credit pauses its expiry, because the amount now funds an active room
  rather than sitting in the lot. A refundable settlement puts it back into the
  lot it came from, with that lot's original expiry.

  A chargeback revokes the credit a reversed payment paid for. Whatever a lot can
  no longer give back is its unrecovered clawback, which the lot absorbs out of
  any credit that returns to it later.
  """

  import Ecto.Query

  alias GroupStay.Credit.Lot
  alias GroupStay.Funding.Allocation
  alias GroupStay.Repo

  @available_days 365

  @doc """
  The date a lot issued by a cancellation on `cancelled_on` expires.

  The lot is available through the 365th day after the cancellation and expires
  the day after that.
  """
  def expires_on(cancelled_on), do: Date.add(cancelled_on, @available_days + 1)

  @doc "A guest's usable lots as of `as_of`, earliest expiry first."
  def available_lots(guest_id, as_of) when is_binary(guest_id) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id,
        where: l.remaining_cents > 0,
        where: l.expires_on > ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
  end

  @doc "Issues a lot to a guest for a cancellation that happened on `cancelled_on`."
  def issue_lot(guest_id, source_operation_id, amount_cents, cancelled_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      issued_cents: amount_cents,
      remaining_cents: amount_cents,
      expires_on: expires_on(cancelled_on)
    })
    |> Repo.insert()
  end

  @doc """
  Takes `amount_cents` of a guest's credit out of their lots, ready to be
  allocated to rooms.

  Lots are consumed by earliest expiry, then by `source_operation_id`. Returns
  the slices taken as `{lot, amount_cents}` in consumption order, or
  `{:error, "insufficient_credit"}` when the guest cannot cover the amount as of
  `as_of`.
  """
  def reserve(guest_id, amount_cents, as_of) do
    lots = available_lots(guest_id, as_of)

    if sum_of(lots, & &1.remaining_cents) < amount_cents do
      {:error, "insufficient_credit"}
    else
      {:ok, take(lots, amount_cents)}
    end
  end

  defp take(_lots, 0), do: []

  defp take([lot | rest], amount_cents) do
    taken = min(lot.remaining_cents, amount_cents)
    {:ok, _lot} = set_remaining(lot, lot.remaining_cents - taken)
    [{lot, taken} | take(rest, amount_cents - taken)]
  end

  @doc """
  Returns `amount_cents` to the lot it came from.

  An unrecovered clawback is extinguished first, before the lot's expiry is
  considered at all: only what is left over becomes available again, and a lot
  whose expiry has already passed simply holds an expired amount instead.
  """
  def restore(lot_ref, amount_cents) do
    lot = Repo.get!(Lot, lot_ref)
    absorbed = min(lot.unrecovered_clawback_cents, amount_cents)

    {:ok, _lot} =
      update_lot(lot, %{
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        remaining_cents: lot.remaining_cents + amount_cents - absorbed
      })

    :ok
  end

  @doc """
  Revokes `amount_cents` of entitlement from a lot.

  The lot's own remaining balance pays first. Anything the lot cannot give back
  is credit that has already left it, and is remembered as unrecovered clawback.
  """
  def claw_back(lot_ref, amount_cents) do
    lot = Repo.get!(Lot, lot_ref)
    recovered = min(lot.remaining_cents, amount_cents)

    {:ok, _lot} =
      update_lot(lot, %{
        remaining_cents: lot.remaining_cents - recovered,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + amount_cents - recovered
      })

    :ok
  end

  @doc """
  Credit Northstar still owes guests as of `as_of`.

  This is the unexpired credit sitting in lots plus the credit currently applied
  to active groups, including credit a chargeback has left short, so applying and
  restoring credit leaves it unchanged.
  """
  def liability_cents(as_of) do
    available =
      Repo.one(
        from l in Lot,
          where: l.remaining_cents > 0,
          where: l.expires_on > ^as_of,
          select: sum(l.remaining_cents)
      )

    applied = Repo.one(from a in applied_credit(), select: sum(a.amount_cents))

    (available || 0) + (applied || 0)
  end

  @doc """
  Credit still applied to active groups that a chargeback has already revoked.

  A lot is short by the lesser of its unrecovered clawback and the credit from it
  that active groups are still holding; anything more has already left the
  liability by other means.
  """
  def shortfall_cents do
    applied =
      Repo.all(
        from a in applied_credit(),
          group_by: a.lot_ref,
          select: {a.lot_ref, sum(a.amount_cents)}
      )
      |> Map.new()

    Repo.all(from l in Lot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.map(&min(&1.unrecovered_clawback_cents, Map.get(applied, &1.id, 0)))
    |> Enum.sum()
  end

  # Credit that is still funding a room, which only ever happens on an active
  # room of an active group.
  defp applied_credit do
    from a in Allocation,
      where: a.kind == "credit",
      where: a.disposition == "held",
      where: not is_nil(a.lot_ref)
  end

  defp set_remaining(%Lot{} = lot, remaining_cents),
    do: update_lot(lot, %{remaining_cents: remaining_cents})

  defp update_lot(%Lot{} = lot, attrs) do
    lot
    |> Lot.changeset(attrs)
    |> Repo.update()
  end

  defp sum_of(enumerable, fun), do: enumerable |> Enum.map(fun) |> Enum.sum()
end
