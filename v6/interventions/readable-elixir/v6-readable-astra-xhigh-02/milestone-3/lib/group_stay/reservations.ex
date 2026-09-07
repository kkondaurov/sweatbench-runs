defmodule GroupStay.Reservations do
  @moduledoc """
  Owns reservation changes and their deposit accounting.

  Mutations run inside `GroupStay.Operations`' immediate transaction and savepoint.
  The caller owns rollback and durable results; this module owns domain validation,
  revision checks and settlement of each funding source.
  """

  alias Ecto.Changeset
  alias GroupStay.{HotelCredit, Ledger, Repo}
  alias GroupStay.Reservations.{Booking, CancellationPolicy, Group}

  @doc "Returns a group with rooms in their original partner order."
  def get_group(group_id) do
    Group |> Repo.get(group_id) |> Repo.preload(:rooms)
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

      {:ok, payment_result(updated, amount)}
    end
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on) do
    with :ok <- Booking.required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(group, operation["amount_cents"]),
         :ok <- HotelCredit.apply_to_group(group, operation["amount_cents"], occurred_on) do
      amount = operation["amount_cents"]

      updated =
        persist(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount
        })

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

  defp update_group(group, %{"type" => "cancel_group"} = operation, occurred_on) do
    refundable? = CancellationPolicy.refundable?(group, occurred_on)
    method = Map.get(operation, "refund_method", "cash")

    with :ok <- refund_method(method, refundable?) do
      cash = Group.cash_paid_cents(group)
      refunded = if refundable? and method == "cash", do: cash, else: 0
      retained = if refundable?, do: 0, else: cash
      converted = if method == "hotel_credit", do: cash, else: 0

      if refundable?, do: HotelCredit.restore(group, occurred_on)
      issued = HotelCredit.issue(group, operation["operation_id"], converted, occurred_on)

      updated =
        persist(group, %{
          status: "cancelled",
          deposit_due_cents: 0,
          refunded_cents: refunded,
          retained_cents: retained,
          cash_converted_to_credit_cents: converted
        })

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

  defp refund_method("hotel_credit", false), do: {:error, :refund_method_not_available}
  defp refund_method(method, _refundable?) when method in ["cash", "hotel_credit"], do: :ok
  defp refund_method(_method, _refundable?), do: {:error, :invalid_operation}

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
      revision: group.revision
    }
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
