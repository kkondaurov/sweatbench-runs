defmodule GroupStay.Groups.RoomCreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditApplication, Room}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "room_credit_allocations" do
    belongs_to :room, Room, type: :binary_id
    belongs_to :credit_application, CreditApplication, type: :binary_id
    field :amount_cents, :integer
    field :allocation_sequence, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :credit_application_id, :amount_cents, :allocation_sequence])
    |> validate_required([:room_id, :credit_application_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
