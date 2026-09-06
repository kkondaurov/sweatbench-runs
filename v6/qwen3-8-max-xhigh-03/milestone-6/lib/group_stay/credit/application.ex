defmodule GroupStay.Credit.Application do
  @moduledoc """
  One portion of a credit lot applied to a group's deposit, as recorded
  before room accounting. New credit applications are carried as room
  allocations; these rows survive from earlier releases and preserve the
  original consumption order that the room-accounting backfill carries
  forward.
  """

  use Ecto.Schema

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :lot, GroupStay.Credit.Lot, foreign_key: :lot_id

    timestamps(type: :utc_datetime)
  end
end
