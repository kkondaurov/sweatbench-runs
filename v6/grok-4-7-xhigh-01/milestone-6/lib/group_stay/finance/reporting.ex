defmodule GroupStay.Finance.Reporting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting" do
    field :singleton, :integer, default: 1
    field :operation_id, :string
    field :starts_on, :date
    field :opening_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:singleton, :operation_id, :starts_on, :opening_liability_cents])
    |> validate_required([:singleton, :operation_id, :starts_on, :opening_liability_cents])
    |> unique_constraint(:singleton)
  end
end
