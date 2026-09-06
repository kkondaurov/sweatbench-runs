defmodule GroupStay.Groups.FinanceOpeningCash do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_opening_cash" do
    field :property_id, :string
    field :held_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :held_cents])
    |> validate_required([:property_id, :held_cents])
    |> unique_constraint(:property_id)
  end
end
