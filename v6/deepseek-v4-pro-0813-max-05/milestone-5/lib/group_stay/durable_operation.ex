defmodule GroupStay.DurableOperation do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  @moduledoc """
  The durable result of a partner operation, keyed by `operation_id`.

  Rows are the audit record of what the gateway submitted: the submitted
  type and the complete canonicalized submission are retained alongside the
  exact result returned for it. The incrementing primary key preserves the
  order in which records were first committed.
  """

  schema "durable_operations" do
    field :operation_id, :string
    field :op_type, :string
    field :payload_json, :string
    field :result_json, :string

    timestamps()
  end
end
