defmodule GroupStay.FinanceOpeningCash do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_opening_cash" do
    field :property_id, :string
    field :held_cents, :integer

    belongs_to :finance_reporting, GroupStay.FinanceReporting

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:finance_reporting_id, :property_id, :held_cents])
    |> validate_required([:finance_reporting_id, :property_id, :held_cents])
  end
end
