defmodule GroupStay.FinanceOpeningCash do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_opening_cash" do
    belongs_to :reporting, GroupStay.FinanceReporting
    field :property_id, :string
    field :opening_held_cents, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:reporting_id, :property_id, :opening_held_cents])
    |> validate_required([:reporting_id, :property_id, :opening_held_cents])
  end
end
