defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order and owns reservation deposit accounting.

  Each operation has its own transaction. SQLite immediate transactions acquire
  the write lock before reading a revision, so competing requests cannot both
  apply against the same revision or overfund the same deposit.
  """
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Booking, Group}

  @required_fields %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => []
  }

  def get_group(id), do: Repo.get(Group, id)

  def ledger do
    Repo.one(
      from group in Group,
        select: %{
          cash_held_cents: coalesce(sum(group.deposit_paid_cents), 0),
          cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
          cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0)
        }
    )
  end

  def process_batch(operations) when is_list(operations), do: Enum.map(operations, &process/1)

  defp process(operation) do
    operation_id = if is_map(operation), do: operation["operation_id"]

    result =
      Repo.transaction(
        fn ->
          case apply_operation(operation) do
            {:ok, fields} -> Map.put(fields, :status, "applied")
            {:error, code} when is_binary(code) -> Repo.rollback(%{code: code})
            {:error, fields} -> Repo.rollback(fields)
          end
        end,
        mode: :immediate
      )

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

  defp update_group(group, %{"type" => "record_cash_payment"} = operation, _date) do
    amount = operation["amount_cents"]
    outstanding = Group.outstanding_deposit(group)

    cond do
      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > outstanding ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        persist(group, %{deposit_paid_cents: group.deposit_paid_cents + amount}, %{
          amount_cents: amount,
          outstanding_deposit_cents: outstanding - amount
        })
    end
  end

  defp update_group(group, %{"type" => "reschedule_group"} = operation, date) do
    with {:ok, arrival} <- Booking.date(operation["new_arrival_on"]),
         :gt <- Date.compare(arrival, date),
         {:ok, departure} <- shifted_departure(group, arrival) do
      persist(group, %{arrival_on: arrival, departure_on: departure}, %{
        new_arrival_on: arrival,
        new_departure_on: departure
      })
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp update_group(group, %{"type" => "cancel_group"}, date) do
    refundable? = group.rate_plan == "flexible" and Date.diff(group.arrival_on, date) >= 14
    refunded = if refundable?, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    persist(
      group,
      %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_refunded_cents: refunded,
        cash_retained_cents: retained
      },
      %{refunded_cents: refunded, retained_cents: retained}
    )
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
