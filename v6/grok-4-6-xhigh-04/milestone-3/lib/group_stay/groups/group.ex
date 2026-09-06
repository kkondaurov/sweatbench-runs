defmodule GroupStay.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

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
    field :status, :string
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :policy_version, :string

    embeds_many :rooms, GroupStay.Groups.Group.Room, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
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
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :cash_converted_to_credit_cents,
      :refunded_cents,
      :retained_cents,
      :policy_version
    ])
    |> cast_embed(:rooms, required: true)
    |> unique_constraint(:group_id)
  end
end

defmodule GroupStay.Groups.Group.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:room_id, :nightly_rate_cents])
    |> validate_required([:room_id, :nightly_rate_cents])
  end
end
