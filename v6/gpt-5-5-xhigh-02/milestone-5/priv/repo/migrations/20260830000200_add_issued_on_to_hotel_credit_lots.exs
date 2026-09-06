defmodule GroupStay.Repo.Migrations.AddIssuedOnToHotelCreditLots do
  use Ecto.Migration

  def up do
    alter table(:hotel_credit_lots) do
      add :issued_on, :date
    end

    execute("""
    UPDATE hotel_credit_lots
    SET issued_on = date(inserted_at)
    """)

    create index(:hotel_credit_lots, [:guest_id, :issued_on, :expires_on, :source_operation_id])
  end

  def down do
    drop index(:hotel_credit_lots, [:guest_id, :issued_on, :expires_on, :source_operation_id])

    alter table(:hotel_credit_lots) do
      remove :issued_on
    end
  end
end
