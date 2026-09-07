defmodule GroupStay.Finance do
  @moduledoc """
  Owns the reporting inception point, period cutoff, and append-only daily finance journal.

  Operational tables remain authoritative for the current ledger. Reporting stores the position
  at inception and journals only later movements, which preserves the important processing-order
  boundary even when an operation's accounting date is earlier than the day it was submitted.
  A close advances the journal's posting floor instead of rewriting history. Consequently every
  closed report is derived only from immutable opening and journal rows, while corrections remain
  visible on the first open day. Per-lot availability movements are internal reporting facts used
  to calculate expiry without changing credit lots when a report is read.
  """

  import Ecto.Query

  alias GroupStay.Credits.{CreditLot}

  alias GroupStay.Finance.{
    CashMovement,
    CashOpeningBalance,
    CreditAvailabilityMovement,
    CreditLotOpening,
    CreditMovement,
    ReportingState
  }

  alias GroupStay.Payments.CashAllocation
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}
  alias GroupStay.Credits

  @state_id 1

  @doc "Starts reporting with the financial position visible in the current transaction."
  @spec start_reporting(Date.t()) :: :ok | {:error, :reporting_already_started}
  def start_reporting(starts_on) do
    if reporting_state() do
      {:error, :reporting_already_started}
    else
      cash_openings = current_cash_by_property()
      credit_openings = current_available_credit_lots(starts_on)

      result =
        %ReportingState{}
        |> ReportingState.changeset(%{
          id: @state_id,
          starts_on: starts_on,
          opening_credit_liability_cents: Credits.liability_cents(starts_on)
        })
        |> Repo.insert()

      case result do
        {:ok, _state} ->
          Enum.each(cash_openings, &insert_cash_opening!/1)
          Enum.each(credit_openings, &insert_credit_opening!/1)
          :ok

        {:error, _changeset} ->
          {:error, :reporting_already_started}
      end
    end
  end

  @doc "Closes every available finance report through the supplied date."
  @spec close_period(Date.t()) :: :ok | {:error, :invalid_period}
  def close_period(period_end_on) do
    case reporting_state() do
      nil ->
        {:error, :invalid_period}

      state ->
        if Date.before?(period_end_on, state.starts_on) do
          {:error, :invalid_period}
        else
          {updated, _rows} =
            Repo.update_all(
              from(reporting_state in ReportingState,
                where:
                  reporting_state.id == @state_id and
                    (is_nil(reporting_state.latest_closed_on) or
                       reporting_state.latest_closed_on < ^period_end_on)
              ),
              set: [latest_closed_on: period_end_on]
            )

          if updated == 1, do: :ok, else: {:error, :invalid_period}
        end
    end
  end

  @doc "Returns the reporting date for an operation, or `nil` before reporting starts."
  @spec posting_date(Date.t()) :: Date.t() | nil
  def posting_date(occurred_on) do
    case posting_context(occurred_on) do
      nil -> nil
      context -> context.posting_on
    end
  end

  @doc """
  Appends the finance effects of one applied operation.

  Cash entries are keyed by the group whose property held or settled the money. Availability
  entries are signed changes to an individual credit lot and intentionally do not imply a
  liability movement by themselves.
  """
  def record_operation(operation_id, occurred_on, options \\ []) do
    case posting_context(occurred_on) do
      nil ->
        :ok

      context ->
        options
        |> Keyword.get(:cash, [])
        |> cash_entries_by_property()
        |> Enum.each(fn {property_id, movements} ->
          attrs =
            movements
            |> Map.put(:operation_id, operation_id)
            |> Map.put(:posting_on, context.posting_on)
            |> Map.put(:property_id, property_id)
            |> Map.put(:late_adjustment, context.late_adjustment?)

          %CashMovement{}
          |> CashMovement.changeset(attrs)
          |> Repo.insert!()
        end)

        availability = Keyword.get(options, :availability, [])

        credit =
          options
          |> Keyword.get(:credit, %{})
          |> add_expired_credit_reactivation(
            availability,
            context.posting_on,
            Keyword.get(options, :reactivate_expired_credit, false)
          )
          |> normalize_movements(CreditMovement)

        if Enum.any?(credit, fn {_field, amount} -> amount != 0 end) do
          %CreditMovement{}
          |> CreditMovement.changeset(
            credit
            |> Map.put(:operation_id, operation_id)
            |> Map.put(:posting_on, context.posting_on)
            |> Map.put(:late_adjustment, context.late_adjustment?)
          )
          |> Repo.insert!()
        end

        availability
        |> aggregate_availability()
        |> Enum.each(fn {lot_id, amount_cents} ->
          %CreditAvailabilityMovement{}
          |> CreditAvailabilityMovement.changeset(%{
            operation_id: operation_id,
            posting_on: context.posting_on,
            credit_lot_id: lot_id,
            amount_cents: amount_cents
          })
          |> Repo.insert!()
        end)

        :ok
    end
  end

  @doc "Returns a daily report or indicates that the requested reporting period does not exist."
  @spec daily_report(Date.t()) :: {:ok, map()} | {:error, :report_not_available}
  def daily_report(date) do
    case reporting_state() do
      nil ->
        {:error, :report_not_available}

      state ->
        if Date.before?(date, state.starts_on) do
          {:error, :report_not_available}
        else
          {cash, late_cash} = cash_report(date)
          {credit, late_credit} = credit_report(state, date)

          {:ok,
           %{
             date: Date.to_iso8601(date),
             status: report_status(state, date),
             cash: cash,
             credit: credit,
             late_adjustments: %{cash: late_cash, credit: late_credit}
           }}
        end
    end
  end

  defp reporting_state, do: Repo.get(ReportingState, @state_id)

  defp posting_context(occurred_on) do
    case reporting_state() do
      nil ->
        nil

      state ->
        ordinary_posting_on = later_date(occurred_on, state.starts_on)

        posting_on =
          case state.latest_closed_on do
            nil -> ordinary_posting_on
            cutoff -> later_date(ordinary_posting_on, Date.add(cutoff, 1))
          end

        %{
          posting_on: posting_on,
          late_adjustment?: Date.after?(posting_on, ordinary_posting_on)
        }
    end
  end

  defp report_status(%ReportingState{latest_closed_on: nil}, _date), do: "open"

  defp report_status(%ReportingState{latest_closed_on: cutoff}, date) do
    if Date.after?(date, cutoff), do: "open", else: "closed"
  end

  defp current_cash_by_property do
    Repo.all(
      from allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.group_id == room.group_id,
        where: allocation.disposition == :held and room.status == :active,
        group_by: group.property_id,
        order_by: group.property_id,
        select: %{property_id: group.property_id, amount_cents: sum(allocation.amount_cents)}
    )
  end

  defp current_available_credit_lots(starts_on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^starts_on,
        select: %{credit_lot_id: lot.id, available_cents: lot.remaining_cents}
    )
  end

  defp insert_cash_opening!(attrs) do
    %CashOpeningBalance{}
    |> CashOpeningBalance.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_credit_opening!(attrs) do
    %CreditLotOpening{}
    |> CreditLotOpening.changeset(attrs)
    |> Repo.insert!()
  end

  defp cash_entries_by_property(entries) do
    Enum.reduce(entries, %{}, fn %{group_id: group_id, movements: movements}, by_property ->
      property_id = Repo.get!(Group, group_id).property_id
      movements = normalize_movements(movements, CashMovement)

      Map.update(by_property, property_id, movements, fn existing ->
        Map.merge(existing, movements, fn _field, left, right -> left + right end)
      end)
    end)
  end

  defp normalize_movements(movements, module) do
    Map.new(module.movement_fields(), fn field -> {field, Map.get(movements, field, 0)} end)
  end

  defp aggregate_availability(entries) do
    entries
    |> Enum.reduce(%{}, fn %{credit_lot_id: lot_id, amount_cents: amount}, totals ->
      Map.update(totals, lot_id, amount, &(&1 + amount))
    end)
    |> Enum.reject(fn {_lot_id, amount} -> amount == 0 end)
  end

  # Credit application is evaluated on the operation's occurrence date. If a close moves that
  # application beyond the lot's expiry, reporting has already removed the unused liability. A
  # signed expiry reversal on the posting day brings back the portion now paused in a group.
  defp add_expired_credit_reactivation(credit, _availability, _posting_on, false), do: credit

  defp add_expired_credit_reactivation(credit, availability, posting_on, true) do
    reactivated_cents =
      availability
      |> aggregate_availability()
      |> Enum.reduce(0, fn
        {lot_id, amount_cents}, total when amount_cents < 0 ->
          lot = Repo.get!(CreditLot, lot_id)

          if Date.after?(posting_on, lot.expires_on),
            do: total - amount_cents,
            else: total

        {_lot_id, _amount_cents}, total ->
          total
      end)

    Map.update(credit, :expired_cents, -reactivated_cents, &(&1 - reactivated_cents))
  end

  defp cash_report(date) do
    openings =
      Repo.all(CashOpeningBalance)
      |> Map.new(&{&1.property_id, &1.amount_cents})

    movements =
      Repo.all(
        from movement in CashMovement,
          where: movement.posting_on <= ^date,
          order_by: [asc: movement.posting_on, asc: movement.id]
      )

    properties =
      movements
      |> Enum.map(& &1.property_id)
      |> Enum.concat(Map.keys(openings))
      |> Enum.uniq()
      |> Enum.sort()

    entries =
      Enum.map(properties, fn property_id ->
        property_movements = Enum.filter(movements, &(&1.property_id == property_id))
        before = Enum.filter(property_movements, &Date.before?(&1.posting_on, date))
        today = Enum.filter(property_movements, &(&1.posting_on == date))
        ordinary = today |> Enum.reject(& &1.late_adjustment) |> sum_cash_movements()
        late = today |> Enum.filter(& &1.late_adjustment) |> sum_cash_movements()
        opening = Map.get(openings, property_id, 0) + cash_delta(before)
        closing = opening + cash_delta(ordinary) + cash_delta(late)

        %{
          report: %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: ordinary,
            closing_held_cents: closing
          },
          late: %{property_id: property_id, movements: late}
        }
      end)
      |> Enum.reject(&empty_cash_entry?/1)

    {
      Enum.map(entries, & &1.report),
      entries |> Enum.map(& &1.late) |> Enum.reject(&zero_movements?(&1.movements))
    }
  end

  defp sum_cash_movements(movements) when is_list(movements) do
    Enum.reduce(movements, normalize_movements(%{}, CashMovement), fn movement, totals ->
      Map.new(totals, fn {field, amount} -> {field, amount + Map.fetch!(movement, field)} end)
    end)
  end

  defp cash_delta(movements) when is_list(movements),
    do: movements |> sum_cash_movements() |> cash_delta()

  defp cash_delta(movements) do
    movements.received_cents + movements.transferred_in_cents -
      movements.transferred_out_cents - movements.refunded_cents - movements.retained_cents -
      movements.converted_to_credit_cents - movements.reduced_cents -
      movements.charged_back_cents
  end

  defp empty_cash_entry?(entry) do
    entry.report.opening_held_cents == 0 and entry.report.closing_held_cents == 0 and
      zero_movements?(entry.report.movements) and zero_movements?(entry.late.movements)
  end

  defp zero_movements?(movements),
    do: Enum.all?(movements, fn {_field, amount} -> amount == 0 end)

  defp credit_report(state, date) do
    direct =
      Repo.all(
        from movement in CreditMovement,
          where: movement.posting_on <= ^date,
          order_by: [asc: movement.posting_on, asc: movement.id]
      )

    expiries = automatic_expiries(state, date)
    before = Enum.filter(direct, &Date.before?(&1.posting_on, date))
    today = Enum.filter(direct, &(&1.posting_on == date))
    ordinary = today |> Enum.reject(& &1.late_adjustment) |> sum_credit_movements()
    late = today |> Enum.filter(& &1.late_adjustment) |> sum_credit_movements()

    opening =
      state.opening_credit_liability_cents + credit_delta(before) -
        expiries_before(expiries, date)

    movements = Map.update!(ordinary, :expired_cents, &(&1 + Map.get(expiries, date, 0)))

    {
      %{
        opening_liability_cents: opening,
        movements: movements,
        closing_liability_cents: opening + credit_delta(movements) + credit_delta(late)
      },
      late
    }
  end

  defp sum_credit_movements(movements) do
    Enum.reduce(movements, normalize_movements(%{}, CreditMovement), fn movement, totals ->
      Map.new(totals, fn {field, amount} -> {field, amount + Map.fetch!(movement, field)} end)
    end)
  end

  defp credit_delta(movements) when is_list(movements),
    do: movements |> sum_credit_movements() |> credit_delta()

  defp credit_delta(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end

  defp automatic_expiries(state, through_date) do
    openings = Repo.all(CreditLotOpening) |> Map.new(&{&1.credit_lot_id, &1.available_cents})

    availability =
      Repo.all(CreditAvailabilityMovement)
      |> Enum.group_by(& &1.credit_lot_id)

    candidate_ids = Map.keys(openings) ++ Map.keys(availability)

    Repo.all(from lot in CreditLot, where: lot.id in ^Enum.uniq(candidate_ids))
    |> Enum.reduce(%{}, fn lot, expiries ->
      contractual_expiry = Date.add(lot.expires_on, 1)
      expiry_on = later_date(contractual_expiry, state.starts_on)

      if Date.after?(expiry_on, through_date) do
        expiries
      else
        opening = Map.get(openings, lot.id, 0)

        movement_total =
          availability
          |> Map.get(lot.id, [])
          |> Enum.filter(&available_before_expiry?(&1, contractual_expiry, state.starts_on))
          |> Enum.reduce(0, fn movement, total -> total + movement.amount_cents end)

        expired = max(opening + movement_total, 0)

        if expired == 0,
          do: expiries,
          else: Map.update(expiries, expiry_on, expired, &(&1 + expired))
      end
    end)
  end

  defp available_before_expiry?(movement, contractual_expiry, starts_on) do
    if not Date.after?(contractual_expiry, starts_on) do
      not Date.after?(movement.posting_on, starts_on)
    else
      Date.before?(movement.posting_on, contractual_expiry)
    end
  end

  defp expiries_before(expiries, date) do
    expiries
    |> Enum.filter(fn {expiry_on, _amount} -> Date.before?(expiry_on, date) end)
    |> Enum.reduce(0, fn {_expiry_on, amount}, total -> total + amount end)
  end

  defp later_date(left, right), do: if(Date.before?(left, right), do: right, else: left)
end
