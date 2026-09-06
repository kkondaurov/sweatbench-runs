defmodule GroupStay.Groups.OperationRecord do
  @moduledoc """
  The durable record that makes a partner operation idempotent.

  One row per `operation_id`, holding the canonical submitted content and the
  exact result returned on the first attempt. Applied and rejected operations
  are both remembered; domain changes and the record commit together.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
