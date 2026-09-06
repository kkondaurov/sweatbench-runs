defmodule GroupStay.Repo.Migrations.AddCreditIssuedOn do
  use Ecto.Migration

  def change do
    alter table(:hotel_credit_lots) do
      add :issued_on, :date
    end

    execute """
    UPDATE hotel_credit_lots
    SET issued_on = date(expires_on, '-366 days')
    WHERE issued_on IS NULL
    """
  end
end
