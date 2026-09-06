defmodule GroupStay.Ledger do
  @moduledoc """
  The cash ledger: accounting facts reported by the partner gateway about
  payments, refunds, retentions, and cash converted into hotel credit.
  """

  alias GroupStay.Credit
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  import Ecto.Query

  @payment "cash_payment"
  @refund "refund"
  @retention "retention"
  @conversion "cash_converted_to_credit"

  @doc "Cash applied to a group's deposit so far."
  def paid_cents(group_pk) do
    from(e in Entry,
      where: e.group_id == ^group_pk and e.kind == ^@payment,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.one()
  end

  @doc "Records cash applied to a group's deposit."
  def record_payment!(group_pk, amount_cents, occurred_on) do
    record!(group_pk, @payment, amount_cents, occurred_on)
  end

  @doc "Records cash refunded on cancellation."
  def record_refund!(group_pk, amount_cents, occurred_on) do
    record!(group_pk, @refund, amount_cents, occurred_on)
  end

  @doc "Records cash retained on cancellation."
  def record_retention!(group_pk, amount_cents, occurred_on) do
    record!(group_pk, @retention, amount_cents, occurred_on)
  end

  @doc "Records cash converted into hotel credit on cancellation."
  def record_conversion!(group_pk, amount_cents, occurred_on) do
    record!(group_pk, @conversion, amount_cents, occurred_on)
  end

  defp record!(group_pk, kind, amount_cents, occurred_on) do
    %Entry{}
    |> Entry.changeset(%{
      group_id: group_pk,
      kind: kind,
      amount_cents: amount_cents,
      occurred_on: occurred_on
    })
    |> Repo.insert!()
  end

  @doc """
  Finance totals, evaluating credit expiry as of `as_of` (the current UTC date
  by default):

    - `cash_held_cents`: cash currently applied to active reservations;
    - `cash_refunded_cents`: cash refunded on cancellation;
    - `cash_retained_cents`: cash retained on cancellation;
    - `cash_converted_to_credit_cents`: cash moved into hotel credit;
    - `credit_liability_cents`: available credit plus credit applied to
      active groups.

  Unpaid deposit requirements are not cash and never appear in these totals.
  """
  def totals(as_of \\ Date.utc_today()) do
    %{
      "cash_held_cents" => sum_entries(join_active(@payment)),
      "cash_refunded_cents" => sum_entries(kind_query(@refund)),
      "cash_retained_cents" => sum_entries(kind_query(@retention)),
      "cash_converted_to_credit_cents" => sum_entries(kind_query(@conversion)),
      "credit_liability_cents" => Credit.liability_cents(as_of)
    }
  end

  defp kind_query(kind) do
    from(e in Entry, where: e.kind == ^kind)
  end

  defp join_active(kind) do
    from(e in Entry,
      join: g in assoc(e, :group),
      where: e.kind == ^kind and g.status == "active"
    )
  end

  defp sum_entries(query) do
    Repo.aggregate(query, :sum, :amount_cents) || 0
  end
end
