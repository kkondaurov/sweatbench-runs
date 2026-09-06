defmodule GroupStay.Finance.OpeningCash do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_reporting_opening_cash" do
    field :property_id, :string
    field :held_cents, :integer
  end

  def changeset(opening_cash, attrs) do
    Ecto.Changeset.cast(opening_cash, attrs, [:property_id, :held_cents])
    |> Ecto.Changeset.validate_required([:property_id, :held_cents])
  end
end
