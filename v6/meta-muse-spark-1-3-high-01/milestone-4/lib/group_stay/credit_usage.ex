defmodule GroupStay.CreditUsage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_usages" do
    field :amount_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot, foreign_key: :credit_lot_id
    belongs_to :group, GroupStay.Group, foreign_key: :group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(usage, attrs) do
    usage
    |> cast(attrs, [:credit_lot_id, :group_db_id, :amount_cents])
    |> validate_required([:credit_lot_id, :group_db_id, :amount_cents])
  end
end
