defmodule GroupStay.Reservations do
  @moduledoc """
  Processes ordered partner operations and owns reservation deposit accounting.

  Each operation has its own SQLite immediate transaction. Acquiring the write
  lock before reading a group makes revision checks and balance changes atomic
  across connections and service instances. A rejection rolls back only that
  operation; subsequent operations in the batch still run.
  """
  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CancellationPolicy,
    CancellationSettlement,
    CashEntry,
    Group,
    HotelCredit,
    Ledger,
    Operation
  }

  @doc "Applies operations in order and returns one outcome for each input."
  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &submit_operation/1)
  end

  @doc "Fetches a group using its unchanged partner identifier."
  def get_group(group_id), do: Repo.get(Group, group_id)

  @doc "Returns cash totals and credit liability, evaluating expiry on the supplied date."
  def ledger(on \\ Date.utc_today()), do: Ledger.totals(on)

  @doc "Returns a guest's current unredeemed credit that has not expired on the supplied date."
  def guest_credit(guest_id, on \\ Date.utc_today()), do: HotelCredit.available(guest_id, on)

  defp submit_operation(operation) do
    outcome =
      with :ok <- Operation.identify(operation) do
        Repo.transact_immediate(fn -> apply_operation(operation) end)
      end

    case outcome do
      {:ok, result} ->
        Map.merge(result, %{operation_id: Operation.id(operation), status: "applied"})

      {:error, code} when is_atom(code) ->
        %{operation_id: Operation.id(operation), status: "rejected", code: to_string(code)}

      {:error, details} when is_map(details) ->
        Map.merge(details, %{operation_id: Operation.id(operation), status: "rejected"})
    end
  end

  defp apply_operation(%{"type" => "open_group"} = operation) do
    if get_group(operation["group_id"]) do
      {:error, :group_already_exists}
    else
      with {:ok, occurred_on} <- Operation.validate_payload(operation),
           {:ok, changeset} <- Group.open(operation, occurred_on) do
        group = Repo.insert!(changeset)

        {:ok,
         %{
           group_id: group.group_id,
           deposit_due_cents: group.deposit_due_cents,
           revision: group.revision
         }}
      end
    end
  end

  defp apply_operation(operation) do
    with {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, occurred_on} <- Operation.validate_payload(operation),
         :ok <- ensure_active(group) do
      apply_to_group(group, operation, occurred_on)
    end
  end

  defp apply_to_group(group, %{"type" => "record_cash_payment"} = operation, occurred_on) do
    amount = operation["amount_cents"]

    with {:ok, changeset} <- Group.record_cash_payment(group, amount) do
      group = Repo.update!(changeset)
      record_cash(group, operation, occurred_on, :payment, amount)

      {:ok, payment_result(group, amount)}
    end
  end

  defp apply_to_group(group, %{"type" => "apply_hotel_credit"} = operation, occurred_on) do
    amount = operation["amount_cents"]

    with {:ok, changeset} <- Group.apply_hotel_credit(group, amount),
         :ok <- HotelCredit.redeem(group, operation, occurred_on) do
      group = Repo.update!(changeset)
      {:ok, payment_result(group, amount)}
    end
  end

  defp apply_to_group(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    with {:ok, changeset} <- Group.reschedule(group, operation["new_arrival_on"], occurred_on) do
      group = Repo.update!(changeset)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         policy_version: group.policy_version,
         refundable_until: CancellationPolicy.refundable_until(group),
         revision: group.revision
       }}
    end
  end

  defp apply_to_group(group, %{"type" => "cancel_group"} = operation, occurred_on) do
    refund_method = Map.get(operation, "refund_method", "cash")

    with {:ok, changeset, settlement} <- Group.cancel(group, occurred_on, refund_method) do
      group = Repo.update!(changeset)
      record_cash(group, operation, occurred_on, :refund, settlement.refunded_cents)
      record_cash(group, operation, occurred_on, :retention, settlement.retained_cents)

      record_cash(
        group,
        operation,
        occurred_on,
        :credit_conversion,
        settlement.cash_converted_to_credit_cents
      )

      if settlement.restore_credit?, do: HotelCredit.restore(group)
      HotelCredit.issue(group, operation, occurred_on, settlement.credit_issued_cents)

      {:ok,
       Map.merge(CancellationSettlement.result(settlement), %{
         group_id: group.group_id,
         revision: group.revision
       })}
    end
  end

  defp payment_result(group, amount) do
    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: Group.outstanding_deposit(group),
      revision: group.revision
    }
  end

  defp fetch_group(group_id) do
    case get_group(group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp check_revision(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      {:ok, expected} when expected !== group.revision ->
        {:error,
         %{
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}

      _ ->
        :ok
    end
  end

  defp ensure_active(%Group{status: :active}), do: :ok
  defp ensure_active(%Group{}), do: {:error, :group_not_active}

  defp record_cash(_group, _operation, _occurred_on, _kind, 0), do: :ok

  defp record_cash(group, operation, occurred_on, kind, amount) do
    Repo.insert!(%CashEntry{
      group_id: group.group_id,
      operation_id: operation["operation_id"],
      occurred_on: occurred_on,
      kind: kind,
      amount_cents: amount
    })
  end
end
