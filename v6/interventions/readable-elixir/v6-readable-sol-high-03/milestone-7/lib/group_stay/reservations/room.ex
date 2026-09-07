defmodule GroupStay.Reservations.Room do
  @moduledoc """
  One room in a group and the deposit funding currently assigned to it.

  Cancelled rooms retain their original price and position for the historical
  group view, while their active due and paid amounts no longer contribute to
  group totals.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attributes) do
    room
    |> cast(attributes, [
      :group_id,
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
      :group_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> unique_constraint([:group_id, :room_id])
    |> unique_constraint([:group_id, :position])
  end

  def accounting_changeset(room, attributes) do
    room
    |> cast(attributes, [:status, :cash_paid_cents, :credit_paid_cents])
    |> validate_inclusion(:status, ~w(active cancelled))
    |> validate_number(:cash_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:credit_paid_cents, greater_than_or_equal_to: 0)
  end
end
