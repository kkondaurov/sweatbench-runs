defmodule GroupStay.Reservations.Credit do
  @moduledoc """
  Hotel credit lots, their redemption into group deposits, and the liability they represent.

  Every function here runs inside the transaction of the operation that called it, so a rejected
  operation leaves lots and applications exactly as they were.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Money
  alias GroupStay.Repo
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Group

  @lot_days 365
  @bonus_percent 10

  @doc """
  Issues a lot worth the converted cash plus its bonus, and returns the credit issued.

  A conversion of no cash issues nothing.
  """
  def issue(%Group{} = group, cash_cents, source_operation_id, issued_on) do
    amount_cents = cash_cents + Money.percent_of(cash_cents, @bonus_percent)

    if amount_cents > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        issued_on: issued_on,
        expires_on: Date.add(issued_on, @lot_days),
        original_cents: amount_cents,
        remaining_cents: amount_cents
      })
    end

    amount_cents
  end

  @doc """
  Redeems `amount_cents` of the guest's unexpired credit into the group's deposit.

  Lots are drawn earliest expiry first, then by `source_operation_id`. Returns
  `{:error, :insufficient_credit}` without touching anything when the guest cannot cover it.
  """
  def redeem(%Group{} = group, amount_cents, on) do
    lots = available_lots(group.guest_id, on)

    if total_remaining(lots) < amount_cents do
      {:error, :insufficient_credit}
    else
      draw(lots, amount_cents, group, on)
      :ok
    end
  end

  defp draw(_lots, 0, _group, _on), do: :ok

  defp draw([lot | rest], amount_cents, group, on) do
    drawn = min(lot.remaining_cents, amount_cents)

    lot
    |> Changeset.change(remaining_cents: lot.remaining_cents - drawn)
    |> Repo.update!()

    Repo.insert!(%CreditApplication{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: drawn,
      applied_on: on,
      status: "applied"
    })

    draw(rest, amount_cents - drawn, group, on)
  end

  @doc """
  Returns credit that funded the group to the lots it came from, keeping the original expiry.

  Credit never earns a second bonus. An amount whose lot has already expired on the cancellation
  date expires with it rather than becoming available again.
  """
  def restore(%Group{} = group, on) do
    for application <- applied_to(group) do
      lot = Repo.get!(CreditLot, application.credit_lot_id)

      if CreditLot.available_on?(lot, on) do
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents + application.amount_cents)
        |> Repo.update!()

        settle(application, "restored")
      else
        settle(application, "expired")
      end
    end

    :ok
  end

  @doc """
  Keeps the credit that funded a non-refundable group, which drops it from the liability.
  """
  def consume(%Group{} = group) do
    for application <- applied_to(group), do: settle(application, "consumed")
    :ok
  end

  defp settle(application, status) do
    application
    |> Changeset.change(status: status)
    |> Repo.update!()
  end

  defp applied_to(%Group{id: id}) do
    Repo.all(
      from a in CreditApplication,
        where: a.group_id == ^id and a.status == "applied",
        order_by: [asc: a.id]
    )
  end

  @doc """
  The guest's unexpired, unexhausted lots on the given date, in the order they are consumed.
  """
  def available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  @doc """
  Credit the guest can still spend on the given date, with the lots it comes from.
  """
  def available(guest_id, on) do
    lots = available_lots(guest_id, on)
    %{guest_id: guest_id, available_cents: total_remaining(lots), lots: lots}
  end

  @doc """
  Credit GroupStay still owes guests on the given date.

  Both unexpired lots and credit currently funding active groups count: redeeming credit only
  moves it between the two, so the liability only falls when credit expires or is consumed by a
  non-refundable cancellation.
  """
  def liability_cents(on) do
    unexpired = from l in CreditLot, where: l.expires_on >= ^on
    applied = from a in CreditApplication, where: a.status == "applied"

    sum_of(unexpired, :remaining_cents) + sum_of(applied, :amount_cents)
  end

  defp total_remaining(lots), do: Enum.sum(Enum.map(lots, & &1.remaining_cents))

  defp sum_of(queryable, field), do: Repo.aggregate(queryable, :sum, field) || 0
end
