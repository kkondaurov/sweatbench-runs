defmodule GroupStay.Groups.Payment do
  @moduledoc """
  Cash recorded against a group deposit.

  A payment records the accounting fact reported by the payment provider.
  Its current disposition — how much is held on active rooms and how much
  was refunded, retained, converted to hotel credit, reduced, or charged
  back — lives on the room allocations that carry its cash, and is reported
  per payment by the reconciliation endpoint.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Group

  schema "payments" do
    belongs_to :group, Group
    field :operation_id, :string
    field :amount_cents, :integer
    field :recorded_on, :date

    timestamps()
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:group_id, :operation_id, :amount_cents, :recorded_on])
    |> validate_required([:group_id, :amount_cents, :recorded_on])
    |> unique_constraint(:operation_id)
    |> foreign_key_constraint(:group_id)
  end
end
