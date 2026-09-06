defmodule GroupStay.Groups do
  @moduledoc """
  The group-deposit domain and its transaction boundary.

  A batch intentionally does not share a transaction: each operation either commits its own
  change or rolls back, allowing later operations to observe earlier successful ones.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.{CreditAllocation, CreditLot, Group, Room}

  @group_operation_types [
    "record_cash_payment",
    "reschedule_group",
    "cancel_group",
    "apply_hotel_credit"
  ]
  @flex_30_policy_start ~D[2027-01-01]

  @doc "Processes partner operations in their submitted order."
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Returns a group in the Partner API representation."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :not_found
      group -> {:ok, group |> Repo.preload(rooms: rooms_in_original_order()) |> group_data()}
    end
  end

  def get_group(_group_id), do: :not_found

  @doc "Returns finance totals, evaluating available credit expiry on the supplied date."
  def ledger(on \\ Date.utc_today()) do
    Group
    |> Repo.all()
    |> Enum.reduce(
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0
      },
      fn group, totals ->
        %{
          cash_held_cents:
            totals.cash_held_cents +
              if(group.status == "active", do: cash_paid_cents(group), else: 0),
          cash_refunded_cents: totals.cash_refunded_cents + group.refunded_cents,
          cash_retained_cents: totals.cash_retained_cents + group.retained_cents,
          cash_converted_to_credit_cents:
            totals.cash_converted_to_credit_cents + cash_converted_to_credit_cents(group)
        }
      end
    )
    |> Map.put(:credit_liability_cents, credit_liability_cents(on))
  end

  @doc "Returns a guest's credit that has not expired on the supplied date."
  def get_guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    {:ok,
     %{
       "guest_id" => guest_id,
       "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
       "lots" =>
         Enum.map(lots, fn lot ->
           %{
             "source_operation_id" => lot.source_operation_id,
             "remaining_cents" => lot.remaining_cents,
             "expires_on" => Date.to_iso8601(lot.expires_on)
           }
         end)
     }}
  end

  defp process_operation(operation) when is_map(operation) do
    case Map.get(operation, "type") do
      "open_group" -> process_open_group(operation)
      type when type in @group_operation_types -> process_group_operation(operation, type)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(%{}, "invalid_operation")

  defp process_open_group(operation) do
    with true <- identifier?(Map.get(operation, "group_id")) do
      in_transaction(fn ->
        case Repo.get_by(Group, group_id: operation["group_id"]) do
          %Group{} -> rollback(rejected(operation, "group_already_exists"))
          nil -> create_group(operation)
        end
      end)
    else
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp create_group(operation) do
    case open_group_attributes(operation) do
      {:ok, group_attrs, room_attrs} ->
        case Repo.insert(Group.create_changeset(%Group{}, group_attrs)) do
          {:ok, group} ->
            insert_rooms!(group, room_attrs)

            applied(operation, %{
              "group_id" => group.group_id,
              "deposit_due_cents" => group.deposit_due_cents,
              "revision" => group.revision
            })

          {:error, changeset} ->
            if Keyword.has_key?(changeset.errors, :group_id) do
              rollback(rejected(operation, "group_already_exists"))
            else
              rollback(rejected(operation, "invalid_operation"))
            end
        end

      {:error, code} ->
        rollback(rejected(operation, code))
    end
  end

  defp insert_rooms!(group, room_attrs) do
    Enum.each(room_attrs, fn attrs ->
      attrs
      |> Map.put(:reservation_id, group.id)
      |> then(&Room.changeset(%Room{}, &1))
      |> Repo.insert!()
    end)
  end

  defp process_group_operation(operation, type) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        attempt_group_operation(operation, type, group_id)

      _ ->
        rejected(operation, "invalid_operation")
    end
  end

  # Optimistic locking makes a concurrent mutation visible as a fresh operation attempt. With an
  # expected revision, the retry returns the specified stale_revision response; without one it
  # preserves the API's unconditional mutation behavior.
  defp attempt_group_operation(operation, type, group_id) do
    case in_transaction(fn -> apply_group_operation(operation, type, group_id) end) do
      :write_conflict ->
        attempt_group_operation(operation, type, group_id)

      result ->
        result
    end
  end

  defp apply_group_operation(operation, type, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        rollback(rejected(operation, "group_not_found"))

      group ->
        with :ok <- valid_expected_revision?(operation),
             :ok <- expected_revision_matches?(operation, group),
             {:ok, occurred_on} <- common_operation_data(operation) do
          apply_active_group_operation(operation, type, group, occurred_on)
        else
          {:error, :invalid_expected_revision} ->
            rollback(rejected(operation, "invalid_operation"))

          {:error, {:stale_revision, expected}} ->
            rollback(
              rejected(operation, "stale_revision", %{
                "group_id" => group.group_id,
                "expected_revision" => expected,
                "actual_revision" => group.revision
              })
            )

          {:error, :invalid_operation} ->
            rollback(rejected(operation, "invalid_operation"))
        end
    end
  end

  defp apply_active_group_operation(operation, type, group, occurred_on) do
    if group.status != "active" do
      rollback(rejected(operation, "group_not_active"))
    else
      case type do
        "record_cash_payment" -> record_cash_payment(operation, group)
        "reschedule_group" -> reschedule_group(operation, group, occurred_on)
        "cancel_group" -> cancel_group(operation, group, occurred_on)
        "apply_hotel_credit" -> apply_hotel_credit(operation, group, occurred_on)
      end
    end
  end

  defp record_cash_payment(operation, group) do
    with {:ok, amount_cents} <- payment_amount(operation),
         outstanding = outstanding_deposit(group),
         true <- amount_cents <= outstanding do
      update_group(
        group,
        %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: cash_paid_cents(group) + amount_cents
        },
        fn updated ->
          applied(operation, %{
            "group_id" => updated.group_id,
            "amount_cents" => amount_cents,
            "outstanding_deposit_cents" => outstanding_deposit(updated),
            "revision" => updated.revision
          })
        end
      )
    else
      {:error, :invalid_operation} -> rollback(rejected(operation, "invalid_operation"))
      {:error, :invalid_amount} -> rollback(rejected(operation, "invalid_amount"))
      false -> rollback(rejected(operation, "payment_exceeds_outstanding"))
    end
  end

  defp reschedule_group(operation, group, occurred_on) do
    with {:ok, new_arrival_on} <- new_arrival_on(operation),
         :gt <- Date.compare(new_arrival_on, occurred_on) do
      length_of_stay = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, length_of_stay)

      update_group(
        group,
        %{arrival_on: new_arrival_on, departure_on: new_departure_on},
        fn updated ->
          applied(operation, %{
            "group_id" => updated.group_id,
            "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated.departure_on),
            "policy_version" => policy_version(updated),
            "refundable_until" => iso8601_date(refundable_until(updated)),
            "revision" => updated.revision
          })
        end
      )
    else
      {:error, :invalid_operation} -> rollback(rejected(operation, "invalid_operation"))
      _ -> rollback(rejected(operation, "invalid_stay"))
    end
  end

  defp cancel_group(operation, group, occurred_on) do
    with {:ok, refund_method} <- refund_method(operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- refund_method_available?(refund_method, refundable?) do
      cash_paid_cents = cash_paid_cents(group)
      credit_issued_cents = credit_issued_cents(cash_paid_cents, refundable?, refund_method)
      settle_credit_allocations(group, occurred_on, refundable?)

      issue_credit_lot!(
        group.guest_id,
        operation["operation_id"],
        credit_issued_cents,
        occurred_on
      )

      refunded_cents = if refundable? and refund_method == "cash", do: cash_paid_cents, else: 0
      retained_cents = if refundable?, do: 0, else: cash_paid_cents

      update_group(
        group,
        %{
          status: "cancelled",
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          cash_converted_to_credit_cents:
            if(refundable? and refund_method == "hotel_credit", do: cash_paid_cents, else: 0)
        },
        fn updated ->
          applied(operation, %{
            "group_id" => updated.group_id,
            "refunded_cents" => refunded_cents,
            "retained_cents" => retained_cents,
            "credit_issued_cents" => credit_issued_cents,
            "revision" => updated.revision
          })
        end
      )
    else
      {:error, :invalid_operation} ->
        rollback(rejected(operation, "invalid_operation"))

      {:error, :refund_method_not_available} ->
        rollback(rejected(operation, "refund_method_not_available"))
    end
  end

  defp apply_hotel_credit(operation, group, occurred_on) do
    with {:ok, amount_cents} <- payment_amount(operation),
         outstanding = outstanding_deposit(group),
         true <- amount_cents <= outstanding do
      lots = available_credit_lots(group.guest_id, occurred_on)

      if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount_cents do
        allocate_credit!(lots, group, amount_cents)

        update_group(
          group,
          %{
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            credit_paid_cents: credit_paid_cents(group) + amount_cents
          },
          fn updated ->
            applied(operation, %{
              "group_id" => updated.group_id,
              "amount_cents" => amount_cents,
              "outstanding_deposit_cents" => outstanding_deposit(updated),
              "revision" => updated.revision
            })
          end
        )
      else
        rollback(rejected(operation, "insufficient_credit"))
      end
    else
      {:error, :invalid_operation} -> rollback(rejected(operation, "invalid_operation"))
      {:error, :invalid_amount} -> rollback(rejected(operation, "invalid_amount"))
      false -> rollback(rejected(operation, "payment_exceeds_outstanding"))
    end
  end

  defp refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, method} when method in ["cash", "hotel_credit"] -> {:ok, method}
      {:ok, _method} -> {:error, :invalid_operation}
    end
  end

  defp refund_method_available?("hotel_credit", false), do: {:error, :refund_method_not_available}
  defp refund_method_available?(_refund_method, _refundable?), do: :ok

  defp credit_issued_cents(cash_paid_cents, true, "hotel_credit") do
    cash_paid_cents + round_percentage(cash_paid_cents, 10)
  end

  defp credit_issued_cents(_cash_paid_cents, _refundable?, _refund_method), do: 0

  defp issue_credit_lot!(_guest_id, _source_operation_id, 0, _cancelled_on), do: :ok

  defp issue_credit_lot!(guest_id, source_operation_id, amount_cents, cancelled_on) do
    Repo.insert!(
      CreditLot.create_changeset(%CreditLot{}, %{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount_cents,
        expires_on: Date.add(cancelled_on, 366),
        revision: 1
      })
    )
  end

  defp settle_credit_allocations(group, occurred_on, true) do
    group
    |> credit_allocations()
    |> Enum.group_by(fn {_allocation, lot} -> lot.id end)
    |> Enum.each(fn {_lot_id, allocations} ->
      {_allocation, lot} = hd(allocations)

      amount_cents =
        Enum.sum(Enum.map(allocations, fn {allocation, _lot} -> allocation.amount_cents end))

      if Date.compare(lot.expires_on, occurred_on) == :gt do
        update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents + amount_cents})
      end
    end)

    delete_credit_allocations(group)
  end

  defp settle_credit_allocations(group, _occurred_on, false), do: delete_credit_allocations(group)

  defp credit_allocations(group) do
    from(allocation in CreditAllocation,
      join: lot in CreditLot,
      on: lot.id == allocation.credit_lot_id,
      where: allocation.reservation_id == ^group.id,
      select: {allocation, lot}
    )
    |> Repo.all()
  end

  defp delete_credit_allocations(group) do
    from(allocation in CreditAllocation, where: allocation.reservation_id == ^group.id)
    |> Repo.delete_all()
  end

  defp allocate_credit!(lots, group, amount_cents) do
    Enum.reduce_while(lots, amount_cents, fn lot, remaining_cents ->
      used_cents = min(lot.remaining_cents, remaining_cents)

      if used_cents == 0 do
        {:cont, remaining_cents}
      else
        update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents - used_cents})

        Repo.insert!(
          CreditAllocation.changeset(%CreditAllocation{}, %{
            reservation_id: group.id,
            credit_lot_id: lot.id,
            amount_cents: used_cents
          })
        )

        case remaining_cents - used_cents do
          0 -> {:halt, 0}
          remaining_cents -> {:cont, remaining_cents}
        end
      end
    end)
  end

  defp update_credit_lot!(lot, attrs) do
    case Repo.update(CreditLot.update_changeset(lot, attrs), stale_error_field: :revision) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :revision) do
          rollback(:write_conflict)
        else
          rollback(rejected(%{}, "invalid_operation"))
        end
    end
  end

  defp update_group(group, attrs, result) do
    case Repo.update(Group.update_changeset(group, attrs), stale_error_field: :revision) do
      {:ok, updated} ->
        result.(updated)

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :revision) do
          rollback(:write_conflict)
        else
          rollback(rejected(%{}, "invalid_operation"))
        end
    end
  end

  defp open_group_attributes(operation) do
    with {:ok, booked_on} <- common_operation_data(operation),
         :ok <- open_group_identifiers?(operation),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, arrival_on, departure_on, nights} <- opening_stay(operation),
         {:ok, rooms} <- opening_rooms(operation),
         lodging_total_cents = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights))),
         deposit_due_cents = deposit_due_cents(rooms, nights, rate_plan) do
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
         lodging_total_cents: lodging_total_cents,
         deposit_due_cents: deposit_due_cents,
         deposit_paid_cents: 0,
         cash_paid_cents: 0,
         credit_paid_cents: 0,
         refunded_cents: 0,
         retained_cents: 0,
         cash_converted_to_credit_cents: 0,
         policy_version: policy_version(rate_plan, booked_on),
         revision: 1
       }, rooms}
    else
      {:error, _reason} = error -> error
      false -> {:error, "invalid_operation"}
    end
  end

  defp open_group_identifiers?(operation) do
    if identifier?(operation["operation_id"]) and identifier?(operation["guest_id"]) and
         identifier?(operation["property_id"]) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, "invalid_operation"}
      {:ok, rate_plan} when rate_plan in ["flexible", "advance_purchase"] -> {:ok, rate_plan}
      {:ok, _rate_plan} -> {:error, "invalid_rate_plan"}
    end
  end

  defp opening_stay(operation) do
    with {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         nights = Date.diff(departure_on, arrival_on),
         true <- nights > 0 do
      {:ok, arrival_on, departure_on, nights}
    else
      {:error, :missing} -> {:error, "invalid_operation"}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp opening_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, valid_rooms} ->
          case room_attributes(room, position) do
            {:ok, attributes} -> {:cont, {:ok, [attributes | valid_rooms]}}
            :error -> {:halt, {:error, "invalid_rooms"}}
          end
        end)
        |> case do
          {:ok, valid_rooms} ->
            valid_rooms = Enum.reverse(valid_rooms)

            if valid_rooms |> Enum.map(& &1.room_id) |> Enum.uniq() |> length() ==
                 length(valid_rooms) do
              {:ok, valid_rooms}
            else
              {:error, "invalid_rooms"}
            end

          error ->
            error
        end

      {:ok, _rooms} ->
        {:error, "invalid_rooms"}
    end
  end

  defp room_attributes(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position
       )
       when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
  end

  defp room_attributes(_room, _position), do: :error

  defp deposit_due_cents(rooms, nights, "flexible") do
    rooms
    |> Enum.map(fn room -> round_percentage(room.nightly_rate_cents * nights, 20) end)
    |> Enum.sum()
  end

  defp deposit_due_cents(rooms, nights, "advance_purchase") do
    rooms
    |> Enum.map(&(&1.nightly_rate_cents * nights))
    |> Enum.sum()
  end

  # Inputs are non-negative integer cents. Adding half the denominator implements the required
  # nearest-cent rule with exact halves rounded up.
  defp round_percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)

  defp common_operation_data(operation) do
    with true <- identifier?(operation["operation_id"]),
         {:ok, occurred_on} <- required_date(operation, "occurred_on") do
      {:ok, occurred_on}
    else
      _ -> {:error, :invalid_operation}
    end
  end

  defp valid_expected_revision?(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, revision} when is_integer(revision) -> :ok
      {:ok, _revision} -> {:error, :invalid_expected_revision}
    end
  end

  defp expected_revision_matches?(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:error, {:stale_revision, expected_revision}}
    end
  end

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, :invalid_operation}

      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, :invalid_amount}
    end
  end

  defp new_arrival_on(operation) do
    case required_date(operation, "new_arrival_on") do
      {:error, :missing} -> {:error, :invalid_operation}
      {:error, :invalid} -> {:error, :invalid_stay}
      result -> result
    end
  end

  defp required_date(operation, field) do
    case Map.fetch(operation, field) do
      :error ->
        {:error, :missing}

      {:ok, date} when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed_date} -> {:ok, parsed_date}
          {:error, _reason} -> {:error, :invalid}
        end

      {:ok, _date} ->
        {:error, :invalid}
    end
  end

  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp cash_paid_cents(group), do: group.cash_paid_cents || group.deposit_paid_cents
  defp credit_paid_cents(group), do: group.credit_paid_cents || 0
  defp cash_converted_to_credit_cents(group), do: group.cash_converted_to_credit_cents || 0

  defp policy_version(%Group{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_policy_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, deadline) != :gt
    end
  end

  defp iso8601_date(nil), do: nil
  defp iso8601_date(date), do: Date.to_iso8601(date)

  defp available_credit_lots(guest_id, on) do
    from(lot in CreditLot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
    |> Repo.all()
  end

  defp credit_liability_cents(on) do
    available_cents =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^on,
        select: sum(lot.remaining_cents)
      )
      |> Repo.one()
      |> Kernel.||(0)

    allocated_cents =
      from(allocation in CreditAllocation,
        join: group in Group,
        on: group.id == allocation.reservation_id,
        where: group.status == "active",
        select: sum(allocation.amount_cents)
      )
      |> Repo.one()
      |> Kernel.||(0)

    available_cents + allocated_cents
  end

  defp rooms_in_original_order, do: from(room in Room, order_by: [asc: room.position])

  defp group_data(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "revision" => group.revision,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => cash_paid_cents(group),
      "credit_paid_cents" => credit_paid_cents(group),
      "policy_version" => policy_version(group),
      "refundable_until" => iso8601_date(refundable_until(group)),
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp in_transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp rollback(result), do: Repo.rollback(result)

  defp applied(operation, fields) do
    Map.merge(
      %{"operation_id" => Map.get(operation, "operation_id"), "status" => "applied"},
      fields
    )
  end

  defp rejected(operation, code, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => Map.get(operation, "operation_id"),
        "status" => "rejected",
        "code" => code
      },
      fields
    )
  end
end
