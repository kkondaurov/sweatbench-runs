defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation: the rooms held for one stay and the deposit owed for them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, GroupStay.Groups.Room

    timestamps(type: :utc_datetime)
  end

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan
             status lodging_total_cents deposit_due_cents deposit_paid_cents
             cash_paid_cents credit_paid_cents revision)a

  def changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:group_id)
  end
end
