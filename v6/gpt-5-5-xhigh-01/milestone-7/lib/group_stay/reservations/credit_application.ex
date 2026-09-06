defmodule GroupStay.Reservations.CreditApplication do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :operation_id, :string
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Reservations.Group
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(credit_application, attrs) do
    credit_application
    |> cast(attrs, [:group_id, :credit_lot_id, :operation_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :operation_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
