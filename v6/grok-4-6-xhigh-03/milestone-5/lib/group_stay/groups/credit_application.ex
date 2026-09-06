defmodule GroupStay.Groups.CreditApplication do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:amount_cents, :group_id, :credit_lot_id])
    |> validate_required([:amount_cents, :group_id, :credit_lot_id])
  end
end
