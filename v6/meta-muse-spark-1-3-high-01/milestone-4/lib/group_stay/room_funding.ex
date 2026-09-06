defmodule GroupStay.RoomFunding do
  use Ecto.Schema
  import Ecto.Changeset

  schema "room_fundings" do
    belongs_to :group, GroupStay.Group, foreign_key: :group_db_id, define_field: false
    belongs_to :room, GroupStay.Room, foreign_key: :room_db_id, define_field: false

    field :group_db_id, :integer
    field :room_db_id, :integer
    field :kind, :string
    field :source_operation_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
    field :seq, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, [
      :group_db_id,
      :room_db_id,
      :kind,
      :source_operation_id,
      :credit_lot_id,
      :amount_cents,
      :seq
    ])
    |> validate_required([:group_db_id, :room_db_id, :kind, :amount_cents, :seq])
  end
end
