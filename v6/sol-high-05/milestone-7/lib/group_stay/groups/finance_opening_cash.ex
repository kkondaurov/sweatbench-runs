defmodule GroupStay.Groups.FinanceOpeningCash do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:property_id, :string, autogenerate: false}
  schema "finance_opening_cash" do
    field :opening_held_cents, :integer
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :opening_held_cents])
    |> validate_required([:property_id, :opening_held_cents])
  end
end
