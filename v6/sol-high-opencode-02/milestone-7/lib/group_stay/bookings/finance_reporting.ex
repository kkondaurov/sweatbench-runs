defmodule GroupStay.Bookings.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :closed_through_on, :date
    field :opening_credit_liability_cents, :integer
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:id, :starts_on, :closed_through_on, :opening_credit_liability_cents])
    |> validate_required([:id, :starts_on, :opening_credit_liability_cents])
  end
end
