defmodule GroupStay.Finance do
  @moduledoc """
  Builds daily finance reports from an inception snapshot and durably posted movements.

  The snapshot is taken in processing order when reporting starts. Subsequent accounting effects
  are appended with a reporting date fixed at commit time. Closing a period materializes each newly
  published report, so later partner submissions can affect only open reports.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias GroupStay.Deposits.{CashAllocation, CreditAllocation, CreditLot, Group}

  alias GroupStay.Finance.{
    CashOpening,
    CreditAvailabilityChange,
    Movement,
    PeriodClose,
    ReportingStart,
    ReportSnapshot
  }

  alias GroupStay.Repo

  @cash_kinds ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_kinds ~w(issued expired consumed revoked absorbed)

  @doc "Starts reporting and captures the financial position immediately before this operation."
  def start(starts_on) do
    if Repo.exists?(ReportingStart) do
      {:error, :reporting_already_started}
    else
      opening_credit = current_credit_liability(starts_on)

      with {:ok, start} <-
             %ReportingStart{}
             |> Changeset.cast(
               %{starts_on: starts_on, opening_credit_liability_cents: opening_credit},
               [:starts_on, :opening_credit_liability_cents]
             )
             |> Repo.insert(),
           :ok <- capture_cash_openings(start),
           :ok <- capture_credit_availability(starts_on) do
        {:ok, start}
      end
    end
  end

  @doc "Closes every report through a strictly advancing cutoff and publishes durable snapshots."
  def close(period_end_on) do
    with %ReportingStart{} = start <- reporting_start(),
         :ok <- validate_period(start, period_end_on),
         previous_cutoff = latest_cutoff(),
         {:ok, _close} <-
           %PeriodClose{}
           |> Changeset.cast(%{period_end_on: period_end_on}, [:period_end_on])
           |> Repo.insert(),
         :ok <- publish_reports(start, previous_cutoff, period_end_on) do
      :ok
    else
      nil -> {:error, :invalid_period}
      {:error, :invalid_period} = error -> error
      {:error, error} -> {:error, error}
    end
  end

  @doc "Appends one cash movement if reporting has started."
  def record_cash(operation, property_id, kind, amount)
      when kind in @cash_kinds and is_integer(amount) do
    record_movement(operation, "cash", property_id, kind, amount)
  end

  @doc "Appends one company-wide credit-liability movement if reporting has started."
  def record_credit(operation, kind, amount) when kind in @credit_kinds and is_integer(amount) do
    record_movement(operation, "credit", nil, kind, amount)
  end

  @doc "Tracks changes to credit which is available and therefore subject to natural expiry."
  def change_available_credit(operation, lot_id, amount) when is_integer(amount) do
    case reporting_start() do
      nil ->
        :ok

      start ->
        {posting_on, _late_adjustment?} = posting_details(operation, start.starts_on)

        %CreditAvailabilityChange{}
        |> Changeset.cast(
          %{
            credit_lot_id: lot_id,
            operation_id: operation["operation_id"],
            posting_on: posting_on,
            amount_cents: amount
          },
          [:credit_lot_id, :operation_id, :posting_on, :amount_cents]
        )
        |> Repo.insert()
        |> result_to_ok()
    end
  end

  @doc "Moves available credit into a deposit without losing a previously published expiry."
  def apply_available_credit(operation, %CreditLot{} = lot, amount)
      when is_integer(amount) and amount > 0 do
    if credit_available_on_posting?(operation, lot.expires_on) do
      change_available_credit(operation, lot.id, -amount)
    else
      # The deposit pauses expiry in current state. If the posting date is already beyond the lot's
      # expiry, its natural expiry belongs to an earlier (possibly closed) report, so reverse that
      # classification on this operation's fixed posting date.
      record_credit(operation, "expired", -amount)
    end
  end

  @doc "Returns whether a lot is still an available liability on an operation's posting date."
  def credit_available_on_posting?(operation, expires_on) do
    case reporting_start() do
      nil ->
        true

      start ->
        {posting_on, _late_adjustment?} = posting_details(operation, start.starts_on)
        not Date.after?(posting_on, expires_on)
    end
  end

  @doc "Returns the daily report, or reports that its requested date predates inception."
  def daily_report(date) do
    case reporting_start() do
      nil ->
        {:error, :report_not_available}

      start ->
        cond do
          Date.before?(date, start.starts_on) ->
            {:error, :report_not_available}

          snapshot = Repo.get_by(ReportSnapshot, report_on: date) ->
            {:ok, snapshot.data}

          true ->
            {:ok, build_report(start, date, "open")}
        end
    end
  end

  defp build_report(start, date, status) do
    movements = Repo.all(from m in Movement, where: m.posting_on <= ^date)
    cash_openings = Repo.all(CashOpening)
    cash = build_cash(cash_openings, movements, date)
    credit = build_credit(start, movements, date)

    %{
      date: date,
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: build_late_adjustments(movements, date)
    }
  end

  defp build_cash(openings, movements, date) do
    opening_by_property = Map.new(openings, &{&1.property_id, &1.opening_held_cents})

    cash_movements = Enum.filter(movements, &(&1.account == "cash"))

    properties =
      (Map.keys(opening_by_property) ++ Enum.map(cash_movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      prior =
        Enum.filter(
          cash_movements,
          &(&1.property_id == property_id and Date.before?(&1.posting_on, date))
        )

      today =
        Enum.filter(cash_movements, &(&1.property_id == property_id and &1.posting_on == date))

      ordinary_today = Enum.reject(today, & &1.late_adjustment)

      opening = Map.get(opening_by_property, property_id, 0) + cash_delta(prior)
      totals = movement_totals(ordinary_today, @cash_kinds)
      all_totals = movement_totals(today, @cash_kinds)
      closing = opening + cash_delta(today)

      if opening == 0 and closing == 0 and
           Enum.all?(all_totals, fn {_kind, amount} -> amount == 0 end) do
        []
      else
        [
          %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: suffix_keys(totals),
            closing_held_cents: closing
          }
        ]
      end
    end)
  end

  defp build_credit(start, movements, date) do
    credit_movements = Enum.filter(movements, &(&1.account == "credit"))
    expiries = natural_expiries(start.starts_on, date)

    prior = Enum.filter(credit_movements, &Date.before?(&1.posting_on, date))
    today = Enum.filter(credit_movements, &(&1.posting_on == date))
    ordinary_today = Enum.reject(today, & &1.late_adjustment)

    opening =
      start.opening_credit_liability_cents + credit_delta(prior) - prior_expiries(expiries, date)

    totals =
      movement_totals(ordinary_today, @credit_kinds)
      |> Map.update!("expired", &(&1 + Map.get(expiries, date, 0)))

    closing = opening + credit_delta(today) - Map.get(expiries, date, 0)

    %{
      opening_liability_cents: opening,
      movements: suffix_keys(totals),
      closing_liability_cents: closing
    }
  end

  defp build_late_adjustments(movements, date) do
    late_today = Enum.filter(movements, &(&1.posting_on == date and &1.late_adjustment))

    cash =
      late_today
      |> Enum.filter(&(&1.account == "cash"))
      |> Enum.group_by(& &1.property_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {property_id, property_movements} ->
        totals = movement_totals(property_movements, @cash_kinds)

        if Enum.all?(totals, fn {_kind, amount} -> amount == 0 end),
          do: [],
          else: [%{property_id: property_id, movements: suffix_keys(totals)}]
      end)

    credit =
      late_today
      |> Enum.filter(&(&1.account == "credit"))
      |> movement_totals(@credit_kinds)
      |> suffix_keys()

    %{cash: cash, credit: credit}
  end

  defp cash_delta(movements) do
    Enum.sum_by(movements, fn movement ->
      if movement.kind in ~w(received transferred_in),
        do: movement.amount_cents,
        else: -movement.amount_cents
    end)
  end

  defp credit_delta(movements) do
    Enum.sum_by(movements, fn movement ->
      if movement.kind == "issued", do: movement.amount_cents, else: -movement.amount_cents
    end)
  end

  defp movement_totals(movements, kinds) do
    Map.new(kinds, fn kind ->
      {kind,
       movements
       |> Enum.filter(&(&1.kind == kind))
       |> Enum.sum_by(& &1.amount_cents)}
    end)
  end

  defp suffix_keys(totals),
    do: Map.new(totals, fn {kind, amount} -> {String.to_atom(kind <> "_cents"), amount} end)

  defp natural_expiries(starts_on, through_date) do
    changes =
      Repo.all(
        from c in CreditAvailabilityChange,
          join: l in CreditLot,
          on: l.id == c.credit_lot_id,
          select: {c.credit_lot_id, c.posting_on, c.amount_cents, l.expires_on}
      )

    changes
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {_lot_id, lot_changes}, expiries ->
      expires_on = lot_changes |> hd() |> elem(3) |> Date.add(1)

      if Date.after?(expires_on, starts_on) and not Date.after?(expires_on, through_date) do
        amount =
          lot_changes
          |> Enum.filter(&Date.before?(elem(&1, 1), expires_on))
          |> Enum.sum_by(&elem(&1, 2))
          |> max(0)

        Map.update(expiries, expires_on, amount, &(&1 + amount))
      else
        expiries
      end
    end)
  end

  defp prior_expiries(expiries, date),
    do:
      expiries
      |> Enum.filter(fn {day, _} -> Date.before?(day, date) end)
      |> Enum.sum_by(&elem(&1, 1))

  defp capture_cash_openings(start) do
    Repo.all(
      from a in CashAllocation,
        join: g in Group,
        on: g.id == a.group_id,
        group_by: g.property_id,
        select: {g.property_id, sum(a.amount_cents)}
    )
    |> Enum.reduce_while(:ok, fn {property_id, amount}, :ok ->
      case %CashOpening{}
           |> Changeset.cast(
             %{
               reporting_start_id: start.id,
               property_id: property_id,
               opening_held_cents: amount
             },
             [:reporting_start_id, :property_id, :opening_held_cents]
           )
           |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp capture_credit_availability(starts_on) do
    Repo.all(from l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^starts_on)
    |> Enum.reduce_while(:ok, fn lot, :ok ->
      case %CreditAvailabilityChange{}
           |> Changeset.cast(
             %{credit_lot_id: lot.id, posting_on: starts_on, amount_cents: lot.remaining_cents},
             [:credit_lot_id, :posting_on, :amount_cents]
           )
           |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp current_credit_liability(on) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      ) || 0

    allocated =
      Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0)) || 0

    available + allocated
  end

  defp record_movement(_operation, _account, _property_id, _kind, 0), do: :ok

  defp record_movement(operation, account, property_id, kind, amount) do
    case reporting_start() do
      nil ->
        :ok

      start ->
        {posting_on, late_adjustment?} = posting_details(operation, start.starts_on)

        %Movement{}
        |> Changeset.cast(
          %{
            operation_id: operation["operation_id"],
            posting_on: posting_on,
            account: account,
            property_id: property_id,
            kind: kind,
            amount_cents: amount,
            late_adjustment: late_adjustment?
          },
          [
            :operation_id,
            :posting_on,
            :account,
            :property_id,
            :kind,
            :amount_cents,
            :late_adjustment
          ]
        )
        |> Repo.insert()
        |> result_to_ok()
    end
  end

  defp posting_details(operation, starts_on) do
    {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
    cutoff = latest_cutoff()
    first_open_on = if cutoff, do: Date.add(cutoff, 1), else: starts_on
    posting_on = latest_date([occurred_on, starts_on, first_open_on])
    moved_by_close? = not is_nil(cutoff) and Date.before?(occurred_on, first_open_on)
    {posting_on, moved_by_close?}
  end

  defp validate_period(start, period_end_on) do
    cutoff = latest_cutoff()

    if Date.before?(period_end_on, start.starts_on) or
         (cutoff && not Date.after?(period_end_on, cutoff)),
       do: {:error, :invalid_period},
       else: :ok
  end

  defp publish_reports(start, previous_cutoff, period_end_on) do
    first_new_date = if previous_cutoff, do: Date.add(previous_cutoff, 1), else: start.starts_on

    Date.range(first_new_date, period_end_on)
    |> Enum.reduce_while(:ok, fn date, :ok ->
      data = build_report(start, date, "closed") |> json_value()

      case %ReportSnapshot{}
           |> Changeset.cast(%{report_on: date, data: data}, [:report_on, :data])
           |> Repo.insert() do
        {:ok, _snapshot} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp latest_cutoff do
    Repo.one(from c in PeriodClose, select: max(c.period_end_on))
  end

  defp latest_date([first | rest]) do
    Enum.reduce(rest, first, fn date, latest ->
      if Date.after?(date, latest), do: date, else: latest
    end)
  end

  defp reporting_start, do: Repo.one(from s in ReportingStart, limit: 1)
  defp result_to_ok({:ok, _}), do: :ok
  defp result_to_ok({:error, error}), do: {:error, error}

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
