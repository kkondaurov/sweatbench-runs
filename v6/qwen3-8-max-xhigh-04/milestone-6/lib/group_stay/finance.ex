defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting.

  The first applied `start_finance_reporting` operation enables reporting and
  captures the opening position on `starts_on`: every property's held cash and
  the company-wide credit liability, evaluated as of `starts_on`, including
  every operation already committed regardless of its `occurred_on`.

  Every later applied operation records its finance effects as movements
  posted on the later of its `occurred_on` and `starts_on`. Movements commit
  with the operation's domain changes, so rejections leave no movement and
  retries never report one twice.

  Reports are read-only recomputations: reading them in any order, or reading
  one repeatedly, never changes a report or any domain state. Credit that
  expires without a partner operation is derived from the lots themselves, so
  later submissions can change earlier open reports.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.Start
  alias GroupStay.Funding.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  # Effect of one cash movement on held cash, per classification.
  @cash_signs %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  @cash_columns %{
    "received" => :received_cents,
    "transferred_in" => :transferred_in_cents,
    "transferred_out" => :transferred_out_cents,
    "refunded" => :refunded_cents,
    "retained" => :retained_cents,
    "converted_to_credit" => :converted_to_credit_cents,
    "reduced" => :reduced_cents,
    "charged_back" => :charged_back_cents
  }

  @credit_columns %{
    "issued" => :issued_cents,
    "expired" => :expired_cents,
    "consumed" => :consumed_cents,
    "revoked" => :revoked_cents,
    "absorbed" => :absorbed_cents
  }

  ## Starting

  @doc """
  Enables reporting on `starts_on` and captures the opening position.

  Returns `{:error, :reporting_already_started}` once reporting has started.
  """
  def start(starts_on) do
    if Repo.exists?(Start) do
      {:error, :reporting_already_started}
    else
      %Start{}
      |> Changeset.change(%{
        singleton: 1,
        starts_on: starts_on,
        opening_held_cents: opening_held_by_property(),
        opening_liability_cents: Credit.liability_cents(starts_on)
      })
      |> Changeset.unique_constraint(:singleton)
      |> Repo.insert()
      |> case do
        {:ok, start} ->
          {:ok, start}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :singleton) do
            {:error, :reporting_already_started}
          else
            raise "unexpected failure starting finance reporting"
          end
      end
    end
  end

  defp opening_held_by_property do
    Repo.all(
      from a in Allocation,
        join: g in Group,
        on: a.group_id == g.id,
        where: a.kind == "cash" and a.disposition == "held",
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp current_start do
    Repo.one(from s in Start, limit: 1)
  end

  ## Recording movements

  @doc """
  Records one cash movement on the property where the cash is held or
  settled. No-op before reporting has started or for a zero amount.
  """
  def record_cash(operation_id, occurred_on, property_id, classification, amount_cents) do
    if amount_cents == 0 do
      :ok
    else
      record("cash", operation_id, occurred_on, classification, amount_cents, %{
        property_id: property_id
      })
    end
  end

  @doc """
  Records one credit movement. No-op before reporting has started or for a
  zero amount. `applied` and `restored` movements are internal: they track a
  lot's remaining balance so natural expiry can be derived, and they are not
  report movements.
  """
  def record_credit(operation_id, occurred_on, classification, amount_cents, lot_id \\ nil) do
    if amount_cents == 0 do
      :ok
    else
      record("credit", operation_id, occurred_on, classification, amount_cents, %{
        credit_lot_id: lot_id
      })
    end
  end

  defp record(kind, operation_id, occurred_on, classification, amount_cents, fields) do
    case current_start() do
      nil ->
        :ok

      start ->
        posted_on =
          if Date.compare(occurred_on, start.starts_on) == :gt,
            do: occurred_on,
            else: start.starts_on

        Repo.insert!(%Movement{
          operation_id: operation_id,
          posted_on: posted_on,
          kind: kind,
          classification: classification,
          amount_cents: amount_cents,
          property_id: fields[:property_id],
          credit_lot_id: fields[:credit_lot_id]
        })

        :ok
    end
  end

  ## Reading one day

  @doc """
  Returns the daily report for `date`, or `{:error, :report_not_available}`
  before reporting has started or for a date before `starts_on`.
  """
  def daily_report(date) do
    case current_start() do
      nil ->
        {:error, :report_not_available}

      start ->
        if Date.compare(date, start.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(start, date)}
        end
    end
  end

  defp build_report(start, date) do
    movements = Repo.all(Movement)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash_section(start, movements, date),
      credit: credit_section(start, movements, date)
    }
  end

  defp cash_section(start, movements, date) do
    cash = Enum.filter(movements, &(&1.kind == "cash"))

    opening =
      Enum.reduce(cash, start.opening_held_cents, fn movement, acc ->
        if Date.compare(movement.posted_on, date) == :lt do
          effect = cash_effect(movement)
          Map.update(acc, movement.property_id, effect, &(&1 + effect))
        else
          acc
        end
      end)

    day_by_property =
      cash
      |> Enum.filter(&(Date.compare(&1.posted_on, date) == :eq))
      |> Enum.reduce(%{}, fn movement, acc ->
        entry = Map.get(acc, movement.property_id, %{})

        entry =
          Map.update(entry, movement.classification, movement.amount_cents, fn amount ->
            amount + movement.amount_cents
          end)

        Map.put(acc, movement.property_id, entry)
      end)

    (Map.keys(opening) ++ Map.keys(day_by_property))
    |> Enum.uniq()
    |> Enum.map(fn property_id ->
      opening_cents = Map.get(opening, property_id, 0)
      day = Map.get(day_by_property, property_id, %{})

      movement_values =
        Map.new(@cash_columns, fn {classification, key} ->
          {key, Map.get(day, classification, 0)}
        end)

      net =
        Enum.reduce(day, 0, fn {classification, amount}, acc ->
          acc + Map.fetch!(@cash_signs, classification) * amount
        end)

      %{
        property_id: property_id,
        opening_held_cents: opening_cents,
        movements: movement_values,
        closing_held_cents: opening_cents + net
      }
    end)
    |> Enum.filter(fn entry ->
      entry.opening_held_cents != 0 or entry.closing_held_cents != 0 or
        Enum.any?(Map.values(entry.movements), &(&1 != 0))
    end)
    |> Enum.sort_by(& &1.property_id)
  end

  defp cash_effect(movement) do
    Map.fetch!(@cash_signs, movement.classification) * movement.amount_cents
  end

  defp credit_section(start, movements, date) do
    all_credit =
      movements
      |> Enum.filter(&(&1.kind == "credit" and Map.has_key?(@credit_columns, &1.classification)))
      |> Enum.map(&Map.take(&1, [:posted_on, :classification, :amount_cents]))
      |> Kernel.++(derived_expiry_movements(start, movements))

    opening =
      Enum.reduce(all_credit, start.opening_liability_cents, fn movement, acc ->
        if Date.compare(movement.posted_on, date) == :lt do
          acc + credit_effect(movement)
        else
          acc
        end
      end)

    day_by_classification =
      all_credit
      |> Enum.filter(&(Date.compare(&1.posted_on, date) == :eq))
      |> Enum.reduce(%{}, fn movement, acc ->
        Map.update(acc, movement.classification, movement.amount_cents, fn amount ->
          amount + movement.amount_cents
        end)
      end)

    movement_values =
      Map.new(@credit_columns, fn {classification, key} ->
        {key, Map.get(day_by_classification, classification, 0)}
      end)

    net =
      Enum.reduce(day_by_classification, 0, fn {classification, amount}, acc ->
        acc + credit_effect(%{classification: classification, amount_cents: amount})
      end)

    %{
      opening_liability_cents: opening,
      movements: movement_values,
      closing_liability_cents: opening + net
    }
  end

  # Issued liability enters; expiry, consumption, revocation, and shortfall
  # absorption move it out.
  defp credit_effect(%{classification: "issued", amount_cents: amount}), do: amount
  defp credit_effect(%{amount_cents: amount}), do: -amount

  # Credit that remains unused through its expiry leaves the liability on the
  # expiry date even when no partner operation was submitted that day. The
  # expired amount is the lot's remaining balance in report time: movements
  # posted on or after the expiry date are reversed out of the current
  # remaining balance so later submissions change earlier open reports.
  defp derived_expiry_movements(start, movements) do
    issued_lot_ids =
      movements
      |> Enum.filter(&(&1.kind == "credit" and &1.classification == "issued"))
      |> MapSet.new(& &1.credit_lot_id)

    credit_by_lot =
      movements
      |> Enum.filter(&(&1.kind == "credit"))
      |> Enum.group_by(& &1.credit_lot_id)

    Repo.all(Lot)
    |> Enum.flat_map(fn lot ->
      issued? = MapSet.member?(issued_lot_ids, lot.id)

      # A lot issued before reporting started contributes only when it was
      # still part of the liability on `starts_on`; a lot issued afterwards
      # expires at the earliest reportable date at the latest.
      expiry_date =
        cond do
          Date.compare(lot.expires_on, start.starts_on) == :gt -> lot.expires_on
          issued? -> start.starts_on
          true -> nil
        end

      if expiry_date do
        adjustment =
          credit_by_lot
          |> Map.get(lot.id, [])
          |> Enum.filter(&(Date.compare(&1.posted_on, expiry_date) != :lt))
          |> Enum.reduce(0, fn movement, acc ->
            case movement.classification do
              "applied" -> acc + movement.amount_cents
              "restored" -> acc - movement.amount_cents
              "revoked" -> acc + movement.amount_cents
              _other -> acc
            end
          end)

        amount = max(0, lot.remaining_cents + adjustment)

        if amount > 0 do
          [%{posted_on: expiry_date, classification: "expired", amount_cents: amount}]
        else
          []
        end
      else
        []
      end
    end)
  end
end
