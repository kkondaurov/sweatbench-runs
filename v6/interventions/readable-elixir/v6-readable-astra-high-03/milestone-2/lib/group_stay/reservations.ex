defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order and owns reservation deposit accounting.

  Each operation has its own transaction. SQLite immediate transactions acquire
  the write lock before reading a revision, so competing requests cannot both
  apply against the same revision or overfund the same deposit.
  """
  alias GroupStay.{Credit, Ledger, Repo}
  alias GroupStay.Reservations.{Booking, Cancellation, CancellationPolicy, Group}

  @required_fields %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "apply_hotel_credit" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => []
  }

  def get_group(id), do: Repo.get(Group, id)

  def ledger(on \\ Date.utc_today()), do: Ledger.totals(on)

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  defp process(operation) do
    operation_id = if is_map(operation), do: operation["operation_id"]

    result =
      Repo.with_write_transaction(fn ->
        case apply_operation(operation) do
          {:ok, fields} -> Map.put(fields, :status, "applied")
          {:error, code} when is_binary(code) -> Repo.rollback(%{code: code})
          {:error, fields} -> Repo.rollback(fields)
        end
      end)

    case result do
      {:ok, fields} -> Map.put(fields, :operation_id, operation_id)
      {:error, fields} -> Map.merge(fields, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp apply_operation(operation) do
    with :ok <- identify_operation(operation) do
      if operation["type"] == "open_group" do
        open_group(operation)
      else
        with {:ok, group} <- fetch_group(operation["group_id"]),
             :ok <- check_revision(group, operation),
             {:ok, occurred_on} <- operation_data(operation),
             :ok <- active(group) do
          update_group(group, operation, occurred_on)
        end
      end
    end
  end

  defp identify_operation(operation) when is_map(operation) do
    if Map.has_key?(@required_fields, operation["type"]) and
         Enum.all?(~w(operation_id group_id), &identifier?(operation[&1])) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp identify_operation(_), do: {:error, "invalid_operation"}

  defp operation_data(operation) do
    fields = Map.fetch!(@required_fields, operation["type"])

    with true <- Enum.all?(fields, &Map.has_key?(operation, &1)),
         {:ok, date} <- Booking.date(operation["occurred_on"]) do
      {:ok, date}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp identifier?(value), do: is_binary(value) and value != ""

  defp open_group(operation) do
    with {:ok, booked_on} <- operation_data(operation),
         true <- Enum.all?(~w(guest_id property_id), &identifier?(operation[&1])),
         nil <- get_group(operation["group_id"]),
         {:ok, group} <- Booking.build(operation, booked_on) do
      group = Repo.insert!(group)
      {:ok, %{group_id: group.group_id, deposit_due_cents: group.deposit_due_cents, revision: 1}}
    else
      %Group{} -> {:error, "group_already_exists"}
      false -> {:error, "invalid_operation"}
      {:error, code} -> {:error, code}
    end
  end

  defp fetch_group(id) do
    case get_group(id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: {:error, "group_not_active"}

  defp update_group(group, %{"type" => type} = operation, date)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    amount = operation["amount_cents"]
    outstanding = Group.outstanding_deposit(group)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > outstanding ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        with {:ok, credit_paid} <- apply_funding(group, type, amount, date) do
          persist(
            group,
            %{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: credit_paid
            },
            %{amount_cents: amount, outstanding_deposit_cents: outstanding - amount}
          )
        end
    end
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation, date) do
    with {:ok, arrival} <- Booking.date(operation["new_arrival_on"]),
         :gt <- Date.compare(arrival, date),
         {:ok, departure} <- shifted_departure(group, arrival) do
      persist(group, %{arrival_on: arrival, departure_on: departure}, %{
        new_arrival_on: arrival,
        new_departure_on: departure,
        policy_version: group.policy_version,
        refundable_until: CancellationPolicy.refundable_until(%{group | arrival_on: arrival})
      })
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp update_group(group, %{"type" => "cancel_group"} = operation, date) do
    with {:ok, changes, result} <- Cancellation.settle(group, operation, date) do
      persist(group, changes, result)
    end
  end

  defp apply_funding(group, "record_cash_payment", _amount, _date),
    do: {:ok, group.credit_paid_cents}

  defp apply_funding(group, "apply_hotel_credit", amount, date) do
    with :ok <- Credit.apply_to_group(group, amount, date) do
      {:ok, group.credit_paid_cents + amount}
    end
  end

  defp shifted_departure(group, arrival) do
    arrival
    |> Date.add(Date.diff(group.departure_on, group.arrival_on))
    |> Date.to_iso8601()
    |> Booking.date()
  rescue
    ArgumentError -> {:error, "invalid_stay"}
  end

  defp persist(group, changes, result) do
    revision = group.revision + 1
    group |> Ecto.Changeset.change(Map.put(changes, :revision, revision)) |> Repo.update!()
    {:ok, Map.merge(result, %{group_id: group.group_id, revision: revision})}
  end
end
