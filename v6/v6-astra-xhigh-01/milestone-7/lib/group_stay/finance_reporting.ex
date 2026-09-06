defmodule GroupStay.FinanceReporting do
  @moduledoc """
  An immutable opening position and signed finance entries, committed with partner
  operations. Report reads only fold entries in a database snapshot.

  Available credit carries a scheduled expiry entry. Drawing from or returning to
  an unexpired lot adjusts that entry, so applied credit never expires. Changes
  involving already expired credit are recognized on the operation's posting date.
  This also works for late submissions without advancing a mutable reporting clock.

  A close advances a durable cutoff under the operation's write lock. Every new
  entry is dated after that cutoff, including corrections to scheduled expiry.
  Existing entries never move, so closed reports need no per-day snapshots.
  """
  import Ecto.Query
  import GroupStay.Operations.Rejection, only: [reject: 1]
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.FinanceReporting.{Entry, Inception}
  alias GroupStay.Reservations.{CreditLot, Group}

  @cash_in ~w(received_cents transferred_in_cents)
  @cash_out ~w(transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_out ~w(expired_cents consumed_cents revoked_cents absorbed_cents)

  def parse_date(value) when is_binary(value), do: Reservations.report_date(value)
  def parse_date(_value), do: {:error, :invalid_date}

  def start(operation) do
    starts_on =
      case parse_date(operation["starts_on"]) do
        {:ok, date} -> date
        _ -> reject("invalid_reporting_date")
      end

    if Repo.get(Inception, 1), do: reject("reporting_already_started")
    Repo.insert!(%Inception{id: 1, starts_on: starts_on})
    posting = %{operation_id: operation["operation_id"], date: starts_on, late_adjustment: false}

    # Keep individual amounts as rows; a company's total can exceed SQLite's
    # integer range even though every group's monetary fields are representable.
    Repo.stream(Group)
    |> Enum.each(fn group ->
      cash(
        posting,
        group,
        :opening_held_cents,
        group.deposit_paid_cents - group.credit_paid_cents
      )

      credit(posting, :opening_liability_cents, group.credit_paid_cents)
    end)

    Repo.stream(from l in CreditLot, where: l.expires_on >= ^starts_on)
    |> Enum.each(fn lot ->
      credit(posting, :opening_liability_cents, lot.remaining_cents)
      available_change(posting, lot, lot.remaining_cents)
    end)

    starts_on
  end

  def close(operation) do
    period_end_on =
      case parse_date(operation["period_end_on"]) do
        {:ok, date} -> date
        _ -> reject("invalid_period")
      end

    inception = Repo.get(Inception, 1) || reject("invalid_period")

    if Date.compare(period_end_on, inception.starts_on) == :lt or
         (inception.closed_through_on != nil and
            Date.compare(period_end_on, inception.closed_through_on) != :gt),
       do: reject("invalid_period")

    inception
    |> Ecto.Changeset.change(closed_through_on: period_end_on)
    |> Repo.update!()

    period_end_on
  end

  def posting(operation_id, occurred_on) do
    case Repo.get(Inception, 1) do
      nil ->
        nil

      inception ->
        ordinary_date = max_date(occurred_on, inception.starts_on)

        date =
          if inception.closed_through_on,
            do: max_date(ordinary_date, Date.add(inception.closed_through_on, 1)),
            else: ordinary_date

        %{
          operation_id: operation_id,
          date: date,
          late_adjustment: Date.compare(date, ordinary_date) == :gt
        }
    end
  end

  def cash(nil, _group, _category, _amount), do: :ok
  def cash(_posting, _group, _category, 0), do: :ok

  def cash(posting, %Group{} = group, category, amount),
    do: insert(posting, group.property_id, category, amount)

  def cash(posting, group_id, category, amount),
    do: cash(posting, Repo.get!(Group, group_id), category, amount)

  def credit(posting, category, amount), do: insert(posting, nil, category, amount)

  # A positive change becomes an expiry outflow, either at natural expiry or now
  # if it is already expired at posting. A negative change cancels that outflow.
  def available_change(nil, _lot, _amount), do: :ok
  def available_change(_posting, _lot, 0), do: :ok

  def available_change(posting, lot, amount) do
    expiry = Date.add(lot.expires_on, 1)

    if expiry.year <= 9999 do
      # Future natural expiry keeps its date even if the originating operation
      # was late. Only an expiry correction pushed past its date by the cutoff
      # belongs in late adjustments.
      scheduled = %{
        posting
        | date: max_date(posting.date, expiry),
          late_adjustment: posting.late_adjustment and Date.compare(expiry, posting.date) == :lt
      }

      credit(scheduled, :expired_cents, amount)
    end
  end

  def revoke(nil, _lot, _amount), do: :ok

  def revoke(posting, lot, amount) do
    # An expired available balance is already outside liability. Revoking it has
    # no second liability effect and must not rewrite its historical expiry.
    if Date.compare(posting.date, lot.expires_on) != :gt do
      credit(posting, :revoked_cents, amount)
      available_change(posting, lot, -amount)
    end
  end

  def daily_report(date) do
    {:ok, result} = Repo.transaction(fn -> read_report(date) end)
    result
  end

  defp read_report(date) do
    case Repo.get(Inception, 1) do
      nil ->
        {:error, :report_not_available}

      inception ->
        if Date.compare(date, inception.starts_on) == :lt,
          do: {:error, :report_not_available},
          else: {:ok, build_report(date, inception.closed_through_on)}
    end
  end

  defp build_report(date, cutoff) do
    {cash, credit} =
      Repo.stream(from e in Entry, where: e.date <= ^date)
      |> Enum.reduce({%{}, balance(["issued_cents" | @credit_out])}, fn entry, {cash, credit} ->
        if entry.property_id do
          updated =
            cash
            |> Map.get(entry.property_id, balance(@cash_in ++ @cash_out))
            |> fold(entry, date, @cash_in, "opening_held_cents")

          {Map.put(cash, entry.property_id, updated), credit}
        else
          {cash, fold(credit, entry, date, ["issued_cents"], "opening_liability_cents")}
        end
      end)

    %{
      date: date,
      status: if(cutoff != nil and Date.compare(date, cutoff) != :gt, do: "closed", else: "open"),
      cash:
        cash
        |> Enum.sort_by(fn {property_id, _} -> property_id end)
        |> Enum.reject(fn {_, row} ->
          row.opening == 0 and row.closing == 0 and
            zero_movements?(row.movements) and zero_movements?(row.late_adjustments)
        end)
        |> Enum.map(fn {property_id, row} ->
          %{
            property_id: property_id,
            opening_held_cents: row.opening,
            movements: row.movements,
            closing_held_cents: row.closing
          }
        end),
      credit: %{
        opening_liability_cents: credit.opening,
        movements: credit.movements,
        closing_liability_cents: credit.closing
      },
      late_adjustments: %{
        cash:
          cash
          |> Enum.sort_by(fn {property_id, _} -> property_id end)
          |> Enum.reject(fn {_, row} -> zero_movements?(row.late_adjustments) end)
          |> Enum.map(fn {property_id, row} ->
            %{property_id: property_id, movements: row.late_adjustments}
          end),
        credit: credit.late_adjustments
      }
    }
  end

  defp balance(categories),
    do: %{
      opening: 0,
      closing: 0,
      movements: Map.new(categories, &{&1, 0}),
      late_adjustments: Map.new(categories, &{&1, 0})
    }

  defp zero_movements?(movements), do: Enum.all?(movements, fn {_, n} -> n == 0 end)

  defp fold(balance, entry, date, inflows, opening_category) do
    opening? = entry.category == opening_category

    delta =
      if opening? or entry.category in inflows, do: entry.amount_cents, else: -entry.amount_cents

    balance = %{balance | closing: balance.closing + delta}

    if opening? or Date.compare(entry.date, date) == :lt do
      %{balance | opening: balance.opening + delta}
    else
      column = if entry.late_adjustment, do: :late_adjustments, else: :movements
      update_in(balance, [column, entry.category], &(&1 + entry.amount_cents))
    end
  end

  defp insert(nil, _property, _category, _amount), do: :ok
  defp insert(_posting, _property, _category, 0), do: :ok

  # Closing the final API calendar date must not block domain operations or let
  # a five-digit SQLite date sort into a published four-digit reporting period.
  defp insert(%{date: %{year: year}}, _property, _category, _amount) when year > 9999,
    do: :ok

  defp insert(posting, property, category, amount) do
    Repo.insert!(%Entry{
      operation_id: posting.operation_id,
      date: posting.date,
      property_id: property,
      category: to_string(category),
      amount_cents: amount,
      late_adjustment: posting.late_adjustment
    })
  end

  defp max_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
