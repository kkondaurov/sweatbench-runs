defmodule GroupStay.Operations.Record do
  @moduledoc """
  The durable record of an operation received from the partner gateway.

  Its integer primary key is assigned by the database in commit order, so the
  table preserves the order in which durable records were first committed.
  """
  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :string
    field :result, :string

    timestamps()
  end
end
