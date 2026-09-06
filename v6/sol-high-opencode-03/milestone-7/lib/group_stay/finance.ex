defmodule GroupStay.Finance do
  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditLot}
  alias GroupStay.Finance.{CashOpening, CreditExpiry, Movement, ReportingState}
  alias GroupStay.Payments.CashAllocation
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  def start(operation) do
    case Repo.get(ReportingState, 1) do
      nil ->
        case reporting_start_date(operation) do
          {:ok, starts_on} -> create_start(operation, starts_on)
          :error -> rejected(operation, "invalid_reporting_date")
        end

      _state ->
        rejected(operation, "reporting_already_started")
    end
  end

  def close(operation) do
    case {Repo.get(ReportingState, 1), period_end_date(operation)} do
      {%ReportingState{} = state, {:ok, period_end_on}} ->
        if valid_close?(state, period_end_on) do
          state
          |> ReportingState.changeset(%{latest_closed_on: period_end_on})
          |> Repo.update!()

          %{
            operation_id: operation["operation_id"],
            status: "applied",
            period_end_on: period_end_on
          }
        else
          rejected(operation, "invalid_period")
        end

      _ ->
        rejected(operation, "invalid_period")
    end
  end

  def report(date) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(ReportingState, 1) do
          nil ->
            {:error, :report_not_available}

          state ->
            if Date.before?(date, state.starts_on) do
              {:error, :report_not_available}
            else
              {:ok, build_report(state, date)}
            end
        end
      end)

    result
  end

  def validate_operation_date(operation) do
    case Repo.get(ReportingState, 1) do
      nil ->
        :ok

      _state ->
        case Date.from_iso8601(operation["occurred_on"] || "") do
          {:ok, _date} -> :ok
          _error -> {:error, "invalid_operation"}
        end
    end
  end

  def record_cash(operation, property_id, kind, amount)
      when kind in @cash_kinds and is_integer(amount) do
    record(operation, "cash", property_id, kind, amount)
  end

  def record_credit(operation, kind, amount) when kind in @credit_kinds and is_integer(amount) do
    record(operation, "credit", nil, kind, amount)
  end

  def issue_credit(operation, lot, amount) do
    case state_and_posting(operation) do
      nil ->
        :ok

      {_state, posting_on, late_adjustment} ->
        insert_movement(
          operation,
          posting_on,
          "credit",
          nil,
          "issued",
          amount,
          late_adjustment
        )

        natural_expiry = Date.add(lot.expires_on, 1)

        if Date.before?(natural_expiry, posting_on) do
          insert_movement(
            operation,
            posting_on,
            "credit",
            nil,
            "expired",
            amount,
            late_adjustment
          )
        else
          put_expiry(lot.id, natural_expiry, amount)
        end

        :ok
    end
  end

  def pause_credit(operation, amounts_by_lot) do
    case state_and_posting(operation) do
      nil ->
        :ok

      {_state, posting_on, late_adjustment} ->
        Enum.each(amounts_by_lot, fn {lot_id, amount} ->
          paused = take_expiry(lot_id, amount, posting_on)

          if paused < amount do
            insert_movement(
              operation,
              posting_on,
              "credit",
              nil,
              "expired",
              paused - amount,
              late_adjustment
            )
          end
        end)
    end

    :ok
  end

  def restore_credit(operation, lot, amount) do
    case state_and_posting(operation) do
      nil ->
        :ok

      {_state, posting_on, late_adjustment} ->
        natural_expiry = Date.add(lot.expires_on, 1)

        if Date.before?(natural_expiry, posting_on) do
          insert_movement(
            operation,
            posting_on,
            "credit",
            nil,
            "expired",
            amount,
            late_adjustment
          )
        else
          put_expiry(lot.id, natural_expiry, amount)
        end
    end
  end

  def revoke_credit(operation, lot_id, amount) do
    case state_and_posting(operation) do
      nil ->
        :ok

      {_state, posting_on, late_adjustment} ->
        revoked = take_expiry(lot_id, amount, posting_on)

        insert_movement(
          operation,
          posting_on,
          "credit",
          nil,
          "revoked",
          revoked,
          late_adjustment
        )
    end
  end

  defp create_start(operation, starts_on) do
    last_pre_reporting_expiry = Date.add(starts_on, -1)

    cash_openings =
      Repo.all(
        from allocation in CashAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          group_by: group.property_id,
          select: {group.property_id, sum(allocation.amount_cents)}
      )

    available_credit =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^last_pre_reporting_expiry,
          select: fragment("COALESCE(SUM(?), 0)", lot.remaining_cents)
      )

    applied_credit =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          select: fragment("COALESCE(SUM(?), 0)", allocation.amount_cents)
      )

    %ReportingState{}
    |> ReportingState.changeset(%{
      id: 1,
      start_operation_id: operation["operation_id"],
      starts_on: starts_on,
      opening_credit_liability_cents: available_credit + applied_credit
    })
    |> Repo.insert!()

    Enum.each(cash_openings, fn {property_id, amount} ->
      %CashOpening{}
      |> CashOpening.changeset(%{property_id: property_id, opening_held_cents: amount})
      |> Repo.insert!()
    end)

    Repo.all(
      from lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^last_pre_reporting_expiry
    )
    |> Enum.each(fn lot ->
      put_expiry(lot.id, Date.add(lot.expires_on, 1), lot.remaining_cents)
    end)

    %{operation_id: operation["operation_id"], status: "applied", starts_on: starts_on}
  end

  defp build_report(state, date) do
    movements = Repo.all(from movement in Movement, where: movement.posting_on <= ^date)
    expiries = Repo.all(from expiry in CreditExpiry, where: expiry.posting_on <= ^date)

    cash = build_cash_report(movements, date)
    credit = build_credit_report(state, movements, expiries, date)

    %{
      date: date,
      status: report_status(state, date),
      cash: cash,
      credit: credit,
      late_adjustments: build_late_adjustments(movements, date)
    }
  end

  defp build_cash_report(movements, date) do
    openings = Repo.all(CashOpening) |> Map.new(&{&1.property_id, &1.opening_held_cents})

    cash_movements = Enum.filter(movements, &(&1.scope == "cash"))

    properties =
      (Map.keys(openings) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    properties
    |> Enum.map(fn property_id ->
      property_movements = Enum.filter(cash_movements, &(&1.property_id == property_id))
      prior = Enum.filter(property_movements, &Date.before?(&1.posting_on, date))
      daily = Enum.filter(property_movements, &(&1.posting_on == date))
      ordinary_daily = Enum.reject(daily, & &1.late_adjustment)
      opening = Map.get(openings, property_id, 0) + cash_delta(prior)
      movement_totals = movement_totals(ordinary_daily, @cash_kinds)
      closing = opening + cash_delta(daily)

      %{
        property_id: property_id,
        opening_held_cents: opening,
        movements: movement_totals,
        closing_held_cents: closing
      }
    end)
    |> Enum.reject(fn entry ->
      entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
        Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end) and
        not property_has_late_movements?(cash_movements, entry.property_id, date)
    end)
  end

  defp build_credit_report(state, movements, expiries, date) do
    credit_movements = Enum.filter(movements, &(&1.scope == "credit"))
    prior = Enum.filter(credit_movements, &Date.before?(&1.posting_on, date))
    daily = Enum.filter(credit_movements, &(&1.posting_on == date))
    ordinary_daily = Enum.reject(daily, & &1.late_adjustment)
    prior_expiry = expiries |> Enum.filter(&Date.before?(&1.posting_on, date)) |> expiry_total()
    daily_expiry = expiries |> Enum.filter(&(&1.posting_on == date)) |> expiry_total()
    opening = state.opening_credit_liability_cents + credit_delta(prior, prior_expiry)

    movement_totals =
      movement_totals(ordinary_daily, @credit_kinds)
      |> Map.update!(:expired_cents, &(&1 + daily_expiry))

    closing = opening + credit_delta(daily, daily_expiry)

    %{
      opening_liability_cents: opening,
      movements: movement_totals,
      closing_liability_cents: closing
    }
  end

  defp movement_totals(movements, kinds) do
    Map.new(kinds, fn kind ->
      key = String.to_atom("#{kind}_cents")

      amount =
        movements
        |> Enum.filter(&(&1.kind == kind))
        |> Enum.map(& &1.amount_cents)
        |> Enum.sum()

      {key, amount}
    end)
  end

  defp build_late_adjustments(movements, date) do
    daily_late =
      Enum.filter(movements, &(&1.posting_on == date and &1.late_adjustment))

    cash =
      daily_late
      |> Enum.filter(&(&1.scope == "cash"))
      |> Enum.group_by(& &1.property_id)
      |> Enum.map(fn {property_id, property_movements} ->
        %{
          property_id: property_id,
          movements: movement_totals(property_movements, @cash_kinds)
        }
      end)
      |> Enum.reject(fn entry ->
        Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end)
      end)
      |> Enum.sort_by(& &1.property_id)

    credit =
      daily_late
      |> Enum.filter(&(&1.scope == "credit"))
      |> movement_totals(@credit_kinds)

    %{cash: cash, credit: credit}
  end

  defp property_has_late_movements?(movements, property_id, date) do
    movements
    |> Enum.filter(fn movement ->
      movement.property_id == property_id and movement.posting_on == date and
        movement.late_adjustment
    end)
    |> movement_totals(@cash_kinds)
    |> Enum.any?(fn {_kind, amount} -> amount != 0 end)
  end

  defp cash_delta(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      sign = if movement.kind in ["received", "transferred_in"], do: 1, else: -1
      total + sign * movement.amount_cents
    end)
  end

  defp credit_delta(movements, expiry) do
    Enum.reduce(movements, -expiry, fn movement, total ->
      sign = if movement.kind == "issued", do: 1, else: -1
      total + sign * movement.amount_cents
    end)
  end

  defp expiry_total(expiries), do: expiries |> Enum.map(& &1.amount_cents) |> Enum.sum()

  defp record(operation, scope, property_id, kind, amount) do
    case state_and_posting(operation) do
      nil ->
        :ok

      {_state, posting_on, late_adjustment} ->
        insert_movement(
          operation,
          posting_on,
          scope,
          property_id,
          kind,
          amount,
          late_adjustment
        )
    end
  end

  defp insert_movement(_operation, _posting_on, _scope, _property_id, _kind, 0, _late),
    do: :ok

  defp insert_movement(
         operation,
         posting_on,
         scope,
         property_id,
         kind,
         amount,
         late_adjustment
       ) do
    %Movement{}
    |> Movement.changeset(%{
      operation_id: operation["operation_id"],
      posting_on: posting_on,
      scope: scope,
      property_id: property_id,
      kind: kind,
      amount_cents: amount,
      late_adjustment: late_adjustment
    })
    |> Repo.insert!()

    :ok
  end

  defp state_and_posting(operation) do
    case Repo.get(ReportingState, 1) do
      nil ->
        nil

      state ->
        natural_posting_on = posting_on(operation, state.starts_on)
        posting_on = after_latest_close(natural_posting_on, state.latest_closed_on)
        {state, posting_on, Date.after?(posting_on, natural_posting_on)}
    end
  end

  defp posting_on(operation, starts_on) do
    occurred_on =
      case Date.from_iso8601(operation["occurred_on"] || "") do
        {:ok, date} -> date
        _error -> starts_on
      end

    max_date(occurred_on, starts_on)
  end

  defp after_latest_close(posting_on, nil), do: posting_on

  defp after_latest_close(posting_on, latest_closed_on) do
    max_date(posting_on, Date.add(latest_closed_on, 1))
  end

  defp put_expiry(_lot_id, _posting_on, 0), do: :ok

  defp put_expiry(lot_id, posting_on, amount) do
    case Repo.get(CreditExpiry, lot_id) do
      nil ->
        %CreditExpiry{}
        |> CreditExpiry.changeset(%{
          credit_lot_id: lot_id,
          posting_on: posting_on,
          amount_cents: amount
        })
        |> Repo.insert!()

      expiry ->
        expiry
        |> CreditExpiry.changeset(%{amount_cents: expiry.amount_cents + amount})
        |> Repo.update!()
    end

    :ok
  end

  defp take_expiry(lot_id, amount, posting_on) do
    case Repo.get(CreditExpiry, lot_id) do
      nil ->
        0

      expiry ->
        if Date.before?(expiry.posting_on, posting_on) do
          0
        else
          taken = min(expiry.amount_cents, amount)

          expiry
          |> CreditExpiry.changeset(%{amount_cents: expiry.amount_cents - taken})
          |> Repo.update!()

          taken
        end
    end
  end

  defp reporting_start_date(%{"starts_on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp reporting_start_date(_operation), do: :error

  defp period_end_date(%{"period_end_on" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp period_end_date(_operation), do: :error

  defp valid_close?(state, period_end_on) do
    # A successful close must leave a representable first day for later postings.
    not Date.before?(period_end_on, state.starts_on) and
      period_end_on != ~D[9999-12-31] and
      (is_nil(state.latest_closed_on) or Date.after?(period_end_on, state.latest_closed_on))
  end

  defp report_status(%ReportingState{latest_closed_on: nil}, _date), do: "open"

  defp report_status(state, date) do
    if Date.after?(date, state.latest_closed_on), do: "open", else: "closed"
  end

  defp max_date(left, right), do: if(Date.before?(left, right), do: right, else: left)

  defp rejected(operation, code) do
    %{operation_id: operation["operation_id"], status: "rejected", code: code}
  end
end
