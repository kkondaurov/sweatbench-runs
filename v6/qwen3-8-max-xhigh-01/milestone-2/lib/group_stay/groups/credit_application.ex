defmodule GroupStay.Groups.CreditApplication do
  @moduledoc """
  Records which credit lots funded a group, so the amounts can be restored to
  their original lots and expiry if the group is cancelled while refundable.

  The state is `"applied"` while the credit funds an active group,
  `"restored"` when a refundable cancellation returned it to its lot, and
  `"consumed"` when a non-refundable cancellation forfeited it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :amount_cents, :integer
    field :occurred_on, :date
    field :state, :string, default: "applied"

    belongs_to :group, Group
    belongs_to :lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = application, attrs) do
    application
    |> cast(attrs, [:group_id, :lot_id, :amount_cents, :occurred_on, :state])
    |> validate_required([:group_id, :lot_id, :amount_cents, :occurred_on, :state])
  end
end
