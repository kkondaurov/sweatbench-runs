defmodule GroupStay.Credit.Application do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "hotel_credit_applications" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end

  def changeset(application, attrs) do
    Ecto.Changeset.cast(application, attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> Ecto.Changeset.validate_required([:group_id, :credit_lot_id, :amount_cents])
  end
end
