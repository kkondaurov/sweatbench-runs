defmodule GroupStay.Operations.OperationRecord do
  @moduledoc """
  The durable record of a partner operation: the operation identifier it was
  first committed under, the operation's type, its complete submitted content,
  and the result remembered for idempotent retries.

  The record is Northstar's audit record of what the gateway submitted. Its
  autoincremented id preserves the order in which records were first committed.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
