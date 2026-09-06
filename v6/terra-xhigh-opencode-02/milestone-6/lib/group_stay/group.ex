defmodule GroupStay.Group do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.{CashPaymentDisposition, CreditApplication, Room}

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0
    field :policy_version, :string
    field :revision, :integer, default: 1

    has_many :rooms, Room
    has_many :credit_applications, CreditApplication
    has_many :cash_payment_dispositions, CashPaymentDisposition
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
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :cash_refunded_cents,
      :cash_retained_cents,
      :cash_converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents,
      :policy_version,
      :revision
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
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :cash_refunded_cents,
      :cash_retained_cents,
      :cash_converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents,
      :policy_version,
      :revision
    ])
    |> validate_inclusion(:rate_plan, ["flexible", "advance_purchase"])
    |> validate_inclusion(:status, ["active", "cancelled"])
    |> validate_inclusion(:policy_version, ["flex-14", "flex-30", "advance-nonrefundable"])
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:credit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_reduced_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_charged_back_cents, greater_than_or_equal_to: 0)
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint(:group_id)
  end
end
