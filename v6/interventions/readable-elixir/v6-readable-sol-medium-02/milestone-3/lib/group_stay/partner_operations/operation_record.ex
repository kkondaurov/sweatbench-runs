defmodule GroupStay.PartnerOperations.OperationRecord do
  @moduledoc """
  The durable idempotency and audit record for a partner operation.

  The generated integer identifier captures first-commit order. The full JSON submission is kept
  for conflict detection and audit, while API reads deliberately expose only `result`.
  """

  use Ecto.Schema

  schema "partner_operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
