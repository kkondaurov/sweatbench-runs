defmodule GroupStay.Reservations.FinanceOpeningCreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finance_opening_credit_lots" do
    field :credit_lot_id, :binary_id
    field :expires_on, :date
    field :opening_available_cents, :integer

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting, type: :id
  end

  def changeset(opening_lot, attrs) do
    opening_lot
    |> cast(attrs, [:finance_reporting_id, :credit_lot_id, :expires_on, :opening_available_cents])
    |> validate_required([
      :finance_reporting_id,
      :credit_lot_id,
      :expires_on,
      :opening_available_cents
    ])
    |> unique_constraint(:credit_lot_id,
      name: :finance_opening_credit_lots_finance_reporting_id_credit_lot_id_index
    )
  end
end
