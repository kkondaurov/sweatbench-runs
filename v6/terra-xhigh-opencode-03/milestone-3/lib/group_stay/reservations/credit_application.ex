defmodule GroupStay.Reservations.CreditApplication do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, Group, foreign_key: :group_db_id
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(credit_application, attrs) do
    credit_application
    |> cast(attrs, [:group_db_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_db_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
