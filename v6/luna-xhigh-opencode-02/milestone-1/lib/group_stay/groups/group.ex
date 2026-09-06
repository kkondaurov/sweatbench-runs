defmodule GroupStay.Groups.Group do
  use Ecto.Schema

  @fields [
    :group_id,
    :guest_id,
    :property_id,
    :booked_on,
    :arrival_on,
    :departure_on,
    :rate_plan,
    :status,
    :lodging_total_cents,
    :deposit_due_cents,
    :deposit_paid_cents,
    :cash_refunded_cents,
    :cash_retained_cents,
    :revision
  ]

  @primary_key {:group_id, :string, autogenerate: false}
  @foreign_key_type :string

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
    field :deposit_paid_cents, :integer
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
    field :revision, :integer
  end

  def changeset(group, attrs) do
    group
    |> Ecto.Changeset.cast(attrs, @fields)
    |> Ecto.Changeset.validate_required(@fields)
  end
end
