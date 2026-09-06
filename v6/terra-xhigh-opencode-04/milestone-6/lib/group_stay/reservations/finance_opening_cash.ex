defmodule GroupStay.Reservations.FinanceOpeningCash do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_opening_cash" do
    field :property_id, :string
    field :opening_held_cents, :integer

    belongs_to :finance_reporting, GroupStay.Reservations.FinanceReporting
  end

  def changeset(opening_cash, attrs) do
    opening_cash
    |> cast(attrs, [:finance_reporting_id, :property_id, :opening_held_cents])
    |> validate_required([:finance_reporting_id, :property_id, :opening_held_cents])
    |> unique_constraint(:property_id,
      name: :finance_opening_cash_finance_reporting_id_property_id_index
    )
  end
end
