defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order and owns reservation deposit accounting.

  Operations supplies the durable transaction boundary before domain validation,
  so retries return their original results without consulting reservation state.
  Each new attempt sees the revision committed by the preceding operation.
  """
  import Ecto.Query
  alias GroupStay.{Accounting, Credits, Operations, Payments, Repo}
  alias GroupStay.Reservations.{Booking, Cancellation, CancellationPolicy, DepositTransfer, Group}

  @group_operations ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms)
  @payment_operations ~w(reduce_cash_payment charge_back_payment)
  @opening_fields ~w(guest_id property_id arrival_on departure_on rate_plan rooms)

  def get_group(group_id), do: Repo.get(Group, group_id)

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        cash =
          Repo.one(
            from group in Group,
              select: %{
                cash_held_cents: coalesce(sum(group.cash_paid_cents), 0),
                cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
                cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
                cash_reduced_cents: coalesce(sum(group.cash_reduced_cents), 0),
                cash_charged_back_cents: coalesce(sum(group.cash_charged_back_cents), 0),
                cash_converted_to_credit_cents:
                  coalesce(sum(group.cash_converted_to_credit_cents), 0)
              }
          )

        cash
        |> Map.put(:credit_liability_cents, Credits.liability(on))
        |> Map.put(:credit_shortfall_cents, Credits.shortfall())
      end)

    totals
  end

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, fn operation -> Operations.execute(operation, &apply_operation/1) end)
  end

  defp apply_operation(%{"type" => "transfer_deposit"} = operation) do
    if Enum.all?(~w(source_group_id destination_group_id), &Booking.identifier?(operation[&1])) do
      with {:ok, source} <- fetch_transfer_group(operation["source_group_id"]),
           {:ok, destination} <- fetch_transfer_group(operation["destination_group_id"]),
           :ok <- check_revision(source, operation),
           :ok <- check_revision(destination, operation, "destination_expected_revision"),
           {:ok, _date} <- operation_date(operation) do
        DepositTransfer.apply(source, destination, operation)
      else
        {:error, fields} when is_map(fields) -> {:error, fields}
        {:error, code} -> reject(code)
      end
    else
      reject("invalid_operation")
    end
  end

  defp apply_operation(%{"type" => type} = operation) when type in @payment_operations do
    if Booking.identifier?(operation["payment_operation_id"]) do
      update_payment(operation)
    else
      reject("invalid_operation")
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    if Booking.identifier?(operation["group_id"]) do
      case operation["type"] do
        "open_group" ->
          case Booking.date(operation["occurred_on"]) do
            {:ok, occurred_on} -> open_group(operation, occurred_on)
            _ -> reject("invalid_operation")
          end

        type when type in @group_operations ->
          update_group(operation)

        _ ->
          reject("invalid_operation")
      end
    else
      reject("invalid_operation")
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp check_revision(group, operation, key \\ "expected_revision") do
    if Map.has_key?(operation, key) and operation[key] !== group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation[key],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp fetch_transfer_group(group_id) do
    case get_group(group_id) do
      nil -> {:error, %{code: "group_not_found", group_id: group_id}}
      group -> {:ok, group}
    end
  end

  defp update_payment(operation) do
    code =
      if operation["type"] == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    with {:ok, payment} <- Payments.fetch(operation["payment_operation_id"], code),
         %Group{} = group <- get_group(payment.result["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, _date} <- operation_date(operation),
         {:ok, fields, changed_group_ids} <- correct_payment(payment, operation) do
      # The original payment group is always addressed, even when all its cash
      # has moved elsewhere. Refresh each changed group exactly once.
      groups =
        [group.group_id | changed_group_ids]
        |> Enum.uniq()
        |> Enum.sort()
        |> Map.new(fn id -> {id, Accounting.refresh(get_group(id))} end)

      group = Map.fetch!(groups, group.group_id)

      applied(
        group,
        Map.merge(fields, %{
          payment_operation_id: payment.operation_id,
          outstanding_deposit_cents: Group.outstanding_deposit(group)
        })
      )
    else
      nil -> reject("group_not_found")
      {:error, fields} when is_map(fields) -> {:error, fields}
      {:error, code} -> reject(code)
    end
  end

  defp operation_date(operation) do
    case Booking.date(operation["occurred_on"]) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp correct_payment(payment, %{"type" => "reduce_cash_payment"} = operation),
    do: Payments.reduce(payment, operation)

  defp correct_payment(payment, %{"type" => "charge_back_payment"}),
    do: Payments.charge_back(payment)

  defp open_group(operation, occurred_on) do
    cond do
      not Enum.all?(@opening_fields, &Map.has_key?(operation, &1)) ->
        reject("invalid_operation")

      not Enum.all?(~w(guest_id property_id), &Booking.identifier?(operation[&1])) ->
        reject("invalid_operation")

      get_group(operation["group_id"]) != nil ->
        reject("group_already_exists")

      true ->
        case Booking.build(operation, occurred_on) do
          {:ok, group} ->
            group = Repo.insert!(group)
            {:ok, Map.take(group, [:group_id, :deposit_due_cents, :revision])}

          {:error, code} ->
            reject(code)
        end
    end
  end

  defp update_group(operation) do
    case get_group(operation["group_id"]) do
      nil ->
        reject("group_not_found")

      group ->
        with :ok <- check_revision(group, operation),
             :ok <- active_group(group),
             {:ok, occurred_on} <- operation_date(operation) do
          apply_to_group(operation["type"], group, operation, occurred_on)
        else
          {:error, fields} when is_map(fields) -> {:error, fields}
          {:error, code} -> reject(code)
        end
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(_group), do: {:error, "group_not_active"}

  defp apply_to_group(type, group, operation, occurred_on)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    with :ok <- validate_payment(group, operation),
         :ok <- fund_deposit(type, group, operation, occurred_on) do
      amount = operation["amount_cents"]

      group = Accounting.refresh(group)

      applied(group, %{
        amount_cents: amount,
        outstanding_deposit_cents: Group.outstanding_deposit(group)
      })
    else
      {:error, code} -> reject(code)
    end
  end

  defp apply_to_group("reschedule_group", group, operation, occurred_on) do
    if Map.has_key?(operation, "new_arrival_on") do
      with {:ok, arrival} <- Booking.date(operation["new_arrival_on"]),
           :gt <- Date.compare(arrival, occurred_on),
           departure <- Date.add(arrival, Date.diff(group.departure_on, group.arrival_on)),
           true <- departure.year <= 9999 do
        group = save(group, arrival_on: arrival, departure_on: departure)

        applied(group, %{
          new_arrival_on: arrival,
          new_departure_on: departure,
          policy_version: group.policy_version,
          refundable_until: CancellationPolicy.refundable_until(group)
        })
      else
        _ -> reject("invalid_stay")
      end
    else
      reject("invalid_operation")
    end
  end

  defp apply_to_group(type, group, operation, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    case Cancellation.settle(group, operation, occurred_on) do
      {:ok, group, fields} -> applied(group, fields)
      {:error, code} -> reject(code)
    end
  end

  defp validate_payment(group, operation) do
    amount = operation["amount_cents"]

    cond do
      not Map.has_key?(operation, "amount_cents") -> {:error, "invalid_operation"}
      not is_integer(amount) or amount <= 0 -> {:error, "invalid_amount"}
      amount > Group.outstanding_deposit(group) -> {:error, "payment_exceeds_outstanding"}
      true -> :ok
    end
  end

  defp fund_deposit("record_cash_payment", group, operation, _occurred_on),
    do: Accounting.fund_cash(group, operation["operation_id"], operation["amount_cents"])

  defp fund_deposit("apply_hotel_credit", group, operation, occurred_on),
    do: Credits.apply_to_group(group, operation["amount_cents"], occurred_on)

  defp save(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp applied(group, fields) do
    {:ok, Map.merge(fields, %{group_id: group.group_id, revision: group.revision})}
  end

  defp reject(code), do: {:error, %{code: code}}
end
