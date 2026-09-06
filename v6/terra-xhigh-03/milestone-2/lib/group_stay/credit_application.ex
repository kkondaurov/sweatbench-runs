defmodule GroupStay.CreditApplication do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_applications" do
    field :amount_cents, :integer

    belongs_to :group_reservation, GroupStay.GroupReservation
    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end

  def create_changeset(application, attrs) do
    application
    |> cast(attrs, [:group_reservation_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_reservation_id, :credit_lot_id, :amount_cents])
  end
end
