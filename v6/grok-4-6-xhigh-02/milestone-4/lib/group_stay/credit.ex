defmodule GroupStay.Credit do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Money
  alias GroupStay.Repo

  def as_of(nil), do: Date.utc_today()

  def as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  def as_of(%Date{} = date), do: date
  def as_of(_), do: Date.utc_today()

  def guest_credit(guest_id, as_of) when is_binary(guest_id) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end),
      lots: Enum.map(lots, &serialize_lot/1)
    }
  end

  def available_cents(guest_id, as_of) do
    available_lots(guest_id, as_of)
    |> Enum.reduce(0, fn lot, acc -> acc + lot.remaining_cents end)
  end

  def liability_cents(as_of) do
    available =
      from(l in CreditLot,
        where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
        select: coalesce(sum(l.remaining_cents), 0)
      )
      |> Repo.one()

    applied =
      from(g in Group,
        where: g.status == "active",
        select: coalesce(sum(g.credit_paid_cents), 0)
      )
      |> Repo.one()

    available + applied
  end

  def issue_lot(_guest_id, _source_operation_id, cash_cents, _cancelled_on)
      when cash_cents <= 0 do
    0
  end

  def issue_lot(guest_id, source_operation_id, cash_cents, cancelled_on) do
    issued_cents = cash_cents + Money.percent(cash_cents, 10)

    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: issued_cents,
      expires_on: Date.add(cancelled_on, 365)
    })
    |> Repo.insert!()

    issued_cents
  end

  def take_from_lots(guest_id, amount_cents, %Date{} = occurred_on) do
    lots = available_lots(guest_id, occurred_on)
    available = Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end)

    if available < amount_cents do
      {:error, :insufficient_credit}
    else
      {_left, takes} =
        Enum.reduce_while(lots, {amount_cents, []}, fn lot, {remaining, takes} ->
          if remaining == 0 do
            {:halt, {0, takes}}
          else
            take = min(lot.remaining_cents, remaining)

            lot
            |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - take})
            |> Repo.update!()

            {:cont, {remaining - take, takes ++ [{lot, take}]}}
          end
        end)

      {:ok, takes}
    end
  end

  def apply_to_group(%Group{} = group, amount_cents, %Date{} = occurred_on) do
    case take_from_lots(group.guest_id, amount_cents, occurred_on) do
      {:error, :insufficient_credit} ->
        {:error, :insufficient_credit}

      {:ok, takes} ->
        consume_recorded(group, takes)
        :ok
    end
  end

  def return_to_lot!(%CreditLot{} = lot, amount_cents, %Date{} = occurred_on)
      when amount_cents > 0 do
    lot = Repo.get!(CreditLot, lot.id)
    unrecovered = lot.unrecovered_clawback_cents || 0
    absorb = min(amount_cents, unrecovered)
    excess = amount_cents - absorb

    remaining =
      if excess > 0 and Date.compare(occurred_on, lot.expires_on) != :gt do
        lot.remaining_cents + excess
      else
        lot.remaining_cents
      end

    lot
    |> CreditLot.changeset(%{
      remaining_cents: remaining,
      unrecovered_clawback_cents: unrecovered - absorb
    })
    |> Repo.update!()
  end

  def return_to_lot!(_lot, _amount_cents, _occurred_on), do: :ok

  def clawback_lot!(%CreditLot{} = lot, entitlement_cents) when entitlement_cents > 0 do
    lot = Repo.get!(CreditLot, lot.id)
    from_remaining = min(entitlement_cents, lot.remaining_cents)

    lot
    |> CreditLot.changeset(%{
      remaining_cents: lot.remaining_cents - from_remaining,
      unrecovered_clawback_cents:
        (lot.unrecovered_clawback_cents || 0) + (entitlement_cents - from_remaining)
    })
    |> Repo.update!()
  end

  def clawback_lot!(_lot, _entitlement_cents), do: :ok

  def restore_applied(%Group{} = group, %Date{} = occurred_on) do
    applications = applications_for(group)

    Enum.each(applications, fn application ->
      return_to_lot!(application.credit_lot, application.amount_cents, occurred_on)
      Repo.delete!(application)
    end)
  end

  def consume_applied(%Group{} = group) do
    applications = applications_for(group)
    Enum.each(applications, &Repo.delete!/1)
  end

  defp available_lots(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
    |> Repo.all()
  end

  defp consume_recorded(group, takes) do
    Enum.each(takes, fn {lot, take} ->
      record_application(group, lot, take)
    end)
  end

  defp record_application(group, lot, amount_cents) do
    case Repo.get_by(CreditApplication, group_id: group.id, credit_lot_id: lot.id) do
      nil ->
        %CreditApplication{}
        |> CreditApplication.changeset(%{
          group_id: group.id,
          credit_lot_id: lot.id,
          amount_cents: amount_cents
        })
        |> Repo.insert!()

      application ->
        application
        |> CreditApplication.changeset(%{
          amount_cents: application.amount_cents + amount_cents
        })
        |> Repo.update!()
    end
  end

  defp applications_for(group) do
    from(a in CreditApplication,
      where: a.group_id == ^group.id,
      preload: [:credit_lot]
    )
    |> Repo.all()
  end

  defp serialize_lot(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: lot.expires_on
    }
  end
end
