defmodule GroupStay.Operations.Operation do
  @moduledoc false

  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :content, :string
    field :result, :string

    timestamps()
  end
end
