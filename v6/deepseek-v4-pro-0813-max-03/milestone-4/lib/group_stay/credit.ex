defmodule GroupStay.Credit do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Accounting.PaymentDisposition
  alias GroupStay.Accounting.RoomAllocation
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @doc "The standard 10% hotel-credit bonus, rounded half up."
  def bonus_value(principal), do: principal + round_cents_half_up(principal, 10)

  defp round_cents_half_up(numerator, denominator)
       when is_integer(numerator) and is_integer(denominator) do
    div(numerator * 2 + denominator, denominator * 2)
  end

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
  source operation id) and returns the per-lot takes taken:
  `{:ok, [%{lot_id: id, amount_cents: amount}]}` or `{:error, :insufficient_credit}`.
  """
  def consume!(group, amount_cents, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount_cents do
      {:error, :insufficient_credit}
    else
      {takes, _} =
        Enum.reduce(lots, {[], amount_cents}, fn lot, {takes, need} ->
          if need <= 0 do
            {takes, need}
          else
            take = min(need, lot.remaining_cents)

            if take > 0 do
              Repo.update_all(
                from(l in CreditLot, where: l.id == ^lot.id),
                set: [remaining_cents: lot.remaining_cents - take]
              )

              {takes ++ [%{lot_id: lot.id, amount_cents: take}], need - take}
            else
              {takes, need}
            end
          end
        end)

      {:ok, takes}
    end
  end

  @doc """
  Returns credit allocated to the given rooms (identified by their allocation
  rows) to their original lots. Unrecovered clawback is extinguished before
  any credit becomes available again; only the excess then returns to the
  lot or expires under the existing rules.
  """
  def restore_for_rooms!(credit_rows, cancellation_date) do
    credit_rows
    |> Enum.group_by(& &1.lot_id, & &1.amount_cents)
    |> Enum.each(fn {lot_id, amounts} ->
      if is_integer(lot_id) do
        lot = Repo.get!(CreditLot, lot_id)
        total = Enum.sum(amounts)

        absorbed = min(total, lot.unrecovered_clawback_cents)
        excess = total - absorbed

        restored =
          if Date.compare(lot.expires_on, cancellation_date) != :lt do
            excess
          else
            0
          end

        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot_id),
          set: [
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
            remaining_cents: lot.remaining_cents + restored
          ]
        )
      end
    end)

    Repo.delete_all(from a in RoomAllocation, where: a.id in ^Enum.map(credit_rows, & &1.id))
    :ok
  end

  @doc "Consumes credit allocated to the given rooms on a non-refundable settlement."
  def consume_for_rooms!(credit_rows) do
    Repo.delete_all(from a in RoomAllocation, where: a.id in ^Enum.map(credit_rows, & &1.id))
    :ok
  end

  @doc """
  Credit liability: unexpired lot balances plus credit currently applied to
  active groups. Applying or restoring credit keeps it constant; revocation,
  expiry, shortfall absorption and non-refundable consumption reduce it.
  """
  def liability(on) do
    available =
      Repo.aggregate(
        from(l in CreditLot, where: l.expires_on >= ^on and l.remaining_cents > 0),
        :sum,
        :remaining_cents
      ) || 0

    applied =
      Repo.aggregate(from(a in RoomAllocation, where: a.kind == "credit"), :sum, :amount_cents) ||
        0

    available + applied
  end

  @doc """
  Sum of current lot shortfalls: for each lot, the lesser of its unrecovered
  clawback and the credit from that lot still applied to active groups.
  """
  def shortfall_total do
    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, acc ->
      applied =
        Repo.aggregate(
          from(a in RoomAllocation,
            where: a.lot_id == ^lot.id and a.kind == "credit"
          ),
          :sum,
          :amount_cents
        ) || 0

      acc + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  @doc """
  A payment's entitlement in a converted lot: the 10%-bonus value of settled
  cash through that payment minus the bonus value through the preceding
  contributor, in the funding order used by room accounting (the unattributed
  senior block first, then durable records in commit order).
  """
  def entitlement_for_payment(lot_id, payment_operation_id) do
    rows =
      Repo.all(
        from d in PaymentDisposition,
          where: d.lot_id == ^lot_id and d.kind == "converted"
      )

    {legacy, payments} =
      Enum.split_with(rows, &is_nil(&1.payment_operation_id))

    legacy_total = legacy |> Enum.map(& &1.amount_cents) |> Enum.sum()
    ids = payments |> Enum.map(& &1.payment_operation_id)

    commit_order =
      Map.new(
        Repo.all(
          from o in Operation, where: o.operation_id in ^ids, select: {o.operation_id, o.id}
        )
      )

    ordered =
      if(legacy_total > 0, do: [{nil, legacy_total}], else: []) ++
        (payments
         |> Enum.map(&{&1.payment_operation_id, &1.amount_cents})
         |> Enum.sort_by(fn {pid, _} -> commit_order[pid] || 0 end))

    {entitlement, _running} =
      Enum.reduce(ordered, {0, 0}, fn {source, amount}, {acc, running} ->
        next = running + amount

        if source == payment_operation_id do
          {acc + bonus_value(next) - bonus_value(running), next}
        else
          {acc, next}
        end
      end)

    entitlement
  end

  @doc """
  Removes the payment's entitlement from the lot's remaining balance first;
  whatever cannot be removed becomes the lot's unrecovered clawback.
  """
  def revoke_entitlement!(lot_id, entitlement) do
    lot = Repo.get!(CreditLot, lot_id)
    taken = min(entitlement, lot.remaining_cents)

    Repo.update_all(
      from(l in CreditLot, where: l.id == ^lot_id),
      set: [
        remaining_cents: lot.remaining_cents - taken,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + (entitlement - taken)
      ]
    )

    :ok
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
