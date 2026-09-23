defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:group_cash_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:group_credit_allocations) do
      add :allocation_order, :integer, null: false, default: 0
    end

    alter table(:partner_operations) do
      add :transferred_funding, :boolean, null: false, default: false
    end

    create index(:group_cash_allocations, [:group_id, :allocation_order])
    create index(:group_credit_allocations, [:group_id, :allocation_order])

    flush()
    backfill_allocation_order()
  end

  def down do
    drop index(:group_credit_allocations, [:group_id, :allocation_order])
    drop index(:group_cash_allocations, [:group_id, :allocation_order])

    alter table(:partner_operations) do
      remove :transferred_funding
    end

    alter table(:group_credit_allocations) do
      remove :allocation_order
    end

    alter table(:group_cash_allocations) do
      remove :allocation_order
    end
  end

  defp backfill_allocation_order do
    operations =
      repo().query!(
        "SELECT operation_id, operation_type, result FROM partner_operations ORDER BY rowid"
      ).rows
      |> Enum.map(fn [operation_id, operation_type, result] ->
        %{operation_id: operation_id, type: operation_type, result: decode_json(result)}
      end)

    groups =
      repo().query!(
        "SELECT group_id, status, cash_paid_cents, credit_paid_cents FROM groups ORDER BY group_id"
      ).rows

    next_order =
      Enum.reduce(groups, 0, fn [group_id, status, cash_paid, credit_paid], next_order ->
        if status != "active" do
          next_order
        else
          group_operations =
            Enum.filter(operations, fn operation ->
              operation.result["group_id"] == group_id and operation.result["status"] == "applied" and
                operation.type in ["record_cash_payment", "apply_hotel_credit"]
            end)

          durable_cash =
            group_operations
            |> Enum.filter(&(&1.type == "record_cash_payment"))
            |> Enum.reduce(0, &((&1.result["amount_cents"] || 0) + &2))

          durable_credit =
            group_operations
            |> Enum.filter(&(&1.type == "apply_hotel_credit"))
            |> Enum.reduce(0, &((&1.result["amount_cents"] || 0) + &2))

          legacy_cash = max(cash_paid - durable_cash, 0)
          legacy_credit = max(credit_paid - durable_credit, 0)

          cash_rows =
            repo().query!(
              "SELECT id, amount_cents FROM group_cash_allocations WHERE group_id = ? AND payment_operation_id IS NULL ORDER BY id",
              [group_id]
            ).rows

          {next_order, _} = assign_rows(cash_rows, legacy_cash, :cash, next_order)

          credit_rows =
            repo().query!(
              "SELECT id, amount_cents FROM group_credit_allocations WHERE group_id = ? ORDER BY id",
              [group_id]
            ).rows

          {next_order, credit_rows} = assign_rows(credit_rows, legacy_credit, :credit, next_order)

          Enum.reduce(group_operations, {next_order, credit_rows}, fn operation,
                                                                      {order,
                                                                       remaining_credit_rows} ->
            case operation.type do
              "record_cash_payment" ->
                rows =
                  repo().query!(
                    "SELECT id, amount_cents FROM group_cash_allocations WHERE group_id = ? AND payment_operation_id = ? ORDER BY id",
                    [group_id, operation.operation_id]
                  ).rows

                {order, _} =
                  assign_rows(rows, operation.result["amount_cents"] || 0, :cash, order)

                {order, remaining_credit_rows}

              "apply_hotel_credit" ->
                assign_rows(
                  remaining_credit_rows,
                  operation.result["amount_cents"] || 0,
                  :credit,
                  order
                )
            end
          end)
          |> elem(0)
        end
      end)

    # Any rows left over indicate funding not represented by the aggregate and durable records.
    # Keep them usable and senior to future allocations while preserving their table-local order.
    leftovers =
      Enum.map(
        repo().query!(
          "SELECT id FROM group_cash_allocations WHERE allocation_order = 0 ORDER BY id"
        ).rows,
        &{:group_cash_allocations, hd(&1)}
      ) ++
        Enum.map(
          repo().query!(
            "SELECT id FROM group_credit_allocations WHERE allocation_order = 0 ORDER BY id"
          ).rows,
          &{:group_credit_allocations, hd(&1)}
        )

    Enum.reduce(leftovers, next_order, fn {table, id}, order ->
      next_order = order + 1
      repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [next_order, id])
      next_order
    end)
  end

  defp assign_rows(rows, 0, _kind, order), do: {order, rows}
  defp assign_rows([], _amount, _kind, order), do: {order, []}

  defp assign_rows([[id, row_amount] | rest], amount, kind, order) do
    next_order = order + 1
    table = if kind == :cash, do: "group_cash_allocations", else: "group_credit_allocations"
    repo().query!("UPDATE #{table} SET allocation_order = ? WHERE id = ?", [next_order, id])

    if row_amount >= amount do
      {next_order, rest}
    else
      assign_rows(rest, amount - row_amount, kind, next_order)
    end
  end

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
end
