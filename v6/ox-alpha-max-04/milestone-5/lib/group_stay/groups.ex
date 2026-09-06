defmodule GroupStay.Groups do
  @moduledoc """
  Group reservations: opening, funding, rescheduling, cancelling groups or
  selected rooms, applying hotel credit, moving held funding between groups,
  reducing recorded cash, and charging payments back, plus the deposit state
  each partner operation produces.

  Every function runs inside its own transaction when called directly and
  joins the caller's transaction when one is already open, so durable
  submission can commit an operation record in the same transaction as the
  domain changes. Transaction mode is `:immediate` so concurrent operations
  serialize on the single SQLite writer before reading a group, keeping the
  revision contract and at-most-once operation effects reliable.

  Rejections are returned as values, never as rollbacks: each function
  validates completely before its first write, so a handled rejection leaves
  no domain state behind. An applied operation increments the revision of
  every group whose state it changes, and always the group it is addressed
  to; reductions and chargebacks that reach funding now held by other groups
  therefore bump those groups as well.
  """

  import Ecto.Query

  alias GroupStay.Accounting
  alias GroupStay.Credit
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Policy
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  @credit_availability_days 365

  @type apply_result ::
          {:ok, map()}
          | {:error,
             :group_not_found
             | :group_not_active
             | :invalid_stay
             | :invalid_rooms
             | :invalid_rate_plan
             | :invalid_amount
             | :payment_exceeds_outstanding
             | :group_already_exists
             | :refund_method_not_available
             | :insufficient_credit
             | :operation_not_found
             | :payment_not_reducible
             | :payment_not_chargeable
             | :reduction_exceeds_held_cash
             | :invalid_transfer
             | :transfer_exceeds_held_funding
             | :transfer_exceeds_outstanding
             | {:group_not_found, String.t()}
             | {:group_not_active, String.t()}}
          | {:stale, String.t(), integer(), integer()}

  @doc """
  Opens a new group reservation. Returns `{:ok, result}` with `group_id`,
  `deposit_due_cents`, and `revision`, or `{:error, code}`.
  """
  @spec open_group(map()) :: apply_result()
  def open_group(attrs) do
    transaction(fn ->
      with :ok <- ensure_absent(attrs.group_id),
           {:ok, arrival, departure} <- stay_dates(attrs.arrival_on, attrs.departure_on),
           {:ok, rooms} <- valid_rooms(attrs.rooms),
           {:ok, rate_plan} <- known_rate_plan(attrs.rate_plan) do
        nights = Date.diff(departure, arrival)

        lodging_total =
          rooms
          |> Enum.map(&(&1.nightly_rate_cents * nights))
          |> Enum.sum()

        deposit_due =
          rooms
          |> Enum.map(&room_deposit(&1.nightly_rate_cents * nights, rate_plan))
          |> Enum.sum()

        group =
          %Group{}
          |> cast_group(%{
            group_id: attrs.group_id,
            guest_id: attrs.guest_id,
            property_id: attrs.property_id,
            booked_on: attrs.booked_on,
            arrival_on: arrival,
            departure_on: departure,
            rate_plan: rate_plan,
            policy_version: Policy.for_rate_plan(rate_plan, attrs.booked_on),
            lodging_total_cents: lodging_total,
            deposit_due_cents: deposit_due,
            revision: 1
          })
          |> Ecto.Changeset.put_assoc(
            :rooms,
            Enum.with_index(rooms, fn room, position ->
              %Room{
                room_id: room.room_id,
                nightly_rate_cents: room.nightly_rate_cents,
                position: position
              }
            end)
          )
          |> Repo.insert!()

        {:ok,
         %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         }}
      end
    end)
  end

  @doc """
  Applies cash to an active group's outstanding deposit. The cash funds the
  active rooms' deposits in their original order.
  """
  @spec record_cash_payment(map()) :: apply_result()
  def record_cash_payment(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, amount} <- payment_amount(params.amount_cents),
           world = Accounting.replay_all(),
           state = Accounting.group_state(world, group.group_id),
           :ok <- within_outstanding(state, amount) do
        new_paid = group.cash_paid_cents + amount
        new_revision = group.revision + 1

        group
        |> cast_group(%{cash_paid_cents: new_paid, revision: new_revision})
        |> Repo.update!()

        Ledger.record!(%{
          group_id: group.id,
          type: "cash_held",
          amount_cents: amount,
          occurred_on: params.occurred_on,
          operation_id: params.operation_id
        })

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: Accounting.active_outstanding(state) - amount,
           revision: new_revision
         }}
      end
    end)
  end

  @doc """
  Moves a group's stay to a new arrival date, shifting the departure by the
  same number of calendar days so the length and price of the stay do not
  change.
  """
  @spec reschedule_group(map()) :: apply_result()
  def reschedule_group(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, new_arrival} <- stay_date(params.new_arrival_on),
           :ok <- future_arrival(new_arrival, params.occurred_on) do
        shift = Date.diff(new_arrival, group.arrival_on)
        new_departure = Date.add(group.departure_on, shift)
        new_revision = group.revision + 1

        group
        |> cast_group(%{
          arrival_on: new_arrival,
          departure_on: new_departure,
          revision: new_revision
        })
        |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           new_arrival_on: new_arrival,
           new_departure_on: new_departure,
           policy_version: group.policy_version,
           refundable_until: Policy.refundable_until(group.policy_version, new_arrival),
           revision: new_revision
         }}
      end
    end)
  end

  @doc """
  Cancels a group and settles every remaining active room's deposit: cash is
  refunded, retained, or converted to hotel credit according to the group's
  fixed policy version, how far ahead cancellation happens, and the requested
  `refund_method`; applied hotel credit returns to its lots on a refundable
  cancellation and is consumed otherwise; and any unpaid deposit is no longer
  due. The group becomes cancelled.
  """
  @spec cancel_group(map()) :: apply_result()
  def cancel_group(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, refundable?} <- refund_available(group, params.refund_method, params.occurred_on),
           world = Accounting.replay_all(),
           state = Accounting.group_state(world, group.group_id),
           room_ids = Accounting.active_room_ids(state) do
        {settlement, new_revision} =
          settle_selected_rooms(group, state, room_ids, params, refundable?)

        {:ok,
         %{
           group_id: group.group_id,
           refunded_cents: settlement.refunded,
           retained_cents: settlement.retained,
           credit_issued_cents: settlement.credit_issued,
           revision: new_revision
         }}
      end
    end)
  end

  @doc """
  Cancels selected rooms of an active group and settles their allocated cash
  and credit with the same rules as a full cancellation. Every supplied room
  identifier must name a distinct active room of the group. If no active
  rooms remain the group becomes cancelled.
  """
  @spec cancel_rooms(map()) :: apply_result()
  def cancel_rooms(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, room_ids} <- cancellable_rooms(group, params.room_ids),
           {:ok, refundable?} <- refund_available(group, params.refund_method, params.occurred_on),
           world = Accounting.replay_all(),
           state = Accounting.group_state(world, group.group_id) do
        {settlement, new_revision} =
          settle_selected_rooms(group, state, room_ids, params, refundable?)

        {:ok,
         %{
           group_id: group.group_id,
           cancelled_room_ids: original_room_order(state, room_ids),
           refunded_cents: settlement.refunded,
           retained_cents: settlement.retained,
           credit_issued_cents: settlement.credit_issued,
           revision: new_revision
         }}
      end
    end)
  end

  @doc """
  Applies the group guest's hotel credit to an active group's outstanding
  deposit. Credit is consumed from the guest's unexpired lots by earliest
  expiry and then by source operation and funds the active rooms in their
  original order; while it funds a room its expiry is paused, until the room
  is settled.
  """
  @spec apply_hotel_credit(map()) :: apply_result()
  def apply_hotel_credit(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, amount} <- payment_amount(params.amount_cents),
           world = Accounting.replay_all(),
           state = Accounting.group_state(world, group.group_id),
           :ok <- within_outstanding(state, amount),
           {:ok, lot_takes} <- Credit.split_lots(group.guest_id, params.occurred_on, amount) do
        assigns = Accounting.place_credit(state, lot_takes)
        Credit.apply_assigns!(group.id, params.operation_id, assigns)

        new_revision = group.revision + 1

        group
        |> cast_group(%{revision: new_revision})
        |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: Accounting.active_outstanding(state) - amount,
           revision: new_revision
         }}
      end
    end)
  end

  @doc """
  Moves held funding - the cash and hotel credit currently allocated to the
  source's active rooms - from one active group to another of the same guest.
  The amount is drawn from the source's allocations in reverse allocation
  order, most recently created first, regardless of funding kind, and fills
  the destination's active rooms in their original order with the drawn units
  in the order they were drawn. Every moved allocation keeps its provenance:
  cash keeps its payment operation identity and hotel credit keeps its
  original lot. Nothing settles, revalues, or moves through a provider, and
  no ledger total changes.
  """
  @spec transfer_deposit(map()) :: apply_result()
  def transfer_deposit(params) do
    transaction(fn ->
      with {:ok, source} <- fetch_group(params.source_group_id, :tagged),
           {:ok, destination} <- fetch_group(params.destination_group_id, :tagged),
           :ok <- revision_guard(source, params.expected_revision),
           :ok <- revision_guard(destination, params.destination_expected_revision),
           :ok <- transferable_groups(source, destination),
           :ok <- active_group_guard(source),
           :ok <- active_group_guard(destination),
           {:ok, amount} <- payment_amount(params.amount_cents),
           world = Accounting.replay_all(),
           source_held = Accounting.held_funding(world, source.group_id),
           :ok <- within_held_funding(source_held, amount),
           destination_state = Accounting.group_state(world, destination.group_id),
           :ok <- within_outstanding(destination_state, amount, :transfer_exceeds_outstanding) do
        {units, world} = Accounting.carve_held_funding(world, source.group_id, amount)
        world = Accounting.fill_units(world, destination.group_id, units)

        cash_moved =
          units
          |> Enum.filter(&(&1.kind == :cash))
          |> Enum.reduce(0, &(&1.amount + &2))

        source_revision = source.revision + 1
        destination_revision = destination.revision + 1

        source
        |> cast_group(%{
          cash_paid_cents: source.cash_paid_cents - cash_moved,
          revision: source_revision
        })
        |> Repo.update!()

        destination
        |> cast_group(%{
          cash_paid_cents: destination.cash_paid_cents + cash_moved,
          revision: destination_revision
        })
        |> Repo.update!()

        {:ok,
         %{
           source_group_id: source.group_id,
           destination_group_id: destination.group_id,
           amount_cents: amount,
           source_outstanding_deposit_cents:
             Accounting.active_outstanding(Accounting.group_state(world, source.group_id)),
           destination_outstanding_deposit_cents:
             Accounting.active_outstanding(Accounting.group_state(world, destination.group_id)),
           source_revision: source_revision,
           destination_revision: destination_revision
         }}
      end
    end)
  end

  @doc """
  Records a provider correction against one durably recorded cash payment:
  removes the corrected amount of that payment's cash still held on active
  rooms - wherever those rooms are, in reverse allocation order across all
  groups - reopening the outstanding deposit of each holding group by the
  amount removed from it. The addressed group is the original payment's
  group.
  """
  @spec reduce_cash_payment(map()) :: apply_result()
  def reduce_cash_payment(params) do
    transaction(fn ->
      with {:ok, record} <- fetch_operation_record(params.payment_operation_id),
           {:ok, result} <- applied_result(record, :payment_not_reducible),
           {:ok, group} <- fetch_group(result["group_id"]),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- cash_payment_guard(record, :payment_not_reducible),
           world = Accounting.replay_all(),
           payment = Accounting.payment_state(world, params.payment_operation_id),
           {:ok, amount} <- payment_amount(params.amount_cents),
           :ok <- held_guard(payment.held, :payment_not_reducible),
           :ok <- within_held(payment.held, amount) do
        {carved_by_group, world} =
          Accounting.carve_payment(world, params.payment_operation_id, amount)

        new_revision = group.revision + 1

        group
        |> cast_group(%{
          cash_paid_cents: group.cash_paid_cents - Map.get(carved_by_group, group.group_id, 0),
          revision: new_revision
        })
        |> Repo.update!()

        bump_other_groups(carved_by_group, group.group_id)

        Ledger.record!(%{
          group_id: group.id,
          type: "cash_reduced",
          amount_cents: amount,
          occurred_on: params.occurred_on,
          operation_id: params.operation_id
        })

        {:ok,
         %{
           payment_operation_id: params.payment_operation_id,
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents:
             Accounting.active_outstanding(Accounting.group_state(world, group.group_id)),
           revision: new_revision
         }}
      end
    end)
  end

  @doc """
  Reverses all cash of one durably recorded cash payment except any portion
  already recorded as reduced: held allocations are removed in reverse
  allocation order across all groups - wherever the payment's cash currently
  funds rooms - refunded and retained portions move to charged-back cash, and
  converted principal moves to charged-back cash while its credit entitlement
  is revoked from the issuing lot. The addressed group is the original
  payment's group, and it may be active or cancelled.
  """
  @spec charge_back_payment(map()) :: apply_result()
  def charge_back_payment(params) do
    transaction(fn ->
      with {:ok, record} <- fetch_operation_record(params.payment_operation_id),
           {:ok, result} <- applied_result(record, :payment_not_chargeable),
           {:ok, group} <- fetch_group(result["group_id"]),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- cash_payment_guard(record, :payment_not_chargeable),
           world = Accounting.replay_all(),
           payment = Accounting.payment_state(world, params.payment_operation_id),
           :ok <- chargeable_guard(payment) do
        charged = payment.held + payment.refunded + payment.retained + payment.converted

        {carved_by_group, world} =
          Accounting.carve_payment(world, params.payment_operation_id, payment.held)

        new_revision = group.revision + 1

        group
        |> cast_group(%{
          cash_paid_cents: group.cash_paid_cents - Map.get(carved_by_group, group.group_id, 0),
          revision: new_revision
        })
        |> Repo.update!()

        bump_other_groups(carved_by_group, group.group_id)

        record_chargeback(group, payment, charged, params)
        revoke_entitlements!(world, params.payment_operation_id)

        {:ok,
         %{
           payment_operation_id: params.payment_operation_id,
           group_id: group.group_id,
           charged_back_cents: charged,
           outstanding_deposit_cents:
             Accounting.active_outstanding(Accounting.group_state(world, group.group_id)),
           revision: new_revision
         }}
      end
    end)
  end

  @doc """
  Returns a group with its rooms in their original order, or `nil` when no
  group carries that identifier.
  """
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(group_id) do
    case Repo.one(from g in Group, where: g.group_id == ^group_id) do
      nil ->
        nil

      group ->
        Repo.preload(group,
          rooms: from(r in Room, order_by: [asc: r.position]),
          credit_applications: []
        )
    end
  end

  ## Shared room settlement

  defp settle_selected_rooms(group, state, room_ids, params, refundable?) do
    refund_method = params.refund_method || "cash"
    room_db_ids = Accounting.room_db_ids(state, room_ids)
    settled_credit = Accounting.settled_room_credit(state, room_ids)

    cash_total =
      state
      |> Accounting.settled_room_cash(room_ids)
      |> Enum.reduce(0, &(&1.amount + &2))

    settlement =
      cond do
        refundable? and refund_method == "hotel_credit" ->
          Credit.settle_rooms_credit!(group.id, room_db_ids, settled_credit, :restore)
          converted = cash_total

          %{
            refunded: 0,
            retained: 0,
            converted: converted,
            credit_issued: issue_credit_lot!(group, converted, params)
          }

        refundable? ->
          Credit.settle_rooms_credit!(group.id, room_db_ids, settled_credit, :restore)

          %{refunded: cash_total, retained: 0, converted: 0, credit_issued: 0}

        true ->
          Credit.settle_rooms_credit!(group.id, room_db_ids, settled_credit, :consume)

          %{refunded: 0, retained: cash_total, converted: 0, credit_issued: 0}
      end

    new_revision = group.revision + 1
    remaining_active = length(Accounting.active_room_ids(state)) - length(room_ids)

    group_updates =
      if remaining_active == 0 do
        %{
          status: "cancelled",
          cash_paid_cents: 0,
          refunded_cents: group.refunded_cents + settlement.refunded,
          retained_cents: group.retained_cents + settlement.retained
        }
      else
        %{
          cash_paid_cents: group.cash_paid_cents - cash_total,
          refunded_cents: group.refunded_cents + settlement.refunded,
          retained_cents: group.retained_cents + settlement.retained
        }
      end

    group
    |> cast_group(Map.put(group_updates, :revision, new_revision))
    |> Repo.update!()

    if room_db_ids != [] do
      Repo.update_all(from(r in Room, where: r.id in ^room_db_ids), set: [status: "cancelled"])
    end

    record_settlement(group, settlement, params)

    {settlement, new_revision}
  end

  defp original_room_order(state, room_ids) do
    ids = MapSet.new(room_ids)
    for room <- state.rooms, MapSet.member?(ids, room.room_id), do: room.room_id
  end

  defp cancellable_rooms(group, room_ids) do
    well_formed? =
      is_list(room_ids) and room_ids != [] and
        Enum.all?(room_ids, &is_binary/1) and
        Enum.all?(room_ids, &(&1 != "")) and
        Enum.uniq(room_ids) == room_ids

    active_ids =
      Repo.all(from r in Room, where: r.group_id == ^group.id and r.status == "active")
      |> MapSet.new(& &1.room_id)

    if well_formed? and Enum.all?(room_ids, &MapSet.member?(active_ids, &1)) do
      {:ok, room_ids}
    else
      {:error, :invalid_rooms}
    end
  end

  ## Payment record resolution

  defp fetch_operation_record(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record}
    end
  end

  defp applied_result(record, error_code) do
    result = Jason.decode!(record.result)

    if result["status"] == "applied" do
      {:ok, result}
    else
      {:error, error_code}
    end
  end

  defp cash_payment_guard(%Record{type: "record_cash_payment"}, _error_code), do: :ok
  defp cash_payment_guard(_record, error_code), do: {:error, error_code}

  defp held_guard(held, _error_code) when held > 0, do: :ok
  defp held_guard(_held, error_code), do: {:error, error_code}

  defp within_held(held, amount) when amount <= held, do: :ok
  defp within_held(_held, _amount), do: {:error, :reduction_exceeds_held_cash}

  defp chargeable_guard(payment) do
    if payment.held + payment.refunded + payment.retained + payment.converted > 0 do
      :ok
    else
      {:error, :payment_not_chargeable}
    end
  end

  defp record_chargeback(group, payment, charged, params) do
    base = %{
      group_id: group.id,
      occurred_on: params.occurred_on,
      operation_id: params.operation_id
    }

    Ledger.record!(Map.merge(base, %{type: "cash_charged_back", amount_cents: charged}))

    if payment.refunded > 0 do
      Ledger.record!(Map.merge(base, %{type: "cash_refunded", amount_cents: -payment.refunded}))
    end

    if payment.retained > 0 do
      Ledger.record!(Map.merge(base, %{type: "cash_retained", amount_cents: -payment.retained}))
    end

    if payment.converted > 0 do
      Ledger.record!(
        Map.merge(base, %{type: "cash_converted_to_credit", amount_cents: -payment.converted})
      )
    end

    :ok
  end

  # Revokes the payment's credit entitlement from every lot it contributed to:
  # what cannot be removed from the lot's remaining balance becomes that lot's
  # unrecovered clawback.
  defp revoke_entitlements!(world, payment_operation_id) do
    Enum.each(Accounting.lot_segments(world), fn {lot_source_op_id, segments} ->
      entitlement = Accounting.entitlement(segments, payment_operation_id)

      if entitlement > 0 do
        lot = Repo.get_by!(Lot, source_operation_id: lot_source_op_id)
        removed = min(lot.remaining_cents, entitlement)

        lot
        |> Ecto.Changeset.change(%{
          remaining_cents: lot.remaining_cents - removed,
          clawback_unrecovered_cents: lot.clawback_unrecovered_cents + (entitlement - removed)
        })
        |> Repo.update!()
      end
    end)
  end

  # Every carved-from group changes state and so increments its revision,
  # adjusting its cash aggregate by the amount carved from it.
  defp bump_other_groups(carved_by_group, addressed_group_id) do
    carved_by_group
    |> Map.delete(addressed_group_id)
    |> Enum.each(fn {group_id, carved} ->
      group = Repo.get_by!(Group, group_id: group_id)

      group
      |> cast_group(%{
        cash_paid_cents: group.cash_paid_cents - carved,
        revision: group.revision + 1
      })
      |> Repo.update!()
    end)

    :ok
  end

  ## Transaction plumbing

  defp transaction(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, value} -> value
      {:error, reason} -> reason
    end
  end

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  # Existence failures that name the group they refer to.
  defp fetch_group(group_id, :tagged) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, {:group_not_found, group_id}}
      group -> {:ok, group}
    end
  end

  defp revision_guard(_group, nil), do: :ok

  defp revision_guard(group, expected_revision) do
    if expected_revision == group.revision do
      :ok
    else
      {:stale, group.group_id, expected_revision, group.revision}
    end
  end

  defp active_guard(group) do
    if group.status == "active", do: :ok, else: {:error, :group_not_active}
  end

  defp active_group_guard(group) do
    if group.status == "active", do: :ok, else: {:error, {:group_not_active, group.group_id}}
  end

  defp transferable_groups(source, destination) do
    if source.group_id == destination.group_id or source.guest_id != destination.guest_id do
      {:error, :invalid_transfer}
    else
      :ok
    end
  end

  defp ensure_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp stay_dates(arrival_on, departure_on) do
    with {:ok, arrival} <- stay_date(arrival_on),
         {:ok, departure} <- stay_date(departure_on),
         :ok <- at_least_one_night(arrival, departure) do
      {:ok, arrival, departure}
    end
  end

  defp stay_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, :invalid_stay}
    end
  end

  defp at_least_one_night(arrival, departure) do
    if Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp future_arrival(new_arrival, occurred_on) do
    if Date.compare(new_arrival, occurred_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp valid_rooms(rooms) do
    with {:ok, parsed} <- parse_rooms(rooms),
         :ok <- unique_room_ids(parsed) do
      {:ok, parsed}
    end
  end

  defp parse_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(rooms, {:ok, []}, fn room, {:ok, acc} ->
      case valid_room(room) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_rooms(_other), do: {:error, :invalid_rooms}

  defp valid_room(room) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate = room["nightly_rate_cents"]

    if is_binary(room_id) and room_id != "" and is_integer(nightly_rate) and nightly_rate > 0 do
      {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate}}
    else
      {:error, :invalid_rooms}
    end
  end

  defp valid_room(_other), do: {:error, :invalid_rooms}

  defp unique_room_ids(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)

    if Enum.uniq(room_ids) == room_ids, do: :ok, else: {:error, :invalid_rooms}
  end

  defp known_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: {:ok, rate_plan}, else: {:error, :invalid_rate_plan}
  end

  defp payment_amount(amount) do
    if is_integer(amount) and amount > 0, do: {:ok, amount}, else: {:error, :invalid_amount}
  end

  defp within_outstanding(state, amount, code \\ :payment_exceeds_outstanding) do
    if amount <= Accounting.active_outstanding(state) do
      :ok
    else
      {:error, code}
    end
  end

  defp within_held_funding(held, amount) when amount <= held, do: :ok
  defp within_held_funding(_held, _amount), do: {:error, :transfer_exceeds_held_funding}

  defp refund_available(group, refund_method, occurred_on) do
    refundable? = Policy.refundable?(group.policy_version, group.arrival_on, occurred_on)

    if not refundable? and refund_method == "hotel_credit" do
      {:error, :refund_method_not_available}
    else
      {:ok, refundable?}
    end
  end

  defp room_deposit(lodging, "flexible"),
    do: Accounting.percent_half_up(lodging, @flexible_deposit_percent)

  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp issue_credit_lot!(_group, 0, _params), do: 0

  defp issue_credit_lot!(group, cash, params) do
    value = cash + Accounting.percent_half_up(cash, @credit_bonus_percent)

    Credit.issue_lot!(%{
      guest_id: group.guest_id,
      source_operation_id: params.operation_id,
      remaining_cents: value,
      expires_on: Date.add(params.occurred_on, @credit_availability_days + 1)
    })

    value
  end

  defp record_settlement(_group, %{refunded: 0, retained: 0, converted: 0}, _params), do: :ok

  defp record_settlement(group, settlement, params) do
    base = %{
      group_id: group.id,
      occurred_on: params.occurred_on,
      operation_id: params.operation_id
    }

    if settlement.refunded > 0 do
      Ledger.record!(Map.merge(base, %{type: "cash_refunded", amount_cents: settlement.refunded}))
    end

    if settlement.retained > 0 do
      Ledger.record!(Map.merge(base, %{type: "cash_retained", amount_cents: settlement.retained}))
    end

    if settlement.converted > 0 do
      Ledger.record!(
        Map.merge(base, %{type: "cash_converted_to_credit", amount_cents: settlement.converted})
      )
    end

    :ok
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp cast_group(%Group{} = group, attrs) do
    Ecto.Changeset.cast(group, attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :cash_paid_cents,
      :refunded_cents,
      :retained_cents
    ])
  end
end
