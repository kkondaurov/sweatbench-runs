defmodule GroupStay.Deposits do
  @moduledoc """
  Applies partner operations to group deposits and reports finance totals.

  `apply_in_transaction/1` must run inside a database transaction opened by
  the caller (see `GroupStay.Operations.Journal`), so domain changes commit in
  the same transaction as the operation's durable record. Handled rejections
  leave all group deposit state unchanged.

  Deposit accounting is room-level: cash and hotel credit fund active rooms in
  their original order, filling one room's deposit before moving to the next.
  Funding is attributed to the operation that created it through cash
  allocations and credit applications, so individual payments can later be
  reduced, charged back, or reconciled without touching anyone else's money.
  """

  import Ecto.Query

  alias GroupStay.Deposits.CashAllocation
  alias GroupStay.Deposits.CreditApplication
  alias GroupStay.Deposits.CreditLot
  alias GroupStay.Deposits.CreditLotContribution
  alias GroupStay.Deposits.Group
  alias GroupStay.Deposits.LedgerEntry
  alias GroupStay.Deposits.PaymentCashDisposition
  alias GroupStay.Deposits.Room
  alias GroupStay.Operations
  alias GroupStay.Operations.Record
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
          | :operation_not_found
          | :payment_not_reducible
          | :reduction_exceeds_held_cash
          | :payment_not_chargeable
          | :payment_not_reconcilable
          | :invalid_transfer
          | :transfer_exceeds_held_funding
          | :transfer_exceeds_outstanding

  @doc """
  Applies one parsed operation and returns the fields reported to the partner.

  Runs inside the caller's database transaction. Errors are plain codes except
  `{:error, {:stale_revision, group_id, expected, actual}}`, which carries the
  identifiers and revisions required by the API document.
  """
  @spec apply_in_transaction(Operations.Operation.t()) ::
          {:ok, map()}
          | {:error, error()}
          | {:error, {:stale_revision, String.t(), pos_integer(), pos_integer()}}
  def apply_in_transaction(%Operations.Operation{} = op) do
    dispatch(op)
  end

  @doc """
  Returns a group by its partner-supplied identifier, or nil.
  """
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(group_id) do
    rooms_query = from(r in Room, order_by: r.position)

    Repo.one(
      from(g in Group,
        where: g.group_id == ^group_id,
        preload: [rooms: ^rooms_query]
      )
    )
  end

  @doc """
  Attaches the current cash and credit holdings to each room of `group` so
  views can report room-level accounting.
  """
  @spec with_room_accounting(Group.t()) :: Group.t()
  def with_room_accounting(%Group{} = group) do
    cash = cash_paid_by_room(group.id)
    credit = credit_paid_by_room(group.id)

    rooms =
      Enum.map(group.rooms, fn room ->
        struct(room,
          cash_paid_cents: Map.get(cash, room.id, 0),
          credit_paid_cents: Map.get(credit, room.id, 0)
        )
      end)

    %{group | rooms: rooms}
  end

  @doc """
  Lodging, deposit-due, paid, and outstanding totals describing the group's
  active rooms only.
  """
  @spec group_totals(Group.t()) :: %{
          lodging_total_cents: non_neg_integer(),
          deposit_due_cents: non_neg_integer(),
          cash_paid_cents: non_neg_integer(),
          credit_paid_cents: non_neg_integer(),
          deposit_paid_cents: non_neg_integer(),
          outstanding_deposit_cents: non_neg_integer()
        }
  def group_totals(%Group{status: "active"} = group) do
    rooms = active_room_rows(group.id)
    cash = cash_paid_by_room(group.id)
    credit = credit_paid_by_room(group.id)

    lodging_total = rooms |> Enum.map(&(&1.lodging_amount_cents || 0)) |> Enum.sum()
    due_total = rooms |> Enum.map(&(&1.deposit_due_cents || 0)) |> Enum.sum()

    cash_total =
      rooms |> Enum.map(&Map.get(cash, &1.id, 0)) |> Enum.sum()

    credit_total =
      rooms |> Enum.map(&Map.get(credit, &1.id, 0)) |> Enum.sum()

    %{
      lodging_total_cents: lodging_total,
      deposit_due_cents: due_total,
      cash_paid_cents: cash_total,
      credit_paid_cents: credit_total,
      deposit_paid_cents: cash_total + credit_total,
      outstanding_deposit_cents: max(due_total - cash_total - credit_total, 0)
    }
  end

  def group_totals(%Group{}) do
    %{
      lodging_total_cents: 0,
      deposit_due_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      deposit_paid_cents: 0,
      outstanding_deposit_cents: 0
    }
  end

  @doc """
  Returns cash currently held plus lifetime refunded, retained,
  cash-converted-to-credit, reduced, and charged-back totals, the outstanding
  credit liability as of `on` (defaults to the current UTC date), and the
  current credit shortfall.

  Held cash is the cash allocated to active rooms right now. The liability
  includes both available credit and credit currently applied to active
  groups, where expiry is paused while the credit funds a group.
  """
  @spec ledger_totals(Date.t()) :: %{
          cash_held_cents: non_neg_integer(),
          cash_refunded_cents: non_neg_integer(),
          cash_retained_cents: non_neg_integer(),
          cash_converted_to_credit_cents: non_neg_integer(),
          cash_reduced_cents: non_neg_integer(),
          cash_charged_back_cents: non_neg_integer(),
          credit_liability_cents: non_neg_integer(),
          credit_shortfall_cents: non_neg_integer()
        }
  def ledger_totals(on \\ Date.utc_today()) do
    %{
      cash_held_cents: total(from(a in CashAllocation, select: coalesce(sum(a.amount_cents), 0))),
      cash_refunded_cents: kind_total("refund"),
      cash_retained_cents: kind_total("retain"),
      cash_converted_to_credit_cents: kind_total("convert_to_credit"),
      cash_reduced_cents: kind_total("reduce_cash"),
      cash_charged_back_cents: kind_total("charge_back_cash"),
      credit_liability_cents: credit_liability(on),
      credit_shortfall_cents: credit_shortfall()
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

  @doc """
  The current disposition of cash from one durably recorded cash payment.

  Every amount is read live; reading never changes state. The six disposition
  fields always sum exactly to the originally recorded amount. Once any of the
  payment's funding has participated in a transfer, the statement also breaks
  its held cash down by group.
  """
  @spec payment_statement(String.t()) ::
          {:ok, map()} | {:error, :operation_not_found | :payment_not_reconcilable}
  def payment_statement(payment_operation_id) do
    with {:ok, record, result} <-
           lookup_applied_payment(payment_operation_id, :payment_not_reconcilable) do
      disposition = get_disposition(record.operation_id)

      statement = %{
        payment_operation_id: record.operation_id,
        original_group_id: result["group_id"],
        recorded_cents: result["amount_cents"],
        held_cents: held_cash(record.operation_id),
        refunded_cents: disposition.refunded_cents,
        retained_cents: disposition.retained_cents,
        converted_to_credit_cents: disposition.converted_cents,
        reduced_cents: disposition.reduced_cents,
        charged_back_cents: disposition.charged_back_cents
      }

      {:ok,
       if disposition.participated_in_transfer do
         Map.put(statement, :held_by_group, held_cash_by_group(record.operation_id))
       else
         statement
       end}
    end
  end

  # Held cash of one payment broken down by currently holding group, ordered
  # by group identifier and omitting groups with no held cash. Its amounts sum
  # to the payment's `held_cents`.
  defp held_cash_by_group(payment_operation_id) do
    from(a in CashAllocation,
      join: g in Group,
      on: g.id == a.group_id,
      where: a.operation_id == ^payment_operation_id,
      select: {g.group_id, a.amount_cents}
    )
    |> Repo.all()
    |> Enum.group_by(fn {group_id, _amount} -> group_id end, fn {_group_id, amount} -> amount end)
    |> Enum.map(fn {group_id, amounts} ->
      %{group_id: group_id, amount_cents: Enum.sum(amounts)}
    end)
    |> Enum.sort_by(& &1.group_id)
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

  # A lot's shortfall is the lesser of its unrecovered clawback and the credit
  # from that lot still applied to active groups.
  defp credit_shortfall do
    applied =
      from(a in CreditApplication,
        join: g in assoc(a, :group),
        where: g.status == "active",
        select: {a.credit_lot_id, coalesce(sum(a.amount_cents), 0)},
        group_by: a.credit_lot_id
      )
      |> Repo.all()
      |> Map.new()

    from(l in CreditLot,
      where: l.unrecovered_clawback_cents > 0,
      select: {l.id, l.unrecovered_clawback_cents}
    )
    |> Repo.all()
    |> Enum.reduce(0, fn {lot_id, unrecovered}, acc ->
      acc + min(unrecovered, Map.get(applied, lot_id, 0))
    end)
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

  defp dispatch(%Operations.Operation{type: :cancel_rooms} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group),
         {:ok, rooms} <- validate_room_selection(group, op.room_ids),
         :ok <- check_refund_method(group, op) do
      cancel_selected_rooms(group, rooms, op)
    end
  end

  defp dispatch(%Operations.Operation{type: :reduce_cash_payment} = op) do
    with {:ok, record, result} <-
           lookup_applied_payment(op.payment_operation_id, :payment_not_reducible),
         {:ok, group} <- fetch_group(result["group_id"]),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_reduction_against_held(record.operation_id, op.amount_cents) do
      reduce_cash(record, group, op)
    end
  end

  defp dispatch(%Operations.Operation{type: :charge_back_payment} = op) do
    with {:ok, record, result} <-
           lookup_applied_payment(op.payment_operation_id, :payment_not_chargeable),
         {:ok, group} <- fetch_group(result["group_id"]),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_chargeable(record.operation_id, result) do
      charge_back(record, group, op)
    end
  end

  defp dispatch(%Operations.Operation{type: :transfer_deposit} = op) do
    # Source existence resolves first, then destination existence; only after
    # both groups exist are the two revision guards and finally the transfer
    # rules evaluated.
    with {:ok, source} <- fetch_transfer_group(op.source_group_id),
         {:ok, destination} <- fetch_transfer_group(op.destination_group_id),
         :ok <- check_revision(source, op.expected_revision),
         :ok <- check_revision(destination, op.destination_expected_revision),
         :ok <- check_transfer(source, destination, op.amount_cents) do
      transfer_deposit(source, destination, op)
    end
  end

  # Transfer rejections carry the offending group's partner identifier.
  defp fetch_transfer_group(group_id) do
    case get_group(group_id) do
      nil -> {:error, {:group_not_found, group_id}}
      group -> {:ok, group}
    end
  end

  defp check_transfer(source, destination, amount_cents) do
    cond do
      source.id == destination.id or source.guest_id != destination.guest_id ->
        {:error, :invalid_transfer}

      source.status != "active" ->
        {:error, {:group_not_active, source.group_id}}

      destination.status != "active" ->
        {:error, {:group_not_active, destination.group_id}}

      not usable_amount?(amount_cents) ->
        {:error, :invalid_amount}

      held_funding(source) < amount_cents ->
        {:error, :transfer_exceeds_held_funding}

      outstanding_deposit(destination) < amount_cents ->
        {:error, :transfer_exceeds_outstanding}

      true ->
        :ok
    end
  end

  defp usable_amount?(value), do: is_integer(value) and value > 0

  # Resolves the durable record for a payment identifier. Anything other than
  # an applied cash payment surfaces as `ineligible_code` for whichever
  # operation asked.
  defp lookup_applied_payment(payment_operation_id, ineligible_code) do
    case Repo.get_by(Record, operation_id: payment_operation_id) do
      nil ->
        {:error, :operation_not_found}

      record ->
        result = Jason.decode!(record.result)

        if record.type == "record_cash_payment" and result["status"] == "applied" do
          {:ok, record, result}
        else
          {:error, ineligible_code}
        end
    end
  end

  ## Opening a group

  defp group_exists?(group_id) do
    Repo.exists?(from(g in Group, where: g.group_id == ^group_id))
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
        |> room_attrs(nights, op.rate_plan)
        |> Map.put(:position, position)
      end)

    lodging_total = rooms |> Enum.map(& &1.lodging_amount_cents) |> Enum.sum()
    deposit_due = rooms |> Enum.map(& &1.deposit_due_cents) |> Enum.sum()

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
           deposit_due_cents: deposit_due,
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

  # Each flexible room's deposit is calculated and rounded separately before
  # the room deposits are summed; an advance-purchase room requires its full
  # lodging amount. Both amounts stay on the room forever afterwards.
  defp room_attrs(room, nights, rate_plan) do
    lodging_amount = nights * room.nightly_rate_cents

    deposit_due =
      case rate_plan do
        "flexible" -> percentage_half_up(lodging_amount, @flexible_deposit_percentage)
        "advance_purchase" -> lodging_amount
      end

    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_amount_cents: lodging_amount,
      deposit_due_cents: deposit_due,
      status: "active"
    }
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
    fund_rooms_with_cash!(group.id, op.operation_id, op.amount_cents)

    updated = bump_revision(group)

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

  ## Cancelling groups and rooms

  # Hotel credit is not a way around a non-refundable policy; requesting it
  # for a non-refundable cancellation rejects the whole operation and leaves
  # the group untouched.
  defp check_refund_method(group, op) do
    if op.refund_method == :hotel_credit and not refundable?(group, op.occurred_on) do
      {:error, :refund_method_not_available}
    else
      :ok
    end
  end

  # All supplied identifiers must name distinct, active rooms of the group.
  defp validate_room_selection(_group, []), do: {:error, :invalid_rooms}

  defp validate_room_selection(group, room_ids) do
    unique_ids = Enum.uniq(room_ids)
    by_room_id = Map.new(group.rooms, fn room -> {room.room_id, room} end)

    distinct_and_active? =
      length(unique_ids) == length(room_ids) and
        Enum.all?(unique_ids, fn room_id ->
          case Map.get(by_room_id, room_id) do
            %Room{status: "active"} -> true
            _other -> false
          end
        end)

    if distinct_and_active? do
      rooms =
        unique_ids
        |> Enum.map(&Map.fetch!(by_room_id, &1))
        |> Enum.sort_by(& &1.position)

      {:ok, rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp cancel(group, op) do
    rooms = active_room_rows(group.id)
    {summary, updated} = settle_rooms(group, rooms, op)

    {:ok,
     %{
       group_id: updated.group_id,
       refunded_cents: summary.refunded,
       retained_cents: summary.retained,
       credit_issued_cents: summary.credit_issued,
       revision: updated.revision
     }}
  end

  defp cancel_selected_rooms(group, rooms, op) do
    {summary, updated} = settle_rooms(group, rooms, op)

    {:ok,
     %{
       group_id: updated.group_id,
       cancelled_room_ids: summary.cancelled_room_ids,
       refunded_cents: summary.refunded,
       retained_cents: summary.retained,
       credit_issued_cents: summary.credit_issued,
       revision: updated.revision
     }}
  end

  # Settles the selected rooms exactly like a full cancellation would settle
  # them: same date, policy, refund method, bonus, and restoration rules.
  # Rooms outside the selection keep their allocations untouched.
  defp settle_rooms(group, rooms, op) do
    room_ids = Enum.map(rooms, & &1.id)
    chunks = cash_chunks_on_rooms(room_ids)
    applications = credit_applications_on_rooms(room_ids)

    {refunded, retained, credit_issued} =
      cond do
        refundable?(group, op.occurred_on) and op.refund_method == :hotel_credit ->
          restore_applications(applications, op.occurred_on)
          {0, 0, convert_cash_to_credit(group, chunks, op)}

        refundable?(group, op.occurred_on) ->
          restore_applications(applications, op.occurred_on)
          settle_cash(chunks, group, op, "refund", :refunded)
          {chunk_total(chunks), 0, 0}

        true ->
          consume_applications(applications)
          settle_cash(chunks, group, op, "retain", :retained)
          {0, chunk_total(chunks), 0}
      end

    Repo.update_all(from(r in Room, where: r.id in ^room_ids), set: [status: "cancelled"])

    # The settled cash has moved to refunded, retained, or converted; its
    # allocations no longer hold anything.
    Repo.delete_all(from(a in CashAllocation, where: a.room_id in ^room_ids))

    rooms_remaining? =
      Repo.exists?(from(r in Room, where: r.group_id == ^group.id and r.status == "active"))

    group_attrs =
      if rooms_remaining? do
        %{revision: group.revision + 1}
      else
        %{revision: group.revision + 1, status: "cancelled"}
      end

    updated = group |> Group.update_changeset(group_attrs) |> Repo.update!()

    %{
      refunded: refunded,
      retained: retained,
      credit_issued: credit_issued,
      cancelled_room_ids: rooms |> Enum.sort_by(& &1.position) |> Enum.map(& &1.room_id)
    }
    |> then(&{&1, updated})
  end

  defp settle_cash([], _group, _op, _kind, _bucket), do: :ok

  defp settle_cash(chunks, group, op, kind, bucket) do
    total = chunk_total(chunks)

    {:ok, _entry} = insert_entry(group, kind, total, op.occurred_on, op.operation_id)

    chunks
    |> Enum.reject(&(&1.operation_id == nil))
    |> Enum.group_by(& &1.operation_id)
    |> Enum.each(fn {payment_operation_id, payment_chunks} ->
      add_disposition(payment_operation_id, bucket, chunk_total(payment_chunks))
    end)
  end

  # The cash-funded portion becomes a credit lot worth 110% of that cash (the
  # 10% bonus uses the standard rounding rule) and leaves cash_held for the
  # cumulative converted total. The lot is available through 365 days after
  # cancellation and expires the following day.
  defp convert_cash_to_credit(group, chunks, op) do
    total = chunk_total(chunks)

    if total > 0 do
      issued = total + percentage_half_up(total, @credit_bonus_percentage)

      {:ok, lot} =
        Repo.insert(
          CreditLot.changeset(%CreditLot{}, %{
            guest_id: group.guest_id,
            source_operation_id: op.operation_id,
            issued_cents: issued,
            remaining_cents: issued,
            expires_on: Date.add(op.occurred_on, @credit_available_days + 1)
          })
        )

      record_contributions!(lot.id, chunks)

      {:ok, _entry} =
        insert_entry(group, "convert_to_credit", total, op.occurred_on, op.operation_id)

      chunks
      |> Enum.reject(&(&1.operation_id == nil))
      |> Enum.group_by(& &1.operation_id)
      |> Enum.each(fn {payment_operation_id, payment_chunks} ->
        add_disposition(payment_operation_id, :converted, chunk_total(payment_chunks))
      end)

      issued
    else
      0
    end
  end

  # Each contributor's entitlement is the bonus-inclusive value of settled cash
  # through that payment minus the value through the preceding one, so the
  # shares telescope exactly onto the issued lot. Legacy cash participates in
  # the running totals but has no durable identity to claw back.
  defp record_contributions!(lot_id, chunks) do
    Enum.reduce(Enum.sort_by(chunks, & &1.fill_seq), {0, 0}, fn chunk, {running, prev_value} ->
      running = running + chunk.amount_cents
      value = bonus_value(running)
      entitlement = value - prev_value

      if entitlement > 0 do
        {:ok, _contribution} =
          Repo.insert(
            CreditLotContribution.changeset(%CreditLotContribution{}, %{
              credit_lot_id: lot_id,
              operation_id: chunk.operation_id,
              entitlement_cents: entitlement
            })
          )
      end

      {running, value}
    end)

    :ok
  end

  # The bonus-inclusive credit value of an amount of cash: the cash plus its
  # standard half-up rounded 10% bonus.
  defp bonus_value(amount) do
    amount + percentage_half_up(amount, @credit_bonus_percentage)
  end

  # Applied credit returns to its original lots with their original expiry. If
  # a lot carries an unrecovered clawback, the returning amount extinguishes it
  # before anything becomes available; only an excess follows the normal expiry
  # rule, and a restoration absorbed by a shortfalled lot reduces liability.
  defp restore_applications(applications, cancelled_on) do
    Enum.each(applications, &Repo.delete!/1)

    applications
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {_lot_id, lot_applications} ->
      lot = hd(lot_applications).credit_lot
      returning = Enum.sum(Enum.map(lot_applications, & &1.amount_cents))

      absorb = min(returning, lot.unrecovered_clawback_cents)
      restored = returning - absorb

      unexpired? = Date.compare(lot.expires_on, cancelled_on) == :gt

      lot_attrs =
        if unexpired? and restored > 0 do
          %{
            remaining_cents: lot.remaining_cents + restored,
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorb
          }
        else
          %{unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorb}
        end

      lot
      |> CreditLot.update_changeset(lot_attrs)
      |> Repo.update!()
    end)
  end

  # A non-refundable cancellation consumes the applied credit; any shortfall on
  # its lots resolves itself because the credit is no longer applied.
  defp consume_applications(applications) do
    Enum.each(applications, &Repo.delete!/1)
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

  defp apply_credit(group, op, lot_allocations) do
    _final_state =
      Enum.reduce(lot_allocations, new_allocation_state(group.id), fn allocation, state ->
        {pieces, state} = take_pieces(state, allocation.amount_cents)

        Enum.each(pieces, fn piece ->
          {:ok, _application} =
            Repo.insert(
              CreditApplication.changeset(%CreditApplication{}, %{
                group_id: group.id,
                credit_lot_id: allocation.lot.id,
                room_id: piece.room_id,
                amount_cents: piece.amount_cents,
                fill_seq: piece.fill_seq
              })
            )
        end)

        state
      end)

    Enum.each(lot_allocations, fn allocation ->
      allocation.lot
      |> CreditLot.update_changeset(%{
        remaining_cents: allocation.lot.remaining_cents - allocation.amount_cents
      })
      |> Repo.update!()
    end)

    updated = bump_revision(group)

    {:ok,
     %{
       group_id: group.group_id,
       amount_cents: op.amount_cents,
       outstanding_deposit_cents: outstanding_deposit(updated),
       revision: updated.revision
     }}
  end

  ## Reducing recorded cash

  defp check_reduction_against_held(payment_operation_id, amount_cents) do
    held = held_cash(payment_operation_id)

    cond do
      held <= 0 ->
        {:error, :payment_not_reducible}

      amount_cents > held ->
        {:error, :reduction_exceeds_held_cash}

      true ->
        :ok
    end
  end

  defp reduce_cash(record, group, op) do
    changed_group_ids = remove_held_cash(record.operation_id, op.amount_cents)

    add_disposition(record.operation_id, :reduced, op.amount_cents)

    {:ok, _entry} =
      insert_entry(group, "reduce_cash", op.amount_cents, op.occurred_on, op.operation_id)

    # An applied operation increments the revision of every group whose state
    # it changes, and always the group it is addressed to.
    bump_other_changed_groups(changed_group_ids, group)

    updated = bump_revision(group)

    {:ok,
     %{
       payment_operation_id: record.operation_id,
       group_id: group.group_id,
       amount_cents: op.amount_cents,
       outstanding_deposit_cents: outstanding_deposit(updated),
       revision: updated.revision
     }}
  end

  # Groups other than the addressed one whose holdings the operation changed
  # still increment their revisions even though they are not guarded by it.
  defp bump_other_changed_groups(changed_group_ids, addressed_group) do
    changed_group_ids
    |> Enum.reject(&(&1 == addressed_group.id))
    |> Enum.each(fn group_id ->
      bump_revision(Repo.get!(Group, group_id))
    end)

    :ok
  end

  ## Charging back a payment

  defp check_chargeable(payment_operation_id, _result) do
    disposition = get_disposition(payment_operation_id)
    held = held_cash(payment_operation_id)

    unsettled =
      held +
        disposition.refunded_cents +
        disposition.retained_cents +
        disposition.converted_cents

    if disposition.charged_back_cents > 0 or unsettled <= 0 do
      {:error, :payment_not_chargeable}
    else
      :ok
    end
  end

  defp charge_back(record, group, op) do
    disposition = ensure_disposition(record.operation_id)
    held = held_cash(record.operation_id)

    total =
      held +
        disposition.refunded_cents +
        disposition.retained_cents +
        disposition.converted_cents

    remove_held_cash(record.operation_id, held)
    |> bump_other_changed_groups(group)

    revoke_entitlements!(record.operation_id)

    disposition
    |> PaymentCashDisposition.changeset(%{
      refunded_cents: 0,
      retained_cents: 0,
      converted_cents: 0,
      charged_back_cents: disposition.charged_back_cents + total
    })
    |> Repo.update!()

    {:ok, _entry} =
      insert_entry(group, "charge_back_cash", total, op.occurred_on, op.operation_id)

    updated = bump_revision(group)

    {:ok,
     %{
       payment_operation_id: record.operation_id,
       group_id: group.group_id,
       charged_back_cents: total,
       outstanding_deposit_cents: outstanding_deposit(updated),
       revision: updated.revision
     }}
  end

  # Revokes every entitlement the payment created when its cash was converted:
  # whatever the lot can still pay comes off its balance, the remainder becomes
  # the lot's unrecovered clawback.
  defp revoke_entitlements!(payment_operation_id) do
    contributions =
      Repo.all(from(c in CreditLotContribution, where: c.operation_id == ^payment_operation_id))

    Enum.each(contributions, &Repo.delete!/1)

    contributions
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {_lot_id, lot_contributions} ->
      lot = Repo.get!(CreditLot, hd(lot_contributions).credit_lot_id)

      entitlement =
        lot_contributions |> Enum.map(& &1.entitlement_cents) |> Enum.sum()

      recovered = min(entitlement, lot.remaining_cents)

      lot
      |> CreditLot.update_changeset(%{
        remaining_cents: lot.remaining_cents - recovered,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + entitlement - recovered
      })
      |> Repo.update!()
    end)
  end

  ## Transferring held funding

  # Moves held funding between two active groups of the same guest without
  # moving money through a provider. Nothing settles or revalues: no credit
  # bonus, no resumed expiry, no ledger total changes. Only the active rooms
  # holding the funding change, so both groups' revisions increment.
  defp transfer_deposit(source, destination, op) do
    amount = op.amount_cents

    {draws, moved_payment_ids} = draw_held_funding(source.id, amount)

    fill_destination_rooms!(destination.id, draws)
    mark_transferred_payments(moved_payment_ids)

    source_updated = bump_revision(source)
    destination_updated = bump_revision(destination)

    {:ok,
     %{
       source_group_id: source.group_id,
       destination_group_id: destination.group_id,
       amount_cents: amount,
       source_outstanding_deposit_cents: outstanding_deposit(source_updated),
       destination_outstanding_deposit_cents: outstanding_deposit(destination_updated),
       source_revision: source_updated.revision,
       destination_revision: destination_updated.revision
     }}
  end

  # Cash and hotel credit currently allocated to the group's active rooms.
  defp held_funding(group) do
    cash_on_active_rooms(group.id) + credit_on_active_rooms(group.id)
  end

  # Removes `amount` from the source's active-room allocations in reverse
  # allocation order (most recently created first), regardless of funding
  # kind. Returns the drawn units as `{kind, allocation, amount}` tuples in
  # draw order plus every payment whose cash participated.
  defp draw_held_funding(group_id, amount) do
    allocations =
      Enum.sort_by(
        cash_allocations_of_group(group_id) ++ credit_applications_of_group(group_id),
        fn {_kind, alloc} -> alloc.fill_seq end,
        :desc
      )

    {draws, _remaining} =
      Enum.reduce_while(allocations, {[], amount}, fn {kind, alloc}, {acc, remaining} ->
        if remaining <= 0 do
          {:halt, {acc, remaining}}
        else
          take = min(alloc.amount_cents, remaining)

          if take == alloc.amount_cents do
            Repo.delete!(alloc)
          else
            alloc
            |> reduce_allocation_amount(alloc.amount_cents - take)
            |> Repo.update!()
          end

          {:cont, {[{kind, alloc, take} | acc], remaining - take}}
        end
      end)

    moved_payment_ids =
      draws
      |> Enum.filter(fn {kind, _alloc, _take} -> kind == :cash end)
      |> Enum.map(fn {_kind, alloc, _take} -> alloc.operation_id end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {Enum.reverse(draws), moved_payment_ids}
  end

  defp cash_allocations_of_group(group_id) do
    Repo.all(
      from(a in CashAllocation,
        join: r in Room,
        on: r.id == a.room_id and r.status == "active",
        where: a.group_id == ^group_id,
        select: {:cash, a}
      )
    )
  end

  # Reduces an allocation's remaining amount regardless of its funding kind.
  defp reduce_allocation_amount(%CashAllocation{} = alloc, left),
    do: CashAllocation.update_changeset(alloc, %{amount_cents: left})

  defp reduce_allocation_amount(%CreditApplication{} = alloc, left),
    do: CreditApplication.update_changeset(alloc, %{amount_cents: left})

  defp credit_applications_of_group(group_id) do
    Repo.all(
      from(a in CreditApplication,
        join: r in Room,
        on: r.id == a.room_id and r.status == "active",
        where: a.group_id == ^group_id,
        select: {:credit, a}
      )
    )
  end

  defp cash_on_active_rooms(group_id) do
    integer_value(
      Repo.one(
        from(a in CashAllocation,
          join: r in Room,
          on: r.id == a.room_id and r.status == "active",
          where: a.group_id == ^group_id,
          select: coalesce(sum(a.amount_cents), 0)
        )
      )
    )
  end

  defp credit_on_active_rooms(group_id) do
    integer_value(
      Repo.one(
        from(a in CreditApplication,
          join: r in Room,
          on: r.id == a.room_id and r.status == "active",
          where: a.group_id == ^group_id,
          select: coalesce(sum(a.amount_cents), 0)
        )
      )
    )
  end

  # Fills the destination's active rooms in their original order with the
  # drawn units, keeping each unit's provenance: cash keeps its payment
  # operation identity and hotel credit keeps its original lot.
  defp fill_destination_rooms!(group_id, draws) do
    Enum.reduce(draws, new_allocation_state(group_id), fn {kind, alloc, take}, state ->
      {pieces, state} = take_pieces(state, take)

      Enum.each(pieces, fn piece ->
        case kind do
          :cash ->
            {:ok, _allocation} =
              Repo.insert(
                CashAllocation.changeset(%CashAllocation{}, %{
                  group_id: group_id,
                  room_id: piece.room_id,
                  operation_id: alloc.operation_id,
                  amount_cents: piece.amount_cents,
                  fill_seq: piece.fill_seq,
                  creation_seq: next_creation_seq()
                })
              )

          :credit ->
            {:ok, _application} =
              Repo.insert(
                CreditApplication.changeset(%CreditApplication{}, %{
                  group_id: group_id,
                  credit_lot_id: alloc.credit_lot_id,
                  room_id: piece.room_id,
                  amount_cents: piece.amount_cents,
                  fill_seq: piece.fill_seq
                })
              )
        end
      end)

      state
    end)

    :ok
  end

  # Once any funding from a cash payment has participated in a transfer its
  # statement evolves to break held cash down by group.
  defp mark_transferred_payments(payment_operation_ids) do
    Enum.each(payment_operation_ids, fn payment_operation_id ->
      disposition = ensure_disposition(payment_operation_id)

      disposition
      |> PaymentCashDisposition.changeset(%{participated_in_transfer: true})
      |> Repo.update!()
    end)

    :ok
  end

  ## Room allocation engine

  # Fills active rooms in their original order, one room's deposit before the
  # next. `fill_seq` values order every allocation of a group so reductions can
  # walk them backwards.
  defp new_allocation_state(group_id) do
    cash = cash_paid_by_room(group_id)
    credit = credit_paid_by_room(group_id)

    capacities =
      active_room_rows(group_id)
      |> Enum.map(fn room ->
        paid = Map.get(cash, room.id, 0) + Map.get(credit, room.id, 0)
        {room.id, max((room.deposit_due_cents || 0) - paid, 0)}
      end)

    %{capacities: capacities, next_seq: next_fill_seq(group_id)}
  end

  defp take_pieces(state, amount) do
    {pieces_rev, caps_rev, _left} =
      Enum.reduce(state.capacities, {[], [], amount}, fn {room_id, capacity},
                                                         {pieces, caps, remaining} ->
        take = capacity |> min(remaining) |> max(0)

        if take <= 0 do
          {pieces, [{room_id, capacity} | caps], remaining}
        else
          {[{room_id, take} | pieces], [{room_id, capacity - take} | caps], remaining - take}
        end
      end)

    pieces =
      pieces_rev
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {{room_id, take}, index} ->
        %{room_id: room_id, amount_cents: take, fill_seq: state.next_seq + index + 1}
      end)

    pieces_count = length(pieces)

    {pieces,
     %{state | capacities: Enum.reverse(caps_rev), next_seq: state.next_seq + pieces_count}}
  end

  defp fund_rooms_with_cash!(group_id, operation_id, amount_cents) do
    {pieces, _state} = take_pieces(new_allocation_state(group_id), amount_cents)

    Enum.each(pieces, fn piece ->
      {:ok, _allocation} =
        Repo.insert(
          CashAllocation.changeset(%CashAllocation{}, %{
            group_id: group_id,
            room_id: piece.room_id,
            operation_id: operation_id,
            amount_cents: piece.amount_cents,
            fill_seq: piece.fill_seq,
            creation_seq: next_creation_seq()
          })
        )
    end)

    :ok
  end

  # Creation order across all groups; SQLite's single-writer execution makes
  # max + 1 race-free inside the caller's transaction.
  defp next_creation_seq do
    Repo.one(from(a in CashAllocation, select: coalesce(max(a.creation_seq), 0))) + 1
  end

  defp next_fill_seq(group_id) do
    cash_max =
      Repo.one(
        from(a in CashAllocation,
          where: a.group_id == ^group_id,
          select: max(a.fill_seq)
        )
      ) || 0

    credit_max =
      Repo.one(
        from(a in CreditApplication,
          where: a.group_id == ^group_id,
          select: max(a.fill_seq)
        )
      ) || 0

    max(cash_max, credit_max)
  end

  defp cash_chunks_on_rooms(room_ids) do
    Repo.all(
      from(a in CashAllocation,
        where: a.room_id in ^room_ids,
        order_by: [asc: a.fill_seq]
      )
    )
  end

  defp credit_applications_on_rooms(room_ids) do
    Repo.all(
      from(a in CreditApplication,
        where: a.room_id in ^room_ids,
        join: l in assoc(a, :credit_lot),
        preload: [credit_lot: l]
      )
    )
  end

  defp chunk_total(chunks), do: Enum.sum(Enum.map(chunks, & &1.amount_cents))

  defp held_cash(payment_operation_id) do
    Repo.one(
      from(a in CashAllocation,
        where: a.operation_id == ^payment_operation_id,
        select: coalesce(sum(a.amount_cents), 0)
      )
    )
    |> integer_value()
  end

  # Removes up to `amount` of a payment's held allocations in reverse creation
  # order across all groups, partially removing the last-touched allocation
  # when needed. Returns the internal group ids whose holdings changed, so the
  # callers can increment every changed group's revision.
  defp remove_held_cash(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from(a in CashAllocation,
          where: a.operation_id == ^payment_operation_id,
          order_by: [desc: a.creation_seq]
        )
      )

    {affected_group_ids, _remaining} =
      Enum.reduce_while(allocations, {MapSet.new(), amount}, fn allocation,
                                                                {affected, remaining} ->
        if remaining <= 0 do
          {:halt, {affected, remaining}}
        else
          take = min(allocation.amount_cents, remaining)
          left = allocation.amount_cents - take

          if left > 0 do
            allocation
            |> CashAllocation.update_changeset(%{amount_cents: left})
            |> Repo.update!()
          else
            Repo.delete!(allocation)
          end

          {:cont, {MapSet.put(affected, allocation.group_id), remaining - take}}
        end
      end)

    MapSet.to_list(affected_group_ids)
  end

  defp cash_paid_by_room(group_id) do
    from(a in CashAllocation,
      where: a.group_id == ^group_id,
      select: {a.room_id, coalesce(sum(a.amount_cents), 0)},
      group_by: a.room_id
    )
    |> Repo.all()
    |> Map.new(fn {room_id, cents} -> {room_id, integer_value(cents)} end)
  end

  defp credit_paid_by_room(group_id) do
    from(a in CreditApplication,
      where: a.group_id == ^group_id,
      select: {a.room_id, coalesce(sum(a.amount_cents), 0)},
      group_by: a.room_id
    )
    |> Repo.all()
    |> Map.new(fn {room_id, cents} -> {room_id, integer_value(cents)} end)
  end

  defp active_room_rows(group_id) do
    Repo.all(
      from(r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: r.position
      )
    )
  end

  defp get_disposition(payment_operation_id) do
    Repo.get_by(PaymentCashDisposition, operation_id: payment_operation_id) ||
      %PaymentCashDisposition{
        operation_id: payment_operation_id,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0
      }
  end

  defp add_disposition(payment_operation_id, bucket, amount_cents) do
    disposition = ensure_disposition(payment_operation_id)

    updated_amounts =
      case bucket do
        :refunded ->
          %{refunded_cents: disposition.refunded_cents + amount_cents}

        :retained ->
          %{retained_cents: disposition.retained_cents + amount_cents}

        :converted ->
          %{converted_cents: disposition.converted_cents + amount_cents}

        :reduced ->
          %{reduced_cents: disposition.reduced_cents + amount_cents}
      end

    disposition
    |> PaymentCashDisposition.changeset(updated_amounts)
    |> Repo.update!()

    :ok
  end

  defp ensure_disposition(payment_operation_id) do
    case Repo.get_by(PaymentCashDisposition, operation_id: payment_operation_id) do
      nil ->
        Repo.insert!(
          PaymentCashDisposition.changeset(%PaymentCashDisposition{}, %{
            operation_id: payment_operation_id
          })
        )

      disposition ->
        disposition
    end
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
      {:error, {:stale_revision, group.group_id, expected_revision, group.revision}}
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
  requirements disappear when a group is cancelled, and cancelling rooms
  reopens whatever was due on the rooms that went away.
  """
  @spec outstanding_deposit(Group.t()) :: non_neg_integer()
  def outstanding_deposit(%Group{} = group) do
    group_totals(group).outstanding_deposit_cents
  end

  defp bump_revision(group) do
    group
    |> Group.update_changeset(%{revision: group.revision + 1})
    |> Repo.update!()
  end

  defp insert_entry(group, kind, amount_cents, occurred_on, operation_id) do
    Repo.insert(
      LedgerEntry.changeset(%LedgerEntry{}, %{
        group_id: group.id,
        kind: kind,
        amount_cents: amount_cents,
        occurred_on: occurred_on,
        operation_id: operation_id
      })
    )
  end

  # Rounds value * percentage / 100 to the nearest cent; an exact half-cent
  # rounds upward.
  @doc false
  def percentage_half_up(value, percentage) do
    div(2 * value * percentage + 100, 200)
  end

  defp kind_total(kind) do
    total(
      from(e in LedgerEntry,
        where: e.kind == ^kind,
        select: coalesce(sum(e.amount_cents), 0)
      )
    )
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
