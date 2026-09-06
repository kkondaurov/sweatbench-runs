defmodule GroupStay.Groups.CreditApplication do
  @moduledoc """
  Records which credit lots fund a group's deposit, so those amounts can be
  restored to their original lots when the group is cancelled while
  refundable, or consumed when it is not.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_applications" do
    field :amount_cents, :integer
    field :status, :string

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(application, attrs) do
    application
    |> cast(attrs, [:credit_lot_id, :group_id, :amount_cents, :status])
    |> validate_required([:credit_lot_id, :group_id, :amount_cents, :status])
    |> validate_inclusion(:status, ~w(applied restored consumed))
    |> assoc_constraint(:credit_lot)
    |> assoc_constraint(:group)
  end
end
