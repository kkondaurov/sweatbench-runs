defmodule GroupStay.Finance.Report do
  @moduledoc """
  Daily finance reporting of held cash and hotel-credit liability.

  The first applied `start_finance_reporting` operation enables reporting and
  captures the opening position: the held cash per property and the
  company-wide credit liability immediately before the operation is processed
  become the opening position on `starts_on`. Operations processed afterward
  post their finance effects to the later of their `occurred_on` and
  `starts_on`, and a daily report replays the movements posted on or before
  the requested date on top of the opening position.

  Credit that remains unused through its lot's `expires_on` date expires the
  following day; that expiry is derived from the lots' balances at read time,
  so the report shows it even when no partner operation was submitted that
  day. Reading a report never changes reporting or domain state.
  """

  import Ecto.Query

  alias GroupStay.Finance.Credit
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.ReportMovement
  alias GroupStay.Finance.ReportOpening
  alias GroupStay.Finance.Reporting
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @cash_entries ~w(received transferred_in transferred_out refunded retained
                   converted_to_credit reduced charged_back)
  @balance_entries ~w(opening issued applied restored revoked)

  @doc """
  Returns the reporting row, or nil when reporting has not started.
  """
  def fetch do
    Repo.one(from r in Reporting, order_by: [asc: r.inserted_at], limit: 1)
  end

  @doc """
  Enables finance reporting on the given date and captures the opening
  position: the held cash per property and the credit liability immediately
  before the start operation is processed.

  Returns `:ok`, or `{:error, :already_started}` when a concurrent start was
  committed first.
  """
  def start(starts_on, start_operation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    try do
      Repo.insert_all(Reporting, [
        %{
          id: Ecto.UUID.generate(),
          starts_on: starts_on,
          start_operation_id: start_operation_id,
          singleton: 1,
          inserted_at: now,
          updated_at: now
        }
      ])
    rescue
      insert_error ->
        # The insert only fails once a concurrent submission has committed a
        # reporting row first; any other failure is re-raised so the start
        # operation rolls back and is not remembered.
        case fetch() do
          nil -> reraise insert_error, __STACKTRACE__
          %Reporting{} -> {:error, :already_started}
        end
    else
      _ ->
        Repo.insert_all(ReportOpening, opening_rows(starts_on, now))
        Repo.insert_all(ReportMovement, lot_opening_rows(starts_on, now))
        :ok
    end
  end

  defp opening_rows(starts_on, now) do
    cash_rows =
      Repo.all(
        from a in RoomAllocation,
          join: g in Group,
          on: a.group_id == g.id,
          where: a.kind == "cash" and a.status == "held",
          group_by: g.property_id,
          select: %{property_id: g.property_id, amount_cents: sum(a.amount_cents)}
      )
      |> Enum.map(fn %{property_id: property_id, amount_cents: amount_cents} ->
        %{
          id: Ecto.UUID.generate(),
          scope: "cash",
          property_id: property_id,
          amount_cents: amount_cents,
          inserted_at: now,
          updated_at: now
        }
      end)

    credit_row = %{
      id: Ecto.UUID.generate(),
      scope: "credit",
      property_id: nil,
      amount_cents: Credit.liability_cents(starts_on),
      inserted_at: now,
      updated_at: now
    }

    cash_rows ++ [credit_row]
  end

  defp lot_opening_rows(starts_on, now) do
    Repo.all(
      from l in CreditLot,
        where: l.remaining_cents > 0 and l.expires_on >= ^starts_on,
        select: %{id: l.id, remaining_cents: l.remaining_cents}
    )
    |> Enum.map(fn lot ->
      %{
        id: Ecto.UUID.generate(),
        on_date: starts_on,
        scope: "credit",
        property_id: nil,
        entry: "opening",
        amount_cents: lot.remaining_cents,
        lot_id: lot.id,
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  @doc """
  Returns the reporting posting date for an operation occurred on the given
  date: the later of the occurrence and `starts_on`, or nil when reporting
  has not started.
  """
  def posting_date(occurred_on) do
    case fetch() do
      nil ->
        nil

      %Reporting{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :gt, do: occurred_on, else: starts_on
    end
  end

  @doc """
  Posts one cash movement for the property, or nothing when reporting has not
  started or the amount is zero.
  """
  def record_cash(nil, _property_id, _entry, _amount_cents), do: :ok
  def record_cash(_posting_date, _property_id, _entry, 0), do: :ok

  def record_cash(posting_date, property_id, entry, amount_cents)
      when entry in @cash_entries do
    insert_movement(%{
      on_date: posting_date,
      scope: "cash",
      property_id: property_id,
      entry: entry,
      amount_cents: amount_cents,
      lot_id: nil
    })
  end

  @doc """
  Posts one credit movement, or nothing when reporting has not started or the
  amount is zero. The amount is the signed effect on the lot's balance or on
  the liability, depending on the entry.
  """
  def record_credit(nil, _entry, _amount_cents, _lot_id), do: :ok
  def record_credit(_posting_date, _entry, 0, _lot_id), do: :ok

  def record_credit(posting_date, entry, amount_cents, lot_id) do
    insert_movement(%{
      on_date: posting_date,
      scope: "credit",
      property_id: nil,
      entry: entry,
      amount_cents: amount_cents,
      lot_id: lot_id
    })
  end

  defp insert_movement(fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(ReportMovement, [
      Map.merge(fields, %{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
    ])

    :ok
  end

  @doc """
  Returns the daily report for the given date.

  Returns `{:error, :report_not_available}` when reporting has not started or
  the date is before `starts_on`.
  """
  def daily_report(date) do
    case fetch() do
      nil ->
        {:error, :report_not_available}

      %Reporting{starts_on: starts_on} ->
        if Date.compare(date, starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(starts_on, date)}
        end
    end
  end

  defp build_report(starts_on, date) do
    openings = Repo.all(ReportOpening)
    movements = Repo.all(from m in ReportMovement, where: m.on_date <= ^date)

    lots =
      Repo.all(from l in CreditLot, select: %{id: l.id, expires_on: l.expires_on})
      |> Map.new(&{&1.id, &1.expires_on})

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: build_cash(openings, movements),
      credit: build_credit(starts_on, date, openings, movements, lots)
    }
  end

  # Cash

  defp build_cash(openings, movements) do
    cash_openings =
      for opening <- openings, opening.scope == "cash", into: %{} do
        {opening.property_id, opening.amount_cents}
      end

    cash_movements = for movement <- movements, movement.scope == "cash", do: movement

    properties =
      (Map.keys(cash_openings) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    for property_id <- properties,
        entry = cash_entry(property_id, Map.get(cash_openings, property_id, 0), cash_movements),
        entry != nil do
      entry
    end
  end

  defp cash_entry(property_id, opening, movements) do
    sums =
      movements
      |> Enum.filter(&(&1.property_id == property_id))
      |> Enum.group_by(& &1.entry, & &1.amount_cents)
      |> Map.new(fn {entry, amounts} -> {entry, Enum.sum(amounts)} end)

    received = Map.get(sums, "received", 0)
    transferred_in = Map.get(sums, "transferred_in", 0)
    transferred_out = Map.get(sums, "transferred_out", 0)
    refunded = Map.get(sums, "refunded", 0)
    retained = Map.get(sums, "retained", 0)
    converted = Map.get(sums, "converted_to_credit", 0)
    reduced = Map.get(sums, "reduced", 0)
    charged_back = Map.get(sums, "charged_back", 0)

    closing =
      opening + received + transferred_in - transferred_out - refunded - retained -
        converted - reduced - charged_back

    all_zero? =
      opening == 0 and closing == 0 and received == 0 and transferred_in == 0 and
        transferred_out == 0 and refunded == 0 and retained == 0 and converted == 0 and
        reduced == 0 and charged_back == 0

    if all_zero? do
      nil
    else
      %{
        property_id: property_id,
        opening_held_cents: opening,
        movements: %{
          received_cents: received,
          transferred_in_cents: transferred_in,
          transferred_out_cents: transferred_out,
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: converted,
          reduced_cents: reduced,
          charged_back_cents: charged_back
        },
        closing_held_cents: closing
      }
    end
  end

  # Credit

  defp build_credit(starts_on, date, openings, movements, lots) do
    opening =
      case Enum.find(openings, &(&1.scope == "credit")) do
        nil -> 0
        credit_opening -> credit_opening.amount_cents
      end

    credit_rows = for movement <- movements, movement.scope == "credit", do: movement

    issued = sum_entry(credit_rows, "issued")
    consumed = sum_entry(credit_rows, "consumed")
    absorbed = sum_entry(credit_rows, "absorbed")
    expired = sum_entry(credit_rows, "expired") + auto_expired(starts_on, date, credit_rows, lots)

    revoked =
      for row <- credit_rows,
          row.entry == "revoked",
          lot_unexpired_on?(lots, row.lot_id, row.on_date),
          reduce: 0 do
        acc -> acc - row.amount_cents
      end

    closing = opening + issued - expired - consumed - revoked - absorbed

    %{
      opening_liability_cents: opening,
      movements: %{
        issued_cents: issued,
        expired_cents: expired,
        consumed_cents: consumed,
        revoked_cents: revoked,
        absorbed_cents: absorbed
      },
      closing_liability_cents: closing
    }
  end

  defp sum_entry(rows, entry) do
    rows
    |> Enum.filter(&(&1.entry == entry))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  # A lot that was still available when reporting started expires on the day
  # after its `expires_on` date; its expired amount is its balance at that
  # point, replayed from its balance rows.
  defp auto_expired(starts_on, date, credit_rows, lots) do
    for {lot_id, expires_on} <- lots,
        Date.compare(expires_on, starts_on) != :lt,
        Date.compare(Date.add(expires_on, 1), date) != :gt,
        reduce: 0 do
      acc ->
        balance =
          for row <- credit_rows,
              row.lot_id == lot_id,
              row.entry in @balance_entries,
              Date.compare(row.on_date, expires_on) != :gt,
              reduce: 0 do
            inner -> inner + row.amount_cents
          end

        acc + balance
    end
  end

  defp lot_unexpired_on?(lots, lot_id, on_date) do
    case Map.fetch(lots, lot_id) do
      {:ok, expires_on} -> Date.compare(expires_on, on_date) != :lt
      :error -> false
    end
  end
end
