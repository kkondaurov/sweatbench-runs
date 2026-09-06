defmodule GroupStay.Finance do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{Credits, Repo, RoomAccounting}

  alias GroupStay.Finance.{CashOpeningPosition, CreditExpiry, Movement, ReportingSetting}
  alias GroupStay.Groups.{Group, HotelCreditLot}

  @cash_classifications [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]
  @credit_classifications ["issued", "expired", "consumed", "revoked", "absorbed"]

  def start_reporting!(starts_on) when is_struct(starts_on, Date) do
    case settings() do
      nil ->
        %ReportingSetting{}
        |> Ecto.Changeset.change(%{
          singleton: 1,
          starts_on: starts_on,
          opening_credit_liability_cents: Credits.liability_cents(starts_on)
        })
        |> Ecto.Changeset.unique_constraint(:singleton)
        |> Repo.insert()
        |> case do
          {:ok, _setting} ->
            snapshot_cash_opening_positions!()
            schedule_existing_credit_expiries!(starts_on)
            :ok

          {:error, changeset} ->
            if Keyword.has_key?(changeset.errors, :singleton),
              do: {:error, :already_started},
              else: raise(changeset)
        end

      _setting ->
        {:error, :already_started}
    end
  end

  def report(date) when is_struct(date, Date) do
    case settings() do
      nil ->
        :not_available

      %{starts_on: starts_on} = setting ->
        if Date.compare(date, starts_on) == :lt,
          do: :not_available,
          else: {:ok, build_report(setting, date)}
    end
  end

  def report(_date), do: :not_available

  def started?, do: not is_nil(settings())

  def posting_on(occurred_on) when is_struct(occurred_on, Date) do
    case settings() do
      nil -> :not_started
      %{starts_on: starts_on} -> {:ok, max_date(occurred_on, starts_on)}
    end
  end

  def posting_on(_occurred_on), do: :invalid_date

  def record_cash(operation_id, occurred_on, property_id, classification, amount_cents)
      when is_binary(operation_id) and is_struct(occurred_on, Date) and is_binary(property_id) and
             classification in @cash_classifications and is_integer(amount_cents) and
             amount_cents != 0 do
    with {:ok, posting_on} <- posting_on(occurred_on) do
      insert_movement!(
        operation_id,
        posting_on,
        "cash",
        property_id,
        classification,
        amount_cents
      )
    else
      :not_started -> :ok
    end
  end

  def record_cash(_operation_id, _occurred_on, _property_id, _classification, _amount_cents),
    do: :ok

  def record_cash_by_group(operation_id, occurred_on, classification, group_amounts)
      when is_binary(operation_id) and is_struct(occurred_on, Date) and
             classification in @cash_classifications and is_map(group_amounts) do
    with {:ok, posting_on} <- posting_on(occurred_on) do
      group_amounts
      |> Enum.filter(fn {_group_id, amount_cents} -> amount_cents != 0 end)
      |> Enum.each(fn {group_id, amount_cents} ->
        property_id =
          Repo.one!(from(group in Group, where: group.id == ^group_id, select: group.property_id))

        insert_movement!(
          operation_id,
          posting_on,
          "cash",
          property_id,
          classification,
          amount_cents
        )
      end)
    else
      :not_started -> :ok
    end
  end

  def record_cash_by_group(_operation_id, _occurred_on, _classification, _group_amounts), do: :ok

  def record_credit(operation_id, occurred_on, classification, amount_cents)
      when is_binary(operation_id) and is_struct(occurred_on, Date) and
             classification in @credit_classifications and is_integer(amount_cents) and
             amount_cents > 0 do
    with {:ok, posting_on} <- posting_on(occurred_on) do
      insert_movement!(operation_id, posting_on, "credit", nil, classification, amount_cents)
    else
      :not_started -> :ok
    end
  end

  def record_credit(_operation_id, _occurred_on, _classification, _amount_cents), do: :ok

  def track_issued_credit_lot(lot, occurred_on)
      when is_struct(lot, HotelCreditLot) and is_struct(occurred_on, Date) do
    with {:ok, posting_on} <- posting_on(occurred_on) do
      schedule_credit_expiry!(lot.id, max_date(lot.expires_on, posting_on))
    else
      :not_started -> :ok
    end
  end

  def track_issued_credit_lot(_lot, _occurred_on), do: :ok

  defp build_report(setting, date) do
    cash = cash_report(setting.starts_on, date)
    credit = credit_report(setting, date)

    %{date: Date.to_iso8601(date), status: "open", cash: cash, credit: credit}
  end

  defp cash_report(starts_on, date) do
    opening =
      Repo.all(
        from(position in CashOpeningPosition, select: {position.property_id, position.held_cents})
      )
      |> Map.new()

    movements = cash_movements_through(date)

    properties =
      (Map.keys(opening) ++ Enum.map(movements, & &1.property_id))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(properties, [], fn property_id, entries ->
      previous = cash_movement_totals(movements, property_id, starts_on, date, :previous)
      today = cash_movement_totals(movements, property_id, starts_on, date, :today)
      opening_held_cents = Map.get(opening, property_id, 0) + cash_balance_change(previous)
      closing_held_cents = opening_held_cents + cash_balance_change(today)

      if opening_held_cents == 0 and closing_held_cents == 0 and
           Enum.all?(Map.values(today), &(&1 == 0)) do
        entries
      else
        entries ++
          [
            %{
              property_id: property_id,
              opening_held_cents: opening_held_cents,
              movements: named_movements(@cash_classifications, today),
              closing_held_cents: closing_held_cents
            }
          ]
      end
    end)
  end

  defp credit_report(setting, date) do
    movements = credit_movement_totals(setting.starts_on, date)

    previous =
      movements
      |> movement_totals_before(date)
      |> Map.update!("expired", &(&1 + scheduled_expiry_cents_before(date)))

    today = movement_totals_on(movements, date)
    today = Map.update!(today, "expired", &(&1 + scheduled_expiry_cents(date)))

    opening_liability_cents =
      setting.opening_credit_liability_cents + credit_balance_change(previous)

    %{
      opening_liability_cents: opening_liability_cents,
      movements: named_movements(@credit_classifications, today),
      closing_liability_cents: opening_liability_cents + credit_balance_change(today)
    }
  end

  defp cash_movements_through(date) do
    Repo.all(
      from(movement in Movement,
        where: movement.kind == "cash" and movement.posting_on <= ^date,
        select: %{
          property_id: movement.property_id,
          posting_on: movement.posting_on,
          classification: movement.classification,
          amount_cents: movement.amount_cents
        }
      )
    )
  end

  defp cash_movement_totals(movements, property_id, starts_on, date, period) do
    movements
    |> Enum.filter(fn movement ->
      movement.property_id == property_id and
        case period do
          :previous ->
            Date.compare(movement.posting_on, starts_on) != :lt and
              Date.compare(movement.posting_on, date) == :lt

          :today ->
            movement.posting_on == date
        end
    end)
    |> totals_by_classification(@cash_classifications)
  end

  defp credit_movement_totals(starts_on, date) do
    Repo.all(
      from(movement in Movement,
        where:
          movement.kind == "credit" and movement.posting_on >= ^starts_on and
            movement.posting_on <= ^date,
        select: %{
          posting_on: movement.posting_on,
          classification: movement.classification,
          amount_cents: movement.amount_cents
        }
      )
    )
  end

  defp movement_totals_before(movements, date) do
    movements
    |> Enum.filter(&(Date.compare(&1.posting_on, date) == :lt))
    |> totals_by_classification(@credit_classifications)
  end

  defp movement_totals_on(movements, date) do
    movements
    |> Enum.filter(&(&1.posting_on == date))
    |> totals_by_classification(@credit_classifications)
  end

  defp totals_by_classification(movements, classifications) do
    base = Map.new(classifications, &{&1, 0})

    Enum.reduce(movements, base, fn movement, totals ->
      Map.update!(totals, movement.classification, &(&1 + movement.amount_cents))
    end)
  end

  defp named_movements(classifications, totals) do
    Map.new(classifications, fn classification ->
      {String.to_atom(classification <> "_cents"), Map.fetch!(totals, classification)}
    end)
  end

  defp cash_balance_change(totals) do
    totals["received"] + totals["transferred_in"] - totals["transferred_out"] -
      totals["refunded"] - totals["retained"] - totals["converted_to_credit"] -
      totals["reduced"] - totals["charged_back"]
  end

  defp credit_balance_change(totals) do
    totals["issued"] - totals["expired"] - totals["consumed"] - totals["revoked"] -
      totals["absorbed"]
  end

  defp scheduled_expiry_cents(date) do
    Repo.one(
      from(expiry in CreditExpiry,
        join: lot in HotelCreditLot,
        on: expiry.hotel_credit_lot_id == lot.id,
        where: expiry.reporting_expires_on == ^date,
        select: coalesce(sum(lot.remaining_cents), 0)
      )
    )
  end

  defp scheduled_expiry_cents_before(date) do
    Repo.one(
      from(expiry in CreditExpiry,
        join: lot in HotelCreditLot,
        on: expiry.hotel_credit_lot_id == lot.id,
        where: expiry.reporting_expires_on < ^date,
        select: coalesce(sum(lot.remaining_cents), 0)
      )
    )
  end

  defp snapshot_cash_opening_positions! do
    RoomAccounting.held_cash_by_property()
    |> Enum.each(fn {property_id, held_cents} ->
      %CashOpeningPosition{}
      |> Ecto.Changeset.change(%{property_id: property_id, held_cents: held_cents})
      |> Repo.insert!()
    end)
  end

  defp schedule_existing_credit_expiries!(starts_on) do
    Repo.all(from(lot in HotelCreditLot, where: lot.expires_on > ^starts_on, select: lot.id))
    |> Enum.each(&schedule_credit_expiry!(&1, credit_lot_expiry_on!(&1)))
  end

  defp credit_lot_expiry_on!(lot_id) do
    Repo.one!(from(lot in HotelCreditLot, where: lot.id == ^lot_id, select: lot.expires_on))
  end

  defp schedule_credit_expiry!(lot_id, reporting_expires_on) do
    %CreditExpiry{}
    |> Ecto.Changeset.change(%{
      hotel_credit_lot_id: lot_id,
      reporting_expires_on: reporting_expires_on
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: :hotel_credit_lot_id)

    :ok
  end

  defp insert_movement!(operation_id, posting_on, kind, property_id, classification, amount_cents) do
    %Movement{}
    |> Ecto.Changeset.change(%{
      operation_id: operation_id,
      posting_on: posting_on,
      kind: kind,
      property_id: property_id,
      classification: classification,
      amount_cents: amount_cents
    })
    |> Repo.insert!()

    :ok
  end

  defp settings, do: Repo.get_by(ReportingSetting, singleton: 1)
  defp max_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end
