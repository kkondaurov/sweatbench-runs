defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation: the stay, its rooms, and the deposit position.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashPayment, Room}

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
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :outstanding_deposit_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0

    has_many :rooms, Room
    has_many :cash_payments, CashPayment

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = group, attrs) do
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
      :revision,
      :deposit_due_cents,
      :deposit_paid_cents,
      :outstanding_deposit_cents,
      :refunded_cents,
      :retained_cents
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
      :deposit_due_cents,
      :deposit_paid_cents,
      :outstanding_deposit_cents,
      :refunded_cents,
      :retained_cents
    ])
    |> unique_constraint(:group_id)
  end
end
