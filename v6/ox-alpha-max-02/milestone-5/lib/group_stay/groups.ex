defmodule GroupStay.Groups do
  @moduledoc """
  Domain logic for group reservations: opening, funding, rescheduling, and
  cancelling groups, hotel credit, payment reductions and chargebacks, plus
  the finance totals derived from them.

  Commands are executed inside the database transaction owned by their caller;
  `GroupStay.Operations` wraps every partner operation in one so domain changes
  commit together with their durable idempotency record. Each command either
  applies completely or, when rejected, performs no writes at all: validation
  always precedes the first write. Commands return one of:

      {:ok, result_fields}
      {:error, code}
      {:error, :stale_revision, %{group_id:, expected_revision:, actual_revision:}}

  An unexpected exception aborts the enclosing transaction, so partially
  written commands roll back along with everything else. `code` is an atom;
  the web layer turns these into API payloads.

  Money is accounted at room level: every active room carries its own lodging,
  deposit requirement, and funded cash and credit. Cash and credit fund active
  room deposits in the rooms' original order, filling one room's deposit before
  moving to the next, and each funding operation continues where the previous
  one stopped. Cash allocations remember which payment they came from so
  reductions and chargebacks can move exactly that payment's money, wherever
  transfers have since taken it. Every allocation row carries one shared
  creation sequence, so "most recently created allocation first" spans both
  funding kinds and every group.
  """

  import Ecto.Query, only: [from: 2]

  alias GroupStay.Repo
  alias GroupStay.Operations.Record
  alias GroupStay.Groups.{CreditLot, Group, Room, RoomCashAllocation, RoomCreditApplication}

  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)

  @flex_cutoff ~D[2027-01-01]
  @cancellation_windows %{"flex-14" => 14, "flex-30" => 30}
  @credit_bonus_days 366

  ## Queries

  @doc """
  Returns the group with the given partner identifier, with rooms in their
  original order, or nil when no such group exists.
  """
  def get_group(group_id) do
    Repo.one(group_query(group_id))
  end

  @doc """
  The cancellation policy version implied by a rate plan and booking date.

  Flexible groups booked on or after the 2027-01-01 cutoff use the 30-day
  window; earlier ones keep the 14-day window. Advance purchase is never
  refundable.
  """
  def policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  def policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  @doc """
  The last date on which cancelling the group is refundable, or nil when its
  policy version has no refundable window.
  """
  def refundable_until(%Group{arrival_on: arrival_on, policy_version: version}) do
    case @cancellation_windows[version] do
      nil -> nil
      days -> Date.add(arrival_on, -days)
    end
  end

  @doc """
  The accounting totals of a group over its active rooms.
  """
  def group_totals(%Group{rooms: rooms}) do
    active = active_rooms(rooms)
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))
    deposit_due = Enum.sum(Enum.map(active, & &1.deposit_due_cents))

    %{
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.lodging_cents)),
      deposit_due_cents: deposit_due,
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: deposit_due - cash - credit
    }
  end

  @doc """
  Cash accounting totals across all groups:

    * `cash_held_cents` - cash currently applied to active reservations;
    * `cash_refunded_cents` - cash returned after refundable cancellations;
    * `cash_retained_cents` - cash kept by the hotel after non-refundable cancellations;
    * `cash_converted_to_credit_cents` - cash turned into hotel credit instead of refunded;
    * `cash_reduced_cents` - cash removed again through provider reductions;
    * `cash_charged_back_cents` - cash reversed through provider chargebacks;
    * `credit_liability_cents` - outstanding hotel credit, both available and applied to active groups;
    * `credit_shortfall_cents` - revoked credit entitlement covered by credit still applied to active groups.

  Expiry is evaluated as of `as_of`; credit funding an active group does not
  expire while it funds that group.
  """
  def ledger_totals(as_of \\ Date.utc_today()) do
    dispositions =
      from(a in RoomCashAllocation,
        group_by: a.disposition,
        select: {a.disposition, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      cash_held_cents: cash_held_total(),
      cash_refunded_cents: scalar_group_sum(:refunded_cents),
      cash_retained_cents: scalar_group_sum(:retained_cents),
      cash_converted_to_credit_cents: scalar_group_sum(:cash_converted_to_credit_cents),
      cash_reduced_cents: Map.get(dispositions, "reduced", 0),
      cash_charged_back_cents: Map.get(dispositions, "charged_back", 0),
      credit_liability_cents: available_credit_total(as_of) + applied_active_credit_total(),
      credit_shortfall_cents: credit_shortfall_total()
    }
  end

  defp cash_held_total do
    Repo.one!(
      from(r in Room,
        join: g in Group,
        on: g.id == r.group_id,
        where: r.status == "active" and g.status == "active",
        select: coalesce(sum(r.cash_paid_cents), 0)
      )
    )
  end

  defp scalar_group_sum(field) do
    Repo.one!(from(g in Group, select: coalesce(sum(field(g, ^field)), 0)))
  end

  defp available_credit_total(as_of) do
    Repo.one!(
      from l in CreditLot,
        select: coalesce(sum(l.remaining_cents), 0),
        where: l.remaining_cents > 0 and l.expires_on > ^as_of
    )
  end

  defp applied_active_credit_total do
    Repo.one!(
      from a in RoomCreditApplication,
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == a.group_id,
        where: r.status == "active" and g.status == "active",
        select: coalesce(sum(a.applied_cents), 0)
    )
  end

  defp credit_shortfall_total do
    clawbacks =
      from(l in CreditLot,
        where: l.unrecovered_clawback_cents > 0,
        select: {l.id, l.unrecovered_clawback_cents}
      )
      |> Repo.all()

    applied_by_lot =
      from(a in RoomCreditApplication,
        join: r in Room,
        on: r.id == a.room_id,
        where: r.status == "active",
        group_by: a.credit_lot_id,
        select: {a.credit_lot_id, coalesce(sum(a.applied_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.reduce(clawbacks, 0, fn {lot_id, unrecovered}, total ->
      total + min(unrecovered, Map.get(applied_by_lot, lot_id, 0))
    end)
  end

  @doc """
  A guest's unexpired, unapplied credit lots as of `as_of`, ordered by expiry
  date and then by the operation that issued them.
  """
  def guest_credit(guest_id, as_of \\ Date.utc_today()) do
    lots =
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  ## Opening

  @doc """
  Opens a new group reservation from a raw `open_group` operation payload.

  The stay must span at least one night, at least one room is required, room
  identifiers are unique within the group, and the rate plan must be known.
  Flexible rooms require a 20% deposit rounded per room (half up); advance
  purchase rooms require the full lodging amount. The cancellation policy
  version is fixed from the booking date.
  """
  def open_group(attrs) do
    with {:ok, params} <- validate_open(attrs) do
      if Repo.exists?(from g in Group, where: g.group_id == ^params.group_id) do
        {:error, :group_already_exists}
      else
        insert_opened_group(params)
      end
    end
  end

  defp insert_opened_group(params) do
    %Group{}
    |> Group.open_changeset(params.attrs, params.rooms)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        {:ok,
         %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         }}

      _ ->
        {:error, :group_already_exists}
    end
  end

  defp validate_open(attrs) do
    with {:ok, booked_on} <- operation_date(attrs["occurred_on"]),
         {:ok, arrival_on} <- stay_date(attrs["arrival_on"]),
         {:ok, departure_on} <- stay_date(attrs["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(attrs["rate_plan"]),
         {:ok, rooms} <- validate_rooms(attrs["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)

      lodgings = Enum.map(rooms, &{&1.room_id, &1.nightly_rate_cents * nights})
      lodging_total = lodgings |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      deposit_due =
        lodgings
        |> Enum.map(fn {_room_id, lodging} -> room_deposit(lodging, rate_plan) end)
        |> Enum.sum()

      room_structs =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, index} ->
          lodging = room.nightly_rate_cents * nights

          %Room{
            position: index,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: "active",
            lodging_cents: lodging,
            deposit_due_cents: room_deposit(lodging, rate_plan),
            cash_paid_cents: 0,
            credit_paid_cents: 0
          }
        end)

      {:ok,
       %{
         group_id: attrs["group_id"],
         deposit_due_cents: deposit_due,
         rooms: room_structs,
         attrs: %{
           group_id: attrs["group_id"],
           guest_id: attrs["guest_id"],
           property_id: attrs["property_id"],
           rate_plan: rate_plan,
           policy_version: policy_version(rate_plan, booked_on),
           status: "active",
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           revision: 1,
           lodging_total_cents: lodging_total,
           deposit_due_cents: deposit_due,
           deposit_paid_cents: 0
         }
       }}
    end
  end

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(arrival_on, departure_on) == :lt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) do
      room_ids = Enum.map(rooms, & &1["room_id"])

      if Enum.uniq(room_ids) == room_ids do
        {:ok,
         Enum.map(rooms, fn room ->
           %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
         end)}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate})
       when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 do
    true
  end

  defp valid_room?(_), do: false

  defp room_deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  ## Payments

  @doc """
  Applies a cash payment against the outstanding deposit of an active group.
  The cash is allocated across the active rooms in their original order and
  attributed to this payment operation.
  """
  def record_cash_payment(group_id, amount_cents, expected_revision, operation_id) do
    with {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- ensure_active(group),
         :ok <- usable_amount?(amount_cents),
         :ok <- within_outstanding?(group, amount_cents) do
      allocate_funding!(group, [cash_item(operation_id, amount_cents)])
      bump_revision!(group)

      {:ok, updated} = load_group(group_id)

      {:ok,
       %{
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  ## Hotel credit

  @doc """
  Applies the guest's hotel credit to an active group's outstanding deposit.

  Credit is consumed from unexpired lots by earliest expiry and then by the
  source operation identifier, and allocated across the active rooms in their
  original order. Which lots fund which rooms is preserved so the amounts can
  be restored if the rooms are later settled while refundable. While credit
  funds an active room its expiry is paused.
  """
  def apply_hotel_credit(group_id, amount_cents, occurred_on, expected_revision, _operation_id) do
    with {:ok, occurred_on} <- operation_date(occurred_on),
         {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- ensure_active(group),
         :ok <- usable_amount?(amount_cents),
         :ok <- within_outstanding?(group, amount_cents),
         :ok <- enough_unexpired_credit?(group.guest_id, amount_cents, occurred_on) do
      takings = consume_lots!(group.guest_id, amount_cents, occurred_on)

      items =
        takings
        |> Enum.reject(fn {_lot_id, taken} -> taken == 0 end)
        |> Enum.map(fn {lot_id, taken} -> credit_item(lot_id, taken) end)

      allocate_funding!(group, items)
      bump_revision!(group)

      {:ok, updated} = load_group(group_id)

      {:ok,
       %{
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp enough_unexpired_credit?(guest_id, amount_cents, as_of) do
    total =
      Repo.one!(
        from l in CreditLot,
          select: coalesce(sum(l.remaining_cents), 0),
          where:
            l.guest_id == ^guest_id and l.remaining_cents > 0 and
              l.expires_on > ^as_of
      )

    if total >= amount_cents do
      :ok
    else
      {:error, :insufficient_credit}
    end
  end

  defp available_lots_query(guest_id, as_of) do
    from(l in CreditLot,
      where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^as_of,
      order_by: [asc: l.expires_on, asc: l.source_operation_id]
    )
  end

  defp consume_lots!(guest_id, amount_cents, as_of) do
    available_lots_query(guest_id, as_of)
    |> Repo.all()
    |> consume_from_lots!(amount_cents, [])
  end

  defp consume_from_lots!(_lots, 0, acc), do: Enum.reverse(acc)

  defp consume_from_lots!([], remaining, _acc) when remaining > 0 do
    raise ArgumentError, message: "insufficient credit to consume"
  end

  defp consume_from_lots!([lot | rest], remaining, acc) do
    take = min(lot.remaining_cents, remaining)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - take)
    |> Repo.update!()

    consume_from_lots!(rest, remaining - take, [{lot.id, take} | acc])
  end

  ## Rescheduling

  @doc """
  Moves an active group's stay to a new arrival date, shifting the departure
  by the same number of nights so length and price are unchanged. The group's
  policy version stays fixed.
  """
  def reschedule_group(group_id, new_arrival_on, occurred_on, expected_revision) do
    with {:ok, occurred_on} <- operation_date(occurred_on),
         {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- ensure_active(group),
         {:ok, new_arrival} <- movable_date(new_arrival_on, occurred_on) do
      nights = Date.diff(group.departure_on, group.arrival_on)
      new_departure = Date.add(new_arrival, nights)

      {:ok, updated} =
        update_group!(group,
          arrival_on: new_arrival,
          departure_on: new_departure,
          revision: group.revision + 1
        )

      {:ok,
       %{
         group_id: updated.group_id,
         new_arrival_on: updated.arrival_on,
         new_departure_on: updated.departure_on,
         policy_version: updated.policy_version,
         refundable_until: refundable_until(updated),
         revision: updated.revision
       }}
    end
  end

  defp movable_date(value, occurred_on) do
    case to_date(value) do
      {:ok, date} ->
        if Date.compare(date, occurred_on) == :gt do
          {:ok, date}
        else
          {:error, :invalid_stay}
        end

      _ ->
        {:error, :invalid_stay}
    end
  end

  ## Cancellation

  @doc """
  Cancels all remaining active rooms of an active group.

  The refund window depends on the group's fixed policy version; cancellation
  on the `refundable_until` date itself is still refundable. Refundable cash can
  be returned as cash or converted into a hotel credit lot worth 110% of the
  cash (bonus rounded half up). Hotel credit is not available for non-refundable
  cancellations. Applied hotel credit returns to its original lots when the
  cancellation is refundable and is consumed otherwise. Unpaid deposit is no
  longer due.
  """
  def cancel_group(group_id, occurred_on, refund_method, expected_revision, operation_id) do
    with {:ok, occurred_on} <- operation_date(occurred_on),
         {:ok, refund_method} <- normalize_refund_method(refund_method),
         {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- ensure_active(group),
         refundable? = refundable?(group, occurred_on),
         :ok <- refund_method_available?(refundable?, refund_method) do
      {refunded, retained, issued} =
        settle_rooms!(
          group,
          active_rooms(group.rooms),
          occurred_on,
          refund_method,
          refundable?,
          operation_id
        )

      {:ok, updated} = load_group(group_id)

      {:ok,
       %{
         group_id: updated.group_id,
         refunded_cents: refunded,
         retained_cents: retained,
         credit_issued_cents: issued,
         revision: updated.revision
       }}
    end
  end

  @doc """
  Cancels selected rooms of an active group, settling exactly their allocated
  cash and credit with the same rules as a full cancellation. Every supplied
  identifier must name a distinct, active room of the group. When no active
  rooms remain the group itself becomes cancelled.
  """
  def cancel_rooms(
        group_id,
        room_ids,
        occurred_on,
        refund_method,
        expected_revision,
        operation_id
      ) do
    with {:ok, occurred_on} <- operation_date(occurred_on),
         {:ok, refund_method} <- normalize_refund_method(refund_method),
         {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- ensure_active(group),
         {:ok, settled_rooms} <- select_rooms(group, room_ids),
         refundable? = refundable?(group, occurred_on),
         :ok <- refund_method_available?(refundable?, refund_method) do
      {refunded, retained, issued} =
        settle_rooms!(group, settled_rooms, occurred_on, refund_method, refundable?, operation_id)

      {:ok, updated} = load_group(group_id)

      {:ok,
       %{
         group_id: updated.group_id,
         cancelled_room_ids: Enum.map(settled_rooms, & &1.room_id),
         refunded_cents: refunded,
         retained_cents: retained,
         credit_issued_cents: issued,
         revision: updated.revision
       }}
    end
  end

  defp normalize_refund_method(nil), do: {:ok, "cash"}
  defp normalize_refund_method(method) when method in @refund_methods, do: {:ok, method}
  defp normalize_refund_method(_), do: {:error, :invalid_operation}

  defp refundable?(group, occurred_on) do
    case @cancellation_windows[group.policy_version] do
      nil -> false
      days -> Date.diff(group.arrival_on, occurred_on) >= days
    end
  end

  defp refund_method_available?(true = _refundable?, _method), do: :ok
  defp refund_method_available?(false = _refundable?, "cash"), do: :ok

  defp refund_method_available?(false = _refundable?, "hotel_credit"),
    do: {:error, :refund_method_not_available}

  defp select_rooms(%Group{rooms: rooms}, room_ids) when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &is_binary/1) and Enum.uniq(room_ids) == room_ids do
      by_id = Map.new(rooms, fn room -> {room.room_id, room} end)
      resolved = Enum.map(room_ids, fn room_id -> by_id[room_id] end)

      if Enum.all?(resolved, &(match?(%Room{}, &1) and &1.status == "active")) do
        {:ok, Enum.sort_by(resolved, & &1.position)}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  defp select_rooms(_group, _room_ids), do: {:error, :invalid_rooms}

  # Shared settlement of whole rooms: cash moves to refunded, retained, or a
  # combined credit lot; applied credit is restored or consumed; the rooms stop
  # being active and, with them, drop out of every group total.
  defp settle_rooms!(group, settled_rooms, occurred_on, refund_method, refundable?, operation_id) do
    room_ids = Enum.map(settled_rooms, & &1.id)

    cash_rows =
      Repo.all(
        from a in RoomCashAllocation,
          where: a.room_id in ^room_ids and a.disposition == "held"
      )

    cash_total = Enum.sum(Enum.map(cash_rows, & &1.amount_cents))
    converts_to_credit? = refundable? and refund_method == "hotel_credit"

    {refunded, retained, issued} =
      cond do
        converts_to_credit? ->
          issued_value = cash_total + bonus_cents(cash_total)

          case issue_credit_lot!(group.guest_id, operation_id, occurred_on, issued_value) do
            nil -> :ok
            lot -> mark_cash_rows!(cash_rows, "converted", lot.id)
          end

          {0, 0, issued_value}

        refundable? ->
          mark_cash_rows!(cash_rows, "refunded", nil)
          {cash_total, 0, 0}

        true ->
          mark_cash_rows!(cash_rows, "retained", nil)
          {0, cash_total, 0}
      end

    applications =
      Repo.all(from a in RoomCreditApplication, where: a.room_id in ^room_ids)

    if refundable? do
      restore_applied_credit!(applications, occurred_on)
    else
      consume_applied_credit!(applications)
    end

    Repo.update_all(from(r in Room, where: r.id in ^room_ids), set: [status: "cancelled"])

    group_now_cancelled? = active_rooms(group.rooms) == settled_rooms

    extra =
      [
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained
      ] ++
        if(converts_to_credit?,
          do: [cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + cash_total],
          else: []
        ) ++
        if(group_now_cancelled?, do: [status: "cancelled"], else: [])

    bump_revision!(group, extra)
    {refunded, retained, issued}
  end

  # Ten percent bonus, rounded half up like every other percentage here.
  defp bonus_cents(cash), do: div(cash * 10 + 50, 100)

  defp issue_credit_lot!(_guest_id, _operation_id, _issued_on, value) when value <= 0,
    do: nil

  defp issue_credit_lot!(guest_id, operation_id, issued_on, value) do
    %CreditLot{}
    |> Ecto.Changeset.change(%{
      guest_id: guest_id,
      source_operation_id: operation_id,
      issued_on: issued_on,
      expires_on: Date.add(issued_on, @credit_bonus_days),
      remaining_cents: value
    })
    |> Repo.insert!()
  end

  defp mark_cash_rows!(rows, disposition, lot_id) do
    Enum.each(rows, fn row ->
      changes = %{disposition: disposition}
      changes = if is_nil(lot_id), do: changes, else: Map.put(changes, :credit_lot_id, lot_id)

      row
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()
    end)
  end

  defp restore_applied_credit!(applications, cancelled_on) do
    Enum.each(applications, fn application ->
      lot = Repo.get!(CreditLot, application.credit_lot_id)
      absorb = min(lot.unrecovered_clawback_cents, application.applied_cents)
      restored = application.applied_cents - absorb

      lot =
        if absorb > 0 do
          lot
          |> Ecto.Changeset.change(
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorb
          )
          |> Repo.update!()
        else
          lot
        end

      if restored > 0 and Date.compare(lot.expires_on, cancelled_on) == :gt do
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot.id),
          inc: [remaining_cents: restored]
        )
      end
    end)

    delete_applications!(applications)
  end

  defp consume_applied_credit!(applications) do
    delete_applications!(applications)
  end

  defp delete_applications!([]) do
    :ok
  end

  defp delete_applications!(applications) do
    ids = Enum.map(applications, & &1.id)
    Repo.delete_all(from a in RoomCreditApplication, where: a.id in ^ids)
    :ok
  end

  ## Payment reductions

  @doc """
  Records a provider correction against one recorded cash payment.

  Only cash from that payment still held on active rooms can be reduced; cash
  already refunded, retained, or converted to hotel credit is settled history.
  Held allocations belonging to the payment are removed in reverse allocation
  order across all groups - wherever transfers have taken them - and each
  affected room's outstanding deposit reopens by the amount removed. Every
  group whose funding changes advances its revision, as does the payment's
  original group; the result's revision is the original group's.
  """
  def reduce_cash_payment(payment_operation_id, amount_cents, expected_revision) do
    with {:ok, record} <- fetch_record(payment_operation_id),
         {:ok, group_id} <- recorded_payment_group(record),
         {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         held = held_cash(payment_operation_id),
         :ok <- reducible?(held),
         :ok <- reduction_amount?(amount_cents),
         :ok <- within_held?(amount_cents, held) do
      affected = remove_held_cash!(payment_operation_id, amount_cents, "reduced")
      bump_revision!(group)
      bump_changed_groups!(affected, group.id)

      {:ok, updated} = load_group(group_id)

      {:ok,
       %{
         payment_operation_id: payment_operation_id,
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  ## Chargebacks

  @doc """
  Reverses all cash of one recorded payment except portions already reduced.

  Held allocations reopen the active rooms' outstanding deposit wherever they
  currently fund rooms - transfers may have spread them across groups - and
  every group whose funding changes advances its revision, as does the
  payment's original group. Refunded and retained portions move to charged
  back, and converted principal moves to charged back while revoking the
  credit entitlement it created. A payment can be charged back whether its
  original group is active or cancelled.
  """
  def charge_back_payment(payment_operation_id, expected_revision) do
    with {:ok, record} <- fetch_record(payment_operation_id),
         {:ok, group_id} <- recorded_payment_group(record, :payment_not_chargeable),
         {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- chargeable?(payment_operation_id) do
      snapshot = disposition_snapshot(payment_operation_id)
      reversed = snapshot.held + snapshot.refunded + snapshot.retained + snapshot.converted

      affected = remove_held_cash!(payment_operation_id, snapshot.held, "charged_back")

      reclassify_dispositions!(
        payment_operation_id,
        ["refunded", "retained", "converted"],
        "charged_back"
      )

      Enum.each(snapshot.converted_by_lot, fn {lot_id, _principal} ->
        revoke_entitlement!(lot_id, payment_operation_id)
      end)

      bump_revision!(group,
        refunded_cents: max(0, group.refunded_cents - snapshot.refunded),
        retained_cents: max(0, group.retained_cents - snapshot.retained),
        cash_converted_to_credit_cents:
          max(0, group.cash_converted_to_credit_cents - snapshot.converted)
      )

      bump_changed_groups!(affected, group.id)

      {:ok, updated} = load_group(group_id)

      {:ok,
       %{
         payment_operation_id: payment_operation_id,
         group_id: updated.group_id,
         charged_back_cents: reversed,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp fetch_record(operation_id) do
    case Repo.one(from r in Record, where: r.operation_id == ^operation_id) do
      nil -> {:error, :operation_not_found}
      record -> {:ok, record}
    end
  end

  defp recorded_payment_group(record, code \\ :payment_not_reducible) do
    result = Jason.decode!(record.result)
    group_id = result["group_id"]

    if record.type == "record_cash_payment" and result["status"] == "applied" and
         is_binary(group_id) do
      {:ok, group_id}
    else
      {:error, code}
    end
  end

  defp held_cash(payment_operation_id) do
    Repo.one!(
      from a in RoomCashAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        where:
          a.payment_operation_id == ^payment_operation_id and a.disposition == "held" and
            r.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  defp reducible?(0 = _held), do: {:error, :payment_not_reducible}
  defp reducible?(held) when held > 0, do: :ok

  defp reduction_amount?(amount) when is_integer(amount) and amount > 0, do: :ok
  defp reduction_amount?(_), do: {:error, :invalid_amount}

  defp within_held?(amount, held) when amount <= held, do: :ok
  defp within_held?(_amount, _held), do: {:error, :reduction_exceeds_held_cash}

  defp chargeable?(payment_operation_id) do
    dispositions =
      from(a in RoomCashAllocation,
        where: a.payment_operation_id == ^payment_operation_id,
        group_by: a.disposition,
        select: {a.disposition, coalesce(sum(a.amount_cents), 0)}
      )
      |> Repo.all()
      |> Map.new()

    reversible =
      Map.get(dispositions, "held", 0) + Map.get(dispositions, "refunded", 0) +
        Map.get(dispositions, "retained", 0) + Map.get(dispositions, "converted", 0)

    if Map.has_key?(dispositions, "charged_back") or reversible == 0 do
      {:error, :payment_not_chargeable}
    else
      :ok
    end
  end

  defp disposition_snapshot(payment_operation_id) do
    rows =
      Repo.all(
        from a in RoomCashAllocation,
          where:
            a.payment_operation_id == ^payment_operation_id and
              a.disposition in ["held", "refunded", "retained", "converted"]
      )

    converted = Enum.filter(rows, &(&1.disposition == "converted"))

    %{
      held: sum_rows(rows, "held"),
      refunded: sum_rows(rows, "refunded"),
      retained: sum_rows(rows, "retained"),
      converted: sum_rows(rows, "converted"),
      converted_by_lot: Enum.group_by(converted, & &1.credit_lot_id)
    }
  end

  defp sum_rows(rows, disposition) do
    rows
    |> Enum.filter(&(&1.disposition == disposition))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  # Removes held cash of one payment in reverse allocation order - the most
  # recently created allocation first, wherever transfers have taken it -
  # splitting the last touched allocation if the amount stops mid-row. Each
  # removed cent reopens its room's deposit. Returns the identifiers of every
  # group whose funding changed so their revisions can advance.
  defp remove_held_cash!(payment_operation_id, amount_cents, new_disposition) do
    active_room_ids = from(r in Room, where: r.status == "active", select: r.id)

    rows =
      Repo.all(
        from a in RoomCashAllocation,
          where:
            a.payment_operation_id == ^payment_operation_id and a.disposition == "held" and
              a.room_id in subquery(active_room_ids),
          order_by: [desc: a.allocation_seq]
      )

    strip_rows!(rows, amount_cents, new_disposition, [])
  end

  defp strip_rows!([], 0 = _remaining, _new_disposition, group_ids), do: Enum.uniq(group_ids)

  defp strip_rows!([], remaining, _new_disposition, _group_ids) when remaining > 0 do
    raise ArgumentError,
      message: "removing #{remaining} cents beyond the payment's held allocations"
  end

  defp strip_rows!([row | rest], remaining, new_disposition, group_ids) do
    take = min(row.amount_cents, remaining)

    if take == row.amount_cents do
      row
      |> Ecto.Changeset.change(disposition: new_disposition)
      |> Repo.update!()
    else
      row
      |> Ecto.Changeset.change(amount_cents: row.amount_cents - take)
      |> Repo.update!()

      Repo.insert!(%RoomCashAllocation{
        group_id: row.group_id,
        room_id: row.room_id,
        payment_operation_id: row.payment_operation_id,
        amount_cents: take,
        disposition: new_disposition,
        allocation_seq: next_allocation_seq!(),
        moved_by_transfer: row.moved_by_transfer
      })
    end

    Repo.update_all(
      from(r in Room, where: r.id == ^row.room_id),
      inc: [cash_paid_cents: -take]
    )

    strip_rows!(rest, remaining - take, new_disposition, [row.group_id | group_ids])
  end

  # An applied operation advances the revision of every group whose state it
  # changes; the caller passes primary keys and excludes any group it already
  # bumped itself.
  defp bump_changed_groups!(group_ids, already_bumped_id) do
    group_ids
    |> Enum.uniq()
    |> Enum.reject(&(&1 == already_bumped_id))
    |> Enum.map(&Repo.one!(from(g in Group, where: g.id == ^&1)))
    |> Enum.each(&bump_revision!/1)

    :ok
  end

  defp reclassify_dispositions!(payment_operation_id, from_dispositions, to_disposition) do
    Repo.update_all(
      from(a in RoomCashAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and
            a.disposition in ^from_dispositions
      ),
      set: [disposition: to_disposition]
    )

    :ok
  end

  # Revokes the credit entitlement one payment earned inside a lot: the
  # standard 10%-bonus value of the cash it settled there minus the bonus value
  # through the preceding contribution, with the unattributed senior block
  # counted first. Whatever cannot be taken from the lot's remaining balance
  # becomes the lot's unrecovered clawback.
  defp revoke_entitlement!(lot_id, payment_operation_id) do
    sources =
      Repo.all(
        from a in RoomCashAllocation,
          where: a.credit_lot_id == ^lot_id and a.disposition in ["converted", "charged_back"],
          order_by: [asc: fragment("rowid")]
      )
      |> Enum.sort_by(&if(is_nil(&1.payment_operation_id), do: 0, else: 1))

    positions =
      sources
      |> Enum.with_index()
      |> Enum.filter(&(elem(&1, 0).payment_operation_id == payment_operation_id))
      |> Enum.map(&elem(&1, 1))

    case positions do
      [] ->
        :ok

      indices ->
        through = Enum.take(sources, List.last(indices) + 1)
        preceding = Enum.take(sources, List.first(indices))

        entitlement =
          bonus_cents(sum_allocations(through)) - bonus_cents(sum_allocations(preceding))

        claw_back_lot!(lot_id, entitlement)
    end
  end

  defp sum_allocations(rows), do: rows |> Enum.map(& &1.amount_cents) |> Enum.sum()

  defp claw_back_lot!(_lot_id, entitlement) when entitlement <= 0, do: :ok

  defp claw_back_lot!(lot_id, entitlement) do
    lot = Repo.get!(CreditLot, lot_id)
    recovered = min(lot.remaining_cents, entitlement)

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents - recovered,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + (entitlement - recovered)
    )
    |> Repo.update!()
  end

  @doc """
  The current disposition of one recorded payment's cash. Returns
  `{:error, :operation_not_found}` without a durable record and
  `{:error, :payment_not_reconcilable}` when the record is not an applied cash
  payment. Reading never changes state.

  Once any of the payment's funding has participated in a deposit transfer the
  statement also carries `held_by_group` - its held cash grouped by the group
  currently holding it, ordered by group identifier and summing to
  `held_cents`. Payments that never participated keep the earlier shape
  without the field.
  """
  def payment_statement(payment_operation_id) do
    with {:ok, record} <- fetch_record(payment_operation_id),
         {:ok, group_id} <- recorded_payment_group(record, :payment_not_reconcilable) do
      rows =
        Repo.all(
          from a in RoomCashAllocation,
            where: a.payment_operation_id == ^payment_operation_id
        )

      by_disposition =
        Enum.group_by(rows, & &1.disposition)
        |> Map.new(fn {disposition, rows} ->
          {disposition, rows |> Enum.map(& &1.amount_cents) |> Enum.sum()}
        end)

      statement = %{
        payment_operation_id: payment_operation_id,
        original_group_id: group_id,
        recorded_cents: rows |> Enum.map(& &1.amount_cents) |> Enum.sum(),
        held_cents: Map.get(by_disposition, "held", 0),
        refunded_cents: Map.get(by_disposition, "refunded", 0),
        retained_cents: Map.get(by_disposition, "retained", 0),
        converted_to_credit_cents: Map.get(by_disposition, "converted", 0),
        reduced_cents: Map.get(by_disposition, "reduced", 0),
        charged_back_cents: Map.get(by_disposition, "charged_back", 0)
      }

      if transferred_before?(payment_operation_id) do
        {:ok, Map.put(statement, :held_by_group, held_by_group(payment_operation_id))}
      else
        {:ok, statement}
      end
    end
  end

  ## Deposit transfers

  @doc """
  Moves held funding - cash and applied hotel credit - from one active group's
  rooms to another active group of the same guest, without moving money
  through a provider.

  Source existence resolves first, then destination existence; afterwards the
  source revision and then the destination revision are checked, and only then
  do the transfer rules apply. Funding leaves the source's active rooms most
  recently created allocation first, whatever its kind, and fills the
  destination's active rooms in their original order following the order in
  which units were drawn. Cash keeps its payment operation identity and credit
  keeps its original lot. Nothing settles or revalues: no bonus is computed,
  applied credit stays paused, and no ledger total changes - only which active
  rooms hold the funding.
  """
  def transfer_deposit(
        source_group_id,
        destination_group_id,
        amount_cents,
        source_expected_revision,
        destination_expected_revision
      ) do
    with {:ok, source} <- load_transfer_group(source_group_id),
         {:ok, destination} <- load_transfer_group(destination_group_id),
         :ok <- ensure_revision(source, source_expected_revision),
         :ok <- ensure_revision(destination, destination_expected_revision),
         :ok <- distinct_same_guest?(source, destination),
         :ok <- transfer_active?(source),
         :ok <- transfer_active?(destination),
         :ok <- usable_amount?(amount_cents),
         held = held_funding(source),
         :ok <- within_held_funding?(amount_cents, held),
         :ok <- within_destination_outstanding?(destination, amount_cents) do
      units = draw_held_funding!(source, amount_cents)
      allocate_funding!(destination, units)
      bump_revision!(source)
      bump_revision!(destination)

      {:ok, source_after} = load_group(source_group_id)
      {:ok, destination_after} = load_group(destination_group_id)

      {:ok,
       %{
         source_group_id: source_after.group_id,
         destination_group_id: destination_after.group_id,
         amount_cents: amount_cents,
         source_outstanding_deposit_cents: outstanding(source_after),
         destination_outstanding_deposit_cents: outstanding(destination_after),
         source_revision: source_after.revision,
         destination_revision: destination_after.revision
       }}
    end
  end

  defp load_transfer_group(group_id) do
    case load_group(group_id) do
      {:ok, group} -> {:ok, group}
      {:error, :group_not_found} -> {:error, :group_not_found, %{group_id: group_id}}
    end
  end

  defp distinct_same_guest?(
         %Group{group_id: group_id, guest_id: guest_id},
         %Group{group_id: group_id, guest_id: guest_id}
       ),
       do: {:error, :invalid_transfer}

  defp distinct_same_guest?(%Group{guest_id: guest_id}, %Group{guest_id: guest_id}), do: :ok

  defp distinct_same_guest?(_source, _destination), do: {:error, :invalid_transfer}

  defp transfer_active?(%Group{status: "active"}), do: :ok

  defp transfer_active?(group),
    do: {:error, :group_not_active, %{group_id: group.group_id}}

  # Held funding is everything currently allocated to the group's active
  # rooms: held cash plus applied hotel credit.
  defp held_funding(group) do
    room_ids = active_room_ids(group)

    cash =
      Repo.one!(
        from a in RoomCashAllocation,
          where: a.room_id in subquery(room_ids) and a.disposition == "held",
          select: coalesce(sum(a.amount_cents), 0)
      )

    credit =
      Repo.one!(
        from a in RoomCreditApplication,
          where: a.room_id in subquery(room_ids),
          select: coalesce(sum(a.applied_cents), 0)
      )

    cash + credit
  end

  defp within_held_funding?(amount, held) when amount <= held, do: :ok
  defp within_held_funding?(_amount, _held), do: {:error, :transfer_exceeds_held_funding}

  defp within_destination_outstanding?(group, amount) do
    if amount > outstanding(group) do
      {:error, :transfer_exceeds_outstanding}
    else
      :ok
    end
  end

  # Takes the requested funding off the source's active rooms, most recently
  # created allocation first regardless of kind, shrinking or removing the rows
  # involved and releasing each room's share. Returns the drawn units in draw
  # order, each keeping its provenance.
  defp draw_held_funding!(source, amount_cents) do
    room_ids = active_room_ids(source)

    cash_entries =
      Repo.all(
        from a in RoomCashAllocation,
          where: a.room_id in subquery(room_ids) and a.disposition == "held",
          order_by: [desc: a.allocation_seq]
      )
      |> Enum.map(&{:cash, &1})

    credit_entries =
      Repo.all(
        from a in RoomCreditApplication,
          where: a.room_id in subquery(room_ids),
          order_by: [desc: a.allocation_seq]
      )
      |> Enum.map(&{:credit, &1})

    draw_units!(merge_entries(cash_entries, credit_entries), amount_cents, [])
  end

  defp merge_entries([], right), do: right
  defp merge_entries(left, []), do: left

  defp merge_entries([left | left_rest] = left_entries, [right | right_rest] = right_entries) do
    if elem(left, 1).allocation_seq >= elem(right, 1).allocation_seq do
      [left | merge_entries(left_rest, right_entries)]
    else
      [right | merge_entries(left_entries, right_rest)]
    end
  end

  defp draw_units!(_entries, 0 = _remaining, acc), do: Enum.reverse(acc)

  defp draw_units!([], remaining, _acc) when remaining > 0,
    do: raise(ArgumentError, message: "transfer exceeds the source's held funding")

  defp draw_units!([{kind, row} | rest], remaining, acc) do
    available = if kind == :cash, do: row.amount_cents, else: row.applied_cents
    take = min(available, remaining)

    release_entry!(kind, row, take)
    draw_units!(rest, remaining - take, [unit_entry(kind, row, take) | acc])
  end

  defp release_entry!(:cash, row, take) do
    shrink_or_delete!(row, take, :amount_cents)

    Repo.update_all(
      from(r in Room, where: r.id == ^row.room_id),
      inc: [cash_paid_cents: -take]
    )

    :ok
  end

  defp release_entry!(:credit, row, take) do
    shrink_or_delete!(row, take, :applied_cents)

    Repo.update_all(
      from(r in Room, where: r.id == ^row.room_id),
      inc: [credit_paid_cents: -take]
    )

    :ok
  end

  defp shrink_or_delete!(row, take, field) do
    if take == Map.fetch!(row, field) do
      Repo.delete!(row)
    else
      row
      |> Ecto.Changeset.change(%{field => Map.fetch!(row, field) - take})
      |> Repo.update!()
    end

    :ok
  end

  defp unit_entry(:cash, row, take) do
    %{
      kind: :cash,
      payment_operation_id: row.payment_operation_id,
      credit_lot_id: nil,
      amount: take,
      via_transfer: true
    }
  end

  defp unit_entry(:credit, row, take) do
    %{
      kind: :credit,
      payment_operation_id: nil,
      credit_lot_id: row.credit_lot_id,
      amount: take,
      via_transfer: true
    }
  end

  defp active_room_ids(group) do
    from(r in Room, where: r.group_id == ^group.id and r.status == "active", select: r.id)
  end

  # Every allocation insert takes the next number of the shared creation
  # sequence so ordering stays consistent across kinds, groups, and transfers.
  defp next_allocation_seq! do
    cash_max = Repo.one!(from(a in RoomCashAllocation, select: max(a.allocation_seq)))
    credit_max = Repo.one!(from(a in RoomCreditApplication, select: max(a.allocation_seq)))

    Enum.max([cash_max || 0, credit_max || 0]) + 1
  end

  defp transferred_before?(payment_operation_id) do
    Repo.exists?(
      from a in RoomCashAllocation,
        where: a.payment_operation_id == ^payment_operation_id and a.moved_by_transfer
    )
  end

  defp held_by_group(payment_operation_id) do
    Repo.all(
      from a in RoomCashAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == a.group_id,
        where:
          a.payment_operation_id == ^payment_operation_id and a.disposition == "held" and
            r.status == "active" and g.status == "active",
        group_by: g.group_id,
        order_by: [asc: g.group_id],
        select: {g.group_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end

  ## Funding allocation

  defp cash_item(operation_id, amount) do
    %{kind: :cash, payment_operation_id: operation_id, credit_lot_id: nil, amount: amount}
  end

  defp credit_item(lot_id, amount) do
    %{kind: :credit, payment_operation_id: nil, credit_lot_id: lot_id, amount: amount}
  end

  # Places each funding item onto the active rooms in their original order,
  # filling one room's deposit before moving to the next.
  defp allocate_funding!(_group, []), do: :ok

  defp allocate_funding!(group, items) do
    Enum.reduce(items, active_rooms(group.rooms), &place_item!/2)
    :ok
  end

  defp place_item!(item, rooms) do
    {placed, placed_rooms} = fill_rooms(item, item.amount, rooms, [])

    unless placed == item.amount do
      raise ArgumentError, message: "funding exceeds the active rooms' deposit capacity"
    end

    placed_rooms
  end

  defp fill_rooms(_item, 0, rooms, acc), do: {0, Enum.reverse(acc, rooms)}

  defp fill_rooms(_item, _remaining, [], _acc) do
    raise ArgumentError, message: "funding exceeds the active rooms' deposit capacity"
  end

  defp fill_rooms(item, remaining, [room | rest], acc) do
    capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

    if capacity <= 0 do
      fill_rooms(item, remaining, rest, [room | acc])
    else
      take = min(capacity, remaining)
      write_take!(room, item, take)
      room = add_to_room(room, item, take)

      {placed, filled_rest} = fill_rooms(item, remaining - take, rest, [])
      {placed + take, Enum.reverse(acc, [room | filled_rest])}
    end
  end

  defp write_take!(room, %{kind: :cash} = item, take) do
    Repo.insert!(%RoomCashAllocation{
      group_id: room.group_id,
      room_id: room.id,
      payment_operation_id: item.payment_operation_id,
      amount_cents: take,
      disposition: "held",
      allocation_seq: next_allocation_seq!(),
      moved_by_transfer: Map.get(item, :via_transfer, false)
    })
  end

  defp write_take!(room, %{kind: :credit, credit_lot_id: lot_id}, take) do
    existing =
      Repo.one(
        from a in RoomCreditApplication,
          where: a.room_id == ^room.id and a.credit_lot_id == ^lot_id
      )

    case existing do
      nil ->
        Repo.insert!(%RoomCreditApplication{
          group_id: room.group_id,
          room_id: room.id,
          credit_lot_id: lot_id,
          applied_cents: take,
          allocation_seq: next_allocation_seq!()
        })

      application ->
        application
        |> Ecto.Changeset.change(applied_cents: application.applied_cents + take)
        |> Repo.update!()
    end
  end

  defp add_to_room(room, %{kind: :cash}, take) do
    bump_room!(room, :cash_paid_cents, take)
  end

  defp add_to_room(room, %{kind: :credit}, take) do
    bump_room!(room, :credit_paid_cents, take)
  end

  defp bump_room!(room, field, take) do
    new_value = Map.get(room, field) + take

    room
    |> Ecto.Changeset.change(%{field => new_value})
    |> Repo.update!()

    Map.put(room, field, new_value)
  end

  ## Shared helpers

  defp active_rooms(rooms), do: Enum.filter(rooms, &(&1.status == "active"))

  defp outstanding(group), do: group_totals(group).outstanding_deposit_cents

  defp group_query(group_id) do
    rooms_query = from r in Room, order_by: r.position

    from g in Group,
      where: g.group_id == ^group_id,
      preload: [rooms: ^rooms_query]
  end

  defp load_group(group_id) do
    case Repo.one(group_query(group_id)) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp ensure_revision(_group, :none), do: :ok

  defp ensure_revision(group, expected_revision) do
    if expected_revision == group.revision do
      :ok
    else
      {:error, :stale_revision,
       %{
         group_id: group.group_id,
         expected_revision: expected_revision,
         actual_revision: group.revision
       }}
    end
  end

  defp ensure_active(%Group{status: "active"}), do: :ok
  defp ensure_active(_group), do: {:error, :group_not_active}

  defp usable_amount?(amount) when is_integer(amount) and amount > 0, do: :ok
  defp usable_amount?(_amount), do: {:error, :invalid_amount}

  defp within_outstanding?(group, amount) do
    if amount > outstanding(group) do
      {:error, :payment_exceeds_outstanding}
    else
      :ok
    end
  end

  defp operation_date(value) do
    case to_date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_operation}
    end
  end

  defp stay_date(value) do
    case to_date(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_stay}
    end
  end

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp to_date(_), do: {:error, :invalid_date}

  defp bump_revision!(group, extra \\ []) do
    {:ok, _updated} = update_group!(group, Keyword.put(extra, :revision, group.revision + 1))
    refresh_money_columns!(group.id)
    :ok
  end

  defp refresh_money_columns!(group_id) do
    totals =
      Repo.one!(
        from r in Room,
          where: r.group_id == ^group_id and r.status == "active",
          select: %{
            lodging_total_cents: coalesce(sum(r.lodging_cents), 0),
            deposit_due_cents: coalesce(sum(r.deposit_due_cents), 0),
            cash_paid_cents: coalesce(sum(r.cash_paid_cents), 0),
            credit_paid_cents: coalesce(sum(r.credit_paid_cents), 0)
          }
      )

    Repo.update_all(
      from(g in Group, where: g.id == ^group_id),
      set: [
        lodging_total_cents: totals.lodging_total_cents,
        deposit_due_cents: totals.deposit_due_cents,
        cash_paid_cents: totals.cash_paid_cents,
        credit_paid_cents: totals.credit_paid_cents,
        deposit_paid_cents: totals.cash_paid_cents + totals.credit_paid_cents
      ]
    )

    :ok
  end

  defp update_group!(group, changes) do
    group
    |> Group.update_changeset(Map.new(changes))
    |> Repo.update()
  end
end
