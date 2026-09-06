defmodule GroupStay.Groups do
  @moduledoc """
  Group reservation operations and deposit accounting.

  Each successful operation changes a persisted group row with an optimistic
  revision check. Credit settlement also updates its lots and allocations in
  the same database transaction, so a rejected operation leaves all accounting
  state untouched.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Groups.HotelCreditAllocation
  alias GroupStay.Groups.HotelCreditLot
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @policy_versions ~w(flex-14 flex-30 advance-nonrefundable)
  @new_policy_start ~D[2027-01-01]
  @credit_expiry_days 366

  @spec process_batch(list()) :: list(map())
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec process_operation(map()) :: map()
  def process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")

    if valid_operation_id?(operation_id) do
      process_idempotently(operation, operation_id)
    else
      process_operation_uncached(operation)
    end
  end

  def process_operation(_operation), do: rejected(nil, "invalid_operation")

  @spec get_operation(String.t()) :: Operation.t() | nil
  def get_operation(operation_id) when is_binary(operation_id) do
    Repo.get_by(Operation, operation_id: operation_id)
  end

  def get_operation(_operation_id), do: nil

  @spec operation_json(Operation.t()) :: map()
  def operation_json(%Operation{result_json: result_json}), do: Jason.decode!(result_json)

  defp process_operation_uncached(operation) do
    operation_id = value(operation, "operation_id")

    case value(operation, "type") do
      "open_group" -> open_group(operation, operation_id)
      "record_cash_payment" -> record_cash_payment(operation, operation_id)
      "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id)
      "reschedule_group" -> reschedule_group(operation, operation_id)
      "cancel_group" -> cancel_group(operation, operation_id)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(group_id) when is_binary(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  def get_group(_group_id), do: nil

  @spec group_json(Group.t()) :: map()
  def group_json(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group_policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: Jason.decode!(group.rooms_json),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: cash_paid(group),
      credit_paid_cents: credit_paid(group),
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  @spec guest_credit(String.t(), Date.t()) :: map()
  def guest_credit(guest_id, on) when is_binary(guest_id) and is_struct(on, Date) do
    lots = available_credit_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  @spec ledger(Date.t()) :: map()
  def ledger(on \\ Date.utc_today()) do
    groups = Repo.all(from group in Group, select: group)

    available_credit_cents =
      Repo.all(
        from lot in HotelCreditLot,
          where: lot.remaining_cents > 0 and lot.issued_on <= ^on and lot.expires_on > ^on,
          select: lot.remaining_cents
      )
      |> Enum.sum()

    active_credit_cents =
      groups
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(&credit_paid/1)
      |> Enum.sum()

    Enum.reduce(
      groups,
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        credit_liability_cents: available_credit_cents + active_credit_cents
      },
      fn group, totals ->
        %{
          cash_held_cents:
            totals.cash_held_cents + if(group.status == "active", do: cash_paid(group), else: 0),
          cash_refunded_cents: totals.cash_refunded_cents + (group.cash_refunded_cents || 0),
          cash_retained_cents: totals.cash_retained_cents + (group.cash_retained_cents || 0),
          cash_converted_to_credit_cents:
            totals.cash_converted_to_credit_cents +
              (group.cash_converted_to_credit_cents || 0),
          credit_liability_cents: totals.credit_liability_cents
        }
      end
    )
  end

  @spec parse_on(String.t() | nil) :: {:ok, Date.t()} | :error
  def parse_on(nil), do: {:ok, Date.utc_today()}
  def parse_on(value), do: parse_date(value)

  defp process_idempotently(operation, operation_id, retries \\ 5) do
    payload_json = canonical_json(operation)

    transaction_result =
      Repo.transaction(
        fn ->
          case Repo.get_by(Operation, operation_id: operation_id) do
            %Operation{payload_json: ^payload_json} = stored ->
              {:stored, operation_json(stored)}

            %Operation{} ->
              {:conflict, rejected(operation_id, "operation_id_conflict")}

            nil ->
              result = process_operation_uncached(operation)
              commit_sequence = next_commit_sequence()

              attrs = %{
                operation_id: operation_id,
                operation_type: operation_type(operation),
                commit_sequence: commit_sequence,
                payload_json: payload_json,
                result_json: Jason.encode!(result)
              }

              case %Operation{} |> Operation.changeset(attrs) |> Repo.insert() do
                {:ok, _stored} ->
                  {:new, result}

                {:error, changeset} ->
                  if operation_id_unique_error?(changeset) do
                    Repo.rollback(:operation_id_race)
                  else
                    raise "could not persist operation record: #{inspect(changeset.errors)}"
                  end
              end
          end
        end,
        mode: :immediate
      )

    case transaction_result do
      {:ok, {_source, result}} ->
        result

      {:error, :operation_id_race} when retries > 0 ->
        process_idempotently(operation, operation_id, retries - 1)

      {:error, :operation_id_race} ->
        raise "could not resolve concurrent operation record"

      {:error, reason} ->
        raise "operation transaction rolled back: #{inspect(reason)}"
    end
  end

  defp operation_type(operation) do
    case value(operation, "type") do
      type when is_binary(type) -> type
      nil -> nil
      type -> Jason.encode!(type)
    end
  end

  defp next_commit_sequence do
    Repo.one(from operation in Operation, select: coalesce(max(operation.commit_sequence), 0)) + 1
  end

  defp operation_id_unique_error?(changeset) do
    case Keyword.get(changeset.errors, :operation_id) do
      {_message, options} -> Keyword.get(options, :constraint) == :unique
      nil -> false
    end
  end

  defp group_id_unique_error?(changeset) do
    case Keyword.get(changeset.errors, :group_id) do
      {_message, options} -> Keyword.get(options, :constraint) == :unique
      nil -> false
    end
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} ->
        {Jason.encode!(to_string(key)), canonical_json(nested_value)}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    "{" <>
      Enum.map_join(entries, ",", fn {key, nested_value} -> key <> ":" <> nested_value end) <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp open_group(operation, operation_id) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id"),
         {:ok, guest_id} <- required_string(operation, "guest_id"),
         {:ok, property_id} <- required_string(operation, "property_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on", "invalid_stay"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- required_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(value(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(value(operation, "rooms")) do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            %Group{} ->
              {:rejected, rejected(operation_id, "group_already_exists", group_id: group_id)}

            nil ->
              nights = Date.diff(departure_on, arrival_on)
              normalized_rooms = calculate_rooms(rooms, nights, rate_plan)
              lodging_total_cents = Enum.sum(Enum.map(normalized_rooms, & &1.lodging_total_cents))
              deposit_due_cents = Enum.sum(Enum.map(normalized_rooms, & &1.deposit_due_cents))
              policy_version = policy_version_for_booking(rate_plan, occurred_on)

              attrs = %{
                group_id: group_id,
                guest_id: guest_id,
                property_id: property_id,
                booked_on: occurred_on,
                arrival_on: arrival_on,
                departure_on: departure_on,
                rate_plan: rate_plan,
                policy_version: policy_version,
                rooms_json: Jason.encode!(Enum.map(normalized_rooms, &room_json/1)),
                lodging_total_cents: lodging_total_cents,
                deposit_due_cents: deposit_due_cents,
                deposit_paid_cents: 0,
                cash_paid_cents: 0,
                credit_paid_cents: 0,
                cash_refunded_cents: 0,
                cash_retained_cents: 0,
                cash_converted_to_credit_cents: 0,
                status: "active",
                revision: 1
              }

              case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
                {:ok, _group} ->
                  {:applied,
                   applied(operation_id,
                     group_id: group_id,
                     deposit_due_cents: deposit_due_cents,
                     revision: 1
                   )}

                {:error, changeset} ->
                  if group_id_unique_error?(changeset) do
                    {:rejected,
                     rejected(operation_id, "group_already_exists", group_id: group_id)}
                  else
                    raise "could not persist group: #{inspect(changeset.errors)}"
                  end
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp record_cash_payment(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              {:rejected, rejected(operation_id, "group_not_found", group_id: group_id)}

            %Group{} = group ->
              case stale_revision(operation, group) do
                :ok ->
                  if group.status != "active" do
                    {:rejected, rejected(operation_id, "group_not_active", group_id: group_id)}
                  else
                    case parse_date(value(operation, "occurred_on")) do
                      {:ok, _occurred_on} ->
                        case usable_amount(value(operation, "amount_cents")) do
                          :error ->
                            {:rejected,
                             rejected(operation_id, "invalid_amount", group_id: group_id)}

                          {:ok, amount_cents} ->
                            outstanding = outstanding_deposit(group)

                            if amount_cents > outstanding do
                              {:rejected,
                               rejected(operation_id, "payment_exceeds_outstanding",
                                 group_id: group_id
                               )}
                            else
                              revision = group.revision + 1
                              new_deposit_paid = group.deposit_paid_cents + amount_cents
                              new_cash_paid = cash_paid(group) + amount_cents

                              case update_deposit(
                                     group,
                                     new_deposit_paid,
                                     new_cash_paid,
                                     credit_paid(group),
                                     revision
                                   ) do
                                :ok ->
                                  {:applied,
                                   applied(operation_id,
                                     group_id: group_id,
                                     amount_cents: amount_cents,
                                     outstanding_deposit_cents: outstanding - amount_cents,
                                     revision: revision
                                   )}

                                :conflict when retries > 0 ->
                                  record_cash_payment(operation, operation_id, retries - 1)

                                :conflict ->
                                  {:rejected,
                                   rejected(operation_id, "stale_revision",
                                     group_id: group_id,
                                     expected_revision: value(operation, "expected_revision"),
                                     actual_revision: current_revision(group_id)
                                   )}
                              end
                            end
                        end

                      :error ->
                        {:rejected,
                         rejected(operation_id, "invalid_operation", group_id: group_id)}
                    end
                  end

                {:stale, actual_revision} ->
                  {:rejected,
                   rejected(operation_id, "stale_revision",
                     group_id: group_id,
                     expected_revision: value(operation, "expected_revision"),
                     actual_revision: actual_revision
                   )}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp apply_hotel_credit(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              {:rejected, rejected(operation_id, "group_not_found", group_id: group_id)}

            %Group{} = group ->
              case stale_revision(operation, group) do
                :ok ->
                  if group.status != "active" do
                    {:rejected, rejected(operation_id, "group_not_active", group_id: group_id)}
                  else
                    case parse_date(value(operation, "occurred_on")) do
                      {:ok, occurred_on} ->
                        case usable_amount(value(operation, "amount_cents")) do
                          :error ->
                            {:rejected,
                             rejected(operation_id, "invalid_amount", group_id: group_id)}

                          {:ok, amount_cents} ->
                            outstanding = outstanding_deposit(group)

                            cond do
                              amount_cents > outstanding ->
                                {:rejected,
                                 rejected(operation_id, "payment_exceeds_outstanding",
                                   group_id: group_id
                                 )}

                              true ->
                                lots = available_credit_lots(group.guest_id, occurred_on)

                                if amount_cents > Enum.sum(Enum.map(lots, & &1.remaining_cents)) do
                                  {:rejected,
                                   rejected(operation_id, "insufficient_credit",
                                     group_id: group_id
                                   )}
                                else
                                  revision = group.revision + 1

                                  case apply_credit_transaction(
                                         group,
                                         lots,
                                         amount_cents,
                                         revision
                                       ) do
                                    {:ok, ^revision} ->
                                      {:applied,
                                       applied(operation_id,
                                         group_id: group_id,
                                         amount_cents: amount_cents,
                                         outstanding_deposit_cents: outstanding - amount_cents,
                                         revision: revision
                                       )}

                                    :conflict when retries > 0 ->
                                      apply_hotel_credit(operation, operation_id, retries - 1)

                                    :conflict ->
                                      {:rejected,
                                       rejected(operation_id, "stale_revision",
                                         group_id: group_id,
                                         expected_revision: value(operation, "expected_revision"),
                                         actual_revision: current_revision(group_id)
                                       )}
                                  end
                                end
                            end
                        end

                      :error ->
                        {:rejected,
                         rejected(operation_id, "invalid_operation", group_id: group_id)}
                    end
                  end

                {:stale, actual_revision} ->
                  {:rejected,
                   rejected(operation_id, "stale_revision",
                     group_id: group_id,
                     expected_revision: value(operation, "expected_revision"),
                     actual_revision: actual_revision
                   )}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp reschedule_group(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              {:rejected, rejected(operation_id, "group_not_found", group_id: group_id)}

            %Group{} = group ->
              case stale_revision(operation, group) do
                :ok ->
                  if group.status != "active" do
                    {:rejected, rejected(operation_id, "group_not_active", group_id: group_id)}
                  else
                    case parse_date(value(operation, "new_arrival_on")) do
                      {:ok, new_arrival_on} ->
                        case parse_date(value(operation, "occurred_on")) do
                          {:ok, occurred_on} ->
                            if Date.compare(new_arrival_on, occurred_on) == :gt do
                              stay_length = Date.diff(group.departure_on, group.arrival_on)
                              new_departure_on = Date.add(new_arrival_on, stay_length)
                              revision = group.revision + 1

                              case update_stay(group, new_arrival_on, new_departure_on, revision) do
                                :ok ->
                                  {:applied,
                                   applied(operation_id,
                                     group_id: group_id,
                                     new_arrival_on: Date.to_iso8601(new_arrival_on),
                                     new_departure_on: Date.to_iso8601(new_departure_on),
                                     policy_version: group_policy_version(group),
                                     refundable_until:
                                       refundable_until(
                                         group_policy_version(group),
                                         new_arrival_on
                                       ),
                                     revision: revision
                                   )}

                                :conflict when retries > 0 ->
                                  reschedule_group(operation, operation_id, retries - 1)

                                :conflict ->
                                  {:rejected,
                                   rejected(operation_id, "stale_revision",
                                     group_id: group_id,
                                     expected_revision: value(operation, "expected_revision"),
                                     actual_revision: current_revision(group_id)
                                   )}
                              end
                            else
                              {:rejected,
                               rejected(operation_id, "invalid_stay", group_id: group_id)}
                            end

                          :error ->
                            {:rejected,
                             rejected(operation_id, "invalid_stay", group_id: group_id)}
                        end

                      :error ->
                        {:rejected, rejected(operation_id, "invalid_stay", group_id: group_id)}
                    end
                  end

                {:stale, actual_revision} ->
                  {:rejected,
                   rejected(operation_id, "stale_revision",
                     group_id: group_id,
                     expected_revision: value(operation, "expected_revision"),
                     actual_revision: actual_revision
                   )}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp cancel_group(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              {:rejected, rejected(operation_id, "group_not_found", group_id: group_id)}

            %Group{} = group ->
              case stale_revision(operation, group) do
                :ok ->
                  if group.status != "active" do
                    {:rejected, rejected(operation_id, "group_not_active", group_id: group_id)}
                  else
                    case parse_date(value(operation, "occurred_on")) do
                      {:ok, occurred_on} ->
                        case refund_method(operation) do
                          {:ok, method} ->
                            refundable? = refundable?(group, occurred_on)

                            if method == "hotel_credit" and not refundable? do
                              {:rejected,
                               rejected(operation_id, "refund_method_not_available",
                                 group_id: group_id
                               )}
                            else
                              revision = group.revision + 1

                              case settle_cancellation(
                                     group,
                                     occurred_on,
                                     method,
                                     refundable?,
                                     operation_id,
                                     revision
                                   ) do
                                {:ok, settlement} ->
                                  {:applied,
                                   applied(operation_id,
                                     group_id: group_id,
                                     refunded_cents: settlement.refunded_cents,
                                     retained_cents: settlement.retained_cents,
                                     credit_issued_cents: settlement.credit_issued_cents,
                                     revision: revision
                                   )}

                                :conflict when retries > 0 ->
                                  cancel_group(operation, operation_id, retries - 1)

                                :conflict ->
                                  {:rejected,
                                   rejected(operation_id, "stale_revision",
                                     group_id: group_id,
                                     expected_revision: value(operation, "expected_revision"),
                                     actual_revision: current_revision(group_id)
                                   )}
                              end
                            end

                          :error ->
                            {:rejected,
                             rejected(operation_id, "invalid_operation", group_id: group_id)}
                        end

                      :error ->
                        {:rejected,
                         rejected(operation_id, "invalid_operation", group_id: group_id)}
                    end
                  end

                {:stale, actual_revision} ->
                  {:rejected,
                   rejected(operation_id, "stale_revision",
                     group_id: group_id,
                     expected_revision: value(operation, "expected_revision"),
                     actual_revision: actual_revision
                   )}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp settle_cancellation(
         %Group{} = group,
         occurred_on,
         method,
         refundable?,
         operation_id,
         revision
       ) do
    cash_paid_cents = cash_paid(group)

    {refunded_cents, retained_cents, cash_converted_to_credit_cents} =
      cond do
        refundable? and method == "cash" -> {cash_paid_cents, 0, 0}
        refundable? and method == "hotel_credit" -> {0, 0, cash_paid_cents}
        true -> {0, cash_paid_cents, 0}
      end

    credit_issued_cents =
      if refundable? and method == "hotel_credit" do
        cash_paid_cents + round_percentage(cash_paid_cents, 10, 100)
      else
        0
      end

    transaction_result =
      Repo.transaction(fn ->
        allocations = credit_allocations(group.group_id)

        if refundable? do
          restore_credit_allocations(allocations, occurred_on)
        end

        Repo.delete_all(
          from allocation in HotelCreditAllocation, where: allocation.group_id == ^group.group_id
        )

        if credit_issued_cents > 0 do
          %HotelCreditLot{}
          |> HotelCreditLot.changeset(%{
            guest_id: group.guest_id,
            source_operation_id: operation_id,
            remaining_cents: credit_issued_cents,
            issued_on: occurred_on,
            expires_on: Date.add(occurred_on, @credit_expiry_days)
          })
          |> Repo.insert!()
        end

        case update_cancellation(
               group,
               refunded_cents,
               retained_cents,
               cash_converted_to_credit_cents,
               revision
             ) do
          :ok ->
            %{
              refunded_cents: refunded_cents,
              retained_cents: retained_cents,
              credit_issued_cents: credit_issued_cents
            }

          :conflict ->
            Repo.rollback(:conflict)
        end
      end)

    case transaction_result do
      {:ok, settlement} -> {:ok, settlement}
      {:error, :conflict} -> :conflict
    end
  end

  defp apply_credit_transaction(%Group{} = group, lots, amount_cents, revision) do
    {:ok, allocations} = consume_credit_lots(lots, amount_cents)

    result =
      Repo.transaction(fn ->
        Enum.each(allocations, fn {lot, amount} ->
          remaining_cents = lot.remaining_cents - amount

          case update_credit_lot(lot, remaining_cents) do
            :ok -> :ok
            :conflict -> Repo.rollback(:conflict)
          end
        end)

        Enum.each(allocations, fn {lot, amount} ->
          Repo.insert!(%HotelCreditAllocation{
            group_id: group.group_id,
            lot_id: lot.id,
            amount_cents: amount
          })
        end)

        case update_deposit(
               group,
               group.deposit_paid_cents + amount_cents,
               cash_paid(group),
               credit_paid(group) + amount_cents,
               revision
             ) do
          :ok -> revision
          :conflict -> Repo.rollback(:conflict)
        end
      end)

    case result do
      {:ok, ^revision} -> {:ok, revision}
      {:error, :conflict} -> :conflict
    end
  end

  defp consume_credit_lots(lots, amount_cents) do
    {remaining, allocations} =
      Enum.reduce_while(lots, {amount_cents, []}, fn lot, {remaining, allocations} ->
        amount = min(remaining, lot.remaining_cents)
        next_allocations = if amount > 0, do: [{lot, amount} | allocations], else: allocations

        if remaining - amount == 0 do
          {:halt, {0, next_allocations}}
        else
          {:cont, {remaining - amount, next_allocations}}
        end
      end)

    if remaining == 0, do: {:ok, Enum.reverse(allocations)}, else: :error
  end

  defp restore_credit_allocations(allocations, occurred_on) do
    Enum.each(allocations, fn allocation ->
      lot = Repo.get!(HotelCreditLot, allocation.lot_id)

      if Date.compare(lot.expires_on, occurred_on) == :gt do
        update_credit_lot_amount(lot, allocation.amount_cents)
      end
    end)
  end

  defp credit_allocations(group_id) do
    Repo.all(
      from allocation in HotelCreditAllocation,
        where: allocation.group_id == ^group_id,
        order_by: [asc: allocation.id]
    )
  end

  defp calculate_rooms(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging_total_cents = nights * room.nightly_rate_cents

      deposit_due_cents =
        case rate_plan do
          "flexible" -> round_percentage(lodging_total_cents, 20, 100)
          "advance_purchase" -> lodging_total_cents
        end

      Map.merge(room, %{
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents
      })
    end)
  end

  defp update_deposit(
         %Group{} = group,
         deposit_paid_cents,
         cash_paid_cents,
         credit_paid_cents,
         revision
       ) do
    query =
      from persisted_group in Group,
        where:
          persisted_group.id == ^group.id and
            persisted_group.revision == ^group.revision,
        update: [
          set: [
            deposit_paid_cents: ^deposit_paid_cents,
            cash_paid_cents: ^cash_paid_cents,
            credit_paid_cents: ^credit_paid_cents,
            revision: ^revision
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp update_stay(%Group{} = group, arrival_on, departure_on, revision) do
    query =
      from persisted_group in Group,
        where:
          persisted_group.id == ^group.id and
            persisted_group.revision == ^group.revision,
        update: [set: [arrival_on: ^arrival_on, departure_on: ^departure_on, revision: ^revision]]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp update_cancellation(
         %Group{} = group,
         refunded_cents,
         retained_cents,
         cash_converted_to_credit_cents,
         revision
       ) do
    query =
      from persisted_group in Group,
        where:
          persisted_group.id == ^group.id and
            persisted_group.revision == ^group.revision,
        update: [
          set: [
            cash_refunded_cents: ^refunded_cents,
            cash_retained_cents: ^retained_cents,
            cash_converted_to_credit_cents: ^cash_converted_to_credit_cents,
            status: "cancelled",
            revision: ^revision
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp update_credit_lot(%HotelCreditLot{} = lot, remaining_cents) do
    query =
      from persisted_lot in HotelCreditLot,
        where:
          persisted_lot.id == ^lot.id and
            persisted_lot.remaining_cents == ^lot.remaining_cents,
        update: [set: [remaining_cents: ^remaining_cents]]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp update_credit_lot_amount(%HotelCreditLot{} = lot, amount_cents) do
    case update_credit_lot(lot, lot.remaining_cents + amount_cents) do
      :ok -> :ok
      :conflict -> Repo.rollback(:conflict)
    end
  end

  defp current_revision(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{revision: revision} -> revision
      nil -> nil
    end
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in HotelCreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.issued_on <= ^on and lot.expires_on > ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp room_json(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents
    }
  end

  defp policy_version_for_booking("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for_booking("flexible", booked_on) do
    if Date.compare(booked_on, @new_policy_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp group_policy_version(%Group{policy_version: version}) when version in @policy_versions,
    do: version

  defp group_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}) do
    policy_version_for_booking(rate_plan, booked_on)
  end

  defp refundable_until(%Group{} = group) do
    refundable_until(group_policy_version(group), group.arrival_on)
  end

  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable_until(policy_version, arrival_on) do
    arrival_on
    |> Date.add(cancellation_window(policy_version) * -1)
    |> Date.to_iso8601()
  end

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30

  defp refundable?(group, occurred_on) do
    case refundable_until(group_policy_version(group), group.arrival_on) do
      nil -> false
      date -> Date.compare(occurred_on, Date.from_iso8601!(date)) != :gt
    end
  end

  defp cash_paid(%Group{cash_paid_cents: cash_paid_cents}) when is_integer(cash_paid_cents),
    do: cash_paid_cents

  defp cash_paid(%Group{
         deposit_paid_cents: deposit_paid_cents,
         credit_paid_cents: credit_paid_cents
       }) do
    max(deposit_paid_cents - (credit_paid_cents || 0), 0)
  end

  defp credit_paid(%Group{credit_paid_cents: credit_paid_cents})
       when is_integer(credit_paid_cents),
       do: credit_paid_cents

  defp credit_paid(%Group{}), do: 0

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    result =
      Enum.reduce_while(rooms, {:ok, MapSet.new(), []}, fn room, {:ok, seen, normalized} ->
        with {:ok, room_id} <- required_string(room, "room_id"),
             {:ok, nightly_rate_cents} <- positive_integer(value(room, "nightly_rate_cents")) do
          if MapSet.member?(seen, room_id) do
            {:halt, {:error, "invalid_rooms"}}
          else
            {:cont,
             {:ok, MapSet.put(seen, room_id),
              [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents} | normalized]}}
          end
        else
          _ -> {:halt, {:error, "invalid_rooms"}}
        end
      end)

    case result do
      {:ok, _seen, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp required_string(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_string(_map, _key), do: {:error, "invalid_operation"}

  defp required_date(map, key, error_code) do
    case parse_date(value(map, key)) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, error_code}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: :error

  defp usable_amount(value), do: positive_integer(value)

  defp valid_operation_id(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp valid_operation_id(_value), do: {:error, "invalid_operation"}

  defp valid_operation_id?(value), do: valid_operation_id(value) == :ok

  defp refund_method(operation) do
    if key_present?(operation, "refund_method") do
      case value(operation, "refund_method") do
        method when method in ["cash", "hotel_credit"] -> {:ok, method}
        _method -> :error
      end
    else
      {:ok, "cash"}
    end
  end

  defp stale_revision(operation, %Group{revision: actual_revision}) do
    if key_present?(operation, "expected_revision") do
      case value(operation, "expected_revision") do
        expected_revision
        when is_integer(expected_revision) and expected_revision == actual_revision ->
          :ok

        _ ->
          {:stale, actual_revision}
      end
    else
      :ok
    end
  end

  defp outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit(%Group{}), do: 0

  defp round_percentage(amount, numerator, denominator) do
    div(amount * numerator * 2 + denominator, denominator * 2)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp value(_map, _key), do: nil

  defp key_present?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))
  end

  defp key_present?(_map, _key), do: false

  defp run_operation(fun, _operation_id) do
    case fun.() do
      {status, result} when status in [:applied, :rejected] -> result
      other -> raise "unexpected operation result: #{inspect(other)}"
    end
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))
  end

  defp rejected(operation_id, code, fields \\ []) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))
  end
end
