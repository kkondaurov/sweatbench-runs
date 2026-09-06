defmodule GroupStay.Finance do
  @moduledoc """
  Queries over the cash and hotel credit recorded against group reservations.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Repo

  @doc """
  Service-wide cash totals split by where the cash currently sits.

  `credit_liability_cents` reports expiry as of `on` and includes both
  available credit and credit currently applied to active groups.
  `credit_shortfall_cents` is the sum of current lot shortfalls: unrecovered
  clawbacks limited to that lot's credit still applied to active groups.
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
      "cash_converted_to_credit_cents" => 0,
      "cash_reduced_cents" => 0,
      "cash_charged_back_cents" => 0
    }

    cash
    |> Repo.all()
    |> Enum.map(fn {kind, sum} -> {"cash_#{kind}_cents", sum || 0} end)
    |> Enum.into(defaults)
    |> Map.put("credit_liability_cents", credit_liability(on))
    |> Map.put("credit_shortfall_cents", credit_shortfall())
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

    applied = applied_credit_query() |> Repo.one() || 0

    available + applied
  end

  @doc """
  The sum of current lot shortfalls: for each lot with an unrecovered clawback,
  the lesser of that clawback and the lot's credit still applied to active
  groups.
  """
  def credit_shortfall do
    shortfalled =
      from(l in CreditLot,
        where: l.unrecovered_clawback_cents > 0,
        select: {l.id, l.unrecovered_clawback_cents}
      )
      |> Repo.all()

    applied = applied_credit_by_lot()

    Enum.reduce(shortfalled, 0, fn {lot_id, unrecovered}, acc ->
      acc + min(unrecovered, Map.get(applied, lot_id, 0))
    end)
  end

  @doc """
  Cash currently held on the group's active rooms, in cents.
  """
  def cash_held(group_id) do
    held_on_active_rooms(group_id, "cash")
  end

  @doc """
  Hotel credit currently applied to the group's active rooms, in cents.
  """
  def credit_applied(group_id) do
    held_on_active_rooms(group_id, "credit")
  end

  @doc """
  The cash dispositions currently recorded for one payment, keyed by movement
  kind. Legacy funding has no payment identity and never appears here.
  """
  def payment_dispositions(payment_operation_id) do
    from(m in CashMovement,
      where: m.operation_id == ^payment_operation_id,
      group_by: m.kind,
      select: {m.kind, coalesce(sum(m.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  One payment's cash currently held per active group, as
  `%{"group_id" => amount_cents}` maps ordered by group id. Groups without
  held cash are omitted.
  """
  def held_cash_by_group(payment_operation_id) do
    from(a in RoomAllocation,
      join: g in Group,
      on: g.id == a.group_id,
      where:
        a.funding_type == "cash" and a.source_operation_id == ^payment_operation_id and
          g.status == "active",
      group_by: g.group_id,
      select: {g.group_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Repo.all()
    |> Enum.filter(fn {_group_id, amount_cents} -> amount_cents > 0 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp held_on_active_rooms(group_id, funding_type) do
    from(al in RoomAllocation,
      join: room in "group_rooms",
      on: room.id == al.room_id,
      where:
        al.group_id == ^group_id and al.funding_type == ^funding_type and room.status == "active",
      select: coalesce(sum(al.amount_cents), 0)
    )
    |> Repo.one() || 0
  end

  defp applied_credit_query do
    from(a in RoomAllocation,
      join: g in Group,
      on: g.id == a.group_id,
      where: a.funding_type == "credit" and g.status == "active",
      select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp applied_credit_by_lot do
    from(a in RoomAllocation,
      join: g in Group,
      on: g.id == a.group_id,
      where: a.funding_type == "credit" and g.status == "active",
      group_by: a.credit_lot_id,
      select: {a.credit_lot_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
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
