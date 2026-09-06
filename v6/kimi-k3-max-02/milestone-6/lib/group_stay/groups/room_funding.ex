defmodule GroupStay.Groups.RoomFunding do
  @moduledoc """
  Allocates cash or hotel credit to one room's deposit. Funding fills active
  rooms in their original order, filling one room's deposit before moving to
  the next.

  A `"held"` allocation currently funds its room's deposit; a `"settled"`
  allocation was settled with its room (refunded, retained, converted, or
  consumed) and remains only as history. Reductions and chargebacks remove
  held allocations instead of settling them, so their amounts stay visible in
  the funding's disposition columns.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashFunding, CreditApplication, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "room_fundings" do
    field :kind, :string
    field :status, :string, default: "held"
    field :amount_cents, :integer

    belongs_to :room, Room, type: :binary_id
    belongs_to :cash_funding, CashFunding, type: :id
    belongs_to :credit_application, CreditApplication, type: :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(room_funding, attrs) do
    room_funding
    |> cast(attrs, [
      :room_id,
      :kind,
      :status,
      :amount_cents,
      :cash_funding_id,
      :credit_application_id
    ])
    |> validate_required([:room_id, :kind, :status, :amount_cents])
    |> validate_inclusion(:kind, ~w(cash credit))
    |> validate_inclusion(:status, ~w(held settled))
    |> validate_source()
    |> assoc_constraint(:room)
    |> assoc_constraint(:cash_funding)
    |> assoc_constraint(:credit_application)
  end

  # Exactly one funding source per allocation: a cash funding for cash, a
  # credit application for hotel credit.
  defp validate_source(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :cash_funding_id),
          get_field(changeset, :credit_application_id)} do
      {"cash", cash_funding_id, nil} when not is_nil(cash_funding_id) -> changeset
      {"credit", nil, application_id} when not is_nil(application_id) -> changeset
      _other -> add_error(changeset, :kind, "must reference exactly one funding source")
    end
  end
end
