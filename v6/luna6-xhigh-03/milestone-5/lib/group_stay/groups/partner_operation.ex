defmodule GroupStay.Groups.PartnerOperation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "partner_operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :submitted_content, :map
    field :result, :map
    field :transferred_funding, :boolean, default: false
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :operation_id,
      :operation_type,
      :submitted_content,
      :result,
      :transferred_funding
    ])
    |> validate_required([:operation_id, :submitted_content, :result])
    |> unique_constraint(:operation_id)
  end
end
