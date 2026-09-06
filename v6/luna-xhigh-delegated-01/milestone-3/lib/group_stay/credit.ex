defmodule GroupStay.Credit do
  @moduledoc "Hotel-credit lots and the allocations that pause their expiry."

  import Ecto.Query

  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @active_status "active"

  def read_guest(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  def available_lots(guest_id, as_of) do
    Repo.all(
      from lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on > ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  def consume(guest_id, group_id, amount_cents, as_of) do
    lots = available_lots(guest_id, as_of)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount_cents do
      {:error, :insufficient_credit}
    else
      consume_lots(lots, group_id, amount_cents)
      {:ok, :consumed}
    end
  end

  def settle_allocations(group_id, as_of, refundable?) do
    allocations = allocations_for_group(group_id)

    expired_or_consumed_cents =
      Enum.reduce(allocations, 0, fn {allocation, lot}, total ->
        can_restore? = refundable? and Date.compare(lot.expires_on, as_of) == :gt

        if can_restore? do
          Repo.update!(
            Ecto.Changeset.change(lot,
              remaining_cents: lot.remaining_cents + allocation.amount_cents
            )
          )

          total
        else
          total + allocation.amount_cents
        end
        |> then(fn next_total ->
          Repo.delete!(allocation)
          next_total
        end)
      end)

    {:ok, expired_or_consumed_cents}
  end

  def allocations_for_group(group_id) do
    Repo.all(
      from allocation in Allocation,
        join: lot in Lot,
        on: lot.id == allocation.lot_id,
        where: allocation.group_id == ^group_id,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id],
        select: {allocation, lot}
    )
  end

  def issue(guest_id, source_operation_id, amount_cents, expires_on) when amount_cents > 0 do
    Repo.insert!(%Lot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      expires_on: expires_on
    })
  end

  def liability(as_of) do
    available =
      Repo.all(
        from lot in Lot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^as_of,
          select: lot.remaining_cents
      )
      |> Enum.sum()

    applied =
      Repo.all(
        from allocation in Allocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == ^@active_status,
          select: allocation.amount_cents
      )
      |> Enum.sum()

    available + applied
  end

  def liability_after_cancellation(group_id, as_of, refundable?, credit_issued_cents) do
    expired_or_consumed_cents =
      allocations_for_group(group_id)
      |> Enum.reduce(0, fn {allocation, lot}, total ->
        can_restore? = refundable? and Date.compare(lot.expires_on, as_of) == :gt

        if can_restore?, do: total, else: total + allocation.amount_cents
      end)

    liability(as_of) - expired_or_consumed_cents + credit_issued_cents
  end

  defp consume_lots(_lots, _group_id, 0), do: :ok

  defp consume_lots([lot | rest], group_id, amount_cents) do
    consumed_cents = min(lot.remaining_cents, amount_cents)

    Repo.update!(
      Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - consumed_cents)
    )

    Repo.insert!(%Allocation{
      group_id: group_id,
      lot_id: lot.id,
      amount_cents: consumed_cents
    })

    consume_lots(rest, group_id, amount_cents - consumed_cents)
  end
end
