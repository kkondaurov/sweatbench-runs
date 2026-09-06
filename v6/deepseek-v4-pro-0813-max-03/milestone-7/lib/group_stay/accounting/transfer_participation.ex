defmodule GroupStay.Accounting.TransferParticipation do
  @moduledoc false

  use Ecto.Schema

  schema "transfer_participations" do
    field :payment_operation_id, :string

    timestamps()
  end
end
