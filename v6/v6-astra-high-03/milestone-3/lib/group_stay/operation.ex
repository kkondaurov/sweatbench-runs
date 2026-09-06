defmodule GroupStay.Operation do
  @moduledoc "Durable partner submission (including its type) and original JSON result, ordered by id."
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :submission, :map
    field :result, :map
  end
end
