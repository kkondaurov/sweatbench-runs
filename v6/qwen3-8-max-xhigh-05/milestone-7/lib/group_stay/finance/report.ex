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

  A `close_finance_period` operation publishes every report through its
  cutoff: reports on or before the latest cutoff are closed and their data
  stays byte-for-byte stable, because operations processed after a close post
  on the day after the cutoff instead of inside the closed period. A movement
  moved forward that way is recorded as a late adjustment and is reported in
  the `late_adjustments` block of each daily report; the ordinary movement
  columns carry only the movements that posted on time.

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
  Returns the reporting posting for an operation occurred on the given date:
  the later of the occurrence and `starts_on`, moved forward to the day after
  the latest closed period when that date falls inside the closed period.

  Returns `{date, late?}` where `late?` tells whether a period close moved
  the posting date forward, or nil when reporting has not started. An
  operation keeps the posting date chosen when it commits; a later close
  never moves it again.
  """
  def posting_date(occurred_on) do
    case fetch() do
      nil ->
        nil

      %Reporting{starts_on: starts_on, latest_close_on: latest_close_on} ->
        natural = if Date.compare(occurred_on, starts_on) == :gt, do: occurred_on, else: starts_on

        case latest_close_on do
          nil ->
            {natural, false}

          cutoff ->
            if Date.compare(natural, cutoff) == :gt do
              {natural, false}
            else
              {Date.add(cutoff, 1), true}
            end
        end
    end
  end

  @doc """
  Closes the finance period through the given date, publishing every report
  on or before it.

  The close applies only when reporting has started, the cutoff is on or
  after `starts_on`, and it is strictly later than the latest successful
  close. Returns `:ok`, or `{:error, :invalid_period}` otherwise.
  """
  def close_period(period_end_on) do
    case fetch() do
      nil ->
        {:error, :invalid_period}

      %Reporting{starts_on: starts_on} ->
        if Date.compare(period_end_on, starts_on) == :lt do
          {:error, :invalid_period}
        else
          advance_close(period_end_on)
        end
    end
  end

  # The conditional update makes the "strictly later than the latest
  # successful close" check atomic with the commit.
  defp advance_close(period_end_on) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {updated, _} =
      Repo.update_all(
        from(r in Reporting,
          where:
            r.singleton == 1 and
              (is_nil(r.latest_close_on) or r.latest_close_on < ^period_end_on)
        ),
        set: [latest_close_on: period_end_on, updated_at: now]
      )

    if updated == 1, do: :ok, else: {:error, :invalid_period}
  end

  @doc """
  Posts one cash movement for the property, or nothing when reporting has not
  started or the amount is zero. The posting is a `{date, late?}` tuple from
  `posting_date/1`.
  """
  def record_cash(nil, _property_id, _entry, _amount_cents), do: :ok
  def record_cash(_posting, _property_id, _entry, 0), do: :ok

  def record_cash({posting_date, late}, property_id, entry, amount_cents)
      when entry in @cash_entries do
    insert_movement(%{
      on_date: posting_date,
      scope: "cash",
      property_id: property_id,
      entry: entry,
      amount_cents: amount_cents,
      lot_id: nil,
      late: late
    })
  end

  @doc """
  Posts one credit movement, or nothing when reporting has not started or the
  amount is zero. The amount is the signed effect on the lot's balance or on
  the liability, depending on the entry. The posting is a `{date, late?}`
  tuple from `posting_date/1`.
  """
  def record_credit(nil, _entry, _amount_cents, _lot_id), do: :ok
  def record_credit(_posting, _entry, 0, _lot_id), do: :ok

  def record_credit({posting_date, late}, entry, amount_cents, lot_id) do
    insert_movement(%{
      on_date: posting_date,
      scope: "credit",
      property_id: nil,
      entry: entry,
      amount_cents: amount_cents,
      lot_id: lot_id,
      late: late
    })

    compensate_expiry({posting_date, late}, entry, amount_cents, lot_id)
  end

  # A balance row posted after its lot's expiry date is not seen by the
  # expiry replay, which derives the expired amount from the balance rows on
  # or before `expires_on`. Post an equal and opposite expired movement so
  # the liability keeps reconciling when a close (or the reporting start)
  # moves an issued, applied, or restored amount past the lot's expiry.
  @balance_entries_recorded ~w(issued applied restored)

  defp compensate_expiry({posting_date, late}, entry, amount_cents, lot_id)
       when entry in @balance_entries_recorded and is_binary(lot_id) do
    case Repo.get(CreditLot, lot_id) do
      nil ->
        :ok

      %CreditLot{expires_on: expires_on} ->
        if Date.compare(expires_on, posting_date) == :lt do
          insert_movement(%{
            on_date: posting_date,
            scope: "credit",
            property_id: nil,
            entry: "expired",
            amount_cents: amount_cents,
            lot_id: lot_id,
            late: late
          })
        end

        :ok
    end
  end

  defp compensate_expiry(_posting, _entry, _amount_cents, _lot_id), do: :ok

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

      %Reporting{starts_on: starts_on, latest_close_on: latest_close_on} ->
        if Date.compare(date, starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(starts_on, date, latest_close_on)}
        end
    end
  end

  defp build_report(starts_on, date, latest_close_on) do
    openings = Repo.all(ReportOpening)
    movements = Repo.all(from m in ReportMovement, where: m.on_date <= ^date)

    lots =
      Repo.all(from l in CreditLot, select: %{id: l.id, expires_on: l.expires_on})
      |> Map.new(&{&1.id, &1.expires_on})

    {cash, late_cash} = build_cash(openings, movements)
    {credit, late_credit} = build_credit(starts_on, date, openings, movements, lots)

    %{
      date: Date.to_iso8601(date),
      status: report_status(date, latest_close_on),
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp report_status(_date, nil), do: "open"

  defp report_status(date, latest_close_on) do
    if Date.compare(date, latest_close_on) != :gt, do: "closed", else: "open"
  end

  # Cash

  # Returns the ordinary cash entries and the late-adjustment cash entries.
  # Ordinary movement columns carry only the movements that posted on time;
  # movements moved forward by a close appear in the late-adjustment entries.
  # A day's total movement is the ordinary value plus the late-adjustment
  # value, and the closing balance uses both.
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

    entries =
      Enum.map(properties, fn property_id ->
        cash_entry(property_id, Map.get(cash_openings, property_id, 0), cash_movements)
      end)

    cash = for {entry, _late} <- entries, entry != nil, do: entry
    late_cash = for {_entry, late} <- entries, late != nil, do: late
    {cash, late_cash}
  end

  defp cash_entry(property_id, opening, movements) do
    property_movements = Enum.filter(movements, &(&1.property_id == property_id))
    {normal_movements, late_movements} = Enum.split_with(property_movements, &(not &1.late))

    normal = cash_sums(normal_movements)
    late = cash_sums(late_movements)

    received = Map.get(normal, "received", 0)
    transferred_in = Map.get(normal, "transferred_in", 0)
    transferred_out = Map.get(normal, "transferred_out", 0)
    refunded = Map.get(normal, "refunded", 0)
    retained = Map.get(normal, "retained", 0)
    converted = Map.get(normal, "converted_to_credit", 0)
    reduced = Map.get(normal, "reduced", 0)
    charged_back = Map.get(normal, "charged_back", 0)

    late_received = Map.get(late, "received", 0)
    late_transferred_in = Map.get(late, "transferred_in", 0)
    late_transferred_out = Map.get(late, "transferred_out", 0)
    late_refunded = Map.get(late, "refunded", 0)
    late_retained = Map.get(late, "retained", 0)
    late_converted = Map.get(late, "converted_to_credit", 0)
    late_reduced = Map.get(late, "reduced", 0)
    late_charged_back = Map.get(late, "charged_back", 0)

    closing =
      opening +
        received + late_received +
        transferred_in + late_transferred_in -
        transferred_out - late_transferred_out -
        refunded - late_refunded -
        retained - late_retained -
        converted - late_converted -
        reduced - late_reduced -
        charged_back - late_charged_back

    entry =
      if opening == 0 and closing == 0 and received == 0 and transferred_in == 0 and
           transferred_out == 0 and refunded == 0 and retained == 0 and converted == 0 and
           reduced == 0 and charged_back == 0 do
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

    late_entry =
      if late_received == 0 and late_transferred_in == 0 and late_transferred_out == 0 and
           late_refunded == 0 and late_retained == 0 and late_converted == 0 and
           late_reduced == 0 and late_charged_back == 0 do
        nil
      else
        %{
          property_id: property_id,
          movements: %{
            received_cents: late_received,
            transferred_in_cents: late_transferred_in,
            transferred_out_cents: late_transferred_out,
            refunded_cents: late_refunded,
            retained_cents: late_retained,
            converted_to_credit_cents: late_converted,
            reduced_cents: late_reduced,
            charged_back_cents: late_charged_back
          }
        }
      end

    {entry, late_entry}
  end

  defp cash_sums(movements) do
    movements
    |> Enum.group_by(& &1.entry, & &1.amount_cents)
    |> Map.new(fn {entry, amounts} -> {entry, Enum.sum(amounts)} end)
  end

  # Credit

  # Returns the ordinary credit object and the late-adjustment credit object.
  # Expiry derived from the lots' balances is never a late adjustment.
  defp build_credit(starts_on, date, openings, movements, lots) do
    opening =
      case Enum.find(openings, &(&1.scope == "credit")) do
        nil -> 0
        credit_opening -> credit_opening.amount_cents
      end

    credit_rows = for movement <- movements, movement.scope == "credit", do: movement
    {normal_rows, late_rows} = Enum.split_with(credit_rows, &(not &1.late))

    issued = sum_entry(normal_rows, "issued")
    consumed = sum_entry(normal_rows, "consumed")
    absorbed = sum_entry(normal_rows, "absorbed")
    expired = sum_entry(normal_rows, "expired") + auto_expired(starts_on, date, credit_rows, lots)
    revoked = revoked_sum(normal_rows, lots)

    late_issued = sum_entry(late_rows, "issued")
    late_consumed = sum_entry(late_rows, "consumed")
    late_absorbed = sum_entry(late_rows, "absorbed")
    late_expired = sum_entry(late_rows, "expired")
    late_revoked = revoked_sum(late_rows, lots)

    closing =
      opening +
        (issued + late_issued) -
        (expired + late_expired) -
        (consumed + late_consumed) -
        (revoked + late_revoked) -
        (absorbed + late_absorbed)

    credit = %{
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

    late_credit = %{
      issued_cents: late_issued,
      expired_cents: late_expired,
      consumed_cents: late_consumed,
      revoked_cents: late_revoked,
      absorbed_cents: late_absorbed
    }

    {credit, late_credit}
  end

  defp revoked_sum(rows, lots) do
    for row <- rows,
        row.entry == "revoked",
        lot_unexpired_on?(lots, row.lot_id, row.on_date),
        reduce: 0 do
      acc -> acc - row.amount_cents
    end
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
