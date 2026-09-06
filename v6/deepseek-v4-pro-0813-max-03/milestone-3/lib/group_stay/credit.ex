defmodule GroupStay.Credit do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credit.CreditAllocation
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Repo

  @doc "Creates a credit lot for one guest."
  def issue_lot!(guest_id, source_operation_id, amount_cents, expires_on) do
    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      expires_on: expires_on
    })
  end

  @doc "Unexpired lots with credit left, ordered by expiry and then source operation."
  def available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
  end

  def available_cents(guest_id, on) do
    Repo.aggregate(
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0
      ),
      :sum,
      :remaining_cents
    ) || 0
  end

  @doc """
  Consumes the requested amount from a guest's lots (earliest expiry, then
  source operation id) and records the allocations against the given group.
  """
  def consume!(group, amount_cents, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount_cents do
      {:error, :insufficient_credit}
    else
      Enum.reduce_while(lots, amount_cents, fn lot, need ->
        if need <= 0 do
          {:halt, need}
        else
          take = min(need, lot.remaining_cents)

          if take > 0 do
            take_from_lot(group, lot, take)
          end

          {:cont, need - take}
        end
      end)

      :ok
    end
  end

  defp take_from_lot(group, lot, take) do
    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - take)
    |> Repo.update!()

    Repo.insert!(%CreditAllocation{
      group_id: group.id,
      lot_id: lot.id,
      amount_cents: take
    })
  end

  @doc """
  Returns credit applied to a group to its original lots. Any amount whose
  original expiry is already past on the cancellation date expires immediately
  instead of becoming available again.
  """
  def restore_for_cancellation!(group, cancellation_date) do
    allocations =
      Repo.all(from a in CreditAllocation, where: a.group_id == ^group.id)

    allocations
    |> Enum.group_by(& &1.lot_id, & &1.amount_cents)
    |> Enum.each(fn {lot_id, amounts} ->
      lot = Repo.get!(CreditLot, lot_id)

      if Date.compare(lot.expires_on, cancellation_date) != :lt do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + Enum.sum(amounts))
        |> Repo.update!()
      end
    end)

    Repo.delete_all(from a in CreditAllocation, where: a.group_id == ^group.id)
    :ok
  end

  @doc "Consumes credit applied to a group on a non-refundable cancellation."
  def consume_for_cancellation!(group) do
    Repo.delete_all(from a in CreditAllocation, where: a.group_id == ^group.id)
    :ok
  end

  @doc """
  Credit liability: unexpired lot balances plus credit currently applied to
  groups. Applying or restoring credit keeps it constant; expiry and
  non-refundable consumption reduce it.
  """
  def liability(on) do
    available =
      Repo.aggregate(
        from(l in CreditLot, where: l.expires_on >= ^on and l.remaining_cents > 0),
        :sum,
        :remaining_cents
      ) || 0

    applied = Repo.aggregate(CreditAllocation, :sum, :amount_cents) || 0
    available + applied
  end

  def guest_credit_json(guest_id, on) do
    lots =
      guest_id
      |> available_lots(on)
      |> Enum.map(fn lot ->
        %{
          "source_operation_id" => lot.source_operation_id,
          "remaining_cents" => lot.remaining_cents,
          "expires_on" => Date.to_iso8601(lot.expires_on)
        }
      end)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.reduce(lots, 0, &(&2 + &1["remaining_cents"])),
      "lots" => lots
    }
  end
end
