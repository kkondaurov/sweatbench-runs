defmodule GroupStay.PartnerOperation do
  @moduledoc """
  The durable idempotency and audit record for one partner operation.

  The generated integer primary key records first-commit order. Records are append-only in the
  application; an operation identifier and its original submission/result are never replaced.
  """

  use Ecto.Schema

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_payload, :map
    field :result, :map

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
