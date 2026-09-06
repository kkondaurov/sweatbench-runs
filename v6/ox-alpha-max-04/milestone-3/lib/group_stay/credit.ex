defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit: lots issued by refundable cancellations, the amounts of those
  lots currently funding active groups, and the credit reads used by support
  and finance.

  Applying credit consumes the guest's lots by earliest expiry and then by
  source operation, recording one application per consumed portion so the
  funding lots can be restored. A lot's `remaining_cents` is its unapplied,
  unconsumed balance; while an amount funds an active group its expiry is
  paused, and it returns to the lot on a refundable cancellation or is
  consumed on a non-refundable one.
  """

  import Ecto.Query

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Issues a new credit lot for a guest.
  """
  @spec issue_lot!(map()) :: Lot.t()
  def issue_lot!(attrs) do
    %Lot{}
    |> Ecto.Changeset.cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> Repo.insert!()
  end

  @doc """
  The guest's credit lots that are unexpired as of `as_of` and still have a
  remaining balance, ordered by earliest expiry and then by source operation.
  """
  @spec available_lots(String.t(), Date.t()) :: [Lot.t()]
  def available_lots(guest_id, as_of) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id and l.expires_on > ^as_of and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  @doc """
  Applies `amount` of the group guest's credit to the group's deposit,
  consuming lots by earliest expiry and then by source operation and
  recording which portions funded the group. Returns `:ok`, or
  `:insufficient` when the guest's unexpired credit cannot cover the amount,
  in which case nothing is consumed.
  """
  @spec apply_to_group(Group.t(), pos_integer(), Date.t()) :: :ok | :insufficient
  def apply_to_group(group, amount, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount do
      :insufficient
    else
      consume(lots, amount, group.id)
      :ok
    end
  end

  @doc """
  The total credit currently applied to a group's deposit.
  """
  @spec applied_to_group(Ecto.UUID.t()) :: integer()
  def applied_to_group(group_id) do
    Repo.one(
      from a in Application,
        where: a.group_id == ^group_id,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  @doc """
  Returns the amounts a group's applications funded back to their original
  lots and expiries, and stops tracking them. The lot keeps its own expiry,
  so an amount restored to an already expired lot expires immediately.
  """
  @spec restore_group_credit!(Ecto.UUID.t()) :: integer()
  def restore_group_credit!(group_id) do
    applications = Repo.all(from a in Application, where: a.group_id == ^group_id)

    Enum.each(applications, fn application ->
      Repo.update_all(
        from(l in Lot, where: l.id == ^application.lot_id),
        inc: [remaining_cents: application.amount_cents]
      )
    end)

    Repo.delete_all(from a in Application, where: a.group_id == ^group_id)

    Enum.reduce(applications, 0, &(&1.amount_cents + &2))
  end

  @doc """
  Consumes the credit a group's applications funded: the amounts leave their
  lots for good and are no longer part of the credit liability.
  """
  @spec consume_group_credit!(Ecto.UUID.t()) :: integer()
  def consume_group_credit!(group_id) do
    applications = Repo.all(from a in Application, where: a.group_id == ^group_id)
    Repo.delete_all(from a in Application, where: a.group_id == ^group_id)

    Enum.reduce(applications, 0, &(&1.amount_cents + &2))
  end

  @doc """
  The guest's available credit as of `as_of`: one read-friendly entry per
  unexpired lot with a remaining balance, ordered by earliest expiry and then
  by source operation.
  """
  @spec guest_credit(String.t(), Date.t()) :: %{
          guest_id: String.t(),
          available_cents: integer(),
          lots: [map()]
        }
  def guest_credit(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots: Enum.map(lots, &lot_view/1)
    }
  end

  @doc """
  The total credit liability as of `as_of`: available credit plus credit
  currently applied to active groups. Applying or restoring credit therefore
  does not change it unless a restored lot has already expired; expiry and
  non-refundable consumption reduce it.
  """
  @spec liability(Date.t()) :: integer()
  def liability(as_of) do
    available =
      Repo.one(
        from l in Lot,
          where: l.expires_on > ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in Application,
          join: g in Group,
          on: g.id == a.group_id,
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + applied
  end

  defp consume(lots, amount, group_id) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      if remaining > 0 do
        take = min(lot.remaining_cents, remaining)

        Repo.update_all(from(l in Lot, where: l.id == ^lot.id),
          inc: [remaining_cents: -take]
        )

        Repo.insert!(%Application{
          group_id: group_id,
          lot_id: lot.id,
          amount_cents: take
        })

        {:cont, remaining - take}
      else
        {:halt, remaining}
      end
    end)
  end

  defp lot_view(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: lot.expires_on
    }
  end
end
