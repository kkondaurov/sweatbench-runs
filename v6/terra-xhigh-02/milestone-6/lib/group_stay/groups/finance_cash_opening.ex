defmodule GroupStay.Groups.FinanceCashOpening do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.FinanceReportingStart

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_cash_openings" do
    belongs_to :reporting_start, FinanceReportingStart, type: :id
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:reporting_start_id, :property_id, :opening_held_cents])
    |> validate_required([:reporting_start_id, :property_id, :opening_held_cents])
    |> validate_length(:property_id, min: 1)
    |> validate_number(:opening_held_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:reporting_start_id, :property_id])
  end
end
