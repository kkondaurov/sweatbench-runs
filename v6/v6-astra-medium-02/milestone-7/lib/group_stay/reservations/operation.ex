defmodule GroupStay.Reservations.Operation do
  @moduledoc "Durable partner submission and result; id orders first commits."
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end
end
