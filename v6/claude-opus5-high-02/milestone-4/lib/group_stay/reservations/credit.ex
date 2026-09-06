defmodule GroupStay.Reservations.Credit do
  @moduledoc """
  Hotel credit lots, their redemption into room deposits, and the liability they represent.

  Credit is issued for the cash of one settlement, is redeemed into the deposits of individual
  rooms, and returns to the lot it came from when such a room is settled while refundable. A
  chargeback can revoke the entitlement cash bought in a lot even after the credit was spent, which
  leaves the lot short until credit returns to it.

  Every function here runs inside the transaction of the operation that called it, so a rejected
  operation leaves lots and applications exactly as they were.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Money
  alias GroupStay.Repo
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Funding
  alias GroupStay.Reservations.Group

  @lot_days 365
  @bonus_percent 10

  @doc """
  What converted cash is worth as hotel credit: the cash itself plus its bonus.
  """
  def value_of(cash_cents), do: cash_cents + Money.percent_of(cash_cents, @bonus_percent)

  @doc """
  Issues a lot worth the converted cash plus its bonus.

  Returns `{lot, credit_issued_cents}`. A conversion of no cash issues nothing.
  """
  def issue(%Group{} = group, cash_cents, source_operation_id, issued_on) do
    amount_cents = value_of(cash_cents)

    lot =
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

    {lot, amount_cents}
  end

  @doc """
  Redeems `amount_cents` of the guest's unexpired credit into the group's room deposits.

  Lots are drawn earliest expiry first, then by `source_operation_id`, and fill the rooms in the
  order the rooms are funded. Returns `{:error, :insufficient_credit}` without touching anything
  when the guest cannot cover it.
  """
  def redeem(%Group{} = group, amount_cents, on) do
    lots = available_lots(group.guest_id, on)

    if total_remaining(lots) < amount_cents do
      {:error, :insufficient_credit}
    else
      group
      |> Funding.fill_plan(amount_cents)
      |> pair_with(draw_plan(lots, amount_cents))
      |> Enum.each(&draw(&1, group, on))

      :ok
    end
  end

  defp draw_plan(_lots, 0), do: []

  defp draw_plan([lot | rest], amount_cents) do
    drawn = min(lot.remaining_cents, amount_cents)
    [{lot, drawn} | draw_plan(rest, amount_cents - drawn)]
  end

  # The rooms to fill and the lots to draw from are two ways of splitting the same amount, so they
  # are walked together into the (room, lot) pairs the applications record.
  defp pair_with([], _draws), do: []

  defp pair_with([{room, room_cents} | rooms], [{lot, lot_cents} | lots]) do
    taken = min(room_cents, lot_cents)
    rooms = if room_cents > taken, do: [{room, room_cents - taken} | rooms], else: rooms
    lots = if lot_cents > taken, do: [{lot, lot_cents - taken} | lots], else: lots

    [{room, lot, taken} | pair_with(rooms, lots)]
  end

  defp draw({room, lot, amount_cents}, group, on) do
    Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id),
      inc: [remaining_cents: -amount_cents]
    )

    Repo.insert!(%CreditApplication{
      group_id: group.id,
      room_id: room.id,
      credit_lot_id: lot.id,
      amount_cents: amount_cents,
      applied_on: on,
      status: "applied"
    })
  end

  @doc """
  Returns credit that funded settled rooms to the lots it came from, keeping the original expiry.

  Credit never earns a second bonus. A lot that a chargeback left short takes what it is owed out
  of the returning amount first; only what is left over can become available again, and it expires
  with the lot if the lot's expiry is already past on the settlement date.
  """
  def restore(applications, on) do
    for application <- applications do
      lot = Repo.get!(CreditLot, application.credit_lot_id)
      absorbed_cents = min(application.amount_cents, lot.unrecovered_clawback_cents)
      returning_cents = application.amount_cents - absorbed_cents
      available? = CreditLot.available_on?(lot, on)

      lot
      |> Changeset.change(
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents,
        remaining_cents: lot.remaining_cents + if(available?, do: returning_cents, else: 0)
      )
      |> Repo.update!()

      settle(application, restored_status(returning_cents, available?), absorbed_cents)
    end

    :ok
  end

  defp restored_status(0, _available?), do: "absorbed"
  defp restored_status(_returning_cents, true), do: "restored"
  defp restored_status(_returning_cents, false), do: "expired"

  @doc """
  Keeps the credit that funded non-refundable rooms, which drops it from the liability.
  """
  def consume(applications) do
    for application <- applications, do: settle(application, "consumed", 0)
    :ok
  end

  defp settle(application, status, absorbed_cents) do
    application
    |> Changeset.change(status: status, absorbed_cents: absorbed_cents)
    |> Repo.update!()
  end

  @doc """
  Takes a payment's entitlement back out of a lot.

  Credit within a lot is fungible, so a clawback simply removes the entitlement from what the lot
  still holds. What the lot cannot cover is remembered until credit returns to it.
  """
  def claw_back(lot_id, entitlement_cents) do
    lot = Repo.get!(CreditLot, lot_id)
    recovered_cents = min(lot.remaining_cents, entitlement_cents)

    lot
    |> Changeset.change(
      remaining_cents: lot.remaining_cents - recovered_cents,
      unrecovered_clawback_cents:
        lot.unrecovered_clawback_cents + entitlement_cents - recovered_cents
    )
    |> Repo.update!()
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

  Both unexpired lots and credit currently funding active rooms count: redeeming credit only moves
  it between the two, so the liability only falls when credit expires, is consumed by a
  non-refundable settlement, has its entitlement revoked, or returns to a lot that is short.
  """
  def liability_cents(on) do
    unexpired = from l in CreditLot, where: l.expires_on >= ^on
    applied = from a in CreditApplication, where: a.status == "applied"

    sum_of(unexpired, :remaining_cents) + sum_of(applied, :amount_cents)
  end

  @doc """
  Credit that is funding active groups although a chargeback has already revoked it.

  A lot is only short while it is still owed clawback and credit from it is still applied
  somewhere; whichever of the two is smaller is what the shortfall currently amounts to.
  """
  def shortfall_cents do
    applied =
      from(a in CreditApplication,
        where: a.status == "applied",
        group_by: a.credit_lot_id,
        select: {a.credit_lot_id, sum(a.amount_cents)}
      )
      |> Repo.all()
      |> Map.new()

    from(l in CreditLot,
      where: l.unrecovered_clawback_cents > 0,
      select: {l.id, l.unrecovered_clawback_cents}
    )
    |> Repo.all()
    |> Enum.map(fn {id, clawback} -> min(clawback, Map.get(applied, id, 0)) end)
    |> Enum.sum()
  end

  defp total_remaining(lots), do: Enum.sum(Enum.map(lots, & &1.remaining_cents))

  defp sum_of(queryable, field), do: Repo.aggregate(queryable, :sum, field) || 0
end
