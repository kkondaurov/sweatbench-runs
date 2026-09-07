defmodule GroupStay.Deposits.CreditAllocation do
  @moduledoc "Tracks the credit lots currently funding an active group deposit."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.{CreditLot, Group}

  schema "credit_allocations" do
    belongs_to :group, Group, foreign_key: :group_record_id
    belongs_to :credit_lot, CreditLot
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_record_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_record_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
    |> unique_constraint([:group_record_id, :credit_lot_id])
  end
end
