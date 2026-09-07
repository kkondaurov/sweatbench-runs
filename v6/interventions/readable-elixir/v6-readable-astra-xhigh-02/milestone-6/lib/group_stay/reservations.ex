defmodule GroupStay.Reservations do
  @moduledoc """
  Owns reservation changes and their deposit accounting.

  Mutations run inside `GroupStay.Operations`' immediate transaction and savepoint.
  The caller owns rollback and durable results; this module owns domain validation,
  revision checks and settlement of each funding source. The caller supplies the
  reporting journal explicitly, including nil before reporting starts, so new
  mutation paths cannot silently omit reporting.
  """

  alias Ecto.Changeset
  alias GroupStay.{Accounting, HotelCredit, Ledger, Payments, Repo}
  alias GroupStay.Reservations.{Booking, CancellationPolicy, DepositTransfer, Group, Settlement}

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
  def apply_operation(operation, journal), do: dispatch(operation, journal)

  defp dispatch(%{"type" => "open_group"} = operation, _journal) do
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

  defp dispatch(%{"type" => "transfer_deposit"} = operation, journal) do
    with {:ok, source} <- fetch_transfer_group(operation["source_group_id"]),
         {:ok, destination} <- fetch_transfer_group(operation["destination_group_id"]),
         :ok <- check_revision(source, operation),
         :ok <- check_revision(destination, operation, "destination_expected_revision"),
         {:ok, _occurred_on} <- operation_date(operation),
         :ok <- Booking.required_fields(operation, ["amount_cents"]),
         :ok <- DepositTransfer.apply(source, destination, operation["amount_cents"], journal) do
      source = persist_accounting(source)
      destination = persist_accounting(destination)

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: operation["amount_cents"],
         source_outstanding_deposit_cents: Group.outstanding_deposit_cents(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit_cents(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp dispatch(%{"type" => type} = operation, journal)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    invalid_code =
      if type == "reduce_cash_payment", do: :payment_not_reducible, else: :payment_not_chargeable

    with {:ok, payment} <- Payments.fetch(operation["payment_operation_id"], invalid_code),
         {:ok, group} <- fetch_group(payment.group_id),
         :ok <- check_revision(group, operation),
         {:ok, _occurred_on} <- operation_date(operation) do
      correct_payment(group, payment, operation, journal)
    end
  end

  defp dispatch(operation, journal) do
    with {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, occurred_on} <- operation_date(operation),
         :ok <- active_group(group) do
      update_group(group, operation, occurred_on, journal)
    end
  end

  defp update_group(group, %{"type" => "record_cash_payment"} = operation, _occurred_on, journal) do
    with :ok <- Booking.required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(group, operation["amount_cents"]) do
      amount = operation["amount_cents"]
      :ok = Payments.record(group, operation, journal)
      updated = persist_accounting(group)

      {:ok, payment_result(updated, amount)}
    end
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on, journal) do
    with :ok <- Booking.required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(group, operation["amount_cents"]),
         :ok <- HotelCredit.apply_to_group(group, operation["amount_cents"], occurred_on, journal) do
      amount = operation["amount_cents"]

      updated = persist_accounting(group)

      {:ok, payment_result(updated, amount)}
    end
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation, occurred_on, _journal) do
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

  defp update_group(group, %{"type" => type} = operation, occurred_on, journal)
       when type in ["cancel_group", "cancel_rooms"] do
    with {:ok, result} <- Settlement.cancel(group, operation, occurred_on, journal) do
      updated = persist_accounting(group)
      {:ok, Map.put(result, :revision, updated.revision)}
    end
  end

  defp correct_payment(group, payment, %{"type" => "reduce_cash_payment"} = operation, journal) do
    with :ok <- Booking.required_fields(operation, ["amount_cents"]),
         {:ok, changed_groups} <- Payments.reduce(payment, operation["amount_cents"], journal) do
      updated = persist_correction(group, changed_groups)
      result = payment_result(updated, operation["amount_cents"])
      {:ok, Map.put(result, :payment_operation_id, payment.payment_operation_id)}
    end
  end

  defp correct_payment(group, payment, %{"type" => "charge_back_payment"}, journal) do
    with {:ok, amount, changed_groups} <- Payments.charge_back(payment, journal) do
      updated = persist_correction(group, changed_groups)

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

  # Corrections guard only the original group, but revise each changed account
  # once. A credit clawback changes a lot, not the groups still funded by that lot.
  defp persist_correction(addressed_group, changed_groups) do
    changed_groups
    |> Enum.uniq()
    |> Enum.reject(&(&1 == addressed_group.group_id))
    |> Enum.each(fn group_id -> persist_accounting(Repo.get!(Group, group_id)) end)

    persist_accounting(addressed_group)
  end

  defp persist_accounting(group) do
    totals =
      Map.merge(Accounting.group_totals(group.group_id), Payments.settled_totals(group.group_id))

    persist(group, totals)
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

  defp fetch_transfer_group(group_id) do
    case fetch_group(group_id) do
      {:error, code} -> {:error, %{code: code, group_id: group_id}}
      found -> found
    end
  end

  defp check_revision(group, operation, field \\ "expected_revision") do
    case Map.fetch(operation, field) do
      {:ok, expected} when expected !== group.revision ->
        {:error,
         %{
           code: :stale_revision,
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}

      _ ->
        :ok
    end
  end

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
