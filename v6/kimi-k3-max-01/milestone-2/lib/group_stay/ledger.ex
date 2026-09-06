defmodule GroupStay.Ledger do
  @moduledoc """
  The cash ledger for group deposits.

  GroupStay records the accounting facts reported by the partner; payment
  providers move the actual money. Cash received against active reservations
  is held until a cancellation moves it to refunded, retained, or converted
  to hotel credit. Deposit requirements that were never paid are not cash
  and never appear here.

  The credit liability is reported alongside the cash totals; it is
  evaluated as of a date because credit lots expire.
  """

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Groups.Group
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  @doc """
  The finance totals across all groups, with credit expiry evaluated as of
  the given date (the current UTC date by default).
  """
  def totals(as_of \\ Date.utc_today()) do
    sums =
      Entry
      |> group_by(:kind)
      |> select([entry], {entry.kind, sum(entry.amount_cents)})
      |> Repo.all()
      |> Map.new()

    received = Map.get(sums, "cash_received", 0)
    refunded = Map.get(sums, "cash_refunded", 0)
    retained = Map.get(sums, "cash_retained", 0)
    converted = Map.get(sums, "cash_converted_to_credit", 0)

    %{
      cash_held_cents: received - refunded - retained - converted,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: Credits.liability_cents(as_of)
    }
  end

  @doc """
  Records cash received against a group's deposit.
  """
  def record_cash_received!(%Group{} = group, amount_cents, %Date{} = occurred_on) do
    insert!(group, "cash_received", amount_cents, occurred_on)
  end

  @doc """
  Records held cash refunded by a cancellation. Zero amounts record nothing.
  """
  def record_cash_refunded!(%Group{}, amount_cents, %Date{}) when amount_cents <= 0, do: nil

  def record_cash_refunded!(%Group{} = group, amount_cents, %Date{} = occurred_on) do
    insert!(group, "cash_refunded", amount_cents, occurred_on)
  end

  @doc """
  Records held cash retained by a cancellation. Zero amounts record nothing.
  """
  def record_cash_retained!(%Group{}, amount_cents, %Date{}) when amount_cents <= 0, do: nil

  def record_cash_retained!(%Group{} = group, amount_cents, %Date{} = occurred_on) do
    insert!(group, "cash_retained", amount_cents, occurred_on)
  end

  @doc """
  Records held cash converted to hotel credit by a cancellation. Zero
  amounts record nothing.
  """
  def record_cash_converted_to_credit!(%Group{}, amount_cents, %Date{})
      when amount_cents <= 0,
      do: nil

  def record_cash_converted_to_credit!(%Group{} = group, amount_cents, %Date{} = occurred_on) do
    insert!(group, "cash_converted_to_credit", amount_cents, occurred_on)
  end

  defp insert!(%Group{} = group, kind, amount_cents, %Date{} = occurred_on) do
    %Entry{}
    |> Entry.changeset(%{
      group_id: group.id,
      kind: kind,
      amount_cents: amount_cents,
      occurred_on: occurred_on
    })
    |> Repo.insert!()
  end
end
