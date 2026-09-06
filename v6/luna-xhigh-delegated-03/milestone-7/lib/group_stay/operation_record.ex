defmodule GroupStay.OperationRecord do
  use Ecto.Schema

  @moduledoc """
  Durable idempotency and audit record for a partner operation.

  The database id is also the order in which records were committed. Records
  are only inserted from the same transaction that processes the operation.
  """

  @primary_key {:id, :id, autogenerate: true}
  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string
  end
end
