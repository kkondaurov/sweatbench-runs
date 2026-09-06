defmodule GroupStay.Credit do
  @moduledoc """
  Reads and accounts for hotel credit held by guests.

  Credit lives in lots created when a refundable cancellation chose hotel
  credit. A lot's remaining cents are its unapplied amount. Applying credit to
  an active group pauses a lot's expiry; a refundable cancellation restores
  applied amounts to their original lots.
  """

  alias GroupStay.Credit.CreditApplication
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  import Ecto.Query

  @doc """
  Returns the guest's available credit as of `on`: the unexpired, unapplied
  portions of their lots, ordered by expiry and then source operation id.
  Expired and exhausted lots are omitted.
  """
  @spec available(String.t(), Date.t()) :: map()
  def available(guest_id, on) do
    lots =
      CreditLot
      |> where([lot], lot.guest_id == ^guest_id)
      |> where([lot], lot.expires_on >= ^on)
      |> where([lot], lot.remaining_cents > 0)
      |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  @doc """
  Total hotel credit liability as of `on`: unexpired available credit plus
  credit currently applied to active groups, whose expiry is paused. Credit
  applied to active groups still counts even when covered by a current
  chargeback shortfall.
  """
  @spec liability(Date.t()) :: integer()
  def liability(on) do
    available =
      CreditLot
      |> where([lot], lot.expires_on >= ^on)
      |> select([lot], sum(lot.remaining_cents))
      |> Repo.one()

    applied =
      CreditApplication
      |> join(:inner, [app], g in Group, on: app.group_id == g.id and g.status == "active")
      |> select([app], sum(app.amount_cents))
      |> Repo.one()

    (available || 0) + (applied || 0)
  end

  @doc """
  The current total credit shortfall produced by chargeback clawbacks.

  For each lot, the shortfall is the lesser of its unrecovered clawback and
  credit from that lot still applied to active groups.
  """
  @spec shortfall() :: integer()
  def shortfall do
    CreditLot
    |> where([lot], lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, applied_cents(lot.id))
    end)
  end

  @doc """
  Credit from one lot currently applied to active groups.
  """
  @spec applied_cents(Ecto.UUID.t()) :: integer()
  def applied_cents(lot_id) do
    CreditApplication
    |> join(:inner, [app], g in Group, on: app.group_id == g.id and g.status == "active")
    |> where([app], app.lot_id == ^lot_id)
    |> select([app], sum(app.amount_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end
end
