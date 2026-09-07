defmodule GroupStay.FinanceReporting do
  @moduledoc """
  Persists the finance-reporting inception and classified daily movements.

  Reporting starts from a snapshot, so operations committed before inception
  never have to be reconstructed. Afterwards movements are recorded in the
  same transaction as their partner operation. Credit expiry is represented by
  a scheduled movement whose amount follows the portion of a lot that remains
  available (credit applied to a group has its expiry paused).
  """

  import Ecto.Query

  alias GroupStay.Deposits.{CreditAllocation, CreditLot, Group}
  alias GroupStay.FinanceReporting.{CashOpening, Movement, Setting}
  alias GroupStay.Repo

  @cash_classes ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_classes ~w(issued expired consumed revoked absorbed)

  @doc "Starts reporting with the financial state visible immediately before this call."
  def start(starts_on) do
    if Repo.get(Setting, 1) do
      {:error, :reporting_already_started}
    else
      cash_openings =
        Repo.all(
          from g in Group,
            where: g.status == "active" and g.cash_paid_cents != 0,
            group_by: g.property_id,
            select: {g.property_id, sum(g.cash_paid_cents)}
        )

      opening_credit = credit_liability(starts_on)

      with {:ok, setting} <-
             %Setting{}
             |> Setting.changeset(%{
               id: 1,
               starts_on: starts_on,
               opening_credit_liability_cents: opening_credit
             })
             |> Repo.insert(),
           :ok <- insert_cash_openings(setting, cash_openings),
           :ok <- schedule_existing_credit_expiries(starts_on) do
        :ok
      end
    end
  end

  @doc "Returns the immutable inception date, when reporting is enabled."
  def starts_on do
    case Repo.get(Setting, 1) do
      nil -> nil
      setting -> setting.starts_on
    end
  end

  @doc "The reporting date for an operation, or nil when reporting is disabled."
  def posting_on(occurred_on) do
    case starts_on() do
      nil -> nil
      starts_on -> if Date.before?(occurred_on, starts_on), do: starts_on, else: occurred_on
    end
  end

  @doc "Records a property cash classification using its API sign convention."
  def record_cash(nil, _property_id, _classification, _amount), do: :ok
  def record_cash(_posting_on, _property_id, _classification, 0), do: :ok

  def record_cash(posting_on, property_id, classification, amount)
      when classification in @cash_classes do
    insert_movement(%{
      posting_on: posting_on,
      property_id: property_id,
      classification: classification,
      amount_cents: amount,
      scheduled_expiry: false
    })
  end

  @doc "Records a company-wide credit-liability classification."
  def record_credit(nil, _classification, _amount), do: :ok
  def record_credit(_posting_on, _classification, 0), do: :ok

  def record_credit(posting_on, classification, amount) when classification in @credit_classes do
    insert_movement(%{
      posting_on: posting_on,
      classification: classification,
      amount_cents: amount,
      scheduled_expiry: false
    })
  end

  @doc "Creates the automatic expiry movement for a newly issued credit lot."
  def schedule_expiry(_lot, nil), do: :ok

  def schedule_expiry(lot, posting_on) do
    natural_expiry = Date.add(lot.expires_on, 1)
    expiry_on = if Date.before?(natural_expiry, posting_on), do: posting_on, else: natural_expiry
    upsert_scheduled_expiry(lot, lot.remaining_cents, expiry_on)
  end

  @doc "Changes the future expiry amount as credit becomes applied or available."
  def adjust_scheduled_expiry(_lot, nil, _delta), do: :ok
  def adjust_scheduled_expiry(_lot, _posting_on, 0), do: :ok

  def adjust_scheduled_expiry(lot, posting_on, delta) do
    movement = scheduled_expiry(lot.id)
    expiry_on = if movement, do: movement.posting_on, else: Date.add(lot.expires_on, 1)

    if Date.compare(posting_on, expiry_on) != :gt do
      current = if movement, do: movement.amount_cents, else: 0
      upsert_scheduled_expiry(lot, max(current + delta, 0), expiry_on)
    else
      :ok
    end
  end

  @doc "Builds an API-ready report without changing any persisted state."
  def daily_report(date) do
    case Repo.get(Setting, 1) do
      nil ->
        {:error, :report_not_available}

      %Setting{starts_on: starts_on} = setting ->
        if Date.before?(date, starts_on),
          do: {:error, :report_not_available},
          else: {:ok, render_report(setting, date)}
    end
  end

  defp render_report(setting, date) do
    cash_openings =
      Repo.all(from o in CashOpening, select: {o.property_id, o.opening_held_cents}) |> Map.new()

    cash_movements =
      Repo.all(
        from m in Movement,
          where: not is_nil(m.property_id) and m.posting_on <= ^date,
          group_by: [m.property_id, m.posting_on, m.classification],
          select: {m.property_id, m.posting_on, m.classification, sum(m.amount_cents)}
      )

    properties =
      (Map.keys(cash_openings) ++ Enum.map(cash_movements, &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(&cash_report(&1, date, cash_openings, cash_movements))
      |> Enum.reject(&empty_cash_report?/1)

    %{
      date: date,
      status: "open",
      cash: cash,
      credit: credit_report(setting, date)
    }
  end

  defp cash_report(property_id, date, openings, all_movements) do
    opening_seed = Map.get(openings, property_id, 0)
    property_movements = Enum.filter(all_movements, &(elem(&1, 0) == property_id))
    before = Enum.filter(property_movements, &Date.before?(elem(&1, 1), date))
    today = Enum.filter(property_movements, &(elem(&1, 1) == date))
    opening = opening_seed + cash_effect(before)

    movements =
      today
      |> Enum.map(fn {_property_id, _posting_on, classification, amount} ->
        {classification, amount}
      end)
      |> movement_totals(@cash_classes)

    %{
      property_id: property_id,
      opening_held_cents: opening,
      movements: movements,
      closing_held_cents: opening + cash_effect(today)
    }
  end

  defp credit_report(setting, date) do
    movements =
      Repo.all(
        from m in Movement,
          where: is_nil(m.property_id) and m.posting_on <= ^date,
          group_by: [m.posting_on, m.classification],
          select: {m.posting_on, m.classification, sum(m.amount_cents)}
      )

    before = Enum.filter(movements, &Date.before?(elem(&1, 0), date))
    today = Enum.filter(movements, &(elem(&1, 0) == date))
    opening = setting.opening_credit_liability_cents + credit_effect(before)

    %{
      opening_liability_cents: opening,
      movements:
        today
        |> Enum.map(fn {_posting_on, classification, amount} -> {classification, amount} end)
        |> movement_totals(@credit_classes),
      closing_liability_cents: opening + credit_effect(today)
    }
  end

  defp movement_totals(rows, classifications) do
    totals =
      Enum.reduce(rows, %{}, fn {classification, amount}, acc ->
        Map.update(acc, classification, amount || 0, &(&1 + (amount || 0)))
      end)

    Map.new(classifications, fn classification ->
      {String.to_atom(classification <> "_cents"), Map.get(totals, classification, 0)}
    end)
  end

  defp cash_effect(rows) do
    Enum.reduce(rows, 0, fn row, total ->
      classification = elem(row, 2)
      amount = elem(row, 3) || 0

      if classification in ~w(received transferred_in),
        do: total + amount,
        else: total - amount
    end)
  end

  defp credit_effect(rows) do
    Enum.reduce(rows, 0, fn {_, classification, amount}, total ->
      if classification == "issued", do: total + (amount || 0), else: total - (amount || 0)
    end)
  end

  defp empty_cash_report?(report) do
    report.opening_held_cents == 0 and report.closing_held_cents == 0 and
      Enum.all?(report.movements, fn {_key, amount} -> amount == 0 end)
  end

  defp credit_liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      ) || 0

    applied = Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0)) || 0
    available + applied
  end

  defp insert_cash_openings(setting, openings) do
    Enum.reduce_while(openings, :ok, fn {property_id, amount}, :ok ->
      result =
        %CashOpening{}
        |> CashOpening.changeset(%{
          reporting_setting_id: setting.id,
          property_id: property_id,
          opening_held_cents: amount
        })
        |> Repo.insert()

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp schedule_existing_credit_expiries(starts_on) do
    Repo.all(
      from l in CreditLot,
        where: l.remaining_cents > 0 and l.expires_on >= ^starts_on
    )
    |> Enum.reduce_while(:ok, fn lot, :ok ->
      case upsert_scheduled_expiry(lot, lot.remaining_cents, Date.add(lot.expires_on, 1)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp scheduled_expiry(lot_id) do
    Repo.one(
      from m in Movement,
        where: m.credit_lot_id == ^lot_id and m.scheduled_expiry == true
    )
  end

  defp upsert_scheduled_expiry(lot, amount, expiry_on) when amount >= 0 do
    attrs = %{
      posting_on: expiry_on,
      classification: "expired",
      amount_cents: amount,
      credit_lot_id: lot.id,
      scheduled_expiry: true
    }

    case scheduled_expiry(lot.id) do
      nil -> %Movement{} |> Movement.changeset(attrs) |> Repo.insert() |> ok_result()
      movement -> movement |> Movement.changeset(attrs) |> Repo.update() |> ok_result()
    end
  end

  defp insert_movement(attrs),
    do: %Movement{} |> Movement.changeset(attrs) |> Repo.insert() |> ok_result()

  defp ok_result({:ok, _}), do: :ok
  defp ok_result({:error, changeset}), do: {:error, changeset}
end
