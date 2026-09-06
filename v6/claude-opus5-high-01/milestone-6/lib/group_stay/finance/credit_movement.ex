defmodule GroupStay.Finance.CreditMovement do
  @moduledoc """
  One event in the life of a hotel-credit lot, on the date it posts to.

  A lot holds credit in two places: the balance still sitting in the lot and the
  balance currently applied to an active room. `remaining_delta_cents` and
  `applied_delta_cents` record how the event moved each of them, which is what
  lets a report say what a lot was worth on a given date.

  `amount_cents` is the liability the event itself moved, and `event` says which
  report column it belongs to. Applying credit moves liability between the two
  balances rather than out of them, so it posts nothing. Expiry is never an event
  at all: a lot expires because a date passed, so a report derives it from the
  liability the other events leave unexplained.

  `opening` carries the position a lot brought into the reporting window and is
  dated the day before reporting starts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @events ~w(opening issued applied restored consumed revoked)

  # The report column each event posts its amount to.
  @columns %{
    "issued" => :issued_cents,
    "restored" => :absorbed_cents,
    "consumed" => :consumed_cents,
    "revoked" => :revoked_cents
  }

  schema "finance_credit_movements" do
    field :posting_date, :date
    field :lot_ref, :id
    field :event, :string
    field :amount_cents, :integer, default: 0
    field :remaining_delta_cents, :integer, default: 0
    field :applied_delta_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :posting_date,
    :lot_ref,
    :event,
    :amount_cents,
    :remaining_delta_cents,
    :applied_delta_cents
  ]

  @doc "The report column an event posts to, or `nil` when it moves no liability."
  def column(event), do: Map.get(@columns, event)

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:event, @events)
  end
end
