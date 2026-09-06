defmodule GroupStay.Ledger do
  @moduledoc """
  Records the accounting facts reported to GroupStay and totals the cash
  position. Payment providers perform the actual movement of money.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  @kind_atoms ~w(payment refund retention credit_conversion)a

  @doc """
  Records cash applied to a group's outstanding deposit.
  """
  def record_payment(group_id, amount_cents) do
    insert_entry("payment", group_id, amount_cents)
  end

  @doc """
  Records cash returned to the partner on cancellation.
  """
  def record_refund(group_id, amount_cents) do
    insert_entry("refund", group_id, amount_cents)
  end

  @doc """
  Records cash kept by the hotel on a non-refundable cancellation.
  """
  def record_retention(group_id, amount_cents) do
    insert_entry("retention", group_id, amount_cents)
  end

  @doc """
  Records cash neither refunded nor retained because the guest chose hotel
  credit: it moves from held cash to converted credit.
  """
  def record_credit_conversion(group_id, amount_cents) do
    insert_entry("credit_conversion", group_id, amount_cents)
  end

  @doc """
  Cash sums recorded for one group, keyed by entry kind atom. Kinds without
  entries default to zero.
  """
  def sums_for_group(group_id) do
    from(e in Entry,
      where: e.group_id == ^group_id,
      group_by: e.kind,
      select: {e.kind, coalesce(sum(e.amount_cents), 0)}
    )
    |> Repo.all()
    |> Map.new()
    |> then(fn by_kind ->
      @kind_atoms
      |> Map.new(fn kind -> {kind, Map.get(by_kind, Atom.to_string(kind), 0)} end)
    end)
  end

  @doc """
  Cash currently applied to active reservations (`cash_held_cents`), the
  cash settled out of them by cancellations (refunded or retained), the cash
  converted into hotel credit, and the outstanding credit liability as of
  `as_of`. Unpaid deposit requirements are not cash and never appear in the
  cash totals.
  """
  def global_totals(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: total("payment", active_only: true),
      cash_refunded_cents: total("refund"),
      cash_retained_cents: total("retention"),
      cash_converted_to_credit_cents: total("credit_conversion"),
      credit_liability_cents: Credit.liability_cents(as_of)
    }
  end

  defp insert_entry(kind, group_id, amount_cents) do
    %Entry{}
    |> Entry.changeset(%{group_id: group_id, kind: kind, amount_cents: amount_cents})
    |> Repo.insert()
  end

  defp total(kind, opts \\ []) do
    query =
      from(e in Entry,
        where: e.kind == ^kind,
        select: coalesce(sum(e.amount_cents), 0)
      )

    query =
      if Keyword.get(opts, :active_only, false) do
        from(e in query, join: g in Group, on: g.id == e.group_id, where: g.status == "active")
      else
        query
      end

    Repo.one(query)
  end
end
