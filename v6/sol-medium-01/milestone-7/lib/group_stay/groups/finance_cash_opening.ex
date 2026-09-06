defmodule GroupStay.Groups.FinanceCashOpening do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer
    belongs_to :finance_reporting, GroupStay.Groups.FinanceReporting

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:finance_reporting_id, :property_id, :opening_held_cents])
    |> validate_required([:finance_reporting_id, :property_id, :opening_held_cents])
  end
end
