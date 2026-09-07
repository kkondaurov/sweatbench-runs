defmodule GroupStay.Reservations do
  @moduledoc """
  Owns reservation changes and their deposit accounting.

  Each operation runs in an immediate SQLite transaction, acquiring the write lock
  before reading a group. Revision checks and the resulting writes are therefore
  atomic even when separate HTTP requests update the same group concurrently.
  A batch deliberately has no surrounding transaction: earlier successes survive
  later rejections.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Booking, Group}

  @doc "Returns a group with rooms in their original partner order."
  def get_group(group_id) do
    Group |> Repo.get(group_id) |> Repo.preload(:rooms)
  end

  @doc "Returns cash balances; unpaid deposit requirements never enter the ledger."
  def ledger do
    # Add in Elixir so totals remain exact even when multiple valid accounts
    # together exceed SQLite's signed 64-bit SUM limit.
    accounts =
      Repo.all(
        from group in Group,
          select:
            {group.status, group.deposit_paid_cents, group.refunded_cents, group.retained_cents}
      )

    initial = %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0}

    Enum.reduce(accounts, initial, fn {status, paid, refunded, retained}, totals ->
      held = if status == "active", do: paid, else: 0

      %{
        cash_held_cents: totals.cash_held_cents + held,
        cash_refunded_cents: totals.cash_refunded_cents + refunded,
        cash_retained_cents: totals.cash_retained_cents + retained
      }
    end)
  end

  @doc false
  def apply_operation(operation) do
    Repo.transaction(
      fn ->
        case dispatch(operation) do
          {:ok, result} -> result
          {:error, code} when is_atom(code) -> Repo.rollback(%{code: code})
          {:error, rejection} -> Repo.rollback(rejection)
        end
      end,
      mode: :immediate
    )
  end

  defp dispatch(%{"type" => "open_group"} = operation) do
    with :ok <- available_group_id(operation["group_id"]),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, attributes} <- Booking.open_attributes(operation) do
      {rooms, attributes} = Map.pop(attributes, :rooms)

      group =
        %Group{}
        |> Changeset.change(Map.put(attributes, :booked_on, booked_on))
        |> Changeset.put_assoc(:rooms, rooms)
        |> Repo.insert!()

      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    end
  end

  defp dispatch(operation) do
    with {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, occurred_on} <- operation_date(operation),
         :ok <- active_group(group) do
      update_group(group, operation, occurred_on)
    end
  end

  defp update_group(group, %{"type" => "record_cash_payment"} = operation, _occurred_on) do
    with :ok <- Booking.required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(group, operation["amount_cents"]) do
      amount = operation["amount_cents"]
      updated = persist(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

      {:ok,
       %{
         group_id: updated.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    with :ok <- Booking.required_fields(operation, ["new_arrival_on"]),
         {:ok, arrival, departure} <- rescheduled_dates(group, operation, occurred_on) do
      updated = persist(group, %{arrival_on: arrival, departure_on: departure})

      {:ok,
       %{
         group_id: updated.group_id,
         new_arrival_on: updated.arrival_on,
         new_departure_on: updated.departure_on,
         revision: updated.revision
       }}
    end
  end

  defp update_group(group, %{"type" => "cancel_group"}, occurred_on) do
    refundable? = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable?, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    updated =
      persist(group, %{
        status: "cancelled",
        deposit_due_cents: 0,
        refunded_cents: refunded,
        retained_cents: retained
      })

    {:ok,
     %{
       group_id: updated.group_id,
       refunded_cents: refunded,
       retained_cents: retained,
       revision: updated.revision
     }}
  end

  defp persist(group, changes) do
    group
    |> Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp available_group_id(group_id) do
    if Repo.get(Group, group_id), do: {:error, :group_already_exists}, else: :ok
  end

  defp fetch_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_revision(group, %{"expected_revision" => expected})
       when expected !== group.revision do
    {:error,
     %{
       code: :stale_revision,
       group_id: group.group_id,
       expected_revision: expected,
       actual_revision: group.revision
     }}
  end

  defp check_revision(_group, _operation), do: :ok

  defp operation_date(operation) do
    case Booking.date(operation["occurred_on"]) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_operation}
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(_group), do: {:error, :group_not_active}

  defp payment_amount(group, amount) do
    cond do
      not is_integer(amount) or amount <= 0 -> {:error, :invalid_amount}
      amount > Group.outstanding_deposit_cents(group) -> {:error, :payment_exceeds_outstanding}
      true -> :ok
    end
  end

  defp rescheduled_dates(group, operation, occurred_on) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    with {:ok, arrival} <- Booking.date(operation["new_arrival_on"]),
         true <- Date.compare(arrival, occurred_on) == :gt,
         true <- Date.diff(~D[9999-12-31], arrival) >= nights do
      departure = Date.add(arrival, nights)
      {:ok, arrival, departure}
    else
      _ -> {:error, :invalid_stay}
    end
  end
end
