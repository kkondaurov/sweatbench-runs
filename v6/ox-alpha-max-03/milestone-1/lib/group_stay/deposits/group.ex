defmodule GroupStay.Deposits.Group do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Deposits.Room

  @rate_plans ~w(flexible advance_purchase)
  @statuses ~w(active cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0

    has_many :rooms, Room

    timestamps(type: :utc_datetime)
  end

  def open_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
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
      :deposit_due_cents
    ])
    |> cast_assoc(:rooms, with: &Room.changeset/2, required: true)
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_inclusion(:rate_plan, @rate_plans)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:group_id)
  end

  def update_changeset(group, attrs) do
    cast(group, attrs, [:arrival_on, :departure_on, :status, :revision, :deposit_paid_cents])
  end
end
