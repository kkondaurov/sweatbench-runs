defmodule GroupStay.Operation do
  @moduledoc "Durable submissions and results, ordered by first commit using the primary key."
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
