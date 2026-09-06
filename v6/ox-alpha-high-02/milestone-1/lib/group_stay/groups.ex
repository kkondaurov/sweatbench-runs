defmodule GroupStay.Groups do
  @moduledoc """
  Applies group reservation and deposit operations.

  Every public command runs inside its own transaction, so a rejected
  operation leaves the database exactly as it was before it began.
  Commands return one of:

    * `{:ok, group}` - the operation was applied;
    * `{:error, reason}` - the operation was rejected; `reason` is a stable
      rejection code atom.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.Group

  @rate_plans ~w(flexible advance_purchase)
  @deposit_percentage 20
  @refundable_lead_days 14

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
  Opens a new group reservation at revision 1.
  """
  def open_group(attrs) do
    Repo.transaction(fn ->
      if Repo.exists?(from g in Group, where: g.group_id == ^attrs.group_id) do
        Repo.rollback(:group_already_exists)
      else
        with :ok <- validate_stay(attrs.arrival_on, attrs.departure_on),
             :ok <- validate_rooms(attrs.rooms),
             :ok <- validate_rate_plan(attrs.rate_plan) do
          insert_group(attrs)
        end
      end
    end)
    |> unwrap()
  end

  @doc """
  Records a cash payment against a group's outstanding deposit.
  """
  def record_cash_payment(group_id, amount_cents, expected_revision) do
    Repo.transaction(fn ->
      with_group(group_id, expected_revision, fn group ->
        cond do
          group.status != "active" ->
            Repo.rollback(:group_not_active)

          not usable_payment?(amount_cents) ->
            Repo.rollback(:invalid_amount)

          amount_cents > outstanding_deposit_cents(group) ->
            Repo.rollback(:payment_exceeds_outstanding)

          true ->
            update_group(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount_cents,
              revision: group.revision + 1
            })
        end
      end)
    end)
    |> unwrap()
  end

  @doc """
  Moves a group's stay so it starts on `new_arrival_on`, shifting the
  departure date by the same number of days.
  """
  def reschedule_group(group_id, new_arrival_on, occurred_on, expected_revision) do
    Repo.transaction(fn ->
      with_group(group_id, expected_revision, fn group ->
        if group.status != "active" do
          Repo.rollback(:group_not_active)
        else
          if valid_new_arrival?(new_arrival_on, occurred_on) do
            shift = Date.diff(group.departure_on, group.arrival_on)

            update_group(group, %{
              arrival_on: new_arrival_on,
              departure_on: Date.add(new_arrival_on, shift),
              revision: group.revision + 1
            })
          else
            Repo.rollback(:invalid_stay)
          end
        end
      end)
    end)
    |> unwrap()
  end

  @doc """
  Cancels a group, moving its paid cash to refunded or retained.
  """
  def cancel_group(group_id, occurred_on, expected_revision) do
    Repo.transaction(fn ->
      with_group(group_id, expected_revision, fn group ->
        if group.status != "active" do
          Repo.rollback(:group_not_active)
        else
          refunded = if refundable?(group, occurred_on), do: group.deposit_paid_cents, else: 0

          update_group(group, %{
            status: "cancelled",
            deposit_paid_cents: 0,
            refunded_cents: group.refunded_cents + refunded,
            retained_cents: group.retained_cents + (group.deposit_paid_cents - refunded),
            revision: group.revision + 1
          })
        end
      end)
    end)
    |> unwrap()
  end

  @doc """
  Cash totals across all groups: cash held on active reservations plus the
  cash already moved out by cancellations.
  """
  def ledger_totals do
    held =
      from g in Group,
        where: g.status == "active",
        select: coalesce(sum(g.deposit_paid_cents), 0)

    refunded = from g in Group, select: coalesce(sum(g.refunded_cents), 0)
    retained = from g in Group, select: coalesce(sum(g.retained_cents), 0)

    %{
      cash_held_cents: Repo.one(held),
      cash_refunded_cents: Repo.one(refunded),
      cash_retained_cents: Repo.one(retained)
    }
  end

  @doc """
  The deposit still owed for a group. Unpaid deposit on a cancelled group is
  no longer due.
  """
  def outstanding_deposit_cents(%{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  def outstanding_deposit_cents(%Group{}), do: 0

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
      {:error, _changeset} -> Repo.rollback(:group_already_exists)
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
        Repo.rollback(:group_not_found)

      group ->
        case check_expected_revision(group, expected_revision) do
          :ok -> fun.(group)
          {:error, reason} -> Repo.rollback(reason)
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
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: Repo.rollback(:invalid_stay)
  end

  defp validate_rooms([]), do: Repo.rollback(:invalid_rooms)

  defp validate_rooms(rooms) do
    unique? = length(rooms) == rooms |> MapSet.new(& &1.room_id) |> MapSet.size()

    rates_valid? =
      Enum.all?(rooms, fn room ->
        is_integer(room.nightly_rate_cents) and room.nightly_rate_cents > 0
      end)

    if unique? and rates_valid?, do: :ok, else: Repo.rollback(:invalid_rooms)
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: Repo.rollback(:invalid_rate_plan)
  end

  # Percentage deposits round to the nearest cent, an exact half-cent upward.
  defp room_deposit("flexible", lodging_cents),
    do: div(lodging_cents * @deposit_percentage + 50, 100)

  defp room_deposit("advance_purchase", lodging_cents), do: lodging_cents

  defp usable_payment?(amount_cents), do: is_integer(amount_cents) and amount_cents > 0

  defp valid_new_arrival?(new_arrival_on, occurred_on),
    do: Date.compare(new_arrival_on, occurred_on) == :gt

  defp refundable?(%{rate_plan: "flexible", arrival_on: arrival_on}, occurred_on),
    do: Date.diff(arrival_on, occurred_on) >= @refundable_lead_days

  defp refundable?(_group, _occurred_on), do: false

  defp unwrap({:ok, result}), do: {:ok, result}
  defp unwrap({:error, {:stale_revision, details}}), do: {:error, :stale_revision, details}
  defp unwrap({:error, reason}), do: {:error, reason}
end
