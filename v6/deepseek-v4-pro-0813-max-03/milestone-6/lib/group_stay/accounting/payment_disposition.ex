defmodule GroupStay.Accounting.PaymentDisposition do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group

  schema "payment_dispositions" do
    field :payment_operation_id, :string
    field :kind, :string
    field :amount_cents, :integer

    belongs_to :group, Group
    belongs_to :lot, CreditLot

    timestamps()
  end
end
