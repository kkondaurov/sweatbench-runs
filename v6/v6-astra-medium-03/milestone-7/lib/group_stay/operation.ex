defmodule GroupStay.Operation do
  @moduledoc "Durable submission and result; id orders first commits under SQLite's single writer."
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end
end
