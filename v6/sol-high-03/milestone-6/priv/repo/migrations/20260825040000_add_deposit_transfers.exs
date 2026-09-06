defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      add :allocation_order, :integer
    end

    alter table(:credit_allocations) do
      add :allocation_order, :integer
    end

    alter table(:cash_payments) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end

    create table(:allocation_counters, primary_key: false) do
      add :id, :integer, primary_key: true
      add :last_value, :integer, null: false
    end

    create table(:cash_dispositions) do
      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :string),
          null: false

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :restrict),
          null: false

      add :kind, :string,
        null: false,
        check: %{
          name: "cash_dispositions_valid_kind",
          expr: "kind IN ('refunded', 'retained', 'converted_to_credit')"
        }

      add :amount_cents, :integer,
        null: false,
        check: %{name: "cash_dispositions_positive_amount", expr: "amount_cents > 0"}
    end

    create index(:cash_dispositions, [:payment_operation_id])
    create index(:cash_dispositions, [:group_id])

    flush()
    backfill_allocation_order()
    backfill_cash_dispositions()

    create unique_index(:cash_allocations, [:allocation_order])
    create unique_index(:credit_allocations, [:allocation_order])
  end

  def down do
    drop table(:cash_dispositions)
    drop table(:allocation_counters)

    alter table(:cash_payments) do
      remove :participated_in_transfer
    end

    alter table(:credit_allocations) do
      remove :allocation_order
    end

    alter table(:cash_allocations) do
      remove :allocation_order
    end
  end

  defp backfill_allocation_order do
    repository = repo()

    cash =
      repository.query!(
        """
        SELECT allocations.id,
               COALESCE(operations.id, 0) AS operation_order
          FROM cash_allocations AS allocations
          LEFT JOIN partner_operations AS operations
            ON operations.operation_id = allocations.payment_operation_id
         ORDER BY operation_order, allocations.id
        """,
        []
      ).rows
      |> Enum.map(fn [id, operation_order] -> {operation_order, 0, id, :cash} end)

    credit = credit_allocation_order(repository)

    last_value =
      (cash ++ credit)
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.reduce(0, fn {{_operation_order, _kind_order, id, kind}, allocation_order}, _ ->
        table = if kind == :cash, do: "cash_allocations", else: "credit_allocations"

        repository.query!(
          "UPDATE #{table} SET allocation_order = ? WHERE id = ?",
          [allocation_order, id]
        )

        allocation_order
      end)

    repository.query!(
      "INSERT INTO allocation_counters (id, last_value) VALUES (1, ?)",
      [last_value]
    )
  end

  defp credit_allocation_order(repository) do
    operations =
      repository.query!(
        "SELECT id, result FROM partner_operations WHERE operation_type = 'apply_hotel_credit' ORDER BY id",
        []
      ).rows
      |> Enum.flat_map(fn [id, raw_result] ->
        result = decode_json(raw_result)

        if result["status"] == "applied",
          do: [{result["group_id"], id, result["amount_cents"]}],
          else: []
      end)
      |> Enum.group_by(&elem(&1, 0), fn {_group_id, id, amount} -> {id, amount} end)

    repository.query!(
      "SELECT id, group_id, amount_cents FROM credit_allocations ORDER BY group_id, id",
      []
    ).rows
    |> Enum.group_by(&Enum.at(&1, 1))
    |> Enum.flat_map(fn {group_id, rows} ->
      durable_sources = Map.get(operations, group_id, [])
      current_amount = Enum.sum(Enum.map(rows, &Enum.at(&1, 2)))
      durable_amount = Enum.sum(Enum.map(durable_sources, &elem(&1, 1)))
      sources = [{0, max(current_amount - durable_amount, 0)} | durable_sources]

      {ranked, _sources} =
        Enum.map_reduce(rows, sources, fn [id, _group_id, amount], remaining_sources ->
          {operation_order, next_sources} = consume_source_amount(remaining_sources, amount)
          {{operation_order, 1, id, :credit}, next_sources}
        end)

      ranked
    end)
  end

  defp consume_source_amount([{_order, 0} | rest], amount),
    do: consume_source_amount(rest, amount)

  defp consume_source_amount([{order, available} | rest], amount) when available >= amount,
    do: {order, [{order, available - amount} | rest]}

  defp consume_source_amount([{order, available} | rest], amount),
    do: {order, consume_across_sources(rest, amount - available)}

  defp consume_source_amount([], _amount), do: {0, []}

  defp consume_across_sources([{_order, available} | rest], amount) when available <= amount,
    do: consume_across_sources(rest, amount - available)

  defp consume_across_sources([{order, available} | rest], amount),
    do: [{order, available - amount} | rest]

  defp consume_across_sources([], _amount), do: []

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value), do: Jason.decode!(value)

  defp backfill_cash_dispositions do
    repository = repo()

    for {column, kind} <- [
          {"refunded_cents", "refunded"},
          {"retained_cents", "retained"},
          {"converted_to_credit_cents", "converted_to_credit"}
        ] do
      repository.query!(
        """
        INSERT INTO cash_dispositions (payment_operation_id, group_id, kind, amount_cents)
        SELECT payment_operation_id, group_id, ?, #{column}
          FROM cash_payments
         WHERE #{column} > 0
        """,
        [kind]
      )
    end
  end
end
