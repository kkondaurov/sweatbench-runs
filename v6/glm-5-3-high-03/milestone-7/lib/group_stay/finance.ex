defmodule GroupStay.Finance do
  @moduledoc """
  The daily finance report: how held cash and hotel-credit liability moved
  since finance reporting began.

  Reporting starts when the first `start_finance_reporting` operation is
  applied. The financial state immediately before that operation is processed
  becomes the opening position on its `starts_on` date — the held cash of each
  property and the credit liability — including every operation already
  committed, even one whose `occurred_on` is on or after `starts_on`.

  Every operation processed after that records its finance movements at the
  posting date, the later of its `occurred_on`, the reporting `starts_on`, and
  the day after the latest finance period close; later submissions can
  therefore change an earlier open report. Credit that remains unused expires
  on its `expires_on` date, and the report shows that expiry even when no
  partner operation was submitted that day. Reading reports never changes a
  report or any domain state.

  A `close_finance_period` operation closes every day through its cutoff: the
  reports of those dates are frozen as published snapshots and keep returning
  their exact stored data — with `status: "closed"` — across later operations,
  later closes, and process restarts. An operation that commits after a close
  posts its complete finance effect on the first open day, and the movements
  the close pushed forward are reported separately in the `late_adjustments`
  block of the days they land on, keeping later corrections visible without
  rewriting a closed day.
  """

  import Ecto.Query

  alias GroupStay.Credits.CreditApplication
  alias GroupStay.Credits.CreditLot
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.Opening
  alias GroupStay.Finance.PeriodClose
  alias GroupStay.Finance.ReportingState
  alias GroupStay.Finance.ReportSnapshot
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @cash_classifications ~w(
    received
    transferred_in
    transferred_out
    refunded
    retained
    converted_to_credit
    reduced
    charged_back
  )

  @credit_classifications ~w(issued expired consumed revoked absorbed)

  ## Starting reporting

  @doc """
  Whether finance reporting has started.
  """
  def started? do
    Repo.exists?(ReportingState, id: 1)
  end

  @doc """
  The durable reporting inception point, or `:error` before reporting has
  started.
  """
  def started_state do
    case Repo.get(ReportingState, 1) do
      nil -> :error
      %ReportingState{} = state -> {:ok, state}
    end
  end

  @doc """
  Records the reporting inception point: the `starts_on` date and the opening
  position observed immediately before the start operation is processed.
  """
  def start_reporting(operation_id, starts_on) do
    openings =
      Repo.all(
        from g in Group,
          where: g.status == "active",
          group_by: g.property_id,
          select: {g.property_id, sum(g.deposit_paid_cents - g.credit_paid_cents)}
      )

    {:ok, state} =
      %ReportingState{}
      |> Ecto.Changeset.change(%{
        id: 1,
        starts_on: starts_on,
        operation_id: operation_id,
        opening_credit_liability_cents: opening_credit_liability_cents(starts_on)
      })
      |> Repo.insert()

    Enum.each(openings, fn {property_id, opening_held_cents} ->
      %Opening{}
      |> Ecto.Changeset.change(%{
        reporting_state_id: state.id,
        property_id: property_id,
        opening_held_cents: opening_held_cents || 0
      })
      |> Repo.insert!()
    end)

    :ok
  end

  # The credit liability as of the day before `starts_on`, observed from the
  # current state: credit applied to active groups plus unexpired lots. Lots
  # that had already expired before reporting began are pre-reporting history
  # and never enter the opening position.
  defp opening_credit_liability_cents(starts_on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^starts_on,
          select: sum(l.remaining_cents)
      )
      |> Kernel.||(0)

    applied_to_active_groups =
      Repo.one(
        from a in CreditApplication,
          join: g in Group,
          on: g.id == a.group_id,
          where: g.status == "active",
          select: sum(a.amount_cents)
      )
      |> Kernel.||(0)

    available + applied_to_active_groups
  end

  ## Closing a period

  @doc """
  The latest successful finance period close, or `nil` before any close was
  applied. Because a close is applied only strictly later than the latest
  recorded cutoff, the newest close always carries the latest one.
  """
  def latest_close do
    Repo.one(from c in PeriodClose, order_by: [desc: c.period_end_on], limit: 1)
  end

  @doc """
  Records a successful finance period close and publishes every daily report
  through `period_end_on`: each date of the still-open reporting period gets a
  frozen snapshot of its complete report, taken from the state observed when
  the close is processed. Dates already published by an earlier close keep
  their existing snapshots untouched.
  """
  def close_period(operation_id, period_end_on) do
    {:ok, %ReportingState{} = state} = started_state()

    %PeriodClose{}
    |> Ecto.Changeset.change(%{operation_id: operation_id, period_end_on: period_end_on})
    |> Repo.insert!()

    snapshot_open_dates(state, period_end_on)

    :ok
  end

  defp snapshot_open_dates(%ReportingState{} = state, period_end_on) do
    published =
      Repo.all(from s in ReportSnapshot, where: s.date <= ^period_end_on, select: s.date)
      |> MapSet.new()

    Date.range(state.starts_on, period_end_on)
    |> Enum.each(fn date ->
      unless MapSet.member?(published, date) do
        %ReportSnapshot{}
        |> Ecto.Changeset.change(%{date: date, data: build_report(state, date, "closed")})
        |> Repo.insert!()
      end
    end)
  end

  ## Recording movements

  @doc """
  The posting date of an operation processed on `occurred_on`: the later of
  its `occurred_on`, the reporting `starts_on`, and the day after the latest
  finance period close, or `nil` before reporting has started.
  """
  def posting_date(occurred_on) do
    case posting(occurred_on) do
      {posting_date, _late?} -> posting_date
      nil -> nil
    end
  end

  # The posting date of an operation together with whether a close moved it
  # forward: a movement is late exactly when its posting date is later than
  # both its `occurred_on` and the reporting `starts_on`.
  defp posting(occurred_on) do
    case started_state() do
      {:ok, %ReportingState{starts_on: starts_on}} ->
        natural_date = max_date(occurred_on, starts_on)

        case latest_close() do
          nil ->
            {natural_date, false}

          %PeriodClose{period_end_on: cutoff} ->
            first_open_day = Date.add(cutoff, 1)

            {max_date(natural_date, first_open_day),
             Date.compare(natural_date, first_open_day) == :lt}
        end

      :error ->
        nil
    end
  end

  defp max_date(a, b), do: if(Date.compare(a, b) == :gt, do: a, else: b)

  @doc """
  Records finance movements for an operation processed on `occurred_on`, each
  a map with `property_id` (`nil` for company-wide credit movements),
  `classification`, and a signed `amount_cents`. A no-op before reporting has
  started; zero amounts are not recorded. Movements a close pushed onto the
  first open day are marked late and reported in the daily report's
  `late_adjustments` block.
  """
  def record(occurred_on, movements) do
    case posting(occurred_on) do
      nil ->
        :ok

      {posting_date, late?} ->
        Enum.each(movements, fn movement ->
          unless movement.amount_cents == 0 do
            %Movement{}
            |> Ecto.Changeset.change(%{
              posting_date: posting_date,
              property_id: movement.property_id,
              classification: movement.classification,
              amount_cents: movement.amount_cents,
              late: late?
            })
            |> Repo.insert!()
          end
        end)
    end
  end

  ## Reading one day

  @doc """
  The daily finance report for `date`, or `{:error, :report_not_available}`
  before reporting has started or for a date before `starts_on`.

  A date within a closed period returns its published snapshot — the exact
  data frozen when the period was closed — with `status: "closed"`. Later
  dates are recomputed from current state with `status: "open"`.
  """
  def daily_report(%Date{} = date) do
    case started_state() do
      {:ok, %ReportingState{} = state} ->
        cond do
          Date.compare(date, state.starts_on) == :lt ->
            {:error, :report_not_available}

          true ->
            case Repo.get_by(ReportSnapshot, date: date) do
              %ReportSnapshot{data: data} -> {:ok, data}
              nil -> {:ok, build_report(state, date, "open")}
            end
        end

      :error ->
        {:error, :report_not_available}
    end
  end

  defp build_report(state, date, status) do
    amounts = movement_amounts(date)
    openings = opening_amounts(state)

    lot_expired_cents = expired_lot_cents(state.starts_on, date)

    property_ids =
      (Map.keys(openings) ++
         for(
           {{property_id, _classification}, _amount} <- Map.merge(amounts.ordinary, amounts.late),
           not is_nil(property_id),
           do: property_id
         ))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "date" => Date.to_iso8601(date),
      "status" => status,
      "cash" => Enum.flat_map(property_ids, &cash_entry(&1, openings, amounts)),
      "credit" => credit_entry(state, amounts, lot_expired_cents),
      "late_adjustments" => %{
        "cash" => late_cash_entries(property_ids, amounts.late),
        "credit" => late_credit_entry(amounts.late)
      }
    }
  end

  # Net movement amounts through `date`, keyed by property (nil for credit)
  # and classification, split into ordinary movements and the late movements
  # a close pushed onto the first open day.
  defp movement_amounts(date) do
    Repo.all(
      from m in Movement,
        where: m.posting_date <= ^date,
        group_by: [m.property_id, m.classification, m.late],
        select: {m.property_id, m.classification, m.late, sum(m.amount_cents)}
    )
    |> Enum.reduce(%{ordinary: %{}, late: %{}}, fn {property_id, classification, late?,
                                                    amount_cents},
                                                   acc ->
      key = {property_id, classification}
      bucket = if late?, do: :late, else: :ordinary
      %{acc | bucket => Map.put(acc[bucket], key, amount_cents)}
    end)
  end

  defp opening_amounts(%ReportingState{} = state) do
    Repo.all(from o in Opening, where: o.reporting_state_id == ^state.id)
    |> Map.new(&{&1.property_id, &1.opening_held_cents})
  end

  # Unused credit that expired through `date`, read from the current state of
  # the lots: the liability left through the lot's expiry, whether or not any
  # partner operation was submitted that day.
  defp expired_lot_cents(starts_on, date) do
    Repo.one(
      from l in CreditLot,
        where: l.expires_on >= ^starts_on and l.expires_on <= ^date,
        select: sum(l.remaining_cents + l.clawed_back_expired_cents)
    )
    |> Kernel.||(0)
  end

  # A property is omitted only when its opening balance, closing balance, and
  # every movement — ordinary and late together — are zero. Its ordinary
  # movement columns carry only the movements that were not pushed forward by
  # a close; its closing balance uses both.
  defp cash_entry(property_id, openings, amounts) do
    opening_held_cents = Map.get(openings, property_id, 0)

    movements =
      Map.new(@cash_classifications, fn classification ->
        {classification, Map.get(amounts.ordinary, {property_id, classification}, 0)}
      end)

    late_movements =
      Map.new(@cash_classifications, fn classification ->
        {classification, Map.get(amounts.late, {property_id, classification}, 0)}
      end)

    closing_held_cents = opening_held_cents + net_cash(movements) + net_cash(late_movements)

    if opening_held_cents == 0 and closing_held_cents == 0 and
         Enum.all?(movements, fn {_k, v} -> v == 0 end) and
         Enum.all?(late_movements, fn {_k, v} -> v == 0 end) do
      []
    else
      [
        %{
          "property_id" => property_id,
          "opening_held_cents" => opening_held_cents,
          "movements" => suffix_cents(movements),
          "closing_held_cents" => closing_held_cents
        }
      ]
    end
  end

  defp net_cash(movements) do
    movements["received"] + movements["transferred_in"] - movements["transferred_out"] -
      movements["refunded"] - movements["retained"] - movements["converted_to_credit"] -
      movements["reduced"] - movements["charged_back"]
  end

  # The late movements of each property, ordered by property_id; a property
  # with no late movement at all is omitted. Signed classifications are kept
  # even when they net to zero.
  defp late_cash_entries(property_ids, late) do
    Enum.flat_map(property_ids, fn property_id ->
      movements =
        Map.new(@cash_classifications, fn classification ->
          {classification, Map.get(late, {property_id, classification}, 0)}
        end)

      if Enum.all?(movements, fn {_k, v} -> v == 0 end) do
        []
      else
        [%{"property_id" => property_id, "movements" => suffix_cents(movements)}]
      end
    end)
  end

  defp credit_entry(%ReportingState{} = state, amounts, lot_expired_cents) do
    issued = Map.get(amounts.ordinary, {nil, "issued"}, 0)
    # Unused credit expires on its expires_on date; restored credit whose
    # expiry has already passed expires immediately at its posting date.
    expired = Map.get(amounts.ordinary, {nil, "expired"}, 0) + lot_expired_cents
    consumed = Map.get(amounts.ordinary, {nil, "consumed"}, 0)
    revoked = Map.get(amounts.ordinary, {nil, "revoked"}, 0)
    absorbed = Map.get(amounts.ordinary, {nil, "absorbed"}, 0)

    late_issued = Map.get(amounts.late, {nil, "issued"}, 0)
    late_expired = Map.get(amounts.late, {nil, "expired"}, 0)
    late_consumed = Map.get(amounts.late, {nil, "consumed"}, 0)
    late_revoked = Map.get(amounts.late, {nil, "revoked"}, 0)
    late_absorbed = Map.get(amounts.late, {nil, "absorbed"}, 0)

    opening_liability_cents = state.opening_credit_liability_cents

    %{
      "opening_liability_cents" => opening_liability_cents,
      "movements" => %{
        "issued_cents" => issued,
        "expired_cents" => expired,
        "consumed_cents" => consumed,
        "revoked_cents" => revoked,
        "absorbed_cents" => absorbed
      },
      "closing_liability_cents" =>
        opening_liability_cents + issued + late_issued - expired - late_expired -
          consumed - late_consumed - revoked - late_revoked - absorbed - late_absorbed
    }
  end

  defp late_credit_entry(late) do
    Map.new(@credit_classifications, fn classification ->
      {classification <> "_cents", Map.get(late, {nil, classification}, 0)}
    end)
  end

  defp suffix_cents(movements) do
    Map.new(movements, fn {classification, amount_cents} ->
      {classification <> "_cents", amount_cents}
    end)
  end
end
