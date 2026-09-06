defmodule GroupStay.Groups.PaymentRecord do
  @moduledoc """
  The current disposition of cash from one durably recorded, applied cash
  payment.

  `amount_cents` is the recorded amount and never changes. The disposition
  fields are cumulative and, together with the cash still held on active
  rooms, sum exactly to `amount_cents`.

  `participated_in_transfer` turns true once any funding of the payment has
  moved between groups through a deposit transfer; from then on its
  statement carries `held_by_group`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payment_records" do
    field :operation_id, :string
    field :amount_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :participated_in_transfer, :boolean, default: false

    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :operation_id,
      :group_id,
      :amount_cents,
      :refunded_cents,
      :retained_cents,
      :converted_cents,
      :reduced_cents,
      :charged_back_cents,
      :participated_in_transfer
    ])
    |> validate_required([:operation_id, :group_id, :amount_cents])
    |> unique_constraint(:operation_id)
  end
end
