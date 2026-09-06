defmodule GroupStay.Finance.PeriodClose do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_period_closes" do
    field :operation_id, :string
    field :period_end_on, :date
  end

  def changeset(close, attrs) do
    Ecto.Changeset.cast(close, attrs, [:operation_id, :period_end_on])
    |> Ecto.Changeset.validate_required([:operation_id, :period_end_on])
  end
end
