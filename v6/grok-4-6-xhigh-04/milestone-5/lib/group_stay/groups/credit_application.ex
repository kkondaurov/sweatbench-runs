defmodule GroupStay.Groups.CreditApplication do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_applications" do
    field :group_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :amount_cents, :integer
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:group_id, :source_operation_id, :expires_on, :amount_cents])
    |> validate_required([:group_id, :source_operation_id, :expires_on, :amount_cents])
  end
end
