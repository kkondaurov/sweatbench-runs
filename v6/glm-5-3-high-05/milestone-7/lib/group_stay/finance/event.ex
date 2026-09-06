defmodule GroupStay.Finance.Event do
  @moduledoc """
  One posted finance movement.

  Movements exist only for operations processed after reporting started.
  Each row records the reporting posting date (the later of the operation's
  `occurred_on`, `starts_on`, and the day after the latest close at the
  moment the operation committed), the property whose cash moved (`nil` for
  the company-wide credit movements), the movement classification, and a
  signed net amount within that classification.

  A movement is `late` when a close moved its posting date forward: its
  finance effect belonged to the closed period, so the movement reports as a
  late adjustment on the first open day instead of an ordinary movement.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_events" do
    field :posting_on, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :late, :boolean, default: false

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
    |> Ecto.Changeset.cast(attrs, [:posting_on, :property_id, :kind, :amount_cents, :late])
    |> Ecto.Changeset.validate_required([:posting_on, :kind, :amount_cents])
    |> Ecto.Changeset.validate_inclusion(:kind, @kinds)
  end
end
