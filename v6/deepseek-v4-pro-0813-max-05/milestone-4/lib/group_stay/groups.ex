defmodule GroupStay.Groups do
  @moduledoc """
  Reads groups and the finance ledger, and computes group money totals.

  Money amounts are integer cents. Deposit rounding is half-up to the
  nearest cent, done per room before summing the group. Group totals
  describe active rooms only; cancelled rooms carry zero requirement and
  zero held funding.
  """

  alias GroupStay.{
    CreditLot,
    DurableOperation,
    Group,
    LegacyFunding,
    Payment,
    Policies,
    Repo,
    RoomAccounting
  }

  import Ecto.Query

  @flexible "flexible"

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

  @doc "The sum of the active rooms' deposits, in cents."
  def deposit_due(group, rooms) do
    Enum.reduce(rooms, 0, fn room, total ->
      if room.status == "active" do
        RoomAccounting.room_deposit(group, room) + total
      else
        total
      end
    end)
  end

  @doc "The sum of the active rooms' lodging amounts, in cents."
  def lodging_total(rooms, nights) do
    Enum.reduce(rooms, 0, fn room, total ->
      if room.status == "active" do
        room_lodging_cents(room, nights) + total
      else
        total
      end
    end)
  end

  @doc "Cash funding the group's active deposit, in cents."
  def held_cash(group), do: RoomAccounting.held_totals(group).cash

  @doc "Hotel credit funding the group's active deposit, in cents."
  def held_credit(group), do: RoomAccounting.held_totals(group).credit

  @doc """
  The group's outstanding deposit, in cents.

  Cancelled groups owe nothing. Active groups owe their active rooms'
  deposit due minus the cash and credit still held against it.
  """
  def outstanding(group) do
    held = RoomAccounting.held_totals(group)
    arranged(group, held)
  end

  defp arranged(%{status: "cancelled"}, _held), do: 0

  defp arranged(group, held) do
    rooms = RoomAccounting.active_rooms(group)
    max(deposit_due(group, rooms) - held.cash - held.credit, 0)
  end

  @doc """
  Returns the client-facing view of a group, or `:not_found`.
  """
  def fetch_view(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        :not_found

      group ->
        LegacyFunding.ensure_forwarded(group)
        group = Repo.preload(group, :rooms)
        nights = nights(group)
        holdings = RoomAccounting.held_by_room_and_kind(group)

        rooms =
          Enum.map(group.rooms, fn room ->
            money = Map.get(holdings, room.id, %{cash: 0, credit: 0})

            if room.status == "active" do
              %{
                "room_id" => room.room_id,
                "nightly_rate_cents" => room.nightly_rate_cents,
                "status" => "active",
                "deposit_due_cents" => RoomAccounting.room_deposit(group, room),
                "cash_paid_cents" => money.cash,
                "credit_paid_cents" => money.credit
              }
            else
              %{
                "room_id" => room.room_id,
                "nightly_rate_cents" => room.nightly_rate_cents,
                "status" => "cancelled",
                "deposit_due_cents" => 0,
                "cash_paid_cents" => 0,
                "credit_paid_cents" => 0
              }
            end
          end)

        active_rooms = Enum.filter(group.rooms, &(&1.status == "active"))

        cash =
          Enum.reduce(active_rooms, 0, fn room, sum ->
            Map.get(holdings, room.id, %{cash: 0, credit: 0}).cash + sum
          end)

        credit =
          Enum.reduce(active_rooms, 0, fn room, sum ->
            Map.get(holdings, room.id, %{cash: 0, credit: 0}).credit + sum
          end)

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
           "rooms" => rooms,
           "lodging_total_cents" => lodging_total(group.rooms, nights),
           "deposit_due_cents" => deposit_due(group, active_rooms),
           "cash_paid_cents" => cash,
           "credit_paid_cents" => credit,
           "deposit_paid_cents" => cash + credit,
           "outstanding_deposit_cents" => outstanding(group)
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
  Current finance totals: held, refunded, retained, converted, reduced, and
  charged-back cash; the credit liability outstanding as of `on`; and the
  current credit shortfall from chargebacks.
  """
  def ledger_totals, do: ledger_totals(Date.utc_today())

  def ledger_totals(on) do
    Enum.each(Repo.all(Group), &LegacyFunding.ensure_forwarded/1)

    %{
      "cash_held_cents" => cash_held(),
      "cash_refunded_cents" => payment_total(:refunded_cents),
      "cash_retained_cents" => payment_total(:retained_cents),
      "cash_converted_to_credit_cents" => payment_total(:converted_cents),
      "cash_reduced_cents" => payment_total(:reduced_cents),
      "cash_charged_back_cents" => payment_total(:charged_back_cents),
      "credit_liability_cents" => available_credit(on) + applied_credit(),
      "credit_shortfall_cents" => credit_shortfall()
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

  @doc """
  The current dispositions of one durably recorded cash payment.

  Returns `{:ok, map}` for an applied payment and `:not_found` /
  `:unreconcilable` otherwise.
  """
  def payment_statement(operation_id) do
    case Repo.get_by(DurableOperation, operation_id: operation_id) do
      nil ->
        :not_found

      durable ->
        result = Jason.decode!(durable.result_json)

        cond do
          durable.op_type != "record_cash_payment" or result["status"] != "applied" ->
            :unreconcilable

          true ->
            case Repo.get_by(Payment, operation_id: operation_id) do
              nil ->
                :unreconcilable

              payment ->
                group = Repo.get!(Group, payment.group_id)

                {:ok,
                 %{
                   "payment_operation_id" => operation_id,
                   "original_group_id" => group.group_id,
                   "recorded_cents" => payment.amount_cents,
                   "held_cents" => RoomAccounting.held_cash(payment),
                   "refunded_cents" => payment.refunded_cents,
                   "retained_cents" => payment.retained_cents,
                   "converted_to_credit_cents" => payment.converted_cents,
                   "reduced_cents" => payment.reduced_cents,
                   "charged_back_cents" => payment.charged_back_cents
                 }}
            end
        end
    end
  end

  defp cash_held do
    Repo.aggregate(
      from(a in GroupStay.RoomAllocation,
        where: a.kind == "cash" and a.status == "held" and a.amount_cents > 0
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp payment_total(field) do
    Repo.one(from(p in Payment, select: sum(field(p, ^field)))) || 0
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
      from(a in GroupStay.RoomAllocation,
        where: a.kind == "credit" and a.status == "held" and a.amount_cents > 0
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  defp credit_shortfall do
    Repo.all(from(l in CreditLot, where: l.unrecovered_clawback_cents > 0))
    |> Enum.reduce(0, fn lot, total ->
      min(lot.unrecovered_clawback_cents, RoomAccounting.lot_applied_credit(lot.id)) + total
    end)
  end
end
