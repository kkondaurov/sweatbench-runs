defmodule GroupStay.Groups.CashPayment do
  @moduledoc """
  The recorded disposition of one durably applied cash payment.

  The six disposition fields always sum to `amount_cents`: cash is held on
  active rooms, or has been refunded, retained, converted to hotel credit,
  reduced by a provider correction, or charged back.
  """

  use Ecto.Schema

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payments" do
    field :operation_id, :string
    belongs_to :group, Group
    field :amount_cents, :integer
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :transferred, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end
