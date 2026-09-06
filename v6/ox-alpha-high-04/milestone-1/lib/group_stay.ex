defmodule GroupStay do
  @moduledoc """
  GroupStay keeps the contexts that define your domain and business logic.

  This context owns group reservations, their deposits, and the finance
  totals derived from them.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Room
  alias GroupStay.Finance.LedgerEntry
  alias GroupStay.Repo

  @flexible_deposit_percentage 20
  @flexible_cancellation_window_days 14

  def flexible_cancellation_window_days, do: @flexible_cancellation_window_days

  def get_group_with_rooms(group_id) do
    case Repo.get(group_query(), group_id) do
      nil -> {:error, :group_not_found}
      %Group{} = group -> {:ok, group}
    end
  end

  defp group_query do
    from(g in Group, preload: [rooms: ^room_order_query()])
  end

  defp room_order_query do
    from r in Room, order_by: [asc: r.position]
  end

  @doc """
  Rounds `amount * percentage / 100` to the nearest cent, with an exact
  half-cent rounded upward.
  """
  def round_percentage(amount_cents, percentage)
      when is_integer(amount_cents) and amount_cents >= 0 do
    div(amount_cents * percentage + 50, 100)
  end

  def flexible_room_deposit(lodging_cents) do
    round_percentage(lodging_cents, @flexible_deposit_percentage)
  end

  def advance_purchase_room_deposit(lodging_cents), do: lodging_cents

  @doc """
  Returns true when a flexible cancellation occurring on `occurred_on` is at
  least #{@flexible_cancellation_window_days} calendar days before arrival.
  """
  def flexible_refundable?(occurred_on, arrival_on) do
    Date.diff(arrival_on, occurred_on) >= @flexible_cancellation_window_days
  end

  def record_ledger_entry(attrs) do
    %LedgerEntry{}
    |> Ecto.Changeset.change(%{
      kind: attrs.kind,
      amount_cents: attrs.amount,
      group_id: attrs.group_id,
      occurred_on: attrs.occurred_on
    })
    |> Repo.insert!()
  end

  @doc """
  Cash currently applied to active reservations.

  Unpaid deposit requirements are not cash and never appear in these totals.
  """
  def finance_totals do
    cash_held =
      from(g in Group,
        where: g.status == "active",
        select: coalesce(sum(g.deposit_paid_cents), 0)
      )

    refunded =
      from(e in LedgerEntry,
        where: e.kind == "refunded",
        select: coalesce(sum(e.amount_cents), 0)
      )

    retained =
      from(e in LedgerEntry,
        where: e.kind == "retained",
        select: coalesce(sum(e.amount_cents), 0)
      )

    %{
      cash_held_cents: Repo.one(cash_held),
      cash_refunded_cents: Repo.one(refunded),
      cash_retained_cents: Repo.one(retained)
    }
  end
end
