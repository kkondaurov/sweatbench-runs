defmodule GroupStay.Finance do
  @moduledoc """
  The daily finance report: a durable reporting inception point, recorded
  movements of held cash and credit liability, period closes that publish
  earlier days, and a read view of one day.

  The first applied `start_finance_reporting` operation snapshots the
  financial position immediately before it; that position becomes the opening
  position on `starts_on`. Every later applied operation records its movements
  in the same transaction as its domain changes. A movement's natural posting
  date is the later of its `occurred_on` and `starts_on`; when that date falls
  inside a closed period, the movement posts on the first open day after the
  latest cutoff instead. A movement keeps the posting date chosen when it
  commits; a later close never moves it again. Rejected operations roll back
  and leave no movements.

  A `close_finance_period` operation publishes every day through its cutoff:
  each newly closed day is built exactly once and stored verbatim, and later
  reads return the stored report, so closed days remain byte-for-byte stable
  across later operations, later closes, and process restarts. Days after the
  latest cutoff remain open and are computed from the movements.

  Reports are pure reads. Each day's entry brackets that day's movements with
  the position at the start and end of the day; the chain begins at the
  opening position captured on `starts_on`. Movements whose posting date was
  moved forward by a close are reported separately as late adjustments: the
  day's total movement is the ordinary value plus the late-adjustment value,
  and the balances use both. Credit that expires by the passage of time is
  projected from the lots themselves, so expiry appears even on days without
  submitted operations.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.OpeningPosition
  alias GroupStay.Finance.PeriodClose
  alias GroupStay.Finance.PublishedReport
  alias GroupStay.Finance.Start
  alias GroupStay.Groups.Backfill
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.RoomAllocation

  @cash_classifications ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)

  ## starting

  @doc """
  Enables reporting and captures the opening position. Runs inside the start
  operation's transaction, so the snapshot and the durable operation record
  commit together.
  """
  def start(starts_on, operation_id) do
    case Repo.get(Start, 1) do
      %Start{} ->
        {:error, :already_started}

      nil ->
        Backfill.backfill_all()
        snapshot_opening_positions(starts_on)
        insert_start(starts_on, operation_id)
    end
  end

  defp snapshot_opening_positions(starts_on) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    held_cash_by_property()
    |> Enum.each(fn {property_id, amount_cents} ->
      Repo.insert!(%OpeningPosition{
        scope: "cash",
        property_id: property_id,
        amount_cents: amount_cents,
        inserted_at: now,
        updated_at: now
      })
    end)

    Repo.insert!(%OpeningPosition{
      scope: "credit",
      property_id: nil,
      amount_cents: Credit.liability_cents(starts_on),
      inserted_at: now,
      updated_at: now
    })
  end

  defp held_cash_by_property do
    RoomAllocation
    |> join(:inner, [a], g in Group, on: g.group_id == a.group_id)
    |> where([a, _g], a.kind == "cash" and a.disposition == "held")
    |> group_by([_a, g], g.property_id)
    |> select([a, g], {g.property_id, sum(a.amount_cents)})
    |> Repo.all()
  end

  defp insert_start(starts_on, operation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    try do
      Repo.insert!(%Start{
        singleton: 1,
        operation_id: operation_id,
        starts_on: starts_on,
        inserted_at: now,
        updated_at: now
      })
    rescue
      # A concurrent start committed first: roll back the snapshot and let the
      # caller replay against the committed inception point.
      Ecto.ConstraintError -> Repo.rollback(:start_taken)
    end

    {:ok,
     %{
       operation_id: operation_id,
       status: "applied",
       starts_on: Date.to_iso8601(starts_on)
     }}
  end

  ## closing

  @doc """
  Closes the finance period through `period_end_on` and publishes every
  report through that day. Runs inside the close operation's transaction, so
  the published reports, the close, and the durable operation record commit
  together.
  """
  def close_period(period_end_on, operation_id) do
    start = Repo.get(Start, 1)
    last = latest_close()

    cond do
      is_nil(start) ->
        {:error, "invalid_period"}

      Date.compare(period_end_on, start.starts_on) == :lt ->
        {:error, "invalid_period"}

      not is_nil(last) and Date.compare(period_end_on, last.period_end_on) != :gt ->
        {:error, "invalid_period"}

      true ->
        publish_close(start, last, period_end_on, operation_id)
    end
  end

  defp publish_close(start, last, period_end_on, operation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    first_new_day =
      case last do
        nil -> start.starts_on
        %PeriodClose{period_end_on: last_end} -> Date.add(last_end, 1)
      end

    try do
      Repo.insert!(%PeriodClose{
        operation_id: operation_id,
        period_end_on: period_end_on,
        inserted_at: now,
        updated_at: now
      })

      publish_range(first_new_day, period_end_on, start.starts_on, now)
    rescue
      # A concurrent close committed first: roll back the publish and let the
      # caller replay against the committed cutoff.
      Ecto.ConstraintError -> Repo.rollback(:close_taken)
    end

    {:ok,
     %{
       operation_id: operation_id,
       status: "applied",
       period_end_on: Date.to_iso8601(period_end_on)
     }}
  end

  # Builds each newly closed day exactly once and stores the report verbatim.
  # Days closed by an earlier close keep their stored reports.
  defp publish_range(from, to, starts_on, now) do
    if Date.compare(from, to) != :gt do
      report = build_report(from, starts_on)

      Repo.insert!(%PublishedReport{
        report_date: from,
        data: Jason.encode!(report),
        inserted_at: now,
        updated_at: now
      })

      publish_range(Date.add(from, 1), to, starts_on, now)
    end
  end

  defp latest_close do
    PeriodClose
    |> order_by([c], desc: c.period_end_on)
    |> limit(1)
    |> Repo.one()
  end

  defp latest_cutoff do
    PeriodClose
    |> select([c], max(c.period_end_on))
    |> Repo.one()
  end

  ## recording movements

  @doc """
  Records one applied operation's movements. Does nothing before reporting
  has started; zero-amount movements are omitted.
  """
  def record_movements(_occurred_on, _operation_id, []), do: :ok

  def record_movements(occurred_on, operation_id, movements) do
    case Repo.get(Start, 1) do
      nil ->
        :ok

      %Start{starts_on: starts_on} ->
        natural = natural_posting_date(occurred_on, starts_on)
        posting_date = posting_date(natural)
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        movements
        |> Enum.reject(&zero?/1)
        |> Enum.each(fn movement ->
          Repo.insert!(movement_row(posting_date, natural, operation_id, now, movement))
        end)
    end
  end

  defp natural_posting_date(occurred_on, starts_on) do
    if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
  end

  # A movement posts on its natural date when that date is open; otherwise it
  # posts on the first open day after the latest cutoff committed at the
  # moment the operation commits.
  defp posting_date(natural) do
    case latest_cutoff() do
      nil ->
        natural

      cutoff ->
        if Date.compare(natural, cutoff) == :gt, do: natural, else: Date.add(cutoff, 1)
    end
  end

  defp zero?({:cash, _property_id, _classification, amount}), do: amount == 0
  defp zero?({:credit, _classification, amount, _lot_id}), do: amount == 0

  defp movement_row(
         posting_date,
         natural,
         operation_id,
         now,
         {:cash, property_id, classification, amount}
       ) do
    %Movement{
      posting_date: posting_date,
      natural_posting_date: natural,
      scope: "cash",
      property_id: property_id,
      classification: classification,
      amount_cents: amount,
      operation_id: operation_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp movement_row(
         posting_date,
         natural,
         operation_id,
         now,
         {:credit, classification, amount, lot_id}
       ) do
    %Movement{
      posting_date: posting_date,
      natural_posting_date: natural,
      scope: "credit",
      property_id: nil,
      classification: classification,
      amount_cents: amount,
      lot_id: lot_id,
      operation_id: operation_id,
      inserted_at: now,
      updated_at: now
    }
  end

  ## reading one day

  @doc """
  The report for one date, or `report_not_available` before reporting has
  started or for a date before the start. A closed day is served from its
  stored report; an open day is computed from the movements.
  """
  def daily_report(date) do
    case Repo.get(Start, 1) do
      nil ->
        {:error, "report_not_available"}

      %Start{starts_on: starts_on} ->
        if Date.compare(date, starts_on) == :lt do
          {:error, "report_not_available"}
        else
          case Repo.get(PublishedReport, date) do
            %PublishedReport{data: data} ->
              {:frozen, data}

            nil ->
              {:ok, report} = Repo.transaction(fn -> build_report(date, starts_on) end)
              {:ok, report}
          end
        end
    end
  end

  defp build_report(date, starts_on) do
    {cash, cash_late} = cash_section(date)
    {credit, credit_late} = credit_section(date, starts_on)

    %{
      date: Date.to_iso8601(date),
      status: report_status(date),
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: cash_late, credit: credit_late}
    }
  end

  defp report_status(date) do
    case latest_cutoff() do
      nil -> "open"
      cutoff -> if Date.compare(date, cutoff) == :gt, do: "open", else: "closed"
    end
  end

  ### cash

  # One day's entry brackets that day's movements with the position at the
  # start and end of the day. The chain begins at the opening position
  # captured on `starts_on`. Movements whose posting date was moved forward
  # by a close are reported as late adjustments; the balances use both.
  defp cash_section(date) do
    opening = opening_cash()

    rows =
      Movement
      |> where([m], m.scope == "cash" and m.posting_date <= ^date)
      |> select(
        [m],
        {m.property_id, m.classification, m.posting_date, m.amount_cents, m.natural_posting_date}
      )
      |> Repo.all()

    {entries, late_entries} =
      (Map.keys(opening) ++ Enum.map(rows, &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&cash_entry(&1, opening, rows, date))
      |> Enum.unzip()

    {Enum.reject(entries, &entry_all_zero?/1), Enum.reject(late_entries, &late_entry_all_zero?/1)}
  end

  defp opening_cash do
    OpeningPosition
    |> where([p], p.scope == "cash")
    |> select([p], {p.property_id, p.amount_cents})
    |> Repo.all()
    |> Map.new()
  end

  defp cash_entry(property_id, opening, rows, date) do
    {prior_rows, day_rows} =
      rows
      |> Enum.filter(fn {row_property_id, _classification, _posting_date, _amount, _natural} ->
        row_property_id == property_id
      end)
      |> Enum.split_with(fn {_property_id, _classification, posting_date, _amount, _natural} ->
        Date.compare(posting_date, date) == :lt
      end)

    opening_cents = Map.get(opening, property_id, 0) + net_cash(prior_rows)

    {ordinary_rows, late_rows} =
      Enum.split_with(day_rows, fn {_property_id, _classification, _posting_date, _amount,
                                    natural} ->
        not moved_by_close?(natural, date)
      end)

    closing_cents = opening_cents + net_cash(day_rows)

    {%{
       property_id: property_id,
       opening_held_cents: opening_cents,
       movements: cash_movement_map(classification_totals(ordinary_rows)),
       closing_held_cents: closing_cents
     },
     %{
       property_id: property_id,
       movements: cash_movement_map(classification_totals(late_rows))
     }}
  end

  defp cash_movement_map(values) do
    %{
      received_cents: values["received"],
      transferred_in_cents: values["transferred_in"],
      transferred_out_cents: values["transferred_out"],
      refunded_cents: values["refunded"],
      retained_cents: values["retained"],
      converted_to_credit_cents: values["converted_to_credit"],
      reduced_cents: values["reduced"],
      charged_back_cents: values["charged_back"]
    }
  end

  defp classification_totals(rows) do
    Map.new(@cash_classifications, fn classification ->
      {classification, classification_total(rows, classification)}
    end)
  end

  defp classification_total(rows, classification) do
    rows
    |> Enum.filter(fn {_property_id, row_classification, _posting_date, _amount, _natural} ->
      row_classification == classification
    end)
    |> Enum.reduce(0, fn {_property_id, _classification, _posting_date, amount, _natural}, sum ->
      sum + amount
    end)
  end

  defp net_cash(rows) do
    Enum.reduce(rows, 0, fn {_property_id, classification, _posting_date, amount, _natural},
                            acc ->
      acc + amount * cash_sign(classification)
    end)
  end

  defp cash_sign("received"), do: 1
  defp cash_sign("transferred_in"), do: 1
  defp cash_sign("transferred_out"), do: -1
  defp cash_sign(_settlement), do: -1

  defp entry_all_zero?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      late_entry_all_zero?(entry)
  end

  defp late_entry_all_zero?(entry) do
    entry.movements
    |> Map.values()
    |> Enum.all?(&(&1 == 0))
  end

  ### credit

  defp credit_section(date, starts_on) do
    rows =
      Movement
      |> where(
        [m],
        m.scope == "credit" and m.classification != "revoked" and m.posting_date <= ^date
      )
      |> select([m], {m.classification, m.posting_date, m.amount_cents, m.natural_posting_date})
      |> Repo.all()

    prior = credit_movement_sums(rows, date, :lt, :all)
    day_ordinary = credit_movement_sums(rows, date, :eq, :ordinary)
    day_late = credit_movement_sums(rows, date, :eq, :late)

    revoked_prior = revoked_liability_effect(date, :lt, :all)
    revoked_day_ordinary = revoked_liability_effect(date, :eq, :ordinary)
    revoked_day_late = revoked_liability_effect(date, :eq, :late)

    expired_prior =
      Map.get(prior, "expired", 0) + passive_expired_cents(starts_on, Date.add(date, -1))

    expired_day_ordinary =
      Map.get(day_ordinary, "expired", 0) + passive_expired_on(starts_on, date)

    expired_day_late = Map.get(day_late, "expired", 0)

    opening_cents =
      opening_liability() +
        Map.get(prior, "issued", 0) - expired_prior - Map.get(prior, "consumed", 0) -
        revoked_prior - Map.get(prior, "absorbed", 0)

    late = %{
      issued_cents: Map.get(day_late, "issued", 0),
      expired_cents: expired_day_late,
      consumed_cents: Map.get(day_late, "consumed", 0),
      revoked_cents: revoked_day_late,
      absorbed_cents: Map.get(day_late, "absorbed", 0)
    }

    issued_cents = Map.get(day_ordinary, "issued", 0)
    expired_cents = expired_day_ordinary
    consumed_cents = Map.get(day_ordinary, "consumed", 0)
    revoked_cents = revoked_day_ordinary
    absorbed_cents = Map.get(day_ordinary, "absorbed", 0)

    closing_cents =
      opening_cents +
        (issued_cents + late.issued_cents) -
        (expired_cents + late.expired_cents) -
        (consumed_cents + late.consumed_cents) -
        (revoked_cents + late.revoked_cents) -
        (absorbed_cents + late.absorbed_cents)

    {%{
       opening_liability_cents: opening_cents,
       movements: %{
         issued_cents: issued_cents,
         expired_cents: expired_cents,
         consumed_cents: consumed_cents,
         revoked_cents: revoked_cents,
         absorbed_cents: absorbed_cents
       },
       closing_liability_cents: closing_cents
     }, late}
  end

  defp opening_liability do
    case Repo.get_by(OpeningPosition, scope: "credit") do
      nil -> 0
      %OpeningPosition{amount_cents: amount_cents} -> amount_cents
    end
  end

  defp credit_movement_sums(rows, date, mode, kind) do
    rows
    |> Enum.filter(fn {_classification, posting_date, _amount, natural} ->
      posting_matches?(posting_date, date, mode) and natural_matches?(natural, date, kind)
    end)
    |> Enum.reduce(%{}, fn {classification, _posting_date, amount, _natural}, acc ->
      Map.update(acc, classification, amount, &(&1 + amount))
    end)
  end

  defp posting_matches?(posting_date, date, :lt), do: Date.compare(posting_date, date) == :lt
  defp posting_matches?(posting_date, date, :eq), do: posting_date == date

  defp natural_matches?(_natural, _date, :all), do: true
  defp natural_matches?(natural, date, :ordinary), do: not moved_by_close?(natural, date)
  defp natural_matches?(nil, _date, :late), do: false
  defp natural_matches?(natural, date, :late), do: moved_by_close?(natural, date)

  # A movement was moved forward by a close when its natural posting date
  # falls before the day it posted on.
  defp moved_by_close?(nil, _date), do: false
  defp moved_by_close?(natural, date), do: Date.compare(natural, date) == :lt

  # Revoked movements are stored with the amount removed from the lot's
  # remaining balance; only revocations posted while the lot was still
  # unexpired reduced the liability.
  defp revoked_liability_effect(date, mode, kind) do
    Movement
    |> join(:inner, [m], l in Lot, on: l.id == m.lot_id)
    |> where(
      [m, l],
      m.scope == "credit" and m.classification == "revoked" and l.expires_on > m.posting_date
    )
    |> filter_posting_date(date, mode)
    |> filter_natural_date(date, kind)
    |> select([m, _l], sum(m.amount_cents))
    |> Repo.one() || 0
  end

  defp filter_posting_date(query, date, :lt), do: where(query, [m, _l], m.posting_date < ^date)
  defp filter_posting_date(query, date, :eq), do: where(query, [m, _l], m.posting_date == ^date)

  defp filter_natural_date(query, _date, :all), do: query

  defp filter_natural_date(query, date, :ordinary),
    do:
      where(
        query,
        [m, _l],
        is_nil(m.natural_posting_date) or m.natural_posting_date >= ^date
      )

  defp filter_natural_date(query, date, :late),
    do:
      where(
        query,
        [m, _l],
        not is_nil(m.natural_posting_date) and m.natural_posting_date < ^date
      )

  # Credit that remains unspent through its expiry leaves the liability on the
  # expiry date even when no operation was submitted that day. The expired
  # portion is the balance remaining at expiry: revocations posted on or after
  # the expiry date reduced the stored balance without reducing liability, so
  # they are added back.
  defp passive_expired_cents(starts_on, date) do
    expiring_lots(starts_on)
    |> Enum.filter(fn {lot, _revoked_after_expiry} ->
      Date.compare(lot.expires_on, date) != :gt
    end)
    |> expired_portion()
  end

  defp passive_expired_on(starts_on, date) do
    expiring_lots(starts_on)
    |> Enum.filter(fn {lot, _revoked_after_expiry} ->
      Date.compare(lot.expires_on, date) == :eq
    end)
    |> expired_portion()
  end

  defp expiring_lots(starts_on) do
    revocations =
      Movement
      |> where([m], m.scope == "credit" and m.classification == "revoked")
      |> select([m], {m.lot_id, m.posting_date, m.amount_cents})
      |> Repo.all()

    Lot
    |> where([l], l.expires_on > ^starts_on)
    |> Repo.all()
    |> Enum.map(fn lot -> {lot, revoked_on_or_after_expiry(lot, revocations)} end)
  end

  defp expired_portion(entries) do
    Enum.reduce(entries, 0, fn {lot, revoked_after_expiry}, acc ->
      acc + lot.remaining_cents + revoked_after_expiry
    end)
  end

  defp revoked_on_or_after_expiry(lot, revocations) do
    revocations
    |> Enum.filter(fn {lot_id, posting_date, _amount} ->
      lot_id == lot.id and Date.compare(posting_date, lot.expires_on) != :lt
    end)
    |> Enum.reduce(0, fn {_lot_id, _posting_date, amount}, sum -> sum + amount end)
  end
end
