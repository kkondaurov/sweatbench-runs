defmodule GroupStay.RoomAccounting.TransferParticipation do
  @moduledoc """
  Marks a durably recorded cash payment whose funding has participated in at
  least one `transfer_deposit` operation.

  Once marked, the payment's reconciliation statement exposes `held_by_group`
  even when nothing is currently held.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transfer_participations" do
    field :payment_operation_id, :string

    timestamps()
  end
end
