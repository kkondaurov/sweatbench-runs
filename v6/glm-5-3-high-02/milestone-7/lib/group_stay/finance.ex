defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting over the deposit domain, with period close.

  The first applied `start_finance_reporting` operation records the
  reporting inception point: `starts_on` plus the opening position
  snapshot — held cash per property and hotel-credit liability — taken
  immediately before that operation was processed, which includes every
  operation already committed, even one whose `occurred_on` is on or
  after `starts_on`.

  Every operation processed after reporting started posts its finance
  effects to an append-only event log inside the same transaction as the
  domain changes it describes. An event's posting date is the later of
  the operation's `occurred_on`, `starts_on`, and the day after the
  latest period close at the moment the operation commits. A posting date
  pushed forward by a close is flagged late and surfaces in the daily
  report's `late_adjustments` block.

  The daily report for a date chains the opening balances from the
  inception position through every event posted before that date, shows
  the date's own movements, and reconciles with the current views.
  Reading a report never writes anything. Hotel-credit expiry needs no
  stored event: unused credit expires the date after its `expires_on`, so
  the report derives expiry movements from the lots' current balances.

  A `close_finance_period` operation closes the books through a cutoff
  date: every report through the cutoff is published — its `data` value
  stored verbatim — and returns `status: "closed"` forever, byte-for-byte
  stable across later operations, later closes, and process restarts.
  Reports after the cutoff stay open and keep following the live state.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.Close
  alias GroupStay.Finance.ClosedReport
  alias GroupStay.Finance.Event
  alias GroupStay.Finance.Reporting
  alias GroupStay.Groups.Allocation
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

  # -- starting ------------------------------------------------------------

  @doc """
  Records the reporting inception point, snapshotting the current state as
  the opening position on `starts_on`.

  Returns `{:ok, result}` with the applied result fields, or
  `{:error, :reporting_already_started}` when reporting has already
  started. Runs inside the calling operation's transaction.
  """
  def start_reporting(starts_on, operation_id) do
    case Repo.one(from(r in Reporting)) do
      nil ->
        opening_position = %{
          "cash" => opening_cash_by_property(),
          "credit_liability_cents" => Credit.liability_cents(starts_on)
        }

        Repo.insert!(%Reporting{
          starts_on: starts_on,
          operation_id: operation_id,
          opening_position: Jason.encode!(opening_position)
        })

        {:ok, %{"starts_on" => Date.to_iso8601(starts_on)}}

      %Reporting{} ->
        {:error, :reporting_already_started}
    end
  end

  # Held cash per property: the opening balance of each property's report.
  defp opening_cash_by_property do
    Repo.all(
      from a in Allocation,
        join: g in Group,
        on: a.group_id == g.id,
        where: a.source == "cash" and a.state == "held",
        group_by: g.property_id,
        select: {g.property_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Map.new(fn {property_id, value} -> {property_id, normalize_sum(value)} end)
  end

  @doc """
  The date finance reporting started, or nil before it has started.
  """
  def reporting_starts_on do
    Repo.one(from r in Reporting, select: r.starts_on)
  end

  # -- closing ---------------------------------------------------------------

  @doc """
  The latest successful close's cutoff date, or nil before any close.
  """
  def latest_cutoff do
    Repo.one(from c in Close, select: max(c.period_end_on))
  end

  @doc """
  Closes the finance period through `period_end_on`, publishing every
  daily report through that date.

  The close applies only when finance reporting has started, the cutoff
  is on or after `starts_on`, and it is strictly later than the latest
  successful close; otherwise `{:error, :reporting_not_started}` or
  `{:error, :invalid_period}`. On success every report through the cutoff
  that is not published yet is computed once and stored verbatim, and
  operations after this point post no earlier than the day after the
  cutoff. Runs inside the calling operation's transaction.
  """
  def close_period(period_end_on, operation_id) do
    case Repo.one(from(r in Reporting)) do
      nil ->
        {:error, :reporting_not_started}

      %Reporting{} = reporting ->
        latest = latest_cutoff()

        cond do
          Date.compare(period_end_on, reporting.starts_on) == :lt ->
            {:error, :invalid_period}

          latest != nil and Date.compare(period_end_on, latest) != :gt ->
            {:error, :invalid_period}

          true ->
            Repo.insert!(%Close{period_end_on: period_end_on, operation_id: operation_id})

            publish_reports_through(reporting, period_end_on, operation_id)

            {:ok, %{"period_end_on" => Date.to_iso8601(period_end_on)}}
        end
    end
  end

  # Each date from `starts_on` through the cutoff that is not published
  # yet is computed once — with status "closed" — and stored verbatim.
  # Dates published by an earlier close keep their stored value untouched.
  defp publish_reports_through(%Reporting{} = reporting, period_end_on, operation_id) do
    published =
      Repo.all(
        from r in ClosedReport,
          where: r.report_on >= ^reporting.starts_on and r.report_on <= ^period_end_on,
          select: r.report_on
      )
      |> MapSet.new()

    Date.range(reporting.starts_on, period_end_on)
    |> Enum.reject(&MapSet.member?(published, &1))
    |> Enum.each(fn date ->
      report = build_report(date, reporting, "closed")

      Repo.insert!(%ClosedReport{
        report_on: date,
        data: Jason.encode!(report),
        closed_by_operation_id: operation_id
      })
    end)

    :ok
  end

  # -- event posting ---------------------------------------------------------

  @doc """
  Posts one reporting movement for an operation processed after reporting
  started, with posting date the later of `occurred_on`, `starts_on`, and
  the day after the latest close at the moment the operation commits.

  A posting date pushed forward by a close is flagged late. Zero and nil
  amounts post nothing, and nothing is posted before reporting has
  started. Commits with the caller's transaction, so a handled rejection
  rolls the event back with its domain changes.
  """
  def post_event(
        kind,
        classification,
        property_id,
        amount_cents,
        occurred_on,
        source_operation_id
      )
      when is_binary(kind) and is_binary(classification) and is_binary(source_operation_id) do
    if is_integer(amount_cents) and amount_cents != 0 do
      case reporting_starts_on() do
        nil ->
          :ok

        starts_on ->
          posting_date = posting_date(occurred_on, starts_on)

          Repo.insert!(%Event{
            posting_date: posting_date,
            kind: kind,
            classification: classification,
            property_id: property_id,
            amount_cents: amount_cents,
            source_operation_id: source_operation_id,
            late: Date.compare(posting_date, max_date(occurred_on, starts_on)) == :gt
          })

          :ok
      end
    else
      :ok
    end
  end

  defp posting_date(occurred_on, starts_on) do
    natural = max_date(occurred_on, starts_on)

    case latest_cutoff() do
      nil -> natural
      cutoff -> max_date(natural, Date.add(cutoff, 1))
    end
  end

  defp max_date(a, b), do: if(Date.compare(a, b) == :gt, do: a, else: b)

  # -- the daily report --------------------------------------------------------

  @doc """
  The daily finance report for `date`.

  Returns `{:error, :report_not_available}` before reporting has started
  or for a date before `starts_on`. A date published by a close returns
  its stored `data` value verbatim with `status: "closed"`. An open date
  chains each property's opening held cash and the company-wide credit
  liability from the inception position through every event posted before
  `date`, reports the movements posted on `date` — ordinary and late
  separately — and derives credit expiry from the lots' current balances.
  """
  def daily_report(date) do
    case Repo.one(from(r in Reporting)) do
      nil ->
        {:error, :report_not_available}

      %Reporting{} = reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :report_not_available}
        else
          case Repo.get_by(ClosedReport, report_on: date) do
            %ClosedReport{} = published ->
              {:ok, Jason.decode!(published.data)}

            nil ->
              {:ok, build_report(date, reporting, report_status(date))}
          end
        end
    end
  end

  defp report_status(date) do
    case latest_cutoff() do
      nil -> "open"
      cutoff -> if Date.compare(date, cutoff) == :gt, do: "open", else: "closed"
    end
  end

  defp build_report(date, %Reporting{} = reporting, status) do
    opening = Jason.decode!(reporting.opening_position)

    {prior_events, day_events} = partition_events(date, reporting.starts_on)

    cash_opening =
      Map.fetch!(opening, "cash")
      |> apply_cash_balances(prior_events)

    credit_opening =
      Map.fetch!(opening, "credit_liability_cents") + credit_balance_of(prior_events)

    cash_ordinary = cash_movements_of(day_events, false)
    cash_late = cash_movements_of(day_events, true)
    credit_ordinary = credit_movements_of(day_events, false)
    credit_late = credit_movements_of(day_events, true)

    cash_entries =
      (Map.keys(cash_opening) ++ Map.keys(cash_ordinary) ++ Map.keys(cash_late))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn property_id ->
        opening_cents = Map.get(cash_opening, property_id, 0)
        movements = cash_movement_map(Map.get(cash_ordinary, property_id, %{}))
        late = cash_movement_map(Map.get(cash_late, property_id, %{}))

        %{
          "property_id" => property_id,
          "opening_held_cents" => opening_cents,
          "movements" => movements,
          "late" => late,
          "closing_held_cents" =>
            opening_cents + cash_balance_delta(movements) + cash_balance_delta(late)
        }
      end)
      |> Enum.reject(fn entry ->
        entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
          movements_zero?(entry["movements"]) and movements_zero?(entry["late"])
      end)
      |> Enum.map(&Map.delete(&1, "late"))

    credit_movements = credit_movement_map(credit_ordinary)
    late_credit = credit_movement_map(credit_late)

    %{
      "date" => Date.to_iso8601(date),
      "status" => status,
      "cash" => cash_entries,
      "credit" => %{
        "opening_liability_cents" => credit_opening,
        "movements" => credit_movements,
        "closing_liability_cents" =>
          credit_opening + credit_balance_delta(credit_movements) +
            credit_balance_delta(late_credit)
      },
      "late_adjustments" => %{
        "cash" => late_cash_entries(cash_late),
        "credit" => late_credit
      }
    }
  end

  # The late-adjustment cash array: properties with at least one late
  # movement on the date, ordered by property_id, omitting properties
  # whose late movements are all zero.
  defp late_cash_entries(cash_late) do
    cash_late
    |> Enum.reject(fn {_property_id, movements} -> movements_zero?(movements) end)
    |> Enum.sort_by(fn {property_id, _movements} -> property_id end)
    |> Enum.map(fn {property_id, movements} ->
      %{"property_id" => property_id, "movements" => cash_movement_map(movements)}
    end)
  end

  # Events visible to the report: the durable log through `date`, plus the
  # derived expiry of unused credit. A lot's expiry movement lands on the
  # date after its `expires_on` — computed from the lot's current balance
  # — and only for dates from `starts_on` onward; earlier expiry is part
  # of the opening position snapshot.
  defp partition_events(date, starts_on) do
    durable = Repo.all(from e in Event, where: e.posting_date <= ^date, order_by: e.id)

    expiry =
      Repo.all(
        from l in Lot,
          where:
            l.remaining_cents > 0 and
              l.expires_on >= ^Date.add(starts_on, -1) and
              l.expires_on < ^date,
          order_by: l.id,
          select: {l.id, l.expires_on, l.remaining_cents}
      )
      |> Enum.map(fn {lot_id, expires_on, remaining_cents} ->
        %Event{
          posting_date: Date.add(expires_on, 1),
          kind: "credit",
          classification: "expired",
          property_id: nil,
          amount_cents: remaining_cents,
          source_id: Integer.to_string(lot_id),
          late: false
        }
      end)

    Enum.split_with(durable ++ expiry, fn event ->
      Date.compare(event.posting_date, date) == :lt
    end)
  end

  # -- balances --------------------------------------------------------------

  defp apply_cash_balances(cash, events) do
    Enum.reduce(events, cash, fn event, cash ->
      if event.kind == "cash" do
        delta = cash_balance_delta(event.classification, event.amount_cents)

        Map.update(cash, event.property_id, delta, &(&1 + delta))
      else
        cash
      end
    end)
  end

  defp credit_balance_of(events) do
    Enum.reduce(events, 0, fn event, acc ->
      if event.kind == "credit",
        do: acc + credit_balance_delta(event.classification, event.amount_cents),
        else: acc
    end)
  end

  # closing held = opening held + received + transferred in
  #              - transferred out - refunded - retained
  #              - converted to credit - reduced - charged back
  defp cash_balance_delta("received", amount), do: amount
  defp cash_balance_delta("transferred_in", amount), do: amount
  defp cash_balance_delta(_classification, amount), do: -amount

  # closing liability = opening liability + issued
  #                   - expired - consumed - revoked - absorbed
  defp credit_balance_delta("issued", amount), do: amount
  defp credit_balance_delta(_classification, amount), do: -amount

  defp cash_balance_delta(movements) when is_map(movements) do
    movements["received_cents"] + movements["transferred_in_cents"] -
      movements["transferred_out_cents"] - movements["refunded_cents"] -
      movements["retained_cents"] - movements["converted_to_credit_cents"] -
      movements["reduced_cents"] - movements["charged_back_cents"]
  end

  defp credit_balance_delta(movements) when is_map(movements) do
    movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
      movements["revoked_cents"] - movements["absorbed_cents"]
  end

  # -- movement aggregation ---------------------------------------------------

  defp cash_movements_of(events, late?) do
    Enum.reduce(events, %{}, fn event, acc ->
      if event.kind == "cash" and late?(event) == late? do
        Map.update(acc, event.property_id, %{event.classification => event.amount_cents}, fn
          movements ->
            Map.update(
              movements,
              event.classification,
              event.amount_cents,
              &(&1 + event.amount_cents)
            )
        end)
      else
        acc
      end
    end)
  end

  defp credit_movements_of(events, late?) do
    Enum.reduce(events, %{}, fn event, acc ->
      if event.kind == "credit" and late?(event) == late? do
        Map.update(acc, event.classification, event.amount_cents, &(&1 + event.amount_cents))
      else
        acc
      end
    end)
  end

  defp late?(%Event{late: late}), do: late == true

  defp cash_movement_map(day) do
    Map.new(@cash_classifications, fn classification ->
      {classification <> "_cents", Map.get(day, classification, 0)}
    end)
  end

  defp credit_movement_map(day) do
    Map.new(@credit_classifications, fn classification ->
      {classification <> "_cents", Map.get(day, classification, 0)}
    end)
  end

  # A property is omitted from the day's cash array only when its opening
  # and closing balances and every movement — ordinary and late — are
  # zero.
  defp movements_zero?(movements) when is_map(movements),
    do: Enum.all?(Map.values(movements), &(&1 == 0))

  defp normalize_sum(nil), do: 0
  defp normalize_sum(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_sum(value) when is_integer(value), do: value
end
