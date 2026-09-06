defmodule GroupStay.Groups.Operation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:commit_order, :id, autogenerate: true}
  schema "operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_content, :map
    field :result, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields ~w(operation_id operation_type submitted_content result)a

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, @fields)
    |> validate_required([:operation_id, :submitted_content, :result])
    |> unique_constraint(:operation_id)
  end
end
