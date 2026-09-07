defmodule GroupStay.Deposits.PartnerOperation do
  @moduledoc """
  The durable receipt for one partner operation.

  The monotonically increasing primary key records first-commit order. The
  complete submission is retained for audit and payload comparison, while the
  stored result makes retries independent of the current deposit state.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:operation_id, :operation_type, :submission, :result])
    |> validate_required([:operation_id, :submission, :result])
    |> unique_constraint(:operation_id)
  end
end
