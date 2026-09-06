defmodule GroupStay.Groups.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting" do
    field :starts_on, :date
    field :start_operation_id, :string
    field :opening_credit_liability_cents, :integer
    field :opening_cash, :map, default: %{}
    field :opening_lots, {:array, :map}, default: []
    field :singleton, :integer, default: 1
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [
      :starts_on,
      :start_operation_id,
      :opening_credit_liability_cents,
      :opening_cash,
      :opening_lots,
      :singleton
    ])
    |> validate_required([
      :starts_on,
      :start_operation_id,
      :opening_credit_liability_cents,
      :opening_cash,
      :opening_lots
    ])
    |> unique_constraint(:singleton)
    |> unique_constraint(:start_operation_id)
  end
end
