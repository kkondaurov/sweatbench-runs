defmodule GroupStay.Group do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:group_id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer

    has_many :rooms, GroupStay.Room,
      foreign_key: :group_id,
      references: :group_id,
      on_delete: :delete_all
  end

  def changeset(group, attrs) do
    cast(group, attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :refunded_cents,
      :retained_cents
    ])
  end
end
