defmodule GroupStay.Groups do
  @moduledoc """
  Reads groups and the finance ledger, and computes group money totals.

  Money amounts are integer cents. Deposit rounding is half-up to the
  nearest cent, done per room before summing the group.
  """

  alias GroupStay.{Group, Payment, Repo}

  import Ecto.Query

  @flexible "flexible"
  @kind_payment "payment"
  @kind_refund "refund"
  @kind_retained "retained"

  @doc "The number of nights of a group's stay."
  def nights(group), do: Date.diff(group.departure_on, group.arrival_on)

  @doc "A room's lodging amount for the group's stay, in cents."
  def room_lodging_cents(room, nights), do: nights * room.nightly_rate_cents

  @doc """
  A room's deposit, in cents.

  Flexible rooms deposit 20% of the room's lodging amount, rounded half-up
  to the nearest cent. Advance-purchase rooms deposit their full lodging
  amount.
  """
  def room_deposit(nightly_rate_cents, @flexible, nights),
    do: round_percent(nights * nightly_rate_cents, 20)

  def room_deposit(nightly_rate_cents, _rate_plan, nights),
    do: nights * nightly_rate_cents

  @doc "Rounds `amount_cents * percent / 100` to the nearest cent, half-up."
  def round_percent(amount_cents, percent), do: div(amount_cents * percent + 50, 100)

  @doc "The group's deposit due, in cents: the sum of its room deposits."
  def deposit_due(group, rooms) do
    nights = nights(group)

    Enum.reduce(rooms, 0, fn room, total ->
      room_deposit(room.nightly_rate_cents, group.rate_plan, nights) + total
    end)
  end

  @doc "The group's lodging total, in cents: the sum of its room lodging amounts."
  def lodging_total(rooms, nights) do
    Enum.reduce(rooms, 0, fn room, total -> room_lodging_cents(room, nights) + total end)
  end

  @doc "Cash applied to the group's deposit so far, in cents."
  def payments_total(group) do
    Repo.aggregate(
      from(p in Payment, where: p.group_id == ^group.id and p.kind == @kind_payment),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc """
  The group's outstanding deposit, in cents.

  Active groups owe their deposit due minus cash applied. Cancelled groups
  owe nothing: their unpaid deposit is no longer due.
  """
  def outstanding(group, rooms) do
    outstanding(group, rooms, payments_total(group))
  end

  defp outstanding(group, rooms, paid) do
    if group.status == "cancelled" do
      0
    else
      max(deposit_due(group, rooms) - paid, 0)
    end
  end

  @doc """
  Returns the client-facing view of a group, or `:not_found`.
  """
  def fetch_view(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :not_found

      group ->
        group = Repo.preload(group, :rooms)
        payment_total = payments_total(group)
        nights = nights(group)

        {:ok,
         %{
           "group_id" => group.group_id,
           "guest_id" => group.guest_id,
           "property_id" => group.property_id,
           "revision" => group.revision,
           "booked_on" => Date.to_iso8601(group.booked_on),
           "arrival_on" => Date.to_iso8601(group.arrival_on),
           "departure_on" => Date.to_iso8601(group.departure_on),
           "rate_plan" => group.rate_plan,
           "status" => group.status,
           "rooms" =>
             Enum.map(group.rooms, fn room ->
               %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
             end),
           "lodging_total_cents" => lodging_total(group.rooms, nights),
           "deposit_due_cents" => deposit_due(group, group.rooms),
           "deposit_paid_cents" => payment_total,
           "outstanding_deposit_cents" => outstanding(group, group.rooms, payment_total)
         }}
    end
  end

  @doc """
  Current finance totals: cash held on active reservations, cash refunded
  at cancellation, and cash retained at cancellation.
  """
  def ledger_totals do
    %{
      "cash_held_cents" => cash_held(),
      "cash_refunded_cents" => kind_total(@kind_refund),
      "cash_retained_cents" => kind_total(@kind_retained)
    }
  end

  defp cash_held do
    Repo.aggregate(
      from(p in Payment,
        join: g in Group,
        on: g.id == p.group_id,
        where: p.kind == @kind_payment and g.status == "active"
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp kind_total(kind) do
    Repo.aggregate(
      from(p in Payment, where: p.kind == ^kind),
      :sum,
      :amount_cents
    ) || 0
  end
end
