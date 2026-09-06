defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation together with the deposit tracked against it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Room

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :revision, :integer, default: 1
    field :policy_version, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, Room
    has_many :credit_applications, GroupStay.Groups.RoomCreditApplication

    timestamps(type: :utc_datetime)
  end

  def open_changeset(group, attrs, rooms) do
    group
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :rate_plan,
      :policy_version,
      :status,
      :booked_on,
      :arrival_on,
      :departure_on,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :refunded_cents,
      :retained_cents
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :rate_plan,
      :status,
      :booked_on,
      :arrival_on,
      :departure_on,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> unique_constraint(:group_id)
    |> put_assoc(:rooms, rooms)
  end

  def update_changeset(group, attrs) do
    cast(group, attrs, [
      :status,
      :arrival_on,
      :departure_on,
      :revision,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_to_credit_cents
    ])
  end
end
