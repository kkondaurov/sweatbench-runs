defmodule GroupStay.Deposits.FinanceOpening do
  @moduledoc """
  The cash held per property at the moment finance reporting started.

  Together with every `GroupStay.Deposits.FinanceEvent` posted since
  `starts_on`, these snapshots reconstruct each property's opening held cash
  for any reportable date.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :opening_held_cents])
    |> validate_required([:property_id, :opening_held_cents])
    |> unique_constraint(:property_id)
  end
end
