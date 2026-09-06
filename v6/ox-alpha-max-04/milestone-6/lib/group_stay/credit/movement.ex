defmodule GroupStay.Credit.Movement do
  @moduledoc """
  The durable record of one credit lot's liability movement: `"applied"` when
  an operation redeemed the lot into a group's deposit, `"restored"` when a
  refundable settlement returned the credit to its lot, and `"consumed"` when
  a non-refundable settlement used it up.

  Applications are deleted once the rooms they fund settle, so the daily
  finance report replays each lot's liability timeline from these movements,
  which are written once and never removed.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_movements" do
    field :operation_id, :string
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :lot, GroupStay.Credit.Lot

    timestamps(type: :utc_datetime)
  end
end
