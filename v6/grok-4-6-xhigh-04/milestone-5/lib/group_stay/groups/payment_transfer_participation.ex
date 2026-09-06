defmodule GroupStay.Groups.PaymentTransferParticipation do
  use Ecto.Schema

  @primary_key {:payment_operation_id, :string, autogenerate: false}

  schema "payment_transfer_participations" do
  end
end
