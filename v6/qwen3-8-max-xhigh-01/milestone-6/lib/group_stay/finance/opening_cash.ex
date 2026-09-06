defmodule GroupStay.Finance.OpeningCash do
  @moduledoc """
  The held cash of the opening position for one property, captured immediately
  before the finance-reporting start operation was processed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_opening_cash" do
    field :property_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :amount_cents])
    |> validate_required([:property_id, :amount_cents])
  end
end
