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

  def apply_to_group(%Group{} = group, amount_cents, %Date{} = occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)
    available = Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end)

    if available < amount_cents do
      {:error, :insufficient_credit}
    else
      consume(group, lots, amount_cents)
      :ok
    end
  end

  def restore_applied(%Group{} = group, %Date{} = occurred_on) do
    applications = applications_for(group)

    Enum.each(applications, fn application ->
      lot = application.credit_lot

      if Date.compare(occurred_on, lot.expires_on) != :gt do
        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents + application.amount_cents})
        |> Repo.update!()
      end

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

  defp consume(group, lots, amount_cents) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining ->
      if remaining == 0 do
        {:halt, 0}
      else
        take = min(lot.remaining_cents, remaining)

        lot
        |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - take})
        |> Repo.update!()

        record_application(group, lot, take)
        {:cont, remaining - take}
      end
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
