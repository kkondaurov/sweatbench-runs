defmodule GroupStay.Groups.CreditApplication do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_applications" do
    belongs_to :group, Group, foreign_key: :reservation_id, type: :binary_id
    belongs_to :credit_lot, CreditLot, type: :binary_id
    field :amount_cents, :integer
    field :source_operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:reservation_id, :credit_lot_id, :amount_cents, :source_operation_id])
    |> validate_required([:reservation_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
