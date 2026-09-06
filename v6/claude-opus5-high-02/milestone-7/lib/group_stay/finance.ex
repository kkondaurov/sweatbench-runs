defmodule GroupStay.Finance do
  @moduledoc """
  Finance reporting: where reporting starts, what each operation posts, and what a day reports.

  Reporting has one inception point and a moving cutoff. Until a `start_finance_reporting`
  operation is applied, nothing is reported and nothing is recorded; the state standing immediately
  before that operation becomes the opening position on its `starts_on`. From then on every
  operation records the finance effects it has, stamped with its posting date - the later of the
  operation's `occurred_on` and `starts_on` - so an operation dated before reporting began still
  posts on the first reported day.

  A `close_finance_period` operation publishes every report through its cutoff. Published figures
  never move again, which is why an operation processed after a close posts on the first open day
  unless it was already dated there. Nothing else about the operation changes: the group, ledger,
  payment, and stored-result views keep stating current state.

  Movements are only ever inserted, and always inside the transaction of the operation that caused
  them, so a rejected operation records nothing and a durable retry records nothing a second time.
  A report is an aggregation of the rows standing when it is read, which is why a later submission
  can change an open day and why reading a report never changes anything. A closed day is stable
  because nothing can post into it any more, not because it was written down.
  """

  import Ecto.Query

  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.PeriodClose
  alias GroupStay.Finance.Posting
  alias GroupStay.Finance.Report
  alias GroupStay.Finance.ReportingStart
  alias GroupStay.Partner.Operation
  alias GroupStay.Repo
  alias GroupStay.Reservations.CashAllocation
  alias GroupStay.Reservations.Credit
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Group

  @doc """
  The date reporting started on, or `nil` while it has not started.
  """
  def starts_on do
    Repo.one(from r in ReportingStart, order_by: [asc: r.id], limit: 1, select: r.starts_on)
  end

  @doc """
  The latest cutoff a close has published through, or `nil` while no period has been closed.
  """
  def latest_cutoff do
    Repo.one(from c in PeriodClose, select: max(c.period_end_on))
  end

  @doc """
  Where an operation's finance effects post, decided once, at the moment the operation commits.

  An operation that happened before reporting began still posts on the first reported day, because
  everything before that day is already stated in the opening position. An operation that happened
  inside a period a close has already published posts on the first open day instead, because a
  published figure never moves; it lands there as a late adjustment. A later close never moves it
  again, since the posting is written onto every movement the operation records.
  """
  def posting(%Operation{occurred_on: occurred_on}) do
    case starts_on() do
      nil ->
        Posting.none()

      starts_on ->
        natural = Enum.max([occurred_on, starts_on], Date)
        date = Enum.max([natural, first_open_day(starts_on)], Date)

        %Posting{date: date, late: Date.compare(date, natural) == :gt}
    end
  end

  # The earliest day nothing has been published for: the day after the latest cutoff, or the first
  # reported day while no period has been closed.
  defp first_open_day(starts_on) do
    case latest_cutoff() do
      nil -> starts_on
      cutoff -> Date.add(cutoff, 1)
    end
  end

  @doc """
  Starts finance reporting and states the opening position on `starts_on`.

  Returns `{:ok, %{starts_on: date}}`, or `{:error, code}` when reporting has already started or
  the operation does not carry a usable date.
  """
  def start(%Operation{} = operation) do
    with :ok <- ensure_not_started(),
         {:ok, starts_on} <- validate_starts_on(operation.data["starts_on"]) do
      Repo.insert!(%ReportingStart{starts_on: starts_on, operation_id: operation.operation_id})
      record_opening(starts_on)

      {:ok, %{starts_on: starts_on}}
    end
  end

  defp ensure_not_started do
    if Repo.exists?(ReportingStart), do: {:error, :reporting_already_started}, else: :ok
  end

  defp validate_starts_on(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_reporting_date}
    end
  end

  defp validate_starts_on(_value), do: {:error, :invalid_reporting_date}

  # The opening position is stated the day before reporting starts, so that it counts towards the
  # opening balance of every reported day without ever being a movement on one of them.
  defp record_opening(starts_on) do
    opening = %Posting{date: Date.add(starts_on, -1), late: false}

    for {property_id, cents} <- held_cash_by_property() do
      record(opening, Movement.cash(), "opening", cents, property_id: property_id)
    end

    record(opening, Movement.credit(), "opening", Credit.liability_cents(starts_on))

    # Lots that have already expired are settled history: only a lot that can still expire on a
    # reported day needs its balance brought forward.
    for lot <- unexpired_lots(starts_on) do
      record(opening, Movement.lot(), "balance", lot.remaining_cents, credit_lot_id: lot.id)
    end

    :ok
  end

  defp held_cash_by_property do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.status == ^CashAllocation.held(),
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
  end

  defp unexpired_lots(starts_on) do
    Repo.all(from l in CreditLot, where: l.expires_on >= ^starts_on and l.remaining_cents > 0)
  end

  ## Closing a period

  @doc """
  Publishes every report through `period_end_on`.

  Returns `{:ok, %{period_end_on: date}}`, or `{:error, :invalid_period}` when reporting has not
  started, the cutoff falls before reporting began, the operation does not carry a usable date, or
  the cutoff does not move the published period forward.
  """
  def close(%Operation{} = operation) do
    with {:ok, period_end_on} <- validate_period_end_on(operation.data["period_end_on"]),
         :ok <- ensure_closable(period_end_on) do
      Repo.insert!(%PeriodClose{
        period_end_on: period_end_on,
        operation_id: operation.operation_id
      })

      {:ok, %{period_end_on: period_end_on}}
    end
  end

  defp validate_period_end_on(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_period}
    end
  end

  defp validate_period_end_on(_value), do: {:error, :invalid_period}

  # There is nothing to publish before reporting begins, a cutoff before the first reported day
  # would publish nothing, and a cutoff that does not move forward would republish figures that
  # are already published.
  defp ensure_closable(period_end_on) do
    if closable?(period_end_on), do: :ok, else: {:error, :invalid_period}
  end

  defp closable?(period_end_on) do
    case starts_on() do
      nil -> false
      starts_on -> Date.compare(period_end_on, starts_on) != :lt and moves_forward?(period_end_on)
    end
  end

  defp moves_forward?(period_end_on) do
    case latest_cutoff() do
      nil -> true
      cutoff -> Date.compare(period_end_on, cutoff) == :gt
    end
  end

  ## Recording movements

  @doc """
  Records held cash moving at one property.
  """
  def record_cash(posting, property_id, kind, amount_cents),
    do: record(posting, Movement.cash(), kind, amount_cents, property_id: property_id)

  @doc """
  Records hotel-credit liability moving.
  """
  def record_credit(posting, kind, amount_cents),
    do: record(posting, Movement.credit(), kind, amount_cents)

  @doc """
  Records a change to what a credit lot holds outside the rooms it funds.

  Lot rows carry no liability of their own. They are the record a lot's expiry is derived from,
  because credit left unused through its `expires_on` expires the next day whether or not the
  partner submitted anything.
  """
  def record_lot(posting, %CreditLot{} = lot, amount_cents),
    do: record(posting, Movement.lot(), "balance", amount_cents, credit_lot_id: lot.id)

  # Nothing is recorded before reporting starts, and an effect of no cents is not a movement.
  defp record(posting, scope, kind, amount_cents, attrs \\ [])

  defp record(%Posting{date: nil}, _scope, _kind, _amount_cents, _attrs), do: :ok
  defp record(_posting, _scope, _kind, 0, _attrs), do: :ok

  defp record(%Posting{} = posting, scope, kind, amount_cents, attrs) do
    Repo.insert!(
      struct!(
        %Movement{
          posting_date: posting.date,
          late: posting.late,
          scope: scope,
          kind: kind,
          amount_cents: amount_cents
        },
        attrs
      )
    )

    :ok
  end

  ## Reading a report

  @doc """
  The report for one date.

  Returns `{:error, :report_not_available}` while reporting has not started and for any date
  before it started.
  """
  def daily_report(%Date{} = date) do
    case starts_on() do
      nil -> {:error, :report_not_available}
      starts_on -> available_report(date, starts_on)
    end
  end

  defp available_report(date, starts_on) do
    if Date.compare(date, starts_on) == :lt do
      {:error, :report_not_available}
    else
      {:ok, Report.build(date, status(date))}
    end
  end

  # A day through the latest cutoff is published, and stays published: cutoffs only move forward.
  defp status(date) do
    case latest_cutoff() do
      nil -> "open"
      cutoff -> if Date.compare(date, cutoff) == :gt, do: "open", else: "closed"
    end
  end
end
