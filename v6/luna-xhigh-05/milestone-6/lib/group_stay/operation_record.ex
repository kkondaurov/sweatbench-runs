defmodule GroupStay.OperationRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload_json, :string
    field :result_json, :string
  end

  def changeset(record, attrs) do
    cast(record, attrs, [:operation_id, :operation_type, :payload_json, :result_json])
  end
end
