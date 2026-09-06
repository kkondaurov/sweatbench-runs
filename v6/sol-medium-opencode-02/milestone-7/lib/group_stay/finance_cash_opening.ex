defmodule GroupStay.FinanceCashOpening do
  use Ecto.Schema

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer

    belongs_to :finance_reporting, GroupStay.FinanceReporting

    timestamps(type: :utc_datetime)
  end
end
