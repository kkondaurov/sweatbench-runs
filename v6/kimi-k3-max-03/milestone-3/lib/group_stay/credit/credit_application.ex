defmodule GroupStay.Credit.CreditApplication do
  @moduledoc """
  Records how much of a credit lot funds an active group, so the exact amounts
  can be restored to their original lots on a refundable cancellation. The
  application is deleted when the group is settled.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:amount_cents, :credit_lot_id, :group_id])
    |> validate_required([:amount_cents, :credit_lot_id, :group_id])
  end
end
