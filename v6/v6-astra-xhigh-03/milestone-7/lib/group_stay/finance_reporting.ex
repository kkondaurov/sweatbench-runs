defmodule GroupStay.FinanceReporting do
  @moduledoc """
  An immutable opening position and additive finance postings, committed with partner operations.

  Available credit schedules an expiry posting. Changes to that availability adjust the schedule,
  so expiry needs neither a background job nor writes during reads. Adjustments made after expiry
  post on the operation's date instead of rewriting the earlier expiry. Closing advances a durable
  cutoff; every subsequent posting is clamped past it before insertion. Existing postings never
  move, so even unread closed reports remain stable without materializing every calendar day.
  """
  use Ecto.Schema
  import Ecto.Query
  alias GroupStay.{CreditLot, Group, Repo}
  alias __MODULE__.Movement

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
    field :closed_through_on, :date
  end

  defmodule Movement do
    @moduledoc false
    use Ecto.Schema

    schema "finance_movements" do
      field :operation_id, :string
      # ISO text also preserves the first open day after a 9999-12-31 close, which cannot
      # round-trip through Ecto's four-digit date decoder.
      field :posting_on, :string
      field :property_id, :string
      field :kind, :string
      field :amount_cents, :integer
      field :late_adjustment, :boolean, default: false
    end
  end

  @cash_in ~w(received_cents transferred_in_cents)
  @cash_out ~w(transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
  @credit_out ~w(expired_cents consumed_cents revoked_cents absorbed_cents)

  # The caller holds the same database write lock used for durable operations.
  def start(starts_on, operation_id) do
    if Repo.get(__MODULE__, 1) do
      {:error, "reporting_already_started"}
    else
      cash =
        Repo.all(
          from g in Group,
            group_by: g.property_id,
            select: {g.property_id, sum(g.deposit_paid_cents - g.credit_paid_cents)}
        )
        |> Map.new()

      applied = Repo.one(from g in Group, select: coalesce(sum(g.credit_paid_cents), 0))

      lots =
        Repo.all(from l in CreditLot, where: l.expires_on >= ^starts_on and l.remaining_cents > 0)

      Repo.insert!(%__MODULE__{
        id: 1,
        starts_on: starts_on,
        opening_cash: cash,
        opening_credit_cents: applied + Enum.sum(Enum.map(lots, & &1.remaining_cents))
      })

      posting = %{operation_id: operation_id, posting_on: starts_on, closed_through_on: nil}
      Enum.each(lots, &available_credit(posting, &1, &1.remaining_cents))
      :ok
    end
  end

  # Called inside the partner operation's immediate transaction, including its audit record.
  def close(period_end_on) do
    case Repo.get(__MODULE__, 1) do
      nil ->
        {:error, "invalid_period"}

      reporting ->
        if Date.compare(period_end_on, reporting.starts_on) == :lt or
             closed?(reporting, period_end_on) do
          {:error, "invalid_period"}
        else
          reporting
          |> Ecto.Changeset.change(closed_through_on: period_end_on)
          |> Repo.update!()

          :ok
        end
    end
  end

  def posting(operation) do
    case Repo.get(__MODULE__, 1) do
      nil ->
        nil

      reporting ->
        # Keep the original effect date until record/4. In particular, moving the operation
        # past a closed expiry must preserve its signed expiry/revocation classifications.
        %{
          operation_id: operation["operation_id"],
          posting_on: later(Date.from_iso8601!(operation["occurred_on"]), reporting.starts_on),
          closed_through_on: reporting.closed_through_on
        }
    end
  end

  def cash(posting, property_id, kind, amount), do: record(posting, property_id, kind, amount)
  def credit(posting, kind, amount), do: record(posting, nil, kind, amount)

  def available_credit(nil, _lot, _delta), do: :ok

  def available_credit(posting, lot, delta) do
    # Determine the expiry effect before clamping to the open period. A correction to a closed
    # expiry becomes a signed late adjustment; an expiry still in the future stays ordinary.
    expiry = later(Date.add(lot.expires_on, 1), posting.posting_on)
    credit(%{posting | posting_on: expiry}, "expired_cents", delta)
  end

  def revoke_credit(nil, _lot, _amount), do: :ok

  def revoke_credit(posting, lot, amount) do
    # Removing an already expired balance does not remove liability a second time.
    if Date.compare(lot.expires_on, posting.posting_on) != :lt do
      credit(posting, "revoked_cents", amount)
      available_credit(posting, lot, -amount)
    end
  end

  defp record(nil, _property_id, _kind, _amount), do: :ok
  defp record(_posting, _property_id, _kind, 0), do: :ok

  defp record(posting, property_id, kind, amount) do
    late = closed?(posting, posting.posting_on)
    posting_on = if late, do: Date.add(posting.closed_through_on, 1), else: posting.posting_on

    Repo.insert!(%Movement{
      operation_id: posting.operation_id,
      posting_on: Date.to_iso8601(posting_on),
      property_id: property_id,
      kind: kind,
      amount_cents: amount,
      late_adjustment: late
    })
  end

  def daily_report(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(__MODULE__, 1) do
          nil ->
            {:error, "report_not_available"}

          reporting ->
            if Date.compare(date, reporting.starts_on) == :lt,
              do: {:error, "report_not_available"},
              else: {:ok, report(reporting, date)}
        end
      end)

    result
  end

  defp report(reporting, date) do
    # Aggregate in SQL; report reads do not load or replay the operation/domain history.
    iso_date = Date.to_iso8601(date)
    through_date = through_date(date)

    movements =
      Repo.all(
        from m in Movement,
          where: ^through_date,
          # Keep postings beyond year 9999 durably, but their expanded ISO years must not
          # sort into any report in the API's four-digit calendar range.
          where: fragment("length(ltrim(?, '-')) = 10", m.posting_on),
          group_by: [m.property_id, m.kind, m.posting_on == ^iso_date, m.late_adjustment],
          select:
            {m.property_id, m.kind, m.posting_on == ^iso_date, m.late_adjustment,
             sum(m.amount_cents)}
      )

    by_property = Enum.group_by(movements, &elem(&1, 0))

    cash =
      (Map.keys(reporting.opening_cash) ++ Map.keys(by_property))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn property_id ->
        rows = Map.get(by_property, property_id, [])
        opening = Map.get(reporting.opening_cash, property_id, 0) + change(rows, false, @cash_in)

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: columns(rows, @cash_in ++ @cash_out),
          closing_held_cents: opening + change(rows, true, @cash_in)
        }
      end)
      |> Enum.reject(fn entry ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          all_zero?(entry.movements) and
          all_zero?(
            columns(Map.get(by_property, entry.property_id, []), @cash_in ++ @cash_out, true)
          )
      end)

    credit_rows = Map.get(by_property, nil, [])
    opening = reporting.opening_credit_cents + change(credit_rows, false, ["issued_cents"])

    %{
      date: date,
      status: if(closed?(reporting, date), do: "closed", else: "open"),
      cash: cash,
      credit: %{
        opening_liability_cents: opening,
        movements: columns(credit_rows, ["issued_cents" | @credit_out]),
        closing_liability_cents: opening + change(credit_rows, true, ["issued_cents"])
      },
      late_adjustments: %{
        cash:
          by_property
          |> Enum.reject(fn {property, _rows} -> is_nil(property) end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {property, rows} ->
            %{property_id: property, movements: columns(rows, @cash_in ++ @cash_out, true)}
          end)
          |> Enum.reject(&all_zero?(&1.movements)),
        credit: columns(credit_rows, ["issued_cents" | @credit_out], true)
      }
    }
  end

  defp through_date(%Date{year: year} = date) when year < 0 do
    # The existing ISO parser also accepts signed years. Their year order is reversed in
    # text, while month/day order is unchanged; a close must protect these dates as well.
    first = Date.to_iso8601(%{date | month: 1, day: 1})
    last = Date.to_iso8601(%{date | month: 12, day: 31})
    today = Date.to_iso8601(date)

    dynamic(
      [m],
      (m.posting_on >= ^first and m.posting_on <= ^today) or
        (m.posting_on > ^last and m.posting_on < "0")
    )
  end

  defp through_date(date) do
    today = Date.to_iso8601(date)
    dynamic([m], m.posting_on <= ^today)
  end

  defp change(rows, today, incoming) do
    Enum.reduce(rows, 0, fn {_property, kind, same_day, _late, amount}, total ->
      if same_day == today,
        do: total + if(kind in incoming, do: amount, else: -amount),
        else: total
    end)
  end

  defp columns(rows, kinds, late_adjustment \\ false) do
    Enum.reduce(rows, Map.new(kinds, &{&1, 0}), fn {_property, kind, today, late, amount},
                                                   columns ->
      if today and late == late_adjustment,
        do: Map.update!(columns, kind, &(&1 + amount)),
        else: columns
    end)
  end

  defp all_zero?(columns), do: Enum.all?(columns, fn {_kind, amount} -> amount == 0 end)
  defp closed?(%{closed_through_on: nil}, _date), do: false
  defp closed?(%{closed_through_on: cutoff}, date), do: Date.compare(date, cutoff) != :gt
  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
