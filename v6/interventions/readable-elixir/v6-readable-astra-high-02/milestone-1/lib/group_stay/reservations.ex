defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations and exposes reservation and finance records.

  Each operation has its own transaction. SQLite's immediate transactions acquire the
  write lock before reading a revision, keeping revision checks and balance changes
  atomic across concurrent requests and service processes. Domain rejections perform
  no writes; a batch continues after each rejection.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [put_change: 3]

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Operation}

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  @doc """
  Totals cash balances and settlements in one database snapshot. Unpaid deposit
  requirements never enter the ledger, and cancellation cannot double-count cash.
  """
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

  defp apply_operation(operation) do
    outcome =
      with :ok <- Operation.validate(operation) do
        {:ok, result} = Repo.transaction(fn -> execute(operation) end, mode: :immediate)
        result
      end

    operation_id = if is_map(operation), do: operation["operation_id"], else: nil
    base = %{operation_id: operation_id}

    case outcome do
      {:ok, result} ->
        Map.merge(base, Map.put(result, :status, "applied"))

      {:error, code} ->
        Map.merge(base, %{status: "rejected", code: code})

      {:error, code, details} ->
        Map.merge(base, Map.merge(details, %{status: "rejected", code: code}))
    end
  end

  defp execute(%{"type" => "open_group"} = operation) do
    if Repo.get(Group, operation["group_id"]) do
      {:error, "group_already_exists"}
    else
      with {:ok, occurred_on} <- operation_date(operation),
           {:ok, changeset, result} <- Group.open(operation, occurred_on) do
        group = Repo.insert!(changeset)
        applied(group, result)
      end
    end
  end

  defp execute(operation) do
    with {:ok, group} <- find_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         :ok <- active(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, changeset, result} <- change_group(group, operation, occurred_on) do
      group = changeset |> put_change(:revision, group.revision + 1) |> Repo.update!()
      applied(group, result)
    end
  end

  defp find_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp check_revision(group, %{"expected_revision" => expected})
       when expected !== group.revision do
    {:error, "stale_revision",
     %{group_id: group.group_id, expected_revision: expected, actual_revision: group.revision}}
  end

  defp check_revision(_, _), do: :ok

  defp active(%Group{status: :active}), do: :ok
  defp active(_), do: {:error, "group_not_active"}

  defp operation_date(operation) do
    case Operation.date(operation["occurred_on"]) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_operation"}
    end
  end

  defp change_group(group, %{"type" => "record_cash_payment"} = operation, _date),
    do: Group.pay(group, operation["amount_cents"])

  defp change_group(group, %{"type" => "reschedule_group"} = operation, date),
    do: Group.reschedule(group, operation["new_arrival_on"], date)

  defp change_group(group, %{"type" => "cancel_group"}, date),
    do: Group.cancel(group, date)

  defp applied(group, result),
    do: {:ok, Map.merge(result, %{group_id: group.group_id, revision: group.revision})}
end
