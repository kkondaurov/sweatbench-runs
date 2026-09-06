defmodule GroupStay.Groups.CashPaymentTransferParticipation do
  @moduledoc false

  use Ecto.Schema

  schema "cash_payment_transfer_participations" do
    field :payment_operation_id, :string

    timestamps(type: :utc_datetime)
  end
end
