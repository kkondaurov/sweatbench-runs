defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting.

  The first applied `start_finance_reporting` operation enables reporting and
  captures the opening position on `starts_on`: every property's held cash and
  the company-wide credit liability, evaluated as of `starts_on`, including
  every operation already committed regardless of its `occurred_on`.

  Every later applied operation records its finance effects as movements
  posted on the latest of its `occurred_on`, `starts_on`, and the day after
  the latest period close cutoff at the moment the operation commits.
  Movements commit with the operation's domain changes, so rejections leave no
  movement and retries never report one twice. An operation keeps the posting
  date chosen when it commits; a later close never moves it again.

  A `close_finance_period` operation publishes every report through its
  cutoff: each day is built as of the close and stored as a snapshot that is
  served byte-for-byte stable from then on. Days after the latest cutoff stay
  open and are read-only recomputations: reading them in any order, or reading
  one repeatedly, never changes a report or any domain state. Credit that
  expires without a partner operation is derived from the lots themselves, so
  later submissions can change earlier open reports.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.Close
  alias GroupStay.Finance.ClosedReport
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

  ## Closing

  @doc """
  Closes the finance period through `period_end_on`.

  The close applies only when reporting has started, `period_end_on` is on or
  after `starts_on`, and it is strictly later than the latest successful
  close; otherwise it returns `{:error, :invalid_period}`.

  An applied close publishes every report from `starts_on` through
  `period_end_on`: each day not already closed is built as of the close and
  stored as a snapshot that remains byte-for-byte stable across later
  operations, later closes, and process restarts.
  """
  def close_period(operation_id, period_end_on) do
    case current_start() do
      nil ->
        {:error, :invalid_period}

      start ->
        case latest_close_cutoff() do
          nil ->
            do_close(start, operation_id, period_end_on)

          cutoff ->
            if Date.compare(period_end_on, cutoff) == :gt do
              do_close(start, operation_id, period_end_on)
            else
              {:error, :invalid_period}
            end
        end
    end
  end

  defp do_close(start, operation_id, period_end_on) do
    if Date.compare(period_end_on, start.starts_on) == :lt do
      {:error, :invalid_period}
    else
      %Close{}
      |> Changeset.change(%{operation_id: operation_id, period_end_on: period_end_on})
      |> Changeset.unique_constraint(:period_end_on)
      |> Repo.insert()
      |> case do
        {:ok, close} ->
          snapshot_closed_reports(start, period_end_on)
          {:ok, close}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :period_end_on) do
            {:error, :invalid_period}
          else
            raise "unexpected failure closing finance period"
          end
      end
    end
  end

  # Builds and stores every report from starts_on through the cutoff that is
  # not already closed, as of the moment the close is processed. Operations
  # earlier in the same batch are already committed and therefore visible.
  defp snapshot_closed_reports(start, period_end_on) do
    movements = Repo.all(Movement)
    lots = Repo.all(Lot)
    existing = MapSet.new(Repo.all(from c in ClosedReport, select: c.date))

    start.starts_on
    |> Date.range(period_end_on)
    |> Enum.each(fn date ->
      unless MapSet.member?(existing, date) do
        report = build_report(start, date, "closed", movements, lots)
        Repo.insert!(%ClosedReport{date: date, data: Jason.encode!(report)})
      end
    end)
  end

  defp latest_close_cutoff do
    Repo.one(from c in Close, select: max(c.period_end_on))
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
        natural =
          if Date.compare(occurred_on, start.starts_on) == :gt,
            do: occurred_on,
            else: start.starts_on

        {posted_on, late} = posting_date(natural)

        Repo.insert!(%Movement{
          operation_id: operation_id,
          posted_on: posted_on,
          kind: kind,
          classification: classification,
          amount_cents: amount_cents,
          property_id: fields[:property_id],
          credit_lot_id: fields[:credit_lot_id],
          late: late
        })

        compensate_expired(start, kind, classification, amount_cents, fields[:credit_lot_id],
          operation_id: operation_id,
          posted_on: posted_on,
          late: late
        )

        :ok
    end
  end

  # The reporting posting date is the latest of the natural date and the day
  # after the latest cutoff at the moment the operation commits. A movement
  # whose posting date is moved forward is marked late and keeps that posting
  # date forever; a later close never moves it again.
  defp posting_date(natural) do
    case latest_close_cutoff() do
      nil ->
        {natural, false}

      cutoff ->
        floor = Date.add(cutoff, 1)

        if Date.compare(natural, floor) == :lt do
          {floor, true}
        else
          {natural, false}
        end
    end
  end

  # Derived expiry removes a lot's report-time remaining balance on the lot's
  # expiry date. When a movement that changes that balance posts on or after
  # the expiry date, the balance has already been expired in report time, so a
  # compensating expired movement keeps the liability correct on the posting
  # date:
  #
  # - an applied amount re-enters the liability as credit applied to an active
  #   group (negative expired);
  # - a restored amount returns to a lot that is already expired and leaves
  #   the liability (positive expired);
  # - a revoked amount was already expired, so the revocation removes nothing
  #   (negative expired).
  defp compensate_expired(start, "credit", classification, amount_cents, lot_id, opts)
       when classification in ["applied", "restored", "revoked"] and not is_nil(lot_id) do
    posted_on = Keyword.fetch!(opts, :posted_on)

    with %Lot{} = lot <- Repo.get(Lot, lot_id),
         {:ok, expiry_date} <- expiry_date_for(lot, start),
         true <- Date.compare(posted_on, expiry_date) != :lt do
      amount = if classification == "restored", do: amount_cents, else: -amount_cents

      Repo.insert!(%Movement{
        operation_id: Keyword.fetch!(opts, :operation_id),
        posted_on: posted_on,
        kind: "credit",
        classification: "expired",
        amount_cents: amount,
        credit_lot_id: lot_id,
        late: Keyword.fetch!(opts, :late)
      })
    else
      _other -> :ok
    end
  end

  defp compensate_expired(_start, _kind, _classification, _amount_cents, _lot_id, _opts), do: :ok

  # The report-time expiry date of a lot, mirroring the derived expiry used
  # when reading a day: the lot's own expiry when it falls after `starts_on`,
  # otherwise `starts_on` for a lot issued after reporting started. Lots
  # issued before reporting started and already expired at `starts_on` never
  # entered the reported liability and have no report-time expiry.
  defp expiry_date_for(lot, start) do
    cond do
      Date.compare(lot.expires_on, start.starts_on) == :gt ->
        {:ok, lot.expires_on}

      Repo.exists?(
        from m in Movement,
          where:
            m.kind == "credit" and m.classification == "issued" and
                m.credit_lot_id == ^lot.id
      ) ->
        {:ok, start.starts_on}

      true ->
        :error
    end
  end

  ## Reading one day

  @doc """
  Returns the daily report for `date`, or `{:error, :report_not_available}`
  before reporting has started or for a date before `starts_on`.

  Days through the latest close cutoff are served from their stored snapshot;
  later days are open and recomputed.
  """
  def daily_report(date) do
    case current_start() do
      nil ->
        {:error, :report_not_available}

      start ->
        if Date.compare(date, start.starts_on) == :lt do
          {:error, :report_not_available}
        else
          case Repo.get(ClosedReport, date) do
            nil ->
              status = if closed_date?(date), do: "closed", else: "open"
              {:ok, build_report(start, date, status, Repo.all(Movement), Repo.all(Lot))}

            closed ->
              {:ok, Jason.decode!(closed.data)}
          end
        end
    end
  end

  defp closed_date?(date) do
    case latest_close_cutoff() do
      nil -> false
      cutoff -> Date.compare(date, cutoff) != :gt
    end
  end

  defp build_report(start, date, status, movements, lots) do
    cash = Enum.filter(movements, &(&1.kind == "cash"))
    credit = Enum.filter(movements, &(&1.kind == "credit"))

    {cash_entries, late_cash} = cash_section(start, cash, date)
    {credit_entry, late_credit} = credit_section(start, credit, lots, date)

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash_entries,
      credit: credit_entry,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  # Ordinary movements are those whose posting date was not moved forward by
  # a close; late movements are reported in the late_adjustments block. The
  # day's total movement per classification is the ordinary value plus the
  # late-adjustment value, and opening and closing balances use both.
  defp cash_section(start, cash, date) do
    opening =
      Enum.reduce(cash, start.opening_held_cents, fn movement, acc ->
        if Date.compare(movement.posted_on, date) == :lt do
          effect = cash_effect(movement)
          Map.update(acc, movement.property_id, effect, &(&1 + effect))
        else
          acc
        end
      end)

    day = Enum.filter(cash, &(Date.compare(&1.posted_on, date) == :eq))
    normal_by_property = cash_by_property(Enum.reject(day, & &1.late))
    late_by_property = cash_by_property(Enum.filter(day, & &1.late))

    entries =
      (Map.keys(opening) ++ Map.keys(normal_by_property) ++ Map.keys(late_by_property))
      |> Enum.uniq()
      |> Enum.map(fn property_id ->
        opening_cents = Map.get(opening, property_id, 0)
        normal = Map.get(normal_by_property, property_id, %{})
        late = Map.get(late_by_property, property_id, %{})

        %{
          property_id: property_id,
          opening_held_cents: opening_cents,
          movements: movement_values(normal, @cash_columns),
          closing_held_cents: opening_cents + cash_net(normal) + cash_net(late)
        }
      end)
      |> Enum.filter(fn entry ->
        entry.opening_held_cents != 0 or entry.closing_held_cents != 0 or
          Enum.any?(Map.values(entry.movements), &(&1 != 0)) or
          Enum.any?(Map.values(Map.get(late_by_property, entry.property_id, %{})), &(&1 != 0))
      end)
      |> Enum.sort_by(& &1.property_id)

    late_entries =
      late_by_property
      |> Enum.map(fn {property_id, late} ->
        %{property_id: property_id, movements: movement_values(late, @cash_columns)}
      end)
      |> Enum.filter(fn entry -> Enum.any?(Map.values(entry.movements), &(&1 != 0)) end)
      |> Enum.sort_by(& &1.property_id)

    {entries, late_entries}
  end

  defp cash_by_property(movements) do
    Enum.reduce(movements, %{}, fn movement, acc ->
      entry = Map.get(acc, movement.property_id, %{})

      entry =
        Map.update(entry, movement.classification, movement.amount_cents, fn amount ->
          amount + movement.amount_cents
        end)

      Map.put(acc, movement.property_id, entry)
    end)
  end

  defp movement_values(day, columns) do
    Map.new(columns, fn {classification, key} ->
      {key, Map.get(day, classification, 0)}
    end)
  end

  defp cash_net(day) do
    Enum.reduce(day, 0, fn {classification, amount}, acc ->
      acc + Map.fetch!(@cash_signs, classification) * amount
    end)
  end

  defp cash_effect(movement) do
    Map.fetch!(@cash_signs, movement.classification) * movement.amount_cents
  end

  defp credit_section(start, credit, lots, date) do
    all_credit =
      credit
      |> Enum.filter(&Map.has_key?(@credit_columns, &1.classification))
      |> Enum.map(&Map.take(&1, [:posted_on, :classification, :amount_cents, :late]))
      |> Kernel.++(derived_expiry_movements(start, credit, lots))

    opening =
      Enum.reduce(all_credit, start.opening_liability_cents, fn movement, acc ->
        if Date.compare(movement.posted_on, date) == :lt do
          acc + credit_effect(movement)
        else
          acc
        end
      end)

    day = Enum.filter(all_credit, &(Date.compare(&1.posted_on, date) == :eq))
    normal_sums = credit_sums(Enum.reject(day, &Map.get(&1, :late, false)))
    late_sums = credit_sums(Enum.filter(day, &Map.get(&1, :late, false)))

    entry = %{
      opening_liability_cents: opening,
      movements: movement_values(normal_sums, @credit_columns),
      closing_liability_cents: opening + credit_net(normal_sums) + credit_net(late_sums)
    }

    {entry, movement_values(late_sums, @credit_columns)}
  end

  defp credit_sums(movements) do
    Enum.reduce(movements, %{}, fn movement, acc ->
      Map.update(acc, movement.classification, movement.amount_cents, fn amount ->
        amount + movement.amount_cents
      end)
    end)
  end

  defp credit_net(day) do
    Enum.reduce(day, 0, fn {classification, amount}, acc ->
      acc + credit_effect(%{classification: classification, amount_cents: amount})
    end)
  end

  # Issued liability enters; expiry, consumption, revocation, and shortfall
  # absorption move it out.
  defp credit_effect(%{classification: "issued", amount_cents: amount}), do: amount
  defp credit_effect(%{amount_cents: amount}), do: -amount

  # Credit that remains unused through its expiry leaves the liability on the
  # expiry date even when no partner operation was submitted that day. The
  # expired amount is the lot's remaining balance in report time: movements
  # posted on or after the expiry date are reversed out of the current
  # remaining balance so later submissions change earlier open reports. A
  # movement whose posting date was moved past the expiry date by a close is
  # reversed the same way, which keeps a closed expiry stable.
  defp derived_expiry_movements(start, credit, lots) do
    issued_lot_ids =
      credit
      |> Enum.filter(&(&1.classification == "issued"))
      |> MapSet.new(& &1.credit_lot_id)

    credit_by_lot = Enum.group_by(credit, & &1.credit_lot_id)

    Enum.flat_map(lots, fn lot ->
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
