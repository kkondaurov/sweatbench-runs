defmodule GroupStay.Groups.Group do
  @moduledoc """
  A partner-managed group reservation holding rooms and deposit totals.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Payment
  alias GroupStay.Groups.Room

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer

    has_many :rooms, Room
    has_many :payments, Payment
    has_many :credit_applications, GroupStay.Credit.Application

    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> unique_constraint(:group_id)
  end
end
