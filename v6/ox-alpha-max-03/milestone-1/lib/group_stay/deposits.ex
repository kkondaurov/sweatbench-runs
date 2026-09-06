defmodule GroupStay.Deposits do
  @moduledoc """
  Applies partner operations to group deposits and reports finance totals.

  Every operation runs inside a single database transaction, so a rejected
  operation leaves the database exactly as it was before that operation began.
  """

  import Ecto.Query

  alias GroupStay.Deposits.Group
  alias GroupStay.Deposits.LedgerEntry
  alias GroupStay.Deposits.Room
  alias GroupStay.Operations
  alias GroupStay.Repo

  @flexible_deposit_percentage 20
  @refundable_days_before_arrival 14

  @type error ::
          :group_already_exists
          | :invalid_stay
          | :invalid_rooms
          | :invalid_rate_plan
          | :group_not_found
          | :group_not_active
          | :invalid_amount
          | :payment_exceeds_outstanding

  @doc """
  Applies one parsed operation and returns the fields reported to the partner.

  Errors are plain codes except `{:error, {:stale_revision, expected, actual}}`,
  which carries the revisions required by the API document.
  """
  @spec apply(Operations.Operation.t()) ::
          {:ok, map()}
          | {:error, error()}
          | {:error, {:stale_revision, pos_integer(), pos_integer()}}
  def apply(%Operations.Operation{} = op) do
    Repo.transaction(fn ->
      case apply_in_transaction(op) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a group by its partner-supplied identifier, or nil.
  """
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(group_id) do
    rooms_query = from r in Room, order_by: r.position

    Repo.one(
      from g in Group,
        where: g.group_id == ^group_id,
        preload: [rooms: ^rooms_query]
    )
  end

  @doc """
  Returns cash currently held plus lifetime refunded and retained totals.
  """
  @spec ledger_totals() :: %{
          cash_held_cents: non_neg_integer(),
          cash_refunded_cents: non_neg_integer(),
          cash_retained_cents: non_neg_integer()
        }
  def ledger_totals do
    held =
      from(e in LedgerEntry,
        join: g in assoc(e, :group),
        where: e.kind == "cash" and g.status == "active",
        select: coalesce(sum(e.amount_cents), 0)
      )

    refunded =
      from(e in LedgerEntry,
        where: e.kind == "refund",
        select: coalesce(sum(e.amount_cents), 0)
      )

    retained =
      from(e in LedgerEntry,
        where: e.kind == "retain",
        select: coalesce(sum(e.amount_cents), 0)
      )

    %{
      cash_held_cents: total(held),
      cash_refunded_cents: total(refunded),
      cash_retained_cents: total(retained)
    }
  end

  ## Dispatching

  defp apply_in_transaction(%Operations.Operation{type: :open_group} = op) do
    # Resolve group existence before evaluating domain rules.
    if group_exists?(op.group_id) do
      {:error, :group_already_exists}
    else
      with :ok <- validate_stay(op),
           :ok <- validate_rooms(op.rooms),
           :ok <- validate_rate_plan(op.rate_plan) do
        open_group(op)
      end
    end
  end

  defp apply_in_transaction(%Operations.Operation{type: :record_cash_payment} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group),
         :ok <- validate_outstanding(group, op.amount_cents) do
      record_cash(group, op)
    end
  end

  defp apply_in_transaction(%Operations.Operation{type: :reschedule_group} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group),
         :ok <- validate_new_arrival(op) do
      reschedule(group, op)
    end
  end

  defp apply_in_transaction(%Operations.Operation{type: :cancel_group} = op) do
    with {:ok, group} <- fetch_group(op.group_id),
         :ok <- check_revision(group, op.expected_revision),
         :ok <- check_active(group) do
      cancel(group, op)
    end
  end

  ## Opening a group

  defp group_exists?(group_id) do
    Repo.exists?(from g in Group, where: g.group_id == ^group_id)
  end

  defp validate_stay(op) do
    if Date.compare(op.departure_on, op.arrival_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  defp validate_rooms([]), do: {:error, :invalid_rooms}

  defp validate_rooms(rooms) do
    positive_rates? = Enum.all?(rooms, fn room -> room.nightly_rate_cents > 0 end)

    room_ids = Enum.map(rooms, & &1.room_id)
    unique_room_ids? = length(room_ids) == length(Enum.uniq(room_ids))

    if positive_rates? and unique_room_ids? do
      :ok
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"], do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp open_group(op) do
    nights = Date.diff(op.departure_on, op.arrival_on)

    rooms =
      op.rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        room
        |> room_attrs(nights)
        |> Map.put(:position, position)
      end)

    lodging_total = rooms |> Enum.map(& &1.lodging_amount_cents) |> Enum.sum()

    deposit_due =
      op.rooms
      |> Enum.map(&room_deposit(&1, nights, op.rate_plan))
      |> Enum.sum()

    attrs = %{
      group_id: op.group_id,
      guest_id: op.guest_id,
      property_id: op.property_id,
      booked_on: op.occurred_on,
      arrival_on: op.arrival_on,
      departure_on: op.departure_on,
      rate_plan: op.rate_plan,
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due,
      rooms: rooms
    }

    attrs
    |> Group.open_changeset()
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        {:ok,
         %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         }}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :group_id) do
          {:error, :group_already_exists}
        else
          {:error, :invalid_rooms}
        end
    end
  end

  defp room_attrs(room, nights) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_amount_cents: nights * room.nightly_rate_cents
    }
  end

  # Each flexible room's deposit is calculated and rounded separately before
  # the room deposits are summed; an advance-purchase room requires its full
  # lodging amount.
  defp room_deposit(room, nights, rate_plan) do
    lodging_amount = nights * room.nightly_rate_cents

    case rate_plan do
      "flexible" -> percentage_half_up(lodging_amount, @flexible_deposit_percentage)
      "advance_purchase" -> lodging_amount
    end
  end

  ## Recording cash

  defp record_cash(group, op) do
    {:ok, _entry} =
      insert_entry(group, "cash", op.amount_cents, op.occurred_on)

    updated =
      group
      |> Group.update_changeset(%{
        deposit_paid_cents: group.deposit_paid_cents + op.amount_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

    {:ok,
     %{
       group_id: group.group_id,
       amount_cents: op.amount_cents,
       outstanding_deposit_cents: outstanding_deposit(updated),
       revision: updated.revision
     }}
  end

  ## Rescheduling

  defp reschedule(group, op) do
    shift = Date.diff(op.new_arrival_on, group.arrival_on)
    new_departure = Date.add(group.departure_on, shift)

    updated =
      group
      |> Group.update_changeset(%{
        arrival_on: op.new_arrival_on,
        departure_on: new_departure,
        revision: group.revision + 1
      })
      |> Repo.update!()

    {:ok,
     %{
       group_id: group.group_id,
       new_arrival_on: updated.arrival_on,
       new_departure_on: updated.departure_on,
       revision: updated.revision
     }}
  end

  defp validate_new_arrival(op) do
    if Date.compare(op.new_arrival_on, op.occurred_on) == :gt do
      :ok
    else
      {:error, :invalid_stay}
    end
  end

  ## Cancelling

  defp cancel(group, op) do
    refundable? =
      group.rate_plan == "flexible" and
        Date.diff(group.arrival_on, op.occurred_on) >= @refundable_days_before_arrival

    paid = group.deposit_paid_cents

    {refunded, retained, kind} =
      cond do
        paid == 0 -> {0, 0, nil}
        refundable? -> {paid, 0, "refund"}
        true -> {0, paid, "retain"}
      end

    if kind do
      {:ok, _entry} = insert_entry(group, kind, paid, op.occurred_on)
    end

    updated =
      group
      |> Group.update_changeset(%{
        status: "cancelled",
        deposit_paid_cents: 0,
        revision: group.revision + 1
      })
      |> Repo.update!()

    {:ok,
     %{
       group_id: updated.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       revision: updated.revision
     }}
  end

  ## Shared helpers

  defp fetch_group(group_id) do
    case get_group(group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  # Existence resolves first; a stale revision is then rejected before any
  # other domain rule is evaluated.
  defp check_revision(_group, nil), do: :ok

  defp check_revision(group, expected_revision) do
    if group.revision == expected_revision do
      :ok
    else
      {:error, {:stale_revision, expected_revision, group.revision}}
    end
  end

  defp check_active(%Group{status: "active"}), do: :ok
  defp check_active(%Group{}), do: {:error, :group_not_active}

  defp validate_outstanding(group, amount_cents) do
    if amount_cents > outstanding_deposit(group) do
      {:error, :payment_exceeds_outstanding}
    else
      :ok
    end
  end

  @doc """
  Cash still owed on an active reservation's deposit. Unpaid deposit
  requirements disappear when a group is cancelled.
  """
  @spec outstanding_deposit(Group.t()) :: non_neg_integer()
  def outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  def outstanding_deposit(%Group{}), do: 0

  defp insert_entry(group, kind, amount_cents, occurred_on) do
    Repo.insert(
      LedgerEntry.changeset(%LedgerEntry{}, %{
        group_id: group.id,
        kind: kind,
        amount_cents: amount_cents,
        occurred_on: occurred_on
      })
    )
  end

  # Rounds value * percentage / 100 to the nearest cent; an exact half-cent
  # rounds upward.
  @doc false
  def percentage_half_up(value, percentage) do
    div(2 * value * percentage + 100, 200)
  end

  defp total(query) do
    query
    |> Repo.one()
    |> integer_value()
  end

  defp integer_value(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(nil), do: 0
end
