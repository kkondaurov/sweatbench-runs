defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  import Ecto.Query

  alias GroupStay.Groups.{RoomCashAllocation, RoomCreditApplication}

  def up do
    alter table(:room_cash_allocations, primary_key: false) do
      add :allocation_seq, :integer
      add :moved_by_transfer, :boolean, null: false, default: false
    end

    alter table(:room_credit_applications, primary_key: false) do
      add :allocation_seq, :integer
    end

    flush()

    number_allocations()
  end

  def down do
    alter table(:room_credit_applications, primary_key: false) do
      remove :allocation_seq
    end

    alter table(:room_cash_allocations, primary_key: false) do
      remove :moved_by_transfer
      remove :allocation_seq
    end
  end

  # Cash and hotel credit allocate through two separate tables, while deposit
  # transfers unwind "the most recently created allocation first, regardless
  # of funding kind". A shared sequence gives every allocation one creation
  # order that both tables can be merged by. Existing rows are numbered oldest
  # first from their insertion order and timestamps; ties between the tables
  # break toward cash, then by each table's own insertion order.
  defp number_allocations do
    cash =
      repo().all(
        from(a in RoomCashAllocation,
          select: {a.id, a.inserted_at, fragment("rowid")},
          order_by: [asc: fragment("rowid")]
        )
      )
      |> Enum.map(fn {id, inserted_at, rowid} -> {0, inserted_at, rowid, id} end)

    credit =
      repo().all(
        from(a in RoomCreditApplication,
          select: {a.id, a.inserted_at, fragment("rowid")},
          order_by: [asc: fragment("rowid")]
        )
      )
      |> Enum.map(fn {id, inserted_at, rowid} -> {1, inserted_at, rowid, id} end)

    (cash ++ credit)
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.each(fn
      {{0, _inserted_at, _rowid, id}, seq} ->
        repo().update_all(
          from(a in RoomCashAllocation, where: a.id == ^id),
          set: [allocation_seq: seq]
        )

      {{1, _inserted_at, _rowid, id}, seq} ->
        repo().update_all(
          from(a in RoomCreditApplication, where: a.id == ^id),
          set: [allocation_seq: seq]
        )
    end)
  end
end
