defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting" do
    field :singleton, :boolean, default: true
    field :starts_on, :date
    field :closed_through, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:singleton, :starts_on, :closed_through])
    |> validate_required([:singleton, :starts_on])
    |> unique_constraint(:singleton)
  end
end
