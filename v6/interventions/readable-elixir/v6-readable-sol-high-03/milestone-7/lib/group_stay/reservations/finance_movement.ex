defmodule GroupStay.Reservations.FinanceMovement do
  @moduledoc """
  One classified cash or credit movement caused by an applied operation.

  Cash rows retain their funding source even before reporting begins. That
  provenance lets a later chargeback reverse a refund, retention, or credit
  conversion at the property where the cash was actually settled. The late
  flag distinguishes effects moved into the open period by a finance close.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.CashFunding

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_date, :date
    field :account, :string
    field :classification, :string
    field :property_id, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
    belongs_to :cash_funding, CashFunding

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(movement, attributes) do
    movement
    |> cast(attributes, [
      :operation_id,
      :posting_date,
      :account,
      :classification,
      :property_id,
      :cash_funding_id,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_required([
      :operation_id,
      :account,
      :classification,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_inclusion(:account, ~w(cash credit))
    |> validate_number(:amount_cents, not_equal_to: 0)
  end
end
