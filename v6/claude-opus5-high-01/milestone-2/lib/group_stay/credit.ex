defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit: the lots a guest holds and the amounts those lots have redeemed
  into group deposits.

  Redeeming credit pauses its expiry, because the amount now funds an active
  group rather than sitting in the lot. A refundable cancellation puts it back
  into the lot it came from, with that lot's original expiry.
  """

  import Ecto.Query

  alias GroupStay.Credit.Lot
  alias GroupStay.Credit.Redemption
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

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
  Redeems `amount_cents` of the group guest's credit into that group.

  Lots are consumed by earliest expiry, then by `source_operation_id`. Returns
  `{:error, "insufficient_credit"}` when the guest cannot cover the amount as of
  `as_of`.
  """
  def redeem(%Group{} = group, amount_cents, as_of) do
    lots = available_lots(group.guest_id, as_of)

    if sum_by(lots, & &1.remaining_cents) < amount_cents do
      {:error, "insufficient_credit"}
    else
      take(lots, amount_cents, group)
    end
  end

  defp take(_lots, 0, _group), do: :ok

  defp take([lot | rest], amount_cents, group) do
    taken = min(lot.remaining_cents, amount_cents)

    {:ok, _lot} = set_remaining(lot, lot.remaining_cents - taken)

    {:ok, _redemption} =
      %Redemption{}
      |> Redemption.changeset(%{lot_ref: lot.id, group_ref: group.id, amount_cents: taken})
      |> Repo.insert()

    take(rest, amount_cents - taken, group)
  end

  @doc """
  Returns the credit a group redeemed to the lots it came from.

  A lot whose expiry has already passed simply holds an expired amount again, so
  the credit leaves the liability instead of becoming available.
  """
  def restore(%Group{} = group) do
    for redemption <- redemptions_for(group) do
      lot = Repo.get!(Lot, redemption.lot_ref)
      {:ok, _lot} = set_remaining(lot, lot.remaining_cents + redemption.amount_cents)
    end

    :ok
  end

  @doc """
  Credit Northstar still owes guests as of `as_of`.

  This is the unexpired credit sitting in lots plus the credit currently funding
  active groups, so redeeming and restoring credit leaves it unchanged.
  """
  def liability_cents(as_of) do
    available =
      Repo.one(
        from l in Lot,
          where: l.remaining_cents > 0,
          where: l.expires_on > ^as_of,
          select: sum(l.remaining_cents)
      )

    redeemed =
      Repo.one(
        from r in Redemption,
          join: g in Group,
          on: g.id == r.group_ref,
          where: g.status == "active",
          select: sum(r.amount_cents)
      )

    (available || 0) + (redeemed || 0)
  end

  defp redemptions_for(%Group{} = group) do
    Repo.all(from r in Redemption, where: r.group_ref == ^group.id, order_by: [asc: r.id])
  end

  defp set_remaining(%Lot{} = lot, remaining_cents) do
    lot
    |> Lot.changeset(%{remaining_cents: remaining_cents})
    |> Repo.update()
  end

  defp sum_by(enumerable, fun), do: enumerable |> Enum.map(fun) |> Enum.sum()
end
