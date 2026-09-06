defmodule GroupStay.Groups do
  @moduledoc """
  Group reservations: opening, funding, rescheduling, and cancelling groups,
  plus the deposit state each partner operation produces.

  Every operation runs inside its own transaction so a rejection leaves the
  database exactly as it was. Transaction mode is `:immediate` so concurrent
  operations serialize on the single SQLite writer before reading a group,
  keeping the revision contract reliable.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @flexible_deposit_percent 20
  @refund_notice_days 14

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
             | :group_already_exists}
          | {:stale, String.t(), integer(), integer()}

  @doc """
  Opens a new group reservation. Returns `{:ok, result}` with `group_id`,
  `deposit_due_cents`, and `revision`, or `{:error, code}`.
  """
  @spec open_group(map()) :: apply_result()
  def open_group(attrs) do
    transaction(fn ->
      ensure_absent!(attrs.group_id)

      arrival = stay_date!(attrs.arrival_on)
      departure = stay_date!(attrs.departure_on)
      at_least_one_night!(arrival, departure)
      rooms = valid_rooms!(attrs.rooms)
      rate_plan = known_rate_plan!(attrs.rate_plan)

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
    end)
  end

  @doc """
  Applies cash to an active group's outstanding deposit.
  """
  @spec record_cash_payment(map()) :: apply_result()
  def record_cash_payment(params) do
    transaction(fn ->
      group = fetch_group!(params.group_id)
      revision_guard!(group, params.expected_revision)
      active_guard!(group)
      amount = payment_amount!(params.amount_cents)
      within_outstanding!(group, amount)

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
         outstanding_deposit_cents: group.deposit_due_cents - new_paid,
         revision: new_revision
       }}
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
      group = fetch_group!(params.group_id)
      revision_guard!(group, params.expected_revision)
      active_guard!(group)

      new_arrival = stay_date!(params.new_arrival_on)
      future_arrival!(new_arrival, params.occurred_on)

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
         revision: new_revision
       }}
    end)
  end

  @doc """
  Cancels a group and settles its deposit: cash is refunded or retained
  according to the rate plan and how far ahead cancellation happens, and any
  unpaid deposit is no longer due.
  """
  @spec cancel_group(map()) :: apply_result()
  def cancel_group(params) do
    transaction(fn ->
      group = fetch_group!(params.group_id)
      revision_guard!(group, params.expected_revision)
      active_guard!(group)

      {refunded, retained} = settlement(group, params.occurred_on)
      new_revision = group.revision + 1

      group
      |> cast_group(%{
        status: "cancelled",
        cash_paid_cents: 0,
        refunded_cents: refunded,
        retained_cents: retained,
        revision: new_revision
      })
      |> Repo.update!()

      record_settlement(group, refunded, retained, params)

      {:ok,
       %{
         group_id: group.group_id,
         refunded_cents: refunded,
         retained_cents: retained,
         revision: new_revision
       }}
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
        Repo.preload(group, rooms: from(r in Room, order_by: [asc: r.position]))
    end
  end

  @doc """
  Rounds `amount * percent / 100` to the nearest cent, with an exact
  half-cent rounding upward.
  """
  @spec percent_half_up(integer(), pos_integer()) :: integer()
  def percent_half_up(amount, percent) do
    div(2 * amount * percent + 100, 200)
  end

  ## Transaction plumbing

  defp transaction(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, value} -> value
      {:error, reason} -> reason
    end
  end

  defp rollback!(reason), do: Repo.rollback({:error, reason})

  defp fetch_group!(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> rollback!(:group_not_found)
      group -> group
    end
  end

  defp revision_guard!(_group, nil), do: :ok

  defp revision_guard!(group, expected_revision) do
    if expected_revision == group.revision do
      :ok
    else
      Repo.rollback({:stale, group.group_id, expected_revision, group.revision})
    end
  end

  defp active_guard!(group) do
    if group.status == "active", do: :ok, else: rollback!(:group_not_active)
  end

  defp ensure_absent!(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      rollback!(:group_already_exists)
    else
      :ok
    end
  end

  defp stay_date!(value) do
    case parse_date(value) do
      {:ok, date} -> date
      :error -> rollback!(:invalid_stay)
    end
  end

  defp at_least_one_night!(arrival, departure) do
    if Date.compare(departure, arrival) == :gt, do: :ok, else: rollback!(:invalid_stay)
  end

  defp future_arrival!(new_arrival, occurred_on) do
    if Date.compare(new_arrival, occurred_on) == :gt, do: :ok, else: rollback!(:invalid_stay)
  end

  defp valid_rooms!(rooms) do
    if is_list(rooms) and rooms != [] do
      parsed = Enum.map(rooms, &valid_room!/1)

      if unique_room_ids?(parsed) do
        parsed
      else
        rollback!(:invalid_rooms)
      end
    else
      rollback!(:invalid_rooms)
    end
  end

  defp valid_room!(room) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate = room["nightly_rate_cents"]

    if is_binary(room_id) and room_id != "" and is_integer(nightly_rate) and nightly_rate > 0 do
      %{room_id: room_id, nightly_rate_cents: nightly_rate}
    else
      rollback!(:invalid_rooms)
    end
  end

  defp valid_room!(_other), do: rollback!(:invalid_rooms)

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, & &1.room_id)
    Enum.uniq(room_ids) == room_ids
  end

  defp known_rate_plan!(rate_plan) do
    if rate_plan in @rate_plans, do: rate_plan, else: rollback!(:invalid_rate_plan)
  end

  defp payment_amount!(amount) do
    if is_integer(amount) and amount > 0, do: amount, else: rollback!(:invalid_amount)
  end

  defp within_outstanding!(group, amount) do
    if amount <= group.deposit_due_cents - group.cash_paid_cents do
      :ok
    else
      rollback!(:payment_exceeds_outstanding)
    end
  end

  defp room_deposit(lodging, "flexible"), do: percent_half_up(lodging, @flexible_deposit_percent)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp settlement(group, occurred_on) do
    days_notice = Date.diff(group.arrival_on, occurred_on)
    refundable? = group.rate_plan == "flexible" and days_notice >= @refund_notice_days

    if refundable?, do: {group.cash_paid_cents, 0}, else: {0, group.cash_paid_cents}
  end

  defp record_settlement(_group, 0, 0, _params), do: :ok

  defp record_settlement(group, refunded, retained, params) do
    if refunded > 0 do
      Ledger.record!(%{
        group_id: group.id,
        type: "cash_refunded",
        amount_cents: refunded,
        occurred_on: params.occurred_on,
        operation_id: params.operation_id
      })
    end

    if retained > 0 do
      Ledger.record!(%{
        group_id: group.id,
        type: "cash_retained",
        amount_cents: retained,
        occurred_on: params.occurred_on,
        operation_id: params.operation_id
      })
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
