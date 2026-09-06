defmodule GroupStay.Credit do
  @moduledoc """
  Guest hotel credit: lots created from refundable cancellations and applied
  to later reservations.
  """

  alias GroupStay.{CreditApplication, CreditLot, Repo, Room, RoomAllocation}

  import Ecto.Query

  @doc """
  Unexpired lots holding remaining credit for a guest as of a date, ordered
  by expiry date, then by the operation that created the lot.
  """
  @spec available_lots(String.t(), Date.t()) :: [CreditLot.t()]
  def available_lots(guest_id, on) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
    |> Repo.all()
  end

  @doc """
  The guest credit payload for the read endpoint, reported as of a date.
  """
  @spec to_response(String.t(), Date.t()) :: map()
  def to_response(guest_id, on) do
    lots = available_lots(guest_id, on)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      "lots" => Enum.map(lots, &lot_response/1)
    }
  end

  @doc """
  Total credit liability as of a date: remaining unexpired credit plus
  credit currently applied to active reservations.
  """
  @spec liability(Date.t()) :: non_neg_integer()
  def liability(on) do
    remaining =
      from(l in CreditLot,
        where: l.remaining_cents > 0 and l.expires_on > ^on,
        select: type(coalesce(sum(l.remaining_cents), 0), :integer)
      )
      |> Repo.one()

    applied =
      from(l in CreditLot,
        select: type(coalesce(sum(l.applied_cents), 0), :integer)
      )
      |> Repo.one()

    remaining + applied
  end

  @doc """
  The current clawback shortfall: for each lot, the lesser of its
  unrecovered clawback and the credit from that lot still applied to active
  groups.
  """
  @spec shortfall() :: non_neg_integer()
  def shortfall do
    applied_active =
      from(a in RoomAllocation,
        join: app in CreditApplication,
        on: app.id == a.credit_application_id,
        join: r in Room,
        on: r.id == a.room_id and r.status == "active",
        where: a.kind == "credit",
        group_by: app.lot_id,
        select: {app.lot_id, type(sum(a.amount_cents), :integer)}
      )
      |> Repo.all()
      |> Map.new()

    from(l in CreditLot, where: l.unrecovered_clawback_cents > 0, select: l)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, Map.get(applied_active, lot.id, 0))
    end)
  end

  defp lot_response(%CreditLot{} = lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => lot.expires_on
    }
  end
end
