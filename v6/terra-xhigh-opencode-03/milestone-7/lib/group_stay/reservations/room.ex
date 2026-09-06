defmodule GroupStay.Reservations.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Reservations.Group, foreign_key: :group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_db_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([
      :group_db_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_number(:nightly_rate_cents, greater_than_or_equal_to: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:credit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, ["active", "cancelled"])
    |> unique_constraint([:group_db_id, :room_id])
  end
end
