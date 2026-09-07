defmodule GroupStay.Finance do
  @moduledoc """
  Starts durable finance reporting and reads open daily reports.

  Inception captures committed balances rather than replaying submission dates.
  Thereafter the journal explains changes by posting date. Reads use a single
  database snapshot and never expire credit or otherwise mutate domain state.
  """
  import Ecto.Query
  alias GroupStay.{Ledger, Repo}
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.{Entry, Journal, Reporting}
  alias GroupStay.Reservations.{Booking, Group}

  @cash_movements ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents
                     retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_movements ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)
  @cash_inflows ~w(received_cents transferred_in_cents)

  def start(operation) do
    with {:ok, starts_on} <- reporting_date(operation["starts_on"]) do
      if Repo.get(Reporting, 1) do
        {:error, "reporting_already_started"}
      else
        Repo.insert!(%Reporting{id: 1, starts_on: starts_on})
        context = %{operation_id: operation["operation_id"], posted_on: starts_on}

        Repo.all(
          from g in Group,
            group_by: g.property_id,
            select: {g.property_id, sum(g.deposit_paid_cents - g.credit_paid_cents)}
        )
        |> Enum.each(fn {property, held} -> Journal.entry(context, property, :opening, held) end)

        Journal.credit(context, :opening, Ledger.totals(starts_on).credit_liability_cents)

        Repo.all(from l in Lot, where: l.expires_on >= ^starts_on and l.remaining_cents > 0)
        |> Enum.each(&Journal.available_changed(context, &1.expires_on, &1.remaining_cents))

        {:ok, %{starts_on: starts_on}}
      end
    end
  end

  def daily_report(value) do
    with {:ok, date} <- reporting_date(value) do
      {:ok, result} = Repo.transaction(fn -> read_report(date) end)
      result
    end
  end

  defp reporting_date(value) do
    case Booking.date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  defp read_report(date) do
    case Repo.get(Reporting, 1) do
      nil ->
        {:error, "report_not_available"}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt,
          do: {:error, "report_not_available"},
          else: {:ok, build_report(date)}
    end
  end

  defp build_report(date) do
    entries =
      Repo.all(
        from e in Entry,
          where: e.posted_on <= ^date,
          group_by: [e.property_id, e.kind, fragment("? < ?", e.posted_on, ^date)],
          select:
            {e.property_id, e.kind, fragment("? < ?", e.posted_on, ^date), sum(e.amount_cents)}
      )
      |> Enum.group_by(&elem(&1, 0))

    cash =
      entries
      |> Map.delete(nil)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {property, facts} ->
        {opening, movements, closing} = balances(facts, @cash_movements, @cash_inflows)

        %{
          property_id: property,
          opening_held_cents: opening,
          movements: movements,
          closing_held_cents: closing
        }
      end)
      |> Enum.reject(fn row ->
        row.opening_held_cents == 0 and row.closing_held_cents == 0 and
          Enum.all?(row.movements, fn {_, amount} -> amount == 0 end)
      end)

    {opening, movements, closing} =
      balances(Map.get(entries, nil, []), @credit_movements, ["issued_cents"])

    %{
      date: date,
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening,
        movements: movements,
        closing_liability_cents: closing
      }
    }
  end

  defp balances(facts, kinds, inflows) do
    {opening, movements} =
      Enum.reduce(facts, {0, Map.new(kinds, &{&1, 0})}, fn
        {_, "opening", _, amount}, {opening, movements} ->
          {opening + amount, movements}

        {_, kind, earlier, amount}, {opening, movements} ->
          if earlier in [true, 1] do
            {opening + signed(kind, amount, inflows), movements}
          else
            {opening, Map.update!(movements, kind, &(&1 + amount))}
          end
      end)

    closing =
      Enum.reduce(movements, opening, fn {kind, amount}, total ->
        total + signed(kind, amount, inflows)
      end)

    {opening, movements, closing}
  end

  defp signed(kind, amount, inflows), do: if(kind in inflows, do: amount, else: -amount)
end
