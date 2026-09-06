defmodule GroupStay.Finance.Reporting do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
  end

  def changeset(reporting, attrs) do
    Ecto.Changeset.cast(reporting, attrs, [:id, :starts_on, :opening_credit_liability_cents])
    |> Ecto.Changeset.validate_required([:id, :starts_on, :opening_credit_liability_cents])
  end
end
