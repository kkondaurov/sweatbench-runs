defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting: the durable reporting inception point, the daily
  report read model, and period close.

  Reporting stays off until a `start_finance_reporting` partner operation
  inserts the singleton `reporting_state` row, capturing the financial state
  immediately before that operation (held cash per property plus the credit
  liability as of `starts_on`).

  Operations applied after the start record signed `finance_movements` rows
  with their posting date: the latest of `occurred_on`, `starts_on`, and the
  day after the latest close cutoff. A movement flagged `late` when its
  posting date was moved forward by a committed close reports in the
  current day's `late_adjustments` block instead of the ordinary movement
  columns; balances use both.

  A period close computes and stores the report for every date through its
  cutoff in `closed_reports`; a closed day's `data` value is then served
  byte-for-byte identically. Credit expiry is synthesized at compute time,
  so closing captures it exactly once.
  """

  import Ecto.Query

  alias GroupStay.Groups
  alias GroupStay.Repo

  alias GroupStay.Groups.{
    ClosedReport,
    CreditLot,
    FinanceMovement,
    Group,
    ReportingState
  }

  @cash_increase ~w(received transferred_in)
  @cash_kinds @cash_increase ++
                ~w(transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  # --- Reporting state -------------------------------------------------------

  @doc "Returns the singleton reporting state row, or nil before reporting."
  def state, do: Repo.one(from s in ReportingState, limit: 1)

  @doc """
  Captures the opening position and starts reporting for `starts_on`: held
  cash per property plus the credit liability as of the start date.
  """
  def start!(starts_on) do
    opening_cash =
      Group
      |> where([g], g.status == "active")
      |> group_by(:property_id)
      |> select([g], {g.property_id, coalesce(sum(g.cash_paid_cents), 0)})
      |> Repo.all()
      |> Map.new(fn {property, amount} -> {property, amount} end)

    liability = Groups.credit_liability(starts_on)

    %ReportingState{
      id: "current",
      starts_on: starts_on,
      opening_cash: opening_cash,
      opening_credit_liability_cents: liability
    }
    |> Repo.insert!()
  end

  # --- Closing the period ----------------------------------------------------

  @doc """
  Publishes every report date from `starts_on` through `period_end_on`:
  each not-yet-frozen day's `data` is computed now and stored durably, then
  `closed_through` advances to the cutoff. Later closes recompute nothing.
  """
  def close!(period_end_on) do
    state = state()

    state.starts_on
    |> Date.range(period_end_on)
    |> Enum.each(fn date ->
      if Repo.get_by(ClosedReport, date: date) == nil do
        %ClosedReport{date: date, data: compute(state, date, "closed")}
        |> Repo.insert!()
      end
    end)

    state
    |> Ecto.Changeset.change(closed_through: period_end_on)
    |> Repo.update!()

    :ok
  end

  # --- Recording movements ----------------------------------------------------

  @doc """
  The posting date for an operation's `occurred_on` value, plus whether a
  committed close moved the date forward: the latest of `occurred_on`,
  `starts_on`, and the day after the latest close cutoff. Values that do not
  parse fall back to `starts_on`, so operations without their own date still
  post. Returns nil before reporting starts.

  `{posting_date, late?}`: the date together with a flag marking that a
  close boundary (not the reporting start or an unparseable fallback) pushed
  the date forward.
  """
  def posting_detail(value) do
    case state() do
      nil ->
        nil

      state ->
        base = parse(value) || state.starts_on

        candidates =
          [state.starts_on] ++
            if(state.closed_through, do: [Date.add(state.closed_through, 1)], else: [])

        posting = latest([base | candidates])
        first_open = state.closed_through && Date.add(state.closed_through, 1)

        late? = first_open != nil and posting == first_open and posting != base

        {posting, late?}
    end
  end

  defp parse(value) do
    case value do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _} -> nil
        end

      _other ->
        nil
    end
  end

  defp latest(dates) do
    Enum.reduce(dates, fn date, acc ->
      if Date.compare(date, acc) == :gt, do: date, else: acc
    end)
  end

  @doc """
  Records finance movements for an applied operation: a `{posting_date,
  late?}` detail plus a list of `{scope, kind, property_id, amount_cents}`
  tuples (property nil for credit). No-op before reporting starts; zero
  amounts are skipped. The late flag is shared by all movements the
  operation reports.
  """
  def record({posting_date, late?}, movements) do
    if posting_date do
      Enum.each(movements, fn {scope, kind, property_id, amount} ->
        if amount != 0 do
          Repo.insert!(%FinanceMovement{
            posting_date: posting_date,
            scope: to_string(scope),
            kind: kind,
            property_id: property_id,
            amount_cents: amount,
            late: late?
          })
        end
      end)
    end

    :ok
  end

  # --- Reading the daily report ----------------------------------------------

  @doc """
  Builds the daily report for `date`, or `:not_available` before reporting
  starts or for a date before `starts_on`. A date closed by a period close
  serves its stored `data` byte-for-byte; open days compute live with
  `status: "open"`. Reading never changes any state.
  """
  def daily_report(date) do
    case state() do
      nil ->
        :not_available

      state ->
        if Date.compare(date, state.starts_on) == :lt do
          :not_available
        else
          if closed?(state, date) do
            case Repo.get_by(ClosedReport, date: date) do
              %ClosedReport{} = frozen -> frozen.data
              nil -> compute(state, date, "closed")
            end
          else
            compute(state, date, "open")
          end
        end
    end
  end

  defp closed?(state, date) do
    state.closed_through != nil and
      Date.compare(date, state.closed_through) != :gt
  end

  # --- Report computation ------------------------------------------------------

  defp compute(state, date, status) do
    {cash, late_cash} = cash_report(state, date)
    {credit, late_credit} = credit_report(state, date)

    %{
      status: status,
      date: Date.to_string(date),
      cash: cash,
      credit: credit,
      late_adjustments: %{
        cash: late_cash,
        credit: %{
          issued_cents: late_credit["issued"],
          expired_cents: late_credit["expired"],
          consumed_cents: late_credit["consumed"],
          revoked_cents: late_credit["revoked"],
          absorbed_cents: late_credit["absorbed"]
        }
      }
    }
  end

  # --- Cash report -------------------------------------------------------------

  # Each property reports its ordinary bucket alongside its late bucket; the
  # main entry keeps exactly the documented keys and the late bucket feeds
  # the late-adjustments block.
  defp cash_report(state, date) do
    rows = movements("cash", date)

    properties =
      (Map.keys(state.opening_cash) ++ Enum.map(rows, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    properties
    |> Enum.map(&cash_entry(state, &1, rows, date))
    |> Enum.reject(&zero_property?/1)
    |> Enum.reduce({[], []}, fn {entry, late_bucket}, {entries, late_entries} ->
      entry = Map.delete(entry, :late_bucket)
      late_entry = late_adjustment(entry, late_bucket)

      late_entries =
        if Enum.all?(late_bucket, fn {_kind, amount} -> amount == 0 end) do
          late_entries
        else
          [late_entry | late_entries]
        end

      {[entry | entries], late_entries}
    end)
    |> then(fn {entries, late_entries} ->
      {Enum.reverse(entries), Enum.reverse(late_entries)}
    end)
  end

  defp late_adjustment(%{property_id: property}, bucket) do
    %{
      property_id: property,
      movements: %{
        received_cents: bucket["received"],
        transferred_in_cents: bucket["transferred_in"],
        transferred_out_cents: bucket["transferred_out"],
        refunded_cents: bucket["refunded"],
        retained_cents: bucket["retained"],
        converted_to_credit_cents: bucket["converted_to_credit"],
        reduced_cents: bucket["reduced"],
        charged_back_cents: bucket["charged_back"]
      }
    }
  end

  # A property reports only when its balances or either movement bucket hold
  # a non-zero classification.
  defp zero_property?({entry, late_bucket}) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end) and
      Enum.all?(late_bucket, fn {_kind, amount} -> amount == 0 end)
  end

  defp cash_entry(state, property, rows, date) do
    relevant = Enum.filter(rows, &(&1.property_id == property))

    {before, day} =
      Enum.split_with(relevant, fn row -> Date.compare(row.posting_date, date) == :lt end)

    delta = Enum.sum(Enum.map(before, &signed_cash/1))
    opening = Map.get(state.opening_cash, property, 0) + delta

    {ordinary, late} = Enum.split_with(day, &(not &1.late))

    ordinary_bucket = bucket(@cash_kinds, ordinary)
    late_bucket = bucket(@cash_kinds, late)

    closing =
      opening + Enum.sum(Enum.map(ordinary, &signed_cash/1)) +
        Enum.sum(Enum.map(late, &signed_cash/1))

    {%{
       property_id: property,
       opening_held_cents: opening,
       movements: %{
         received_cents: ordinary_bucket["received"],
         transferred_in_cents: ordinary_bucket["transferred_in"],
         transferred_out_cents: ordinary_bucket["transferred_out"],
         refunded_cents: ordinary_bucket["refunded"],
         retained_cents: ordinary_bucket["retained"],
         converted_to_credit_cents: ordinary_bucket["converted_to_credit"],
         reduced_cents: ordinary_bucket["reduced"],
         charged_back_cents: ordinary_bucket["charged_back"]
       },
       late_bucket: late_bucket,
       closing_held_cents: closing
     }, late_bucket}
  end

  defp bucket(kinds, rows) do
    base = Map.new(kinds, &{&1, 0})

    Enum.reduce(rows, base, fn row, acc ->
      Map.update!(acc, row.kind, &(&1 + row.amount_cents))
    end)
  end

  # --- Credit report -------------------------------------------------------------

  # The late adjustments credit block is always present, even when every
  # classification is zero; expiry is synthesized at compute time and never
  # classifies as late.
  defp credit_report(state, date) do
    rows = movements("credit", date)

    before = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :lt))
    day = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :eq))

    {ordinary, late} = Enum.split_with(day, &(not &1.late))

    opening =
      state.opening_credit_liability_cents +
        sum_kind(before, "issued") - sum_kind(before, "consumed") - sum_kind(before, "revoked") -
        sum_kind(before, "absorbed") -
        expired_amount(state.starts_on, date, :before)

    day_expired = expired_amount(state.starts_on, date, :on)
    ordinary_bucket = bucket(@credit_kinds, ordinary)
    late_bucket = bucket(@credit_kinds, late)

    closing =
      opening +
        ordinary_bucket["issued"] + late_bucket["issued"] - day_expired -
        ordinary_bucket["consumed"] - late_bucket["consumed"] - ordinary_bucket["revoked"] -
        late_bucket["revoked"] - ordinary_bucket["absorbed"] - late_bucket["absorbed"]

    credit = %{
      opening_liability_cents: opening,
      movements: %{
        issued_cents: ordinary_bucket["issued"],
        expired_cents: day_expired,
        consumed_cents: ordinary_bucket["consumed"],
        revoked_cents: ordinary_bucket["revoked"],
        absorbed_cents: ordinary_bucket["absorbed"]
      },
      closing_liability_cents: closing
    }

    {credit, late_bucket}
  end

  # --- Helpers -----------------------------------------------------------------

  defp movements(scope, date) do
    FinanceMovement
    |> where([m], m.scope == ^scope and m.posting_date <= ^date)
    |> Repo.all()
  end

  defp sum_kind(rows, kind) do
    rows
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  defp signed_cash(%{kind: kind, amount_cents: amount}) do
    if kind in @cash_increase, do: amount, else: -amount
  end

  # Credit that remains available through its `expires_on` date expires on
  # the following day. The expiry movement is synthesized at compute time
  # from the lots' current availability, so it shows even on days without
  # partner operations; closing a period captures it once, durably. Lots
  # already expired when reporting started were already out of the opening
  # liability, so only lots expiring on or after `starts_on` are synthesized.
  defp expired_amount(starts_on, date, relation) do
    CreditLot
    |> where([l], l.expires_on >= ^starts_on and l.available_cents > 0)
    |> select([l], {l.expires_on, l.available_cents})
    |> Repo.all()
    |> Enum.filter(fn {expires_on, _amount} ->
      expiry = Date.add(expires_on, 1)

      case relation do
        :before -> Date.compare(expiry, date) == :lt
        :on -> Date.compare(expiry, date) == :eq
      end
    end)
    |> Enum.map(fn {_expires_on, amount} -> amount end)
    |> Enum.sum()
  end
end
