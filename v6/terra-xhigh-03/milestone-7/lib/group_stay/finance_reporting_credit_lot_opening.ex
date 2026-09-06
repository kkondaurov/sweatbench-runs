defmodule GroupStay.FinanceReportingCreditLotOpening do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_credit_lot_openings" do
    field :opening_available_cents, :integer
    field :expires_on, :date

    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:credit_lot_id, :opening_available_cents, :expires_on])
    |> validate_required([:credit_lot_id, :opening_available_cents, :expires_on])
    |> unique_constraint(:credit_lot_id)
  end
end
