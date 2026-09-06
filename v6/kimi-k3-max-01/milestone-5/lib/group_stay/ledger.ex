defmodule GroupStay.Ledger do
  @moduledoc """
  The cash ledger for group deposits.

  GroupStay records the accounting facts reported by the partner; payment
  providers move the actual money. Cash received against active reservations
  is held until a cancellation moves it to refunded, retained, or converted
  to hotel credit, or a provider correction moves it to reduced or
  charged-back cash. Recorded cash therefore equals held cash plus refunded,
  retained, converted, reduced, and charged-back cash. Deposit requirements
  that were never paid are not cash and never appear here.

  The credit liability and shortfall are reported alongside the cash totals;
  the liability is evaluated as of a date because credit lots expire, while
  the shortfall is a current property of the lots.
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
    reduced = Map.get(sums, "cash_reduced", 0)
    charged_back = Map.get(sums, "cash_charged_back", 0)

    %{
      cash_held_cents: received - refunded - retained - converted - reduced - charged_back,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      cash_reduced_cents: reduced,
      cash_charged_back_cents: charged_back,
      credit_liability_cents: Credits.liability_cents(as_of),
      credit_shortfall_cents: Credits.shortfall_cents()
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

  @doc """
  Reclassifies settled cash from one disposition kind to another by
  recording a compensating pair of entries (a negative amount in the source
  kind and a positive amount in the target kind), so recorded cash is
  unchanged. Zero amounts record nothing.
  """
  def reclassify_cash!(%Group{}, _from_kind, _to_kind, amount_cents, %Date{})
      when amount_cents <= 0,
      do: nil

  def reclassify_cash!(%Group{} = group, from_kind, to_kind, amount_cents, %Date{} = occurred_on) do
    insert!(group, from_kind, -amount_cents, occurred_on)
    insert!(group, to_kind, amount_cents, occurred_on)
  end

  @doc """
  Reclassifies held cash into a disposition kind. Held cash is tracked
  against recorded cash, so a single positive entry in the target kind moves
  it off the held total. Zero amounts record nothing.
  """
  def reclassify_held_cash!(%Group{}, _kind, amount_cents, %Date{})
      when amount_cents <= 0,
      do: nil

  def reclassify_held_cash!(%Group{} = group, kind, amount_cents, %Date{} = occurred_on) do
    insert!(group, kind, amount_cents, occurred_on)
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
