defmodule GroupStay.Finance.CashOpening do
  use Ecto.Schema

  schema "finance_cash_openings" do
    field :property_id, :string
    field :held_cents, :integer
    belongs_to :finance_reporting, GroupStay.Finance.Reporting

    timestamps(type: :utc_datetime)
  end
end
