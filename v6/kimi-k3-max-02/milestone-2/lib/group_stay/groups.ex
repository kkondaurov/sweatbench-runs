defmodule GroupStay.Groups do
  @moduledoc """
  The Groups context owns group reservations: opening them, recording cash and
  hotel credit against their deposits, rescheduling their stays, and
  cancelling them, as well as the credit lots and finance totals derived from
  those records.

  Partner operations are applied one at a time, each in its own transaction,
  so a rejected operation leaves the database exactly as it was before the
  operation began and never stops later operations in the same batch.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Groups.{CreditApplication, CreditLot, Group}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)

  # Flexible groups booked before this date keep the original 14-day
  # cancellation window; flexible groups booked on or after it use 30 days.
  @flex_policy_cutover ~D[2027-01-01]

  # A credit lot issued on cancellation is available through the date 365
  # days after cancellation and expires the following day.
  @credit_lifetime_days 365

  ## Reads

  @doc """
  Fetches a group by its partner-supplied `group_id`, with rooms in their
  original order. Returns `:error` when no such group exists.
  """
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :error
      %Group{} = group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_group_id), do: :error

  @doc """
  The last date on which cancelling the group is refundable: the arrival date
  minus the group's fixed cancellation window. `nil` for advance-purchase
  groups, which are never refundable.
  """
  def refundable_until(%Group{} = group) do
    case cancellation_window(group.policy_version) do
      nil -> nil
      window_days -> Date.add(group.arrival_on, -window_days)
    end
  end

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30
  defp cancellation_window(_policy_version), do: nil

  @doc """
  Finance totals across all groups and credit lots, reporting credit expiry as
  of `on_date`: cash held against active reservations, cash refunded, retained
  or converted to credit through cancellations, and the outstanding credit
  liability. Unpaid deposit requirements never appear in these totals.
  """
  def ledger_totals(on_date \\ Date.utc_today()) do
    %{
      cash_held_cents: ledger_sum("active", :cash_paid_cents),
      cash_refunded_cents: ledger_sum("cancelled", :refunded_cents),
      cash_retained_cents: ledger_sum("cancelled", :retained_cents),
      cash_converted_to_credit_cents: ledger_sum("cancelled", :cash_converted_cents),
      credit_liability_cents: credit_liability(on_date)
    }
  end

  defp ledger_sum(status, field) do
    Repo.one(
      from g in Group,
        where: g.status == ^status,
        select: coalesce(sum(field(g, ^field)), 0)
    )
  end

  # The credit liability covers both available credit and credit currently
  # applied to active groups. Expiry and non-refundable consumption reduce it;
  # applying or restoring credit merely moves it between the two parts.
  defp credit_liability(on_date) do
    available_cents =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on_date,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from a in CreditApplication,
          where: a.status == "applied",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available_cents + applied_cents
  end

  @doc """
  A guest's hotel credit as of `on_date`: the available total and the
  unexpired, unexhausted lots ordered by expiry and then source operation.
  """
  def guest_credit(guest_id, on_date \\ Date.utc_today()) do
    lots = available_lots(guest_id, on_date)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(for lot <- lots, do: lot.remaining_cents),
      lots: Enum.map(lots, &lot_data/1)
    }
  end

  defp lot_data(%CreditLot{} = lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_string(lot.expires_on)
    }
  end

  # Lots available to a guest as of `on_date`, in consumption order: earliest
  # expiry first, then `source_operation_id` for equal expiries.
  defp available_lots(guest_id, on_date) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on_date,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
  end

  ## Partner operations

  @doc """
  Applies partner operations in array order and returns one result map per
  operation, in the same order. An operation can observe changes made by
  earlier operations in the same batch; a rejected operation changes nothing.
  """
  def apply_operations(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(operation) do
    case Repo.transact(fn -> do_apply(operation) end) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp do_apply(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp do_apply(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp do_apply(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp do_apply(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)

  defp do_apply(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp do_apply(operation) when is_map(operation), do: rejected(operation, "invalid_operation")

  defp do_apply(_operation), do: rejected(%{}, "invalid_operation")

  ## open_group

  defp open_group(operation) do
    with :ok <- require_fields(operation, ["group_id", "guest_id", "property_id"]),
         {:ok, booked_on} <- fetch_occurred_on(operation),
         :ok <- ensure_group_absent(Map.get(operation, "group_id")),
         {:ok, arrival_on, departure_on} <- stay_dates(operation),
         {:ok, rooms} <- valid_rooms(Map.get(operation, "rooms")),
         :ok <- valid_rate_plan(Map.get(operation, "rate_plan")) do
      create_group(operation, booked_on, arrival_on, departure_on, rooms)
    else
      error -> rejection_for(operation, error)
    end
  end

  defp create_group(operation, booked_on, arrival_on, departure_on, rooms) do
    rate_plan = Map.get(operation, "rate_plan")
    nights = Date.diff(departure_on, arrival_on)

    room_attrs =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          room_id: Map.get(room, "room_id"),
          nightly_rate_cents: Map.get(room, "nightly_rate_cents"),
          position: position
        }
      end)

    lodging_total_cents =
      Enum.sum(for room <- room_attrs, do: nights * room.nightly_rate_cents)

    deposit_due_cents =
      Enum.sum(
        for room <- room_attrs,
            do: room_deposit(rate_plan, nights * room.nightly_rate_cents)
      )

    attrs = %{
      group_id: Map.get(operation, "group_id"),
      guest_id: Map.get(operation, "guest_id"),
      property_id: Map.get(operation, "property_id"),
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: rate_plan,
      policy_version: policy_version(rate_plan, booked_on),
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      rooms: room_attrs
    }

    case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
      {:ok, group} ->
        applied(operation, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, %Changeset{}} ->
        rejected(operation, "group_already_exists")
    end
  end

  # A group's policy version is fixed when the group is opened, from its rate
  # plan and booking date; rescheduling never moves it to a newer policy.
  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  # A flexible room requires 20% of its lodging amount as deposit. An
  # advance-purchase room requires its full lodging amount.
  defp room_deposit("flexible", lodging_cents), do: percent_of(lodging_cents, 20)
  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  # Percentages round to the nearest cent; an exact half-cent rounds upward.
  defp percent_of(cents, percent), do: div(cents * percent + 50, 100)

  ## record_cash_payment

  defp record_cash_payment(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, amount_cents} <- payment_amount(Map.get(operation, "amount_cents")),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      deposit_paid_cents = group.deposit_paid_cents + amount_cents

      group =
        update_group!(group, %{
          deposit_paid_cents: deposit_paid_cents,
          cash_paid_cents: group.cash_paid_cents + amount_cents
        })

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: group.deposit_due_cents - deposit_paid_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  defp payment_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp payment_amount(_amount_cents), do: {:error, "invalid_amount"}

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  ## apply_hotel_credit

  defp apply_hotel_credit(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, amount_cents} <- payment_amount(Map.get(operation, "amount_cents")),
         :ok <- ensure_within_outstanding(group, amount_cents),
         {:ok, takes} <- credit_coverage(group.guest_id, amount_cents, occurred_on) do
      Enum.each(takes, fn {lot, take_cents} ->
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents - take_cents)
        |> Repo.update!()

        %CreditApplication{}
        |> CreditApplication.changeset(%{
          credit_lot_id: lot.id,
          group_id: group.id,
          amount_cents: take_cents,
          status: "applied"
        })
        |> Repo.insert!()
      end)

      deposit_paid_cents = group.deposit_paid_cents + amount_cents

      group =
        update_group!(group, %{
          deposit_paid_cents: deposit_paid_cents,
          credit_paid_cents: group.credit_paid_cents + amount_cents
        })

      applied(operation, %{
        group_id: group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: group.deposit_due_cents - deposit_paid_cents,
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  # Plans how the guest's unexpired lots cover the requested amount, consuming
  # lots by earliest expiry and then by source_operation_id. The operation's
  # occurred_on date decides which lots have expired.
  defp credit_coverage(guest_id, amount_cents, occurred_on) do
    lots = available_lots(guest_id, occurred_on)
    available_cents = Enum.sum(for lot <- lots, do: lot.remaining_cents)

    if available_cents < amount_cents do
      {:error, "insufficient_credit"}
    else
      {takes, _uncovered} =
        Enum.map_reduce(lots, amount_cents, fn lot, uncovered ->
          take_cents = min(lot.remaining_cents, uncovered)
          {{lot, take_cents}, uncovered - take_cents}
        end)

      takes = for {lot, take_cents} <- takes, take_cents > 0, do: {lot, take_cents}
      {:ok, takes}
    end
  end

  ## reschedule_group

  defp reschedule_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, new_arrival_on} <- new_arrival(operation, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      group = update_group!(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on})

      applied(operation, %{
        group_id: group.group_id,
        new_arrival_on: Date.to_string(group.arrival_on),
        new_departure_on: Date.to_string(group.departure_on),
        policy_version: group.policy_version,
        refundable_until: format_date(refundable_until(group)),
        revision: group.revision
      })
    else
      error -> rejection_for(operation, error)
    end
  end

  defp new_arrival(operation, occurred_on) do
    case parse_date(Map.get(operation, "new_arrival_on")) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:error, "invalid_stay"}
        end

      :error ->
        {:error, "invalid_stay"}
    end
  end

  ## cancel_group

  defp cancel_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_revision(operation, group),
         :ok <- ensure_active(group),
         {:ok, occurred_on} <- fetch_occurred_on(operation),
         {:ok, refund_method} <- fetch_refund_method(operation),
         :ok <- ensure_refund_method_available(group, occurred_on, refund_method) do
      settle_cancellation(group, occurred_on, refund_method, operation)
    else
      error -> rejection_for(operation, error)
    end
  end

  # Omitting refund_method means cash, preserving existing callers.
  defp fetch_refund_method(operation) do
    case Map.get(operation, "refund_method") do
      nil -> {:ok, "cash"}
      refund_method when refund_method in @refund_methods -> {:ok, refund_method}
      _other -> {:error, "invalid_operation"}
    end
  end

  # Hotel credit is not a way around a non-refundable policy.
  defp ensure_refund_method_available(group, occurred_on, "hotel_credit") do
    if refundable?(group, occurred_on) do
      :ok
    else
      {:error, "refund_method_not_available"}
    end
  end

  defp ensure_refund_method_available(_group, _occurred_on, "cash"), do: :ok

  # A flexible group cancelled on or before its refundable_until date is
  # refundable; advance-purchase groups never are.
  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      last_refundable_date -> Date.compare(occurred_on, last_refundable_date) != :gt
    end
  end

  defp settle_cancellation(group, occurred_on, refund_method, operation) do
    cash_cents = group.cash_paid_cents

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      if refundable?(group, occurred_on) do
        restore_applied_credit(group)

        case refund_method do
          "cash" ->
            {cash_cents, 0, 0, 0}

          "hotel_credit" ->
            credit_issued_cents =
              issue_credit_lot(group, occurred_on, Map.get(operation, "operation_id"), cash_cents)

            {0, 0, cash_cents, credit_issued_cents}
        end
      else
        consume_applied_credit(group)
        {0, cash_cents, 0, 0}
      end

    group =
      update_group!(group, %{
        status: "cancelled",
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        cash_converted_cents: converted_cents
      })

    applied(operation, %{
      group_id: group.group_id,
      refunded_cents: group.refunded_cents,
      retained_cents: group.retained_cents,
      credit_issued_cents: credit_issued_cents,
      revision: group.revision
    })
  end

  # The cash-funded portion becomes a credit lot worth 110% of that cash: the
  # original cash plus a 10% bonus under the standard rounding rule. The lot
  # is available through the date 365 days after cancellation.
  defp issue_credit_lot(_group, _occurred_on, _operation_id, 0), do: 0

  defp issue_credit_lot(group, occurred_on, operation_id, cash_cents) do
    lot_cents = cash_cents + percent_of(cash_cents, 10)

    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      original_cents: lot_cents,
      remaining_cents: lot_cents,
      expires_on: Date.add(occurred_on, @credit_lifetime_days)
    })
    |> Repo.insert!()

    lot_cents
  end

  # Applied credit returns to its original lots with its original expiry and
  # never receives a second bonus. If a lot's expiry is already past on the
  # cancellation date, the restored amount expires immediately: it stays
  # excluded from the guest's available credit and from the liability.
  defp restore_applied_credit(group) do
    for application <- applied_credit(group) do
      lot = application.credit_lot

      lot
      |> Changeset.change(remaining_cents: lot.remaining_cents + application.amount_cents)
      |> Repo.update!()

      application
      |> Changeset.change(status: "restored")
      |> Repo.update!()
    end

    :ok
  end

  defp consume_applied_credit(group) do
    for application <- applied_credit(group) do
      application
      |> Changeset.change(status: "consumed")
      |> Repo.update!()
    end

    :ok
  end

  defp applied_credit(group) do
    Repo.all(
      from a in CreditApplication,
        where: a.group_id == ^group.id and a.status == "applied",
        preload: [:credit_lot]
    )
  end

  ## Shared validation and persistence

  defp fetch_group(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, "group_not_found"}
          %Group{} = group -> {:ok, group}
        end

      _other ->
        {:error, "invalid_operation"}
    end
  end

  # Group existence is resolved before revisions are compared, and a stale
  # revision is rejected before any other domain rule is evaluated.
  defp check_revision(operation, group) do
    case Map.get(operation, "expected_revision") do
      nil ->
        :ok

      expected_revision ->
        if expected_revision == group.revision do
          :ok
        else
          {:error, "stale_revision",
           %{expected_revision: expected_revision, actual_revision: group.revision}}
        end
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(%Group{}), do: {:error, "group_not_active"}

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &is_binary(Map.get(operation, &1))) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp fetch_occurred_on(operation) do
    case parse_date(Map.get(operation, "occurred_on")) do
      {:ok, occurred_on} -> {:ok, occurred_on}
      :error -> {:error, "invalid_operation"}
    end
  end

  defp ensure_group_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, "group_already_exists"}
    else
      :ok
    end
  end

  defp stay_dates(operation) do
    with {:ok, arrival_on} <- parse_date(Map.get(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(Map.get(operation, "departure_on")),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on}
    else
      _other -> {:error, "invalid_stay"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok, rooms}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp valid_room?(room) do
    is_map(room) and is_binary(Map.get(room, "room_id")) and
      is_integer(Map.get(room, "nightly_rate_cents")) and
      Map.get(room, "nightly_rate_cents") >= 0
  end

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, &Map.get(&1, "room_id"))
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_string(date)

  # Every applied operation addressed to a group increments its revision
  # exactly once, even when no booking field visibly changes.
  defp update_group!(group, attrs) do
    group
    |> Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  ## Operation results

  defp applied(operation, fields) do
    result =
      Map.merge(
        %{operation_id: Map.get(operation, "operation_id"), status: "applied"},
        fields
      )

    {:ok, result}
  end

  defp rejection_for(operation, {:error, code}), do: rejected(operation, code)

  defp rejection_for(operation, {:error, code, extra}),
    do: rejected(operation, code, extra)

  defp rejected(operation, code, extra \\ %{}) do
    result = %{
      operation_id: Map.get(operation, "operation_id"),
      status: "rejected",
      code: code
    }

    result =
      case Map.get(operation, "group_id") do
        group_id when is_binary(group_id) -> Map.put(result, :group_id, group_id)
        _other -> result
      end

    {:error, Map.merge(result, extra)}
  end
end
