defmodule GroupStay.PaymentTransfer do
  @moduledoc "Persistent participation marker, independent of current cash disposition."
  use Ecto.Schema

  @primary_key {:payment_operation_id, :string, autogenerate: false}
  schema "payment_transfers" do
  end
end
