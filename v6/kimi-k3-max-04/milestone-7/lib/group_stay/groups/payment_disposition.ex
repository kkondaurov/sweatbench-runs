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

  `transferred` flags that some of the payment's cash moved through a
  deposit transfer; the payment statement then adds `held_by_group`.
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
    field :transferred, :boolean, default: false

    # Property attribution of the settled buckets, so a chargeback
    # reclassifies refunded/retained/converted cash at the property where it
    # was settled. Map of bucket name ("refunded"/"retained"/"converted") to
    # a property-to-cents map.
    field :settled_locations, :map, default: %{}

    timestamps()
  end
end
