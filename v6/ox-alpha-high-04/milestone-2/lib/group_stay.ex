defmodule GroupStay do
  @moduledoc """
  GroupStay keeps the contexts that define your domain and business logic.

  This context owns group reservations, their deposits, and the finance
  totals derived from them.
  """

  import Ecto.Query

  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Room
  alias GroupStay.Finance.CreditApplication
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.LedgerEntry
  alias GroupStay.Repo

  @flexible_deposit_percentage 20
  @flex_14_window_days 14
  @flex_30_window_days 30
  # Flexible groups booked on or after this date use the 30-day window.
  @flex_30_cutoff ~D[2027-01-01]
  @flex_14_policy "flex-14"
  @flex_30_policy "flex-30"
  @advance_policy "advance-nonrefundable"

  @hotel_credit_bonus_percentage 10
  # Credit is available through 365 days after issuance and expires the
  # following day; `expires_on` holds the last usable date.
  @hotel_credit_validity_days 365

  @doc """
  The cancellation policy version implied by the group's booking date and rate
  plan. Fixed when the group is opened: both inputs never change afterwards,
  so rescheduling never moves a group to a newer policy.
  """
  def policy_version(rate_plan, booked_on)

  def policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_cutoff) == :lt, do: @flex_14_policy, else: @flex_30_policy
  end

  def policy_version("advance_purchase", _booked_on), do: @advance_policy

  @doc """
  Cancellation window in days for a policy version, or `nil` when the policy
  never allows refunds.
  """
  def cancellation_window_days("flex-14"), do: @flex_14_window_days
  def cancellation_window_days("flex-30"), do: @flex_30_window_days
  def cancellation_window_days(_policy), do: nil

  @doc """
  The last cancellation date that is still refundable for a flexible group, as
  an ISO 8601 string; `nil` for advance purchase.
  """
  def refundable_until(rate_plan, booked_on, arrival_on) do
    case cancellation_window_days(policy_version(rate_plan, booked_on)) do
      nil -> nil
      days -> Date.to_iso8601(Date.add(arrival_on, -days))
    end
  end

  @doc """
  Returns true when a cancellation occurring on `occurred_on` is at least the
  group's cancellation-window number of calendar days before arrival.
  """
  def refundable?(rate_plan, booked_on, occurred_on, arrival_on) do
    case cancellation_window_days(policy_version(rate_plan, booked_on)) do
      nil -> false
      days -> Date.diff(arrival_on, occurred_on) >= days
    end
  end

  @doc """
  The 10% hotel-credit bonus for refunded cash, rounded with the standard
  rounding rule.
  """
  def hotel_credit_bonus(cash_cents) when is_integer(cash_cents) and cash_cents >= 0 do
    round_percentage(cash_cents, @hotel_credit_bonus_percentage)
  end

  def hotel_credit_lot_amount(cash_cents), do: cash_cents + hotel_credit_bonus(cash_cents)

  def get_group_with_rooms(group_id) do
    case Repo.get(group_query(), group_id) do
      nil -> {:error, :group_not_found}
      %Group{} = group -> {:ok, group}
    end
  end

  defp group_query do
    from(g in Group, preload: [rooms: ^room_order_query()])
  end

  defp room_order_query do
    from r in Room, order_by: [asc: r.position]
  end

  @doc """
  Rounds `amount * percentage / 100` to the nearest cent, with an exact
  half-cent rounded upward.
  """
  def round_percentage(amount_cents, percentage)
      when is_integer(amount_cents) and amount_cents >= 0 do
    div(amount_cents * percentage + 50, 100)
  end

  def flexible_room_deposit(lodging_cents) do
    round_percentage(lodging_cents, @flexible_deposit_percentage)
  end

  def advance_purchase_room_deposit(lodging_cents), do: lodging_cents

  @doc """
  Returns true when a flexible cancellation occurring on `occurred_on` is at
  least #{@flex_14_window_days} calendar days before arrival.

  Superseded by `refundable?/4`, which selects the window from the group's
  policy version; kept only for callers of the original release.
  """
  def flexible_refundable?(occurred_on, arrival_on) do
    Date.diff(arrival_on, occurred_on) >= @flex_14_window_days
  end

  def record_ledger_entry(attrs) do
    %LedgerEntry{}
    |> Ecto.Changeset.change(%{
      kind: attrs.kind,
      amount_cents: attrs.amount,
      group_id: attrs.group_id,
      occurred_on: attrs.occurred_on
    })
    |> Repo.insert!()
  end

  @doc """
  Cash currently applied to active reservations.

  Unpaid deposit requirements are not cash and never appear in these totals.
  Hotel credit applied to active groups is not cash either; it is reported as
  part of `credit_liability_cents` instead.
  """
  def finance_totals(opts \\ []) do
    # Expiry is reported as of the current UTC date unless a caller pins it,
    # e.g. when serving the ledger's optional `on` query parameter.
    as_of = Keyword.get(opts, :as_of, Date.utc_today())

    cash_held =
      from(g in Group,
        where: g.status == "active",
        select: coalesce(sum(g.cash_paid_cents), 0)
      )

    refunded =
      from(e in LedgerEntry,
        where: e.kind == "refunded",
        select: coalesce(sum(e.amount_cents), 0)
      )

    retained =
      from(e in LedgerEntry,
        where: e.kind == "retained",
        select: coalesce(sum(e.amount_cents), 0)
      )

    converted =
      from(e in LedgerEntry,
        where: e.kind == "converted_to_credit",
        select: coalesce(sum(e.amount_cents), 0)
      )

    %{
      cash_held_cents: Repo.one(cash_held),
      cash_refunded_cents: Repo.one(refunded),
      cash_retained_cents: Repo.one(retained),
      cash_converted_to_credit_cents: Repo.one(converted),
      credit_liability_cents: credit_liability(as_of)
    }
  end

  ## Hotel credit

  @doc """
  Issues a hotel-credit lot worth `cash_cents` plus its bonus to `guest_id`.

  The lot is available through #{@hotel_credit_validity_days} days after
  issuance and expires the following day. Returns the issued lot amount.
  """
  def issue_hotel_credit(guest_id, source_operation_id, cash_cents, issued_on) do
    amount = hotel_credit_lot_amount(cash_cents)

    if amount > 0 do
      %CreditLot{}
      |> Ecto.Changeset.change(%{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        issued_on: issued_on,
        expires_on: Date.add(issued_on, @hotel_credit_validity_days),
        remaining_cents: amount
      })
      |> Repo.insert!()
    end

    amount
  end

  # Available lots for a guest: positive balance, not expired as of `as_of`,
  # ordered by earliest expiry then by source operation for equal expiries.
  defp available_lots_query(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
  end

  @doc """
  The guest's available credit: lots readable as of `as_of`, expired and
  exhausted lots omitted.
  """
  def available_credit(guest_id, as_of) do
    available_lots_query(guest_id, as_of)
    |> Repo.aggregate(:sum, :remaining_cents)
    |> Kernel.||(0)
  end

  @doc """
  Guests read their own lots through this view. Omitted lots are exhausted or
  expired as of `as_of`.
  """
  def guest_credit(guest_id, as_of) do
    lots =
      available_lots_query(guest_id, as_of)
      |> Repo.all()
      |> Enum.map(fn lot ->
        %{
          source_operation_id: lot.source_operation_id,
          remaining_cents: lot.remaining_cents,
          expires_on: lot.expires_on
        }
      end)

    %{available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)), lots: lots}
  end

  @doc """
  Redeems up to `amount_cents` of the group's guest credit into the group's
  active deposit.

  Lots are consumed by earliest expiry, then by source operation. Each taken
  portion moves out of its lot's available balance into a per-group
  application row, which pauses that portion's expiry while the group is
  active. Returns `:ok`, having validated expiry as of `occurred_on`.
  """
  def apply_group_credit(group, occurred_on, operation_id, amount_cents) do
    guest_id = group.guest_id

    if available_credit(guest_id, occurred_on) < amount_cents do
      {:error, :insufficient_credit}
    else
      consume_lots(guest_id, occurred_on, %{
        group_id: group.group_id,
        operation_id: operation_id,
        amount_cents: amount_cents
      })

      :ok
    end
  end

  defp consume_lots(guest_id, occurred_on, request) do
    available_lots_query(guest_id, occurred_on)
    |> Repo.all()
    |> Enum.reduce_while(request.amount_cents, fn lot, needed ->
      take = min(lot.remaining_cents, needed)

      if take > 0 do
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - take))

        %CreditApplication{}
        |> Ecto.Changeset.change(%{
          group_id: request.group_id,
          lot_id: lot.id,
          amount_cents: take,
          applied_operation_id: request.operation_id,
          applied_on: occurred_on
        })
        |> Repo.insert!()
      end

      {:cont, needed - take}
    end)

    :ok
  end

  @doc """
  Returns every portion of the group's applied hotel credit to its original
  lot with its original expiry — restored amounts never receive a second
  bonus.

  A portion whose original expiry is already past on `restore_on` expires
  immediately instead: it does not become available again, so dropping it
  reduces the credit liability.
  """
  def restore_group_credit(group, restore_on) do
    applications =
      from(a in CreditApplication, where: a.group_id == ^group.group_id)
      |> Repo.all()

    Enum.each(applications, fn application ->
      lot = Repo.get!(CreditLot, application.lot_id)

      if Date.compare(lot.expires_on, restore_on) != :lt do
        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + application.amount_cents
          )
        )
      end

      Repo.delete!(application)
    end)

    :ok
  end

  @doc """
  Consumes the group's applied hotel credit, as happens on a non-refundable
  cancellation: the credit liability drops and nothing returns to any lot.
  """
  def consume_group_credit(group_id) do
    Repo.delete_all(from(a in CreditApplication, where: a.group_id == ^group_id))
    :ok
  end

  @doc """
  Credit owed to guests: available unexpired lot balances plus credit
  currently redeemed into active groups' deposits (where expiry is paused).

  Applying credit therefore does not change this total; restoring already
  expired credit does reduce it.
  """
  def credit_liability(as_of) do
    available =
      from(l in CreditLot, where: l.remaining_cents > 0 and l.expires_on >= ^as_of)
      |> Repo.aggregate(:sum, :remaining_cents)
      |> Kernel.||(0)

    funded = Repo.aggregate(CreditApplication, :sum, :amount_cents) || 0

    available + funded
  end
end
