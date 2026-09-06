defmodule GroupStay.Credit do
  @moduledoc """
  Hotel credit issued from refundable cancellations: issuing lots, applying
  them to group deposits, restoring or consuming them on settlement, and the
  read views over guest credit and the credit liability.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit.Lot
  alias GroupStay.Credit.Application
  alias GroupStay.Groups.Group

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
  deposit, consuming lots by earliest expiry and then source operation.
  """
  def apply_credit(%Group{} = group, amount_cents, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)
    available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

    if available < amount_cents do
      {:error, "insufficient_credit"}
    else
      consume_lots(lots, amount_cents, group)
      :ok
    end
  end

  @doc """
  Restores the credit applied to a group back to its original lots with the
  original expiry. Called when a credit-funded group is cancelled while
  refundable. A restored amount whose expiry is already past on
  `occurred_on` expires immediately: it reduces the credit liability instead
  of becoming available again.
  """
  def restore_credit(%Group{} = group, occurred_on) do
    group
    |> applications_for()
    |> Enum.each(fn application ->
      lot = Repo.get!(Lot, application.lot_id)

      if Date.compare(lot.expires_on, occurred_on) == :gt do
        lot
        |> change(remaining_cents: lot.remaining_cents + application.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(application)
    end)
  end

  @doc """
  Consumes the credit applied to a group without restoring it. Called when a
  credit-funded group is cancelled non-refundably.
  """
  def consume_credit(%Group{} = group) do
    group
    |> applications_for()
    |> Enum.each(&Repo.delete!/1)
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
  the group.
  """
  def liability_cents(as_of) do
    available =
      Lot
      |> where([l], l.expires_on > ^as_of)
      |> select([l], sum(l.remaining_cents))
      |> Repo.one() || 0

    applied =
      Application
      |> join(:inner, [a], g in Group, on: g.group_id == a.group_id)
      |> where([_a, g], g.status == "active")
      |> select([a, _g], sum(a.amount_cents))
      |> Repo.one() || 0

    available + applied
  end

  defp consume_lots(_lots, 0, _group), do: :ok

  defp consume_lots([lot | rest], remaining_cents, group) do
    taken_cents = min(lot.remaining_cents, remaining_cents)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    lot
    |> change(remaining_cents: lot.remaining_cents - taken_cents)
    |> Repo.update!()

    Repo.insert!(%Application{
      group_id: group.group_id,
      lot_id: lot.id,
      amount_cents: taken_cents,
      inserted_at: now,
      updated_at: now
    })

    consume_lots(rest, remaining_cents - taken_cents, group)
  end

  defp applications_for(%Group{} = group) do
    Application
    |> where([a], a.group_id == ^group.group_id)
    |> order_by([a], asc: a.id)
    |> Repo.all()
  end
end
