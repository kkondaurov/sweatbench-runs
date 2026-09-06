defmodule GroupStay.Credits.Application do
  @moduledoc """
  The amount of a credit lot currently funding a group's deposit. The record
  preserves which lots funded a group so the amounts can be restored to
  their original lots if the group is later cancelled while refundable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credits.Lot
  alias GroupStay.Groups.Group

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :credit_lot, Lot
    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:credit_lot_id, :group_id, :amount_cents])
    |> validate_required([:credit_lot_id, :group_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
    |> assoc_constraint(:credit_lot)
    |> assoc_constraint(:group)
  end
end
