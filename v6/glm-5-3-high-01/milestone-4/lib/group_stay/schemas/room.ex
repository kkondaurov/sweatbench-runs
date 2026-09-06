defmodule GroupStay.Schemas.Room do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    belongs_to :group, GroupStay.Schemas.Group
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer

    timestamps()
  end
end
