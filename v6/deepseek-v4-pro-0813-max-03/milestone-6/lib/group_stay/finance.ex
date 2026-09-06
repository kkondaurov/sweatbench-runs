defmodule GroupStay.Finance do
  @moduledoc """
  Durable finance reporting.

  `start_finance_reporting` captures the financial state immediately before it
  is processed as the opening position on `starts_on`. Every finance effect of
  a later applied operation is recorded as a movement posted on the later of
  the operation's `occurred_on` and `starts_on`. Daily reports replay those
  movements on top of the opening position, deriving credit expiry from the
  per-lot movement log, so reading a report never changes domain state.
  """

  import Ecto.Query

  alias GroupStay.Accounting.RoomAllocation
  alias GroupStay.Credit
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.Reporting
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @cash_kinds ~w(
    received
    transferred_in
    transferred_out
    refunded
    retained
    converted_to_credit
    reduced
    charged_back
  )

  @credit_kinds ~w(issued expired consumed revoked absorbed)

  # Kinds whose rows change a lot's remaining (available) balance.
  @remaining_kinds ~w(issued credit_applied credit_restore revoked)

  # Signed effect of each cash movement on held cash.
  @held_sign %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  # Signed effect of each credit movement on credit liability.
  @liability_sign %{
    "issued" => 1,
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  # Signed effect of each kind on its lot's remaining balance.
  @remaining_sign %{
    "issued" => 1,
    "credit_applied" => 1,
    "credit_restore" => 1,
    "revoked" => -1
  }

  # ------------------------------------------------------------------
  # Reporting lifecycle
  # ------------------------------------------------------------------

  @doc "The reporting record, or nil when reporting has not started."
  def reporting do
    Repo.one(from r in Reporting, order_by: [asc: r.id], limit: 1)
  end

  def reporting_started?, do: not is_nil(reporting())

  @doc """
  Enables reporting with the given start date, capturing the financial state
  as it stands right now (including every operation already committed).
  """
  def start_reporting!(starts_on) do
    opening = %{
      "cash" => cash_held_by_property(),
      "credit_liability_cents" => Credit.liability(starts_on),
      "lots" => lot_snapshots()
    }

    Repo.insert!(%Reporting{starts_on: starts_on, opening: opening})
  end

  defp cash_held_by_property do
    Repo.all(
      from a in RoomAllocation,
        join: g in Group,
        on: a.group_id == g.id,
        where: a.kind == "cash",
        group_by: g.property_id,
        select: {g.property_id, fragment("COALESCE(SUM(?), 0)", a.amount_cents)}
    )
    |> Map.new()
  end

  defp lot_snapshots do
    Repo.all(CreditLot)
    |> Enum.map(fn lot ->
      %{
        "lot_id" => lot.id,
        "expires_on" => Date.to_iso8601(lot.expires_on),
        "remaining_cents" => lot.remaining_cents
      }
    end)
  end

  # ------------------------------------------------------------------
  # Movement recording
  # ------------------------------------------------------------------

  @doc """
  Persists movement rows for one applied operation. Each row is a map with
  `:property_id` (nil for company-wide credit rows), `:kind`, `:amount_cents`,
  `:lot_id` and `:expires_on` (only for issued rows). Amounts carry the sign of
  their report column.
  """
  def insert_movements!(_operation_id, _posting, []), do: :ok

  def insert_movements!(operation_id, posting, rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    expanded =
      rows
      |> Enum.reject(&expired_revocation?(&1, posting))
      |> Enum.flat_map(fn row ->
        base = %{
          operation_id: operation_id,
          posting_date: posting,
          property_id: Map.get(row, :property_id),
          kind: Map.fetch!(row, :kind),
          amount_cents: Map.fetch!(row, :amount_cents),
          lot_id: Map.get(row, :lot_id),
          expires_on: Map.get(row, :expires_on),
          inserted_at: now,
          updated_at: now
        }

        if expires_immediately?(row, posting) do
          [base, %{base | kind: "expired", expires_on: nil}]
        else
          [base]
        end
      end)

    Repo.insert_all(Movement, expanded)
    :ok
  end

  # A lot that publishes on or after the day it expires can never be available
  # in any report: its expiry is recorded together with its issuance.
  defp expires_immediately?(%{kind: "issued", lot_id: lot_id, expires_on: expires_on}, posting)
       when is_integer(lot_id) and not is_nil(expires_on) do
    Date.compare(Date.add(expires_on, 1), posting) != :gt
  end

  defp expires_immediately?(_row, _posting), do: false

  # A revocation that posts after the lot's expiry write-off is already
  # reflected in the expiry itself, so it carries no liability movement.
  defp expired_revocation?(%{kind: "revoked", expires_on: expires_on}, posting)
       when not is_nil(expires_on) do
    Date.compare(Date.add(expires_on, 1), posting) != :gt
  end

  defp expired_revocation?(_row, _posting), do: false

  # ------------------------------------------------------------------
  # Daily report
  # ------------------------------------------------------------------

  @doc """
  Builds the report for one date. Returns `:not_started` when reporting has not
  started, `:not_available` for dates before `starts_on`, and `{:ok, report}`
  otherwise.
  """
  def daily_report(date) do
    case reporting() do
      nil ->
        :not_started

      record ->
        if Date.compare(date, record.starts_on) == :lt do
          :not_available
        else
          {:ok, build(date, record)}
        end
    end
  end

  defp build(date, record) do
    opening = record.opening
    rows = Repo.all(from m in Movement, where: m.posting_date <= ^date)

    properties =
      (Map.keys(opening["cash"] || %{}) ++
         Enum.flat_map(rows, fn row -> if row.property_id, do: [row.property_id], else: [] end))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(&cash_entry(&1, opening, rows, date))
      |> Enum.reject(&zero_cash_entry?/1)

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash,
      "credit" => credit_entry(opening, rows, date, record.starts_on)
    }
  end

  defp cash_entry(property_id, opening, rows, date) do
    opening_held = Map.get(opening["cash"] || %{}, property_id, 0)

    {prior, today} =
      rows
      |> Enum.filter(&(&1.property_id == property_id))
      |> Enum.split_with(&(Date.compare(&1.posting_date, date) == :lt))

    opening_held =
      opening_held +
        (prior
         |> Enum.filter(&(&1.kind in @cash_kinds))
         |> Enum.map(&(@held_sign[&1.kind] * &1.amount_cents))
         |> Enum.sum())

    movements =
      today
      |> Enum.filter(&(&1.kind in @cash_kinds))
      |> Enum.group_by(& &1.kind, & &1.amount_cents)
      |> sum_columns()

    movements = movement_columns(movements, @cash_kinds)

    closing_held =
      Enum.reduce(@cash_kinds, opening_held, fn kind, acc ->
        acc + @held_sign[kind] * movements[kind <> "_cents"]
      end)

    %{
      "property_id" => property_id,
      "opening_held_cents" => opening_held,
      "movements" => movements,
      "closing_held_cents" => closing_held
    }
  end

  defp zero_cash_entry?(entry) do
    entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
      Enum.all?(entry["movements"], fn {_kind, amount} -> amount == 0 end)
  end

  defp credit_entry(opening, rows, date, starts_on) do
    lots = lot_meta(opening, rows)
    expiries = synthetic_expiries(lots, rows, starts_on)

    {prior, today} =
      rows
      |> Enum.filter(&(&1.kind in @credit_kinds))
      |> Enum.split_with(&(Date.compare(&1.posting_date, date) == :lt))

    opening_liability = opening["credit_liability_cents"] || 0

    opening_liability =
      opening_liability +
        (prior |> Enum.map(&(@liability_sign[&1.kind] * &1.amount_cents)) |> Enum.sum()) -
        (expiries
         |> Enum.filter(&(Date.compare(&1.posting_date, date) == :lt))
         |> Enum.map(& &1.amount_cents)
         |> Enum.sum())

    movements =
      today
      |> Enum.group_by(& &1.kind, & &1.amount_cents)
      |> sum_columns()
      |> Map.update("expired", expired_on(date, expiries), &(&1 + expired_on(date, expiries)))

    movements = movement_columns(movements, @credit_kinds)

    closing_liability =
      Enum.reduce(@credit_kinds, opening_liability, fn kind, acc ->
        acc + @liability_sign[kind] * movements[kind <> "_cents"]
      end)

    %{
      "opening_liability_cents" => opening_liability,
      "movements" => movements,
      "closing_liability_cents" => closing_liability
    }
  end

  defp expired_on(date, expiries) do
    expiries
    |> Enum.filter(&(Date.compare(&1.posting_date, date) == :eq))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  # Lot metadata: snapshot lots plus lots issued after reporting started.
  defp lot_meta(opening, rows) do
    base =
      opening
      |> Map.get("lots", [])
      |> Enum.map(fn lot ->
        {lot["lot_id"],
         %{expires_on: Date.from_iso8601!(lot["expires_on"]), base: lot["remaining_cents"]}}
      end)
      |> Map.new()

    rows
    |> Enum.filter(&(&1.kind == "issued" and not is_nil(&1.expires_on)))
    |> Enum.reduce(base, fn row, acc ->
      Map.put_new(acc, row.lot_id, %{expires_on: row.expires_on, base: 0})
    end)
  end

  # Passive expiries: a lot that still holds credit through its `expires_on`
  # goes off the books the following day. Only reported on days at or after
  # `starts_on`; earlier expiries belong to the opening position.
  defp synthetic_expiries(lots, rows, starts_on) do
    rows_by_lot = Enum.group_by(rows, & &1.lot_id)

    lots
    |> Enum.map(fn {lot_id, meta} ->
      remaining =
        meta.base +
          (rows_by_lot
           |> Map.get(lot_id, [])
           |> Enum.filter(
             &(&1.kind in @remaining_kinds and
                 Date.compare(&1.posting_date, meta.expires_on) != :gt)
           )
           |> Enum.map(&(@remaining_sign[&1.kind] * &1.amount_cents))
           |> Enum.sum())

      %{
        posting_date: Date.add(meta.expires_on, 1),
        amount_cents: max(remaining, 0),
        lot_id: lot_id
      }
    end)
    |> Enum.filter(fn expiry ->
      Date.compare(expiry.posting_date, starts_on) != :lt and expiry.amount_cents > 0
    end)
  end

  defp sum_columns(columns) do
    Map.new(columns, fn {key, values} -> {key, Enum.sum(values)} end)
  end

  defp movement_columns(map, kinds) do
    for kind <- kinds, into: %{} do
      {kind <> "_cents", Map.get(map, kind, 0)}
    end
  end
end
