defmodule GroupStay.Finance do
  import Ecto.Query

  alias GroupStay.Finance.{CashOpening, CreditExpiration, DailyReport, Movement, Reporting}
  alias GroupStay.Groups.{CashAllocation, CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  def start(starts_on) do
    if Repo.get(Reporting, 1) do
      {:error, :reporting_already_started}
    else
      opening_credit = current_credit_liability(starts_on)

      Repo.insert!(%Reporting{
        id: 1,
        starts_on: starts_on,
        opening_credit_liability_cents: opening_credit
      })

      cash_opening()
      credit_expirations(starts_on)

      {:ok, %{starts_on: starts_on}}
    end
  end

  def report(on) do
    Repo.transaction(fn -> report_in_transaction(on) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def close(period_end_on) do
    case Repo.get(Reporting, 1) do
      nil ->
        {:error, :invalid_period}

      reporting ->
        valid_start = not Date.before?(period_end_on, reporting.starts_on)

        valid_cutoff =
          is_nil(reporting.latest_closed_on) or
            Date.after?(period_end_on, reporting.latest_closed_on)

        if valid_start and valid_cutoff do
          first_on =
            if reporting.latest_closed_on,
              do: Date.add(reporting.latest_closed_on, 1),
              else: reporting.starts_on

          first_on
          |> Date.range(period_end_on)
          |> Enum.each(fn on ->
            data = build_report(reporting, on, "closed") |> json_value()
            Repo.insert!(%DailyReport{date: on, data: data})
          end)

          reporting
          |> Ecto.Changeset.change(latest_closed_on: period_end_on)
          |> Repo.update!()

          {:ok, %{period_end_on: period_end_on}}
        else
          {:error, :invalid_period}
        end
    end
  end

  def record(operation_id, occurred_on, attrs) do
    case Repo.get(Reporting, 1) do
      nil ->
        :ok

      reporting ->
        {posting_on, late_adjustment} = posting_date(occurred_on, reporting)

        attrs =
          attrs
          |> Map.new()
          |> Map.put(:operation_id, operation_id)
          |> Map.put(:posting_on, posting_on)
          |> Map.put(:late_adjustment, late_adjustment)

        Repo.insert!(struct(Movement, attrs))
        :ok
    end
  end

  def schedule_expiration(lot, amount) when amount > 0 do
    case Repo.get(Reporting, 1) do
      nil ->
        :ok

      reporting ->
        expiration_on = later_date(Date.add(lot.expires_on, 1), reporting.starts_on)
        expiration = Repo.get(CreditExpiration, lot.id)

        if expiration do
          expiration
          |> Ecto.Changeset.change(amount_cents: expiration.amount_cents + amount)
          |> Repo.update!()
        else
          Repo.insert!(%CreditExpiration{
            credit_lot_id: lot.id,
            expires_on: expiration_on,
            amount_cents: amount
          })
        end

        record_expiration(lot, expiration_on, amount, reporting)

        :ok
    end
  end

  def schedule_expiration(_lot, _amount), do: :ok

  def unschedule_expiration(lot, amount) when amount > 0 do
    case Repo.get(CreditExpiration, lot.id) do
      nil ->
        :ok

      expiration ->
        removed = min(expiration.amount_cents, amount)

        expiration
        |> Ecto.Changeset.change(amount_cents: expiration.amount_cents - removed)
        |> Repo.update!()

        if removed > 0 do
          reporting = Repo.get!(Reporting, 1)
          record_expiration(lot, expiration.expires_on, -removed, reporting)
        end

        :ok
    end
  end

  def unschedule_expiration(_lot, _amount), do: :ok

  defp cash_opening do
    Repo.all(
      from allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.group_id,
        group_by: group.property_id,
        select: {group.property_id, sum(allocation.amount_cents)}
    )
    |> Enum.each(fn {property_id, held} ->
      Repo.insert!(%CashOpening{property_id: property_id, held_cents: held})
    end)
  end

  defp credit_expirations(starts_on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^starts_on
    )
    |> Enum.each(&schedule_expiration(&1, &1.remaining_cents))
  end

  defp report_in_transaction(on) do
    case Repo.get(Reporting, 1) do
      nil ->
        {:error, :report_not_available}

      reporting ->
        if Date.before?(on, reporting.starts_on),
          do: {:error, :report_not_available},
          else: {:ok, stored_or_open_report(reporting, on)}
    end
  end

  defp stored_or_open_report(reporting, on) do
    case Repo.get(DailyReport, on) do
      nil -> build_report(reporting, on, "open")
      report -> report.data
    end
  end

  defp build_report(reporting, on, status) do
    openings = Repo.all(CashOpening) |> Map.new(&{&1.property_id, &1.held_cents})
    movements = Repo.all(from movement in Movement, where: movement.posting_on <= ^on)

    properties =
      movements
      |> Enum.reject(&is_nil(&1.property_id))
      |> Enum.map(& &1.property_id)
      |> Kernel.++(Map.keys(openings))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(&cash_report(&1, Map.get(openings, &1, 0), movements, on))
      |> Enum.reject(&empty_cash?/1)

    late_cash =
      properties
      |> Enum.map(&late_cash_report(&1, movements, on))
      |> Enum.reject(&empty_movements?(&1.movements))

    %{
      date: on,
      status: status,
      cash: cash,
      credit: credit_report(reporting, movements, on),
      late_adjustments: %{
        cash: late_cash,
        credit: daily_sums(movements, on, @credit_fields, true)
      }
    }
  end

  defp cash_report(property_id, inception, movements, on) do
    prior =
      Enum.filter(movements, fn movement ->
        movement.property_id == property_id and Date.before?(movement.posting_on, on)
      end)

    daily = daily_movements(movements, on, false, property_id)

    opening = inception + Enum.sum(Enum.map(prior, &cash_delta/1))
    movement = sums(daily, @cash_fields)
    late_movement = sums(daily_movements(movements, on, true, property_id), @cash_fields)

    %{
      property_id: property_id,
      opening_held_cents: opening,
      movements: movement,
      closing_held_cents: opening + cash_delta(movement) + cash_delta(late_movement)
    }
  end

  defp late_cash_report(property_id, movements, on) do
    %{
      property_id: property_id,
      movements: sums(daily_movements(movements, on, true, property_id), @cash_fields)
    }
  end

  defp credit_report(reporting, movements, on) do
    opening_liability = reporting.opening_credit_liability_cents
    prior = Enum.filter(movements, &Date.before?(&1.posting_on, on))
    daily = daily_movements(movements, on, false)
    opening = opening_liability + Enum.sum(Enum.map(prior, &credit_delta/1))
    movement = sums(daily, @credit_fields)
    late_movement = daily_sums(movements, on, @credit_fields, true)

    %{
      opening_liability_cents: opening,
      movements: movement,
      closing_liability_cents: opening + credit_delta(movement) + credit_delta(late_movement)
    }
  end

  defp current_credit_liability(on) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    allocated =
      Repo.one(
        from allocation in CreditAllocation, select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + allocated
  end

  defp record_expiration(lot, baseline_on, amount, reporting) do
    {posting_on, late_adjustment} = posting_date(baseline_on, reporting)

    Repo.insert!(%Movement{
      operation_id: "credit-expiration:#{lot.id}",
      posting_on: posting_on,
      late_adjustment: late_adjustment,
      expired_cents: amount
    })
  end

  defp posting_date(baseline_on, reporting) do
    baseline_on = later_date(baseline_on, reporting.starts_on)

    case reporting.latest_closed_on do
      nil ->
        {baseline_on, false}

      cutoff ->
        posting_on = later_date(baseline_on, Date.add(cutoff, 1))
        {posting_on, Date.after?(posting_on, baseline_on)}
    end
  end

  defp daily_movements(movements, on, late_adjustment, property_id \\ :all) do
    Enum.filter(movements, fn movement ->
      Date.compare(movement.posting_on, on) == :eq and
        movement.late_adjustment == late_adjustment and
        (property_id == :all or movement.property_id == property_id)
    end)
  end

  defp daily_sums(movements, on, fields, late_adjustment) do
    movements
    |> daily_movements(on, late_adjustment)
    |> sums(fields)
  end

  defp sums(entries, fields) do
    Map.new(fields, fn field -> {field, Enum.sum(Enum.map(entries, &Map.fetch!(&1, field)))} end)
  end

  defp cash_delta(entry) do
    entry.received_cents + entry.transferred_in_cents - entry.transferred_out_cents -
      entry.refunded_cents - entry.retained_cents - entry.converted_to_credit_cents -
      entry.reduced_cents - entry.charged_back_cents
  end

  defp credit_delta(entry) do
    entry.issued_cents - entry.expired_cents - entry.consumed_cents - entry.revoked_cents -
      entry.absorbed_cents
  end

  defp empty_cash?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      Enum.all?(entry.movements, fn {_field, value} -> value == 0 end)
  end

  defp empty_movements?(movements), do: Enum.all?(movements, fn {_field, value} -> value == 0 end)

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp later_date(left, right) do
    if Date.before?(left, right), do: right, else: left
  end
end
