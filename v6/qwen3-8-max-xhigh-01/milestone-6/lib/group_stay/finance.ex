defmodule GroupStay.Finance do
  @moduledoc """
  Daily finance reporting.

  Reporting begins with the first applied `start_finance_reporting`
  operation. The financial state immediately before that operation is
  processed becomes the opening position on `starts_on`: the held cash of
  every property, the company-wide credit liability, and each credit lot
  still unexpired on `starts_on` with its remaining balance.

  Every applied operation processed after reporting started records its
  finance effects as movements posted on the later of its `occurred_on` and
  `starts_on`; all effects of one operation share the same posting date.
  Rejected operations record nothing, and a durable retry returns its stored
  result without recording again.

  A daily report is a pure read: the opening position plus the movements
  through the requested date. Credit that remains unused through its expiry
  date expires on that date, and a report shows that expiry even when no
  partner operation was submitted that day.
  """

  import Ecto.Query

  alias GroupStay.Finance.{Movement, OpeningCash, OpeningLot, Start}
  alias GroupStay.Groups.{CashAllocation, CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  # The start row is a singleton; the fixed primary key is what makes a
  # concurrent second start fail instead of committing.
  @singleton_id "00000000-0000-0000-0000-000000000001"

  # How each cash movement kind affects the held cash of its property.
  @cash_signs %{
    "received" => 1,
    "transferred_in" => 1,
    "transferred_out" => -1,
    "refunded" => -1,
    "retained" => -1,
    "converted_to_credit" => -1,
    "reduced" => -1,
    "charged_back" => -1
  }

  # How each credit movement kind affects the company-wide liability.
  @credit_signs %{
    "issued" => 1,
    "expired" => -1,
    "consumed" => -1,
    "revoked" => -1,
    "absorbed" => -1
  }

  # The movement kinds that change a credit lot's remaining balance, used to
  # reconstruct how much of a lot is left when it expires.
  @remaining_signs %{
    "issued" => 1,
    "credit_applied" => -1,
    "credit_restored" => 1,
    "revoked" => -1
  }

  @doc """
  The applied finance-reporting start, or `nil` when reporting has not
  started.
  """
  def start, do: Repo.get(Start, @singleton_id)

  def started?, do: start() != nil

  @doc """
  The reporting posting date for an operation with the given `occurred_on`:
  the later of `occurred_on` and `starts_on`. Returns `nil` when reporting
  has not started.
  """
  def posting_date(%Date{} = occurred_on) do
    case start() do
      nil ->
        nil

      %Start{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on
    end
  end

  @doc """
  Records the finance movements of an applied operation, unless reporting
  has not started. All movements of one operation share its posting date.
  Zero-amount movements are omitted.
  """
  def record_movements(%Date{} = occurred_on, movements) do
    movements = Enum.reject(movements, fn movement -> movement.amount_cents == 0 end)

    case movements do
      [] ->
        :ok

      movements ->
        case posting_date(occurred_on) do
          nil ->
            :ok

          posting_date ->
            Enum.each(movements, fn movement ->
              %Movement{}
              |> Movement.create_changeset(%{
                posting_date: posting_date,
                kind: movement.kind,
                amount_cents: movement.amount_cents,
                property_id: Map.get(movement, :property_id),
                credit_lot_id: Map.get(movement, :credit_lot_id)
              })
              |> Repo.insert!()
            end)
        end
    end
  end

  @doc """
  Enables finance reporting with the financial state immediately before the
  start operation as the opening position on `starts_on`.

  Runs inside the start operation's transaction. A concurrent start that
  commits first rolls this attempt back with `:reporting_start_race`.
  """
  def start_reporting!(%Date{} = starts_on) do
    changeset =
      Start.create_changeset(%Start{}, %{
        id: @singleton_id,
        starts_on: starts_on,
        opening_credit_liability_cents: opening_credit_liability(starts_on)
      })

    case Repo.insert(changeset) do
      {:ok, _start} ->
        insert_opening_cash!()
        insert_opening_lots!(starts_on)
        :ok

      {:error, _changeset} ->
        Repo.rollback(:reporting_start_race)
    end
  end

  # The credit liability immediately before the start operation, evaluated as
  # of `starts_on`: unexpired lot balances plus credit applied to active
  # groups.
  defp opening_credit_liability(starts_on) do
    unexpired =
      Repo.aggregate(
        from(l in CreditLot, where: l.expires_on > ^starts_on),
        :sum,
        :remaining_cents
      ) || 0

    held =
      Repo.aggregate(
        from(a in CreditAllocation, where: a.state == "held"),
        :sum,
        :amount_cents
      ) || 0

    unexpired + held
  end

  defp insert_opening_cash! do
    Repo.all(
      from a in CashAllocation,
        where: a.state == "held",
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == r.group_id,
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
    |> Enum.each(fn {property_id, amount_cents} ->
      %OpeningCash{}
      |> OpeningCash.create_changeset(%{property_id: property_id, amount_cents: amount_cents})
      |> Repo.insert!()
    end)
  end

  defp insert_opening_lots!(starts_on) do
    Repo.all(from l in CreditLot, where: l.expires_on > ^starts_on)
    |> Enum.each(fn lot ->
      %OpeningLot{}
      |> OpeningLot.create_changeset(%{
        credit_lot_id: lot.id,
        remaining_cents: lot.remaining_cents
      })
      |> Repo.insert!()
    end)
  end

  @doc """
  The daily finance report for `date`.

  Returns `{:error, :report_not_available}` before reporting has started or
  for a date before `starts_on`. Reading a report never changes a report or
  any domain state.
  """
  def daily_report(%Date{} = date) do
    case start() do
      nil ->
        {:error, :report_not_available}

      %Start{} = start ->
        if Date.compare(date, start.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(start, date)}
        end
    end
  end

  defp build_report(%Start{} = start, date) do
    movements = Repo.all(from m in Movement, where: m.posting_date <= ^date)

    %{
      date: date,
      status: "open",
      cash: cash_entries(date, movements),
      credit: credit_entry(start, date, movements)
    }
  end

  # Cash entries

  defp cash_entries(date, movements) do
    opening =
      OpeningCash
      |> Repo.all()
      |> Map.new(fn opening -> {opening.property_id, opening.amount_cents} end)

    cash_movements = Enum.filter(movements, &(&1.property_id != nil))

    (Map.keys(opening) ++ Enum.map(cash_movements, & &1.property_id))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn property ->
      case cash_entry(property, Map.get(opening, property, 0), date, cash_movements) do
        nil -> []
        entry -> [entry]
      end
    end)
  end

  # A property is omitted only when its opening balance, closing balance,
  # and every movement of the day are zero.
  defp cash_entry(property, opening_snapshot, date, cash_movements) do
    own = Enum.filter(cash_movements, &(&1.property_id == property))
    {before, today} = split_by_date(own, date)

    opening = opening_snapshot + cash_net(before)
    day = kind_totals(Movement.cash_kinds(), today)
    closing = opening + cash_net(today)

    if opening == 0 and closing == 0 and Enum.all?(Map.values(day), &(&1 == 0)) do
      nil
    else
      %{
        property_id: property,
        opening_held_cents: opening,
        movements: movement_map(Movement.cash_kinds(), day),
        closing_held_cents: closing
      }
    end
  end

  defp cash_net(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      total + movement.amount_cents * Map.fetch!(@cash_signs, movement.kind)
    end)
  end

  # Credit entry

  defp credit_entry(%Start{} = start, date, movements) do
    credit_movements =
      Enum.filter(movements, &(&1.kind in Movement.credit_kinds())) ++
        time_based_expiries(start, date, movements)

    {before, today} = split_by_date(credit_movements, date)

    opening = start.opening_credit_liability_cents + credit_net(before)
    day = kind_totals(Movement.credit_kinds(), today)
    closing = opening + credit_net(today)

    %{
      opening_liability_cents: opening,
      movements: movement_map(Movement.credit_kinds(), day),
      closing_liability_cents: closing
    }
  end

  defp credit_net(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      total + movement.amount_cents * Map.fetch!(@credit_signs, movement.kind)
    end)
  end

  # Credit that remains unused through its expiry date expires on that date,
  # even when no partner operation was submitted that day. A lot issued by an
  # operation processed after reporting started never expires before
  # `starts_on`.
  defp time_based_expiries(%Start{} = start, date, movements) do
    opening_by_lot =
      OpeningLot
      |> Repo.all()
      |> Map.new(fn opening -> {opening.credit_lot_id, opening.remaining_cents} end)

    issued_lot_ids =
      for m <- movements, m.kind == "issued", m.credit_lot_id != nil, uniq: true do
        m.credit_lot_id
      end

    case Enum.uniq(Map.keys(opening_by_lot) ++ issued_lot_ids) do
      [] ->
        []

      lot_ids ->
        Repo.all(from l in CreditLot, where: l.id in ^lot_ids)
        |> Enum.flat_map(fn lot ->
          expiry_date = later_of(lot.expires_on, start.starts_on)

          if Date.compare(expiry_date, date) == :gt do
            []
          else
            base = Map.get(opening_by_lot, lot.id, 0)

            case remaining_before_expiry(lot.id, base, movements, expiry_date) do
              0 -> []
              amount -> [%{posting_date: expiry_date, kind: "expired", amount_cents: amount}]
            end
          end
        end)
    end
  end

  # The lot's remaining balance immediately before its expiry: its opening
  # balance (none for a lot issued after reporting started) plus every
  # recorded balance change posted before the expiry, and the lot's own
  # issuance when it posts on the expiry date itself.
  defp remaining_before_expiry(lot_id, base, movements, expiry_date) do
    movements
    |> Enum.filter(&(&1.credit_lot_id == lot_id and Map.has_key?(@remaining_signs, &1.kind)))
    |> Enum.reduce(base, fn movement, remaining ->
      cond do
        Date.compare(movement.posting_date, expiry_date) == :lt ->
          remaining + movement.amount_cents * Map.fetch!(@remaining_signs, movement.kind)

        movement.kind == "issued" and
            Date.compare(movement.posting_date, expiry_date) == :eq ->
          remaining + movement.amount_cents

        true ->
          remaining
      end
    end)
  end

  # Shared helpers

  defp split_by_date(movements, date) do
    Enum.split_with(movements, fn movement ->
      Date.compare(movement.posting_date, date) == :lt
    end)
  end

  defp kind_totals(kinds, movements) do
    base = Map.new(kinds, &{&1, 0})

    Enum.reduce(movements, base, fn movement, acc ->
      Map.update!(acc, movement.kind, &(&1 + movement.amount_cents))
    end)
  end

  defp movement_map(kinds, totals) do
    Map.new(kinds, fn kind ->
      {String.to_atom(kind <> "_cents"), Map.fetch!(totals, kind)}
    end)
  end

  defp later_of(a, b) do
    if Date.compare(a, b) == :lt, do: b, else: a
  end
end
