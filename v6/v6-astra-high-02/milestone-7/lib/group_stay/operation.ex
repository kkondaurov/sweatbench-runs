defmodule GroupStay.Operation do
  @moduledoc "Durable submissions and results, ordered by their first commit's id."
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end
end
