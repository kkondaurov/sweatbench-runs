defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order and owns reservation deposit accounting.

  Each operation runs in an immediate SQLite transaction: the write lock is
  acquired before reading a revision, so concurrent requests cannot both apply
  against the same revision. Rejections roll back only their own operation.
  """
  import Ecto.Query
  alias GroupStay.{Credits, Repo}
  alias GroupStay.Reservations.{Booking, CancellationPolicy, Group}

  @group_operations ~w(record_cash_payment apply_hotel_credit reschedule_group cancel_group)
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
                cash_converted_to_credit_cents:
                  coalesce(sum(group.cash_converted_to_credit_cents), 0)
              }
          )

        Map.put(cash, :credit_liability_cents, Credits.liability(on))
      end)

    totals
  end

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  defp process_operation(operation) do
    result =
      Repo.write_transaction(fn ->
        case apply_operation(operation) do
          {:ok, fields} -> fields
          {:error, fields} -> Repo.rollback(fields)
        end
      end)

    operation_id = if is_map(operation), do: operation["operation_id"], else: nil

    case result do
      {:ok, fields} -> Map.merge(fields, %{operation_id: operation_id, status: "applied"})
      {:error, fields} -> Map.merge(fields, %{operation_id: operation_id, status: "rejected"})
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    if Enum.all?(~w(operation_id group_id), &Booking.identifier?(operation[&1])) do
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
        cond do
          Map.has_key?(operation, "expected_revision") and
              operation["expected_revision"] !== group.revision ->
            {:error,
             %{
               code: "stale_revision",
               group_id: group.group_id,
               expected_revision: operation["expected_revision"],
               actual_revision: group.revision
             }}

          group.status != "active" ->
            reject("group_not_active")

          true ->
            case Booking.date(operation["occurred_on"]) do
              {:ok, occurred_on} ->
                apply_to_group(operation["type"], group, operation, occurred_on)

              _ ->
                reject("invalid_operation")
            end
        end
    end
  end

  defp apply_to_group(type, group, operation, occurred_on)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    with :ok <- validate_payment(group, operation),
         :ok <- fund_deposit(type, group, operation["amount_cents"], occurred_on) do
      amount = operation["amount_cents"]

      funding_field =
        if type == "record_cash_payment", do: :cash_paid_cents, else: :credit_paid_cents

      group =
        save(group, [
          {:deposit_paid_cents, group.deposit_paid_cents + amount},
          {funding_field, Map.fetch!(group, funding_field) + amount}
        ])

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

  defp apply_to_group("cancel_group", group, operation, occurred_on) do
    method = Map.get(operation, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, occurred_on)

    cond do
      method not in ["cash", "hotel_credit"] ->
        reject("invalid_operation")

      method == "hotel_credit" and not refundable? ->
        reject("refund_method_not_available")

      true ->
        refunded = if refundable? and method == "cash", do: group.cash_paid_cents, else: 0
        retained = if refundable?, do: 0, else: group.cash_paid_cents
        converted = if method == "hotel_credit", do: group.cash_paid_cents, else: 0

        issued =
          if method == "hotel_credit",
            do: Credits.issue(group, operation["operation_id"], occurred_on),
            else: 0

        Credits.settle(group, refundable?, occurred_on)

        group =
          save(group,
            status: "cancelled",
            deposit_due_cents: 0,
            deposit_paid_cents: 0,
            cash_paid_cents: 0,
            credit_paid_cents: 0,
            cash_refunded_cents: refunded,
            cash_retained_cents: retained,
            cash_converted_to_credit_cents: converted
          )

        applied(group, %{
          refunded_cents: refunded,
          retained_cents: retained,
          credit_issued_cents: issued
        })
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

  defp fund_deposit("record_cash_payment", _group, _amount, _occurred_on), do: :ok

  defp fund_deposit("apply_hotel_credit", group, amount, occurred_on),
    do: Credits.apply_to_group(group, amount, occurred_on)

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
