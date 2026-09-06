defmodule GroupStay.Reservations.FinanceReporting do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting" do
    field :starts_on, :date
    field :operation_id, :string
    field :opening_credit_liability_cents, :integer, default: 0
    field :last_closed_on, :date
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:starts_on, :operation_id, :opening_credit_liability_cents, :last_closed_on])
    |> validate_required([:starts_on, :operation_id, :opening_credit_liability_cents])
    |> unique_constraint(:operation_id)
  end
end
