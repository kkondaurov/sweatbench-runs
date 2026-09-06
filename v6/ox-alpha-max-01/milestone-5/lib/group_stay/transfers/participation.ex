defmodule GroupStay.Transfers.Participation do
  @moduledoc """
  The durable marker that a cash payment once had held funding moved by a
  deposit transfer.

  Transfers change no ledger total, so this row is the only evidence that a
  payment's remaining held cash may span several groups; a payment marked
  here reports `held_by_group` in its statement forever, ordered by group
  id, empty once nothing is held. The unique index keeps concurrent
  transfers of the same payment at most-once per marker.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "transfer_participations" do
    field :operation_id, :string

    timestamps()
  end

  def changeset(participation, attrs) do
    participation
    |> cast(attrs, [:operation_id])
    |> validate_required([:operation_id])
    |> unique_constraint(:operation_id)
  end
end
