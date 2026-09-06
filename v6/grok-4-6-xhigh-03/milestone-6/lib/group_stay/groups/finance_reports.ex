defmodule GroupStay.Groups.FinanceReports do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.FinanceLotRemainingChange
  alias GroupStay.Groups.FinanceLotSnapshot
  alias GroupStay.Groups.FinanceMovement
  alias GroupStay.Groups.FinanceOpeningCash
  alias GroupStay.Groups.FinanceReportingStart
  alias GroupStay.Groups.Group

  @cash_classes [
    :received_cents,
    :transferred_in_cents,
    :transferred_out_cents,
    :refunded_cents,
    :retained_cents,
    :converted_to_credit_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  @credit_classes [
    :issued_cents,
    :expired_cents,
    :consumed_cents,
    :revoked_cents,
    :absorbed_cents
  ]

  def start(starts_on, as_of_on, opening_liability_cents, operation_id) do
    if current_start() do
      :already_started
    else
      persist_start(starts_on, as_of_on, opening_liability_cents, operation_id)
    end
  end

  def posting_date(occurred_on) do
    case current_start() do
      nil ->
        nil

      start ->
        cond do
          is_nil(occurred_on) -> start.starts_on
          Date.compare(occurred_on, start.starts_on) == :lt -> start.starts_on
          true -> occurred_on
        end
    end
  end

  def record_cash!(_posting_date, _property_id, _classification, amount, _operation_id)
      when amount == 0 or is_nil(amount),
      do: :ok

  def record_cash!(nil, _property_id, _classification, _amount, _operation_id), do: :ok

  def record_cash!(_posting_date, property_id, _classification, _amount, _operation_id)
      when not is_binary(property_id),
      do: :ok

  def record_cash!(posting_date, property_id, classification, amount, operation_id) do
    insert_movement!(%{
      posting_date: posting_date,
      book: "cash",
      property_id: property_id,
      classification: to_string(classification),
      amount_cents: amount,
      operation_id: operation_id
    })
  end

  def record_credit!(_posting_date, _classification, amount, _operation_id)
      when amount == 0 or is_nil(amount),
      do: :ok

  def record_credit!(nil, _classification, _amount, _operation_id), do: :ok

  def record_credit!(posting_date, classification, amount, operation_id) do
    insert_movement!(%{
      posting_date: posting_date,
      book: "credit",
      property_id: nil,
      classification: to_string(classification),
      amount_cents: amount,
      operation_id: operation_id
    })
  end

  def record_issued!(nil, _lot, _operation_id), do: :ok

  def record_issued!(posting_date, lot, operation_id) do
    record_credit!(posting_date, "issued", lot.issued_cents, operation_id)
    snapshot_lot!(lot)
    :ok
  end

  def snapshot_lot!(%CreditLot{} = lot) do
    %FinanceLotSnapshot{}
    |> FinanceLotSnapshot.changeset(%{
      credit_lot_id: lot.id,
      remaining_cents: lot.remaining_cents,
      expires_on: lot.expires_on
    })
    |> Repo.insert!()

    :ok
  end

  def record_remaining_change!(_lot_id, nil, _delta, _operation_id), do: :ok

  def record_remaining_change!(_lot_id, _posting_date, 0, _operation_id), do: :ok

  def record_remaining_change!(lot_id, posting_date, delta, operation_id) do
    %FinanceLotRemainingChange{}
    |> FinanceLotRemainingChange.changeset(%{
      credit_lot_id: lot_id,
      posting_date: posting_date,
      delta_cents: delta,
      operation_id: operation_id
    })
    |> Repo.insert!()

    :ok
  end

  def lot_live?(%CreditLot{} = lot, %Date{} = posting_date) do
    Date.compare(lot.expires_on, posting_date) != :lt
  end

  def lot_live?(_lot, _posting_date), do: true

  def daily_report(value) do
    case parse_iso_date(value) do
      :error ->
        {:error, :invalid_reporting_date}

      {:ok, date} ->
        case current_start() do
          nil ->
            {:error, :report_not_available}

          start ->
            if Date.compare(date, start.starts_on) == :lt do
              {:error, :report_not_available}
            else
              {:ok, build_report(start, date)}
            end
        end
    end
  end

  defp persist_start(starts_on, as_of_on, opening_liability_cents, operation_id) do
    changeset =
      FinanceReportingStart.changeset(%FinanceReportingStart{}, %{
        singleton: 1,
        operation_id: operation_id || "start_finance_reporting",
        starts_on: starts_on,
        as_of_on: as_of_on,
        opening_liability_cents: opening_liability_cents
      })

    case Repo.insert(changeset) do
      {:ok, _start} ->
        snapshot_opening_cash!()
        snapshot_existing_lots!()
        :ok

      {:error, _changeset} ->
        :already_started
    end
  end

  defp snapshot_opening_cash! do
    Group
    |> where([g], g.status == "active" and g.cash_paid_cents != 0)
    |> select([g], {g.property_id, g.cash_paid_cents})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {property_id, amounts} ->
      %FinanceOpeningCash{}
      |> FinanceOpeningCash.changeset(%{
        property_id: property_id,
        held_cents: Enum.sum(amounts)
      })
      |> Repo.insert!()
    end)
  end

  defp snapshot_existing_lots! do
    CreditLot
    |> Repo.all()
    |> Enum.each(&snapshot_lot!/1)
  end

  defp current_start do
    FinanceReportingStart
    |> limit(1)
    |> Repo.one()
  end

  defp insert_movement!(attrs) do
    %FinanceMovement{}
    |> FinanceMovement.changeset(attrs)
    |> Repo.insert!()

    :ok
  end

  defp build_report(start, date) do
    snapshots = Repo.all(FinanceLotSnapshot)
    changes = Repo.all(FinanceLotRemainingChange)
    movements = Repo.all(FinanceMovement)

    cash_openings = cash_held_as_of(date, movements)
    cash_on_date = cash_movements_on(date, movements)
    credit_opening = credit_liability_as_of(start, date, movements, snapshots, changes)
    credit_on_date = credit_movements_on(start, date, movements, snapshots, changes)

    properties =
      (Map.keys(cash_openings) ++ Map.keys(cash_on_date))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        opening = Map.get(cash_openings, property_id, 0)
        movs = Map.get(cash_on_date, property_id, zero_cash_movements())
        closing = close_cash(opening, movs)

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: movs,
          closing_held_cents: closing
        }
      end)
      |> Enum.reject(&zero_cash_entry?/1)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: credit_opening,
        movements: credit_on_date,
        closing_liability_cents: close_credit(credit_opening, credit_on_date)
      }
    }
  end

  defp cash_held_as_of(date, movements) do
    base =
      FinanceOpeningCash
      |> Repo.all()
      |> Map.new(&{&1.property_id, &1.held_cents})

    movements
    |> Enum.filter(&(&1.book == "cash" and Date.compare(&1.posting_date, date) == :lt))
    |> Enum.reduce(base, fn movement, acc ->
      held = Map.get(acc, movement.property_id, 0)
      Map.put(acc, movement.property_id, apply_cash_held(held, movement))
    end)
  end

  defp cash_movements_on(date, movements) do
    movements
    |> Enum.filter(&(&1.book == "cash" and &1.posting_date == date))
    |> Enum.reduce(%{}, fn movement, acc ->
      movs = Map.get(acc, movement.property_id, zero_cash_movements())
      key = cash_class_key(movement.classification)
      Map.put(acc, movement.property_id, Map.update!(movs, key, &(&1 + movement.amount_cents)))
    end)
  end

  defp credit_liability_as_of(start, date, movements, snapshots, changes) do
    journal =
      movements
      |> Enum.filter(&(&1.book == "credit" and Date.compare(&1.posting_date, date) == :lt))
      |> Enum.reduce(zero_credit_movements(), &add_credit_movement/2)

    expired = calendar_expired_before(start, date, snapshots, changes)
    journal = Map.update!(journal, :expired_cents, &(&1 + expired))
    close_credit(start.opening_liability_cents, journal)
  end

  defp credit_movements_on(start, date, movements, snapshots, changes) do
    journal =
      movements
      |> Enum.filter(&(&1.book == "credit" and &1.posting_date == date))
      |> Enum.reduce(zero_credit_movements(), &add_credit_movement/2)

    expired = calendar_expired_on(start, date, snapshots, changes)
    Map.update!(journal, :expired_cents, &(&1 + expired))
  end

  defp add_credit_movement(movement, acc) do
    key = credit_class_key(movement.classification)
    Map.update!(acc, key, &(&1 + movement.amount_cents))
  end

  defp calendar_expired_before(start, date, snapshots, changes) do
    Enum.reduce(snapshots, 0, fn snapshot, acc ->
      case expiry_posting(start, snapshot) do
        nil ->
          acc

        posted ->
          if Date.compare(posted, date) == :lt do
            acc + remaining_at(snapshot, posted, changes)
          else
            acc
          end
      end
    end)
  end

  defp calendar_expired_on(start, date, snapshots, changes) do
    Enum.reduce(snapshots, 0, fn snapshot, acc ->
      case expiry_posting(start, snapshot) do
        nil ->
          acc

        posted ->
          if posted == date do
            acc + remaining_at(snapshot, posted, changes)
          else
            acc
          end
      end
    end)
  end

  defp expiry_posting(start, snapshot) do
    if Date.compare(snapshot.expires_on, start.as_of_on) == :lt do
      nil
    else
      later_date(Date.add(snapshot.expires_on, 1), start.starts_on)
    end
  end

  defp remaining_at(snapshot, posting, changes) do
    delta =
      changes
      |> Enum.filter(fn change ->
        change.credit_lot_id == snapshot.credit_lot_id and
          Date.compare(change.posting_date, posting) == :lt
      end)
      |> Enum.reduce(0, fn change, acc -> acc + change.delta_cents end)

    max(snapshot.remaining_cents + delta, 0)
  end

  defp apply_cash_held(held, movement) do
    amount = movement.amount_cents

    case movement.classification do
      "received" -> held + amount
      "transferred_in" -> held + amount
      "transferred_out" -> held - amount
      "refunded" -> held - amount
      "retained" -> held - amount
      "converted_to_credit" -> held - amount
      "reduced" -> held - amount
      "charged_back" -> held - amount
      _ -> held
    end
  end

  defp close_cash(opening, movs) do
    opening + movs.received_cents + movs.transferred_in_cents - movs.transferred_out_cents -
      movs.refunded_cents - movs.retained_cents - movs.converted_to_credit_cents -
      movs.reduced_cents - movs.charged_back_cents
  end

  defp close_credit(opening, movs) do
    opening + movs.issued_cents - movs.expired_cents - movs.consumed_cents - movs.revoked_cents -
      movs.absorbed_cents
  end

  defp zero_cash_entry?(entry) do
    entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
      Enum.all?(@cash_classes, fn key -> Map.fetch!(entry.movements, key) == 0 end)
  end

  defp zero_cash_movements do
    Map.new(@cash_classes, &{&1, 0})
  end

  defp zero_credit_movements do
    Map.new(@credit_classes, &{&1, 0})
  end

  defp cash_class_key("received"), do: :received_cents
  defp cash_class_key("transferred_in"), do: :transferred_in_cents
  defp cash_class_key("transferred_out"), do: :transferred_out_cents
  defp cash_class_key("refunded"), do: :refunded_cents
  defp cash_class_key("retained"), do: :retained_cents
  defp cash_class_key("converted_to_credit"), do: :converted_to_credit_cents
  defp cash_class_key("reduced"), do: :reduced_cents
  defp cash_class_key("charged_back"), do: :charged_back_cents

  defp credit_class_key("issued"), do: :issued_cents
  defp credit_class_key("expired"), do: :expired_cents
  defp credit_class_key("consumed"), do: :consumed_cents
  defp credit_class_key("revoked"), do: :revoked_cents
  defp credit_class_key("absorbed"), do: :absorbed_cents

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp parse_iso_date(%Date{} = date), do: {:ok, date}

  defp parse_iso_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_iso_date(_), do: :error
end
