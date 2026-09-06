defmodule GroupStay.Groups do
  @moduledoc """
  The deposit-keeping context: group reservations, their rooms, their
  payments, the hotel credit applied to them, and the finance ledger totals
  derived from that state.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Credit.Application
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Payment
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  @held "held"
  @policy_cutoff ~D[2027-01-01]

  def group_exists?(group_id) when is_binary(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  @doc """
  Loads a group with its rooms (in their original order), payments, and
  credit applications.
  """
  def fetch_by_group_id(group_id) when is_binary(group_id) do
    case Repo.one(from g in Group, where: g.group_id == ^group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from r in Room, where: r.group_id == ^group.id, order_by: r.position, select: r
          )

        payments = Repo.all(from p in Payment, where: p.group_id == ^group.id, select: p)

        applications =
          Repo.all(from a in Application, where: a.group_id == ^group.id, select: a)

        %{group | rooms: rooms, payments: payments, credit_applications: applications}
    end
  end

  @doc """
  The group view returned by the read API.
  """
  def view(%Group{} = group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until_iso(group),
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => deposit_paid_cents(group),
      "cash_paid_cents" => cash_paid_cents(group),
      "credit_paid_cents" => credit_paid_cents(group),
      "outstanding_deposit_cents" => outstanding_deposit_cents(group)
    }
  end

  # -- policy versions ---------------------------------------------------------

  @doc """
  The policy version a group receives when it is opened, fixed by its rate
  plan and booking date.
  """
  def policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc "The group's fixed policy version."
  def policy_version(%Group{policy_version: nil} = group),
    do: policy_version_for(group.rate_plan, group.booked_on)

  def policy_version(%Group{policy_version: policy_version}), do: policy_version

  @doc "The cancellation window in days, or nil for a non-refundable policy."
  def cancellation_window("flex-14"), do: 14
  def cancellation_window("flex-30"), do: 30
  def cancellation_window(_), do: nil

  @doc """
  The last date on which cancelling the group is still refundable, or nil
  for a non-refundable policy.
  """
  def refundable_until(%Group{} = group) do
    case cancellation_window(policy_version(group)) do
      nil -> nil
      window -> Date.add(group.arrival_on, -window)
    end
  end

  @doc "`refundable_until` as an ISO 8601 string, or nil."
  def refundable_until_iso(%Group{} = group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  # -- deposit totals ----------------------------------------------------------

  @doc """
  Total cash and credit ever applied to the group's deposit.
  """
  def deposit_paid_cents(%Group{} = group),
    do: cash_paid_cents(group) + credit_paid_cents(group)

  @doc "Total cash ever applied to the group's deposit."
  def cash_paid_cents(%Group{payments: payments}),
    do: Enum.sum(Enum.map(payments, & &1.amount_cents))

  @doc "Total hotel credit ever applied to the group's deposit."
  def credit_paid_cents(%Group{credit_applications: applications}),
    do: Enum.sum(Enum.map(applications, & &1.amount_cents))

  @doc """
  Deposit still outstanding on an active group. Once the group is cancelled
  the unpaid remainder is no longer due, so nothing is outstanding.
  """
  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group) do
    group.deposit_due_cents - held_paid_cents(group) - applied_credit_cents(group)
  end

  @doc "Cash currently applied to the group's deposit."
  def held_paid_cents(%Group{payments: payments}), do: held_paid_cents(payments)

  def held_paid_cents(payments) when is_list(payments) do
    payments
    |> Enum.filter(&(&1.state == @held))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  @doc "Hotel credit currently applied to the group's deposit."
  def applied_credit_cents(%Group{credit_applications: applications}) do
    applications
    |> Enum.filter(&(&1.state == "applied"))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  # -- ledger ------------------------------------------------------------------

  @doc """
  Finance totals across all groups, bucketed by payment state, plus the
  hotel-credit liability. Expiry is evaluated as of `as_of`.
  """
  def ledger_totals(as_of) do
    %{
      "cash_held_cents" => sum_payment_state(@held),
      "cash_refunded_cents" => sum_payment_state("refunded"),
      "cash_retained_cents" => sum_payment_state("retained"),
      "cash_converted_to_credit_cents" => sum_payment_state("converted"),
      "credit_liability_cents" => Credit.liability_cents(as_of)
    }
  end

  defp sum_payment_state(state) do
    Repo.one(
      from p in Payment,
        where: p.state == ^state,
        select: coalesce(sum(p.amount_cents), 0)
    )
    |> normalize_sum()
  end

  defp normalize_sum(nil), do: 0
  defp normalize_sum(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_sum(value) when is_integer(value), do: value

  # -- writes ------------------------------------------------------------------

  @doc """
  Inserts a group and its rooms in their original order. Returns
  `{:error, :group_already_exists}` when the partner group identifier
  is already taken.
  """
  def create_group(attrs, rooms) do
    %Group{}
    |> Group.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        insert_rooms(group, rooms)
        {:ok, group}

      {:error, _changeset} ->
        {:error, :group_already_exists}
    end
  end

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, index} ->
      %Room{}
      |> Room.changeset(%{
        group_id: group.id,
        room_id: room.room_id,
        nightly_rate_cents: room.nightly_rate_cents,
        position: index
      })
      |> Repo.insert!()
    end)
  end

  @doc """
  Records cash applied to a group's deposit.
  """
  def create_payment(group, amount_cents, recorded_on) do
    %Payment{}
    |> Payment.changeset(%{
      group_id: group.id,
      amount_cents: amount_cents,
      state: @held,
      recorded_on: recorded_on
    })
    |> Repo.insert()
  end

  @doc """
  Moves every held payment of the group to the settlement state and marks the
  group cancelled, bumping its revision. The revision guard makes the update
  fail with `{:error, :stale}` when the group changed concurrently.
  """
  def cancel_group(group, settlement_state) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(p in Payment, where: p.group_id == ^group.id and p.state == ^@held)
    |> Repo.update_all(set: [state: settlement_state, updated_at: now])

    from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
    |> Repo.update_all(set: [status: "cancelled", revision: group.revision + 1, updated_at: now])
    |> case do
      {1, _} ->
        {:ok, %{group | status: "cancelled", revision: group.revision + 1}}

      {_, _} ->
        {:error, :stale}
    end
  end

  @doc """
  Shifts the group's stay dates, bumping its revision. The revision guard
  makes the update fail with `{:error, :stale}` when the group changed
  concurrently.
  """
  def reschedule_group(group, arrival_on, departure_on) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
    |> Repo.update_all(
      set: [
        arrival_on: arrival_on,
        departure_on: departure_on,
        revision: group.revision + 1,
        updated_at: now
      ]
    )
    |> case do
      {1, _} ->
        {:ok,
         %{
           group
           | arrival_on: arrival_on,
             departure_on: departure_on,
             revision: group.revision + 1
         }}

      {_, _} ->
        {:error, :stale}
    end
  end

  @doc """
  Bumps the group's revision, returning the new revision, or `{:error, :stale}`
  when the group changed concurrently.
  """
  def bump_revision(group) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(g in Group, where: g.id == ^group.id and g.revision == ^group.revision)
    |> Repo.update_all(set: [revision: group.revision + 1, updated_at: now])
    |> case do
      {1, _} -> {:ok, group.revision + 1}
      {_, _} -> {:error, :stale}
    end
  end

  @doc "The group's current revision, re-read from the database."
  def current_revision(group_id) do
    case Repo.one(from g in Group, where: g.group_id == ^group_id, select: g.revision) do
      nil -> 0
      revision -> revision
    end
  end
end
