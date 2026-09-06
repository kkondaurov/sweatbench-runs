defmodule GroupStay.FinancePeriodClose do
  @moduledoc "A durable successful finance period close."

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date
    field :commit_sequence, :integer
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:operation_id, :period_end_on, :commit_sequence])
    |> validate_required([:operation_id, :period_end_on, :commit_sequence])
    |> unique_constraint(:period_end_on)
  end
end
