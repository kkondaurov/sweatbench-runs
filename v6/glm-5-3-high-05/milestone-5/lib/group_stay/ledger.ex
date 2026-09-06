defmodule GroupStay.Ledger do
  @moduledoc """
  The cash ledger: accounting facts reported by the partner gateway about
  payments, refunds, retentions, cash converted into hotel credit, provider
  corrections (reductions), and chargebacks.

  Disposition entries (refund, retention, conversion, reduction, chargeback)
  attribute themselves to the cash-payment entry they settle through
  `payment_entry_id` whenever the settled cash has a durable payment
  identity; funding from before durable operation records existed settles
  as unattributed entries. A chargeback reclassifies a payment's refunded,
  retained, and converted entries as charged-back cash: the ledger
  classification changes, but the historical refund or retention is not
  reversed or reissued.
  """

  alias GroupStay.Accounting
  alias GroupStay.Credit
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  import Ecto.Query

  @payment "cash_payment"
  @refund "refund"
  @retention "retention"
  @conversion "cash_converted_to_credit"
  @reduction "cash_reduction"
  @chargeback "cash_chargeback"

  ## Recording

  @doc "Records cash applied to a group's deposit, attributed to its operation."
  def record_payment!(group_pk, amount_cents, occurred_on, operation_key \\ nil) do
    record!(group_pk, @payment, amount_cents, occurred_on, operation_key, nil)
  end

  @doc "Records cash refunded on cancellation."
  def record_refund!(group_pk, amount_cents, occurred_on, payment_entry_pk \\ nil) do
    record!(group_pk, @refund, amount_cents, occurred_on, nil, payment_entry_pk)
  end

  @doc "Records cash retained on cancellation."
  def record_retention!(group_pk, amount_cents, occurred_on, payment_entry_pk \\ nil) do
    record!(group_pk, @retention, amount_cents, occurred_on, nil, payment_entry_pk)
  end

  @doc "Records cash converted into hotel credit on cancellation."
  def record_conversion!(group_pk, amount_cents, occurred_on, payment_entry_pk \\ nil) do
    record!(group_pk, @conversion, amount_cents, occurred_on, nil, payment_entry_pk)
  end

  @doc "Records a provider correction reducing previously recorded cash."
  def record_reduction!(%Entry{} = payment_entry, amount_cents, occurred_on) do
    record!(payment_entry.group_id, @reduction, amount_cents, occurred_on, nil, payment_entry.id)
  end

  @doc "Records cash reversed by a chargeback."
  def record_chargeback!(%Entry{} = payment_entry, amount_cents, occurred_on) do
    record!(payment_entry.group_id, @chargeback, amount_cents, occurred_on, nil, payment_entry.id)
  end

  defp record!(group_pk, kind, amount_cents, occurred_on, operation_key, payment_entry_pk) do
    %Entry{}
    |> Entry.changeset(%{
      group_id: group_pk,
      kind: kind,
      amount_cents: amount_cents,
      occurred_on: occurred_on,
      operation_key: operation_key,
      payment_entry_id: payment_entry_pk
    })
    |> Repo.insert!()
  end

  ## Payment lookups

  @doc "The cash-payment entry created by an applied payment operation."
  def payment_entry_by_operation_key(operation_key) do
    Repo.get_by(Entry, operation_key: operation_key, kind: @payment)
  end

  @doc "One disposition kind's total for a payment, such as refunds or reductions."
  def disposition_cents(payment_entry_pk, kind) do
    from(e in Entry,
      where: e.payment_entry_id == ^payment_entry_pk and e.kind == ^kind,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.one()
  end

  @doc """
  Reclassifies a payment's refunded, retained, and converted entries as
  charged-back cash. The ledger classification changes; the historical refund
  or retention is not reversed or reissued.
  """
  def reclassify_payment_dispositions!(payment_entry_pk) do
    from(e in Entry,
      where:
        e.payment_entry_id == ^payment_entry_pk and
          e.kind in ^[@refund, @retention, @conversion]
    )
    |> Repo.update_all(
      set: [kind: @chargeback, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    :ok
  end

  ## Totals

  @doc """
  Finance totals, evaluating credit expiry as of `as_of` (the current UTC
  date by default):

    - `cash_held_cents`: cash currently applied to active reservations;
    - `cash_refunded_cents`: cash refunded on cancellation;
    - `cash_retained_cents`: cash retained on cancellation;
    - `cash_converted_to_credit_cents`: cash moved into hotel credit;
    - `cash_reduced_cents`: cash removed by provider corrections;
    - `cash_charged_back_cents`: cash reversed by chargebacks;
    - `credit_liability_cents`: available credit plus credit applied to
      active groups;
    - `credit_shortfall_cents`: credit entitlement clawed back that could not
      be recovered from current lot balances.

  Unpaid deposit requirements are not cash and never appear in these totals.
  Recorded cash equals held cash plus refunded, retained, converted, reduced,
  and charged-back cash.
  """
  def totals(as_of \\ Date.utc_today()) do
    %{
      "cash_held_cents" => Accounting.held_cash_cents(),
      "cash_refunded_cents" => sum_entries(kind_query(@refund)),
      "cash_retained_cents" => sum_entries(kind_query(@retention)),
      "cash_converted_to_credit_cents" => sum_entries(kind_query(@conversion)),
      "cash_reduced_cents" => sum_entries(kind_query(@reduction)),
      "cash_charged_back_cents" => sum_entries(kind_query(@chargeback)),
      "credit_liability_cents" => Credit.liability_cents(as_of),
      "credit_shortfall_cents" => Credit.shortfall_cents()
    }
  end

  defp kind_query(kind) do
    from(e in Entry, where: e.kind == ^kind)
  end

  defp sum_entries(query) do
    Repo.aggregate(query, :sum, :amount_cents) || 0
  end
end
