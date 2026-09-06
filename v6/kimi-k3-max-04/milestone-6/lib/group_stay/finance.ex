defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting: the durable reporting inception point and the
  daily report read model.

  Reporting stays off until a `start_finance_reporting` partner operation
  inserts the singleton `reporting_state` row, capturing the financial state
  immediately before that operation (held cash per property plus the credit
  liability as of `starts_on`).

  Operations applied after the start record signed `finance_movements` rows
  with their posting date (the later of `occurred_on` and `starts_on`). The
  opening position plus the recorded movements roll a report forward; credit
  expiry is synthesized at read time, so expiry appears even on days without
  partner operations.
  """

  import Ecto.Query

  alias GroupStay.Groups
  alias GroupStay.Repo

  alias GroupStay.Groups.{
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

  # --- Recording movements ---------------------------------------------------

  @doc """
  The posting date for an operation's `occurred_on` value: the later of that
  date and `starts_on`. Values that do not parse fall back to `starts_on`,
  so operations without their own date still post. Returns nil before
  reporting starts.
  """
  def posting_date(value) do
    case state() do
      nil ->
        nil

      state ->
        parsed =
          case value do
            value when is_binary(value) ->
              case Date.from_iso8601(value) do
                {:ok, date} -> date
                {:error, _} -> nil
              end

            _other ->
              nil
          end

        date = parsed || state.starts_on

        if Date.compare(date, state.starts_on) == :lt, do: state.starts_on, else: date
    end
  end

  @doc """
  Records finance movements for an applied operation: a list of
  `{scope, kind, property_id, amount_cents}` tuples (property nil for
  credit). No-op before reporting starts; zero amounts are skipped.
  """
  def record(posting_date, movements) do
    if posting_date do
      Enum.each(movements, fn {scope, kind, property_id, amount} ->
        if amount != 0 do
          Repo.insert!(%FinanceMovement{
            posting_date: posting_date,
            scope: to_string(scope),
            kind: kind,
            property_id: property_id,
            amount_cents: amount
          })
        end
      end)
    end

    :ok
  end

  # --- Reading the daily report ----------------------------------------------

  @doc """
  Builds the daily report for `date`, or `:not_available` before reporting
  starts or for a date before `starts_on`. Reading never changes any state.
  """
  def daily_report(date) do
    case state() do
      nil ->
        :not_available

      state ->
        if Date.compare(date, state.starts_on) == :lt do
          :not_available
        else
          %{
            status: "open",
            date: Date.to_string(date),
            cash: cash_entry_list(state, date),
            credit: credit_report(state, date)
          }
        end
    end
  end

  # --- Cash report -------------------------------------------------------------

  defp cash_entry_list(state, date) do
    rows = movements("cash", date)

    properties =
      (Map.keys(state.opening_cash) ++ Enum.map(rows, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    properties
    |> Enum.map(&cash_entry(state, &1, rows, date))
    |> Enum.reject(&all_zero?/1)
  end

  defp cash_entry(state, property, rows, date) do
    relevant = Enum.filter(rows, &(&1.property_id == property))

    {before, day} =
      Enum.split_with(relevant, fn row -> Date.compare(row.posting_date, date) == :lt end)

    delta = Enum.sum(Enum.map(before, &signed_cash/1))
    opening = Map.get(state.opening_cash, property, 0) + delta
    day_bucket = bucket(@cash_kinds, day)
    closing = opening + Enum.sum(Enum.map(day, &signed_cash/1))

    %{
      property_id: property,
      opening_held_cents: opening,
      movements: %{
        received_cents: day_bucket["received"],
        transferred_in_cents: day_bucket["transferred_in"],
        transferred_out_cents: day_bucket["transferred_out"],
        refunded_cents: day_bucket["refunded"],
        retained_cents: day_bucket["retained"],
        converted_to_credit_cents: day_bucket["converted_to_credit"],
        reduced_cents: day_bucket["reduced"],
        charged_back_cents: day_bucket["charged_back"]
      },
      closing_held_cents: closing
    }
  end

  defp bucket(kinds, rows) do
    base = Map.new(kinds, &{&1, 0})

    Enum.reduce(rows, base, fn row, acc ->
      Map.update!(acc, row.kind, &(&1 + row.amount_cents))
    end)
  end

  defp all_zero?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end)
  end

  # --- Credit report -------------------------------------------------------------

  defp credit_report(state, date) do
    rows = movements("credit", date)

    before = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :lt))
    day = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :eq))

    opening =
      state.opening_credit_liability_cents +
        sum_kind(before, "issued") - sum_kind(before, "consumed") - sum_kind(before, "revoked") -
        sum_kind(before, "absorbed") -
        expired_amount(state.starts_on, date, :before)

    day_expired = expired_amount(state.starts_on, date, :on)
    day_bucket = bucket(@credit_kinds, day)

    closing =
      opening +
        day_bucket["issued"] - day_expired - day_bucket["consumed"] - day_bucket["revoked"] -
        day_bucket["absorbed"]

    %{
      opening_liability_cents: opening,
      movements: %{
        issued_cents: day_bucket["issued"],
        expired_cents: day_expired,
        consumed_cents: day_bucket["consumed"],
        revoked_cents: day_bucket["revoked"],
        absorbed_cents: day_bucket["absorbed"]
      },
      closing_liability_cents: closing
    }
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
  # the following day. The expiry movement is synthesized at read time from
  # the lots' current availability, so it shows even on days without partner
  # operations. Lots already expired when reporting started were already out
  # of the opening liability, so only lots expiring on or after `starts_on`
  # are synthesized.
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
