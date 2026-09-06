defmodule GroupStay.Finance.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest by a cancellation.

  `remaining_cents` is the portion of the lot that is currently available.
  Amounts applied to an active group leave the remaining total and are tracked
  as credit applications until they are restored or consumed.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :original_amount_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :credit_applications, GroupStay.Finance.CreditApplication

    timestamps(type: :utc_datetime)
  end
end
