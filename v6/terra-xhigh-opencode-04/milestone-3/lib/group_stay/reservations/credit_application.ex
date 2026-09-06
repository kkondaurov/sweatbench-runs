defmodule GroupStay.Reservations.CreditApplication do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Reservations.Group
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
  end
end
