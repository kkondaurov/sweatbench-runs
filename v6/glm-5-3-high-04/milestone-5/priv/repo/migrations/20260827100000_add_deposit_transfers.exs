defmodule GroupStay.Repo.Migrations.AddDepositTransfers do
  use Ecto.Migration

  def up do
    # Global creation order of room allocations, shared by cash and credit
    # funding so transfers can draw them in reverse allocation order
    # regardless of funding kind. Null marks allocations created before this
    # release; they order before every sequenced allocation using their
    # attribution.
    alter table(:room_cash_allocations) do
      add :seq, :integer
    end

    alter table(:credit_applications) do
      add :seq, :integer
    end

    create index(:room_cash_allocations, [:seq])
    create index(:credit_applications, [:seq])

    # True once any funding of the payment has participated in a transfer;
    # from then on its statement carries held_by_group.
    alter table(:payment_records) do
      add :participated_in_transfer, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:payment_records) do
      remove :participated_in_transfer
    end

    drop index(:credit_applications, [:seq])
    drop index(:room_cash_allocations, [:seq])

    alter table(:credit_applications) do
      remove :seq
    end

    alter table(:room_cash_allocations) do
      remove :seq
    end
  end
end
