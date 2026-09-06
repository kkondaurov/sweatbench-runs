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
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group

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
  Records a cash payment against a group's outstanding deposit.
  """
  def record_cash_payment(group_id, amount_cents, expected_revision) do
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
  Cancels a group and settles its paid deposit.

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
            settle_cancelled_group(group, occurred_on, refundable?(group, occurred_on),
              refund_method: refund_method,
              operation_id: operation_id
            )
        end
      end)
    end)
  end

  @doc """
  Applies the guest's hotel credit to an active group's outstanding deposit.

  Lots are consumed by earliest expiry, then by source operation id. The
  applied amounts are remembered per lot so they can be restored if the
  group is later cancelled while refundable.
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
            consume_lots!(group.guest_id, group.id, amount_cents, occurred_on)

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
  Cash totals across all groups plus the hotel credit liability.

  Cash held is cash currently applied to active reservations. Cancellations
  move it to refunded, retained, or converted-to-credit. The credit liability
  covers both available credit and credit currently applied to active groups;
  expiry and non-refundable consumption reduce it. All expiry-sensitive
  totals are evaluated as of `on_date`.
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

    %{
      cash_held_cents: Repo.one(held),
      cash_refunded_cents: Repo.one(refunded),
      cash_retained_cents: Repo.one(retained),
      cash_converted_to_credit_cents: Repo.one(converted),
      credit_liability_cents: credit_liability_cents(on_date)
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

  defp settle_cancelled_group(group, occurred_on, refundable?, opts) do
    {refunded, retained, converted, credit_issued} =
      if refundable? do
        restore_applied_credit!(group, occurred_on)

        case Keyword.fetch!(opts, :refund_method) do
          "hotel_credit" ->
            cash = group.cash_paid_cents
            lot_cents = credit_with_bonus(cash)

            if cash > 0 do
              create_lot!(
                group.guest_id,
                Keyword.fetch!(opts, :operation_id),
                lot_cents,
                Date.add(occurred_on, @credit_lifetime_days)
              )
            end

            {0, 0, cash, lot_cents}

          _cash ->
            {group.cash_paid_cents, 0, 0, 0}
        end
      else
        consume_applied_credit!(group)
        {0, group.cash_paid_cents, 0, 0}
      end

    group =
      update_group(group, %{
        status: "cancelled",
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
        revision: group.revision + 1
      })

    %{group: group, credit_issued_cents: credit_issued}
  end

  # Non-refundable settlement permanently consumes the credit that funded
  # this group: the amounts leave their lots and the liability shrinks.
  defp consume_applied_credit!(group) do
    applications_with_lots(group.id)
    |> Enum.each(fn {application, lot} ->
      lot
      |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - application.amount_cents)
      |> Repo.update!()
    end)

    delete_applications!(group.id)
  end

  # Applied credit returns to its original lots with its original expiry and
  # never receives a second bonus. A lot whose expiry is already past on the
  # cancellation date stays expired: its restored amount expires immediately
  # instead of becoming available again, which reduces the credit liability.
  defp restore_applied_credit!(group, occurred_on) do
    applications_with_lots(group.id)
    |> Enum.each(fn {application, lot} ->
      if Date.compare(lot.expires_on, occurred_on) != :gt do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - application.amount_cents)
        |> Repo.update!()
      end
    end)

    delete_applications!(group.id)
  end

  # Applying credit records which lot funds the group and by how much. The
  # lot's value itself is untouched until the group settles, so the funded
  # portion neither expires nor appears as available while it funds.
  defp consume_lots!(guest_id, group_id, amount_cents, occurred_on) do
    entries =
      guest_id
      |> lot_states()
      |> Enum.sort_by(&{&1.expires_on, &1.source_operation_id})
      |> lot_availability(occurred_on)
      |> Enum.filter(&(&1.free_cents > 0))

    Enum.reduce_while(entries, amount_cents, fn entry, remaining_needed ->
      if remaining_needed <= 0 do
        {:halt, remaining_needed}
      else
        take = min(entry.free_cents, remaining_needed)

        Repo.insert!(%CreditApplication{
          group_id: group_id,
          credit_lot_id: entry.state.id,
          amount_cents: take
        })

        {:cont, remaining_needed - take}
      end
    end)
  end

  # Per-lot state: the value still owned by the guest and how much of it
  # currently funds active groups (where expiry is paused).
  defp lot_states(nil), do: []

  defp lot_states(guest_ids) do
    from(l in CreditLot,
      left_join: a in CreditApplication,
      on: a.credit_lot_id == l.id,
      left_join: g in Group,
      on: g.id == a.group_id and g.status == "active",
      where: l.guest_id in ^List.wrap(guest_ids),
      group_by: [l.id, l.guest_id, l.source_operation_id, l.remaining_cents, l.expires_on],
      order_by: [l.id],
      select: %{
        id: l.id,
        guest_id: l.guest_id,
        source_operation_id: l.source_operation_id,
        remaining_cents: l.remaining_cents,
        expires_on: l.expires_on,
        funded_cents: coalesce(sum(a.amount_cents), 0)
      }
    )
    |> Repo.all()
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

  defp all_guests, do: lot_states(all_lot_guest_ids())

  defp all_lot_guest_ids do
    Repo.all(from l in CreditLot, distinct: true, select: l.guest_id)
  end

  defp applications_with_lots(group_id) do
    from(a in CreditApplication,
      join: l in CreditLot,
      on: l.id == a.credit_lot_id,
      where: a.group_id == ^group_id,
      select: {a, l}
    )
    |> Repo.all()
  end

  defp delete_applications!(group_id) do
    Repo.delete_all(from a in CreditApplication, where: a.group_id == ^group_id)
  end

  defp create_lot!(guest_id, source_operation_id, remaining_cents, expires_on) do
    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: remaining_cents,
      expires_on: expires_on
    })
  end

  # The 10% bonus rounds to the nearest cent, an exact half-cent upward.
  defp credit_with_bonus(cash_cents), do: div(cash_cents * @credit_bonus_numerator + 50, 100)

  defp insert_group(attrs) do
    nights = Date.diff(attrs.departure_on, attrs.arrival_on)

    lodging_total_cents =
      Enum.sum(Enum.map(attrs.rooms, fn room -> nights * room.nightly_rate_cents end))

    deposit_due_cents =
      Enum.sum(
        Enum.map(attrs.rooms, fn room ->
          room_deposit(attrs.rate_plan, nights * room.nightly_rate_cents)
        end)
      )

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
      "rooms" =>
        Enum.map(attrs.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end)
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
  defp check_expected_revision(_group, nil), do: :ok

  defp check_expected_revision(group, expected_revision) do
    if group.revision == expected_revision do
      :ok
    else
      {:error, {:stale_revision, [actual_revision: group.revision]}}
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
end
