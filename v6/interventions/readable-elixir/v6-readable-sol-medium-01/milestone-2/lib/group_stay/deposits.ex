defmodule GroupStay.Deposits do
  @moduledoc """
  Applies partner operations to group deposits and exposes the read model.

  A batch is intentionally not one transaction. Each operation owns a small
  transaction, which makes a rejection atomic while allowing later operations
  to observe all earlier successful operations in the batch.
  """

  import Ecto.Query

  alias GroupStay.Deposits.{CreditAllocation, CreditLot, Group, Room}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @new_flexible_policy_date ~D[2027-01-01]

  @doc "Applies partner operations in their original order."
  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns an API-ready representation of a group."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group |> Repo.preload(:rooms) |> render_group()}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  @doc "Returns available credit lots for a guest as of the supplied date."
  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  @doc "Returns cash settlement totals and credit liability as of the supplied date."
  def ledger(on \\ Date.utc_today()) do
    cash_totals =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    available_liability =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied_liability =
      Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))

    cash_totals
    |> Map.new(fn {key, value} -> {key, value || 0} end)
    |> Map.put(:credit_liability_cents, (available_liability || 0) + (applied_liability || 0))
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    with :ok <- valid_operation_id(operation_id),
         {:ok, result} <- dispatch(operation) do
      Map.merge(%{operation_id: operation_id, status: "applied"}, result)
    else
      {:error, code} -> rejection(operation_id, code)
      {:error, code, details} -> Map.merge(rejection(operation_id, code), details)
    end
  end

  defp process_operation(_), do: rejection(nil, :invalid_operation)

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: with_group(operation, &record_cash_payment/3)

  defp dispatch(%{"type" => "reschedule_group"} = operation),
    do: with_group(operation, &reschedule_group/3)

  defp dispatch(%{"type" => "cancel_group"} = operation),
    do: with_group(operation, &cancel_group/3)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: with_group(operation, &apply_hotel_credit/3)

  defp dispatch(_operation), do: {:error, :invalid_operation}

  defp open_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      transaction(fn ->
        if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
          Repo.rollback(:group_already_exists)
        end

        with {:ok, booked_on} <- required_date(operation, "occurred_on"),
             {:ok, guest_id} <- required_identifier(operation, "guest_id"),
             {:ok, property_id} <- required_identifier(operation, "property_id"),
             {:ok, arrival_on} <- domain_date(operation, "arrival_on"),
             {:ok, departure_on} <- domain_date(operation, "departure_on"),
             :ok <- valid_stay(arrival_on, departure_on),
             {:ok, rate_plan} <- rate_plan(operation),
             {:ok, rooms} <- rooms(operation),
             nights = Date.diff(departure_on, arrival_on),
             lodging_total = lodging_total(rooms, nights),
             deposit_due = deposit_due(rooms, nights, rate_plan),
             policy_version = policy_version(rate_plan, booked_on),
             {:ok, group} <-
               insert_group(%{
                 group_id: group_id,
                 guest_id: guest_id,
                 property_id: property_id,
                 booked_on: booked_on,
                 arrival_on: arrival_on,
                 departure_on: departure_on,
                 rate_plan: rate_plan,
                 policy_version: policy_version,
                 status: "active",
                 revision: 1,
                 lodging_total_cents: lodging_total,
                 deposit_due_cents: deposit_due,
                 deposit_paid_cents: 0,
                 cash_paid_cents: 0,
                 credit_paid_cents: 0,
                 cash_refunded_cents: 0,
                 cash_retained_cents: 0,
                 cash_converted_to_credit_cents: 0
               }),
             :ok <- insert_rooms(group, rooms) do
          %{group_id: group_id, deposit_due_cents: deposit_due, revision: 1}
        else
          {:error, code} when is_atom(code) -> Repo.rollback(code)
          {:error, _changeset} -> Repo.rollback(:invalid_operation)
        end
      end)
    end
  end

  # Existence and revision checks deliberately precede every other domain rule.
  defp with_group(operation, callback) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      transaction(fn ->
        case Repo.get_by(Group, group_id: group_id) do
          nil ->
            Repo.rollback(:group_not_found)

          group ->
            case check_revision(group, operation) do
              :ok ->
                case required_date(operation, "occurred_on") do
                  {:ok, occurred_on} -> callback.(group, operation, occurred_on)
                  {:error, code} -> Repo.rollback(code)
                end

              {:error, code, details} ->
                Repo.rollback({code, details})

              {:error, code} ->
                Repo.rollback(code)
            end
        end
      end)
    end
  end

  defp record_cash_payment(group, operation, _occurred_on) do
    with :ok <- active(group),
         {:ok, amount} <- payment_amount(operation),
         outstanding = group.deposit_due_cents - group.deposit_paid_cents,
         :ok <- does_not_exceed(amount, outstanding),
         {:ok, updated} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             cash_paid_cents: group.cash_paid_cents + amount,
             revision: group.revision + 1
           }) do
      %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
        revision: updated.revision
      }
    else
      {:error, code} when is_atom(code) -> Repo.rollback(code)
      {:error, _changeset} -> Repo.rollback(:invalid_operation)
    end
  end

  defp apply_hotel_credit(group, operation, occurred_on) do
    with :ok <- active(group),
         {:ok, amount} <- payment_amount(operation),
         outstanding = group.deposit_due_cents - group.deposit_paid_cents,
         :ok <- does_not_exceed(amount, outstanding),
         lots = available_lots(group.guest_id, occurred_on),
         :ok <- enough_credit(lots, amount),
         :ok <- consume_credit(group, lots, amount),
         {:ok, updated} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             credit_paid_cents: group.credit_paid_cents + amount,
             revision: group.revision + 1
           }) do
      %{
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: updated.deposit_due_cents - updated.deposit_paid_cents,
        revision: updated.revision
      }
    else
      {:error, code} when is_atom(code) -> Repo.rollback(code)
      {:error, _changeset} -> Repo.rollback(:invalid_operation)
    end
  end

  defp reschedule_group(group, operation, occurred_on) do
    with :ok <- active(group),
         {:ok, new_arrival_on} <- reschedule_date(operation),
         :ok <- future_arrival(new_arrival_on, occurred_on),
         stay_length = Date.diff(group.departure_on, group.arrival_on),
         new_departure_on = Date.add(new_arrival_on, stay_length),
         {:ok, updated} <-
           update_group(group, %{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: group.revision + 1
           }) do
      %{
        group_id: group.group_id,
        new_arrival_on: updated.arrival_on,
        new_departure_on: updated.departure_on,
        policy_version: group_policy_version(updated),
        refundable_until: refundable_until(updated),
        revision: updated.revision
      }
    else
      {:error, code} when is_atom(code) -> Repo.rollback(code)
      {:error, _changeset} -> Repo.rollback(:invalid_operation)
    end
  end

  defp cancel_group(group, operation, occurred_on) do
    with :ok <- active(group),
         {:ok, refund_method} <- refund_method(operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- refund_method_available(refund_method, refundable?),
         :ok <- settle_applied_credit(group, occurred_on, refundable?),
         {:ok, credit_issued} <-
           issue_cancellation_credit(group, operation, occurred_on, refund_method),
         refunded =
           if(refundable? and refund_method == "cash", do: group.cash_paid_cents, else: 0),
         retained = if(refundable?, do: 0, else: group.cash_paid_cents),
         converted =
           if(refundable? and refund_method == "hotel_credit",
             do: group.cash_paid_cents,
             else: 0
           ),
         {:ok, updated} <-
           update_group(group, %{
             status: "cancelled",
             deposit_due_cents: group.deposit_paid_cents,
             cash_refunded_cents: refunded,
             cash_retained_cents: retained,
             cash_converted_to_credit_cents: converted,
             revision: group.revision + 1
           }) do
      %{
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: credit_issued,
        revision: updated.revision
      }
    else
      {:error, code} when is_atom(code) -> Repo.rollback(code)
      {:error, _changeset} -> Repo.rollback(:invalid_operation)
    end
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp enough_credit(lots, amount) do
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount,
      do: :ok,
      else: {:error, :insufficient_credit}
  end

  defp consume_credit(group, lots, amount) do
    Enum.reduce_while(lots, {:ok, amount}, fn
      _lot, {:ok, 0} ->
        {:halt, :ok}

      lot, {:ok, remaining} ->
        redeemed = min(lot.remaining_cents, remaining)

        with {:ok, _lot} <-
               lot
               |> CreditLot.changeset(%{remaining_cents: lot.remaining_cents - redeemed})
               |> Repo.update(),
             :ok <- add_allocation(group, lot, redeemed) do
          {:cont, {:ok, remaining - redeemed}}
        else
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
    end)
    |> case do
      {:ok, 0} -> :ok
      :ok -> :ok
      other -> other
    end
  end

  defp add_allocation(group, lot, amount) do
    case Repo.get_by(CreditAllocation,
           group_record_id: group.id,
           credit_lot_id: lot.id
         ) do
      nil ->
        case %CreditAllocation{}
             |> CreditAllocation.changeset(%{
               group_record_id: group.id,
               credit_lot_id: lot.id,
               amount_cents: amount
             })
             |> Repo.insert() do
          {:ok, _allocation} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      allocation ->
        case allocation
             |> CreditAllocation.changeset(%{amount_cents: allocation.amount_cents + amount})
             |> Repo.update() do
          {:ok, _allocation} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp settle_applied_credit(group, occurred_on, refundable?) do
    allocations =
      Repo.all(
        from a in CreditAllocation,
          where: a.group_record_id == ^group.id,
          preload: [:credit_lot]
      )

    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      restore_result =
        if refundable? and Date.compare(allocation.credit_lot.expires_on, occurred_on) != :lt do
          allocation.credit_lot
          |> CreditLot.changeset(%{
            remaining_cents: allocation.credit_lot.remaining_cents + allocation.amount_cents
          })
          |> Repo.update()
          |> case do
            {:ok, _lot} -> :ok
            {:error, changeset} -> {:error, changeset}
          end
        else
          :ok
        end

      with :ok <- restore_result,
           {:ok, _allocation} <- Repo.delete(allocation) do
        {:cont, :ok}
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp issue_cancellation_credit(group, operation, occurred_on, "hotel_credit") do
    amount = group.cash_paid_cents + round_percentage(group.cash_paid_cents, 10)

    if amount == 0 do
      {:ok, 0}
    else
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: amount,
        expires_on: Date.add(occurred_on, 365)
      })
      |> Repo.insert()
      |> case do
        {:ok, _lot} -> {:ok, amount}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp issue_cancellation_credit(_group, _operation, _occurred_on, "cash"), do: {:ok, 0}

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ~w(cash hotel_credit) -> {:ok, method}
      _ -> {:error, :invalid_operation}
    end
  end

  defp refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp refund_method_available(_method, _refundable?), do: :ok

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      date -> Date.compare(occurred_on, date) != :gt
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.before?(booked_on, @new_flexible_policy_date), do: "flex-14", else: "flex-30"
  end

  # The fallback keeps rows made by an older binary readable even before a
  # rolling deployment has populated the new column.
  defp group_policy_version(%Group{policy_version: nil} = group),
    do: policy_version(group.rate_plan, group.booked_on)

  defp group_policy_version(group), do: group.policy_version

  defp refundable_until(group) do
    case group_policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp transaction(fun) do
    # IMMEDIATE serializes writers before they read a revision. That prevents
    # two concurrent SQLite transactions from both validating against the same
    # aggregate snapshot and then losing one update.
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> {:ok, result}
      {:error, {code, details}} -> {:error, code, details}
      {:error, code} -> {:error, code}
    end
  end

  defp insert_group(attrs), do: %Group{} |> Group.create_changeset(attrs) |> Repo.insert()

  defp insert_rooms(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {room, position}, :ok ->
      attrs = Map.merge(room, %{group_record_id: group.id, position: position})

      case %Room{} |> Room.changeset(attrs) |> Repo.insert() do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp update_group(group, attrs), do: group |> Group.update_changeset(attrs) |> Repo.update()

  defp check_revision(group, operation) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        {:error, :stale_revision,
         %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         }}

      {:ok, _invalid} ->
        {:error, :invalid_operation}
    end
  end

  defp valid_operation_id(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp valid_operation_id(_), do: {:error, :invalid_operation}

  defp required_identifier(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, :invalid_operation}
    end
  end

  defp required_date(operation, key) do
    case Map.fetch(operation, key) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, :invalid_operation}
        end

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp domain_date(operation, key) do
    case Map.fetch(operation, key) do
      :error ->
        {:error, :invalid_operation}

      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, :invalid_stay}
        end

      {:ok, _} ->
        {:error, :invalid_stay}
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    if Date.before?(arrival_on, departure_on), do: :ok, else: {:error, :invalid_stay}
  end

  defp future_arrival(arrival_on, occurred_on) do
    if Date.after?(arrival_on, occurred_on), do: :ok, else: {:error, :invalid_stay}
  end

  defp reschedule_date(operation) do
    case Map.fetch(operation, "new_arrival_on") do
      :error -> {:error, :invalid_operation}
      {:ok, _} -> domain_date(operation, "new_arrival_on")
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, :invalid_operation}
      {:ok, rate_plan} when rate_plan in @rate_plans -> {:ok, rate_plan}
      {:ok, _} -> {:error, :invalid_rate_plan}
    end
  end

  defp rooms(operation) do
    case Map.fetch(operation, "rooms") do
      :error -> {:error, :invalid_operation}
      {:ok, rooms} when is_list(rooms) and rooms != [] -> validate_rooms(rooms)
      {:ok, _} -> {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(rooms) do
    parsed =
      Enum.reduce_while(rooms, [], fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}, acc
        when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(rate) and rate > 0 ->
          {:cont, [%{room_id: room_id, nightly_rate_cents: rate} | acc]}

        _, _acc ->
          {:halt, :invalid}
      end)

    case parsed do
      :invalid ->
        {:error, :invalid_rooms}

      parsed ->
        parsed = Enum.reverse(parsed)
        ids = Enum.map(parsed, & &1.room_id)
        if Enum.uniq(ids) == ids, do: {:ok, parsed}, else: {:error, :invalid_rooms}
    end
  end

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error -> {:error, :invalid_operation}
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, _} -> {:error, :invalid_amount}
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp does_not_exceed(amount, outstanding) when amount <= outstanding, do: :ok
  defp does_not_exceed(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp lodging_total(rooms, nights) do
    Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))
  end

  defp deposit_due(rooms, nights, "advance_purchase"), do: lodging_total(rooms, nights)

  defp deposit_due(rooms, nights, "flexible") do
    Enum.sum(Enum.map(rooms, &round_percentage(&1.nightly_rate_cents * nights, 20)))
  end

  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)

  defp render_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: group_policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: group.deposit_due_cents - group.deposit_paid_cents
    }
  end

  defp rejection(operation_id, code) do
    %{operation_id: operation_id, status: "rejected", code: Atom.to_string(code)}
  end
end
