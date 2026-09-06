defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation and its deposit accounting record.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditApplication, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
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
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0

    has_many :rooms, Room, preload_order: [asc: :position]
    has_many :credit_applications, CreditApplication

    timestamps(type: :utc_datetime)
  end

  @fields [
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
    :deposit_due_cents,
    :deposit_paid_cents,
    :cash_paid_cents,
    :credit_paid_cents,
    :refunded_cents,
    :retained_cents,
    :cash_converted_cents,
    :cash_reduced_cents,
    :cash_charged_back_cents
  ]

  @doc false
  def changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required([
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
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> unique_constraint(:group_id)
    |> cast_assoc(:rooms, with: &Room.changeset/2)
  end
end
