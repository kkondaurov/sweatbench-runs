defmodule GroupStay.Groups do
  @moduledoc """
  Applies group reservation and deposit operations.

  Every public command is atomic: it runs in its own transaction unless the
  caller already opened one. Commands return one of:

    * `{:ok, result}` - the operation was applied;
    * `{:error, reason}` - the operation was rejected; `reason` is a stable
      rejection code atom.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.LotContribution
  alias GroupStay.Groups.PaymentDisposition
  alias GroupStay.Groups.PaymentSettlement
  alias GroupStay.Groups.Room
  alias GroupStay.Groups.RoomAllocation

  @rate_plans ~w(flexible advance_purchase)
  @deposit_percentage 20

  # Runs a command, opening a transaction only when none is already open, so
  # commands compose inside a caller's transaction. Rejections are signalled
  # with `throw` and converted back to `{:error, reason}` at the boundary;
  # when a transaction was opened here it is rolled back before returning.
  defp run_command(fun) do
    raw =
      try do
        if Repo.in_transaction?(), do: {:ok, fun.()}, else: Repo.transaction(fun)
      catch
        :throw, {:rejected, reason} -> {:error, {:rejected, reason}}
      end

    case raw do
      {:ok, value} -> {:ok, value}
      {:error, {:rejected, reason}} -> rejection(reason)
      {:error, reason} -> rejection(reason)
    end
  end

  defp reject(code), do: throw({:rejected, code})

  defp rejection({:stale_revision, details}), do: {:error, :stale_revision, details}
  # Rejections that carry extra result fields, such as the group a
  # group_not_active or stale revision refers to.
  defp rejection({code, details}) when is_list(details), do: {:error, code, details}
  defp rejection(code), do: {:error, code}

  @flex_14_window_days 14
  @flex_30_window_days 30
  # Flexible groups booked on this date or later use the longer window.
  @flex_30_boundary ~D[2027-01-01]
  @advance_policy_version "advance-nonrefundable"
  @credit_bonus_numerator 110
  @credit_lifetime_days 366

  def rate_plans, do: @rate_plans

  @doc """
  Returns a group by its partner identifier with rooms in their original
  order, or nil when the group does not exist.
  """
  def get_group(group_id) do
    Group
    |> where([g], g.group_id == ^group_id)
    |> preload(:rooms)
    |> Repo.one()
    |> case do
      %Group{} = group -> %{group | rooms: Enum.sort_by(group.rooms, & &1.position)}
      nil -> nil
    end
  end

  @doc """
  The cancellation policy version a group is locked into. It is derived from
  the group's rate plan and its original booking date only, so rescheduling
  never moves a group to a newer policy and groups created before this
  release keep the policy their booking date implies.
  """
  def policy_version(%Group{} = group) do
    {version, _window} = policy(group)
    version
  end

  @doc """
  The last cancellation date that is refundable for the group: its arrival
  minus its cancellation window. `nil` for non-refundable policies.
  """
  def refundable_until(%Group{} = group) do
    {_version, window} = policy(group)

    case window do
      nil -> nil
      days -> Date.add(group.arrival_on, -days)
    end
  end

  @doc """
  Opens a new group reservation at revision 1.
  """
  def open_group(attrs) do
    run_command(fn ->
      if Repo.exists?(from g in Group, where: g.group_id == ^attrs.group_id) do
        reject(:group_already_exists)
      else
        with :ok <- validate_stay(attrs.arrival_on, attrs.departure_on),
             :ok <- validate_rooms(attrs.rooms),
             :ok <- validate_rate_plan(attrs.rate_plan) do
          insert_group(attrs)
        end
      end
    end)
  end

  @doc """
  Records a cash payment against a group's outstanding deposit. The applied
  cash funds the active rooms in their original order, filling one room's
  deposit before moving to the next.
  """
  def record_cash_payment(group_id, amount_cents, expected_revision, operation_id) do
    run_command(fn ->
      with_group(group_id, expected_revision, fn group ->
        cond do
          group.status != "active" ->
            reject(:group_not_active)

          not usable_payment?(amount_cents) ->
            reject(:invalid_amount)

          amount_cents > outstanding_deposit_cents(group) ->
            reject(:payment_exceeds_outstanding)

          true ->
            allocate_funding!(group, [
              %{
                kind: "cash",
                source_operation_id: operation_id,
                credit_lot_id: nil,
                amount: amount_cents
              }
            ])

            ensure_disposition!(operation_id, group.group_id, amount_cents)

            update_group(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount_cents,
              cash_paid_cents: group.cash_paid_cents + amount_cents,
              revision: group.revision + 1
            })
        end
      end)
    end)
  end

  @doc """
  Moves a group's stay so it starts on `new_arrival_on`, shifting the
  departure date by the same number of days. The group keeps the policy
  version fixed when it was opened; only `refundable_until` is recomputed.
  """
  def reschedule_group(group_id, new_arrival_on, occurred_on, expected_revision) do
    run_command(fn ->
      with_group(group_id, expected_revision, fn group ->
        if group.status != "active" do
          reject(:group_not_active)
        else
          if valid_new_arrival?(new_arrival_on, occurred_on) do
            shift = Date.diff(group.departure_on, group.arrival_on)

            update_group(group, %{
              arrival_on: new_arrival_on,
              departure_on: Date.add(new_arrival_on, shift),
              revision: group.revision + 1
            })
          else
            reject(:invalid_stay)
          end
        end
      end)
    end)
  end

  @doc """
  Cancels a group and settles its remaining active rooms.

  A refundable cancellation refunds the cash or, with `refund_method:
  "hotel_credit"`, converts it to a credit lot worth 110% of the cash.
  Credit previously applied to the group always returns to its original
  lots without a second bonus. A non-refundable cancellation retains the
  cash and consumes any applied credit.

  Returns `{:ok, %{group: group, credit_issued_cents: cents}}`.
  """
  def cancel_group(group_id, occurred_on, expected_revision, refund_method, operation_id) do
    run_command(fn ->
      with_group(group_id, expected_revision, fn group ->
        cond do
          group.status != "active" ->
            reject(:group_not_active)

          refund_method == "hotel_credit" and not refundable?(group, occurred_on) ->
            reject(:refund_method_not_available)

          true ->
            settle_selected_rooms!(
              group,
              active_rooms(group),
              occurred_on,
              refundable?(group, occurred_on),
              refund_method: refund_method,
              operation_id: operation_id
            )
        end
      end)
    end)
  end

  @doc """
  Cancels selected rooms of an active group and settles their allocated cash
  and credit with the same rules as a full cancellation.

  All supplied identifiers must name distinct active rooms of the group;
  otherwise the whole operation is rejected with `invalid_rooms`. The bonus
  on a hotel-credit settlement is computed once on the selected rooms'
  combined cash. Unpaid deposit on the selected rooms ceases to be due;
  other rooms and their allocations are unchanged. When no active rooms
  remain the group itself becomes cancelled.
  """
  def cancel_rooms(
        group_id,
        room_ids,
        occurred_on,
        expected_revision,
        refund_method,
        operation_id
      ) do
    run_command(fn ->
      with_group(group_id, expected_revision, fn group ->
        cond do
          group.status != "active" ->
            reject(:group_not_active)

          refund_method == "hotel_credit" and not refundable?(group, occurred_on) ->
            reject(:refund_method_not_available)

          true ->
            case selected_active_rooms(group, room_ids) do
              rooms when is_list(rooms) and rooms != [] ->
                settle_selected_rooms!(group, rooms, occurred_on, refundable?(group, occurred_on),
                  refund_method: refund_method,
                  operation_id: operation_id
                )

              _ ->
                reject(:invalid_rooms)
            end
        end
      end)
    end)
  end

  @doc """
  Reduces a recorded cash payment by removing its still-held allocations in
  reverse allocation order across every group they currently fund. Each
  affected group's outstanding deposit reopens by what it lost.
  """
  def reduce_cash_payment(%{
        payment_operation_id: payment_operation_id,
        group_id: group_id,
        amount_cents: amount_cents,
        expected_revision: expected_revision
      }) do
    run_command(fn ->
      with_group(group_id, expected_revision, fn group ->
        held = held_cash_cents_all(payment_operation_id)

        cond do
          held <= 0 ->
            reject(:payment_not_reducible)

          not usable_payment?(amount_cents) ->
            reject(:invalid_amount)

          amount_cents > held ->
            reject(:reduction_exceeds_held_cash)

          true ->
            {_units, removed_by_group} =
              draw_segments!(
                Repo.all(
                  from a in RoomAllocation,
                    where:
                      a.kind == "cash" and a.source_operation_id == ^payment_operation_id,
                    order_by: [desc: a.id]
                ),
                amount_cents
              )

            bump_disposition!(
              require_disposition!(payment_operation_id),
              :reduced_cents,
              amount_cents
            )

            # The reduced classification stays on the payment's own group.
            group = update_group(group, %{cash_reduced_cents: group.cash_reduced_cents + amount_cents})

            %{group: apply_group_removals!(group, removed_by_group)}
        end
      end)
    end)
  end

  @doc """
  Charges back every remaining cent of one recorded cash payment except the
  portion already recorded as reduced.

  Held allocations are removed in reverse allocation order across every
  group they currently fund, refunded and retained portions move to
  charged-back cash on exactly the groups that booked them, and converted
  principal moves to charged-back cash while revoking the credit
  entitlement it created.
  """
  def charge_back_payment(%{
        payment_operation_id: payment_operation_id,
        group_id: group_id,
        expected_revision: expected_revision
      }) do
    run_command(fn ->
      with_group(group_id, expected_revision, fn group ->
        disposition = require_disposition!(payment_operation_id)

        chargeable =
          disposition.recorded_cents - disposition.reduced_cents - disposition.charged_back_cents

        if chargeable <= 0, do: reject(:payment_not_chargeable)

        {_units, removed_by_group} =
          draw_segments!(
            Repo.all(
              from a in RoomAllocation,
                where:
                  a.kind == "cash" and a.source_operation_id == ^payment_operation_id,
                order_by: [desc: a.id]
            ),
            held_cash_cents_all(payment_operation_id)
          )

        revert_settlements!(disposition, group)

        claw_back_converted_credit!(payment_operation_id)

        disposition
        |> Ecto.Changeset.change(%{
          refunded_cents: 0,
          retained_cents: 0,
          converted_cents: 0,
          charged_back_cents: disposition.charged_back_cents + chargeable
        })
        |> Repo.update!()

        # The charged-back classification is booked on the payment's own
        # group, which is always incremented once as the addressed group.
        removed_here = Map.get(removed_by_group, group.id, 0)

        group =
          update_group(group, %{
            cash_charged_back_cents: group.cash_charged_back_cents + chargeable,
            deposit_paid_cents: group.deposit_paid_cents - removed_here,
            cash_paid_cents: group.cash_paid_cents - removed_here,
            revision: group.revision + 1
          })

        Enum.each(removed_by_group, fn {group_db_id, cents} ->
          if group_db_id != group.id do
            other = Repo.get!(Group, group_db_id)

            update_group(other, %{
              deposit_paid_cents: other.deposit_paid_cents - cents,
              cash_paid_cents: other.cash_paid_cents - cents,
              revision: other.revision + 1
            })
          end
        end)

        %{group: Repo.reload!(get_group(group.group_id)), charged_back_cents: chargeable}
      end)
    end)
  end

  @doc """
  Moves applied deposit funding between two active groups of the same guest.

  `amount_cents` is drawn from the source group's active-room allocations in
  reverse allocation order regardless of funding kind and fills the
  destination's active rooms in their original order, preserving the order
  in which units were drawn. Every moved portion keeps its provenance: cash
  keeps its payment operation identity and hotel credit keeps its lot.

  A transfer settles and revalues nothing and changes no ledger total; it
  only changes which active rooms hold the funding.
  """
  def transfer_deposit(
        source_group_id,
        destination_group_id,
        amount_cents,
        source_expected_revision,
        destination_expected_revision
      ) do
    run_command(fn ->
      source = transfer_group!(source_group_id)
      destination = transfer_group!(destination_group_id)

      check_expected_revision(source, source_expected_revision) |> reject_on_error()
      check_expected_revision(destination, destination_expected_revision) |> reject_on_error()

      cond do
        source.id == destination.id or source.guest_id != destination.guest_id ->
          reject(:invalid_transfer)

        source.status != "active" ->
          reject({:group_not_active, group_id: source.group_id})

        destination.status != "active" ->
          reject({:group_not_active, group_id: destination.group_id})

        not usable_payment?(amount_cents) ->
          reject(:invalid_amount)

        held_funding_cents(source.id) < amount_cents ->
          reject(:transfer_exceeds_held_funding)

        outstanding_deposit_cents(destination) < amount_cents ->
          reject(:transfer_exceeds_outstanding)

        true ->
          {units, _removed_by_group} = draw_segments!(source_allocations_desc(source.id), amount_cents)

          mark_transfer_participation!(units)

          allocate_funding!(destination, units)

          cash_moved = units |> Enum.filter(&(&1.kind == "cash")) |> Enum.sum_by(& &1.amount)
          credit_moved = units |> Enum.filter(&(&1.kind == "credit")) |> Enum.sum_by(& &1.amount)

          source = bump_transfer_counters!(source, -amount_cents, -cash_moved, -credit_moved)

          destination =
            bump_transfer_counters!(destination, amount_cents, cash_moved, credit_moved)

          %{
            source: Repo.reload!(source),
            destination: Repo.reload!(destination),
            amount_cents: amount_cents
          }
      end
    end)
  end

  @doc """
  The current disposition of one recorded cash payment, or nil when no
  disposition exists for it. Reading never changes state.
  """
  def payment_statement(payment_operation_id) do
    case Repo.one(
           from d in PaymentDisposition,
             where: d.payment_operation_id == ^payment_operation_id
         ) do
      nil ->
        nil

      disposition ->
        other =
          disposition.refunded_cents + disposition.retained_cents + disposition.converted_cents +
            disposition.reduced_cents + disposition.charged_back_cents

        statement = %{
          payment_operation_id: disposition.payment_operation_id,
          original_group_id: disposition.group_id,
          recorded_cents: disposition.recorded_cents,
          held_cents: disposition.recorded_cents - other,
          refunded_cents: disposition.refunded_cents,
          retained_cents: disposition.retained_cents,
          converted_to_credit_cents: disposition.converted_cents,
          reduced_cents: disposition.reduced_cents,
          charged_back_cents: disposition.charged_back_cents
        }

        # Only payments whose cash ever participated in a transfer report
        # where their held cash sits; the amounts always sum to held_cents.
        if disposition.participated_in_transfer do
          Map.put(statement, :held_by_group, held_by_group(disposition.payment_operation_id))
        else
          statement
        end
    end
  end

  # Held cash of one payment grouped by the partner group that currently
  # holds it, ordered by group id. Groups without held cash are omitted.
  defp held_by_group(payment_operation_id) do
    from(a in RoomAllocation,
      join: g in Group,
      on: g.id == a.group_id,
      join: r in Room,
      on: r.id == a.room_id,
      where:
        a.kind == "cash" and a.source_operation_id == ^payment_operation_id and
          g.status == "active" and r.status == "active",
      group_by: g.group_id,
      order_by: g.group_id,
      select: {g.group_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Enum.filter(fn {_group_id, amount} -> amount > 0 end)
    |> Enum.map(fn {group_id, amount} -> %{group_id: group_id, amount_cents: amount} end)
  end

  @doc """
  Applies the guest's hotel credit to an active group's outstanding deposit.

  Lots are consumed by earliest expiry, then by source operation id. The
  applied amounts are remembered per room and lot so they can be restored if
  the rooms are later settled while refundable.
  """
  def apply_hotel_credit(group_id, amount_cents, occurred_on, expected_revision) do
    run_command(fn ->
      with_group(group_id, expected_revision, fn group ->
        cond do
          group.status != "active" ->
            reject(:group_not_active)

          not usable_payment?(amount_cents) ->
            reject(:invalid_amount)

          amount_cents > outstanding_deposit_cents(group) ->
            reject(:payment_exceeds_outstanding)

          available_credit_cents(group.guest_id, occurred_on) < amount_cents ->
            reject(:insufficient_credit)

          true ->
            entries =
              lot_takes(group.guest_id, amount_cents, occurred_on)
              |> Enum.map(fn {lot_id, cents} ->
                %{
                  kind: "credit",
                  source_operation_id: nil,
                  credit_lot_id: lot_id,
                  amount: cents
                }
              end)

            allocate_funding!(group, entries)

            update_group(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount_cents,
              credit_paid_cents: group.credit_paid_cents + amount_cents,
              revision: group.revision + 1
            })
        end
      end)
    end)
  end

  @doc """
  Cash totals across all groups plus the hotel credit liability and shortfall.

  Cash held is cash currently applied to active reservations. Cancellations
  move it to refunded, retained, or converted-to-credit. Provider
  corrections move recorded cash to reduced; chargebacks move it to
  charged-back. The credit liability covers both available credit and credit
  currently applied to active groups; expiry, non-refundable consumption,
  revoked entitlements and shortfall-absorbed restorations reduce it. The
  credit shortfall sums, per shortfalled lot, the portion of its
  unrecovered clawback covered by credit still applied to active groups.
  All expiry-sensitive totals are evaluated as of `on_date`.
  """
  def ledger_totals(on_date \\ default_on_date()) do
    held =
      from g in Group,
        where: g.status == "active",
        select: coalesce(sum(g.cash_paid_cents), 0)

    refunded = from g in Group, select: coalesce(sum(g.refunded_cents), 0)
    retained = from g in Group, select: coalesce(sum(g.retained_cents), 0)

    converted =
      from g in Group, select: coalesce(sum(g.cash_converted_to_credit_cents), 0)

    reduced = from g in Group, select: coalesce(sum(g.cash_reduced_cents), 0)
    charged_back = from g in Group, select: coalesce(sum(g.cash_charged_back_cents), 0)

    %{
      cash_held_cents: Repo.one(held),
      cash_refunded_cents: Repo.one(refunded),
      cash_retained_cents: Repo.one(retained),
      cash_reduced_cents: Repo.one(reduced),
      cash_charged_back_cents: Repo.one(charged_back),
      cash_converted_to_credit_cents: Repo.one(converted),
      credit_liability_cents: credit_liability_cents(on_date),
      credit_shortfall_cents: credit_shortfall_cents()
    }
  end

  @doc """
  A guest's available credit as of `on_date`: unexpired, unfunded portions
  of their lots, ordered by expiry then source operation id. Expired and
  exhausted lots are omitted.
  """
  def guest_credit(guest_id, on_date \\ default_on_date()) do
    lots =
      guest_id
      |> lot_states()
      |> Enum.sort_by(&{&1.expires_on, &1.source_operation_id})
      |> lot_availability(on_date)
      |> Enum.filter(&(&1.free_cents > 0))
      |> Enum.map(fn entry ->
        %{
          source_operation_id: entry.state.source_operation_id,
          remaining_cents: entry.free_cents,
          expires_on: entry.state.expires_on
        }
      end)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  @doc """
  The deposit still owed for a group. Unpaid deposit on a cancelled group is
  no longer due.
  """
  def outstanding_deposit_cents(%{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  def outstanding_deposit_cents(%Group{}), do: 0

  defp policy(%Group{rate_plan: "advance_purchase"}), do: {@advance_policy_version, nil}

  defp policy(%Group{rate_plan: "flexible", booked_on: booked_on}) do
    if Date.compare(booked_on, @flex_30_boundary) == :lt do
      {"flex-14", @flex_14_window_days}
    else
      {"flex-30", @flex_30_window_days}
    end
  end

  # ---------------------------------------------------------------------------
  # Room funding allocation
  # ---------------------------------------------------------------------------

  defp active_rooms(group),
    do: group.rooms |> Enum.filter(&(&1.status == "active")) |> Enum.sort_by(& &1.position)

  defp selected_active_rooms(group, room_ids) do
    distinct? = length(room_ids) == room_ids |> MapSet.new() |> MapSet.size()

    by_room_id = Map.new(active_rooms(group), &{&1.room_id, &1})

    if distinct? and Enum.all?(room_ids, &Map.has_key?(by_room_id, &1)) do
      Enum.map(room_ids, &Map.fetch!(by_room_id, &1))
    end
  end

  # Allocates a sequence of funding entries across the group's active rooms
  # in original order, filling one room's deposit before moving to the next.
  # Entries allocate in the order given: operation-processing order.
  defp allocate_funding!(group, entries) do
    {_segments, _rooms} =
      Enum.reduce(entries, {[], active_rooms(group)}, fn entry, {_segments, rooms} ->
        fill_one_entry!(group.id, rooms, entry)
      end)
  end

  defp fill_one_entry!(group_id, rooms, entry) do
    {updated_rooms_rev, segments_rev, leftover} =
      Enum.reduce(rooms, {[], [], entry}, fn room, {rooms_acc, segments_acc, entry_acc} ->
        cond do
          entry_acc.amount <= 0 ->
            {[room | rooms_acc], segments_acc, entry_acc}

          room_capacity(room) <= 0 ->
            {[room | rooms_acc], segments_acc, entry_acc}

          true ->
            take = min(room_capacity(room), entry_acc.amount)
            updated_room = apply_room_funding!(room, entry_acc.kind, take)

            segment =
              insert_allocation!(group_id, room.id, entry_acc.kind, entry_acc.source_operation_id,
                credit_lot_id: entry_acc.credit_lot_id,
                amount_cents: take
              )

            {[updated_room | rooms_acc], [segment | segments_acc],
             Map.put(entry_acc, :amount, entry_acc.amount - take)}
        end
      end)

    unless leftover.amount == 0 do
      raise ArgumentError,
            "funding could not be fully allocated to active rooms: #{leftover.amount} cents left"
    end

    {Enum.reverse(segments_rev), Enum.reverse(updated_rooms_rev)}
  end

  defp room_capacity(room),
    do: max((room.deposit_due_cents || 0) - room.cash_paid_cents - room.credit_paid_cents, 0)

  defp apply_room_funding!(room, "cash", take) do
    room
    |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + take)
    |> Repo.update!()
  end

  defp apply_room_funding!(room, "credit", take) do
    room
    |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + take)
    |> Repo.update!()
  end

  defp insert_allocation!(group_id, room_id, kind, source_operation_id, fields) do
    Repo.insert!(%RoomAllocation{
      group_id: group_id,
      room_id: room_id,
      kind: kind,
      source_operation_id: source_operation_id,
      credit_lot_id: Keyword.fetch!(fields, :credit_lot_id),
      amount_cents: Keyword.fetch!(fields, :amount_cents),
      fill_order: next_fill_order(group_id)
    })
  end

  defp next_fill_order(group_id) do
    Repo.one(
      from a in RoomAllocation,
        where: a.group_id == ^group_id,
        select: coalesce(max(a.fill_order), 0)
    ) + 1
  end

  # Applies the per-group effects of removing held cash: every group that
  # lost funding reopens its deposit and increments its revision, and the
  # addressed group always increments its own revision exactly once.
  defp apply_group_removals!(addressed, removed_by_group) do
    Enum.each(removed_by_group, fn {group_db_id, cents} ->
      if group_db_id != addressed.id do
        other = Repo.get!(Group, group_db_id)

        update_group(other, %{
          deposit_paid_cents: other.deposit_paid_cents - cents,
          cash_paid_cents: other.cash_paid_cents - cents,
          revision: other.revision + 1
        })
      end
    end)

    removed_here = Map.get(removed_by_group, addressed.id, 0)

    update_group(addressed, %{
      deposit_paid_cents: addressed.deposit_paid_cents - removed_here,
      cash_paid_cents: addressed.cash_paid_cents - removed_here,
      revision: addressed.revision + 1
    })
  end

  # Draws up to `amount` from the given allocations in the order given -
  # callers pass them newest first - updating room counters and deleting or
  # shrinking each drawn segment. Returns the drawn units in draw order plus
  # how much funding each affected group lost.
  defp draw_segments!(segments, amount) do
    {units_rev, removed_rev, _remaining} =
      Enum.reduce_while(segments, {[], %{}, amount}, fn segment, {units, removed, remaining} ->
        if remaining <= 0 do
          {:halt, {units, removed, 0}}
        else
          take = min(segment.amount_cents, remaining)
          unit = take_from_segment!(segment, take)

          {:cont,
           {[unit | units], Map.update(removed, segment.group_id, take, &(&1 + take)),
            remaining - take}}
        end
      end)

    {Enum.reverse(units_rev), removed_rev}
  end

  defp take_from_segment!(segment, take) do
    room = Repo.get!(Room, segment.room_id)
    counter = if segment.kind == "cash", do: :cash_paid_cents, else: :credit_paid_cents

    room
    |> Ecto.Changeset.change(%{counter => Map.get(room, counter) - take})
    |> Repo.update!()

    if take == segment.amount_cents do
      Repo.delete!(segment)
    else
      segment
      |> Ecto.Changeset.change(amount_cents: segment.amount_cents - take)
      |> Repo.update!()
    end

    %{
      kind: segment.kind,
      source_operation_id: segment.source_operation_id,
      credit_lot_id: segment.credit_lot_id,
      amount: take
    }
  end

  # Every cent of one payment currently held on any active room.
  defp held_cash_cents_all(payment_operation_id) do
    Repo.one(
      from a in RoomAllocation,
        where: a.kind == "cash" and a.source_operation_id == ^payment_operation_id,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  # ---------------------------------------------------------------------------
  # Deposit transfers
  # ---------------------------------------------------------------------------

  defp transfer_group!(group_id) do
    case get_group(group_id) do
      nil -> throw({:rejected, {:group_not_found, [group_id: group_id]}})
      group -> group
    end
  end

  defp reject_on_error(:ok), do: :ok
  defp reject_on_error({:error, reason}), do: reject(reason)

  # All funding - cash and credit alike - currently allocated to the group's
  # active rooms.
  defp held_funding_cents(group_db_id) do
    Repo.one(
      from a in RoomAllocation,
        where: a.group_id == ^group_db_id,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  # The source's allocations newest first, so drawing walks them in reverse
  # allocation order.
  defp source_allocations_desc(group_db_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.group_id == ^group_db_id,
        order_by: [desc: a.fill_order]
    )
  end

  # Once any of a payment's cash participates in a transfer its statement
  # starts reporting held_by_group.
  defp mark_transfer_participation!(units) do
    Enum.each(units, fn
      %{kind: "cash", source_operation_id: operation_id} when is_binary(operation_id) ->
        disposition = require_disposition!(operation_id)

        unless disposition.participated_in_transfer do
          disposition
          |> Ecto.Changeset.change(participated_in_transfer: true)
          |> Repo.update!()
        end

      _other ->
        :ok
    end)
  end

  defp bump_transfer_counters!(group, deposit_delta, cash_delta, credit_delta) do
    update_group(group, %{
      deposit_paid_cents: group.deposit_paid_cents + deposit_delta,
      cash_paid_cents: group.cash_paid_cents + cash_delta,
      credit_paid_cents: group.credit_paid_cents + credit_delta,
      revision: group.revision + 1
    })
  end

  # ---------------------------------------------------------------------------
  # Settlement (full and partial cancellations)
  # ---------------------------------------------------------------------------

  # Settles the given active rooms of `group`. Rooms are settled with the
  # group's cancellation policy: refundable settlements refund or convert the
  # combined cash and return applied credit to its lots; non-refundable
  # settlements retain the cash and consume the credit.
  defp settle_selected_rooms!(%Group{} = group, rooms, occurred_on, refundable?, opts) do
    # Reported and settled in the group's original room order.
    rooms = rooms |> Enum.sort_by(& &1.position) |> Enum.map(&Repo.reload!/1)
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(from a in RoomAllocation, where: a.room_id in ^room_ids, order_by: a.fill_order)

    cash_allocations = Enum.filter(allocations, &(&1.kind == "cash"))
    credit_allocations = Enum.filter(allocations, &(&1.kind == "credit"))
    cash_total = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))

    {refunded, retained, converted, credit_issued} =
      if refundable? do
        restore_credit_allocations!(credit_allocations, occurred_on)

        case Keyword.fetch!(opts, :refund_method) do
          "hotel_credit" ->
            issued =
              convert_cash_to_lot!(
                group,
                cash_total,
                cash_allocations,
                occurred_on,
                Keyword.fetch!(opts, :operation_id)
              )

            {0, 0, cash_total, issued}

          _cash ->
            bump_dispositions!(cash_allocations, :refunded_cents)
            bump_settlements!(cash_allocations, :refunded_cents, group.id)
            {cash_total, 0, 0, 0}
        end
      else
        consume_credit_allocations!(credit_allocations)
        bump_dispositions!(cash_allocations, :retained_cents)
        bump_settlements!(cash_allocations, :retained_cents, group.id)
        {0, cash_total, 0, 0}
      end

    Enum.each(rooms, fn room ->
      room
      |> Ecto.Changeset.change(status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0)
      |> Repo.update!()
    end)

    Repo.delete_all(from a in RoomAllocation, where: a.room_id in ^room_ids)

    nights = Date.diff(group.departure_on, group.arrival_on)

    settled_lodging = Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * nights + &2))
    settled_due = Enum.reduce(rooms, 0, &((&1.deposit_due_cents || 0) + &2))
    settled_cash = Enum.reduce(rooms, 0, &((&1.cash_paid_cents || 0) + &2))
    settled_credit = Enum.reduce(rooms, 0, &((&1.credit_paid_cents || 0) + &2))

    group_remains_active? =
      active_rooms(group) |> Enum.any?(&(&1.id not in room_ids))

    group =
      update_group(group, %{
        status: if(group_remains_active?, do: "active", else: "cancelled"),
        lodging_total_cents: group.lodging_total_cents - settled_lodging,
        deposit_due_cents: group.deposit_due_cents - settled_due,
        deposit_paid_cents: group.deposit_paid_cents - settled_cash - settled_credit,
        cash_paid_cents: group.cash_paid_cents - settled_cash,
        credit_paid_cents: group.credit_paid_cents - settled_credit,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
        revision: group.revision + 1
      })

    %{
      group: group,
      cancelled_room_ids: Enum.map(rooms, & &1.room_id),
      refunded_cents: refunded,
      retained_cents: retained,
      credit_issued_cents: credit_issued
    }
  end

  # Converts the settled cash into a credit lot worth 110% of it and records
  # which payment contributed which principal, in funding order, so the
  # entitlement can be telescoped out again on a chargeback.
  defp convert_cash_to_lot!(_group, 0, _cash_allocations, _occurred_on, _operation_id), do: 0

  defp convert_cash_to_lot!(group, cash_total, cash_allocations, occurred_on, operation_id) do
    value = bonus_value(cash_total)

    lot =
      create_lot!(
        group.guest_id,
        operation_id,
        value,
        Date.add(occurred_on, @credit_lifetime_days)
      )

    cash_allocations
    |> consolidate(fn allocation ->
      {allocation.source_operation_id, allocation.amount_cents, allocation.fill_order}
    end)
    |> Enum.each(fn {payment_operation_id, principal, first_order} ->
      Repo.insert!(%LotContribution{
        credit_lot_id: lot.id,
        payment_operation_id: payment_operation_id,
        principal_cents: principal,
        fill_order: first_order
      })
    end)

    bump_dispositions!(cash_allocations, :converted_cents)
    bump_settlements!(cash_allocations, :converted_cents, group.id)

    value
  end

  # Applied credit returns to its original lots with its original expiry and
  # never receives a second bonus. While it funded rooms the lot's value was
  # untouched, so restoration stops the funding. Any unrecovered clawback on
  # the lot is extinguished first - before the expiry check - by the returned
  # amount, and only the excess then becomes available or expires under the
  # existing rules. A lot whose expiry is already past on the settlement date
  # stays expired: its excess disappears instead of becoming available again.
  defp restore_credit_allocations!(credit_allocations, occurred_on) do
    credit_allocations
    |> consolidate(&{&1.credit_lot_id, &1.amount_cents, &1.fill_order})
    |> Enum.each(fn {lot_id, returned, _first_order} ->
      lot = Repo.get!(CreditLot, lot_id)
      absorbed = min(lot.unrecovered_clawback_cents, returned)
      excess = returned - absorbed
      expired? = Date.compare(lot.expires_on, occurred_on) != :gt

      changes = %{
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        # The absorbed portion patches the clawback hole instead of becoming
        # available, which reduces the credit liability.
        remaining_cents: lot.remaining_cents - absorbed
      }

      changes =
        if expired?,
          do: Map.update!(changes, :remaining_cents, &max(&1 - excess, 0)),
          else: changes

      lot
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()
    end)
  end

  # Non-refundable settlement permanently consumes the credit that funded the
  # settled rooms: the amounts leave their lots and the liability shrinks.
  defp consume_credit_allocations!(credit_allocations) do
    credit_allocations
    |> consolidate(&{&1.credit_lot_id, &1.amount_cents, &1.fill_order})
    |> Enum.each(fn {lot_id, consumed, _first_order} ->
      lot = Repo.get!(CreditLot, lot_id)

      lot
      |> Ecto.Changeset.change(remaining_cents: max(lot.remaining_cents - consumed, 0))
      |> Repo.update!()
    end)
  end

  # Consolidates allocations by key, preserving first-seen fill order.
  # Returns `{key, total_amount, first_fill_order}` tuples sorted by that
  # order.
  defp consolidate(allocations, key_fn) do
    allocations
    |> Enum.map(key_fn)
    |> Enum.reduce({%{}, %{}}, fn {key, amount, fill_order}, {amounts, orders} ->
      amounts = Map.update(amounts, key, amount, &(&1 + amount))
      orders = Map.update(orders, key, fill_order, &min(&1, fill_order))
      {amounts, orders}
    end)
    |> then(fn {amounts, orders} ->
      amounts
      |> Enum.map(fn {key, amount} -> {key, amount, Map.fetch!(orders, key)} end)
      |> Enum.sort_by(&elem(&1, 2))
    end)
  end

  # ---------------------------------------------------------------------------
  # Payment reductions and chargebacks
  # ---------------------------------------------------------------------------

  defp require_disposition!(payment_operation_id) do
    Repo.one!(
      from d in PaymentDisposition,
        where: d.payment_operation_id == ^payment_operation_id
    )
  end

  # Moves the settled portions of the payment back out of whichever groups
  # booked them, so charged-back cash replaces refunded, retained and
  # converted classifications on exactly the groups that recorded them.
  # Funding that settled before per-group attribution existed - all of it in
  # the payment's own group - falls back to the addressed group.
  defp revert_settlements!(disposition, addressed_group) do
    rows =
      Repo.all(
        from s in PaymentSettlement,
          where: s.payment_operation_id == ^disposition.payment_operation_id
      )

    totals =
      Enum.reduce(rows, %{refunded: 0, retained: 0, converted: 0}, fn row, acc ->
        group = Repo.get!(Group, row.group_id)

        update_group(group, %{
          refunded_cents: group.refunded_cents - row.refunded_cents,
          retained_cents: group.retained_cents - row.retained_cents,
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - row.converted_cents
        })

        Repo.delete!(row)

        %{
          refunded: acc.refunded + row.refunded_cents,
          retained: acc.retained + row.retained_cents,
          converted: acc.converted + row.converted_cents
        }
      end)

    residual_refunded = disposition.refunded_cents - totals.refunded
    residual_retained = disposition.retained_cents - totals.retained
    residual_converted = disposition.converted_cents - totals.converted

    if residual_refunded != 0 or residual_retained != 0 or residual_converted != 0 do
      update_group(addressed_group, %{
        refunded_cents: addressed_group.refunded_cents - residual_refunded,
        retained_cents: addressed_group.retained_cents - residual_retained,
        cash_converted_to_credit_cents:
          addressed_group.cash_converted_to_credit_cents - residual_converted
      })
    end
  end

  defp bump_disposition!(disposition, field, delta) do
    disposition
    |> Ecto.Changeset.change(%{field => Map.get(disposition, field) + delta})
    |> Repo.update!()
  end

  defp bump_dispositions!(cash_allocations, field) do
    cash_allocations
    |> Enum.filter(&is_binary(&1.source_operation_id))
    |> Enum.reduce(%{}, fn allocation, acc ->
      Map.update(
        acc,
        allocation.source_operation_id,
        allocation.amount_cents,
        &(&1 + allocation.amount_cents)
      )
    end)
    |> Enum.each(fn {payment_operation_id, amount} ->
      disposition = require_disposition!(payment_operation_id)
      bump_disposition!(disposition, field, amount)
    end)
  end

  # Records under which group a payment's settled cash was classified, so a
  # later chargeback can revert those classifications on exactly those
  # groups. Only attributed cash participates; legacy funding has no
  # payment identity to record.
  defp bump_settlements!(cash_allocations, field, group_db_id) do
    cash_allocations
    |> Enum.filter(&is_binary(&1.source_operation_id))
    |> Enum.reduce(%{}, fn allocation, acc ->
      Map.update(
        acc,
        allocation.source_operation_id,
        allocation.amount_cents,
        &(&1 + allocation.amount_cents)
      )
    end)
    |> Enum.each(fn {payment_operation_id, amount} ->
      settlement =
        Repo.one(
          from s in PaymentSettlement,
            where:
              s.payment_operation_id == ^payment_operation_id and s.group_id == ^group_db_id
        ) ||
          Repo.insert!(%PaymentSettlement{
            payment_operation_id: payment_operation_id,
            group_id: group_db_id
          })

      bump_disposition!(settlement, field, amount)
    end)
  end

  # Revokes the credit entitlement the payment earned in every lot it helped
  # fund. Each lot's entitlement is computed independently: the standard
  # half-up bonus value of the settled cash through that payment minus the
  # bonus value through the preceding contribution, with the unattributed
  # senior block first. Credit currently applied to active groups cannot be
  # recalled, so the clawback removes the entitlement from the lot's unfunded
  # balance; whatever cannot be removed becomes the lot's unrecovered
  # clawback.
  defp claw_back_converted_credit!(payment_operation_id) do
    lot_ids =
      Repo.all(
        from c in LotContribution,
          where: c.payment_operation_id == ^payment_operation_id,
          distinct: true,
          select: c.credit_lot_id
      )

    Enum.each(lot_ids, fn lot_id ->
      entitlement = credit_entitlement_cents(lot_id, payment_operation_id)
      lot = Repo.get!(CreditLot, lot_id)

      grabbable = max(lot.remaining_cents - lot_funded_cents(lot.id), 0)
      recovered = min(entitlement, grabbable)

      lot
      |> Ecto.Changeset.change(%{
        remaining_cents: lot.remaining_cents - recovered,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + (entitlement - recovered)
      })
      |> Repo.update!()
    end)
  end

  defp credit_entitlement_cents(lot_id, payment_operation_id) do
    contributions =
      Repo.all(
        from c in LotContribution,
          where: c.credit_lot_id == ^lot_id,
          order_by: c.fill_order
      )
      |> consolidate(&{&1.payment_operation_id, &1.principal_cents, &1.fill_order})

    own =
      Enum.find(contributions, &match?({^payment_operation_id, _, _}, &1))

    before_own =
      case own do
        nil ->
          0

        {_, _, order} ->
          contributions
          |> Enum.take_while(&(elem(&1, 2) < order))
          |> Enum.reduce(0, &(elem(&1, 1) + &2))
      end

    case own do
      nil ->
        0

      {_, principal, _} ->
        bonus_value(before_own + principal) - bonus_value(before_own)
    end
  end

  # ---------------------------------------------------------------------------
  # Hotel credit
  # ---------------------------------------------------------------------------

  # Plans which lot funds how much of the applied credit, consuming lots by
  # earliest expiry then source operation id. The lots' value itself is left
  # untouched here: the funded portion neither expires nor appears as
  # available while it funds active rooms.
  defp lot_takes(guest_id, amount_cents, occurred_on) do
    entries =
      guest_id
      |> lot_states()
      |> Enum.sort_by(&{&1.expires_on, &1.source_operation_id})
      |> lot_availability(occurred_on)
      |> Enum.filter(&(&1.free_cents > 0))

    {takes, _leftover} =
      Enum.reduce_while(entries, {[], amount_cents}, fn entry, {takes, needed} ->
        if needed <= 0 do
          {:halt, {takes, 0}}
        else
          take = min(entry.free_cents, needed)
          {:cont, {[{entry.state.id, take} | takes], needed - take}}
        end
      end)

    Enum.reverse(takes)
  end

  # Per-lot state: the value still owned by the guest and how much of it
  # currently funds active rooms (where expiry is paused).
  defp lot_states(nil), do: []

  defp lot_states(guest_ids) do
    guest_ids
    |> List.wrap()
    |> then(fn ids ->
      Repo.all(from l in CreditLot, where: l.guest_id in ^ids, order_by: l.id)
    end)
    |> Enum.map(fn lot ->
      %{
        id: lot.id,
        guest_id: lot.guest_id,
        source_operation_id: lot.source_operation_id,
        remaining_cents: lot.remaining_cents,
        expires_on: lot.expires_on,
        funded_cents: lot_funded_cents(lot.id)
      }
    end)
  end

  # Credit from this lot currently applied to active rooms of active groups.
  defp lot_funded_cents(lot_id) do
    Repo.one(
      from a in RoomAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == a.group_id,
        where: a.credit_lot_id == ^lot_id and g.status == "active" and r.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp lot_availability(states, on_date) do
    Enum.map(states, fn state ->
      free_cents = max(state.remaining_cents - state.funded_cents, 0)
      expired? = Date.compare(state.expires_on, on_date) != :gt

      %{
        state: state,
        free_cents: if(expired?, do: 0, else: free_cents),
        liability_cents: state.funded_cents + if(expired?, do: 0, else: free_cents)
      }
    end)
  end

  defp available_credit_cents(guest_id, on_date) do
    guest_id
    |> guest_credit(on_date)
    |> Map.fetch!(:available_cents)
  end

  defp credit_liability_cents(on_date) do
    all_guests()
    |> lot_availability(on_date)
    |> Enum.reduce(0, &(&1.liability_cents + &2))
  end

  # A lot's current shortfall is the lesser of its unrecovered clawback and
  # the credit from that lot still applied to active groups.
  defp credit_shortfall_cents do
    Repo.all(
      from l in CreditLot,
        where: l.unrecovered_clawback_cents > 0,
        select: %{id: l.id, unrecovered_clawback_cents: l.unrecovered_clawback_cents}
    )
    |> Enum.reduce(0, fn lot, sum ->
      sum + min(lot.unrecovered_clawback_cents, lot_funded_cents(lot.id))
    end)
  end

  defp all_guests, do: lot_states(all_lot_guest_ids())

  defp all_lot_guest_ids do
    Repo.all(from l in CreditLot, distinct: true, select: l.guest_id)
  end

  defp create_lot!(guest_id, source_operation_id, remaining_cents, expires_on) do
    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: remaining_cents,
      expires_on: expires_on
    })
  end

  # ---------------------------------------------------------------------------
  # Group persistence
  # ---------------------------------------------------------------------------

  defp insert_group(attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    rooms =
      Enum.map(attrs.rooms, fn room ->
        lodging_cents = nights * room.nightly_rate_cents

        %{
          "room_id" => room.room_id,
          "nightly_rate_cents" => room.nightly_rate_cents,
          "status" => "active",
          "deposit_due_cents" => room_deposit(attrs.rate_plan, lodging_cents),
          "cash_paid_cents" => 0,
          "credit_paid_cents" => 0
        }
      end)

    lodging_total_cents = nights * Enum.sum(Enum.map(attrs.rooms, & &1.nightly_rate_cents))
    deposit_due_cents = Enum.sum(Enum.map(rooms, & &1["deposit_due_cents"]))

    %Group{}
    |> Group.changeset(%{
      "group_id" => attrs.group_id,
      "guest_id" => attrs.guest_id,
      "property_id" => attrs.property_id,
      "booked_on" => attrs.booked_on,
      "arrival_on" => attrs.arrival_on,
      "departure_on" => attrs.departure_on,
      "rate_plan" => attrs.rate_plan,
      "status" => "active",
      "revision" => 1,
      "lodging_total_cents" => lodging_total_cents,
      "deposit_due_cents" => deposit_due_cents,
      "rooms" => rooms
    })
    |> put_room_positions()
    |> Repo.insert()
    |> case do
      {:ok, group} -> Repo.preload(group, :rooms)
      {:error, _changeset} -> reject(:group_already_exists)
    end
  end

  defp put_room_positions(changeset) do
    rooms = Ecto.Changeset.get_change(changeset, :rooms, [])

    positioned =
      Enum.with_index(rooms, fn room_changeset, index ->
        Ecto.Changeset.change(room_changeset, position: index)
      end)

    if positioned == [] do
      changeset
    else
      Ecto.Changeset.put_change(changeset, :rooms, positioned)
    end
  end

  defp with_group(group_id, expected_revision, fun) do
    case get_group(group_id) do
      nil ->
        reject(:group_not_found)

      group ->
        case check_expected_revision(group, expected_revision) do
          :ok -> fun.(group)
          {:error, reason} -> reject(reason)
        end
    end
  end

  # Group existence is resolved before comparing revisions, so a missing group
  # reports group_not_found even when expected_revision would also mismatch.
  # The derived group id travels with the details so operations addressed by
  # another identifier can report the addressed group.
  defp check_expected_revision(_group, nil), do: :ok

  defp check_expected_revision(group, expected_revision) do
    if group.revision == expected_revision do
      :ok
    else
      {:error,
       {:stale_revision,
        actual_revision: group.revision, group_id: group.group_id, expected_revision: expected_revision}}
    end
  end

  defp update_group(group, changes) do
    group
    |> Group.changeset(Map.new(changes))
    |> Repo.update!()
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: reject(:invalid_stay)
  end

  defp validate_rooms([]), do: reject(:invalid_rooms)

  defp validate_rooms(rooms) do
    unique? = length(rooms) == rooms |> MapSet.new(& &1.room_id) |> MapSet.size()

    rates_valid? =
      Enum.all?(rooms, fn room ->
        is_integer(room.nightly_rate_cents) and room.nightly_rate_cents > 0
      end)

    if unique? and rates_valid?, do: :ok, else: reject(:invalid_rooms)
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: reject(:invalid_rate_plan)
  end

  # Percentage deposits round to the nearest cent, an exact half-cent upward.
  defp room_deposit("flexible", lodging_cents),
    do: div(lodging_cents * @deposit_percentage + 50, 100)

  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  defp usable_payment?(amount_cents), do: is_integer(amount_cents) and amount_cents > 0

  defp valid_new_arrival?(new_arrival_on, occurred_on),
    do: Date.compare(new_arrival_on, occurred_on) == :gt

  defp default_on_date, do: Date.utc_today()

  # A flexible reservation is refundable when cancellation occurs no later
  # than its policy's cancellation window before arrival.
  defp refundable?(%Group{} = group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(until, occurred_on) != :lt
    end
  end

  # The credited value of cash: 110%, rounded to the nearest cent, an exact
  # half-cent upward.
  defp bonus_value(cash_cents), do: div(cash_cents * @credit_bonus_numerator + 50, 100)

  defp ensure_disposition!(operation_id, group_id, recorded_cents) do
    case Repo.one(
           from d in PaymentDisposition,
             where: d.payment_operation_id == ^operation_id
         ) do
      nil ->
        Repo.insert!(%PaymentDisposition{
          payment_operation_id: operation_id,
          group_id: group_id,
          recorded_cents: recorded_cents
        })

      %PaymentDisposition{} = disposition ->
        disposition
    end
  end
end
