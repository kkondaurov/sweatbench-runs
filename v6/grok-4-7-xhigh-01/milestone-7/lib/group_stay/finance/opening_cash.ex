defmodule GroupStay.Finance.OpeningCash do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_opening_cash" do
    field :property_id, :string
    field :held_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :held_cents])
    |> validate_required([:property_id, :held_cents])
    |> validate_number(:held_cents, greater_than: 0)
    |> unique_constraint(:property_id)
  end
end
