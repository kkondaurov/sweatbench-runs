defmodule GroupStay.Credits do
  @moduledoc """
  Hotel credit lots and their application to group deposits.

  A lot is created when a refundable cancellation settles into hotel credit.
  Its value funds later deposits: while applied to an active group the amount
  is paused (expiry cannot bite), and a refundable cancellation restores it to
  the original lot. A lot's available balance is what remains unapplied and
  unexpired as of a given date.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Credits.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Issues a credit lot for a guest, sourced from the cancellation operation
  that created it.
  """
  def create_lot(attrs) do
    %CreditLot{}
    |> cast(attrs, [:guest_id, :source_operation_id, :amount_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :amount_cents, :expires_on])
    |> Repo.insert!()
  end

  @doc """
  The guest's credit position as of the given date: total available credit and
  the live lots, ordered by expiry and then source operation. Expired and
  exhausted lots are omitted.
  """
  def guest_credit(guest_id, on_date) do
    redeemable = redeemable_lots(guest_id, on_date)

    %{
      "guest_id" => guest_id,
      "available_cents" => available_from(redeemable),
      "lots" =>
        Enum.map(redeemable, fn {lot, remaining} ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => remaining,
            "expires_on" => Date.to_string(lot.expires_on)
          }
        end)
    }
  end

  @doc """
  The credit the guest can spend on the given date: unapplied balances of
  unexpired lots.
  """
  def available_cents(guest_id, on_date) do
    available_from(redeemable_lots(guest_id, on_date))
  end

  @doc """
  Redeems the guest's credit into the group's deposit, consuming lots by
  earliest expiry and then by source operation. The caller guarantees the
  guest has enough available credit.
  """
  def consume(guest_id, amount_cents, on_date, %Group{} = group) do
    guest_id
    |> redeemable_lots(on_date)
    |> Enum.reduce(amount_cents, fn {lot, remaining}, needed ->
      if needed > 0 do
        take = min(needed, remaining)

        %CreditApplication{}
        |> cast(
          %{credit_lot_id: lot.id, group_id: group.id, amount_cents: take},
          [:credit_lot_id, :group_id, :amount_cents]
        )
        |> Repo.insert!()

        needed - take
      else
        needed
      end
    end)

    :ok
  end

  @doc """
  Returns the credit funding the group to its original lots, where it keeps
  its original expiry.
  """
  def restore_applications(%Group{} = group) do
    Repo.delete_all(from a in CreditApplication, where: a.group_id == ^group.id)
  end

  @doc """
  Permanently consumes the credit funding the group (a non-refundable
  settlement): the lots shrink by the applied amounts so the credit is never
  available again.
  """
  def consume_applications(%Group{} = group) do
    applications = Repo.all(from a in CreditApplication, where: a.group_id == ^group.id)

    Enum.each(applications, fn application ->
      lot = Repo.get!(CreditLot, application.credit_lot_id)

      lot
      |> change(amount_cents: lot.amount_cents - application.amount_cents)
      |> Repo.update!()
    end)

    restore_applications(group)
  end

  @doc """
  The outstanding credit liability as of the given date: available credit plus
  credit paused inside active deposits. Applied credit counts even when its
  lot has expired, because expiry is paused while it funds a group.
  """
  def liability_cents(on_date) do
    lots = Repo.all(CreditLot)
    applied = applied_by_lot(Enum.map(lots, & &1.id))

    Enum.sum(
      Enum.map(lots, fn lot ->
        if Date.compare(on_date, lot.expires_on) == :gt do
          Map.get(applied, lot.id, 0)
        else
          lot.amount_cents
        end
      end)
    )
  end

  defp available_from(redeemable) do
    Enum.sum(Enum.map(redeemable, fn {_lot, remaining} -> remaining end))
  end

  # Unexpired lots with an unapplied balance, in consumption order.
  defp redeemable_lots(guest_id, on_date) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.expires_on >= ^on_date,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    applied = applied_by_lot(Enum.map(lots, & &1.id))

    lots
    |> Enum.map(fn lot -> {lot, lot.amount_cents - Map.get(applied, lot.id, 0)} end)
    |> Enum.filter(fn {_lot, remaining} -> remaining > 0 end)
  end

  defp applied_by_lot(lot_ids) do
    from(a in CreditApplication,
      where: a.credit_lot_id in ^lot_ids,
      group_by: a.credit_lot_id,
      select: {a.credit_lot_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
