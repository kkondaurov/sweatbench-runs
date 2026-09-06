defmodule GroupStay.Deposits.Room do
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(active cancelled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_rooms" do
    belongs_to :group, GroupStay.Deposits.Group
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_amount_cents, :integer
    field :deposit_due_cents, :integer
    field :status, :string, default: "active"

    field :cash_paid_cents, :integer, virtual: true, default: 0
    field :credit_paid_cents, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :position,
      :room_id,
      :nightly_rate_cents,
      :lodging_amount_cents,
      :deposit_due_cents,
      :status
    ])
    |> validate_required([:position, :room_id, :nightly_rate_cents])
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:group_id, :position])
  end

  def update_changeset(room, attrs) do
    room
    |> cast(attrs, [:status])
    |> validate_inclusion(:status, @statuses)
  end
end
