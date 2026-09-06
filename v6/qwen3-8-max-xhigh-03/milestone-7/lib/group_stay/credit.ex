defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit issued from refundable cancellations: issuing lots, applying
  them to group deposits through room allocations, restoring or consuming
  them on settlement, clawbacks, and the read views over guest credit and the
  credit liability.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups
  alias GroupStay.Groups.RoomAllocation

  @available_days 365

  @doc """
  Issues a credit lot for a guest. The lot is available through
  `available_days` after `occurred_on` and expires the following day.
  """
  def issue_lot(guest_id, source_operation_id, issued_cents, occurred_on) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Lot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      issued_cents: issued_cents,
      remaining_cents: issued_cents,
      expires_on: Date.add(occurred_on, @available_days + 1),
      inserted_at: now,
      updated_at: now
    })
  end

  @doc """
  Applies `amount_cents` of a guest's unexpired credit to an active group's
  deposit, consuming lots by earliest expiry and then source operation and
  funding the group's rooms in their original order under `operation_id`.
  """
  def apply_credit(%Groups.Group{} = group, amount_cents, occurred_on, operation_id) do
    lots = available_lots(group.guest_id, occurred_on)
    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available < amount_cents do
      {:error, "insufficient_credit"}
    else
      chunks = consume_lots(lots, amount_cents)
      Groups.allocate_funding(group.group_id, chunks, operation_id)
      :ok
    end
  end

  @doc """
  Restores credit allocations to their original lots with the original
  expiry. Called when credit-funded rooms are settled while refundable.

  If the lot carries unrecovered clawback, the returning credit extinguishes
  that clawback before any amount becomes available; this absorption occurs
  before the expiry check. A restored amount whose expiry is already past on
  `occurred_on` expires immediately: it reduces the credit liability instead
  of becoming available again.

  Returns the totals that left the credit liability, as
  `{absorbed_cents, expired_cents}`.
  """
  def restore_allocations(allocations, occurred_on) do
    Enum.reduce(allocations, {0, 0}, fn allocation, {absorbed_total, expired_total} ->
      lot = Repo.get!(Lot, application_lot_id(allocation))

      absorbed = min(allocation.amount_cents, lot.clawback_cents)
      restored = allocation.amount_cents - absorbed

      available =
        if restored > 0 and Date.compare(lot.expires_on, occurred_on) == :gt do
          restored
        else
          0
        end

      if absorbed > 0 or available > 0 do
        lot
        |> change(
          clawback_cents: lot.clawback_cents - absorbed,
          remaining_cents: lot.remaining_cents + available
        )
        |> Repo.update!()
      end

      allocation |> change(disposition: "restored") |> Repo.update!()

      {absorbed_total + absorbed, expired_total + (restored - available)}
    end)
  end

  @doc """
  Consumes credit allocations without restoring them. Called when credit-funded
  rooms are settled non-refundably. Consumed credit is no longer applied to an
  active group, so any shortfall it covered shrinks automatically.
  """
  def consume_allocations(allocations) do
    Enum.each(allocations, fn allocation ->
      allocation |> change(disposition: "consumed") |> Repo.update!()
    end)
  end

  @doc """
  The guest's available credit lots as of a date: unexpired lots with
  remaining cents, ordered by expiry and then source operation.
  """
  def available_lots(guest_id, as_of) do
    Lot
    |> where(
      [l],
      l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_of
    )
    |> order_by([l], asc: l.expires_on, asc: l.source_operation_id)
    |> Repo.all()
  end

  @doc """
  The read view of a guest's credit as of a date.
  """
  def guest_credit(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots:
        Enum.map(
          lots,
          &%{
            source_operation_id: &1.source_operation_id,
            remaining_cents: &1.remaining_cents,
            expires_on: &1.expires_on
          }
        )
    }
  end

  @doc """
  The credit liability as of a date: available (unexpired) credit plus credit
  currently applied to active groups, whose expiry is paused while it funds
  the group. Credit covered by a current shortfall is still applied credit
  and remains in the liability.
  """
  def liability_cents(as_of) do
    available =
      Lot
      |> where([l], l.expires_on > ^as_of)
      |> select([l], sum(l.remaining_cents))
      |> Repo.one() || 0

    applied =
      RoomAllocation
      |> where([a], a.kind == "credit" and a.disposition == "held")
      |> select([a], sum(a.amount_cents))
      |> Repo.one() || 0

    available + applied
  end

  @doc """
  The current credit shortfall: for each lot carrying unrecovered clawback,
  the lesser of that clawback and the lot's credit still applied to active
  groups.
  """
  def shortfall_cents do
    applied_by_lot =
      RoomAllocation
      |> where([a], a.kind == "credit" and a.disposition == "held")
      |> group_by([a], a.lot_id)
      |> select([a], {a.lot_id, sum(a.amount_cents)})
      |> Repo.all()
      |> Map.new()

    Lot
    |> where([l], l.clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, acc ->
      acc + min(lot.clawback_cents, Map.get(applied_by_lot, lot.id, 0))
    end)
  end

  defp application_lot_id(%RoomAllocation{lot_id: lot_id}), do: lot_id

  defp consume_lots(lots, amount_cents), do: consume_lots(lots, amount_cents, [])

  defp consume_lots(_lots, 0, chunks), do: Enum.reverse(chunks)

  defp consume_lots([lot | rest], remaining_cents, chunks) do
    taken_cents = min(lot.remaining_cents, remaining_cents)

    lot
    |> change(remaining_cents: lot.remaining_cents - taken_cents)
    |> Repo.update!()

    consume_lots(rest, remaining_cents - taken_cents, [{lot.id, taken_cents} | chunks])
  end
end
