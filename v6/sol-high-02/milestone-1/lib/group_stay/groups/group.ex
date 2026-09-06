defmodule GroupStay.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:group_id, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :group_id}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :revision, :integer, default: 1
  end

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status
             lodging_total_cents deposit_due_cents deposit_paid_cents revision)a

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:group_id)
  end
end
