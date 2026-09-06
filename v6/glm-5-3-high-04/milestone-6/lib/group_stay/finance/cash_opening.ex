defmodule GroupStay.Finance.CashOpening do
  @moduledoc """
  The opening cash position of one property: the cash held by that
  property's active groups at the moment reporting started.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(opening, attrs) do
    opening
    |> Ecto.Changeset.cast(attrs, [:property_id, :opening_held_cents])
    |> Ecto.Changeset.validate_required([:property_id, :opening_held_cents])
  end
end
