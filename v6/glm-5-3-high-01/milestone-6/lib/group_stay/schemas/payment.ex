defmodule GroupStay.Schemas.Payment do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payments" do
    field :operation_id, :string
    belongs_to :group, GroupStay.Schemas.Group
    field :recorded_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
    field :transferred, :boolean

    timestamps()
  end
end
