defmodule GroupStay.Credits do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Groups.{Group, HotelCreditApplication, HotelCreditLot}
  alias GroupStay.Repo

  @active "active"

  def guest_credit(guest_id, on) when is_binary(guest_id) and is_struct(on, Date) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
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

  def guest_credit(_guest_id, _on), do: %{guest_id: nil, available_cents: 0, lots: []}

  def consume!(%Group{} = group, amount_cents, on) do
    lots = available_lots(group.guest_id, on)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      {:error, :insufficient_credit}
    else
      lots
      |> Enum.reduce_while(amount_cents, fn lot, remaining_to_apply ->
        amount_from_lot = min(lot.remaining_cents, remaining_to_apply)

        if amount_from_lot == 0 do
          {:cont, remaining_to_apply}
        else
          case Repo.update_all(
                 from(current_lot in HotelCreditLot,
                   where:
                     current_lot.id == ^lot.id and current_lot.remaining_cents >= ^amount_from_lot and
                       current_lot.expires_on > ^on
                 ),
                 inc: [remaining_cents: -amount_from_lot]
               ) do
            {1, _} ->
              %HotelCreditApplication{}
              |> Ecto.Changeset.change(%{
                group_id: group.id,
                hotel_credit_lot_id: lot.id,
                amount_cents: amount_from_lot
              })
              |> Repo.insert!()

              {:cont, remaining_to_apply - amount_from_lot}

            {0, _} ->
              Repo.rollback(:retry)
          end
        end
      end)

      :ok
    end
  end

  def issue(guest_id, source_operation_id, cash_cents, cancelled_on)
      when is_binary(guest_id) and is_binary(source_operation_id) and is_integer(cash_cents) and
             cash_cents >= 0 and is_struct(cancelled_on, Date) do
    credit_cents = cash_cents + round_percentage(cash_cents, 10)

    if credit_cents > 0 do
      %HotelCreditLot{}
      |> Ecto.Changeset.change(%{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: credit_cents,
        expires_on: Date.add(cancelled_on, 366)
      })
      |> Repo.insert!()
    end

    credit_cents
  end

  def restore_group_credit!(%Group{} = group, cancelled_on) do
    group_credit_applications(group.id)
    |> Enum.each(fn application ->
      if Date.compare(application.hotel_credit_lot.expires_on, cancelled_on) == :gt do
        Repo.update_all(
          from(lot in HotelCreditLot, where: lot.id == ^application.hotel_credit_lot_id),
          inc: [remaining_cents: application.amount_cents]
        )
      end

      Repo.delete!(application)
    end)
  end

  def consume_group_credit!(%Group{} = group) do
    Repo.delete_all(
      from(application in HotelCreditApplication, where: application.group_id == ^group.id)
    )
  end

  def liability_cents(on) when is_struct(on, Date) do
    available =
      Repo.one(
        from(lot in HotelCreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
        )
      )

    applied =
      Repo.one(
        from(application in HotelCreditApplication,
          join: group in Group,
          on: application.group_id == group.id,
          where: group.status == ^@active,
          select: coalesce(sum(application.amount_cents), 0)
        )
      )

    available + applied
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from(lot in HotelCreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
    )
  end

  defp group_credit_applications(group_id) do
    Repo.all(
      from(application in HotelCreditApplication,
        join: lot in HotelCreditLot,
        on: application.hotel_credit_lot_id == lot.id,
        where: application.group_id == ^group_id,
        preload: [hotel_credit_lot: lot]
      )
    )
  end

  defp round_percentage(amount_cents, percentage),
    do: div(amount_cents * percentage + 50, 100)
end
