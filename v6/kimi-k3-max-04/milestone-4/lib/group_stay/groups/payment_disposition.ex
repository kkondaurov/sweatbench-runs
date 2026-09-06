defmodule GroupStay.Groups.PaymentDisposition do
  @moduledoc """
  The current disposition of cash from one durably recorded, applied cash
  payment. Each bucket is integer cents that moved out of the held state:

  - `refunded_cents` / `retained_cents`: settled by a refundable or
    non-refundable cancellation;
  - `converted_cents`: settled into a hotel-credit lot;
  - `reduced_cents`: corrected by the payment provider;
  - `charged_back_cents`: reversed by a chargeback.

  The held remainder lives in `cash_allocations` rows for the same
  `operation_id`. The buckets plus the held cash always sum to the payment's
  recorded amount.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "payment_dispositions" do
    field :operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    timestamps()
  end
end
