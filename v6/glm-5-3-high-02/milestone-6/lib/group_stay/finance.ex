defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting over the deposit domain.

  The first applied `start_finance_reporting` operation records the
  reporting inception point: `starts_on` plus the opening position
  snapshot — held cash per property and hotel-credit liability — taken
  immediately before that operation was processed, which includes every
  operation already committed, even one whose `occurred_on` is on or after
  `starts_on`.

  Every operation processed after reporting started posts its finance
  effects to an append-only event log inside the same transaction as the
  domain changes it describes. An event's posting date is the later of the
  operation's `occurred_on` and `starts_on`, so a later submission with an
  earlier `occurred_on` can still change an earlier open report.

  The daily report for a date chains the opening balances from the
  inception position through every event posted before that date, shows
  the date's own movements, and reconciles with the current views.
  Reading a report never writes anything. Hotel-credit expiry needs no
  stored event: unused credit expires the date after its `expires_on`, so
  the report derives expiry movements from the lots' current balances.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
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
    case Repo.one(from r in Reporting) do
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

  # -- event posting ---------------------------------------------------------

  @doc """
  Posts one reporting movement for an operation processed after reporting
  started, with posting date the later of `occurred_on` and `starts_on`.

  Zero and nil amounts post nothing, and nothing is posted before
  reporting has started. Commits with the caller's transaction, so a
  handled rejection rolls the event back with its domain changes.
  """
  def post_event(kind, classification, property_id, amount_cents, occurred_on, source_operation_id)
      when is_binary(kind) and is_binary(classification) and is_binary(source_operation_id) do
    if is_integer(amount_cents) and amount_cents != 0 do
      case reporting_starts_on() do
        nil ->
          :ok

        starts_on ->
          posting_date =
            if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on

          Repo.insert!(%Event{
            posting_date: posting_date,
            kind: kind,
            classification: classification,
            property_id: property_id,
            amount_cents: amount_cents,
            source_operation_id: source_operation_id
          })

          :ok
      end
    else
      :ok
    end
  end

  # -- the daily report --------------------------------------------------------

  @doc """
  The daily finance report for `date`.

  Returns `{:error, :report_not_available}` before reporting has started
  or for a date before `starts_on`. The report chains each property's
  opening held cash and the company-wide credit liability from the
  inception position through every event posted before `date`, reports
  the movements posted on `date`, and derives credit expiry from the
  lots' current balances.
  """
  def daily_report(date) do
    case Repo.one(from r in Reporting) do
      nil ->
        {:error, :report_not_available}

      %Reporting{} = reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(date, reporting)}
        end
    end
  end

  defp build_report(date, %Reporting{} = reporting) do
    opening = Jason.decode!(reporting.opening_position)

    {prior_events, day_events} = partition_events(date, reporting.starts_on)

    cash_opening =
      opening
      |> Map.fetch!("cash")
      |> apply_cash_balances(prior_events)

    credit_opening = Map.fetch!(opening, "credit_liability_cents") + credit_balance_of(prior_events)

    cash_day = cash_movements_of(day_events)
    credit_day = credit_movements_of(day_events)

    cash_entries =
      (Map.keys(cash_opening) ++ Map.keys(cash_day))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn property_id ->
        opening_cents = Map.get(cash_opening, property_id, 0)
        movements = cash_movement_map(Map.get(cash_day, property_id, %{}))

        %{
          "property_id" => property_id,
          "opening_held_cents" => opening_cents,
          "movements" => movements,
          "closing_held_cents" => opening_cents + cash_balance_delta(movements)
        }
      end)
      |> Enum.reject(&cash_entry_zero?/1)

    credit_movements = credit_movement_map(credit_day)

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_entries,
      "credit" => %{
        "opening_liability_cents" => credit_opening,
        "movements" => credit_movements,
        "closing_liability_cents" => credit_opening + credit_balance_delta(credit_movements)
      }
    }
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
          source_id: Integer.to_string(lot_id)
        }
      end)

    Enum.split_with(durable ++ expiry, fn event ->
      Date.compare(event.posting_date, date) == :lt
    end)
  end

  # -- balances --------------------------------------------------------------

  defp apply_cash_balances(events, cash) do
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

  defp cash_movements_of(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      if event.kind == "cash" do
        Map.update(acc, event.property_id, %{event.classification => event.amount_cents}, fn
          movements ->
            Map.update(movements, event.classification, event.amount_cents, &(&1 + event.amount_cents))
        end)
      else
        acc
      end
    end)
  end

  defp credit_movements_of(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      if event.kind == "credit" do
        Map.update(acc, event.classification, event.amount_cents, &(&1 + event.amount_cents))
      else
        acc
      end
    end)
  end

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

  defp cash_entry_zero?(%{
         "opening_held_cents" => opening,
         "movements" => movements,
         "closing_held_cents" => closing
       }) do
    opening == 0 and closing == 0 and Enum.all?(Map.values(movements), &(&1 == 0))
  end

  defp normalize_sum(nil), do: 0
  defp normalize_sum(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_sum(value) when is_integer(value), do: value
end
