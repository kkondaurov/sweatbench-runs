defmodule GroupStay.Reservations do
  @moduledoc """
  Owns reservation changes and their deposit accounting.

  Mutations run inside `GroupStay.Operations`' immediate transaction and savepoint.
  The caller owns rollback and durable results; this module owns domain validation,
  revision checks and settlement of each funding source.
  """

  alias Ecto.Changeset
  alias GroupStay.{Accounting, HotelCredit, Ledger, Payments, Repo}
  alias GroupStay.Reservations.{Booking, CancellationPolicy, Group, Settlement}

  @doc "Returns a group with rooms in their original partner order."
  def get_group(group_id) do
    {:ok, group} =
      Repo.transaction(fn ->
        case Repo.get(Group, group_id) do
          nil -> nil
          group -> %{group | rooms: Accounting.rooms(group_id)}
        end
      end)

    group
  end

  @doc "Returns cash balances and credit liability at the requested expiry date."
  defdelegate ledger(on \\ Date.utc_today()), to: Ledger, as: :totals

  @doc "Applies a validated envelope inside the caller's operation transaction."
  def apply_operation(operation), do: dispatch(operation)

  defp dispatch(%{"type" => "open_group"} = operation) do
    with :ok <- available_group_id(operation["group_id"]),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, attributes} <- Booking.open_attributes(operation) do
      {rooms, attributes} = Map.pop(attributes, :rooms)

      attributes =
        Map.merge(attributes, %{
          booked_on: booked_on,
          policy_version: CancellationPolicy.version(attributes.rate_plan, booked_on)
        })

      group =
        %Group{}
        |> Changeset.change(attributes)
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

  defp dispatch(%{"type" => type} = operation)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    invalid_code =
      if type == "reduce_cash_payment", do: :payment_not_reducible, else: :payment_not_chargeable

    with {:ok, payment} <- Payments.fetch(operation["payment_operation_id"], invalid_code),
         {:ok, group} <- fetch_group(payment.group_id),
         :ok <- check_revision(group, operation),
         {:ok, _occurred_on} <- operation_date(operation) do
      correct_payment(group, payment, operation)
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
      :ok = Payments.record(group, operation)
      updated = persist_accounting(group)

      {:ok, payment_result(updated, amount)}
    end
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on) do
    with :ok <- Booking.required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(group, operation["amount_cents"]),
         :ok <- HotelCredit.apply_to_group(group, operation["amount_cents"], occurred_on) do
      amount = operation["amount_cents"]

      updated = persist_accounting(group)

      {:ok, payment_result(updated, amount)}
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
         policy_version: updated.policy_version,
         refundable_until: CancellationPolicy.refundable_until(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(group, %{"type" => type} = operation, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    with {:ok, changes, result} <- Settlement.cancel(group, operation, occurred_on) do
      updated = persist_accounting(group, changes)
      {:ok, Map.put(result, :revision, updated.revision)}
    end
  end

  defp correct_payment(group, payment, %{"type" => "reduce_cash_payment"} = operation) do
    with :ok <- Booking.required_fields(operation, ["amount_cents"]),
         :ok <- Payments.reduce(payment, operation["amount_cents"]) do
      updated = persist_accounting(group)
      result = payment_result(updated, operation["amount_cents"])
      {:ok, Map.put(result, :payment_operation_id, payment.payment_operation_id)}
    end
  end

  defp correct_payment(group, payment, %{"type" => "charge_back_payment"}) do
    with {:ok, amount} <- Payments.charge_back(payment) do
      updated =
        persist_accounting(group, %{
          refunded_cents: group.refunded_cents - payment.refunded_cents,
          retained_cents: group.retained_cents - payment.retained_cents,
          cash_converted_to_credit_cents:
            group.cash_converted_to_credit_cents - payment.converted_to_credit_cents
        })

      {:ok,
       %{
         payment_operation_id: payment.payment_operation_id,
         group_id: group.group_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(updated),
         revision: updated.revision
       }}
    end
  end

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
      revision: group.revision
    }
  end

  defp persist_accounting(group, changes \\ %{}) do
    totals = Accounting.group_totals(group.group_id)
    persist(group, Map.merge(changes, totals))
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
