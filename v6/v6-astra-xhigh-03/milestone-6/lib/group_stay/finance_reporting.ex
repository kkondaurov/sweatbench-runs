defmodule GroupStay.FinanceReporting do
  @moduledoc """
  An immutable opening position and additive finance postings, committed with partner operations.

  Available credit schedules an expiry posting. Changes to that availability adjust the schedule,
  so expiry needs neither a background job nor writes during reads. Adjustments made after expiry
  post on the operation's date instead of rewriting the earlier expiry. Backdated operations can
  still adjust open reports, just like other signed postings.
  """
  use Ecto.Schema
  import Ecto.Query
  alias GroupStay.{CreditLot, Group, Repo}
  alias __MODULE__.Movement

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_cents, :integer
  end

  defmodule Movement do
    @moduledoc false
    use Ecto.Schema

    schema "finance_movements" do
      field :operation_id, :string
      field :posting_on, :date
      field :property_id, :string
      field :kind, :string
      field :amount_cents, :integer
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

      posting = %{operation_id: operation_id, posting_on: starts_on}
      Enum.each(lots, &available_credit(posting, &1, &1.remaining_cents))
      :ok
    end
  end

  def posting(operation) do
    case Repo.get(__MODULE__, 1) do
      nil ->
        nil

      reporting ->
        %{
          operation_id: operation["operation_id"],
          posting_on: later(Date.from_iso8601!(operation["occurred_on"]), reporting.starts_on)
        }
    end
  end

  def cash(posting, property_id, kind, amount), do: record(posting, property_id, kind, amount)
  def credit(posting, kind, amount), do: record(posting, nil, kind, amount)

  def available_credit(nil, _lot, _delta), do: :ok

  def available_credit(posting, lot, delta) do
    expiry = later(Date.add(lot.expires_on, 1), posting.posting_on)

    # The API cannot read years beyond 9999. Their expanded ISO representation also does not
    # sort chronologically in SQLite, so never insert an unreachable expiry into the date index.
    if expiry.year <= 9999 do
      credit(%{posting | posting_on: expiry}, "expired_cents", delta)
    end
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
    Repo.insert!(%Movement{
      operation_id: posting.operation_id,
      posting_on: posting.posting_on,
      property_id: property_id,
      kind: kind,
      amount_cents: amount
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
    movements =
      Repo.all(
        from m in Movement,
          where: m.posting_on <= ^date,
          group_by: [m.property_id, m.kind, m.posting_on == ^date],
          select: {m.property_id, m.kind, m.posting_on == ^date, sum(m.amount_cents)}
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
          Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end)
      end)

    credit_rows = Map.get(by_property, nil, [])
    opening = reporting.opening_credit_cents + change(credit_rows, false, ["issued_cents"])

    %{
      date: date,
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening,
        movements: columns(credit_rows, ["issued_cents" | @credit_out]),
        closing_liability_cents: opening + change(credit_rows, true, ["issued_cents"])
      }
    }
  end

  defp change(rows, today, incoming) do
    Enum.reduce(rows, 0, fn {_property, kind, same_day, amount}, total ->
      if same_day == today,
        do: total + if(kind in incoming, do: amount, else: -amount),
        else: total
    end)
  end

  defp columns(rows, kinds) do
    Enum.reduce(rows, Map.new(kinds, &{&1, 0}), fn {_property, kind, today, amount}, columns ->
      if today, do: Map.update!(columns, kind, &(&1 + amount)), else: columns
    end)
  end

  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
