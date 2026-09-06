defmodule GroupStay.Finance do
  @moduledoc """
  Finance reporting: where reporting starts, what each operation posts, and what a day reports.

  Reporting has one inception point. Until a `start_finance_reporting` operation is applied,
  nothing is reported and nothing is recorded; the state standing immediately before that
  operation becomes the opening position on its `starts_on`. From then on every operation records
  the finance effects it has, stamped with its posting date - the later of the operation's
  `occurred_on` and `starts_on` - so an operation dated before reporting began still posts on the
  first reported day.

  Movements are only ever inserted, and always inside the transaction of the operation that caused
  them, so a rejected operation records nothing and a durable retry records nothing a second time.
  A report is an aggregation of the rows standing when it is read, which is why a later submission
  can change a day that has already been reported and why reading a report never changes anything.
  """

  import Ecto.Query

  alias GroupStay.Finance.Movement
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
  The date an operation's finance effects post to, or `nil` while reporting has not started.

  An operation that happened before reporting began still posts on the first reported day, because
  everything before that day is already stated in the opening position.
  """
  def posting_date(%Operation{occurred_on: occurred_on}) do
    case starts_on() do
      nil ->
        nil

      starts_on ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
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
    on = Date.add(starts_on, -1)

    for {property_id, cents} <- held_cash_by_property() do
      record(on, Movement.cash(), "opening", cents, property_id: property_id)
    end

    record(on, Movement.credit(), "opening", Credit.liability_cents(starts_on))

    # Lots that have already expired are settled history: only a lot that can still expire on a
    # reported day needs its balance brought forward.
    for lot <- unexpired_lots(starts_on) do
      record(on, Movement.lot(), "balance", lot.remaining_cents, credit_lot_id: lot.id)
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

  ## Recording movements

  @doc """
  Records held cash moving at one property.
  """
  def record_cash(posting_date, property_id, kind, amount_cents),
    do: record(posting_date, Movement.cash(), kind, amount_cents, property_id: property_id)

  @doc """
  Records hotel-credit liability moving.
  """
  def record_credit(posting_date, kind, amount_cents),
    do: record(posting_date, Movement.credit(), kind, amount_cents)

  @doc """
  Records a change to what a credit lot holds outside the rooms it funds.

  Lot rows carry no liability of their own. They are the record a lot's expiry is derived from,
  because credit left unused through its `expires_on` expires the next day whether or not the
  partner submitted anything.
  """
  def record_lot(posting_date, %CreditLot{} = lot, amount_cents),
    do: record(posting_date, Movement.lot(), "balance", amount_cents, credit_lot_id: lot.id)

  # Nothing is recorded before reporting starts, and an effect of no cents is not a movement.
  defp record(posting_date, scope, kind, amount_cents, attrs \\ [])

  defp record(nil, _scope, _kind, _amount_cents, _attrs), do: :ok
  defp record(_posting_date, _scope, _kind, 0, _attrs), do: :ok

  defp record(posting_date, scope, kind, amount_cents, attrs) do
    Repo.insert!(
      struct!(
        %Movement{
          posting_date: posting_date,
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
      {:ok, Report.build(date)}
    end
  end
end
