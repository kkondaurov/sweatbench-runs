defmodule GroupStay.Credits.CreditApplication do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot
  alias GroupStay.Groups.Group

  schema "credit_applications" do
    belongs_to :group, Group
    belongs_to :credit_lot, CreditLot
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
