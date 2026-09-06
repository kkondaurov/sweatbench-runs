defmodule GroupStay.Reporting do
  @moduledoc "Durable finance-reporting inception, movements, and read-only reports."

  import Ecto.Query

  alias GroupStay.CashSettlement
  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Reporting.{CreditExpiry, FinanceReportMovement, FinanceReporting}
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
      opening_credit_liability_cents: opening_credit_liability_cents
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
          {:ok, build_report(reporting, date)}
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

  def record_credit_consumption(occurred_on, segments) do
    with_reporting(fn _reporting ->
      Enum.each(segments, fn segment ->
        adjust_expiry_tracking(segment.lot_id, segment.amount_cents, occurred_on)
      end)
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

          expired_cents =
            detail.expired_cents +
              if(
                detail.restored_cents > 0 and
                  Date.compare(detail.expires_on, reporting.starts_on) != :gt,
                do: detail.restored_cents,
                else: 0
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
      attrs =
        if Date.compare(lot.expires_on, reporting.starts_on) == :gt,
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
      revoked_cents =
        Enum.reduce(details, 0, fn detail, total ->
          if detail.removed_cents > 0 and
               Date.compare(detail.expires_on, reporting.starts_on) == :gt and
               Date.compare(detail.expires_on, occurred_on) == :gt do
            adjust_expiry_tracking(detail.lot_id, -detail.removed_cents, occurred_on)
            total + detail.removed_cents
          else
            total
          end
        end)

      if revoked_cents > 0 do
        insert_movement!(reporting, operation_id, occurred_on, nil, %{
          revoked_cents: revoked_cents
        })
      end
    end)

    :ok
  end

  defp build_report(reporting, date) do
    rows = Repo.all(from movement in FinanceReportMovement, where: movement.posting_date <= ^date)
    before_rows = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :lt))
    today_rows = Enum.filter(rows, &(Date.compare(&1.posting_date, date) == :eq))
    opening_cash = Jason.decode!(reporting.opening_cash_json)
    before_cash = aggregate_cash(before_rows)
    today_cash = aggregate_cash(today_rows)

    property_ids =
      (Map.keys(opening_cash) ++ Map.keys(before_cash) ++ Map.keys(today_cash))
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      property_ids
      |> Enum.map(fn property_id ->
        opening_held_cents =
          Map.get(opening_cash, property_id, 0) +
            cash_delta(Map.get(before_cash, property_id, %{}))

        movement = cash_movement(Map.get(today_cash, property_id, %{}))
        closing_held_cents = opening_held_cents + cash_delta(movement)

        %{
          property_id: property_id,
          opening_held_cents: opening_held_cents,
          movements: movement,
          closing_held_cents: closing_held_cents
        }
      end)
      |> Enum.filter(&cash_entry_present?/1)

    before_credit = aggregate_credit(before_rows)
    today_credit = aggregate_credit(today_rows)
    before_expired = expiry_amount(reporting.starts_on, date, :before)
    today_expired = expiry_amount(reporting.starts_on, date, :today)

    before_credit =
      Map.update(before_credit, :expired_cents, before_expired, &(&1 + before_expired))

    today_credit = Map.update(today_credit, :expired_cents, today_expired, &(&1 + today_expired))

    opening_liability_cents =
      reporting.opening_credit_liability_cents + credit_delta(before_credit)

    credit_movement = credit_movement(today_credit)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening_liability_cents,
        movements: credit_movement,
        closing_liability_cents: opening_liability_cents + credit_delta(credit_movement)
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

        nil ->
          :ok

        expiry ->
          new_amount = max(expiry.scheduled_cents + amount_cents, 0)
          Repo.update!(Ecto.Changeset.change(expiry, scheduled_cents: new_amount))
      end
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

  defp expiry_amount(starts_on, date, mode) do
    comparison = if mode == :before, do: :lt, else: :eq

    Repo.all(
      from expiry in CreditExpiry,
        where: expiry.expires_on >= ^starts_on and expiry.expires_on <= ^date,
        select: {expiry.expires_on, expiry.scheduled_cents}
    )
    |> Enum.filter(fn {expires_on, _amount} -> Date.compare(expires_on, date) == comparison end)
    |> Enum.reduce(0, fn {_expires_on, amount_cents}, total -> total + amount_cents end)
  end

  defp cash_entry_present?(entry) do
    entry.opening_held_cents != 0 or entry.closing_held_cents != 0 or
      Enum.any?(Map.values(entry.movements), &(&1 != 0))
  end

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
    if Date.compare(occurred_on, reporting.starts_on) == :lt,
      do: reporting.starts_on,
      else: occurred_on
  end

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
