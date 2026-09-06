defmodule GroupStay.Bookings.Group do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Bookings.Room

  @primary_key {:group_id, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :group_id}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, Room,
      foreign_key: :group_id,
      references: :group_id
  end

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status
             lodging_total_cents deposit_due_cents deposit_paid_cents cash_refunded_cents
             cash_retained_cents revision)a

  def changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:group_id)
  end
end
