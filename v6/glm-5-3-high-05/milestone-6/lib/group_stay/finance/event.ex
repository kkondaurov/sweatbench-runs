defmodule GroupStay.Finance.Event do
  @moduledoc """
  One posted finance movement.

  Movements exist only for operations processed after reporting started.
  Each row records the reporting posting date (the later of the operation's
  `occurred_on` and `starts_on`), the property whose cash moved (`nil` for
  the company-wide credit movements), the movement classification, and a
  signed net amount within that classification.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_events" do
    field :posting_on, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer

    timestamps()
  end

  @cash_kinds ~w(
    received
    transferred_in
    transferred_out
    refunded
    retained
    converted_to_credit
    reduced
    charged_back
  )

  @credit_kinds ~w(
    credit_issued
    credit_expired
    credit_consumed
    credit_revoked
    credit_absorbed
  )

  @kinds @cash_kinds ++ @credit_kinds

  def changeset(event, attrs) do
    event
    |> Ecto.Changeset.cast(attrs, [:posting_on, :property_id, :kind, :amount_cents])
    |> Ecto.Changeset.validate_required([:posting_on, :kind, :amount_cents])
    |> Ecto.Changeset.validate_inclusion(:kind, @kinds)
  end
end
