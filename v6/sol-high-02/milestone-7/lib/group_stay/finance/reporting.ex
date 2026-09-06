defmodule GroupStay.Finance.Reporting do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Finance.{
    CashDisposition,
    CashMovement,
    CashOpening,
    CreditAllocation,
    CreditAvailabilityMovement,
    CreditLot,
    CreditLotPosition,
    CreditMovement,
    ReportingState,
    RoomCashAllocation
  }

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @cash_categories ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit_categories ~w(issued expired consumed revoked absorbed)

  def start(starts_on) do
    case state() do
      nil ->
        Repo.insert!(%ReportingState{
          id: 1,
          starts_on: starts_on,
          opening_credit_liability_cents: credit_liability(starts_on)
        })

        snapshot_cash_openings()
        snapshot_credit_lots(starts_on)
        :ok

      _state ->
        {:error, :reporting_already_started}
    end
  end

  def state, do: Repo.get(ReportingState, 1)

  def close(period_end_on) do
    case state() do
      nil ->
        {:error, :invalid_period}

      reporting ->
        valid_start = Date.compare(period_end_on, reporting.starts_on) != :lt

        if valid_start do
          case from(r in ReportingState,
                 where:
                   r.id == 1 and
                     (is_nil(r.latest_closed_on) or r.latest_closed_on < ^period_end_on)
               )
               |> Repo.update_all(set: [latest_closed_on: period_end_on]) do
            {1, nil} -> :ok
            {0, nil} -> {:error, :invalid_period}
          end
        else
          {:error, :invalid_period}
        end
    end
  end

  def cash(operation, property_id, category, amount_cents, payment_operation_id \\ nil)

  def cash(_operation, _property_id, _category, 0, _payment_operation_id), do: :ok

  def cash(operation, property_id, category, amount_cents, payment_operation_id)
      when category in @cash_categories do
    case posting_context(operation) do
      nil ->
        :ok

      {posting_date, late_adjustment} ->
        Repo.insert!(%CashMovement{
          operation_id: operation["operation_id"],
          payment_operation_id: payment_operation_id,
          property_id: property_id,
          posting_date: posting_date,
          category: category,
          amount_cents: amount_cents,
          late_adjustment: late_adjustment
        })

        :ok
    end
  end

  def credit(operation, category, amount_cents, credit_lot_id \\ nil)

  def credit(_operation, _category, 0, _credit_lot_id), do: :ok

  def credit(operation, category, amount_cents, credit_lot_id)
      when category in @credit_categories do
    case posting_context(operation) do
      nil ->
        :ok

      {posting_date, late_adjustment} ->
        Repo.insert!(%CreditMovement{
          operation_id: operation["operation_id"],
          credit_lot_id: credit_lot_id,
          posting_date: posting_date,
          category: category,
          amount_cents: amount_cents,
          late_adjustment: late_adjustment
        })

        :ok
    end
  end

  def availability(operation, %CreditLot{} = lot, amount_cents) do
    case posting_context(operation) do
      nil ->
        :ok

      {posting_date, _late_adjustment} ->
        cond do
          amount_cents != 0 and Date.compare(lot.expires_on, posting_date) == :lt ->
            credit(operation, "expired", amount_cents, lot.id)

          amount_cents != 0 and Date.compare(lot.expires_on, posting_date) != :lt ->
            ensure_credit_lot_position(lot)

            Repo.insert!(%CreditAvailabilityMovement{
              operation_id: operation["operation_id"],
              credit_lot_id: lot.id,
              posting_date: posting_date,
              amount_cents: amount_cents
            })

          true ->
            :ok
        end

        if amount_cents == 0 do
          ensure_credit_lot_position(lot)
        end

        :ok
    end
  end

  def credit_lot_active_on_posting?(operation, %CreditLot{} = lot) do
    case posting_context(operation) do
      nil ->
        false

      {posting_date, _late_adjustment} ->
        Date.compare(lot.expires_on, posting_date) != :lt
    end
  end

  def add_disposition(_payment_operation_id, _property_id, _category, 0), do: :ok

  def add_disposition(payment_operation_id, property_id, category, amount_cents)
      when category in ~w(refunded retained converted_to_credit) do
    case Repo.get_by(CashDisposition,
           payment_operation_id: payment_operation_id,
           property_id: property_id,
           category: category
         ) do
      nil ->
        Repo.insert!(%CashDisposition{
          payment_operation_id: payment_operation_id,
          property_id: property_id,
          category: category,
          amount_cents: amount_cents
        })

      disposition ->
        from(d in CashDisposition, where: d.id == ^disposition.id)
        |> Repo.update_all(inc: [amount_cents: amount_cents])
    end

    :ok
  end

  def take_dispositions(payment_operation_id) do
    dispositions =
      from(d in CashDisposition,
        where: d.payment_operation_id == ^payment_operation_id,
        order_by: d.id
      )
      |> Repo.all()

    from(d in CashDisposition, where: d.payment_operation_id == ^payment_operation_id)
    |> Repo.delete_all()

    dispositions
  end

  def daily_report(date) do
    case state() do
      nil ->
        {:error, :report_not_available}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :report_not_available}
        else
          cash = cash_report(reporting, date)
          credit = credit_report(reporting, date)

          {:ok,
           %{
             date: Date.to_iso8601(date),
             status: report_status(reporting, date),
             cash: cash.entries,
             credit: credit.entry,
             late_adjustments: %{
               cash: cash.late_adjustments,
               credit: suffix_movement_keys(credit.late_adjustments)
             }
           }}
        end
    end
  end

  defp posting_context(operation) do
    case state() do
      nil ->
        nil

      reporting ->
        {:ok, occurred_on} = Date.from_iso8601(operation["occurred_on"])
        ordinary_posting_date = max_date(occurred_on, reporting.starts_on)

        case reporting.latest_closed_on do
          nil ->
            {ordinary_posting_date, false}

          latest_closed_on ->
            first_open_date = Date.add(latest_closed_on, 1)
            posting_date = max_date(ordinary_posting_date, first_open_date)
            {posting_date, Date.compare(posting_date, ordinary_posting_date) == :gt}
        end
    end
  end

  defp max_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp report_status(%ReportingState{latest_closed_on: nil}, _date), do: "open"

  defp report_status(reporting, date) do
    if Date.compare(date, reporting.latest_closed_on) != :gt, do: "closed", else: "open"
  end

  defp snapshot_cash_openings do
    from(a in RoomCashAllocation,
      join: r in Room,
      on: r.id == a.room_id,
      join: g in Group,
      on: g.group_id == a.group_id,
      where: r.status == "active" and g.status == "active",
      group_by: g.property_id,
      select: {g.property_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Enum.each(fn {property_id, amount} ->
      Repo.insert!(%CashOpening{property_id: property_id, opening_held_cents: amount})
    end)
  end

  defp snapshot_credit_lots(starts_on) do
    from(l in CreditLot, where: l.expires_on >= ^starts_on)
    |> Repo.all()
    |> Enum.each(fn lot ->
      Repo.insert!(%CreditLotPosition{
        credit_lot_id: lot.id,
        expires_on: lot.expires_on,
        opening_available_cents: lot.remaining_cents
      })
    end)
  end

  defp ensure_credit_lot_position(lot) do
    if is_nil(Repo.get_by(CreditLotPosition, credit_lot_id: lot.id)) do
      Repo.insert!(%CreditLotPosition{
        credit_lot_id: lot.id,
        expires_on: lot.expires_on,
        opening_available_cents: 0
      })
    end
  end

  defp credit_liability(as_of) do
    available =
      from(l in CreditLot,
        where: l.expires_on >= ^as_of and l.remaining_cents > 0,
        select: coalesce(sum(l.remaining_cents), 0)
      )
      |> Repo.one()

    applied =
      from(a in CreditAllocation,
        join: g in Group,
        on: g.group_id == a.group_id,
        where: g.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
      )
      |> Repo.one()

    available + applied
  end

  defp cash_report(_reporting, date) do
    openings =
      from(o in CashOpening, select: {o.property_id, o.opening_held_cents})
      |> Repo.all()
      |> Map.new()

    movements =
      from(m in CashMovement,
        where: m.posting_date <= ^date,
        order_by: m.id
      )
      |> Repo.all()

    properties =
      (Map.keys(openings) ++ Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    {entries, late_adjustments} =
      Enum.reduce(properties, {[], []}, fn property_id, {entries, late_adjustments} ->
        property_movements = Enum.filter(movements, &(&1.property_id == property_id))

        opening =
          Map.get(openings, property_id, 0) +
            (property_movements
             |> Enum.filter(&(Date.compare(&1.posting_date, date) == :lt))
             |> Enum.sum_by(&cash_effect/1))

        ordinary_movements =
          property_movements
          |> Enum.filter(&(&1.posting_date == date and not &1.late_adjustment))
          |> movement_totals(@cash_categories)

        late_movements =
          property_movements
          |> Enum.filter(&(&1.posting_date == date and &1.late_adjustment))
          |> movement_totals(@cash_categories)

        closing = opening + cash_effect(ordinary_movements) + cash_effect(late_movements)

        entry =
          if opening == 0 and closing == 0 and
               all_zero?(ordinary_movements) and all_zero?(late_movements) do
            []
          else
            [
              %{
                property_id: property_id,
                opening_held_cents: opening,
                movements: suffix_movement_keys(ordinary_movements),
                closing_held_cents: closing
              }
            ]
          end

        late_entry =
          if all_zero?(late_movements) do
            []
          else
            [%{property_id: property_id, movements: suffix_movement_keys(late_movements)}]
          end

        {entries ++ entry, late_adjustments ++ late_entry}
      end)

    %{entries: entries, late_adjustments: late_adjustments}
  end

  defp credit_report(reporting, date) do
    movements =
      from(m in CreditMovement,
        where: m.posting_date <= ^date,
        order_by: m.id
      )
      |> Repo.all()

    scheduled = scheduled_expiries()

    expired_before =
      scheduled
      |> Enum.filter(fn {expiry_date, _amount} -> Date.compare(expiry_date, date) == :lt end)
      |> Enum.sum_by(&elem(&1, 1))

    opening =
      reporting.opening_credit_liability_cents +
        (movements
         |> Enum.filter(&(Date.compare(&1.posting_date, date) == :lt))
         |> Enum.sum_by(&credit_effect/1)) - expired_before

    ordinary_movements =
      movements
      |> Enum.filter(&(&1.posting_date == date and not &1.late_adjustment))
      |> movement_totals(@credit_categories)
      |> Map.update!("expired", fn explicit_expired ->
        scheduled_today =
          scheduled
          |> Enum.filter(fn {expiry_date, _amount} -> expiry_date == date end)
          |> Enum.sum_by(&elem(&1, 1))

        explicit_expired + scheduled_today
      end)

    late_movements =
      movements
      |> Enum.filter(&(&1.posting_date == date and &1.late_adjustment))
      |> movement_totals(@credit_categories)

    closing = opening + credit_effect(ordinary_movements) + credit_effect(late_movements)

    %{
      entry: %{
        opening_liability_cents: opening,
        movements: suffix_movement_keys(ordinary_movements),
        closing_liability_cents: closing
      },
      late_adjustments: late_movements
    }
  end

  defp scheduled_expiries do
    positions = Repo.all(CreditLotPosition)

    activity_by_lot =
      from(a in CreditAvailabilityMovement, order_by: a.id)
      |> Repo.all()
      |> Enum.group_by(& &1.credit_lot_id)

    Enum.map(positions, fn position ->
      activity =
        activity_by_lot
        |> Map.get(position.credit_lot_id, [])
        |> Enum.filter(&(Date.compare(&1.posting_date, position.expires_on) != :gt))
        |> Enum.sum_by(& &1.amount_cents)

      {Date.add(position.expires_on, 1), max(position.opening_available_cents + activity, 0)}
    end)
  end

  defp movement_totals(movements, categories) do
    totals = Map.new(categories, &{&1, 0})

    Enum.reduce(
      movements,
      totals,
      &Map.update!(&2, &1.category, fn total -> total + &1.amount_cents end)
    )
  end

  defp cash_effect(%CashMovement{category: category, amount_cents: amount}),
    do: cash_effect(category, amount)

  defp cash_effect(movements) when is_map(movements) do
    movements["received"] + movements["transferred_in"] - movements["transferred_out"] -
      movements["refunded"] - movements["retained"] - movements["converted_to_credit"] -
      movements["reduced"] - movements["charged_back"]
  end

  defp cash_effect(category, amount) when category in ~w(received transferred_in), do: amount
  defp cash_effect(_category, amount), do: -amount

  defp credit_effect(%CreditMovement{category: category, amount_cents: amount}),
    do: credit_effect(category, amount)

  defp credit_effect(movements) when is_map(movements) do
    movements["issued"] - movements["expired"] - movements["consumed"] -
      movements["revoked"] - movements["absorbed"]
  end

  defp credit_effect("issued", amount), do: amount
  defp credit_effect(_category, amount), do: -amount

  defp suffix_movement_keys(map) do
    Map.new(map, fn {key, value} -> {key <> "_cents", value} end)
  end

  defp all_zero?(movements), do: Enum.all?(movements, fn {_key, value} -> value == 0 end)
end
