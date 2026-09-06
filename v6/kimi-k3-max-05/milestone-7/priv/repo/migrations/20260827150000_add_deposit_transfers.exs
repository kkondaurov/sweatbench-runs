defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    alter table(:cash_allocations) do
      # Wall-clock insertion order cannot order cash allocations against
      # credit applications created in the same second, so both funding
      # kinds share one allocation sequence. Transfer draws consume a
      # source group's held funding from the highest sequence first.
      add :allocation_seq, :integer
    end

    alter table(:credit_applications) do
      add :allocation_seq, :integer
    end

    create index(:cash_allocations, [:allocation_seq])
    create index(:credit_applications, [:allocation_seq])

    flush()

    backfill_allocation_sequences()
  end

  def down do
    drop index(:credit_applications, [:allocation_seq])

    alter table(:credit_applications) do
      remove :allocation_seq
    end

    drop index(:cash_allocations, [:allocation_seq])

    alter table(:cash_allocations) do
      remove :allocation_seq
    end
  end

  # Existing rows receive a sequence consistent with their wall-clock
  # insertion; ties allocate cash before credit, matching the order the
  # room-accounting migration brought legacy funding forward in.
  defp backfill_allocation_sequences do
    cash =
      repo().query!("SELECT id, inserted_at FROM cash_allocations ORDER BY id").rows
      |> Enum.map(fn [id, inserted_at] -> {:cash, id, inserted_at} end)

    credit =
      repo().query!("SELECT id, inserted_at FROM credit_applications ORDER BY id").rows
      |> Enum.map(fn [id, inserted_at] -> {:credit, id, inserted_at} end)

    (cash ++ credit)
    |> Enum.sort_by(fn {kind, id, inserted_at} -> {inserted_at, kind_rank(kind), id} end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{kind, id, _inserted_at}, seq} ->
      repo().query!(
        "UPDATE #{table_name(kind)} SET allocation_seq = ?1 WHERE id = ?2",
        [seq, id]
      )
    end)
  end

  defp table_name(:cash), do: "cash_allocations"
  defp table_name(:credit), do: "credit_applications"

  defp kind_rank(:cash), do: 0
  defp kind_rank(:credit), do: 1
end
