defmodule GroupStay.Repo.Migrations.AddDailyFinanceReporting do
  use Ecto.Migration

  def up do
    create table(:finance_reporting, primary_key: false) do
      add :id, :integer, primary_key: true
      add :starts_on, :date, null: false
      add :opening_credit_liability_cents, :integer, null: false
    end

    create table(:finance_cash_openings) do
      add :property_id, :text, null: false
      add :opening_held_cents, :integer, null: false
    end

    create unique_index(:finance_cash_openings, [:property_id])

    create table(:finance_cash_movements) do
      add :operation_id, :text, null: false
      add :payment_operation_id, :text
      add :property_id, :text, null: false
      add :posting_date, :date, null: false
      add :category, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_cash_movements, [:posting_date, :property_id])
    create index(:finance_cash_movements, [:payment_operation_id])

    create table(:finance_credit_movements) do
      add :operation_id, :text, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      add :posting_date, :date, null: false
      add :category, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_movements, [:posting_date])

    create table(:finance_credit_lot_positions) do
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :expires_on, :date, null: false
      add :opening_available_cents, :integer, null: false, default: 0
    end

    create unique_index(:finance_credit_lot_positions, [:credit_lot_id])
    create index(:finance_credit_lot_positions, [:expires_on])

    create table(:finance_credit_availability_movements) do
      add :operation_id, :text, null: false
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict), null: false
      add :posting_date, :date, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:finance_credit_availability_movements, [:credit_lot_id, :posting_date])

    create table(:finance_cash_dispositions) do
      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :text),
          null: false

      add :property_id, :text, null: false
      add :category, :text, null: false
      add :amount_cents, :integer, null: false
    end

    create unique_index(:finance_cash_dispositions, [
             :payment_operation_id,
             :property_id,
             :category
           ])

    flush()
    backfill_cash_dispositions()
  end

  def down do
    drop table(:finance_cash_dispositions)
    drop table(:finance_credit_availability_movements)
    drop table(:finance_credit_lot_positions)
    drop table(:finance_credit_movements)
    drop table(:finance_cash_movements)
    drop table(:finance_cash_openings)
    drop table(:finance_reporting)
  end

  defp backfill_cash_dispositions do
    groups = load_groups()
    settlements = load_settlements(groups)

    %{rows: payment_rows} =
      repo().query!("""
      SELECT p.payment_operation_id, p.group_id, g.guest_id, g.property_id,
             p.refunded_cents, p.retained_cents, p.converted_to_credit_cents,
             COALESCE(o.id, 0), p.participated_in_transfer
      FROM cash_payments p
      JOIN groups g ON g.group_id = p.group_id
      LEFT JOIN operation_records o ON o.operation_id = p.payment_operation_id
      ORDER BY COALESCE(o.id, 0), p.payment_operation_id
      """)

    payments =
      Enum.map(payment_rows, fn [
                                  payment_id,
                                  group_id,
                                  guest_id,
                                  property_id,
                                  refunded,
                                  retained,
                                  converted,
                                  record_id,
                                  participated_in_transfer
                                ] ->
        %{
          payment_id: payment_id,
          original_group_id: group_id,
          guest_id: guest_id,
          original_property_id: property_id,
          refunded: refunded,
          retained: retained,
          converted_to_credit: converted,
          record_id: record_id,
          participated_in_transfer: participated_in_transfer in [true, 1]
        }
      end)

    rows =
      backfill_settled_category(payments, settlements, :refunded) ++
        backfill_settled_category(payments, settlements, :retained) ++
        backfill_converted(payments, groups)

    rows
    |> Enum.group_by(&{&1.payment_id, &1.property_id, &1.category})
    |> Enum.each(fn {{payment_id, property_id, category}, grouped_rows} ->
      amount = Enum.sum(Enum.map(grouped_rows, & &1.amount))
      insert_disposition(payment_id, property_id, Atom.to_string(category), amount)
    end)
  end

  defp load_groups do
    %{rows: rows} = repo().query!("SELECT group_id, guest_id, property_id FROM groups")

    Map.new(rows, fn [group_id, guest_id, property_id] ->
      {group_id, %{guest_id: guest_id, property_id: property_id}}
    end)
  end

  defp load_settlements(groups) do
    %{rows: rows} =
      repo().query!("""
      SELECT id, result
      FROM operation_records
      WHERE operation_type IN ('cancel_group', 'cancel_rooms')
      ORDER BY id
      """)

    rows
    |> Enum.flat_map(fn [record_id, encoded_result] ->
      result = decode_json(encoded_result)
      group_id = result["group_id"]
      group = Map.get(groups, group_id)

      if result["status"] == "applied" and group do
        [
          settlement(record_id, group_id, group, :refunded, result["refunded_cents"] || 0),
          settlement(record_id, group_id, group, :retained, result["retained_cents"] || 0)
        ]
      else
        []
      end
    end)
    |> List.flatten()
    |> Enum.reject(&(&1.remaining == 0))
  end

  defp settlement(record_id, group_id, group, category, amount) do
    %{
      record_id: record_id,
      group_id: group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      category: category,
      remaining: amount
    }
  end

  defp backfill_settled_category(payments, settlements, category) do
    category_payments = Enum.filter(payments, &(&1[category] > 0))
    category_settlements = Enum.filter(settlements, &(&1.category == category))

    {direct_rows, category_settlements} =
      category_payments
      |> Enum.reject(& &1.participated_in_transfer)
      |> Enum.map_reduce(category_settlements, fn payment, remaining_settlements ->
        remaining_settlements =
          reserve_original_group_settlement(
            remaining_settlements,
            payment.original_group_id,
            payment.record_id,
            payment[category]
          )

        {disposition_row(payment, payment.original_property_id, category, payment[category]),
         remaining_settlements}
      end)

    transferred_payments = Enum.filter(category_payments, & &1.participated_in_transfer)

    guest_ids =
      (Enum.map(transferred_payments, & &1.guest_id) ++
         Enum.map(category_settlements, & &1.guest_id))
      |> Enum.uniq()

    transferred_rows =
      Enum.flat_map(guest_ids, fn guest_id ->
        guest_payments = Enum.filter(transferred_payments, &(&1.guest_id == guest_id))
        guest_settlements = Enum.filter(category_settlements, &(&1.guest_id == guest_id))

        untracked =
          max(
            Enum.sum(Enum.map(guest_settlements, & &1.remaining)) -
              Enum.sum(Enum.map(guest_payments, & &1[category])),
            0
          )

        {_legacy_rows, available_settlements, _unmatched_legacy} =
          take_from_settlements(guest_settlements, untracked, -1, nil, category)

        {rows, _settlements} =
          Enum.map_reduce(guest_payments, available_settlements, fn payment,
                                                                    remaining_settlements ->
            {allocated, remaining_settlements, unmatched} =
              take_from_settlements(
                remaining_settlements,
                payment[category],
                payment.record_id,
                payment.payment_id,
                category
              )

            fallback =
              if unmatched > 0 do
                [disposition_row(payment, payment.original_property_id, category, unmatched)]
              else
                []
              end

            {allocated ++ fallback, remaining_settlements}
          end)

        List.flatten(rows)
      end)

    direct_rows ++ transferred_rows
  end

  defp reserve_original_group_settlement(settlements, group_id, minimum_record_id, amount) do
    {updated, _remaining} =
      Enum.map_reduce(settlements, amount, fn settlement, remaining ->
        available =
          if settlement.group_id == group_id and settlement.record_id > minimum_record_id,
            do: settlement.remaining,
            else: 0

        reserved = min(available, remaining)
        {%{settlement | remaining: settlement.remaining - reserved}, remaining - reserved}
      end)

    updated
  end

  defp take_from_settlements(settlements, requested, minimum_record_id, payment_id, category) do
    {updated, rows, remaining} =
      Enum.reduce(settlements, {[], [], requested}, fn settlement, {updated, rows, remaining} ->
        available =
          if settlement.record_id > minimum_record_id, do: settlement.remaining, else: 0

        amount = min(available, remaining)

        row =
          if amount > 0 and payment_id do
            [
              %{
                payment_id: payment_id,
                property_id: settlement.property_id,
                category: category,
                amount: amount
              }
            ]
          else
            []
          end

        {
          [%{settlement | remaining: settlement.remaining - amount} | updated],
          row ++ rows,
          remaining - amount
        }
      end)

    {Enum.reverse(rows), Enum.reverse(updated), remaining}
  end

  defp backfill_converted(payments, groups) do
    %{rows: entitlement_rows} =
      repo().query!("""
      SELECT e.payment_operation_id, l.source_operation_id, SUM(e.principal_cents)
      FROM credit_entitlements e
      JOIN credit_lots l ON l.id = e.credit_lot_id
      WHERE e.payment_operation_id IS NOT NULL
      GROUP BY e.payment_operation_id, l.source_operation_id
      ORDER BY MIN(e.id)
      """)

    operation_groups = operation_result_groups()

    attributed =
      Enum.flat_map(entitlement_rows, fn [payment_id, source_operation_id, amount] ->
        with group_id when is_binary(group_id) <- operation_groups[source_operation_id],
             %{property_id: property_id} <- groups[group_id] do
          [
            %{
              payment_id: payment_id,
              property_id: property_id,
              category: :converted_to_credit,
              amount: amount
            }
          ]
        else
          _missing -> []
        end
      end)

    attributed_by_payment =
      attributed
      |> Enum.group_by(& &1.payment_id)
      |> Map.new(fn {payment_id, rows} ->
        {payment_id, Enum.sum(Enum.map(rows, & &1.amount))}
      end)

    fallback =
      Enum.flat_map(payments, fn payment ->
        unmatched =
          payment.converted_to_credit - Map.get(attributed_by_payment, payment.payment_id, 0)

        if unmatched > 0 do
          [
            disposition_row(
              payment,
              payment.original_property_id,
              :converted_to_credit,
              unmatched
            )
          ]
        else
          []
        end
      end)

    attributed ++ fallback
  end

  defp operation_result_groups do
    %{rows: rows} = repo().query!("SELECT operation_id, result FROM operation_records")

    Map.new(rows, fn [operation_id, encoded_result] ->
      {operation_id, decode_json(encoded_result)["group_id"]}
    end)
  end

  defp disposition_row(payment, property_id, category, amount) do
    %{
      payment_id: payment.payment_id,
      property_id: property_id,
      category: category,
      amount: amount
    }
  end

  defp insert_disposition(_payment_id, _property_id, _category, 0), do: :ok

  defp insert_disposition(payment_id, property_id, category, amount) do
    repo().query!(
      "INSERT INTO finance_cash_dispositions (payment_operation_id, property_id, category, amount_cents) VALUES (?, ?, ?, ?)",
      [payment_id, property_id, category, amount]
    )
  end

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
end
