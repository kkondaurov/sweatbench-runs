defmodule GroupStay.Groups do
  @moduledoc """
  Group reservations: opening, funding, rescheduling, and cancelling groups,
  applying hotel credit, plus the deposit state each partner operation
  produces.

  Every function runs inside its own transaction when called directly and
  joins the caller's transaction when one is already open, so durable
  submission can commit an operation record in the same transaction as the
  domain changes. Transaction mode is `:immediate` so concurrent operations
  serialize on the single SQLite writer before reading a group, keeping the
  revision contract and at-most-once operation effects reliable.

  Rejections are returned as values, never as rollbacks: each function
  validates completely before its first write, so a handled rejection leaves
  no domain state behind.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Policy
  alias GroupStay.Groups.Room
  alias GroupStay.Ledger
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
             | :insufficient_credit}
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
  Applies cash to an active group's outstanding deposit.
  """
  @spec record_cash_payment(map()) :: apply_result()
  def record_cash_payment(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, amount} <- payment_amount(params.amount_cents),
           :ok <- within_outstanding(group, amount) do
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
           outstanding_deposit_cents: outstanding(%Group{group | cash_paid_cents: new_paid}),
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
  Cancels a group and settles its deposit: cash is refunded, retained, or
  converted to hotel credit according to the group's fixed policy version,
  how far ahead cancellation happens, and the requested `refund_method`;
  applied hotel credit returns to its lots on a refundable cancellation and
  is consumed otherwise; and any unpaid deposit is no longer due.
  """
  @spec cancel_group(map()) :: apply_result()
  def cancel_group(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, refundable?} <- refund_available(group, params.refund_method, params.occurred_on) do
        refund_method = params.refund_method || "cash"

        settlement =
          cond do
            refundable? and refund_method == "hotel_credit" ->
              Credit.restore_group_credit!(group.id)
              converted = group.cash_paid_cents

              %{
                refunded: 0,
                retained: 0,
                converted: converted,
                credit_issued: issue_credit_lot!(group, converted, params)
              }

            refundable? ->
              Credit.restore_group_credit!(group.id)

              %{refunded: group.cash_paid_cents, retained: 0, converted: 0, credit_issued: 0}

            true ->
              Credit.consume_group_credit!(group.id)

              %{refunded: 0, retained: group.cash_paid_cents, converted: 0, credit_issued: 0}
          end

        new_revision = group.revision + 1

        group
        |> cast_group(%{
          status: "cancelled",
          cash_paid_cents: 0,
          refunded_cents: settlement.refunded,
          retained_cents: settlement.retained,
          revision: new_revision
        })
        |> Repo.update!()

        record_settlement(group, settlement, params)

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
  Applies the group guest's hotel credit to an active group's outstanding
  deposit. Credit is consumed from the guest's unexpired lots by earliest
  expiry and then by source operation; while it funds the group its expiry is
  paused, until the group is cancelled.
  """
  @spec apply_hotel_credit(map()) :: apply_result()
  def apply_hotel_credit(params) do
    transaction(fn ->
      with {:ok, group} <- fetch_group(params.group_id),
           :ok <- revision_guard(group, params.expected_revision),
           :ok <- active_guard(group),
           {:ok, amount} <- payment_amount(params.amount_cents),
           :ok <- within_outstanding(group, amount),
           :ok <- sufficient_credit(group, amount, params.occurred_on) do
        new_revision = group.revision + 1

        group
        |> cast_group(%{revision: new_revision})
        |> Repo.update!()

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding(group),
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

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
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

  defp within_outstanding(group, amount) do
    if amount <=
         group.deposit_due_cents - group.cash_paid_cents - Credit.applied_to_group(group.id) do
      :ok
    else
      {:error, :payment_exceeds_outstanding}
    end
  end

  defp refund_available(group, refund_method, occurred_on) do
    refundable? = Policy.refundable?(group.policy_version, group.arrival_on, occurred_on)

    if not refundable? and refund_method == "hotel_credit" do
      {:error, :refund_method_not_available}
    else
      {:ok, refundable?}
    end
  end

  defp sufficient_credit(group, amount, occurred_on) do
    case Credit.apply_to_group(group, amount, occurred_on) do
      :ok -> :ok
      :insufficient -> {:error, :insufficient_credit}
    end
  end

  defp outstanding(group) do
    max(
      group.deposit_due_cents - group.cash_paid_cents - Credit.applied_to_group(group.id),
      0
    )
  end

  defp room_deposit(lodging, "flexible"), do: percent_half_up(lodging, @flexible_deposit_percent)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp issue_credit_lot!(_group, 0, _params), do: 0

  defp issue_credit_lot!(group, cash, params) do
    value = cash + percent_half_up(cash, @credit_bonus_percent)

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
