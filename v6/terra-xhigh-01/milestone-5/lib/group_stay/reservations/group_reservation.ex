defmodule GroupStay.Reservations.GroupReservation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.{GroupCreditPayment, GroupRoom}

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
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :policy_version, :string
    field :revision, :integer, default: 1

    has_many :rooms, GroupRoom
    has_many :credit_payments, GroupCreditPayment

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
      :cash_converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents,
      :credit_paid_cents,
      :policy_version,
      :revision
    ])
    |> unique_constraint(:partner_group_id)
  end
end
