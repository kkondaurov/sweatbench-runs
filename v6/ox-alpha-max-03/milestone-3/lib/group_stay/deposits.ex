defmodule GroupStay.Deposits do
  @moduledoc """
  Applies partner operations to group deposits and reports finance totals.

  `apply_in_transaction/1` must run inside a database transaction opened by
  the caller (see `GroupStay.Operations.Journal`), so domain changes commit in
  the same transaction as the operation's durable record. Handled rejections
  leave all group deposit state unchanged.
  """

  import Ecto.Query

  alias GroupStay.Deposits.CreditApplication
  alias GroupStay.Deposits.CreditLot
  alias GroupStay.Deposits.Group
  alias GroupStay.Deposits.LedgerEntry
  alias GroupStay.Deposits.Room
  alias GroupStay.Operations
  alias GroupStay.Repo

  @flexible_deposit_percentage 20
  @credit_bonus_percentage 10
  # Flexible groups booked on or after this date use the 30-day window;
  # earlier bookings keep the 14-day window. A group's policy version is
  # fixed when the group is opened and never moves to a newer policy.
  @flexible_policy_cutoff ~D[2027-01-01]
  @policy_flex_14 "flex-14"
  @policy_flex_30 "flex-30"
  @policy_advance_nonrefundable "advance-nonrefundable"
  # A credit lot is available through 365 days after issuance and expires
  # the following day.
  @credit_available_days 365

  @type error ::
          :group_already_exists
          | :invalid_stay
          | :invalid_rooms
          | :invalid_rate_plan
          | :group_not_found
          | :group_not_active
          | :invalid_amount
          | :payment_exceeds_outstanding
          | :refund_method_not_available
          | :insufficient_credit

  @doc """
  Applies one parsed operation and returns the fields reported to the partner.

  Runs inside the caller's database transaction. Errors are plain codes except
  `{:error, {:stale_revision, expected, actual}}`, which carries the revisions
  required by the API document.
  """
  @spec apply_in_transaction(Operations.Operation.t()) ::
          {:ok, map()}
          | {:error, error()}
          | {:error, {:stale_revision, pos_integer(), pos_integer()}}
  def apply_in_transaction(%Operations.Operation{} = op) do
    dispatch(op)
  end

  @doc """
  Returns a group by its partner-supplied identifier, or nil.
  """
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(group_id) do
    rooms_query = from r in Room, order_by: r.position

    Repo.one(
      from g in Group,
        where: g.group_id == ^group_id,
        preload: [rooms: ^rooms_query]
    )
  end

  @doc """
  Returns cash currently held plus lifetime refunded, retained, and
  cash-converted-to-credit totals, and the outstanding credit liability as of
  `on` (defaults to the current UTC date).

  The liability includes both available credit and credit currently applied to
  active groups, where expiry is paused while the credit funds a group.
  """
  @spec ledger_totals(Date.t()) :: %{
          cash_held_cents: non_neg_integer(),
          cash_refunded_cents: non_neg_integer(),
          cash_retained_cents: non_neg_integer(),
          cash_converted_to_credit_cents: non_neg_integer(),
          credit_liability_cents: non_neg_integer()
        }
  def ledger_totals(on \\ Date.utc_today()) do
    held =
      from(e in LedgerEntry,
        join: g in assoc(e, :group),
        where: e.kind == "cash" and g.status == "active",
        select: coalesce(sum(e.amount_cents), 0)
      )

    refunded =
      from(e in LedgerEntry,
        where: e.kind == "refund",
        select: coalesce(sum(e.amount_cents), 0)
      )

    retained =
      from(e in LedgerEntry,
        where: e.kind == "retain",
        select: coalesce(sum(e.amount_cents), 0)
      )

    converted =
      from(e in LedgerEntry,
        where: e.kind == "convert_to_credit",
        select: coalesce(sum(e.amount_cents), 0)
      )

    %{
      cash_held_cents: total(held),
      cash_refunded_cents: total(refunded),
      cash_retained_cents: total(retained),
      cash_converted_to_credit_cents: total(converted),
      credit_liability_cents: credit_liability(on)
    }
  end

  @doc """
  Available hotel credit lots for a guest as of `on` (defaults to the current
  UTC date), ordered by expiry date, then by source operation identifier.
  Expired and exhausted lots are omitted.
  """
  @spec guest_credit(String.t(), Date.t()) :: %{
          guest_id: String.t(),
          available_cents: non_neg_integer(),
          lots: [
            %{
              source_operation_id: String.t(),
              remaining_cents: pos_integer(),
              expires_on: Date.t()
            }
          ]
        }
  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id],
        select: %{
          source_operation_id: l.source_operation_id,
          remaining_cents: l.remaining_cents,
          expires_on: l.expires_on
        }
      )
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  defp credit_liability(on) do
    available =
      from(l in CreditLot,
        where: l.remaining_cents > 0 and l.expires_on > ^on,
        select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      from(a in CreditApplication,
        join: g in assoc(a, :group),
        where: g.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
      )

    total(available) + total(applied)
  end

  ## Dispatching

  defp dispatch(%Operations.Operation{type: :open_group} = op) do
    # Resolve group existence before evaluating domain rules.
    if group_exists?(op.group_id) do
      {:error, :group_already_exists}
    else
      with :ok <- validate_stay(op),
           :ok <- validate_rooms(op.rooms),
           :ok <- validate_rate_plan(op.rate_plan) do
        open_group(op)
      end
    end
  end

  defp dispatch(%Operations.Operation{type: :record_cash_payment} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group),
         :ok <- validate_outstanding(group, op.amount_cents) do
      record_cash(group, op)
    end
  end

  defp dispatch(%Operations.Operation{type: :reschedule_group} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group),
         :ok <- validate_new_arrival(op) do
      reschedule(group, op)
    end
  end

  defp dispatch(%Operations.Operation{type: :cancel_group} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group),
         :ok <- check_refund_method(group, op) do
      cancel(group, op)
    end
  end

  defp dispatch(%Operations.Operation{type: :apply_hotel_credit} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group),
         :ok <- validate_outstanding(group, op.amount_cents),
         {:ok, allocations} <- allocate_credit(group.guest_id, op.amount_cents, op.occurred_on) do
      apply_credit(group, op, allocations)
    end
  end

  ## Opening a group

  defp group_exists?(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  defp validate_stay(op) do
    if Date.compare(op.departure_on, op.arrival_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp validate_rooms([]), do: {:error, :invalid_rooms}

  defp validate_rooms(rooms) do
    positive_rates? = Enum.all?(rooms, fn room -> room.nightly_rate_cents > 0 end)

    room_ids = Enum.map(rooms, & &1.room_id)
    unique_room_ids? = length(room_ids) == length(Enum.uniq(room_ids))

    if positive_rates? and unique_room_ids? do
      :ok
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"], do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp open_group(op) do
    nights = Date.diff(op.departure_on, op.arrival_on)

    rooms =
      op.rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        room
        |> room_attrs(nights)
        |> Map.put(:position, position)
      end)

    lodging_total = rooms |> Enum.map(& &1.lodging_amount_cents) |> Enum.sum()

    deposit_due =
      op.rooms
      |> Enum.map(&room_deposit(&1, nights, op.rate_plan))
      |> Enum.sum()

    attrs = %{
      group_id: op.group_id,
      guest_id: op.guest_id,
      property_id: op.property_id,
      booked_on: op.occurred_on,
      arrival_on: op.arrival_on,
      departure_on: op.departure_on,
      rate_plan: op.rate_plan,
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      # The policy version is fixed here and never changes afterwards.
      policy_version: policy_version(op.rate_plan, op.occurred_on),
      rooms: rooms
    }

    attrs
    |> Group.open_changeset()
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        {:ok,
         %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         }}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :group_id) do
          {:error, :group_already_exists}
        else
          {:error, :invalid_rooms}
        end
    end
  end

  defp room_attrs(room, nights) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_amount_cents: nights * room.nightly_rate_cents
    }
  end

  # Each flexible room's deposit is calculated and rounded separately before
  # the room deposits are summed; an advance-purchase room requires its full
  # lodging amount.
  defp room_deposit(room, nights, rate_plan) do
    lodging_amount = nights * room.nightly_rate_cents

    case rate_plan do
      "flexible" -> percentage_half_up(lodging_amount, @flexible_deposit_percentage)
      "advance_purchase" -> lodging_amount
    end
  end

  ## Cancellation policy versions

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flexible_policy_cutoff) == :lt do
      @policy_flex_14
    else
      @policy_flex_30
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: @policy_advance_nonrefundable

  @doc """
  The cancellation window in calendar days for a group's policy version, or
  nil when the policy is never refundable.
  """
  @spec cancellation_window(String.t()) :: non_neg_integer() | nil
  def cancellation_window(@policy_flex_14), do: 14
  def cancellation_window(@policy_flex_30), do: 30
  def cancellation_window(@policy_advance_nonrefundable), do: nil

  @doc """
  The last date on which cancelling the group is refundable, or nil for
  advance purchase. Recomputed from the current arrival date; the policy
  version itself never moves.
  """
  @spec refundable_until(Group.t()) :: Date.t() | nil
  def refundable_until(%Group{} = group) do
    case cancellation_window(group.policy_version) do
      nil -> nil
      window -> Date.add(group.arrival_on, -window)
    end
  end

  # A flexible group is refundable when cancellation happens at least its
  # window's number of calendar days before arrival; cancelling exactly on
  # `refundable_until` is refundable. Advance purchase never refunds.
  defp refundable?(%Group{} = group, on_date) do
    case cancellation_window(group.policy_version) do
      nil -> false
      window -> Date.diff(group.arrival_on, on_date) >= window
    end
  end

  ## Recording cash

  defp record_cash(group, op) do
    {:ok, _entry} =
      insert_entry(group, "cash", op.amount_cents, op.occurred_on)

    updated =
      group
      |> Group.update_changeset(%{
        deposit_paid_cents: group.deposit_paid_cents + op.amount_cents,
        cash_paid_cents: group.cash_paid_cents + op.amount_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

    {:ok,
     %{
       group_id: group.group_id,
       amount_cents: op.amount_cents,
       outstanding_deposit_cents: outstanding_deposit(updated),
       revision: updated.revision
     }}
  end

  ## Rescheduling

  defp reschedule(group, op) do
    shift = Date.diff(op.new_arrival_on, group.arrival_on)
    new_departure = Date.add(group.departure_on, shift)

    updated =
      group
      |> Group.update_changeset(%{
        arrival_on: op.new_arrival_on,
        departure_on: new_departure,
        revision: group.revision + 1
      })
      |> Repo.update!()

    {:ok,
     %{
       group_id: group.group_id,
       new_arrival_on: updated.arrival_on,
       new_departure_on: updated.departure_on,
       policy_version: updated.policy_version,
       refundable_until: refundable_until(updated),
       revision: updated.revision
     }}
  end

  defp validate_new_arrival(op) do
    if Date.compare(op.new_arrival_on, op.occurred_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  ## Cancelling

  # Hotel credit is not a way around a non-refundable policy; requesting it
  # for a non-refundable cancellation rejects the whole operation and leaves
  # the group active.
  defp check_refund_method(group, op) do
    if op.refund_method == :hotel_credit and not refundable?(group, op.occurred_on) do
      {:error, :refund_method_not_available}
    else
      :ok
    end
  end

  defp cancel(group, op) do
    cash = group.cash_paid_cents
    refundable? = refundable?(group, op.occurred_on)

    {refunded, retained, credit_issued} =
      cond do
        refundable? and op.refund_method == :hotel_credit ->
          restore_applied_credit(group, op.occurred_on)
          {0, 0, convert_cash_to_credit(group, op)}

        refundable? ->
          restore_applied_credit(group, op.occurred_on)

          if cash > 0 do
            {:ok, _entry} = insert_entry(group, "refund", cash, op.occurred_on)
          end

          {cash, 0, 0}

        true ->
          consume_applied_credit(group)

          if cash > 0 do
            {:ok, _entry} = insert_entry(group, "retain", cash, op.occurred_on)
          end

          {0, cash, 0}
      end

    updated =
      group
      |> Group.update_changeset(%{
        status: "cancelled",
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        revision: group.revision + 1
      })
      |> Repo.update!()

    {:ok,
     %{
       group_id: updated.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       credit_issued_cents: credit_issued,
       revision: updated.revision
     }}
  end

  # The cash-funded portion becomes a credit lot worth 110% of that cash (the
  # 10% bonus uses the standard rounding rule) and leaves cash_held for the
  # cumulative converted total. The lot is available through 365 days after
  # cancellation and expires the following day.
  defp convert_cash_to_credit(group, op) do
    cash = group.cash_paid_cents

    if cash > 0 do
      issued = cash + percentage_half_up(cash, @credit_bonus_percentage)

      {:ok, _lot} =
        Repo.insert(
          CreditLot.changeset(%CreditLot{}, %{
            guest_id: group.guest_id,
            source_operation_id: op.operation_id,
            issued_cents: issued,
            remaining_cents: issued,
            expires_on: Date.add(op.occurred_on, @credit_available_days + 1)
          })
        )

      {:ok, _entry} = insert_entry(group, "convert_to_credit", cash, op.occurred_on)

      issued
    else
      0
    end
  end

  # Applied credit returns to its original lots with its original expiry. A
  # lot whose expiry is already past on the cancellation date cannot hold the
  # restored amount again; it expires immediately instead.
  defp restore_applied_credit(group, cancelled_on) do
    group.id
    |> applications_with_lots_query()
    |> Repo.all()
    |> Enum.each(fn application ->
      if Date.compare(application.expires_on, cancelled_on) == :gt do
        lot = Repo.get!(CreditLot, application.credit_lot_id)

        lot
        |> CreditLot.update_changeset(%{
          remaining_cents: lot.remaining_cents + application.amount_cents
        })
        |> Repo.update!()
      end

      Repo.delete!(%CreditApplication{id: application.id})
    end)
  end

  # A non-refundable cancellation consumes the applied credit.
  defp consume_applied_credit(group) do
    Repo.delete_all(from(a in CreditApplication, where: a.group_id == ^group.id))
  end

  ## Applying hotel credit

  # Lots are consumed by earliest expiry, then by source operation id for
  # equal expiries. Expiry is evaluated with the operation's occurred_on date;
  # while credit funds an active group its expiry is paused, so only the lots'
  # unapplied remainders need to be unexpired here.
  defp allocate_credit(guest_id, amount_cents, occurred_on) do
    lots =
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^occurred_on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

    {allocations, shortfall} =
      Enum.reduce(lots, {[], amount_cents}, fn lot, {acc, remaining} ->
        if remaining > 0 do
          take = min(lot.remaining_cents, remaining)
          {[%{lot: lot, amount_cents: take} | acc], remaining - take}
        else
          {acc, remaining}
        end
      end)

    if shortfall > 0 do
      {:error, :insufficient_credit}
    else
      {:ok, Enum.reverse(allocations)}
    end
  end

  defp apply_credit(group, op, allocations) do
    Enum.each(allocations, fn allocation ->
      {:ok, _application} =
        Repo.insert(
          CreditApplication.changeset(%CreditApplication{}, %{
            group_id: group.id,
            credit_lot_id: allocation.lot.id,
            amount_cents: allocation.amount_cents
          })
        )

      allocation.lot
      |> CreditLot.update_changeset(%{
        remaining_cents: allocation.lot.remaining_cents - allocation.amount_cents
      })
      |> Repo.update!()
    end)

    updated =
      group
      |> Group.update_changeset(%{
        deposit_paid_cents: group.deposit_paid_cents + op.amount_cents,
        credit_paid_cents: group.credit_paid_cents + op.amount_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

    {:ok,
     %{
       group_id: group.group_id,
       amount_cents: op.amount_cents,
       outstanding_deposit_cents: outstanding_deposit(updated),
       revision: updated.revision
     }}
  end

  ## Shared helpers

  defp fetch_group(group_id) do
    case get_group(group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  # Existence resolves first; a stale revision is then rejected before any
  # other domain rule is evaluated.
  defp check_revision(_group, nil), do: :ok

  defp check_revision(group, expected_revision) do
    if group.revision == expected_revision do
      :ok
    else
      {:error, {:stale_revision, expected_revision, group.revision}}
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(%Group{}), do: {:error, :group_not_active}

  defp validate_outstanding(group, amount_cents) do
    if amount_cents > outstanding_deposit(group) do
      {:error, :payment_exceeds_outstanding}
    else
      :ok
    end
  end

  @doc """
  Cash still owed on an active reservation's deposit. Unpaid deposit
  requirements disappear when a group is cancelled.
  """
  @spec outstanding_deposit(Group.t()) :: non_neg_integer()
  def outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  def outstanding_deposit(%Group{}), do: 0

  defp insert_entry(group, kind, amount_cents, occurred_on) do
    Repo.insert(
      LedgerEntry.changeset(%LedgerEntry{}, %{
        group_id: group.id,
        kind: kind,
        amount_cents: amount_cents,
        occurred_on: occurred_on
      })
    )
  end

  defp applications_with_lots_query(group_id) do
    from(a in CreditApplication,
      join: l in assoc(a, :credit_lot),
      where: a.group_id == ^group_id,
      select: %{
        id: a.id,
        credit_lot_id: l.id,
        amount_cents: a.amount_cents,
        expires_on: l.expires_on
      }
    )
  end

  # Rounds value * percentage / 100 to the nearest cent; an exact half-cent
  # rounds upward.
  @doc false
  def percentage_half_up(value, percentage) do
    div(2 * value * percentage + 100, 200)
  end

  defp total(query) do
    query
    |> Repo.one()
    |> integer_value()
  end

  defp integer_value(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(nil), do: 0
end
