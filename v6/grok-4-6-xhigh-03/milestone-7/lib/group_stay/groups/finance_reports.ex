defmodule GroupStay.Groups.FinanceReports do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.FinanceClosedReport
  alias GroupStay.Groups.FinanceLotRemainingChange
  alias GroupStay.Groups.FinanceLotSnapshot
  alias GroupStay.Groups.FinanceMovement
  alias GroupStay.Groups.FinanceOpeningCash
  alias GroupStay.Groups.FinancePeriodClose
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

  def close(period_end_on, operation_id) do
    case current_start() do
      nil ->
        :invalid_period

      start ->
        if Date.compare(period_end_on, start.starts_on) == :lt do
          :invalid_period
        else
          persist_close(start, period_end_on, operation_id)
        end
    end
  end

  def posting_date(occurred_on) do
    case posting_context(occurred_on) do
      nil -> nil
      context -> context.date
    end
  end

  def posting_context(occurred_on) do
    case current_start() do
      nil ->
        nil

      start ->
        natural = natural_posting_date(occurred_on, start)
        posted = later_date(natural, first_open_on(start))

        %{
          date: posted,
          late: Date.compare(natural, posted) == :lt
        }
    end
  end

  def record_cash!(_posting, _property_id, _classification, amount, _operation_id)
      when amount == 0 or is_nil(amount),
      do: :ok

  def record_cash!(nil, _property_id, _classification, _amount, _operation_id), do: :ok

  def record_cash!(_posting, property_id, _classification, _amount, _operation_id)
      when not is_binary(property_id),
      do: :ok

  def record_cash!(posting, property_id, classification, amount, operation_id) do
    case posting_parts(posting) do
      nil ->
        :ok

      {date, late} ->
        insert_movement!(%{
          posting_date: date,
          book: "cash",
          property_id: property_id,
          classification: to_string(classification),
          amount_cents: amount,
          operation_id: operation_id,
          late_adjustment: late
        })
    end
  end

  def record_credit!(_posting, _classification, amount, _operation_id)
      when amount == 0 or is_nil(amount),
      do: :ok

  def record_credit!(nil, _classification, _amount, _operation_id), do: :ok

  def record_credit!(posting, classification, amount, operation_id) do
    case posting_parts(posting) do
      nil ->
        :ok

      {date, late} ->
        insert_movement!(%{
          posting_date: date,
          book: "credit",
          property_id: nil,
          classification: to_string(classification),
          amount_cents: amount,
          operation_id: operation_id,
          late_adjustment: late
        })
    end
  end

  def record_issued!(nil, _lot, _operation_id), do: :ok

  def record_issued!(posting, lot, operation_id) do
    record_credit!(posting, "issued", lot.issued_cents, operation_id)
    snapshot_lot!(lot, posting)
    :ok
  end

  def snapshot_lot!(%CreditLot{} = lot, posting \\ nil) do
    %FinanceLotSnapshot{}
    |> FinanceLotSnapshot.changeset(
      Map.merge(
        %{
          credit_lot_id: lot.id,
          remaining_cents: lot.remaining_cents,
          expires_on: lot.expires_on
        },
        expiry_attrs(lot, posting)
      )
    )
    |> Repo.insert!()

    :ok
  end

  def record_remaining_change!(_lot_id, nil, _delta, _operation_id), do: :ok

  def record_remaining_change!(_lot_id, _posting, 0, _operation_id), do: :ok

  def record_remaining_change!(lot_id, posting, delta, operation_id) do
    case posting_parts(posting) do
      nil ->
        :ok

      {date, late} ->
        %FinanceLotRemainingChange{}
        |> FinanceLotRemainingChange.changeset(%{
          credit_lot_id: lot_id,
          posting_date: date,
          delta_cents: delta,
          operation_id: operation_id,
          late_adjustment: late
        })
        |> Repo.insert!()

        :ok
    end
  end

  def lot_live?(%CreditLot{} = lot, posting) do
    case posting_date_of(posting) do
      %Date{} = date -> Date.compare(lot.expires_on, date) != :lt
      _ -> true
    end
  end

  def lot_live?(_lot, _posting), do: true

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
              {:ok, report_for(start, date)}
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

  defp persist_close(start, period_end_on, operation_id) do
    latest = latest_close()

    if latest && Date.compare(period_end_on, latest.period_end_on) != :gt do
      :invalid_period
    else
      changeset =
        FinancePeriodClose.changeset(%FinancePeriodClose{}, %{
          operation_id: operation_id || "close_finance_period",
          period_end_on: period_end_on
        })

      case Repo.insert(changeset) do
        {:ok, _close} ->
          publish_reports!(start, period_end_on, latest)
          :ok

        {:error, _changeset} ->
          :invalid_period
      end
    end
  end

  defp publish_reports!(start, period_end_on, latest) do
    from =
      case latest do
        nil -> start.starts_on
        close -> Date.add(close.period_end_on, 1)
      end

    snapshots = Repo.all(FinanceLotSnapshot)
    changes = Repo.all(FinanceLotRemainingChange)
    movements = Repo.all(FinanceMovement)

    Enum.each(Date.range(from, period_end_on), fn date ->
      report = build_report(start, date, "closed", snapshots, changes, movements)

      %FinanceClosedReport{}
      |> FinanceClosedReport.changeset(%{
        report_date: date,
        data_json: Jason.encode!(report)
      })
      |> Repo.insert!()
    end)
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

  defp latest_close do
    FinancePeriodClose
    |> order_by([c], desc: c.period_end_on)
    |> limit(1)
    |> Repo.one()
  end

  defp first_open_on(start) do
    case latest_close() do
      nil -> start.starts_on
      close -> later_date(Date.add(close.period_end_on, 1), start.starts_on)
    end
  end

  defp natural_posting_date(nil, start), do: start.starts_on

  defp natural_posting_date(occurred_on, start) do
    later_date(occurred_on, start.starts_on)
  end

  defp insert_movement!(attrs) do
    %FinanceMovement{}
    |> FinanceMovement.changeset(attrs)
    |> Repo.insert!()

    :ok
  end

  defp report_for(start, date) do
    case Repo.get_by(FinanceClosedReport, report_date: date) do
      %FinanceClosedReport{data_json: json} ->
        Jason.decode!(json)

      nil ->
        build_report(start, date, "open")
    end
  end

  defp build_report(start, date, status) do
    build_report(
      start,
      date,
      status,
      Repo.all(FinanceLotSnapshot),
      Repo.all(FinanceLotRemainingChange),
      Repo.all(FinanceMovement)
    )
  end

  defp build_report(start, date, status, snapshots, changes, movements) do
    cash_openings = cash_held_as_of(date, movements)
    {cash_ordinary, cash_late} = split_cash_movements_on(date, movements)
    credit_opening = credit_liability_as_of(start, date, movements, snapshots, changes)

    {credit_ordinary, credit_late} =
      split_credit_movements_on(start, date, movements, snapshots, changes)

    properties =
      (Map.keys(cash_openings) ++ Map.keys(cash_ordinary) ++ Map.keys(cash_late))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      properties
      |> Enum.map(fn property_id ->
        opening = Map.get(cash_openings, property_id, 0)
        ordinary = Map.get(cash_ordinary, property_id, zero_cash_movements())
        late = Map.get(cash_late, property_id, zero_cash_movements())
        closing = close_cash(opening, add_movements(ordinary, late))

        %{
          property_id: property_id,
          opening_held_cents: opening,
          movements: ordinary,
          closing_held_cents: closing
        }
      end)
      |> Enum.reject(fn entry ->
        late = Map.get(cash_late, entry.property_id, zero_cash_movements())
        total = add_movements(entry.movements, late)

        zero_cash_row?(entry.opening_held_cents, entry.closing_held_cents, total)
      end)

    late_cash =
      cash_late
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {property_id, movs} ->
        if zero_movements?(movs, @cash_classes) do
          []
        else
          [%{property_id: property_id, movements: movs}]
        end
      end)

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash,
      credit: %{
        opening_liability_cents: credit_opening,
        movements: credit_ordinary,
        closing_liability_cents:
          close_credit(credit_opening, add_movements(credit_ordinary, credit_late))
      },
      late_adjustments: %{
        cash: late_cash,
        credit: credit_late
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

  defp split_cash_movements_on(date, movements) do
    Enum.reduce(movements, {%{}, %{}}, fn movement, {ordinary, late} ->
      if movement.book == "cash" and movement.posting_date == date do
        dest = if late?(movement), do: late, else: ordinary
        movs = Map.get(dest, movement.property_id, zero_cash_movements())
        key = cash_class_key(movement.classification)

        dest =
          Map.put(
            dest,
            movement.property_id,
            Map.update!(movs, key, &(&1 + movement.amount_cents))
          )

        if late?(movement), do: {ordinary, dest}, else: {dest, late}
      else
        {ordinary, late}
      end
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

  defp split_credit_movements_on(start, date, movements, snapshots, changes) do
    {ordinary, late} =
      Enum.reduce(movements, {zero_credit_movements(), zero_credit_movements()}, fn movement,
                                                                                    {ord, late} ->
        if movement.book == "credit" and movement.posting_date == date do
          if late?(movement) do
            {ord, add_credit_movement(movement, late)}
          else
            {add_credit_movement(movement, ord), late}
          end
        else
          {ord, late}
        end
      end)

    {cal_ordinary, cal_late} = calendar_expired_split(start, date, snapshots, changes)

    {
      Map.update!(ordinary, :expired_cents, &(&1 + cal_ordinary)),
      Map.update!(late, :expired_cents, &(&1 + cal_late))
    }
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

  defp calendar_expired_split(start, date, snapshots, changes) do
    Enum.reduce(snapshots, {0, 0}, fn snapshot, {ordinary, late} ->
      case expiry_posting(start, snapshot) do
        ^date ->
          amount = remaining_at(snapshot, date, changes)

          if expiry_late?(snapshot) do
            {ordinary, late + amount}
          else
            {ordinary + amount, late}
          end

        _ ->
          {ordinary, late}
      end
    end)
  end

  defp expiry_posting(start, snapshot) do
    cond do
      Date.compare(snapshot.expires_on, start.as_of_on) == :lt ->
        nil

      match?(%Date{}, snapshot.expiry_posting_date) ->
        snapshot.expiry_posting_date

      true ->
        later_date(Date.add(snapshot.expires_on, 1), start.starts_on)
    end
  end

  defp expiry_attrs(lot, posting) do
    case current_start() do
      nil ->
        %{expiry_posting_date: nil, expiry_late: false}

      start ->
        if Date.compare(lot.expires_on, start.as_of_on) == :lt do
          %{expiry_posting_date: nil, expiry_late: false}
        else
          natural = later_date(Date.add(lot.expires_on, 1), start.starts_on)
          issue_date = posting_date_of(posting) || start.starts_on
          posted = later_date(natural, issue_date)

          %{
            expiry_posting_date: posted,
            expiry_late: Date.compare(natural, posted) == :lt
          }
        end
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

  defp zero_cash_row?(opening, closing, movs) do
    opening == 0 and closing == 0 and zero_movements?(movs, @cash_classes)
  end

  defp zero_movements?(movs, keys) do
    Enum.all?(keys, fn key -> Map.fetch!(movs, key) == 0 end)
  end

  defp add_movements(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
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

  defp late?(record) do
    Map.get(record, :late_adjustment) in [true, 1]
  end

  defp expiry_late?(snapshot) do
    Map.get(snapshot, :expiry_late) in [true, 1]
  end

  defp posting_parts(nil), do: nil
  defp posting_parts(%Date{} = date), do: {date, false}

  defp posting_parts(%{date: date} = context) do
    {date, Map.get(context, :late) in [true, 1]}
  end

  defp posting_parts(_), do: nil

  defp posting_date_of(posting) do
    case posting_parts(posting) do
      {date, _} -> date
      _ -> nil
    end
  end

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
