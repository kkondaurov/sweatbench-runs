defmodule GroupStay.Groups.FinanceCreditLotChange do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_credit_lot_changes" do
    belongs_to :credit_lot, CreditLot
    field :available_delta_cents, :integer
    field :posted_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [:credit_lot_id, :available_delta_cents, :posted_on])
    |> validate_required([:credit_lot_id, :available_delta_cents, :posted_on])
    |> validate_number(:available_delta_cents, not_equal_to: 0)
  end
end
