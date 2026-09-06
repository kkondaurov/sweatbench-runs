defmodule GroupStay.CreditApplication do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.{CreditLot, Group}

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, Group
    belongs_to :credit_lot, CreditLot
  end

  def changeset(credit_application, attrs) do
    credit_application
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
