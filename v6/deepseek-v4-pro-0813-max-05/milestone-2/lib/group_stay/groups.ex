defmodule GroupStay.Groups do
  @moduledoc """
  Reads groups and the finance ledger, and computes group money totals.

  Money amounts are integer cents. Deposit rounding is half-up to the
  nearest cent, done per room before summing the group.
  """

  alias GroupStay.{CreditApplication, CreditLot, Group, Payment, Policies, Repo}

  import Ecto.Query

  @flexible "flexible"
  @kind_payment "payment"
  @kind_refund "refund"
  @kind_retained "retained"
  @kind_converted "converted"

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

  @doc "Hotel credit applied to the group's deposit so far, in cents."
  def credit_paid(group) do
    Repo.aggregate(
      from(a in CreditApplication, where: a.group_id == ^group.id),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc """
  The group's outstanding deposit, in cents.

  Active groups owe their deposit due minus cash and credit applied.
  Cancelled groups owe nothing: their unpaid deposit is no longer due.
  """
  def outstanding(group, rooms) do
    outstanding(group, rooms, payments_total(group) + credit_paid(group))
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
        cash = payments_total(group)
        credit = credit_paid(group)
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
           "policy_version" => Policies.policy_version(group),
           "refundable_until" => iso_date(Policies.refundable_until(group)),
           "rooms" =>
             Enum.map(group.rooms, fn room ->
               %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
             end),
           "lodging_total_cents" => lodging_total(group.rooms, nights),
           "deposit_due_cents" => deposit_due(group, group.rooms),
           "cash_paid_cents" => cash,
           "credit_paid_cents" => credit,
           "deposit_paid_cents" => cash + credit,
           "outstanding_deposit_cents" => outstanding(group, group.rooms, cash + credit)
         }}
    end
  end

  defp iso_date(nil), do: nil
  defp iso_date(date), do: Date.to_iso8601(date)

  @doc "The date used by as-of reads, defaulting to today's UTC date."
  def as_of(params) do
    case Map.get(params, "on") do
      nil ->
        {:ok, Date.utc_today()}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Current finance totals: cash held on active reservations, cash refunded,
  retained, or converted into hotel credit at cancellation, and the total
  credit liability outstanding as of `on`.
  """
  def ledger_totals, do: ledger_totals(Date.utc_today())

  def ledger_totals(on) do
    %{
      "cash_held_cents" => cash_held(),
      "cash_refunded_cents" => kind_total(@kind_refund),
      "cash_retained_cents" => kind_total(@kind_retained),
      "cash_converted_to_credit_cents" => kind_total(@kind_converted),
      "credit_liability_cents" => available_credit(on) + applied_credit()
    }
  end

  @doc """
  A guest's hotel credit view as of `on`: the available total and the
  unexpired, unexhausted lots ordered by expiry, then source operation.
  """
  def guest_credit(guest_id, on) do
    lots =
      Repo.all(
        from(l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
        )
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.reduce(lots, 0, fn lot, total -> lot.remaining_cents + total end),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
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

  defp available_credit(on) do
    Repo.aggregate(
      from(l in CreditLot, where: l.remaining_cents > 0 and l.expires_on > ^on),
      :sum,
      :remaining_cents
    ) || 0
  end

  defp applied_credit do
    Repo.aggregate(
      from(a in CreditApplication, where: a.status == "applied"),
      :sum,
      :amount_cents
    ) || 0
  end
end
