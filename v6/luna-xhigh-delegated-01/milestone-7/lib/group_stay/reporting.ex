defmodule GroupStay.Reporting do
  @moduledoc "Durable finance-reporting inception, movements, and read-only reports."

  import Ecto.Query

  alias GroupStay.CashSettlement
  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.{Group, Room}

  alias GroupStay.Reporting.{
    CreditExpiry,
    FinanceReportMovement,
    FinanceReportSnapshot,
    FinanceReporting
  }

  alias GroupStay.Repo

  @reporting_id 1

  @cash_fields [
    :received_cents,
    :transferred_in_cents,
    :transferred_out_cents,
    :refunded_cents,
    :retained_cents,
    :converted_to_credit_cents,
    :reduced_cents,
    :charged_back_cents
  ]

  @credit_fields [:issued_cents, :expired_cents, :consumed_cents, :revoked_cents, :absorbed_cents]

  def started? do
    Repo.exists?(from reporting in FinanceReporting, where: reporting.id == ^@reporting_id)
  end

  def start!(starts_on) do
    opening_cash = current_cash_by_property()
    opening_credit_liability_cents = Credit.liability(starts_on)

    Repo.insert!(%FinanceReporting{
      id: @reporting_id,
      starts_on: starts_on,
      opening_cash_json: Jason.encode!(opening_cash),
      opening_credit_liability_cents: opening_credit_liability_cents,
      latest_close_on: nil
    })

    initialize_credit_expiries(starts_on)
    :ok
  end

  def read(date) do
    case Repo.get(FinanceReporting, @reporting_id) do
      nil ->
        {:error, :report_not_available}

      reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :report_not_available}
        else
          case Repo.get(FinanceReportSnapshot, date) do
            nil ->
              report = build_report(reporting, date)

              if closed_on?(reporting, date),
                do: {:ok, Map.put(report, :status, "closed")},
                else: {:ok, report}

            snapshot ->
              {:ok, Jason.decode!(snapshot.data_json)}
          end
        end
    end
  end

  def close!(period_end_on) do
    case Repo.get(FinanceReporting, @reporting_id) do
      nil ->
        {:error, :invalid_period}

      reporting ->
        cond do
          Date.compare(period_end_on, reporting.starts_on) == :lt ->
            {:error, :invalid_period}

          reporting.latest_close_on &&
              Date.compare(period_end_on, reporting.latest_close_on) != :gt ->
            {:error, :invalid_period}

          true ->
            first_date =
              case reporting.latest_close_on do
                nil -> reporting.starts_on
                latest_close_on -> Date.add(latest_close_on, 1)
              end

            first_date
            |> Date.range(period_end_on)
            |> Enum.each(fn date ->
              case Repo.get(FinanceReportSnapshot, date) do
                nil ->
                  report = build_report(reporting, date) |> Map.put(:status, "closed")

                  Repo.insert!(%FinanceReportSnapshot{
                    report_date: date,
                    data_json: Jason.encode!(canonical_json(report))
                  })

                _snapshot ->
                  :ok
              end
            end)

            Repo.update!(Ecto.Changeset.change(reporting, latest_close_on: period_end_on))
            :ok
        end
    end
  end

  def record_cash_received(operation_id, occurred_on, property_id, amount_cents) do
    with_reporting(fn reporting ->
      insert_movement!(reporting, operation_id, occurred_on, property_id, %{
        received_cents: amount_cents
      })
    end)
  end

  def record_cash_settlement(
        operation_id,
        occurred_on,
        property_id,
        allocations,
        disposition
      ) do
    grouped_allocations =
      allocations
      |> Enum.filter(&(&1.amount_cents > 0))
      |> Enum.group_by(& &1.operation_id, & &1.amount_cents)

    Enum.each(grouped_allocations, fn {payment_operation_id, amounts} ->
      if is_binary(payment_operation_id) do
        Repo.insert!(%CashSettlement{
          payment_operation_id: payment_operation_id,
          settlement_operation_id: operation_id,
          property_id: property_id,
          disposition: Atom.to_string(disposition),
          amount_cents: Enum.sum(amounts)
        })
      end
    end)

    with_reporting(fn reporting ->
      field = disposition_field(disposition)

      Enum.each(grouped_allocations, fn {payment_operation_id, amounts} ->
        insert_movement!(
          reporting,
          operation_id,
          occurred_on,
          property_id,
          %{field => Enum.sum(amounts)},
          if(is_binary(payment_operation_id), do: payment_operation_id, else: nil)
        )
      end)
    end)

    :ok
  end

  def record_transfer(
        operation_id,
        occurred_on,
        source_property_id,
        destination_property_id,
        cash_cents
      )
      when cash_cents > 0 do
    with_reporting(fn reporting ->
      insert_movement!(reporting, operation_id, occurred_on, source_property_id, %{
        transferred_out_cents: cash_cents
      })

      insert_movement!(reporting, operation_id, occurred_on, destination_property_id, %{
        transferred_in_cents: cash_cents
      })
    end)

    :ok
  end

  def record_transfer(
        _operation_id,
        _occurred_on,
        _source_property_id,
        _destination_property_id,
        0
      ),
      do: :ok

  def record_reduction(operation_id, occurred_on, removed_by_group) do
    with_reporting(fn reporting ->
      Enum.each(removed_by_group, fn {group_id, amount_cents} ->
        group = Repo.get!(Group, group_id)

        insert_movement!(reporting, operation_id, occurred_on, group.property_id, %{
          reduced_cents: amount_cents
        })
      end)
    end)

    :ok
  end

  def record_charge_back(
        operation_id,
        occurred_on,
        payment_operation_id,
        payment,
        held_by_group
      ) do
    settlements =
      Repo.all(
        from settlement in CashSettlement,
          where: settlement.payment_operation_id == ^payment_operation_id
      )

    with_reporting(fn reporting ->
      settlement_totals =
        Enum.reduce(settlements, %{}, fn settlement, totals ->
          key = {settlement.property_id, settlement.disposition}
          Map.update(totals, key, settlement.amount_cents, &(&1 + settlement.amount_cents))
        end)

      Enum.each([:refunded_cents, :retained_cents, :converted_to_credit_cents], fn field ->
        disposition = disposition_field_name(field)
        recorded = Map.get(payment, field) || 0

        settled =
          settlement_totals
          |> Enum.filter(fn {{_property_id, settlement_disposition}, _amount} ->
            settlement_disposition == disposition
          end)
          |> Enum.reduce(0, fn {_key, amount_cents}, total -> total + amount_cents end)

        if recorded > settled do
          insert_movement!(
            reporting,
            operation_id,
            occurred_on,
            payment_property(payment),
            %{
              field => -(recorded - settled),
              charged_back_cents: recorded - settled
            },
            payment_operation_id
          )
        end
      end)

      Enum.each(settlements, fn settlement ->
        field = settlement_field(settlement.disposition)

        insert_movement!(
          reporting,
          operation_id,
          occurred_on,
          settlement.property_id,
          %{
            field => -settlement.amount_cents,
            charged_back_cents: settlement.amount_cents
          },
          payment_operation_id
        )
      end)

      Enum.each(held_by_group, fn {group_id, amount_cents} ->
        group = Repo.get!(Group, group_id)

        insert_movement!(
          reporting,
          operation_id,
          occurred_on,
          group.property_id,
          %{
            charged_back_cents: amount_cents
          },
          payment_operation_id
        )
      end)
    end)

    :ok
  end

  def record_credit_consumption(operation_id, occurred_on, segments) do
    with_reporting(fn reporting ->
      late_expired_cents =
        Enum.reduce(segments, 0, fn segment, total ->
          removed_cents =
            adjust_expiry_tracking(segment.lot_id, -segment.amount_cents, occurred_on)

          corrected_cents =
            if late_expiry_correction?(reporting, occurred_on, segment.lot_id),
              do: if(removed_cents > 0, do: removed_cents, else: segment.amount_cents),
              else: 0

          total + corrected_cents
        end)

      if late_expired_cents > 0 do
        insert_movement!(reporting, operation_id, occurred_on, nil, %{
          expired_cents: -late_expired_cents
        })
      end
    end)

    :ok
  end

  def record_credit_settlement(operation_id, occurred_on, details) do
    with_reporting(fn reporting ->
      totals =
        Enum.reduce(details, %{expired_cents: 0, consumed_cents: 0, absorbed_cents: 0}, fn detail,
                                                                                           totals ->
          if detail.restored_cents > 0 do
            adjust_expiry_tracking(detail.lot_id, detail.restored_cents, occurred_on)
          end

          late_expired_cents =
            if detail.restored_cents > 0 and
                 late_expiry_correction?(reporting, occurred_on, detail.lot_id),
               do: detail.restored_cents,
               else: 0

          expired_cents =
            detail.expired_cents +
              if(
                detail.restored_cents > 0 and
                  Date.compare(detail.expires_on, reporting.starts_on) != :gt,
                do: detail.restored_cents,
                else: late_expired_cents
              )

          %{
            totals
            | expired_cents: totals.expired_cents + expired_cents,
              consumed_cents: totals.consumed_cents + detail.consumed_cents,
              absorbed_cents: totals.absorbed_cents + detail.absorbed_cents
          }
        end)

      attrs = Map.filter(totals, fn {_field, amount_cents} -> amount_cents > 0 end)

      if map_size(attrs) > 0 do
        insert_movement!(reporting, operation_id, occurred_on, nil, attrs)
      end
    end)

    :ok
  end

  def record_credit_issued(operation_id, occurred_on, lot, amount_cents) when amount_cents > 0 do
    with_reporting(fn reporting ->
      posting_date = posting_date(reporting, occurred_on)

      attrs =
        if Date.compare(lot.expires_on, posting_date) == :gt,
          do: %{issued_cents: amount_cents},
          else: %{issued_cents: amount_cents, expired_cents: amount_cents}

      insert_movement!(reporting, operation_id, occurred_on, nil, attrs)

      if Date.compare(lot.expires_on, reporting.starts_on) == :gt do
        upsert_expiry!(lot.id, lot.expires_on, amount_cents)
      end
    end)

    :ok
  end

  def record_credit_issued(_operation_id, _occurred_on, _lot, 0), do: :ok

  def record_credit_revoked(operation_id, occurred_on, details) do
    with_reporting(fn reporting ->
      {revoked_cents, reversed_expiry_cents} =
        Enum.reduce(details, {0, 0}, fn detail, {revoked_total, reversed_total} ->
          if detail.removed_cents > 0 and
               Date.compare(detail.expires_on, reporting.starts_on) == :gt and
               Date.compare(detail.expires_on, occurred_on) == :gt do
            removed_from_expiry =
              adjust_expiry_tracking(detail.lot_id, -detail.removed_cents, occurred_on)

            reversed_expiry =
              if late_expiry_correction?(reporting, occurred_on, detail.lot_id),
                do: removed_from_expiry,
                else: 0

            {revoked_total + detail.removed_cents, reversed_total + reversed_expiry}
          else
            {revoked_total, reversed_total}
          end
        end)

      attrs =
        if revoked_cents > 0 do
          %{revoked_cents: revoked_cents}
        else
          %{}
        end

      attrs =
        if reversed_expiry_cents > 0,
          do: Map.put(attrs, :expired_cents, -reversed_expiry_cents),
          else: attrs

      if map_size(attrs) > 0 do
        insert_movement!(reporting, operation_id, occurred_on, nil, attrs)
      end
    end)

    :ok
  end

  defp build_report(reporting, date) do
    rows = Repo.all(from movement in FinanceReportMovement, where: movement.posting_date <= ^date)
    before_rows = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :lt))
    today_rows = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :eq))

    {ordinary_today_rows, late_today_rows} =
      Enum.split_with(today_rows, &(not late_movement?(&1, reporting)))

    opening_cash = Jason.decode!(reporting.opening_cash_json)
    before_cash = aggregate_cash(before_rows)
    today_cash = aggregate_cash(ordinary_today_rows)
    late_cash = aggregate_cash(late_today_rows)

    property_ids =
      (Map.keys(opening_cash) ++
         Map.keys(before_cash) ++ Map.keys(today_cash) ++ Map.keys(late_cash))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      property_ids
      |> Enum.map(fn property_id ->
        opening_held_cents =
          Map.get(opening_cash, property_id, 0) +
            cash_delta(Map.get(before_cash, property_id, %{}))

        movement = cash_movement(Map.get(today_cash, property_id, %{}))
        late_movement = cash_movement(Map.get(late_cash, property_id, %{}))

        closing_held_cents =
          opening_held_cents + cash_delta(movement) + cash_delta(late_movement)

        %{
          property_id: property_id,
          opening_held_cents: opening_held_cents,
          movements: movement,
          closing_held_cents: closing_held_cents,
          late_movement: late_movement
        }
      end)
      |> Enum.filter(fn entry ->
        cash_entry_present?(entry) or late_cash_entry_present?(%{movements: entry.late_movement})
      end)
      |> Enum.map(&Map.delete(&1, :late_movement))

    credit_before_rows = credit_rows_before(before_rows, reporting, date)
    before_credit = aggregate_credit(credit_before_rows)
    today_credit = aggregate_credit(ordinary_today_rows)
    late_credit = aggregate_credit(late_today_rows)
    close_on = closed_through(reporting, date)
    before_expired = expiry_amount(reporting.starts_on, date, :before, close_on)
    today_expired = expiry_amount(reporting.starts_on, date, :today, close_on)

    before_credit =
      Map.update(before_credit, :expired_cents, before_expired, &(&1 + before_expired))

    today_credit = Map.update(today_credit, :expired_cents, today_expired, &(&1 + today_expired))

    opening_liability_cents =
      opening_credit_liability(reporting, date) + credit_delta(before_credit)

    credit_movement = credit_movement(today_credit)
    late_credit_movement = credit_movement(late_credit)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening_liability_cents,
        movements: credit_movement,
        closing_liability_cents:
          opening_liability_cents +
            credit_delta(credit_movement) + credit_delta(late_credit_movement)
      },
      late_adjustments: %{
        cash:
          late_cash
          |> Enum.map(fn {property_id, values} ->
            %{property_id: property_id, movements: cash_movement(values)}
          end)
          |> Enum.sort_by(& &1.property_id)
          |> Enum.filter(&late_cash_entry_present?/1),
        credit: late_credit_movement
      }
    }
  end

  defp current_cash_by_property do
    Repo.all(
      from group in Group,
        join: room in Room,
        on: room.group_id == group.group_id,
        where: group.status == "active" and room.status == "active",
        group_by: group.property_id,
        select: {group.property_id, sum(room.cash_paid_cents)}
    )
    |> Enum.into(%{}, fn {property_id, amount_cents} -> {property_id, amount_cents || 0} end)
  end

  defp initialize_credit_expiries(starts_on) do
    Repo.all(
      from lot in Lot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^starts_on
    )
    |> Enum.each(fn lot -> upsert_expiry!(lot.id, lot.expires_on, lot.remaining_cents) end)
  end

  defp upsert_expiry!(lot_id, expires_on, amount_cents) do
    case Repo.get_by(CreditExpiry, lot_id: lot_id) do
      nil ->
        Repo.insert!(%CreditExpiry{
          lot_id: lot_id,
          expires_on: expires_on,
          scheduled_cents: amount_cents
        })

      expiry ->
        Repo.update!(
          Ecto.Changeset.change(expiry, scheduled_cents: expiry.scheduled_cents + amount_cents)
        )
    end
  end

  defp adjust_expiry_tracking(lot_id, amount_cents, as_of) do
    reporting = Repo.get!(FinanceReporting, @reporting_id)
    lot = Repo.get!(Lot, lot_id)

    if amount_cents != 0 and Date.compare(lot.expires_on, as_of) == :gt and
         Date.compare(lot.expires_on, reporting.starts_on) == :gt do
      case Repo.get_by(CreditExpiry, lot_id: lot_id) do
        nil when amount_cents > 0 ->
          Repo.insert!(%CreditExpiry{
            lot_id: lot_id,
            expires_on: lot.expires_on,
            scheduled_cents: amount_cents
          })

          amount_cents

        nil ->
          0

        expiry ->
          new_amount = max(expiry.scheduled_cents + amount_cents, 0)
          Repo.update!(Ecto.Changeset.change(expiry, scheduled_cents: new_amount))
          abs(new_amount - expiry.scheduled_cents)
      end
    else
      0
    end
  end

  defp aggregate_cash(rows) do
    Enum.reduce(rows, %{}, fn row, properties ->
      if row.property_id do
        Map.update(
          properties,
          row.property_id,
          row_cash_values(row),
          &add_values(&1, row_cash_values(row))
        )
      else
        properties
      end
    end)
  end

  defp aggregate_credit(rows) do
    Enum.reduce(rows, %{}, fn row, totals -> add_values(totals, row_credit_values(row)) end)
  end

  defp row_cash_values(row), do: Map.new(@cash_fields, &{&1, Map.get(row, &1) || 0})
  defp row_credit_values(row), do: Map.new(@credit_fields, &{&1, Map.get(row, &1) || 0})

  defp add_values(left, right) do
    Enum.reduce(right, left, fn {field, amount_cents}, values ->
      Map.update(values, field, amount_cents, &(&1 + amount_cents))
    end)
  end

  defp cash_movement(values), do: Map.new(@cash_fields, &{&1, Map.get(values, &1, 0)})
  defp credit_movement(values), do: Map.new(@credit_fields, &{&1, Map.get(values, &1, 0)})

  defp cash_delta(values) do
    (values[:received_cents] || 0) +
      (values[:transferred_in_cents] || 0) -
      (values[:transferred_out_cents] || 0) -
      (values[:refunded_cents] || 0) -
      (values[:retained_cents] || 0) -
      (values[:converted_to_credit_cents] || 0) -
      (values[:reduced_cents] || 0) -
      (values[:charged_back_cents] || 0)
  end

  defp credit_delta(values) do
    (values[:issued_cents] || 0) -
      (values[:expired_cents] || 0) -
      (values[:consumed_cents] || 0) -
      (values[:revoked_cents] || 0) -
      (values[:absorbed_cents] || 0)
  end

  defp expiry_amount(starts_on, date, mode, closed_through_on) do
    comparison = if mode == :before, do: :lt, else: :eq

    Repo.all(
      from expiry in CreditExpiry,
        where: expiry.expires_on >= ^starts_on and expiry.expires_on <= ^date,
        select: {expiry.expires_on, expiry.scheduled_cents}
    )
    |> Enum.filter(fn {expires_on, _amount} ->
      Date.compare(expires_on, date) == comparison and
        (is_nil(closed_through_on) or Date.compare(expires_on, closed_through_on) == :gt)
    end)
    |> Enum.reduce(0, fn {_expires_on, amount_cents}, total -> total + amount_cents end)
  end

  defp credit_rows_before(before_rows, reporting, date) do
    case closed_through(reporting, date) do
      nil -> before_rows
      close_on -> Enum.filter(before_rows, &(Date.compare(&1.posting_date, close_on) == :gt))
    end
  end

  defp opening_credit_liability(reporting, date) do
    case closed_through(reporting, date) do
      nil ->
        reporting.opening_credit_liability_cents

      close_on ->
        reporting_snapshot = Repo.get!(FinanceReportSnapshot, close_on)
        Jason.decode!(reporting_snapshot.data_json)["credit"]["closing_liability_cents"]
    end
  end

  defp cash_entry_present?(entry) do
    entry.opening_held_cents != 0 or entry.closing_held_cents != 0 or
      Enum.any?(Map.values(entry.movements), &(&1 != 0))
  end

  defp late_cash_entry_present?(entry),
    do: Enum.any?(Map.values(entry.movements), &(&1 != 0))

  defp insert_movement!(
         reporting,
         operation_id,
         occurred_on,
         property_id,
         attrs,
         related_payment_operation_id \\ nil
       ) do
    Repo.insert!(%FinanceReportMovement{
      operation_id: operation_id,
      occurred_on: occurred_on,
      posting_date: posting_date(reporting, occurred_on),
      property_id: property_id,
      related_payment_operation_id: related_payment_operation_id,
      received_cents: Map.get(attrs, :received_cents, 0),
      transferred_in_cents: Map.get(attrs, :transferred_in_cents, 0),
      transferred_out_cents: Map.get(attrs, :transferred_out_cents, 0),
      refunded_cents: Map.get(attrs, :refunded_cents, 0),
      retained_cents: Map.get(attrs, :retained_cents, 0),
      converted_to_credit_cents: Map.get(attrs, :converted_to_credit_cents, 0),
      reduced_cents: Map.get(attrs, :reduced_cents, 0),
      charged_back_cents: Map.get(attrs, :charged_back_cents, 0),
      issued_cents: Map.get(attrs, :issued_cents, 0),
      expired_cents: Map.get(attrs, :expired_cents, 0),
      consumed_cents: Map.get(attrs, :consumed_cents, 0),
      revoked_cents: Map.get(attrs, :revoked_cents, 0),
      absorbed_cents: Map.get(attrs, :absorbed_cents, 0)
    })
  end

  defp posting_date(reporting, occurred_on) do
    natural_date = later_date(occurred_on, reporting.starts_on)

    case reporting.latest_close_on do
      nil -> natural_date
      latest_close_on -> later_date(natural_date, Date.add(latest_close_on, 1))
    end
  end

  defp late_movement?(%{occurred_on: nil}, _reporting), do: false

  defp late_movement?(movement, reporting) do
    natural_date = later_date(movement.occurred_on, reporting.starts_on)
    Date.compare(movement.posting_date, natural_date) == :gt
  end

  defp late_expiry_correction?(reporting, occurred_on, lot_id) do
    case reporting.latest_close_on do
      nil ->
        false

      latest_close_on ->
        lot = Repo.get!(Lot, lot_id)

        Date.compare(lot.expires_on, latest_close_on) != :gt and
          late_posting?(reporting, occurred_on)
    end
  end

  defp late_posting?(reporting, occurred_on) do
    Date.compare(
      posting_date(reporting, occurred_on),
      later_date(occurred_on, reporting.starts_on)
    ) ==
      :gt
  end

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp closed_on?(reporting, date) do
    reporting.latest_close_on && Date.compare(date, reporting.latest_close_on) != :gt
  end

  defp closed_through(reporting, date) do
    if reporting.latest_close_on && Date.compare(date, reporting.latest_close_on) == :gt,
      do: reporting.latest_close_on,
      else: nil
  end

  defp canonical_json(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {if(is_binary(key), do: key, else: to_string(key)), canonical_json(nested_value)}
    end)
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value

  defp with_reporting(fun) do
    case Repo.get(FinanceReporting, @reporting_id) do
      nil -> :ok
      reporting -> fun.(reporting)
    end
  end

  defp disposition_field(:refunded), do: :refunded_cents
  defp disposition_field(:retained), do: :retained_cents
  defp disposition_field(:converted), do: :converted_to_credit_cents

  defp disposition_field_name(:refunded_cents), do: "refunded"
  defp disposition_field_name(:retained_cents), do: "retained"
  defp disposition_field_name(:converted_to_credit_cents), do: "converted"

  defp settlement_field("refunded"), do: :refunded_cents
  defp settlement_field("retained"), do: :retained_cents
  defp settlement_field("converted"), do: :converted_to_credit_cents

  defp payment_property(payment) do
    Repo.get!(Group, payment.group_id).property_id
  end
end
