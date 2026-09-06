defmodule GroupStay.FinanceReporting do
  @moduledoc """
  The daily finance report and the reporting inception point.

  The first applied `start_finance_reporting` operation enables reporting.
  The financial state immediately before it is processed becomes the opening
  position on `starts_on`: per-property held cash, the credit liability as
  of `starts_on`, and the current unapplied balance of every credit lot that
  can still expire inside the report range.

  Every operation processed after that point records its finance effects as
  dated movement rows whose posting date is the later of the operation's
  `occurred_on` and `starts_on`. A later operation can therefore change an
  earlier open report. Rejected operations record nothing; durable retries
  replay the stored result without recording a movement again.

  The daily report is derived, on read, from the opening position plus the
  movement rows posted on or before the requested date. Credit expiry is not
  submitted by the partner: a lot's unused balance expires on the day after
  its `expires_on` date, and that expiry is computed from the lot's seeded
  balance and its recorded lifecycle events.
  """

  alias GroupStay.Credit
  alias GroupStay.Credit.CreditLot
  alias GroupStay.FinanceReporting.LotSeed
  alias GroupStay.FinanceReporting.Movement
  alias GroupStay.FinanceReporting.Position
  alias GroupStay.FinanceReporting.Start
  alias GroupStay.Groups.Group
  alias GroupStay.Operations
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting.RoomAllocation

  import Ecto.Query

  @cash_fields [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted",
    "reduced",
    "charged_back"
  ]

  @cash_sign %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  @doc """
  Whether reporting has been enabled.
  """
  @spec started?() :: boolean()
  def started? do
    Repo.exists?(Start)
  end

  @doc """
  The first report date, or `nil` before reporting has started.
  """
  @spec starts_on() :: Date.t() | nil
  def starts_on do
    Repo.one(from s in Start, select: s.starts_on)
  end

  @doc """
  Enables reporting with `starts_on`, capturing the current financial state
  as the opening position. Returns `:ok` or `:already_started` when another
  start won the race.
  """
  @spec start(Date.t()) :: :ok | :already_started
  def start(starts_on) do
    case Repo.transaction(fn -> capture_opening(starts_on) end) do
      {:ok, _captured} -> :ok
      {:error, %Ecto.ConstraintError{}} -> :already_started
      {:error, reason} -> raise reason
    end
  end

  defp capture_opening(starts_on) do
    opening_liability = Credit.liability(starts_on)

    {:ok, _start} =
      Repo.insert(%Start{
        singleton: 1,
        starts_on: starts_on,
        opening_liability_cents: opening_liability
      })

    Enum.each(held_cash_by_property(), fn {property_id, amount} ->
      {:ok, _position} =
        Repo.insert(%Position{property_id: property_id, opening_held_cents: amount})
    end)

    Enum.each(lot_seeds(starts_on), fn %{lot_id: lot_id, initial_cents: initial} ->
      {:ok, _seed} = Repo.insert(%LotSeed{lot_id: lot_id, initial_cents: initial})
    end)

    :ok
  end

  defp held_cash_by_property do
    Repo.all(
      from a in RoomAllocation,
        join: g in Group,
        on: a.group_id == g.id,
        where: a.kind == "cash" and a.disposition == "held",
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
  end

  defp lot_seeds(starts_on) do
    CreditLot
    |> where([lot], lot.remaining_cents > 0)
    |> where([lot], lot.expires_on >= ^starts_on)
    |> select([lot], %{lot_id: lot.id, initial_cents: lot.remaining_cents})
    |> Repo.all()
  end

  @doc """
  The posting date of an operation processed after reporting started: the
  later of its `occurred_on` and `starts_on`. Operations without an
  `occurred_on` post on `starts_on`.
  """
  @spec posting_date(map(), Date.t()) :: Date.t()
  def posting_date(operation, starts_on) do
    case occurred_on(operation) do
      nil -> starts_on
      date -> if Date.compare(date, starts_on) == :gt, do: date, else: starts_on
    end
  end

  defp occurred_on(%{"occurred_on" => value}) do
    case Operations.parse_date(value) do
      {:ok, date} -> date
      :error -> nil
    end
  end

  defp occurred_on(_operation), do: nil

  @doc """
  Records the cash effects of an applied operation. A no-op before reporting
  has started. Effects are `%{property_id:, classification:, amount_cents:}`
  maps; the amounts are signed in their classification's direction.
  """
  @spec record_cash(map(), [map()]) :: :ok
  def record_cash(operation, effects) do
    case starts_on() do
      nil ->
        :ok

      starts_on ->
        date = posting_date(operation, starts_on)

        Enum.each(effects, fn %{
                                property_id: property_id,
                                classification: classification,
                                amount_cents: amount_cents
                              } ->
          insert_movement(%Movement{
            category: "cash",
            classification: classification,
            property_id: property_id,
            amount_cents: amount_cents,
            posting_date: date
          })
        end)

        :ok
    end
  end

  @doc """
  Records the credit effects of an applied operation. A no-op before
  reporting has started. Rows are `%{lot_id:, classification:, amount_cents:}`
  maps.
  """
  @spec record_credit(map(), [map()]) :: :ok
  def record_credit(operation, rows) do
    case starts_on() do
      nil ->
        :ok

      starts_on ->
        date = posting_date(operation, starts_on)

        Enum.each(rows, fn row -> record_credit_row(row, date) end)

        :ok
    end
  end

  defp record_credit_row(row, date) do
    %{lot_id: lot_id, classification: classification, amount_cents: amount} = row

    cond do
      amount == 0 ->
        :ok

      classification == "issued" and lot_expired_on?(lot_id, date) ->
        insert_movement(finance_movement("issued", lot_id, amount, date))
        insert_movement(finance_movement("expired", lot_id, amount, date))

      classification == "restore" ->
        insert_movement(finance_movement("pool_restore", lot_id, amount, date))

        if lot_expired_on?(lot_id, date) do
          insert_movement(finance_movement("expired", lot_id, amount, date))
        end

        :ok

      true ->
        insert_movement(finance_movement(classification, lot_id, amount, date))
    end

    :ok
  end

  @doc """
  Records the credit side of a chargeback: the payment's entitlement is
  removed from each lot's unapplied balance, and the removal is a revoked
  movement only when the lot is still unexpired on the posting date.
  """
  @spec record_revocations(map(), [map()]) :: :ok
  def record_revocations(operation, revocations) do
    case starts_on() do
      nil ->
        :ok

      starts_on ->
        date = posting_date(operation, starts_on)

        Enum.each(revocations, fn %{lot_id: lot_id, removed_cents: removed} ->
          insert_movement(finance_movement("pool_revoke", lot_id, -removed, date))

          unless lot_expired_on?(lot_id, date) do
            insert_movement(finance_movement("revoked", lot_id, removed, date))
          end
        end)

        :ok
    end
  end

  defp lot_expired_on?(lot_id, date) do
    case lot_id && Repo.get(CreditLot, lot_id) do
      nil -> false
      lot -> Date.compare(lot.expires_on, date) == :lt
    end
  end

  defp finance_movement(classification, lot_id, amount_cents, date) do
    %Movement{
      category: "credit",
      classification: classification,
      lot_id: lot_id,
      amount_cents: amount_cents,
      posting_date: date
    }
  end

  @doc """
  Records both sides of a settlement at `property_id`: the cash leaving the
  hotel's held balance and the credit the settlement generated or consumed.
  """
  @spec record_settlement(map(), String.t(), map()) :: :ok
  def record_settlement(operation, property_id, settlement) do
    record_cash(operation, [
      %{
        property_id: property_id,
        classification: "refunded",
        amount_cents: settlement.refunded_cents
      },
      %{
        property_id: property_id,
        classification: "retained",
        amount_cents: settlement.retained_cents
      },
      %{
        property_id: property_id,
        classification: "converted",
        amount_cents: settlement.converted_cents
      }
    ])

    issued_rows =
      if settlement.credit_issued_cents > 0 do
        [
          %{
            lot_id: settlement.credit_lot_id,
            classification: "issued",
            amount_cents: settlement.credit_issued_cents
          }
        ]
      else
        []
      end

    record_credit(operation, issued_rows ++ settlement.credit_effects)
  end

  defp insert_movement(%Movement{amount_cents: 0}), do: :ok

  defp insert_movement(%Movement{} = movement) do
    Repo.insert!(movement)
    :ok
  end

  @doc """
  The daily report for `date`, or `:not_available` before reporting has
  started or before `starts_on`.
  """
  @spec daily_report(Date.t()) :: {:ok, map()} | :not_available
  def daily_report(date) do
    case starts_on() do
      nil ->
        :not_available

      starts_on ->
        if Date.compare(date, starts_on) == :lt do
          :not_available
        else
          {:ok, build_report(date, starts_on)}
        end
    end
  end

  defp build_report(date, starts_on) do
    start = Repo.one!(Start)
    openings = positions_map()

    day_cash_rows =
      Repo.all(from m in Movement, where: m.category == "cash" and m.posting_date == ^date)

    cumulative_cash_rows =
      Repo.all(
        from m in Movement,
          where: m.category == "cash" and m.posting_date <= ^date
      )

    credit_rows =
      Repo.all(
        from m in Movement,
          where: m.category == "credit" and m.posting_date <= ^date
      )

    expiries_on_date = __MODULE__.Expiry.expiries_on(date, starts_on, credit_rows)
    cumulative_expired = __MODULE__.Expiry.expired_up_to(date, starts_on, credit_rows)

    day_by_property =
      day_cash_rows
      |> Enum.group_by(& &1.property_id)
      |> Map.new(fn {property_id, rows} -> {property_id, class_sums(rows)} end)

    cumulative_by_property =
      cumulative_cash_rows
      |> Enum.group_by(& &1.property_id)
      |> Map.new(fn {property_id, rows} -> {property_id, class_sums(rows)} end)

    properties =
      openings
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(day_by_property |> Map.keys() |> MapSet.new())
      |> MapSet.union(cumulative_by_property |> Map.keys() |> MapSet.new())
      |> Enum.sort()

    cash_entries =
      properties
      |> Enum.map(fn property_id ->
        opening = Map.get(openings, property_id, 0)
        day = Map.get(day_by_property, property_id, %{})
        cumulative = Map.get(cumulative_by_property, property_id, %{})

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: %{
            received_cents: Map.get(day, "received", 0),
            transferred_in_cents: Map.get(day, "transferred_in", 0),
            transferred_out_cents: Map.get(day, "transferred_out", 0),
            refunded_cents: Map.get(day, "refunded", 0),
            retained_cents: Map.get(day, "retained", 0),
            converted_to_credit_cents: Map.get(day, "converted", 0),
            reduced_cents: Map.get(day, "reduced", 0),
            charged_back_cents: Map.get(day, "charged_back", 0)
          },
          closing_held_cents: closing_held(opening, cumulative)
        }
      end)
      |> Enum.filter(fn entry ->
        entry.opening_held_cents != 0 or entry.closing_held_cents != 0 or
          Enum.any?(entry.movements, fn {_key, value} -> value != 0 end)
      end)

    credit_movements = %{
      issued_cents: sum_posted(credit_rows, date, "issued"),
      expired_cents: sum_posted(credit_rows, date, "expired") + expiries_on_date,
      consumed_cents: sum_posted(credit_rows, date, "consumed"),
      revoked_cents: sum_posted(credit_rows, date, "revoked"),
      absorbed_cents: sum_posted(credit_rows, date, "absorbed")
    }

    issued = sum_total(credit_rows, "issued")
    expired = sum_total(credit_rows, "expired") + cumulative_expired
    consumed = sum_total(credit_rows, "consumed")
    revoked = sum_total(credit_rows, "revoked")
    absorbed = sum_total(credit_rows, "absorbed")

    closing_liability =
      start.opening_liability_cents + issued - expired - consumed - revoked - absorbed

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash_entries,
      credit: %{
        opening_liability_cents: start.opening_liability_cents,
        movements: credit_movements,
        closing_liability_cents: closing_liability
      }
    }
  end

  defp positions_map do
    Map.new(Repo.all(from p in Position, select: {p.property_id, p.opening_held_cents}))
  end

  defp class_sums(rows) do
    rows
    |> Enum.group_by(& &1.classification)
    |> Map.new(fn {classification, group} ->
      {classification, Enum.reduce(group, 0, &(&1.amount_cents + &2))}
    end)
  end

  defp closing_held(opening, cumulative) do
    Enum.reduce(@cash_fields, opening, fn classification, total ->
      total + @cash_sign[classification] * Map.get(cumulative, classification, 0)
    end)
  end

  defp sum_posted(rows, date, classification) do
    rows
    |> Enum.filter(&(&1.posting_date == date and &1.classification == classification))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  defp sum_total(rows, classification) do
    rows
    |> Enum.filter(&(&1.classification == classification))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  defmodule Expiry do
    @moduledoc false

    alias GroupStay.Credit.CreditLot
    alias GroupStay.FinanceReporting.LotSeed
    alias GroupStay.Repo

    import Ecto.Query

    @pool_classifications ["issued", "pool_apply", "pool_restore", "pool_revoke"]

    @doc """
    The credit that expires on `date`, before report movements.
    """
    @spec expiries_on(Date.t(), Date.t(), [struct()]) :: integer()
    def expiries_on(date, starts_on, credit_rows) do
      credit_rows
      |> lot_expiries(starts_on)
      |> Enum.reduce(0, fn %{expiry_day: expiry_day, pool: pool}, total ->
        if expiry_day == date, do: total + pool, else: total
      end)
    end

    @doc """
    The credit that expired on or before `date`, before report movements.
    """
    @spec expired_up_to(Date.t(), Date.t(), [struct()]) :: integer()
    def expired_up_to(date, starts_on, credit_rows) do
      credit_rows
      |> lot_expiries(starts_on)
      |> Enum.reduce(0, fn %{expiry_day: expiry_day, pool: pool}, total ->
        if Date.compare(expiry_day, date) != :gt, do: total + pool, else: total
      end)
    end

    # For every credit lot touched by movement rows or seeded at the start,
    # the amount that expired on its expiry day: the seeded unapplied balance
    # plus every pool event posted before that day. Lots that already expired
    # before the report range contribute nothing.
    defp lot_expiries(credit_rows, starts_on) do
      seeds = Map.new(Repo.all(from s in LotSeed, select: {s.lot_id, s.initial_cents}))

      lot_ids =
        credit_rows
        |> Enum.filter(&(&1.classification in @pool_classifications))
        |> Enum.map(& &1.lot_id)
        |> Kernel.++(Map.keys(seeds))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      expiries_on_by_lot =
        CreditLot
        |> where([lot], lot.id in ^lot_ids)
        |> select([lot], {lot.id, lot.expires_on})
        |> Repo.all()
        |> Map.new(fn {lot_id, expires_on} -> {lot_id, expires_on} end)

      Enum.flat_map(lot_ids, fn lot_id ->
        case expiries_on_by_lot do
          %{^lot_id => expires_on} ->
            if Date.compare(expires_on, starts_on) == :lt do
              []
            else
              pool =
                Map.get(seeds, lot_id, 0) +
                  (credit_rows
                   |> Enum.filter(fn row ->
                     row.lot_id == lot_id and row.classification in @pool_classifications and
                       Date.compare(row.posting_date, Date.add(expires_on, 1)) == :lt
                   end)
                   |> Enum.reduce(0, &(&1.amount_cents + &2)))

              [%{expiry_day: Date.add(expires_on, 1), pool: pool}]
            end

          _ ->
            []
        end
      end)
    end
  end
end
