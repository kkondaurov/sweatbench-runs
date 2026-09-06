defmodule GroupStay.Credit.Application do
  @moduledoc """
  Records which credit lot funded an active group, and for how much, so the
  credit can be restored to its original lot if the group is later cancelled
  while refundable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :credit_lot, GroupStay.Credit.Lot

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:group_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
