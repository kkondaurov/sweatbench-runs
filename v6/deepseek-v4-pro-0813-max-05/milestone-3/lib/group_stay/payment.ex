defmodule GroupStay.Payment do
  use Ecto.Schema

  alias GroupStay.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payments" do
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :group, Group

    timestamps()
  end
end
