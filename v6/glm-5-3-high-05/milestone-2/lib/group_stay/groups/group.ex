defmodule GroupStay.Groups.Group do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :arrival_on, :date
    field :departure_on, :date
    field :booked_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1

    has_many :rooms, GroupStay.Groups.Room
    has_many :ledger_entries, GroupStay.Ledger.Entry

    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> Ecto.Changeset.cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :arrival_on,
      :departure_on,
      :booked_on,
      :rate_plan,
      :policy_version,
      :status,
      :revision
    ])
    |> Ecto.Changeset.unique_constraint(:group_id)
  end
end
