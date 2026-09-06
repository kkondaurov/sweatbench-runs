defmodule GroupStay.Finance.CreditLot do
  @moduledoc """
  A lot of hotel credit issued for one settlement, available through its
  expiry date.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    timestamps(type: :utc_datetime)
  end
end
