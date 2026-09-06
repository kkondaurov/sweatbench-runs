defmodule GroupStay.Groups.FinanceCreditLotOpening do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditLot, FinanceReportingStart}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_credit_lot_openings" do
    belongs_to :reporting_start, FinanceReportingStart, type: :id
    belongs_to :credit_lot, CreditLot
    field :opening_available_cents, :integer
    field :expires_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:reporting_start_id, :credit_lot_id, :opening_available_cents, :expires_on])
    |> validate_required([
      :reporting_start_id,
      :credit_lot_id,
      :opening_available_cents,
      :expires_on
    ])
    |> validate_number(:opening_available_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:reporting_start_id, :credit_lot_id])
  end
end
