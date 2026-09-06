defmodule GroupStay.Ledger.Entry do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ledger_entries" do
    field :kind, :string
    field :amount_cents, :integer
    field :occurred_on, :date
    field :operation_key, :string
    field :payment_entry_id, :binary_id
    # True once any funding from this cash payment has participated in a
    # deposit transfer; the payment's statement then always reports
    # `held_by_group`, even after none of its cash remains held.
    field :participated_in_transfer, :boolean, default: false

    belongs_to :group, GroupStay.Groups.Group

    timestamps()
  end

  @kinds ~w(cash_payment refund retention cash_converted_to_credit cash_reduction cash_chargeback)

  def changeset(entry, attrs) do
    entry
    |> Ecto.Changeset.cast(attrs, [
      :kind,
      :amount_cents,
      :occurred_on,
      :group_id,
      :operation_key,
      :payment_entry_id,
      :participated_in_transfer
    ])
    |> Ecto.Changeset.validate_inclusion(:kind, @kinds)
    |> Ecto.Changeset.validate_number(:amount_cents, greater_than: 0)
    |> Ecto.Changeset.assoc_constraint(:group)
  end
end
