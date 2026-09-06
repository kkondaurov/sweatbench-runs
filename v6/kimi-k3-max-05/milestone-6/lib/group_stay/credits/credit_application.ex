defmodule GroupStay.Credits.CreditApplication do
  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer
    # Shared allocation sequence with cash, ordering transfers.
    field :allocation_seq, :integer

    belongs_to :credit_lot, GroupStay.Credits.CreditLot
    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room

    timestamps(type: :utc_datetime)
  end
end
