defmodule GroupStay.Groups do
  @moduledoc """
  Domain logic for group reservations: opening, funding, rescheduling, and
  cancelling groups, hotel credit, plus the finance totals derived from them.

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
  """

  import Ecto.Query, only: [from: 2]

  alias GroupStay.Repo
  alias GroupStay.Groups.{CreditLot, Group, GroupCreditApplication, Room}

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
  Cash accounting totals across all groups:

    * `cash_held_cents` - cash currently applied to active reservations;
    * `cash_refunded_cents` - cash returned after refundable cancellations;
    * `cash_retained_cents` - cash kept by the hotel after non-refundable cancellations;
    * `cash_converted_to_credit_cents` - cash turned into hotel credit instead of refunded;
    * `credit_liability_cents` - outstanding hotel credit, both available and applied to active groups.

  Expiry is evaluated as of `as_of`; credit funding an active group does not
  expire while it funds that group.
  """
  def ledger_totals(as_of \\ Date.utc_today()) do
    cash = cash_totals()

    %{
      cash_held_cents: cash.cash_held_cents,
      cash_refunded_cents: cash.cash_refunded_cents,
      cash_retained_cents: cash.cash_retained_cents,
      cash_converted_to_credit_cents: cash.cash_converted_to_credit_cents,
      credit_liability_cents: available_credit_total(as_of) + applied_active_credit_total()
    }
  end

  defp cash_totals do
    Repo.one!(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.cash_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0),
          cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
        }
    )
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
      from a in GroupCreditApplication,
        join: g in Group,
        on: g.id == a.group_id,
        select: coalesce(sum(a.applied_cents), 0),
        where: g.status == "active"
    )
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
          %Room{
            position: index,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents
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
  """
  def record_cash_payment(group_id, amount_cents, expected_revision) do
    with {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- ensure_active(group),
         :ok <- usable_amount?(amount_cents),
         :ok <- within_outstanding?(group, amount_cents) do
      {:ok, updated} =
        update_group!(group,
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: group.cash_paid_cents + amount_cents,
          revision: group.revision + 1
        )

      {:ok,
       %{
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
         revision: updated.revision
       }}
    end
  end

  ## Hotel credit

  @doc """
  Applies the guest's hotel credit to an active group's outstanding deposit.

  Credit is consumed from unexpired lots by earliest expiry and then by the
  source operation identifier. Which lots funded the group is preserved so the
  amounts can be restored if the group is later cancelled while refundable.
  While credit funds an active group its expiry is paused.
  """
  def apply_hotel_credit(group_id, amount_cents, occurred_on, expected_revision) do
    with {:ok, occurred_on} <- operation_date(occurred_on),
         {:ok, group} <- load_group(group_id),
         :ok <- ensure_revision(group, expected_revision),
         :ok <- ensure_active(group),
         :ok <- usable_amount?(amount_cents),
         :ok <- within_outstanding?(group, amount_cents),
         :ok <- enough_unexpired_credit?(group.guest_id, amount_cents, occurred_on) do
      consume_lots!(group.id, group.guest_id, amount_cents, occurred_on)

      {:ok, updated} =
        update_group!(group,
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          credit_paid_cents: group.credit_paid_cents + amount_cents,
          revision: group.revision + 1
        )

      {:ok,
       %{
         group_id: updated.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
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

  defp consume_lots!(group_id, guest_id, amount_cents, as_of) do
    available_lots_query(guest_id, as_of)
    |> Repo.all()
    |> consume_from_lots!(group_id, amount_cents)
  end

  defp consume_from_lots!(_lots, _group_id, 0), do: :ok

  defp consume_from_lots!([lot | rest], group_id, remaining) do
    take = min(lot.remaining_cents, remaining)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - take)
    |> Repo.update!()

    record_application!(group_id, lot.id, take)
    consume_from_lots!(rest, group_id, remaining - take)
  end

  defp record_application!(group_id, lot_id, cents) do
    existing =
      Repo.one(
        from a in GroupCreditApplication,
          where: a.group_id == ^group_id and a.credit_lot_id == ^lot_id
      )

    case existing do
      nil ->
        %GroupCreditApplication{group_id: group_id, credit_lot_id: lot_id}
        |> Ecto.Changeset.change(applied_cents: cents)
        |> Repo.insert!()

      application ->
        application
        |> Ecto.Changeset.change(applied_cents: application.applied_cents + cents)
        |> Repo.update!()
    end
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
  Cancels an active group.

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
      settle_cancellation(group, occurred_on, refund_method, refundable?, operation_id)
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

  defp settle_cancellation(group, occurred_on, refund_method, refundable?, operation_id) do
    cash_paid = group.cash_paid_cents

    {refunded, retained, converted, issued} =
      if refundable? do
        if refund_method == "hotel_credit" do
          issued_value = cash_paid + bonus_cents(cash_paid)
          issue_credit_lot!(group.guest_id, operation_id, occurred_on, issued_value)
          {0, 0, cash_paid, issued_value}
        else
          {cash_paid, 0, 0, 0}
        end
      else
        {0, cash_paid, 0, 0}
      end

    if refundable? do
      restore_applied_credit!(group.id, occurred_on)
    else
      consume_applied_credit!(group.id)
    end

    {:ok, updated} =
      update_group!(group,
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
        revision: group.revision + 1
      )

    {:ok,
     %{
       group_id: updated.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       credit_issued_cents: issued,
       revision: updated.revision
     }}
  end

  # Ten percent bonus, rounded half up like every other percentage here.
  defp bonus_cents(cash), do: div(cash * 10 + 50, 100)

  defp issue_credit_lot!(_guest_id, _operation_id, _issued_on, value) when value <= 0,
    do: :ok

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

  defp restore_applied_credit!(group_id, cancelled_on) do
    applications = Repo.all(from a in GroupCreditApplication, where: a.group_id == ^group_id)

    Enum.each(applications, fn application ->
      lot = Repo.get!(CreditLot, application.credit_lot_id)

      if Date.compare(lot.expires_on, cancelled_on) == :gt do
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot.id),
          inc: [remaining_cents: application.applied_cents]
        )
      end

      # A lot whose expiry is already past on the cancellation date stays
      # expired: the restored amount reduces the credit liability instead of
      # becoming available again.
    end)

    Repo.delete_all(from a in GroupCreditApplication, where: a.group_id == ^group_id)
  end

  defp consume_applied_credit!(group_id) do
    Repo.delete_all(from a in GroupCreditApplication, where: a.group_id == ^group_id)
  end

  ## Shared helpers

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
    if amount > group.deposit_due_cents - group.deposit_paid_cents do
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

  defp update_group!(group, changes) do
    group
    |> Group.update_changeset(Map.new(changes))
    |> Repo.update()
  end
end
