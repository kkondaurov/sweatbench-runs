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

  def record_cash(operation_id, occurred_on, movements_by_property) do
    case reporting() do
      nil ->
        :ok

      reporting ->
        movements_by_property
        |> Enum.reject(fn {_property_id, values} -> zero_values?(values, @cash_fields) end)
        |> Enum.each(fn {property_id, values} ->
          Repo.insert!(
            struct!(
              FinanceCashMovement,
              %{
                operation_id: operation_id,
                posting_on: posting_on(occurred_on, reporting),
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
        unless zero_values?(values, @credit_fields) do
          Repo.insert!(
            struct!(
              FinanceCreditMovement,
              %{
                operation_id: operation_id,
                posting_on: posting_on(occurred_on, reporting)
              }
              |> Map.merge(normalize(values, @credit_fields))
            )
          )
        end
    end
  end

  def schedule_expiry(%CreditLot{} = lot, amount, occurred_on) when amount > 0 do
    case reporting() do
      nil ->
        :ok

      reporting ->
        if Date.compare(occurred_on, lot.expires_on) != :gt do
          posting_on = max_date(Date.add(lot.expires_on, 1), reporting.starts_on)

          case Repo.get_by(FinanceCreditExpiry, credit_lot_id: lot.id) do
            nil ->
              Repo.insert!(%FinanceCreditExpiry{
                credit_lot_id: lot.id,
                posting_on: posting_on,
                amount_cents: amount
              })

            expiry ->
              expiry |> change(amount_cents: expiry.amount_cents + amount) |> Repo.update!()
          end
        end
    end

    :ok
  end

  def schedule_expiry(_lot, _amount, _occurred_on), do: :ok

  def unschedule_expiry(%CreditLot{} = lot, amount, occurred_on) when amount > 0 do
    if Date.compare(occurred_on, lot.expires_on) != :gt do
      case Repo.get_by(FinanceCreditExpiry, credit_lot_id: lot.id) do
        nil ->
          :ok

        expiry ->
          remaining = expiry.amount_cents - amount

          cond do
            remaining > 0 -> expiry |> change(amount_cents: remaining) |> Repo.update!()
            remaining == 0 -> Repo.delete!(expiry)
            true -> raise "finance credit expiry invariant violated"
          end
      end
    end

    :ok
  end

  def unschedule_expiry(_lot, _amount, _occurred_on), do: :ok

  def daily_report(date) do
    case reporting() do
      nil ->
        :not_available

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          :not_available
        else
          {:ok,
           %{
             date: Date.to_iso8601(date),
             status: "open",
             cash: cash_report(reporting, date),
             credit: credit_report(reporting, date)
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

    Enum.flat_map(properties, fn property_id ->
      property_movements = Enum.filter(movements, &(&1.property_id == property_id))
      before = Enum.filter(property_movements, &(Date.compare(&1.posting_on, date) == :lt))
      today = Enum.filter(property_movements, &(Date.compare(&1.posting_on, date) == :eq))
      opening = Map.get(openings, property_id, 0) + cash_effect(before)
      movement_data = sum_fields(today, @cash_fields)
      closing = opening + cash_effect(movement_data)

      if opening == 0 and closing == 0 and zero_values?(movement_data, @cash_fields) do
        []
      else
        [
          %{
            property_id: property_id,
            opening_held_cents: opening,
            movements: movement_data,
            closing_held_cents: closing
          }
        ]
      end
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
    movement_data = sum_fields(today, @credit_fields)

    %{
      opening_liability_cents: opening,
      movements: movement_data,
      closing_liability_cents: opening + credit_effect(movement_data)
    }
  end

  defp expiry_values(expiry), do: %{expired_cents: expiry.amount_cents}

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
  defp posting_on(occurred_on, reporting), do: max_date(occurred_on, reporting.starts_on)
  defp max_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)

  defp sum_fields(rows, fields) when is_list(rows) do
    Map.new(fields, fn field ->
      {field, Enum.sum(Enum.map(rows, &Map.get(&1, field, 0)))}
    end)
  end

  defp normalize(values, fields), do: Map.new(fields, &{&1, Map.get(values, &1, 0)})
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
