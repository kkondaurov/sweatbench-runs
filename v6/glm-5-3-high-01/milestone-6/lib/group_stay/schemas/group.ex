defmodule GroupStay.Schemas.Group do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :arrival_on, :date
    field :departure_on, :date
    field :booked_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :cash_reduced_cents, :integer
    field :cash_charged_back_cents, :integer

    has_many :rooms, GroupStay.Schemas.Room

    timestamps()
  end
end
