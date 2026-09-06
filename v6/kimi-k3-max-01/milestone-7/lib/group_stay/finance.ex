defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting: the inception point and the posting-dated
  movement stream the report reads.

  The first applied `start_finance_reporting` operation snapshots the
  financial state immediately before it is processed (held cash per property
  and the company-wide credit liability) as the opening position on
  `starts_on`. Every operation processed after the start records its finance
  effects as movements whose posting date is the later of the operation's
  `occurred_on` and `starts_on`.

  The daily report derives from the snapshot plus the movement stream, so
  reading reports never changes state and equivalent submissions produce
  equivalent reports. Credit lots that remain unused through their
  `expires_on` date expire on that date; that expiry is derived from the
  current lots at report time, so it appears even on days without partner
  operations.

  A `close_finance_period` operation publishes every report through its
  `period_end_on` cutoff: the rendered report is snapshotted once and never
  changes again. An operation processed after a close whose `occurred_on` is
  no longer in the open period posts on the first open day instead, and the
  report exposes those movements separately as late adjustments.
  """

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Credits.Lot
  alias GroupStay.Finance.Close
  alias GroupStay.Finance.ClosedReport
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.Reporting
  alias GroupStay.Groups
  alias GroupStay.Repo

  @scopes ~w(cash credit)

  @cash_classifications ~w(received transferred_in transferred_out refunded retained
                           converted_to_credit reduced charged_back)

  @credit_classifications ~w(issued expired consumed revoked absorbed)

  # The algebraic effect of each classification on the held-cash / liability
  # balance: positive amounts move the balance up or down. Reversals record
  # negative amounts within the classification, applied with the same effect.
  @effects %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1,
    "issued" => 1,
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  @doc """
  The singleton reporting row, or `nil` before reporting started.
  """
  def reporting_row do
    Reporting
    |> order_by(:id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Whether finance reporting has started.
  """
  def started? do
    reporting_row() != nil
  end

  @doc """
  Enables reporting: snapshots the current financial state as the opening
  position on `starts_on`. Credit expiry in the snapshot is evaluated as of
  the day before, so lots expiring on `starts_on` still open the first
  report and expire with that day's movement.
  """
  def start!(%Date{} = starts_on) do
    opening_cash = Groups.held_cash_by_property()
    opening_liability = Credits.liability_cents(Date.shift(starts_on, day: -1))

    %Reporting{}
    |> Reporting.changeset(%{
      starts_on: starts_on,
      opening_cash: Jason.encode!(opening_cash),
      opening_liability_cents: opening_liability
    })
    |> Repo.insert!()
  end

  @doc """
  The latest successful period close cutoff, or `nil` before any close.
  """
  def latest_cutoff do
    Close
    |> order_by(desc: :period_end_on)
    |> limit(1)
    |> select([close], close.period_end_on)
    |> Repo.one()
  end

  @doc """
  Whether a close through `period_end_on` can apply: reporting must have
  started, the cutoff must be on or after `starts_on`, and it must be
  strictly later than the latest successful close.
  """
  def closeable?(%Date{} = period_end_on) do
    case reporting_row() do
      nil ->
        false

      %Reporting{starts_on: starts_on} ->
        cutoff = latest_cutoff()

        Date.compare(period_end_on, starts_on) != :lt and
          (is_nil(cutoff) or Date.compare(period_end_on, cutoff) == :gt)
    end
  end

  @doc """
  Closes the period through `period_end_on`: records the cutoff and
  publishes a snapshot of every report from the first still-open day through
  the cutoff. Reports closed by an earlier close keep their stored snapshot.
  """
  def close!(%Date{} = period_end_on) do
    %Reporting{} = row = reporting_row()

    first_open =
      case latest_cutoff() do
        nil -> row.starts_on
        cutoff -> Date.shift(cutoff, day: 1)
      end

    %Close{}
    |> Close.changeset(%{period_end_on: period_end_on})
    |> Repo.insert!()

    for date <- Date.range(first_open, period_end_on) do
      %ClosedReport{}
      |> ClosedReport.changeset(%{
        date: date,
        data: Jason.encode!(build_report(row, date, "closed"))
      })
      |> Repo.insert!()
    end

    :ok
  end

  @doc """
  The posting date for an operation processed after reporting started: the
  later of its `occurred_on`, `starts_on`, and the day after the latest
  close cutoff, so submissions can never post into a closed period.
  """
  def posting_on(%Date{} = occurred_on) do
    {posting_on, _late} = posting(occurred_on)
    posting_on
  end

  @doc """
  The posting date for an operation and whether a period close moved it
  forward. An operation whose `occurred_on` is already in the open period
  keeps it; otherwise the whole effect posts on the first open day as a late
  adjustment.
  """
  def posting(%Date{} = occurred_on) do
    case reporting_row() do
      nil ->
        {occurred_on, false}

      %Reporting{starts_on: starts_on} ->
        base =
          if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on

        case latest_cutoff() do
          nil ->
            {base, false}

          cutoff ->
            first_open = Date.shift(cutoff, day: 1)

            if Date.compare(base, first_open) == :lt do
              {first_open, true}
            else
              {base, false}
            end
        end
    end
  end

  @doc """
  Records a finance movement. A no-op before reporting starts and for zero
  amounts, so every caller can record unconditionally on the applied path.
  `scope` is `cash` (with a property) or `credit` (company-wide).
  """
  def record_movement!(_scope, _property_id, _classification, 0, %Date{}), do: :ok

  def record_movement!(scope, property_id, classification, amount_cents, %Date{} = occurred_on)
      when scope in @scopes do
    case reporting_row() do
      nil ->
        :ok

      %Reporting{} ->
        {posting_on, late} = posting(occurred_on)

        %Movement{}
        |> Movement.changeset(%{
          scope: scope,
          property_id: property_id,
          classification: classification,
          amount_cents: amount_cents,
          posting_on: posting_on,
          late: late
        })
        |> Repo.insert!()

        :ok
    end
  end

  @doc """
  The daily report for a date, or `:not_available` before reporting started
  or for a date before `starts_on`. The report contains one cash entry per
  property with any nonzero balance or movement, ordered by property id, one
  company-wide credit object, and the late adjustments posted onto the date
  by a period close. A date at or before the latest close cutoff returns its
  published snapshot with `status: "closed"`.
  """
  def report(%Date{} = date) do
    case reporting_row() do
      nil ->
        :not_available

      %Reporting{starts_on: starts_on} = row ->
        if Date.compare(date, starts_on) == :lt do
          :not_available
        else
          case closed_report(date) do
            %ClosedReport{data: data} -> {:ok, Jason.decode!(data)}
            nil -> {:ok, build_report(row, date, "open")}
          end
        end
    end
  end

  defp closed_report(%Date{} = date) do
    ClosedReport
    |> where(date: ^date)
    |> Repo.one()
  end

  defp build_report(%Reporting{} = row, %Date{} = date, status) do
    movements =
      Movement
      |> where([movement], movement.posting_on <= ^date)
      |> select([movement], %{
        scope: movement.scope,
        property_id: movement.property_id,
        classification: movement.classification,
        amount_cents: movement.amount_cents,
        posting_on: movement.posting_on,
        late: movement.late
      })
      |> Repo.all()

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash_entries(row, movements, date),
      credit: credit_object(row, movements, date),
      late_adjustments: late_adjustments(movements, date)
    }
  end

  ## Cash report

  defp cash_entries(%Reporting{} = row, movements, %Date{} = date) do
    snapshot = Jason.decode!(row.opening_cash)
    rows = Enum.filter(movements, &(&1.scope == "cash"))

    {before_rows, today_rows} = Enum.split_with(rows, &past_posting?(&1, date))
    {late_rows, ordinary_rows} = Enum.split_with(today_rows, & &1.late)

    properties =
      (Map.keys(snapshot) ++ Enum.map(rows, & &1.property_id))
      |> Enum.uniq()

    properties
    |> Enum.map(fn property ->
      opening = Map.get(snapshot, property, 0) + effect_sum(before_rows, property)
      ordinary = classification_sums(ordinary_rows, property)
      late = classification_sums(late_rows, property)
      closing = opening + effect_sum(today_rows, property)

      {property, opening, ordinary, late, closing}
    end)
    |> Enum.filter(fn {_property, opening, ordinary, late, closing} ->
      opening != 0 or closing != 0 or any_movement?(ordinary) or any_movement?(late)
    end)
    |> Enum.sort_by(fn {property, _opening, _ordinary, _late, _closing} -> property end)
    |> Enum.map(fn {property, opening, ordinary, _late, closing} ->
      %{
        property_id: property,
        opening_held_cents: opening,
        movements: classification_map(@cash_classifications, ordinary),
        closing_held_cents: closing
      }
    end)
  end

  defp any_movement?(today) do
    Enum.any?(today, fn {_classification, amount} -> amount != 0 end)
  end

  # Signed sum of movement amounts for one property, applying each
  # classification's algebraic effect.
  defp effect_sum(rows, property) do
    rows
    |> Enum.filter(&(&1.property_id == property))
    |> Enum.reduce(0, fn row, sum ->
      sum + row.amount_cents * Map.fetch!(@effects, row.classification)
    end)
  end

  # Sums by classification for the rows of one property.
  defp classification_sums(rows, property) do
    rows
    |> Enum.filter(&(&1.property_id == property))
    |> classification_sums()
  end

  defp classification_sums(rows) do
    rows
    |> Enum.group_by(& &1.classification, & &1.amount_cents)
    |> Map.new(fn {classification, amounts} -> {classification, Enum.sum(amounts)} end)
  end

  defp classification_map(classifications, today) do
    Map.new(classifications, fn classification ->
      {classification <> "_cents", Map.get(today, classification, 0)}
    end)
  end

  ## Late adjustments

  # The movements posted onto the date whose posting date was moved forward
  # by a period close. For each classification, the day's total movement is
  # the ordinary value plus the late value here; opening and closing
  # balances use both. Signed classifications are kept even when their net
  # balance effect is zero.
  defp late_adjustments(movements, %Date{} = date) do
    rows =
      Enum.filter(movements, fn movement ->
        movement.late and Date.compare(movement.posting_on, date) == :eq
      end)

    cash =
      rows
      |> Enum.filter(&(&1.scope == "cash"))
      |> Enum.map(& &1.property_id)
      |> Enum.uniq()
      |> Enum.map(fn property -> {property, classification_sums(rows, property)} end)
      |> Enum.filter(fn {_property, sums} -> any_movement?(sums) end)
      |> Enum.sort_by(fn {property, _sums} -> property end)
      |> Enum.map(fn {property, sums} ->
        %{property_id: property, movements: classification_map(@cash_classifications, sums)}
      end)

    credit =
      rows
      |> Enum.filter(&(&1.scope == "credit"))
      |> classification_sums()
      |> then(&classification_map(@credit_classifications, &1))

    %{cash: cash, credit: credit}
  end

  ## Credit report

  defp credit_object(%Reporting{} = row, movements, %Date{} = date) do
    rows = Enum.filter(movements, &(&1.scope == "credit"))
    {before_rows, today_rows} = Enum.split_with(rows, &past_posting?(&1, date))
    ordinary_rows = Enum.reject(today_rows, & &1.late)

    # Lot expiry is derived from the current lots, so it is reported even on
    # days without partner operations.
    expiry_by_day = lot_expiry_by_day(row.starts_on, date)

    expired_before =
      expiry_by_day
      |> Enum.filter(fn {expires_on, _amount} -> Date.compare(expires_on, date) == :lt end)
      |> Enum.map(fn {_expires_on, amount} -> amount end)
      |> Enum.sum()

    expired_today = Map.get(expiry_by_day, date, 0)

    opening = row.opening_liability_cents + credit_effect_sum(before_rows) - expired_before

    today =
      ordinary_rows
      |> classification_sums()
      |> Map.update("expired", expired_today, &(&1 + expired_today))

    closing = opening + credit_effect_sum(today_rows) - expired_today

    %{
      opening_liability_cents: opening,
      movements: classification_map(@credit_classifications, today),
      closing_liability_cents: closing
    }
  end

  defp credit_effect_sum(rows) do
    Enum.reduce(rows, 0, fn row, sum ->
      sum + row.amount_cents * Map.fetch!(@effects, row.classification)
    end)
  end

  # Lots expiring within the reporting window up to the report date, grouped
  # by their expiry day, using their current remaining balance.
  defp lot_expiry_by_day(%Date{} = starts_on, %Date{} = date) do
    Lot
    |> where([lot], lot.expires_on >= ^starts_on and lot.expires_on <= ^date)
    |> group_by(:expires_on)
    |> select([lot], {lot.expires_on, sum(lot.remaining_cents)})
    |> Repo.all()
    |> Map.new()
  end

  defp past_posting?(row, %Date{} = date), do: Date.compare(row.posting_on, date) == :lt
end
