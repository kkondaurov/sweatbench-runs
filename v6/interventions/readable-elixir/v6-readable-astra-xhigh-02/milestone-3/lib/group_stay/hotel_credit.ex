defmodule GroupStay.HotelCredit do
  @moduledoc """
  Issues, redeems and restores guest credit while preserving each lot's expiry.

  Mutations run inside the reservation operation's immediate transaction. That
  lock protects credit shared by several groups, as well as each group's revision.
  Reads filter current balances by expiry; they do not replay past operations.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.HotelCredit.{Application, Lot}
  alias GroupStay.Repo

  def balance(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  @doc false
  def available_liability_cents(on) do
    from(lot in Lot, where: lot.expires_on >= ^on, select: lot.remaining_cents)
    |> Repo.all()
    |> Enum.sum()
  end

  @doc false
  def issue(_group, _operation_id, 0, _on), do: 0

  def issue(group, operation_id, cash_cents, on) do
    issued = cash_cents + div(cash_cents * 10 + 50, 100)

    Repo.insert!(%Lot{
      source_group_id: group.group_id,
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      issued_cents: issued,
      remaining_cents: issued,
      expires_on: Date.add(on, 365)
    })

    issued
  end

  @doc false
  def apply_to_group(group, amount, on) do
    lots = Repo.all(available_lots(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount do
      Enum.reduce_while(lots, amount, fn lot, outstanding ->
        redeemed = min(lot.remaining_cents, outstanding)
        change_remaining(lot, -redeemed)
        record_application(group, lot, redeemed)

        case outstanding - redeemed do
          0 -> {:halt, 0}
          remaining -> {:cont, remaining}
        end
      end)

      :ok
    else
      {:error, :insufficient_credit}
    end
  end

  @doc false
  def restore(group, on) do
    applications =
      Repo.all(
        from application in Application,
          where: application.group_id == ^group.group_id,
          preload: [:credit_lot]
      )

    Enum.each(applications, fn application ->
      # An expired restoration is settled immediately, so it cannot become
      # spendable again even if a later operation supplies an earlier date.
      if Date.compare(application.credit_lot.expires_on, on) != :lt do
        change_remaining(application.credit_lot, application.amount_cents)
      end
    end)
  end

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp change_remaining(lot, delta) do
    lot
    |> Changeset.change(remaining_cents: lot.remaining_cents + delta)
    |> Repo.update!()
  end

  defp record_application(group, lot, amount) do
    case Repo.get_by(Application, group_id: group.group_id, credit_lot_id: lot.id) do
      nil ->
        Repo.insert!(%Application{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: amount
        })

      application ->
        application
        |> Changeset.change(amount_cents: application.amount_cents + amount)
        |> Repo.update!()
    end
  end
end
