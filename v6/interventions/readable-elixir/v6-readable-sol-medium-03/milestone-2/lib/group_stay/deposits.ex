defmodule GroupStay.Deposits do
  @moduledoc """
  Owns group deposit reservations and their accounting state.

  Partner operations are deliberately applied in individual transactions. This gives a batch
  ordered visibility while ensuring that one rejected operation cannot partially change a group.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Deposits.{CreditAllocation, CreditLot, Group, LedgerEntry, Policy}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)

  @doc "Processes partner operations in order, committing each successful operation separately."
  def process_operations(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns a group with rooms kept in their original partner-supplied order."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  @doc "Returns cash settlement totals and credit liability as of the supplied date."
  def ledger(on \\ Date.utc_today()) do
    cash_totals =
      from(entry in LedgerEntry,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'cash_payment' THEN ? WHEN ? IN ('refund', 'retention', 'credit_conversion') THEN -? ELSE 0 END",
                  entry.kind,
                  entry.amount_cents,
                  entry.kind,
                  entry.amount_cents
                )
              ),
              0
            ),
          cash_refunded_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'refund' THEN ? ELSE 0 END",
                  entry.kind,
                  entry.amount_cents
                )
              ),
              0
            ),
          cash_retained_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'retention' THEN ? ELSE 0 END",
                  entry.kind,
                  entry.amount_cents
                )
              ),
              0
            ),
          cash_converted_to_credit_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'credit_conversion' THEN ? ELSE 0 END",
                  entry.kind,
                  entry.amount_cents
                )
              ),
              0
            )
        }
      )
      |> Repo.one()

    available_liability =
      from(lot in CreditLot,
        where: lot.expires_on >= ^on,
        select: coalesce(sum(lot.remaining_cents), 0)
      )
      |> Repo.one()

    allocated_liability =
      from(allocation in CreditAllocation,
        join: group in assoc(allocation, :group),
        where: group.status == "active",
        select: coalesce(sum(allocation.amount_cents), 0)
      )
      |> Repo.one()

    cash_totals
    |> Map.new(fn {key, value} -> {key, value || 0} end)
    |> Map.put(:credit_liability_cents, available_liability + allocated_liability)
  end

  @doc "Returns a guest's unexpired, available credit lots in consumption order."
  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      from(lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  def outstanding_deposit(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding_deposit(%Group{}), do: 0

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    result =
      if valid_identifier?(operation_id) do
        case Map.get(operation, "type") do
          "open_group" ->
            transact(fn -> open_group(operation) end)

          "record_cash_payment" ->
            transact(fn -> update_existing(operation, &record_cash_payment/2) end)

          "reschedule_group" ->
            transact(fn -> update_existing(operation, &reschedule_group/2) end)

          "cancel_group" ->
            transact(fn -> update_existing(operation, &cancel_group/2) end)

          "apply_hotel_credit" ->
            transact(fn -> update_existing(operation, &apply_hotel_credit/2) end)

          _ ->
            {:error, :invalid_operation}
        end
      else
        {:error, :invalid_operation}
      end

    format_result(operation_id, result)
  end

  defp process_operation(_), do: format_result(nil, {:error, :invalid_operation})

  defp transact(fun) do
    case Repo.transaction(
           fn ->
             case fun.() do
               {:ok, value} -> value
               {:error, reason} -> Repo.rollback(reason)
             end
           end,
           mode: :immediate
         ) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_group(operation) do
    with {:ok, attrs} <- open_attributes(operation),
         false <- Repo.exists?(from g in Group, where: g.group_id == ^attrs.group_id),
         {:ok, group} <- insert_group(attrs) do
      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    else
      true -> {:error, :group_already_exists}
      {:error, %Changeset{}} -> {:error, :group_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_attributes(operation) do
    required_ids = ~w(group_id guest_id property_id)

    cond do
      not Enum.all?(required_ids, &valid_identifier?(Map.get(operation, &1))) ->
        {:error, :invalid_operation}

      not Map.has_key?(operation, "occurred_on") or not Map.has_key?(operation, "arrival_on") or
        not Map.has_key?(operation, "departure_on") or not Map.has_key?(operation, "rooms") or
          not Map.has_key?(operation, "rate_plan") ->
        {:error, :invalid_operation}

      true ->
        build_open_attributes(operation)
    end
  end

  defp build_open_attributes(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"], :invalid_stay),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], :invalid_stay),
         {:ok, departure_on} <- parse_date(operation["departure_on"], :invalid_stay),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         nights <- Date.diff(departure_on, arrival_on),
         {lodging_total, deposit_due} <- totals(rooms, nights, operation["rate_plan"]) do
      {:ok,
       %{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: operation["rate_plan"],
         policy_version: Policy.version(operation["rate_plan"], booked_on),
         rooms: rooms,
         lodging_total_cents: lodging_total,
         deposit_due_cents: deposit_due
       }}
    end
  end

  defp insert_group(attrs) do
    room_attrs = Enum.with_index(attrs.rooms, &Map.put(&1, :position, &2))
    insert_attrs = attrs |> Map.delete(:rooms) |> Map.put(:rooms, room_attrs)

    %Group{}
    |> Changeset.cast(insert_attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> Changeset.put_change(:status, "active")
    |> Changeset.put_change(:revision, 1)
    |> Changeset.cast_assoc(:rooms,
      with: fn room, params ->
        Changeset.cast(room, params, [:room_id, :nightly_rate_cents, :position])
      end
    )
    |> Changeset.unique_constraint(:group_id)
    |> Repo.insert()
  end

  defp update_existing(operation, update_fun) do
    group_id = operation["group_id"]

    if valid_identifier?(group_id) do
      case Repo.get_by(Group, group_id: group_id) do
        nil -> {:error, :group_not_found}
        group -> check_revision_then_update(group, operation, update_fun)
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp check_revision_then_update(group, operation, update_fun) do
    case Map.fetch(operation, "expected_revision") do
      {:ok, expected} when is_integer(expected) and expected !== group.revision ->
        {:error, {:stale_revision, group.group_id, expected, group.revision}}

      {:ok, expected} when is_integer(expected) ->
        apply_complete_operation(operation, group, update_fun)

      :error ->
        apply_complete_operation(operation, group, update_fun)

      {:ok, _invalid_revision} ->
        {:error, :invalid_operation}
    end
  end

  defp apply_complete_operation(operation, group, update_fun) do
    if structurally_complete?(operation) do
      update_fun.(group, operation)
    else
      {:error, :invalid_operation}
    end
  end

  defp structurally_complete?(%{"type" => "record_cash_payment"} = operation),
    do: Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents")

  defp structurally_complete?(%{"type" => "reschedule_group"} = operation),
    do: Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "new_arrival_on")

  defp structurally_complete?(%{"type" => "cancel_group"} = operation),
    do: Map.has_key?(operation, "occurred_on")

  defp structurally_complete?(%{"type" => "apply_hotel_credit"} = operation),
    do: Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "amount_cents")

  defp structurally_complete?(_operation), do: false

  defp record_cash_payment(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, amount} <- payment_amount(operation),
         true <- amount <= outstanding_deposit(group),
         {:ok, _entry} <-
           insert_ledger_entry(group, operation, occurred_on, "cash_payment", amount) do
      group
      |> Changeset.change(
        deposit_paid_cents: group.deposit_paid_cents + amount,
        cash_paid_cents: group.cash_paid_cents + amount,
        revision: group.revision + 1
      )
      |> Repo.update()
      |> applied(fn updated ->
        %{
          group_id: updated.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(updated),
          revision: updated.revision
        }
      end)
    else
      false -> {:error, :payment_exceeds_outstanding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reschedule_group(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, new_arrival} <- reschedule_date(operation),
         true <- Date.after?(new_arrival, occurred_on) do
      days = Date.diff(new_arrival, group.arrival_on)
      new_departure = Date.add(group.departure_on, days)

      group
      |> Changeset.change(
        arrival_on: new_arrival,
        departure_on: new_departure,
        revision: group.revision + 1
      )
      |> Repo.update()
      |> applied(fn updated ->
        %{
          group_id: updated.group_id,
          new_arrival_on: updated.arrival_on,
          new_departure_on: updated.departure_on,
          policy_version: updated.policy_version,
          refundable_until: Policy.refundable_until(updated),
          revision: updated.revision
        }
      end)
    else
      false -> {:error, :invalid_stay}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_group(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, refund_method} <- refund_method(operation),
         refundable = Policy.refundable?(group, occurred_on),
         :ok <- refund_method_available(refund_method, refundable),
         {:ok, settlement} <-
           settle_cancellation(group, operation, occurred_on, refundable, refund_method) do
      with :ok <- settle_credit_allocations(group, occurred_on, refundable) do
        group
        |> Changeset.change(
          status: "cancelled",
          refunded_cents: settlement.refunded_cents,
          retained_cents: settlement.retained_cents,
          revision: group.revision + 1
        )
        |> Repo.update()
        |> applied(fn updated ->
          %{
            group_id: updated.group_id,
            refunded_cents: settlement.refunded_cents,
            retained_cents: settlement.retained_cents,
            credit_issued_cents: settlement.credit_issued_cents,
            revision: updated.revision
          }
        end)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_hotel_credit(group, operation) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], :invalid_operation),
         :ok <- active(group),
         {:ok, amount} <- payment_amount(operation),
         true <- amount <= outstanding_deposit(group),
         {:ok, lots} <- sufficient_credit(group.guest_id, occurred_on, amount),
         :ok <- consume_credit_lots(group, lots, amount) do
      group
      |> Changeset.change(
        deposit_paid_cents: group.deposit_paid_cents + amount,
        credit_paid_cents: group.credit_paid_cents + amount,
        revision: group.revision + 1
      )
      |> Repo.update()
      |> applied(fn updated ->
        %{
          group_id: updated.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(updated),
          revision: updated.revision
        }
      end)
    else
      false -> {:error, :payment_exceeds_outstanding}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, :invalid_operation}
    end
  end

  defp refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp refund_method_available(_method, _refundable), do: :ok

  defp settle_cancellation(group, operation, occurred_on, true, "hotel_credit") do
    issued = group.cash_paid_cents + rounded_percentage(group.cash_paid_cents, 10)

    with :ok <-
           insert_settlement(
             group,
             operation,
             occurred_on,
             {"credit_conversion", group.cash_paid_cents}
           ),
         :ok <- issue_credit(group.guest_id, operation["operation_id"], occurred_on, issued) do
      {:ok, %{refunded_cents: 0, retained_cents: 0, credit_issued_cents: issued}}
    end
  end

  defp settle_cancellation(group, operation, occurred_on, true, "cash") do
    with :ok <-
           insert_settlement(group, operation, occurred_on, {"refund", group.cash_paid_cents}) do
      {:ok, %{refunded_cents: group.cash_paid_cents, retained_cents: 0, credit_issued_cents: 0}}
    end
  end

  defp settle_cancellation(group, operation, occurred_on, false, "cash") do
    with :ok <-
           insert_settlement(group, operation, occurred_on, {"retention", group.cash_paid_cents}) do
      {:ok, %{refunded_cents: 0, retained_cents: group.cash_paid_cents, credit_issued_cents: 0}}
    end
  end

  defp issue_credit(_guest_id, _operation_id, _occurred_on, 0), do: :ok

  defp issue_credit(guest_id, operation_id, occurred_on, amount) do
    %CreditLot{}
    |> Changeset.cast(
      %{
        guest_id: guest_id,
        source_operation_id: operation_id,
        remaining_cents: amount,
        expires_on: Date.add(occurred_on, 365)
      },
      [:guest_id, :source_operation_id, :remaining_cents, :expires_on]
    )
    |> Repo.insert()
    |> case do
      {:ok, _lot} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp sufficient_credit(guest_id, occurred_on, amount) do
    lots =
      from(lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount do
      {:ok, lots}
    else
      {:error, :insufficient_credit}
    end
  end

  defp consume_credit_lots(group, lots, amount) do
    Enum.reduce_while(lots, amount, fn lot, left ->
      used = min(lot.remaining_cents, left)

      with {:ok, _lot} <-
             lot
             |> Changeset.change(remaining_cents: lot.remaining_cents - used)
             |> Repo.update(),
           {:ok, _allocation} <- insert_credit_allocation(group, lot, used) do
        remaining = left - used
        if remaining == 0, do: {:halt, 0}, else: {:cont, remaining}
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      0 -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_credit_allocation(group, lot, amount) do
    %CreditAllocation{}
    |> Changeset.cast(
      %{group_id: group.id, credit_lot_id: lot.id, amount_cents: amount},
      [:group_id, :credit_lot_id, :amount_cents]
    )
    |> Repo.insert()
  end

  defp settle_credit_allocations(group, occurred_on, refundable) do
    allocations =
      from(allocation in CreditAllocation,
        where: allocation.group_id == ^group.id,
        preload: [:credit_lot]
      )
      |> Repo.all()

    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      result =
        if refundable and not Date.after?(occurred_on, allocation.credit_lot.expires_on) do
          current_lot = Repo.get!(CreditLot, allocation.credit_lot_id)

          current_lot
          |> Changeset.change(
            remaining_cents: current_lot.remaining_cents + allocation.amount_cents
          )
          |> Repo.update()
        else
          {:ok, allocation.credit_lot}
        end

      with {:ok, _lot} <- result, {:ok, _allocation} <- Repo.delete(allocation) do
        {:cont, :ok}
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp rounded_percentage(amount, percent), do: div(amount * percent + 50, 100)

  defp reschedule_date(operation) do
    if Map.has_key?(operation, "new_arrival_on") do
      parse_date(operation["new_arrival_on"], :invalid_stay)
    else
      {:error, :invalid_operation}
    end
  end

  defp payment_amount(operation) do
    if Map.has_key?(operation, "amount_cents") do
      case operation["amount_cents"] do
        amount when is_integer(amount) and amount > 0 -> {:ok, amount}
        _ -> {:error, :invalid_amount}
      end
    else
      {:error, :invalid_operation}
    end
  end

  defp insert_settlement(_group, _operation, _occurred_on, {_kind, 0}), do: :ok

  defp insert_settlement(group, operation, occurred_on, {kind, amount}) do
    case insert_ledger_entry(group, operation, occurred_on, kind, amount) do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_ledger_entry(group, operation, occurred_on, kind, amount) do
    %LedgerEntry{}
    |> Changeset.cast(
      %{
        group_id: group.id,
        operation_id: operation["operation_id"],
        occurred_on: occurred_on,
        kind: kind,
        amount_cents: amount
      },
      [:group_id, :operation_id, :occurred_on, :kind, :amount_cents]
    )
    |> Repo.insert()
  end

  defp validate_stay(arrival, departure) do
    if Date.before?(arrival, departure), do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, :invalid_rate_plan}
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
          valid_identifier?(room_id) and is_integer(rate) and rate > 0

        _ ->
          false
      end)

    identifiers = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(identifiers) == identifiers do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_), do: {:error, :invalid_rooms}

  defp totals(rooms, nights, rate_plan) do
    lodging = Enum.map(rooms, &(&1.nightly_rate_cents * nights))
    lodging_total = Enum.sum(lodging)

    deposit_due =
      case rate_plan do
        "flexible" -> Enum.sum(Enum.map(lodging, &div(&1 * 20 + 50, 100)))
        "advance_purchase" -> lodging_total
      end

    {lodging_total, deposit_due}
  end

  defp parse_date(value, error) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, error}
    end
  end

  defp parse_date(_, error), do: {:error, error}

  defp active(%Group{status: "active"}), do: :ok
  defp active(%Group{}), do: {:error, :group_not_active}

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp applied({:ok, value}, formatter), do: {:ok, formatter.(value)}
  defp applied({:error, changeset}, _formatter), do: {:error, changeset}

  defp format_result(operation_id, {:ok, fields}) do
    fields |> Map.put(:operation_id, operation_id) |> Map.put(:status, "applied")
  end

  defp format_result(operation_id, {:error, {:stale_revision, group_id, expected, actual}}) do
    %{
      operation_id: operation_id,
      status: "rejected",
      code: "stale_revision",
      group_id: group_id,
      expected_revision: expected,
      actual_revision: actual
    }
  end

  defp format_result(operation_id, {:error, %Changeset{}}) do
    format_result(operation_id, {:error, :invalid_operation})
  end

  defp format_result(operation_id, {:error, code}) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end
end
