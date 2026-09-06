defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations one at a time. Each mutation is conditional on the
  revision that was read, so a concurrent update cannot silently overwrite it.
  """

  import Ecto.Query

  alias GroupStay.CancellationPolicy
  alias GroupStay.Groups
  alias GroupStay.Groups.{CreditApplication, CreditLot, Group, Room}
  alias GroupStay.Repo

  @max_cents 9_223_372_036_854_775_807
  @retry_attempts 3

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def process_operation(operation) when is_map(operation) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation, @retry_attempts)
      "reschedule_group" -> reschedule_group(operation, @retry_attempts)
      "cancel_group" -> cancel_group(operation, @retry_attempts)
      "apply_hotel_credit" -> apply_hotel_credit(operation, @retry_attempts)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  def process_operation(_operation),
    do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  defp open_group(operation) do
    with {:ok, attrs, rooms} <- validate_open_group(operation),
         {:ok, group} <- insert_group(attrs, rooms) do
      %{
        operation_id: operation["operation_id"],
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:error, code} -> rejected(operation, code)
    end
  end

  defp record_cash_payment(operation, attempts) do
    with_group(operation, fn group ->
      with :ok <- valid_common_date(operation),
           :ok <- active(group),
           {:ok, amount_cents} <- payment_amount(operation),
           :ok <- does_not_exceed_outstanding(group, amount_cents) do
        case conditional_update(group,
               deposit_paid_cents: group.deposit_paid_cents + amount_cents,
               cash_paid_cents: Groups.cash_paid(group) + amount_cents
             ) do
          :ok ->
            %{
              operation_id: operation["operation_id"],
              status: "applied",
              group_id: group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents:
                group.deposit_due_cents - group.deposit_paid_cents - amount_cents,
              revision: group.revision + 1
            }

          :conflict ->
            retry(operation, attempts, &record_cash_payment/2)
        end
      else
        {:error, code} -> rejected(operation, code)
      end
    end)
  end

  defp reschedule_group(operation, attempts) do
    with_group(operation, fn group ->
      with {:ok, occurred_on} <- common_date(operation),
           {:ok, new_arrival_on} <- new_arrival_date(operation),
           :ok <- active(group),
           :ok <- future_arrival(new_arrival_on, occurred_on) do
        days_moved = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.add(group.departure_on, days_moved)

        case conditional_update(group,
               arrival_on: new_arrival_on,
               departure_on: new_departure_on
             ) do
          :ok ->
            %{
              operation_id: operation["operation_id"],
              status: "applied",
              group_id: group.group_id,
              new_arrival_on: Date.to_iso8601(new_arrival_on),
              new_departure_on: Date.to_iso8601(new_departure_on),
              policy_version: Groups.policy_version(group),
              refundable_until:
                group
                |> Groups.policy_version()
                |> CancellationPolicy.refundable_until(new_arrival_on)
                |> format_date(),
              revision: group.revision + 1
            }

          :conflict ->
            retry(operation, attempts, &reschedule_group/2)
        end
      else
        {:error, code} -> rejected(operation, code)
      end
    end)
  end

  defp cancel_group(operation, attempts) do
    with_group(operation, fn group ->
      with {:ok, occurred_on} <- common_date(operation),
           :ok <- active(group),
           {:ok, refund_method} <- refund_method(operation),
           :ok <- refund_method_available(group, occurred_on, refund_method) do
        case settle_cancellation(group, operation["operation_id"], occurred_on, refund_method) do
          {:ok, result} ->
            Map.merge(
              %{
                operation_id: operation["operation_id"],
                status: "applied",
                group_id: group.group_id,
                revision: group.revision + 1
              },
              result
            )

          :conflict ->
            retry(operation, attempts, &cancel_group/2)
        end
      else
        {:error, code} -> rejected(operation, code)
      end
    end)
  end

  defp apply_hotel_credit(operation, attempts) do
    with_group(operation, fn group ->
      with {:ok, occurred_on} <- common_date(operation),
           :ok <- active(group),
           {:ok, amount_cents} <- payment_amount(operation),
           :ok <- does_not_exceed_outstanding(group, amount_cents),
           {:ok, allocations} <- credit_allocations(group.guest_id, occurred_on, amount_cents) do
        case redeem_credit(group, allocations, amount_cents) do
          :ok ->
            %{
              operation_id: operation["operation_id"],
              status: "applied",
              group_id: group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents:
                group.deposit_due_cents - group.deposit_paid_cents - amount_cents,
              revision: group.revision + 1
            }

          :conflict ->
            retry(operation, attempts, &apply_hotel_credit/2)
        end
      else
        {:error, code} -> rejected(operation, code)
      end
    end)
  end

  defp with_group(operation, action) do
    with :ok <- operation_id(operation),
         {:ok, group_id} <- group_identifier(operation),
         %Group{} = group <- Repo.get_by(Group, group_id: group_id),
         :ok <- expected_revision(operation, group) do
      action.(group)
    else
      nil ->
        rejected(operation, "group_not_found")

      {:error, :invalid_operation} ->
        rejected(operation, "invalid_operation")

      {:error, {:stale_revision, group}} ->
        rejected(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation["expected_revision"],
          actual_revision: group.revision
        })
    end
  end

  defp validate_open_group(operation) do
    required_fields = [
      "operation_id",
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]

    with :ok <- require_fields(operation, required_fields),
         :ok <- operation_id(operation),
         :ok <- identifiers(operation, ["group_id", "guest_id", "property_id"]),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(operation["rate_plan"]),
         {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
           rooms(operation["rooms"], arrival_on, departure_on, rate_plan) do
      {:ok,
       %{
         group_id: operation["group_id"],
         guest_id: operation["guest_id"],
         property_id: operation["property_id"],
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         status: "active",
         revision: 1,
         lodging_total_cents: lodging_total_cents,
         deposit_due_cents: deposit_due_cents,
         deposit_paid_cents: 0,
         cash_paid_cents: 0,
         credit_paid_cents: 0,
         policy_version: CancellationPolicy.version(rate_plan, booked_on),
         cancelled_refunded_cents: 0,
         cancelled_retained_cents: 0,
         cancelled_cash_converted_to_credit_cents: 0
       }, rooms}
    else
      {:error, :invalid_operation} -> {:error, "invalid_operation"}
      {:error, :invalid_stay} -> {:error, "invalid_stay"}
      {:error, :invalid_rate_plan} -> {:error, "invalid_rate_plan"}
      {:error, :invalid_rooms} -> {:error, "invalid_rooms"}
      {:error, _invalid_date} -> {:error, "invalid_stay"}
    end
  end

  defp insert_group(attrs, rooms) do
    Repo.transaction(fn ->
      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          Enum.each(rooms, fn room ->
            room
            |> Map.put(:reservation_id, group.id)
            |> then(&Room.changeset(%Room{}, &1))
            |> Repo.insert!()
          end)

          group

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            Repo.rollback("group_already_exists")
          else
            Repo.rollback("invalid_operation")
          end
      end
    end)
    |> case do
      {:ok, group} -> {:ok, group}
      {:error, code} -> {:error, code}
    end
  end

  defp conditional_update(group, changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {updated_count, _} =
      Repo.update_all(
        from(current in Group,
          where: current.id == ^group.id and current.revision == ^group.revision
        ),
        set: Keyword.merge(changes, revision: group.revision + 1, updated_at: now)
      )

    if updated_count == 1, do: :ok, else: :conflict
  end

  defp retry(operation, attempts, operation_fun) when attempts > 0,
    do: operation_fun.(operation, attempts - 1)

  defp retry(operation, _attempts, operation_fun) do
    # A supplied revision becomes stale after a conditional update loses a race;
    # re-entering once produces the documented stale response with the actual
    # revision. Unconditional operations retain their unconditional semantics by
    # retrying against the newly-read state.
    if Map.has_key?(operation, "expected_revision") do
      operation_fun.(operation, 0)
    else
      operation_fun.(operation, @retry_attempts)
    end
  end

  defp operation_id(operation) do
    if valid_identifier?(operation["operation_id"]), do: :ok, else: {:error, :invalid_operation}
  end

  defp group_identifier(operation) do
    case operation["group_id"] do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 -> {:ok, group_id}
      _ -> {:error, :invalid_operation}
    end
  end

  defp identifiers(operation, fields) do
    if Enum.all?(fields, &valid_identifier?(operation[&1])) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, revision} when is_integer(revision) and revision > 0 and revision == group.revision ->
        :ok

      {:ok, revision} when is_integer(revision) and revision > 0 ->
        {:error, {:stale_revision, group}}

      {:ok, _revision} ->
        {:error, :invalid_operation}
    end
  end

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)) do
      :ok
    else
      {:error, :invalid_operation}
    end
  end

  defp valid_common_date(operation) do
    with :ok <- require_fields(operation, ["occurred_on"]),
         {:ok, _date} <- parse_date(operation["occurred_on"]) do
      :ok
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp common_date(operation) do
    with :ok <- require_fields(operation, ["occurred_on"]),
         {:ok, date} <- parse_date(operation["occurred_on"]) do
      {:ok, date}
    else
      _ -> {:error, "invalid_operation"}
    end
  end

  defp new_arrival_date(operation) do
    case require_fields(operation, ["new_arrival_on"]) do
      :ok ->
        case parse_date(operation["new_arrival_on"]) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_stay"}
        end

      {:error, :invalid_operation} ->
        {:error, "invalid_operation"}
    end
  end

  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp parse_date(_date), do: {:error, :invalid_date}

  defp rate_plan("flexible"), do: {:ok, "flexible"}
  defp rate_plan("advance_purchase"), do: {:ok, "advance_purchase"}
  defp rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp rooms(rooms, arrival_on, departure_on, rate_plan) when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new(), 0, 0}, fn {room, position},
                                                           {:ok, acc, ids, lodging, deposit} ->
      case room_amounts(room, nights, rate_plan, ids) do
        {:ok, room_id, rate, room_lodging, room_deposit} ->
          total_lodging = lodging + room_lodging
          total_deposit = deposit + room_deposit

          if total_lodging <= @max_cents and total_deposit <= @max_cents do
            room_attrs = %{room_id: room_id, nightly_rate_cents: rate, position: position}

            {:cont,
             {:ok, [room_attrs | acc], MapSet.put(ids, room_id), total_lodging, total_deposit}}
          else
            {:halt, {:error, :invalid_rooms}}
          end

        {:error, :invalid_rooms} ->
          {:halt, {:error, :invalid_rooms}}
      end
    end)
    |> case do
      {:ok, room_attrs, _ids, lodging, deposit} ->
        {:ok, Enum.reverse(room_attrs), lodging, deposit}

      {:error, :invalid_rooms} ->
        {:error, :invalid_rooms}
    end
  end

  defp rooms(_rooms, _arrival_on, _departure_on, _rate_plan), do: {:error, :invalid_rooms}

  defp room_amounts(%{"room_id" => room_id, "nightly_rate_cents" => rate}, nights, rate_plan, ids)
       when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(rate) and rate > 0 and
              rate <= @max_cents do
    lodging = rate * nights

    if lodging <= @max_cents and not MapSet.member?(ids, room_id) do
      deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
      {:ok, room_id, rate, lodging, deposit}
    else
      {:error, :invalid_rooms}
    end
  end

  defp room_amounts(_room, _nights, _rate_plan, _ids), do: {:error, :invalid_rooms}

  defp payment_amount(operation) do
    with :ok <- require_fields(operation, ["amount_cents"]),
         amount_cents
         when is_integer(amount_cents) and amount_cents > 0 and amount_cents <= @max_cents <-
           operation["amount_cents"] do
      {:ok, amount_cents}
    else
      {:error, :invalid_operation} -> {:error, "invalid_operation"}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(%Group{}), do: {:error, "group_not_active"}

  defp does_not_exceed_outstanding(group, amount_cents) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents,
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp future_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _ -> {:error, "refund_method_not_available"}
    end
  end

  defp refund_method_available(group, occurred_on, "hotel_credit") do
    if refundable?(group, occurred_on),
      do: :ok,
      else: {:error, "refund_method_not_available"}
  end

  defp refund_method_available(_group, _occurred_on, "cash"), do: :ok

  defp refundable?(group, occurred_on) do
    CancellationPolicy.refundable?(
      Groups.policy_version(group),
      group.arrival_on,
      occurred_on
    )
  end

  defp settle_cancellation(group, source_operation_id, occurred_on, refund_method) do
    cash_paid_cents = Groups.cash_paid(group)

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      cancellation_amounts(group, occurred_on, refund_method, cash_paid_cents)

    result = %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents
    }

    case Repo.transaction(fn ->
           if refundable?(group, occurred_on) do
             restore_credit_applications(group.id, occurred_on)
           else
             consume_credit_applications(group.id)
           end

           if credit_issued_cents > 0 do
             expires_on = Date.add(occurred_on, 365)

             %CreditLot{}
             |> CreditLot.changeset(%{
               guest_id: group.guest_id,
               source_operation_id: source_operation_id,
               remaining_cents: credit_issued_cents,
               expires_on: expires_on
             })
             |> Repo.insert!()
           end

           case conditional_update(group,
                  status: "cancelled",
                  cancelled_refunded_cents: refunded_cents,
                  cancelled_retained_cents: retained_cents,
                  cancelled_cash_converted_to_credit_cents: converted_cents
                ) do
             :ok -> result
             :conflict -> Repo.rollback(:conflict)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :conflict} -> :conflict
    end
  end

  defp cancellation_amounts(group, occurred_on, refund_method, cash_paid_cents) do
    if refundable?(group, occurred_on) do
      case refund_method do
        "cash" ->
          {cash_paid_cents, 0, 0, 0}

        "hotel_credit" ->
          credit_issued_cents = cash_paid_cents + percentage_bonus(cash_paid_cents)
          {0, 0, cash_paid_cents, credit_issued_cents}
      end
    else
      {0, cash_paid_cents, 0, 0}
    end
  end

  defp percentage_bonus(amount_cents), do: div(amount_cents * 10 + 50, 100)

  defp restore_credit_applications(reservation_id, occurred_on) do
    credit_applications(reservation_id)
    |> Enum.each(fn application ->
      if Date.compare(application.expires_on, occurred_on) != :lt do
        Repo.update_all(
          from(lot in CreditLot, where: lot.id == ^application.credit_lot_id),
          inc: [remaining_cents: application.amount_cents]
        )
      end
    end)

    consume_credit_applications(reservation_id)
  end

  defp consume_credit_applications(reservation_id) do
    Repo.delete_all(
      from(application in CreditApplication, where: application.reservation_id == ^reservation_id)
    )
  end

  defp credit_applications(reservation_id) do
    Repo.all(
      from(application in CreditApplication,
        join: lot in CreditLot,
        on: lot.id == application.credit_lot_id,
        where: application.reservation_id == ^reservation_id,
        select: %{
          credit_lot_id: application.credit_lot_id,
          amount_cents: application.amount_cents,
          expires_on: lot.expires_on
        }
      )
    )
  end

  defp credit_allocations(guest_id, occurred_on, amount_cents) do
    case take_credit(Groups.available_lots(guest_id, occurred_on), amount_cents) do
      {:ok, allocations} -> {:ok, allocations}
      :insufficient -> {:error, "insufficient_credit"}
    end
  end

  defp take_credit(lots, amount_cents) do
    {allocations, remaining_cents} =
      Enum.reduce_while(lots, {[], amount_cents}, fn lot, {allocations, remaining_cents} ->
        applied_cents = min(lot.remaining_cents, remaining_cents)
        allocation = %{lot: lot, amount_cents: applied_cents}

        if applied_cents == remaining_cents do
          {:halt, {[allocation | allocations], 0}}
        else
          {:cont, {[allocation | allocations], remaining_cents - applied_cents}}
        end
      end)

    if remaining_cents == 0, do: {:ok, Enum.reverse(allocations)}, else: :insufficient
  end

  defp redeem_credit(group, allocations, amount_cents) do
    case Repo.transaction(fn ->
           case debit_credit_lots(allocations) do
             :ok ->
               Enum.each(allocations, fn allocation ->
                 %CreditApplication{}
                 |> CreditApplication.changeset(%{
                   reservation_id: group.id,
                   credit_lot_id: allocation.lot.id,
                   amount_cents: allocation.amount_cents
                 })
                 |> Repo.insert!()
               end)

               case conditional_update(group,
                      deposit_paid_cents: group.deposit_paid_cents + amount_cents,
                      credit_paid_cents: group.credit_paid_cents + amount_cents
                    ) do
                 :ok -> :ok
                 :conflict -> Repo.rollback(:conflict)
               end

             :conflict ->
               Repo.rollback(:conflict)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :conflict} -> :conflict
    end
  end

  defp debit_credit_lots(allocations) do
    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      lot_id = allocation.lot.id
      remaining_cents = allocation.lot.remaining_cents

      {updated_count, _} =
        Repo.update_all(
          from(lot in CreditLot,
            where: lot.id == ^lot_id and lot.remaining_cents == ^remaining_cents
          ),
          set: [remaining_cents: remaining_cents - allocation.amount_cents]
        )

      if updated_count == 1, do: {:cont, :ok}, else: {:halt, :conflict}
    end)
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp rejected(operation, code, extra \\ %{}) do
    Map.merge(
      %{operation_id: Map.get(operation, "operation_id"), status: "rejected", code: code},
      extra
    )
  end
end
