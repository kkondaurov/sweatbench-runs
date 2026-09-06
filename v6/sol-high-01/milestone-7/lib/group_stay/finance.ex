defmodule GroupStay.Finance do
  @moduledoc false

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Bookings.{
    CreditLot,
    FinanceCashMovement,
    FinanceCashOpening,
    FinanceCreditExpiry,
    FinanceCreditMovement,
    FinanceReporting,
    Group,
    Room,
    RoomFundingAllocation
  }

  alias GroupStay.Repo

  @cash_fields ~w(received_cents transferred_in_cents transferred_out_cents refunded_cents
                  retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a
  @credit_fields ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

  def start(starts_on) do
    if Repo.get(FinanceReporting, 1) do
      {:error, :already_started}
    else
      opening_cash = held_cash_by_property()
      applied_credit = active_credit_by_lot() |> Map.values() |> Enum.sum()

      available_lots =
        Repo.all(
          from lot in CreditLot,
            where: lot.remaining_cents > 0 and lot.expires_on >= ^starts_on
        )

      Repo.insert!(%FinanceReporting{
        id: 1,
        starts_on: starts_on,
        opening_credit_liability_cents:
          applied_credit + Enum.sum(Enum.map(available_lots, & &1.remaining_cents))
      })

      Enum.each(opening_cash, fn {property_id, amount} ->
        Repo.insert!(%FinanceCashOpening{property_id: property_id, amount_cents: amount})
      end)

      Enum.each(available_lots, fn lot ->
        Repo.insert!(%FinanceCreditExpiry{
          credit_lot_id: lot.id,
          posting_on: max_date(Date.add(lot.expires_on, 1), starts_on),
          amount_cents: lot.remaining_cents
        })
      end)

      :ok
    end
  end

  def close(period_end_on) do
    case reporting() do
      nil ->
        {:error, :invalid_period}

      reporting ->
        valid_start? = Date.compare(period_end_on, reporting.starts_on) != :lt

        later_than_previous? =
          is_nil(reporting.closed_through) or
            Date.compare(period_end_on, reporting.closed_through) == :gt

        if valid_start? and later_than_previous? do
          reporting |> change(closed_through: period_end_on) |> Repo.update!()
          :ok
        else
          {:error, :invalid_period}
        end
    end
  end

  def record_cash(operation_id, occurred_on, movements_by_property) do
    case reporting() do
      nil ->
        :ok

      reporting ->
        {posting_on, late_adjustment} = posting_details(occurred_on, reporting)

        movements_by_property
        |> Enum.reject(fn {_property_id, values} -> zero_values?(values, @cash_fields) end)
        |> Enum.each(fn {property_id, values} ->
          Repo.insert!(
            struct!(
              FinanceCashMovement,
              %{
                operation_id: operation_id,
                posting_on: posting_on,
                late_adjustment: late_adjustment,
                property_id: property_id
              }
              |> Map.merge(normalize(values, @cash_fields))
            )
          )
        end)
    end
  end

  def record_credit(operation_id, occurred_on, values) do
    case reporting() do
      nil ->
        :ok

      reporting ->
        add_credit_movement(operation_id, occurred_on, values, reporting)
    end
  end

  def schedule_expiry(%CreditLot{} = lot, amount, occurred_on, operation_id) when amount > 0 do
    case reporting() do
      nil ->
        :ok

      reporting ->
        if Date.compare(occurred_on, lot.expires_on) != :gt do
          natural_posting_on = max_date(Date.add(lot.expires_on, 1), reporting.starts_on)
          {posting_on, late_adjustment} = posting_details(natural_posting_on, reporting)

          case Repo.get_by(FinanceCreditExpiry, credit_lot_id: lot.id) do
            nil ->
              Repo.insert!(%FinanceCreditExpiry{
                credit_lot_id: lot.id,
                posting_on: posting_on,
                late_adjustment: late_adjustment,
                amount_cents: amount
              })

            expiry ->
              if closed?(expiry.posting_on, reporting) do
                add_credit_movement(
                  operation_id,
                  occurred_on,
                  %{expired_cents: amount},
                  reporting
                )
              else
                expiry |> change(amount_cents: expiry.amount_cents + amount) |> Repo.update!()
              end
          end
        end
    end

    :ok
  end

  def schedule_expiry(_lot, _amount, _occurred_on, _operation_id), do: :ok

  def unschedule_expiry(%CreditLot{} = lot, amount, occurred_on, operation_id) when amount > 0 do
    if Date.compare(occurred_on, lot.expires_on) != :gt do
      case Repo.get_by(FinanceCreditExpiry, credit_lot_id: lot.id) do
        nil ->
          :ok

        expiry ->
          if closed?(expiry.posting_on, reporting()) do
            add_credit_movement(
              operation_id,
              occurred_on,
              %{expired_cents: -amount},
              reporting()
            )
          else
            remaining = expiry.amount_cents - amount

            cond do
              remaining > 0 -> expiry |> change(amount_cents: remaining) |> Repo.update!()
              remaining == 0 -> Repo.delete!(expiry)
              true -> raise "finance credit expiry invariant violated"
            end
          end
      end
    end

    :ok
  end

  def unschedule_expiry(_lot, _amount, _occurred_on, _operation_id), do: :ok

  def daily_report(date) do
    case reporting() do
      nil ->
        :not_available

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          :not_available
        else
          {cash, late_cash} = cash_report(reporting, date)
          {credit, late_credit} = credit_report(reporting, date)

          {:ok,
           %{
             date: Date.to_iso8601(date),
             status: if(closed?(date, reporting), do: "closed", else: "open"),
             cash: cash,
             credit: credit,
             late_adjustments: %{cash: late_cash, credit: late_credit}
           }}
        end
    end
  end

  defp cash_report(_reporting, date) do
    openings =
      Repo.all(FinanceCashOpening)
      |> Map.new(&{&1.property_id, &1.amount_cents})

    movements =
      Repo.all(from movement in FinanceCashMovement, where: movement.posting_on <= ^date)

    properties =
      (Map.keys(openings) ++ Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(properties, {[], []}, fn property_id, {cash_entries, late_entries} ->
      property_movements = Enum.filter(movements, &(&1.property_id == property_id))
      before = Enum.filter(property_movements, &(Date.compare(&1.posting_on, date) == :lt))
      today = Enum.filter(property_movements, &(Date.compare(&1.posting_on, date) == :eq))
      ordinary_today = Enum.reject(today, & &1.late_adjustment)
      late_today = Enum.filter(today, & &1.late_adjustment)
      opening = Map.get(openings, property_id, 0) + cash_effect(before)
      ordinary_data = sum_fields(ordinary_today, @cash_fields)
      late_data = sum_fields(late_today, @cash_fields)
      total_data = add_fields(ordinary_data, late_data, @cash_fields)
      closing = opening + cash_effect(total_data)

      cash_entries =
        if opening == 0 and closing == 0 and zero_values?(ordinary_data, @cash_fields) and
             zero_values?(late_data, @cash_fields) do
          cash_entries
        else
          cash_entries ++
            [
              %{
                property_id: property_id,
                opening_held_cents: opening,
                movements: ordinary_data,
                closing_held_cents: closing
              }
            ]
        end

      late_entries =
        if zero_values?(late_data, @cash_fields) do
          late_entries
        else
          late_entries ++ [%{property_id: property_id, movements: late_data}]
        end

      {cash_entries, late_entries}
    end)
  end

  defp credit_report(reporting, date) do
    operation_movements =
      Repo.all(from movement in FinanceCreditMovement, where: movement.posting_on <= ^date)

    expiries = Repo.all(from expiry in FinanceCreditExpiry, where: expiry.posting_on <= ^date)

    before =
      Enum.filter(operation_movements, &(Date.compare(&1.posting_on, date) == :lt)) ++
        Enum.map(
          Enum.filter(expiries, &(Date.compare(&1.posting_on, date) == :lt)),
          &expiry_values/1
        )

    today =
      Enum.filter(operation_movements, &(Date.compare(&1.posting_on, date) == :eq)) ++
        Enum.map(
          Enum.filter(expiries, &(Date.compare(&1.posting_on, date) == :eq)),
          &expiry_values/1
        )

    opening = reporting.opening_credit_liability_cents + credit_effect(before)
    ordinary_data = sum_fields(Enum.reject(today, & &1.late_adjustment), @credit_fields)
    late_data = sum_fields(Enum.filter(today, & &1.late_adjustment), @credit_fields)
    total_data = add_fields(ordinary_data, late_data, @credit_fields)

    {%{
       opening_liability_cents: opening,
       movements: ordinary_data,
       closing_liability_cents: opening + credit_effect(total_data)
     }, late_data}
  end

  defp expiry_values(expiry),
    do: %{expired_cents: expiry.amount_cents, late_adjustment: expiry.late_adjustment}

  defp held_cash_by_property do
    Repo.all(
      from allocation in RoomFundingAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.group_id == room.group_id,
        where: allocation.funding_type == "cash" and room.status == "active",
        group_by: group.property_id,
        select: {group.property_id, sum(allocation.amount_cents)}
    )
    |> Map.new()
  end

  defp active_credit_by_lot do
    Repo.all(
      from allocation in RoomFundingAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.funding_type == "credit" and room.status == "active",
        group_by: allocation.credit_lot_id,
        select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
    )
    |> Map.new()
  end

  defp reporting, do: Repo.get(FinanceReporting, 1)

  defp posting_details(occurred_on, reporting) do
    natural_posting_on = max_date(occurred_on, reporting.starts_on)

    posting_on =
      case reporting.closed_through do
        nil -> natural_posting_on
        closed_through -> max_date(natural_posting_on, Date.add(closed_through, 1))
      end

    {posting_on, Date.compare(posting_on, natural_posting_on) == :gt}
  end

  defp add_credit_movement(operation_id, occurred_on, values, reporting) do
    unless zero_values?(values, @credit_fields) do
      normalized = normalize(values, @credit_fields)
      {posting_on, late_adjustment} = posting_details(occurred_on, reporting)

      case Repo.get_by(FinanceCreditMovement, operation_id: operation_id) do
        nil ->
          Repo.insert!(
            struct!(
              FinanceCreditMovement,
              %{
                operation_id: operation_id,
                posting_on: posting_on,
                late_adjustment: late_adjustment
              }
              |> Map.merge(normalized)
            )
          )

        movement ->
          if movement.posting_on != posting_on or movement.late_adjustment != late_adjustment do
            raise "finance operation posting invariant violated"
          end

          changes = Map.new(@credit_fields, &{&1, Map.fetch!(movement, &1) + normalized[&1]})
          movement |> change(changes) |> Repo.update!()
      end
    end

    :ok
  end

  defp closed?(_date, nil), do: false
  defp closed?(_date, %FinanceReporting{closed_through: nil}), do: false

  defp closed?(date, %FinanceReporting{closed_through: closed_through}),
    do: Date.compare(date, closed_through) != :gt

  defp max_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)

  defp sum_fields(rows, fields) when is_list(rows) do
    Map.new(fields, fn field ->
      {field, Enum.sum(Enum.map(rows, &Map.get(&1, field, 0)))}
    end)
  end

  defp normalize(values, fields), do: Map.new(fields, &{&1, Map.get(values, &1, 0)})
  defp add_fields(left, right, fields), do: Map.new(fields, &{&1, left[&1] + right[&1]})
  defp zero_values?(values, fields), do: Enum.all?(fields, &(Map.get(values, &1, 0) == 0))

  defp cash_effect(rows) when is_list(rows), do: rows |> sum_fields(@cash_fields) |> cash_effect()

  defp cash_effect(values) do
    values.received_cents + values.transferred_in_cents - values.transferred_out_cents -
      values.refunded_cents - values.retained_cents - values.converted_to_credit_cents -
      values.reduced_cents - values.charged_back_cents
  end

  defp credit_effect(rows) when is_list(rows),
    do: rows |> sum_fields(@credit_fields) |> credit_effect()

  defp credit_effect(values) do
    values.issued_cents - values.expired_cents - values.consumed_cents -
      values.revoked_cents - values.absorbed_cents
  end
end
