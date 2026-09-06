defmodule GroupStay.Groups do
  @moduledoc """
  Read-side access to group reservations, hotel credit, and the deposit
  ledger.
  """

  import Ecto.Query

  alias GroupStay.Groups.{CashPayment, CreditApplication, CreditLot, Group, Room}
  alias GroupStay.Repo

  # Flexible groups booked before this date keep the original 14-day
  # cancellation window; groups booked on or after it use the 30-day window.
  # A group's policy version is fixed by its booking date, so rescheduling
  # never moves it to a newer policy.
  @policy_change_date ~D[2027-01-01]
  @cancellation_windows %{"flex-14" => 14, "flex-30" => 30}

  @doc """
  Fetches a group by its partner identifier, with rooms in their original
  order. Returns `nil` when the group does not exist.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        nil

      group ->
        Repo.preload(group, rooms: from(r in Room, order_by: [asc: r.position]))
    end
  end

  @doc """
  Builds the JSON representation of a group for the partner API.
  """
  def group_view(%Group{} = group) do
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
      "policy_version" => policy_version(group),
      "refundable_until" => iso_date_or_nil(refundable_until(group)),
      "rooms" => Enum.map(group.rooms, &room_view/1),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => cash_paid_cents(group),
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  defp room_view(%Room{} = room) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "status" => room.status,
      "deposit_due_cents" => room.deposit_cents,
      "cash_paid_cents" => room.cash_paid_cents,
      "credit_paid_cents" => room.credit_paid_cents
    }
  end

  defp iso_date_or_nil(nil), do: nil
  defp iso_date_or_nil(date), do: Date.to_iso8601(date)

  @doc """
  The cancellation policy fixed for the group when it was opened.
  """
  def policy_version(%Group{rate_plan: "advance_purchase"}), do: "advance-nonrefundable"

  def policy_version(%Group{booked_on: booked_on}) do
    if Date.compare(booked_on, @policy_change_date) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The last date on which a flexible group can be cancelled refundably;
  `nil` for advance-purchase groups.
  """
  def refundable_until(%Group{rate_plan: "advance_purchase"}), do: nil

  def refundable_until(%Group{} = group) do
    Date.add(group.arrival_on, -@cancellation_windows[policy_version(group)])
  end

  @doc """
  A flexible group is refundable when cancellation occurs on or before its
  refundable_until date; advance-purchase groups never are.
  """
  def refundable?(%Group{} = group, occurred_on) do
    group.rate_plan == "flexible" and
      Date.compare(occurred_on, refundable_until(group)) != :gt
  end

  @doc """
  Cash applied to the group's deposit; the remainder of the paid deposit is
  hotel credit.
  """
  def cash_paid_cents(%Group{} = group) do
    group.deposit_paid_cents - group.credit_paid_cents
  end

  @doc """
  Unpaid deposit is only due while the group is active; cancellation drops
  the remaining requirement.
  """
  def outstanding_deposit_cents(%Group{} = group) do
    if group.status == "active" do
      group.deposit_due_cents - group.deposit_paid_cents
    else
      0
    end
  end

  @doc """
  A guest's unexpired, unspent credit lots and their total, as of the given
  date. Expired and exhausted lots are omitted, ordered by expiry date and
  then source operation.
  """
  def guest_credit_view(guest_id, as_of) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    %{
      "guest_id" => guest_id,
      "available_cents" => lots |> Enum.map(& &1.remaining_cents) |> Enum.sum(),
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
  Finance totals across all groups.

  Cash held is the cash currently applied to active reservations;
  cancellation moves each group's cash to refunded, retained, or converted
  to credit, provider corrections reduce it, and chargebacks move it to
  charged-back cash. Unpaid deposit requirements are not cash and never
  appear here.

  The credit liability is reported as of the given date and includes both
  available credit and credit currently applied to active groups, including
  credit covered by a current shortfall. The credit shortfall is the sum of
  each lot's unrecovered clawback that is still covered by credit from that
  lot applied to active groups.
  """
  def ledger(as_of) do
    cash_held =
      Repo.one(
        from p in CashPayment,
          join: g in assoc(p, :group),
          where: g.status == "active",
          select:
            coalesce(
              sum(
                p.amount_cents - p.refunded_cents - p.retained_cents - p.converted_cents -
                  p.reduced_cents - p.charged_back_cents
              ),
              0
            )
      )

    cash_refunded = Repo.one(from g in Group, select: coalesce(sum(g.refunded_cents), 0))
    cash_retained = Repo.one(from g in Group, select: coalesce(sum(g.retained_cents), 0))

    cash_converted = Repo.one(from g in Group, select: coalesce(sum(g.converted_cents), 0))

    cash_reduced = Repo.one(from g in Group, select: coalesce(sum(g.cash_reduced_cents), 0))

    cash_charged_back =
      Repo.one(from g in Group, select: coalesce(sum(g.cash_charged_back_cents), 0))

    credit_available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    credit_applied =
      Repo.one(
        from a in CreditApplication,
          join: g in assoc(a, :group),
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    %{
      "cash_held_cents" => cash_held,
      "cash_refunded_cents" => cash_refunded,
      "cash_retained_cents" => cash_retained,
      "cash_converted_to_credit_cents" => cash_converted,
      "cash_reduced_cents" => cash_reduced,
      "cash_charged_back_cents" => cash_charged_back,
      "credit_liability_cents" => credit_available + credit_applied,
      "credit_shortfall_cents" => credit_shortfall()
    }
  end

  # A lot's current shortfall is the lesser of its unrecovered clawback and
  # credit from that lot still applied to active groups.
  defp credit_shortfall do
    applied_by_lot =
      Repo.all(
        from a in CreditApplication,
          join: g in assoc(a, :group),
          where: g.status == "active",
          group_by: a.lot_id,
          select: {a.lot_id, sum(a.amount_cents)}
      )
      |> Map.new()

    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, shortfall ->
      shortfall + min(lot.unrecovered_clawback_cents, Map.get(applied_by_lot, lot.id, 0))
    end)
  end
end
