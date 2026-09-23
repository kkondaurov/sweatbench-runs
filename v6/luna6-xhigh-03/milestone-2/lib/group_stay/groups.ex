defmodule GroupStay.Groups do
  @moduledoc "Reservation, deposit, and finance operations for GroupStay."

  import Ecto.Query

  alias GroupStay.Groups.{CreditLot, Group, GroupCreditAllocation, LedgerEntry, Room}
  alias GroupStay.Repo

  @max_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        rooms =
          Repo.all(
            from room in Room,
              where: room.group_id == ^group.group_id,
              order_by: room.position,
              select: %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
          )

        outstanding =
          if group.status == "active",
            do: max(group.deposit_due_cents - group.deposit_paid_cents, 0),
            else: 0

        %{
          group_id: group.group_id,
          guest_id: group.guest_id,
          property_id: group.property_id,
          booked_on: Date.to_iso8601(group.booked_on),
          arrival_on: Date.to_iso8601(group.arrival_on),
          departure_on: Date.to_iso8601(group.departure_on),
          rate_plan: group.rate_plan,
          policy_version: group.policy_version,
          refundable_until: refundable_until(group),
          status: group.status,
          revision: group.revision,
          rooms: rooms,
          lodging_total_cents: group.lodging_total_cents,
          deposit_due_cents: group.deposit_due_cents,
          deposit_paid_cents: group.deposit_paid_cents,
          cash_paid_cents: group.cash_paid_cents,
          credit_paid_cents: group.credit_paid_cents,
          outstanding_deposit_cents: outstanding
        }
    end
  end

  def guest_credit(guest_id, on_date \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on_date,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id],
          select: %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots:
        Enum.map(lots, fn lot ->
          %{lot | expires_on: Date.to_iso8601(lot.expires_on)}
        end)
    }
  end

  def ledger_totals(on_date \\ Date.utc_today()) do
    totals =
      Repo.all(
        from entry in LedgerEntry,
          group_by: entry.entry_type,
          select: {entry.entry_type, sum(entry.amount_cents)}
      )
      |> Map.new()

    held = Map.get(totals, "cash_held", 0) || 0
    refunded = Map.get(totals, "cash_refunded", 0) || 0
    retained = Map.get(totals, "cash_retained", 0) || 0
    converted = Map.get(totals, "cash_converted_to_credit", 0) || 0

    available_credit =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on_date,
          select: sum(lot.remaining_cents)
      ) || 0

    applied_credit =
      Repo.one(
        from allocation in GroupCreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          select: sum(allocation.amount_cents)
      ) || 0

    %{
      cash_held_cents: max(held - refunded - retained - converted, 0),
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: available_credit + applied_credit
    }
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")
    type = Map.get(operation, "type")

    cond do
      not valid_identifier?(operation_id) -> rejection(operation_id, "invalid_operation")
      not is_binary(type) -> rejection(operation_id, "invalid_operation")
      type == "open_group" -> open_group(operation, operation_id)
      type == "record_cash_payment" -> record_cash_payment(operation, operation_id)
      type == "reschedule_group" -> reschedule_group(operation, operation_id)
      type == "cancel_group" -> cancel_group(operation, operation_id)
      type == "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id)
      true -> rejection(operation_id, "invalid_operation")
    end
  end

  defp process_operation(_), do: rejection(nil, "invalid_operation")

  defp open_group(operation, operation_id) do
    group_id = Map.get(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejection(operation_id, "invalid_operation")
    else
      transaction_result(fn ->
        if Repo.get(Group, group_id) do
          {:error, rejection(operation_id, "group_already_exists", %{group_id: group_id})}
        else
          case open_attributes(operation) do
            {:error, code} ->
              {:error, rejection(operation_id, code)}

            {:ok, attrs, room_attrs} ->
              case Repo.insert(Group.changeset(%Group{}, attrs)) do
                {:ok, _group} ->
                  Enum.each(room_attrs, fn room ->
                    Repo.insert!(Room.changeset(%Room{}, Map.put(room, :group_id, group_id)))
                  end)

                  {:ok,
                   applied(operation_id, %{
                     group_id: group_id,
                     deposit_due_cents: attrs.deposit_due_cents,
                     revision: 1
                   })}

                {:error, changeset} ->
                  if Keyword.has_key?(changeset.errors, :group_id) do
                    {:error,
                     rejection(operation_id, "group_already_exists", %{group_id: group_id})}
                  else
                    {:error, rejection(operation_id, "invalid_operation")}
                  end
              end
          end
        end
      end)
    end
  end

  defp record_cash_payment(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      transaction_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, amount} <- payment_amount(operation),
                 {:ok, occurred_on} <- operation_date(operation) do
              outstanding = group.deposit_due_cents - group.deposit_paid_cents

              if amount > outstanding do
                {:error,
                 rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group_id})}
              else
                case update_group(
                       group,
                       %{
                         deposit_paid_cents: group.deposit_paid_cents + amount,
                         cash_paid_cents: group.cash_paid_cents + amount
                       },
                       operation_id
                     ) do
                  :ok ->
                    insert_ledger_entry!(group_id, "cash_held", amount, occurred_on)

                    {:ok,
                     applied(operation_id, %{
                       group_id: group_id,
                       amount_cents: amount,
                       outstanding_deposit_cents: outstanding - amount,
                       revision: group.revision + 1
                     })}

                  {:error, result} ->
                    {:error, result}
                end
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp reschedule_group(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      transaction_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, occurred_on} <- operation_date(operation),
                 {:ok, new_arrival} <- date_field(operation, "new_arrival_on"),
                 true <- Date.compare(new_arrival, occurred_on) == :gt,
                 {:ok, new_departure} <-
                   shifted_date(group.departure_on, Date.diff(new_arrival, group.arrival_on)) do
              case update_group(
                     group,
                     %{arrival_on: new_arrival, departure_on: new_departure},
                     operation_id
                   ) do
                :ok ->
                  {:ok,
                   applied(operation_id, %{
                     group_id: group_id,
                     new_arrival_on: Date.to_iso8601(new_arrival),
                     new_departure_on: Date.to_iso8601(new_departure),
                     policy_version: group.policy_version,
                     refundable_until:
                       date_json(refundable_until_for(group.policy_version, new_arrival)),
                     revision: group.revision + 1
                   })}

                {:error, result} ->
                  {:error, result}
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
              false -> {:error, rejection(operation_id, "invalid_stay", %{group_id: group_id})}
              :error -> {:error, rejection(operation_id, "invalid_stay", %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp cancel_group(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      transaction_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, occurred_on} <- operation_date(operation),
                 {:ok, refund_method} <- refund_method(operation),
                 refundable? <- refundable_on?(group, occurred_on),
                 :ok <- refund_method_allowed(refund_method, refundable?, operation_id, group_id) do
              cash_refunded =
                if refundable? and refund_method == "cash", do: group.cash_paid_cents, else: 0

              cash_retained = if refundable?, do: 0, else: group.cash_paid_cents

              credit_issued =
                if refundable? and refund_method == "hotel_credit",
                  do: credit_issue_amount(group.cash_paid_cents),
                  else: 0

              if credit_issued > @max_integer do
                {:error, rejection(operation_id, "invalid_amount", %{group_id: group_id})}
              else
                case update_group(group, %{status: "cancelled"}, operation_id) do
                  :ok ->
                    if cash_refunded > 0,
                      do:
                        insert_ledger_entry!(
                          group_id,
                          "cash_refunded",
                          cash_refunded,
                          occurred_on
                        )

                    if cash_retained > 0,
                      do:
                        insert_ledger_entry!(
                          group_id,
                          "cash_retained",
                          cash_retained,
                          occurred_on
                        )

                    if credit_issued > 0 do
                      insert_ledger_entry!(
                        group_id,
                        "cash_converted_to_credit",
                        group.cash_paid_cents,
                        occurred_on
                      )

                      expires_on = Date.add(occurred_on, 365)

                      Repo.insert!(
                        CreditLot.changeset(%CreditLot{}, %{
                          guest_id: group.guest_id,
                          source_operation_id: operation_id,
                          issued_cents: credit_issued,
                          remaining_cents: credit_issued,
                          expires_on: expires_on
                        })
                      )
                    end

                    settle_group_credit!(group, occurred_on, refundable?)

                    {:ok,
                     applied(operation_id, %{
                       group_id: group_id,
                       refunded_cents: cash_refunded,
                       retained_cents: cash_retained,
                       credit_issued_cents: credit_issued,
                       revision: group.revision + 1
                     })}

                  {:error, result} ->
                    {:error, result}
                end
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp apply_hotel_credit(operation, operation_id) do
    with {:ok, group_id} <- operation_group_id(operation) do
      transaction_result(fn ->
        case Repo.get(Group, group_id) do
          nil ->
            {:error, rejection(operation_id, "group_not_found", %{group_id: group_id})}

          group ->
            with :ok <- check_revision(operation, group, operation_id),
                 :ok <- active_group(group, operation_id),
                 {:ok, amount} <- payment_amount(operation),
                 {:ok, occurred_on} <- operation_date(operation) do
              outstanding = group.deposit_due_cents - group.deposit_paid_cents

              cond do
                amount > outstanding ->
                  {:error,
                   rejection(operation_id, "payment_exceeds_outstanding", %{group_id: group_id})}

                true ->
                  lots = available_credit_lots(group.guest_id, occurred_on)
                  available = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

                  if available < amount do
                    {:error,
                     rejection(operation_id, "insufficient_credit", %{group_id: group_id})}
                  else
                    case update_group(
                           group,
                           %{
                             deposit_paid_cents: group.deposit_paid_cents + amount,
                             credit_paid_cents: group.credit_paid_cents + amount
                           },
                           operation_id
                         ) do
                      :ok ->
                        consume_credit_lots!(lots, group_id, amount)

                        {:ok,
                         applied(operation_id, %{
                           group_id: group_id,
                           amount_cents: amount,
                           outstanding_deposit_cents: outstanding - amount,
                           revision: group.revision + 1
                         })}

                      {:error, result} ->
                        {:error, result}
                    end
                  end
              end
            else
              {:error, result} when is_map(result) -> {:error, result}
              {:error, code} -> {:error, rejection(operation_id, code, %{group_id: group_id})}
            end
        end
      end)
    else
      {:error, code} -> rejection(operation_id, code)
    end
  end

  defp open_attributes(operation) do
    with {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- date_field(operation, "arrival_on"),
         {:ok, departure_on} <- date_field(operation, "departure_on"),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         guest_id when is_binary(guest_id) and byte_size(guest_id) > 0 <-
           Map.get(operation, "guest_id"),
         property_id when is_binary(property_id) and byte_size(property_id) > 0 <-
           Map.get(operation, "property_id"),
         {:ok, rate_plan} <- rate_plan(Map.get(operation, "rate_plan")),
         {:ok, rooms, lodging_total, deposit_due} <-
           room_amounts(Map.get(operation, "rooms"), arrival_on, departure_on, rate_plan) do
      group_id = Map.get(operation, "group_id")

      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         policy_version: policy_version(rate_plan, booked_on),
         status: "active",
         lodging_total_cents: lodging_total,
         deposit_due_cents: deposit_due,
         deposit_paid_cents: 0,
         cash_paid_cents: 0,
         credit_paid_cents: 0,
         revision: 1
       }, rooms}
    else
      false -> {:error, "invalid_stay"}
      {:error, code} -> {:error, code}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp room_amounts(rooms, arrival_on, departure_on, rate_plan)
       when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    parsed =
      Enum.reduce_while(rooms, {:ok, [], MapSet.new(), 0, 0}, fn room,
                                                                 {:ok, attrs, seen, lodging_sum,
                                                                  deposit_sum} ->
        room_id = if is_map(room), do: Map.get(room, "room_id"), else: nil
        nightly_rate = if is_map(room), do: Map.get(room, "nightly_rate_cents"), else: nil

        cond do
          not valid_identifier?(room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          MapSet.member?(seen, room_id) ->
            {:halt, {:error, "invalid_rooms"}}

          not is_integer(nightly_rate) or nightly_rate <= 0 or nightly_rate > @max_integer ->
            {:halt, {:error, "invalid_rooms"}}

          true ->
            lodging = nights * nightly_rate
            deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

            if lodging > @max_integer or lodging_sum + lodging > @max_integer or
                 deposit_sum + deposit > @max_integer do
              {:halt, {:error, "invalid_rooms"}}
            else
              room_attrs = %{
                group_id: nil,
                room_id: room_id,
                nightly_rate_cents: nightly_rate,
                position: length(attrs)
              }

              {:cont,
               {:ok, [room_attrs | attrs], MapSet.put(seen, room_id), lodging_sum + lodging,
                deposit_sum + deposit}}
            end
        end
      end)

    case parsed do
      {:ok, attrs, _seen, lodging_total, deposit_due} ->
        {:ok, Enum.reverse(attrs), lodging_total, deposit_due}

      error ->
        error
    end
  end

  defp room_amounts(_, _arrival_on, _departure_on, _rate_plan), do: {:error, "invalid_rooms"}

  defp operation_group_id(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 -> {:ok, group_id}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp rate_plan(value) when value in ["flexible", "advance_purchase"], do: {:ok, value}
  defp rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp operation_date(operation) do
    case Map.fetch(operation, "occurred_on") do
      :error -> {:error, "invalid_operation"}
      {:ok, value} -> parse_date(value, "invalid_stay")
    end
  end

  defp date_field(operation, key) do
    case Map.fetch(operation, key) do
      :error -> {:error, "invalid_stay"}
      {:ok, value} -> parse_date(value, "invalid_stay")
    end
  end

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, code}
    end
  end

  defp parse_date(_, code), do: {:error, code}

  defp shifted_date(date, day_shift) do
    {:ok, Date.add(date, day_shift)}
  rescue
    _ -> :error
  end

  defp payment_amount(operation) do
    case Map.get(operation, "amount_cents") do
      amount when is_integer(amount) and amount > 0 and amount <= @max_integer -> {:ok, amount}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp check_revision(operation, group, operation_id) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, expected} when expected === group.revision ->
        :ok

      {:ok, expected} ->
        {:error,
         rejection(operation_id, "stale_revision", %{
           group_id: group.group_id,
           expected_revision: expected,
           actual_revision: group.revision
         })}
    end
  end

  defp active_group(%Group{status: "active"}, _operation_id), do: :ok

  defp active_group(group, operation_id) do
    {:error, rejection(operation_id, "group_not_active", %{group_id: group.group_id})}
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: version, arrival_on: arrival_on}),
    do: refundable_until_for(version, arrival_on)

  defp refundable_until_for("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until_for("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until_for("advance-nonrefundable", _arrival_on), do: nil

  defp date_json(nil), do: nil
  defp date_json(%Date{} = date), do: Date.to_iso8601(date)

  defp refundable_on?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, method} when method in ["cash", "hotel_credit"] -> {:ok, method}
      {:ok, _} -> {:error, "invalid_refund_method"}
    end
  end

  defp refund_method_allowed("hotel_credit", false, operation_id, group_id),
    do: {:error, rejection(operation_id, "refund_method_not_available", %{group_id: group_id})}

  defp refund_method_allowed(_method, _refundable?, _operation_id, _group_id), do: :ok

  defp credit_issue_amount(cash_cents) do
    cash_cents + div(cash_cents + 5, 10)
  end

  defp available_credit_lots(guest_id, on_date) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on_date,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp consume_credit_lots!(lots, group_id, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      used = min(lot.remaining_cents, remaining)

      Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))

      Repo.insert!(
        GroupCreditAllocation.changeset(%GroupCreditAllocation{}, %{
          group_id: group_id,
          credit_lot_id: lot.id,
          amount_cents: used
        })
      )

      if used == remaining do
        {:halt, 0}
      else
        {:cont, remaining - used}
      end
    end)
  end

  defp settle_group_credit!(group, occurred_on, refundable?) do
    allocations =
      Repo.all(
        from allocation in GroupCreditAllocation,
          where: allocation.group_id == ^group.group_id
      )

    Enum.each(allocations, fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable? and Date.compare(lot.expires_on, occurred_on) != :lt do
        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + allocation.amount_cents
          )
        )
      end

      Repo.delete!(allocation)
    end)
  end

  defp update_group(group, attrs, operation_id) do
    query =
      from current in Group,
        where: current.group_id == ^group.group_id and current.revision == ^group.revision

    {count, _} =
      Repo.update_all(query,
        set: Map.to_list(attrs),
        inc: [revision: 1]
      )

    if count == 1 do
      :ok
    else
      actual = Repo.get(Group, group.group_id)

      if actual do
        {:error,
         rejection(operation_id, "stale_revision", %{
           group_id: group.group_id,
           expected_revision: group.revision,
           actual_revision: actual.revision
         })}
      else
        {:error, rejection(operation_id, "group_not_found", %{group_id: group.group_id})}
      end
    end
  end

  defp insert_ledger_entry!(group_id, type, amount, occurred_on) do
    Repo.insert!(
      LedgerEntry.changeset(%LedgerEntry{}, %{
        group_id: group_id,
        entry_type: type,
        amount_cents: amount,
        occurred_on: occurred_on
      })
    )
  end

  defp transaction_result(fun) do
    case Repo.transaction(
           fn ->
             case fun.() do
               {:ok, result} -> result
               {:error, result} -> Repo.rollback(result)
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp rejection(operation_id, code, fields \\ %{}) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
end
