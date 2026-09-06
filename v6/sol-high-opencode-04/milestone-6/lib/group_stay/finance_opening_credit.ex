defmodule GroupStay.FinanceOpeningCredit do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_opening_credit" do
    field :available_cents, :integer
    field :applied_cents, :integer
    field :expires_on, GroupStay.WideDate

    belongs_to :finance_reporting, GroupStay.FinanceReporting
    belongs_to :credit_lot, GroupStay.CreditLot, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [
      :finance_reporting_id,
      :credit_lot_id,
      :available_cents,
      :applied_cents,
      :expires_on
    ])
    |> validate_required([
      :finance_reporting_id,
      :credit_lot_id,
      :available_cents,
      :applied_cents,
      :expires_on
    ])
  end
end
