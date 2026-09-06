defmodule GroupStay.Groups.FinanceClose do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_closes" do
    field :reporting_id, :integer
    field :operation_id, :string
    field :period_end_on, :date
  end

  def changeset(close, attrs) do
    cast(close, attrs, [:reporting_id, :operation_id, :period_end_on])
  end
end
