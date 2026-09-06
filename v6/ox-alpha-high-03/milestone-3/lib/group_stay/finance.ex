defmodule GroupStay.Finance do
  @moduledoc """
  Queries over the cash and hotel credit recorded against group reservations.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditApplication
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Repo

  @doc """
  Cash currently held for an active reservation, in cents.
  """
  def cash_held(group_id) do
    query =
      from m in CashMovement,
        where: [group_id: ^group_id, kind: "held"],
        select: coalesce(sum(m.amount_cents), 0)

    Repo.one(query) || 0
  end

  @doc """
  Service-wide cash totals split by where the cash currently sits.

  `credit_liability_cents` reports expiry as of `on` and includes both
  available credit and credit currently applied to active groups.
  """
  def totals(on \\ Date.utc_today()) do
    cash =
      from m in CashMovement,
        group_by: m.kind,
        select: {m.kind, sum(m.amount_cents)}

    defaults = %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 0
    }

    cash_totals =
      cash
      |> Repo.all()
      |> Enum.map(fn {kind, sum} -> {"cash_#{kind}_cents", sum || 0} end)
      |> Enum.into(defaults)

    Map.put(cash_totals, "credit_liability_cents", credit_liability(on))
  end

  @doc """
  Hotel credit from lots currently applied to a group's deposit, in cents.
  """
  def credit_applied(group_id) do
    query =
      from a in CreditApplication,
        where: [group_id: ^group_id],
        select: coalesce(sum(a.amount_cents), 0)

    Repo.one(query) || 0
  end

  @doc """
  Hotel credit available to a guest in unexpired lots as of `on`, in cents.
  """
  def available_credit(guest_id, on) do
    guest_id |> unexpired_lots_query(on) |> available_sum_query() |> Repo.one() || 0
  end

  @doc """
  The guest's available credit lots as of `on`, ordered by expiry then source
  operation. Expired and exhausted lots are omitted.
  """
  def credit_lots(guest_id, on) do
    guest_id
    |> unexpired_lots_query(on)
    |> where([l], l.remaining_cents > 0)
    |> order_by([l], asc: l.expires_on, asc: l.source_operation_id)
    |> select([l], {l.source_operation_id, l.remaining_cents, l.expires_on})
    |> Repo.all()
  end

  @doc """
  The outstanding hotel-credit liability as of `on`: available credit plus
  credit currently applied to active groups.
  """
  def credit_liability(on) do
    available =
      from(l in CreditLot)
      |> unexpired_lots_filter(on)
      |> available_sum_query()
      |> Repo.one() || 0

    applied =
      from(a in CreditApplication,
        join: g in Group,
        on: g.id == a.group_id,
        where: g.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one() || 0

    available + applied
  end

  defp unexpired_lots_query(guest_id, on) do
    from(l in CreditLot, where: l.guest_id == ^guest_id) |> unexpired_lots_filter(on)
  end

  defp unexpired_lots_filter(query, on) do
    where(query, [l], l.expires_on > ^on)
  end

  defp available_sum_query(query) do
    select(query, [l], coalesce(sum(l.remaining_cents), 0))
  end
end
