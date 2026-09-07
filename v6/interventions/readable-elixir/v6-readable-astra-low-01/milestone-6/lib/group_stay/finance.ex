defmodule GroupStay.Finance do
  @moduledoc """
  Durable inception balances and a daily movement journal, committed with partner
  operations. Cash differences retain the allocation's current property, including
  reversals of settled history. Credit settlement records its economic reason.

  Available credit also schedules expiry on the day after its lot expires. Changes
  to availability adjust that scheduled entry, never before the posting date of
  the change. This keeps expiry independent of reads and operation arrival order;
  applied credit remains a liability with no scheduled expiry until it returns.
  """
  import Ecto.Query
  alias GroupStay.{Repo, CashAllocation, Credits}
  alias GroupStay.Credits.Lot
  alias GroupStay.Reservations.Group
  alias GroupStay.Finance.Entry

  @cash ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_reporting_date"}
    end
  end

  def parse_date(_), do: {:error, "invalid_reporting_date"}

  defp starts_on do
    case Repo.one(from r in "finance_reporting", select: r.starts_on) do
      nil -> nil
      value -> Date.from_iso8601!(value)
    end
  end

  def start(value) do
    with {:ok, date} <- parse_date(value) do
      if starts_on() do
        {:error, "reporting_already_started"}
      else
        Repo.insert_all("finance_reporting", [%{id: 1, starts_on: Date.to_iso8601(date)}])

        for {{property, "held"}, amount} <- cash_snapshot() do
          post(date, property, "opening", amount)
        end

        post(date, nil, "opening", Credits.liability(date))

        for lot <- Repo.all(Lot), Date.compare(lot.expires_on, date) != :lt do
          post(Date.add(lot.expires_on, 1), nil, "expired_cents", lot.remaining_cents)
        end

        {:ok, %{starts_on: date}}
      end
    end
  end

  @doc "Captures only when reporting is enabled, inside the operation's transaction."
  def before_operation do
    if date = starts_on() do
      %{starts_on: date, cash: cash_snapshot()}
    end
  end

  def after_operation(nil, _operation), do: :ok

  def after_operation(before, operation) do
    date = posting_date(before.starts_on, Date.from_iso8601!(operation["occurred_on"]))
    after_cash = cash_snapshot()
    properties = Map.keys(before.cash) ++ Map.keys(after_cash)

    properties
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.each(fn property ->
      delta = fn kind ->
        Map.get(after_cash, {property, kind}, 0) - Map.get(before.cash, {property, kind}, 0)
      end

      if operation["type"] != "transfer_deposit" do
        dispositions = ~w(refunded retained converted_to_credit reduced charged_back)
        received = delta.("held") + Enum.sum(Enum.map(dispositions, delta))
        post(date, property, "received_cents", received)
        for kind <- dispositions, do: post(date, property, kind <> "_cents", delta.(kind))
      end
    end)
  end

  @doc "Records both sides of a cash transfer, including transfers within one property."
  def cash_transfer(source, destination, amount, occurred_on) do
    if start = starts_on() do
      date = posting_date(start, occurred_on)
      post(date, source.property_id, "transferred_out_cents", amount)
      post(date, destination.property_id, "transferred_in_cents", amount)
    end

    :ok
  end

  @doc "Records a credit liability change at the operation's clamped posting date."
  def credit_movement(kind, amount, occurred_on) do
    if start = starts_on(), do: post(posting_date(start, occurred_on), nil, kind, amount)
    :ok
  end

  @doc "Adjusts scheduled expiry when credit enters or leaves a lot's available balance."
  def credit_availability_change(amount, expires_on, occurred_on) do
    if start = starts_on() do
      date = posting_date(start, occurred_on)
      post(posting_date(date, Date.add(expires_on, 1)), nil, "expired_cents", amount)
    end

    :ok
  end

  @doc "Revoking already expired, unused credit cannot reduce liability a second time."
  def credit_revoked(amount, expires_on, occurred_on) do
    if start = starts_on() do
      date = posting_date(start, occurred_on)

      if Date.compare(expires_on, date) != :lt do
        post(date, nil, "revoked_cents", amount)
        post(Date.add(expires_on, 1), nil, "expired_cents", -amount)
      end
    end

    :ok
  end

  def daily_report(value) do
    with {:ok, date} <- parse_date(value) do
      {:ok, result} = Repo.transaction(fn -> report(date) end)
      result
    end
  end

  defp report(date) do
    start = starts_on()

    if is_nil(start) or Date.compare(date, start) == :lt do
      {:error, "report_not_available"}
    else
      entries = Repo.all(from e in Entry, where: e.posted_on <= ^date)
      {credit, cash} = Enum.split_with(entries, &is_nil(&1.property_id))

      cash =
        cash
        |> Enum.group_by(& &1.property_id)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {property, entries} ->
          balances(entries, date, @cash, "held") |> Map.put(:property_id, property)
        end)
        |> Enum.reject(fn row ->
          row["opening_held_cents"] == 0 and row["closing_held_cents"] == 0 and
            Enum.all?(row.movements, fn {_, amount} -> amount == 0 end)
        end)

      {:ok,
       %{
         date: date,
         status: "open",
         cash: cash,
         credit: balances(credit, date, @credit, "liability")
       }}
    end
  end

  defp balances(entries, date, columns, balance) do
    {today, earlier} =
      Enum.split_with(entries, &(&1.posted_on == date and &1.classification != "opening"))

    opening = Enum.sum(Enum.map(earlier, &effect/1))

    movements =
      Map.new(columns, fn kind ->
        {kind,
         today
         |> Enum.filter(&(&1.classification == kind))
         |> Enum.map(& &1.amount_cents)
         |> Enum.sum()}
      end)

    %{
      "opening_#{balance}_cents" => opening,
      "closing_#{balance}_cents" => opening + Enum.sum(Enum.map(today, &effect/1)),
      :movements => movements
    }
  end

  defp effect(entry) do
    if entry.classification in ~w(opening received_cents transferred_in_cents issued_cents),
      do: entry.amount_cents,
      else: -entry.amount_cents
  end

  defp cash_snapshot do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.group_id == a.group_id,
        group_by: [g.property_id, a.disposition],
        select: {{g.property_id, a.disposition}, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp posting_date(left, right), do: if(Date.compare(left, right) == :gt, do: left, else: right)
  defp post(_date, _property, _kind, 0), do: :ok

  defp post(date, property, kind, amount) do
    Repo.insert!(%Entry{
      posted_on: date,
      property_id: property,
      classification: kind,
      amount_cents: amount
    })
  end
end
