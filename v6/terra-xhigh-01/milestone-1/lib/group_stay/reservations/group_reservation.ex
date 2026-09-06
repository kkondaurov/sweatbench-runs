defmodule GroupStay.Reservations.GroupReservation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.GroupRoom

  schema "group_reservations" do
    field :partner_group_id, :string
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
    field :outstanding_deposit_cents, :integer
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, GroupRoom

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :partner_group_id,
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
      :outstanding_deposit_cents,
      :cash_refunded_cents,
      :cash_retained_cents,
      :revision
    ])
    |> unique_constraint(:partner_group_id)
  end
end
