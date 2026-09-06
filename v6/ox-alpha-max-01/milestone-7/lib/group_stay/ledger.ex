defmodule GroupStay.Ledger do
  @moduledoc """
  Records the accounting facts reported to GroupStay and totals the cash
  position. Payment providers perform the actual movement of money.

  Recorded cash for one payment equals its held, refunded, retained,
  converted, reduced, and charged-back dispositions together. Settlement
  and correction entries name the payment they dispose of through
  `operation_id`; charging a payment back reclassifies its settled
  portions to charged-back cash.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups.Funding
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  @doc """
  Records cash applied to a group's outstanding deposit.
  """
  def record_payment(group_id, amount_cents, opts \\ []) do
    insert_entry("payment", group_id, amount_cents, Keyword.get(opts, :operation_id))
  end

  @doc """
  Records cash returned to the partner on cancellation.
  """
  def record_refund(group_id, amount_cents, opts \\ []) do
    insert_entry("refund", group_id, amount_cents, Keyword.get(opts, :operation_id))
  end

  @doc """
  Records cash kept by the hotel on a non-refundable cancellation.
  """
  def record_retention(group_id, amount_cents, opts \\ []) do
    insert_entry("retention", group_id, amount_cents, Keyword.get(opts, :operation_id))
  end

  @doc """
  Records cash neither refunded nor retained because the guest chose hotel
  credit: it moves from held cash to converted credit.
  """
  def record_credit_conversion(group_id, amount_cents, opts \\ []) do
    insert_entry("credit_conversion", group_id, amount_cents, Keyword.get(opts, :operation_id))
  end

  @doc """
  Records a provider correction shrinking one recorded payment's held cash.
  """
  def record_reduction(group_id, payment_operation_id, amount_cents) do
    insert_entry("reduction", group_id, amount_cents, payment_operation_id)
  end

  @doc """
  Records cash reversed by a chargeback against one payment.
  """
  def record_chargeback(group_id, payment_operation_id, amount_cents) do
    insert_entry("chargeback", group_id, amount_cents, payment_operation_id)
  end

  @doc """
  Moves every refunded, retained, or converted portion of one payment's
  cash to charged-back classification. The historical refund or retention
  is not reversed or reissued — only the ledger classification changes.
  """
  def reclassify_settled_to_chargeback(payment_operation_id) do
    {_, _} =
      from(e in Entry,
        where:
          e.operation_id == ^payment_operation_id and
            e.kind in ~w(refund retention credit_conversion)
      )
      |> Repo.update_all(set: [kind: "chargeback"])

    :ok
  end

  @doc """
  The global cash and credit position as of `as_of`.

  `cash_held_cents` is cash currently allocated to active rooms' deposits.
  `cash_reduced_cents` and `cash_charged_back_cents` are cumulative
  provider corrections. `credit_shortfall_cents` is the current sum of lot
  shortfalls. Unpaid deposit requirements are not cash and never appear in
  the cash totals.
  """
  def global_totals(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: held_cash_total(),
      cash_refunded_cents: total("refund"),
      cash_retained_cents: total("retention"),
      cash_converted_to_credit_cents: total("credit_conversion"),
      cash_reduced_cents: total("reduction"),
      cash_charged_back_cents: total("chargeback"),
      credit_liability_cents: Credit.liability_cents(as_of),
      credit_shortfall_cents: Credit.shortfall_cents()
    }
  end

  defp insert_entry(kind, group_id, amount_cents, operation_id) do
    %Entry{}
    |> Entry.changeset(%{
      group_id: group_id,
      kind: kind,
      amount_cents: amount_cents,
      operation_id: operation_id
    })
    |> Repo.insert()
  end

  defp held_cash_total do
    from(f in Funding,
      join: g in Group,
      on: g.id == f.group_id,
      where: f.kind == "cash" and g.status == "active",
      select: coalesce(sum(f.amount_cents), 0)
    )
    |> Repo.one()
  end

  defp total(kind) do
    from(e in Entry,
      where: e.kind == ^kind,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.one()
  end
end
