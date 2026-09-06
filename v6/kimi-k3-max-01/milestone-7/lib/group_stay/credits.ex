defmodule GroupStay.Credits do
  @moduledoc """
  The hotel-credit context: credit lots issued by refundable cancellations,
  their application to group deposits, and the entitlements that tie lots
  back to the payments whose cash funded them.

  A lot is available through the day before `expires_on` and expires on
  `expires_on`. Credit applied to an active group keeps funding that group
  with its expiry paused until the group is cancelled: a refundable
  cancellation restores it to its original lot and expiry, while a
  non-refundable cancellation consumes it. Credit returning to a lot first
  extinguishes the lot's unrecovered clawback (its shortfall), before any
  excess becomes available again or expires.

  Expiry is always evaluated against an explicit date: the operation's
  `occurred_on` when applying or restoring credit, and the requested as-of
  date when reading balances.
  """

  import Ecto.Query

  alias GroupStay.Credits.Entitlement
  alias GroupStay.Credits.Lot
  alias GroupStay.Groups
  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  The credit lots available to a guest as of a date: unexpired and not
  exhausted, in consumption order (earliest expiry, then source operation).
  """
  def available_lots(guest_id, %Date{} = as_of) when is_binary(guest_id) do
    Lot
    |> where(guest_id: ^guest_id)
    |> where([lot], lot.expires_on > ^as_of)
    |> where([lot], lot.remaining_cents > 0)
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  @doc """
  The guest's available credit balance as of a date.
  """
  def available_cents(guest_id, %Date{} = as_of) do
    guest_id
    |> available_lots(as_of)
    |> Enum.map(& &1.remaining_cents)
    |> Enum.sum()
  end

  @doc """
  Issues a credit lot to a guest. Zero-value lots record nothing.
  """
  def issue_lot!(_guest_id, _source_operation_id, amount_cents, %Date{} = _expires_on)
      when amount_cents <= 0 do
    nil
  end

  def issue_lot!(guest_id, source_operation_id, amount_cents, %Date{} = expires_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      expires_on: expires_on,
      remaining_cents: amount_cents
    })
    |> Repo.insert!()
  end

  @doc """
  Records the per-payment entitlements of a freshly issued lot. `funding`
  lists the settled cash as `{payment_operation_id, amount_cents}` pairs in
  funding order, with the unattributed senior block (`nil`) first. Each
  entitlement is the 10%-bonus value of the settled cash through that
  payment minus the bonus value through the preceding payment, so the
  entitlements telescope exactly to the lot's issued amount.
  """
  def record_entitlements!(%Lot{} = lot, funding) when is_list(funding) do
    Enum.reduce(funding, {0, 0}, fn
      {_payer, 0}, acc ->
        acc

      {payer, amount}, {running, bonus_running} ->
        running = running + amount
        bonus_total = running + Groups.round_half_up(running * 10, 100)
        entitlement = bonus_total - bonus_running

        %Entitlement{}
        |> Entitlement.changeset(%{
          credit_lot_id: lot.id,
          payment_operation_id: payer,
          amount_cents: entitlement,
          unrecovered_cents: 0
        })
        |> Repo.insert!()

        {running, bonus_total}
    end)

    :ok
  end

  @doc """
  Revokes a payment's entitlement from every lot it contributed to. The
  entitlement comes out of the lot's remaining balance first; whatever
  cannot be removed becomes the lot's unrecovered clawback. Returns the
  `{expires_on, removed_cents}` detail of every lot the entitlement touched,
  so callers can classify the liability movement.
  """
  def revoke_entitlements!(payment_operation_id) do
    Entitlement
    |> where(payment_operation_id: ^payment_operation_id)
    |> preload(:credit_lot)
    |> Repo.all()
    |> Enum.flat_map(fn entitlement ->
      lot = entitlement.credit_lot
      recoverable = entitlement.amount_cents - entitlement.unrecovered_cents

      if recoverable > 0 do
        removed = min(lot.remaining_cents, recoverable)

        {:ok, _lot} =
          lot
          |> Lot.changeset(%{remaining_cents: lot.remaining_cents - removed})
          |> Repo.update()

        {:ok, _entitlement} =
          entitlement
          |> Entitlement.changeset(%{
            unrecovered_cents: entitlement.unrecovered_cents + (recoverable - removed)
          })
          |> Repo.update()

        if removed > 0 do
          [{lot.expires_on, removed}]
        else
          []
        end
      else
        []
      end
    end)
  end

  @doc """
  Applies `amount_cents` of the guest's credit to the group's deposit,
  consuming lots in consumption order and recording which lots funded the
  group. The caller must have verified the guest has enough available credit.
  """
  def apply_to_group!(%Group{} = group, amount_cents, %Date{} = as_of) do
    group.guest_id
    |> available_lots(as_of)
    |> Enum.reduce_while(amount_cents, fn
      _lot, 0 ->
        {:halt, 0}

      lot, remaining ->
        take = min(lot.remaining_cents, remaining)

        {:ok, _lot} =
          lot
          |> Lot.changeset(%{remaining_cents: lot.remaining_cents - take})
          |> Repo.update()

        Groups.allocate_funding!(group, "credit", take, credit_lot_id: lot.id)

        {:cont, remaining - take}
    end)

    :ok
  end

  @doc """
  Restores an applied credit allocation to its original lot and expiry after
  a refundable cancellation. The restored amount first extinguishes the
  lot's unrecovered clawback; only an excess becomes available again, and
  only if the lot has not already expired on the cancellation date. Returns
  the amounts absorbed by the clawback and immediately expired, so callers
  can classify the liability movement.
  """
  def restore_allocation!(%Allocation{kind: "credit"} = allocation, %Date{} = occurred_on) do
    lot = Repo.get!(Lot, allocation.credit_lot_id)
    excess = absorb_clawback!(lot, allocation.amount_cents)
    absorbed = allocation.amount_cents - excess

    expired? = Date.compare(lot.expires_on, occurred_on) != :gt

    if excess > 0 and not expired? do
      {:ok, _lot} =
        lot
        |> Lot.changeset(%{remaining_cents: lot.remaining_cents + excess})
        |> Repo.update()
    end

    %{absorbed: absorbed, expired: if(expired?, do: excess, else: 0)}
  end

  # Extinguishes the lot's unrecovered clawback; returns the amount left
  # after absorption. Absorption happens before any expiry check.
  defp absorb_clawback!(%Lot{} = lot, amount_cents) do
    entitlements =
      Entitlement
      |> where(credit_lot_id: ^lot.id)
      |> where([entitlement], entitlement.unrecovered_cents > 0)
      |> order_by(:id)
      |> Repo.all()

    {_takes, left} =
      Enum.map_reduce(entitlements, amount_cents, fn entitlement, left ->
        take = min(entitlement.unrecovered_cents, left)

        if take > 0 do
          {:ok, _entitlement} =
            entitlement
            |> Entitlement.changeset(%{unrecovered_cents: entitlement.unrecovered_cents - take})
            |> Repo.update()
        end

        {take, left - take}
      end)

    left
  end

  @doc """
  The credit liability as of a date: available credit in unexpired lots plus
  credit currently applied to active groups. Expiry and non-refundable
  consumption reduce it; applying or restoring credit does not, unless a
  restored lot has already expired or the restoration is absorbed by a
  shortfall.
  """
  def liability_cents(%Date{} = as_of) do
    available =
      Lot
      |> where([lot], lot.expires_on > ^as_of)
      |> select([lot], coalesce(sum(lot.remaining_cents), 0))
      |> Repo.one()

    applied =
      Allocation
      |> where(kind: "credit")
      |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
      |> Repo.one()

    available + applied
  end

  @doc """
  The current credit shortfall: for each lot, the lesser of its unrecovered
  clawback and the credit from that lot still applied to active groups,
  summed across lots.
  """
  def shortfall_cents do
    unrecovered_by_lot =
      Entitlement
      |> group_by(:credit_lot_id)
      |> select([entitlement], {entitlement.credit_lot_id, sum(entitlement.unrecovered_cents)})
      |> Repo.all()

    Enum.sum(
      for {lot_id, unrecovered} <- unrecovered_by_lot, unrecovered > 0 do
        applied =
          Allocation
          |> where(kind: "credit", credit_lot_id: ^lot_id)
          |> select([allocation], coalesce(sum(allocation.amount_cents), 0))
          |> Repo.one()

        min(unrecovered, applied)
      end
    )
  end

  @doc """
  The JSON representation of a guest's credit as returned by the read
  endpoint. Expired and exhausted lots are omitted.
  """
  def credit_payload(guest_id, %Date{} = as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: lots |> Enum.map(& &1.remaining_cents) |> Enum.sum(),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end
end
