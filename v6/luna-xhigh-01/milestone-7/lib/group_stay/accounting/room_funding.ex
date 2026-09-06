defmodule GroupStay.Accounting.RoomFunding do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "room_funding_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :funding_type, :string
    field :source_type, :string
    field :source_id, :string
    field :credit_application_id, :integer
    field :amount_cents, :integer
  end

  def changeset(allocation, attrs) do
    Ecto.Changeset.cast(allocation, attrs, [
      :group_id,
      :room_id,
      :funding_type,
      :source_type,
      :source_id,
      :credit_application_id,
      :amount_cents
    ])
    |> Ecto.Changeset.validate_required([
      :group_id,
      :room_id,
      :funding_type,
      :source_type,
      :amount_cents
    ])
  end
end
