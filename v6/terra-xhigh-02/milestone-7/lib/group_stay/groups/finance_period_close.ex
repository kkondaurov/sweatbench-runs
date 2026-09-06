defmodule GroupStay.Groups.FinancePeriodClose do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_period_closes" do
    field :period_end_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(close, attrs) do
    close
    |> cast(attrs, [:period_end_on])
    |> validate_required([:period_end_on])
    |> unique_constraint(:period_end_on)
  end
end
