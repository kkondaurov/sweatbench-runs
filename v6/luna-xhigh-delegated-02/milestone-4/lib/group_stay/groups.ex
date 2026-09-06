defmodule GroupStay.Groups do
  @moduledoc """
  Group reservation operations and deposit accounting.

  Aggregate values on a group remain useful for compatibility with older
  databases, but current accounting is derived from room allocations. Every
  operation and its idempotency record are committed in one transaction.
  """

  import Ecto.Query

  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.CashPayment
  alias GroupStay.Groups.CreditLotEntitlement
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
  def process_batch(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

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
  def get_operation(operation_id) when is_binary(operation_id),
    do: Repo.get_by(Operation, operation_id: operation_id)

  def get_operation(_operation_id), do: nil

  @spec operation_json(Operation.t()) :: map()
  def operation_json(%Operation{result_json: result_json}), do: Jason.decode!(result_json)

  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(group_id) when is_binary(group_id), do: Repo.get_by(Group, group_id: group_id)
  def get_group(_group_id), do: nil

  @spec group_json(Group.t()) :: map()
  def group_json(%Group{} = group) do
    details = room_accounting(group)
    totals = totals_from_details(details)

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
      rooms:
        Enum.map(details, fn %{room: room, cash_paid_cents: cash, credit_paid_cents: credit} ->
          Map.merge(room, %{cash_paid_cents: cash, credit_paid_cents: credit})
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents
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

  @spec payment_reconciliation(String.t()) :: {:ok, map()} | {:error, String.t()}
  def payment_reconciliation(payment_operation_id) when is_binary(payment_operation_id) do
    with %Operation{operation_type: "record_cash_payment"} = operation <-
           get_operation(payment_operation_id),
         result <- operation_json(operation),
         true <- result["status"] == "applied",
         payment <- payment_record_for_read(payment_operation_id, result) do
      case payment do
        %CashPayment{} = payment ->
          {:ok,
           %{
             payment_operation_id: payment.payment_operation_id,
             original_group_id: payment.group_id,
             recorded_cents: payment.recorded_cents,
             held_cents: payment.held_cents,
             refunded_cents: payment.refunded_cents,
             retained_cents: payment.retained_cents,
             converted_to_credit_cents: payment.converted_to_credit_cents,
             reduced_cents: payment.reduced_cents,
             charged_back_cents: payment.charged_back_cents
           }}

        :missing ->
          {:error, "payment_not_reconcilable"}
      end
    else
      nil -> {:error, "operation_not_found"}
      false -> {:error, "payment_not_reconcilable"}
      %Operation{} -> {:error, "payment_not_reconcilable"}
      _ -> {:error, "payment_not_reconcilable"}
    end
  end

  def payment_reconciliation(_payment_operation_id), do: {:error, "operation_not_found"}

  defp payment_record_for_read(payment_operation_id, result) do
    case Repo.get_by(CashPayment, payment_operation_id: payment_operation_id) do
      %CashPayment{} = payment ->
        payment

      nil ->
        case Repo.get_by(Group, group_id: result["group_id"]) do
          %Group{status: "active"} = group when group.room_accounting_initialized == false ->
            %CashPayment{
              payment_operation_id: payment_operation_id,
              group_id: group.group_id,
              recorded_cents: result["amount_cents"],
              held_cents: result["amount_cents"]
            }

          _ ->
            :missing
        end
    end
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
      |> Enum.map(fn group -> totals_from_details(room_accounting(group)).credit_paid_cents end)
      |> Enum.sum()

    payment_totals =
      Repo.one(
        from payment in CashPayment,
          select: %{
            refunded: coalesce(sum(payment.refunded_cents), 0),
            retained: coalesce(sum(payment.retained_cents), 0),
            converted: coalesce(sum(payment.converted_to_credit_cents), 0),
            reduced: coalesce(sum(payment.reduced_cents), 0),
            charged_back: coalesce(sum(payment.charged_back_cents), 0)
          }
      )

    legacy_totals =
      Enum.reduce(groups, %{refunded: 0, retained: 0, converted: 0}, fn group, totals ->
        %{
          refunded: totals.refunded + (group.cash_refunded_cents || 0),
          retained: totals.retained + (group.cash_retained_cents || 0),
          converted: totals.converted + (group.cash_converted_to_credit_cents || 0)
        }
      end)

    shortfall =
      Repo.all(from lot in HotelCreditLot, where: lot.unrecovered_clawback_cents > 0)
      |> Enum.map(fn lot ->
        applied =
          Repo.one(
            from allocation in HotelCreditAllocation,
              join: group in Group,
              on: group.group_id == allocation.group_id,
              where: allocation.lot_id == ^lot.id and group.status == "active",
              select: coalesce(sum(allocation.amount_cents), 0)
          )

        min(lot.unrecovered_clawback_cents, applied)
      end)
      |> Enum.sum()

    %{
      cash_held_cents:
        groups
        |> Enum.filter(&(&1.status == "active"))
        |> Enum.map(fn group -> totals_from_details(room_accounting(group)).cash_paid_cents end)
        |> Enum.sum(),
      cash_refunded_cents: legacy_totals.refunded + payment_totals.refunded,
      cash_retained_cents: legacy_totals.retained + payment_totals.retained,
      cash_converted_to_credit_cents: legacy_totals.converted + payment_totals.converted,
      cash_reduced_cents: payment_totals.reduced,
      cash_charged_back_cents: payment_totals.charged_back,
      credit_liability_cents: available_credit_cents + active_credit_cents,
      credit_shortfall_cents: shortfall
    }
  end

  @spec parse_on(String.t() | nil) :: {:ok, Date.t()} | :error
  def parse_on(nil), do: {:ok, Date.utc_today()}
  def parse_on(value), do: parse_date(value)

  @doc """
  Materialize room allocations for groups created before room accounting was
  introduced. The migration calls this after adding the new tables; keeping
  the same operation available makes an interrupted deployment retryable.
  """
  @spec backfill_room_accounting() :: :ok
  def backfill_room_accounting do
    case Repo.transaction(fn ->
           Repo.all(from group in Group, where: group.room_accounting_initialized == false)
           |> Enum.each(&prepare_room_accounting/1)
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "room accounting backfill failed: #{inspect(reason)}"
    end
  end

  defp process_operation_uncached(operation) do
    operation_id = value(operation, "operation_id")

    case value(operation, "type") do
      "open_group" -> open_group(operation, operation_id)
      "record_cash_payment" -> record_cash_payment(operation, operation_id)
      "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id)
      "reschedule_group" -> reschedule_group(operation, operation_id)
      "cancel_group" -> cancel_group(operation, operation_id)
      "cancel_rooms" -> cancel_rooms(operation, operation_id)
      "reduce_cash_payment" -> reduce_cash_payment(operation, operation_id)
      "charge_back_payment" -> charge_back_payment(operation, operation_id)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

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

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

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
      case Repo.get_by(Group, group_id: group_id) do
        %Group{} ->
          rejected(operation_id, "group_already_exists", group_id: group_id)

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
            room_accounting_initialized: true,
            status: "active",
            revision: 1
          }

          case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
            {:ok, _group} ->
              applied(operation_id,
                group_id: group_id,
                deposit_due_cents: deposit_due_cents,
                revision: 1
              )

            {:error, changeset} ->
              if group_id_unique_error?(changeset) do
                rejected(operation_id, "group_already_exists", group_id: group_id)
              else
                raise "could not persist group: #{inspect(changeset.errors)}"
              end
          end
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp record_cash_payment(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          rejected(operation_id, "group_not_found", group_id: group_id)

        %Group{} = group ->
          case stale_revision(operation, group) do
            {:stale, actual} ->
              stale_result(operation_id, group_id, operation, actual)

            :ok ->
              cond do
                group.status != "active" ->
                  rejected(operation_id, "group_not_active", group_id: group_id)

                parse_date(value(operation, "occurred_on")) == :error ->
                  rejected(operation_id, "invalid_operation", group_id: group_id)

                true ->
                  case usable_amount(value(operation, "amount_cents")) do
                    :error ->
                      rejected(operation_id, "invalid_amount", group_id: group_id)

                    {:ok, amount} ->
                      outstanding =
                        totals_from_details(room_accounting(group)).outstanding_deposit_cents

                      if amount > outstanding do
                        rejected(operation_id, "payment_exceeds_outstanding", group_id: group_id)
                      else
                        revision = group.revision + 1

                        case apply_cash_payment(group, operation_id, amount, revision) do
                          :ok ->
                            applied(operation_id,
                              group_id: group_id,
                              amount_cents: amount,
                              outstanding_deposit_cents: outstanding - amount,
                              revision: revision
                            )

                          :conflict when retries > 0 ->
                            record_cash_payment(operation, operation_id, retries - 1)

                          :conflict ->
                            stale_result(
                              operation_id,
                              group_id,
                              operation,
                              current_revision(group_id)
                            )
                        end
                      end
                  end
              end
          end
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp apply_cash_payment(group, operation_id, amount, revision) do
    case Repo.transaction(fn ->
           prepared = prepare_room_accounting(group)
           plan = funding_plan(prepared, amount)

           if plan == :error, do: Repo.rollback(:conflict)

           %CashPayment{}
           |> CashPayment.changeset(%{
             payment_operation_id: operation_id,
             group_id: group.group_id,
             recorded_cents: amount,
             held_cents: amount
           })
           |> Repo.insert!()

           Enum.each(plan, fn {room_id, room_amount} ->
             Repo.insert!(%CashAllocation{
               group_id: group.group_id,
               room_id: room_id,
               payment_operation_id: operation_id,
               amount_cents: room_amount
             })
           end)

           case update_group_row(prepared, revision, deposit_fields(prepared, amount, 0)) do
             :ok -> :ok
             :conflict -> Repo.rollback(:conflict)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :conflict} -> :conflict
    end
  end

  defp apply_hotel_credit(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          rejected(operation_id, "group_not_found", group_id: group_id)

        %Group{} = group ->
          case stale_revision(operation, group) do
            {:stale, actual} ->
              stale_result(operation_id, group_id, operation, actual)

            :ok ->
              cond do
                group.status != "active" ->
                  rejected(operation_id, "group_not_active", group_id: group_id)

                parse_date(value(operation, "occurred_on")) == :error ->
                  rejected(operation_id, "invalid_operation", group_id: group_id)

                true ->
                  with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
                       {:ok, amount} <- usable_amount(value(operation, "amount_cents")) do
                    outstanding =
                      totals_from_details(room_accounting(group)).outstanding_deposit_cents

                    lots = available_credit_lots(group.guest_id, occurred_on)

                    cond do
                      amount > outstanding ->
                        rejected(operation_id, "payment_exceeds_outstanding", group_id: group_id)

                      amount > Enum.sum(Enum.map(lots, & &1.remaining_cents)) ->
                        rejected(operation_id, "insufficient_credit", group_id: group_id)

                      true ->
                        revision = group.revision + 1

                        case apply_credit_payment(group, operation_id, amount, lots, revision) do
                          :ok ->
                            applied(operation_id,
                              group_id: group_id,
                              amount_cents: amount,
                              outstanding_deposit_cents: outstanding - amount,
                              revision: revision
                            )

                          :conflict when retries > 0 ->
                            apply_hotel_credit(operation, operation_id, retries - 1)

                          :conflict ->
                            stale_result(
                              operation_id,
                              group_id,
                              operation,
                              current_revision(group_id)
                            )
                        end
                    end
                  else
                    :error -> rejected(operation_id, "invalid_amount", group_id: group_id)
                  end
              end
          end
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp apply_credit_payment(group, operation_id, amount, lots, revision) do
    case Repo.transaction(fn ->
           prepared = prepare_room_accounting(group)
           room_plan = funding_plan(prepared, amount)
           {:ok, lot_plan} = consume_credit_lots(lots, amount)
           allocations = room_lot_plan(room_plan, lot_plan)

           Enum.each(lot_plan, fn {lot, lot_amount} ->
             case update_credit_lot(lot, lot.remaining_cents - lot_amount) do
               :ok -> :ok
               :conflict -> Repo.rollback(:conflict)
             end
           end)

           Enum.each(allocations, fn {room_id, lot, allocation_amount} ->
             Repo.insert!(%HotelCreditAllocation{
               group_id: group.group_id,
               lot_id: lot.id,
               room_id: room_id,
               operation_id: operation_id,
               amount_cents: allocation_amount
             })
           end)

           case update_group_row(prepared, revision, deposit_fields(prepared, 0, amount)) do
             :ok -> :ok
             :conflict -> Repo.rollback(:conflict)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :conflict} -> :conflict
    end
  end

  defp reschedule_group(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      case Repo.get_by(Group, group_id: group_id) do
        nil ->
          rejected(operation_id, "group_not_found", group_id: group_id)

        %Group{} = group ->
          case stale_revision(operation, group) do
            {:stale, actual} ->
              stale_result(operation_id, group_id, operation, actual)

            :ok ->
              cond do
                group.status != "active" ->
                  rejected(operation_id, "group_not_active", group_id: group_id)

                true ->
                  with {:ok, new_arrival} <- parse_date(value(operation, "new_arrival_on")),
                       {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
                       true <- Date.compare(new_arrival, occurred_on) == :gt do
                    stay_length = Date.diff(group.departure_on, group.arrival_on)
                    new_departure = Date.add(new_arrival, stay_length)
                    revision = group.revision + 1

                    case update_group_row(group, revision,
                           arrival_on: new_arrival,
                           departure_on: new_departure
                         ) do
                      :ok ->
                        applied(operation_id,
                          group_id: group_id,
                          new_arrival_on: Date.to_iso8601(new_arrival),
                          new_departure_on: Date.to_iso8601(new_departure),
                          policy_version: group_policy_version(group),
                          refundable_until:
                            refundable_until(group_policy_version(group), new_arrival),
                          revision: revision
                        )

                      :conflict when retries > 0 ->
                        reschedule_group(operation, operation_id, retries - 1)

                      :conflict ->
                        stale_result(
                          operation_id,
                          group_id,
                          operation,
                          current_revision(group_id)
                        )
                    end
                  else
                    _ -> rejected(operation_id, "invalid_stay", group_id: group_id)
                  end
              end
          end
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp cancel_group(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      cancel_selected(operation, operation_id, group_id, nil, retries)
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp cancel_rooms(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      room_ids =
        if is_nil(value(operation, "room_ids")),
          do: :missing_room_ids,
          else: value(operation, "room_ids")

      cancel_selected(operation, operation_id, group_id, room_ids, retries)
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp cancel_selected(operation, operation_id, group_id, requested_room_ids, retries) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        rejected(operation_id, "group_not_found", group_id: group_id)

      %Group{} = group ->
        case stale_revision(operation, group) do
          {:stale, actual} ->
            stale_result(operation_id, group_id, operation, actual)

          :ok ->
            cond do
              group.status != "active" ->
                rejected(operation_id, "group_not_active", group_id: group_id)

              parse_date(value(operation, "occurred_on")) == :error ->
                rejected(operation_id, "invalid_operation", group_id: group_id)

              true ->
                with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
                     {:ok, method} <- refund_method(operation),
                     {:ok, room_ids} <- cancellation_room_ids(group, requested_room_ids),
                     refundable? <- refundable?(group, occurred_on) do
                  if method == "hotel_credit" and not refundable? do
                    rejected(operation_id, "refund_method_not_available", group_id: group_id)
                  else
                    revision = group.revision + 1

                    case settle_rooms(
                           group,
                           room_ids,
                           occurred_on,
                           method,
                           refundable?,
                           operation_id,
                           revision
                         ) do
                      {:ok, settlement} ->
                        result =
                          applied(operation_id,
                            group_id: group_id,
                            refunded_cents: settlement.refunded_cents,
                            retained_cents: settlement.retained_cents,
                            credit_issued_cents: settlement.credit_issued_cents,
                            revision: revision
                          )

                        if requested_room_ids == nil,
                          do: result,
                          else: Map.put(result, :cancelled_room_ids, room_ids)

                      :conflict when retries > 0 ->
                        cancel_selected(
                          operation,
                          operation_id,
                          group_id,
                          requested_room_ids,
                          retries - 1
                        )

                      :conflict ->
                        stale_result(
                          operation_id,
                          group_id,
                          operation,
                          current_revision(group_id)
                        )
                    end
                  end
                else
                  {:error, "invalid_rooms"} ->
                    rejected(operation_id, "invalid_rooms", group_id: group_id)

                  {:error, _code} ->
                    rejected(operation_id, "invalid_operation", group_id: group_id)
                end
            end
        end
    end
  end

  defp settle_rooms(group, room_ids, occurred_on, method, refundable?, operation_id, revision) do
    case Repo.transaction(fn ->
           prepared = prepare_room_accounting(group)
           cash_rows = cash_allocations_for_rooms(prepared.group_id, room_ids)
           credit_rows = credit_allocations_for_rooms(prepared.group_id, room_ids)
           cash_by_payment = Enum.group_by(cash_rows, & &1.payment_operation_id)
           legacy_cash = Enum.sum(Enum.map(Map.get(cash_by_payment, nil, []), & &1.amount_cents))

           durable_cash =
             Enum.reject(cash_by_payment, fn {payment_id, _rows} -> is_nil(payment_id) end)

           {refunded, retained, converted, legacy_totals} =
             settle_cash_rows(durable_cash, legacy_cash, method, refundable?)

           if refundable? do
             credit_rows
             |> Enum.group_by(& &1.lot_id)
             |> Enum.each(fn {lot_id, rows} ->
               amount = Enum.sum(Enum.map(rows, & &1.amount_cents))
               restore_credit_lot!(Repo.get!(HotelCreditLot, lot_id), amount, occurred_on)
             end)
           end

           Repo.delete_all(
             from allocation in CashAllocation,
               where:
                 allocation.group_id == ^prepared.group_id and allocation.room_id in ^room_ids
           )

           Repo.delete_all(
             from allocation in HotelCreditAllocation,
               where:
                 allocation.group_id == ^prepared.group_id and allocation.room_id in ^room_ids
           )

           credit_issued =
             if refundable? and method == "hotel_credit",
               do:
                 converted + legacy_totals.converted +
                   round_percentage(converted + legacy_totals.converted, 10, 100),
               else: 0

           lot =
             if credit_issued > 0,
               do: new_credit_lot!(prepared, operation_id, occurred_on, credit_issued)

           if lot, do: create_lot_entitlements!(lot, cash_rows)

           rooms = room_specs(prepared)

           new_rooms =
             Enum.map(rooms, fn room ->
               if room.room_id in room_ids, do: Map.put(room, :status, "cancelled"), else: room
             end)

           new_status =
             if Enum.any?(new_rooms, &(&1.status == "active")), do: "active", else: "cancelled"

           group_attrs = [
             rooms_json: Jason.encode!(Enum.map(new_rooms, &room_json/1)),
             status: new_status,
             cash_refunded_cents: (prepared.cash_refunded_cents || 0) + legacy_totals.refunded,
             cash_retained_cents: (prepared.cash_retained_cents || 0) + legacy_totals.retained,
             cash_converted_to_credit_cents:
               (prepared.cash_converted_to_credit_cents || 0) + legacy_totals.converted
           ]

           case update_group_row(prepared, revision, group_attrs) do
             :ok ->
               {:ok,
                %{
                  refunded_cents: refunded + legacy_totals.refunded,
                  retained_cents: retained + legacy_totals.retained,
                  credit_issued_cents: if(is_nil(lot), do: 0, else: credit_issued)
                }}

             :conflict ->
               Repo.rollback(:conflict)
           end
         end) do
      {:ok, {:ok, settlement}} -> {:ok, settlement}
      {:ok, settlement} -> {:ok, settlement}
      {:error, :conflict} -> :conflict
    end
  end

  defp settle_cash_rows(durable_cash, legacy_cash, method, refundable?) do
    {refunded, retained, converted} =
      Enum.reduce(durable_cash, {0, 0, 0}, fn {payment_id, rows},
                                              {refund_total, retain_total, convert_total} ->
        amount = Enum.sum(Enum.map(rows, & &1.amount_cents))
        payment = Repo.get_by!(CashPayment, payment_operation_id: payment_id)

        attrs =
          cond do
            refundable? and method == "cash" ->
              %{
                held_cents: payment.held_cents - amount,
                refunded_cents: payment.refunded_cents + amount
              }

            refundable? and method == "hotel_credit" ->
              %{
                held_cents: payment.held_cents - amount,
                converted_to_credit_cents: payment.converted_to_credit_cents + amount
              }

            true ->
              %{
                held_cents: payment.held_cents - amount,
                retained_cents: payment.retained_cents + amount
              }
          end

        Repo.update!(Ecto.Changeset.change(payment, attrs))

        cond do
          refundable? and method == "cash" ->
            {refund_total + amount, retain_total, convert_total}

          refundable? and method == "hotel_credit" ->
            {refund_total, retain_total, convert_total + amount}

          true ->
            {refund_total, retain_total + amount, convert_total}
        end
      end)

    legacy =
      cond do
        refundable? and method == "cash" ->
          %{refunded: legacy_cash, retained: 0, converted: 0}

        refundable? and method == "hotel_credit" ->
          %{refunded: 0, retained: 0, converted: legacy_cash}

        true ->
          %{refunded: 0, retained: legacy_cash, converted: 0}
      end

    {refunded, retained, converted, legacy}
  end

  defp reduce_cash_payment(operation, operation_id) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, target_id} <- required_string(operation, "payment_operation_id") do
      case target_payment(target_id) do
        {:error, code} ->
          rejected(operation_id, code)

        {:ok, _target_operation, target_result, payment} ->
          group_id = target_result["group_id"]

          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              rejected(operation_id, "operation_not_found")

            group ->
              case stale_revision(operation, group) do
                {:stale, actual} ->
                  stale_result(operation_id, group_id, operation, actual)

                :ok ->
                  cond do
                    payment.held_cents <= 0 ->
                      rejected(operation_id, "payment_not_reducible")

                    true ->
                      case usable_amount(value(operation, "amount_cents")) do
                        :error ->
                          rejected(operation_id, "invalid_amount")

                        {:ok, amount} when amount > payment.held_cents ->
                          rejected(operation_id, "reduction_exceeds_held_cash")

                        {:ok, amount} ->
                          outstanding =
                            totals_from_details(room_accounting(group)).outstanding_deposit_cents

                          revision = group.revision + 1

                          case reduce_payment_transaction(group, payment, amount, revision) do
                            :ok ->
                              applied(operation_id,
                                payment_operation_id: target_id,
                                group_id: group_id,
                                amount_cents: amount,
                                outstanding_deposit_cents: outstanding + amount,
                                revision: revision
                              )

                            :conflict ->
                              stale_result(
                                operation_id,
                                group_id,
                                operation,
                                current_revision(group_id)
                              )
                          end
                      end
                  end
              end
          end
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp reduce_payment_transaction(group, payment, amount, revision) do
    case Repo.transaction(fn ->
           prepared = prepare_room_accounting(group)
           remove_cash_amount!(prepared, payment.payment_operation_id, amount)

           payment
           |> Ecto.Changeset.change(
             held_cents: payment.held_cents - amount,
             reduced_cents: payment.reduced_cents + amount
           )
           |> Repo.update!()

           case update_group_row(prepared, revision, []) do
             :ok -> :ok
             :conflict -> Repo.rollback(:conflict)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :conflict} -> :conflict
    end
  end

  defp charge_back_payment(operation, operation_id) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, target_id} <- required_string(operation, "payment_operation_id") do
      case target_payment(target_id) do
        {:error, code} ->
          rejected(operation_id, code)

        {:ok, _target_operation, target_result, payment} ->
          group_id = target_result["group_id"]

          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              rejected(operation_id, "operation_not_found")

            group ->
              case stale_revision(operation, group) do
                {:stale, actual} ->
                  stale_result(operation_id, group_id, operation, actual)

                :ok ->
                  if payment.charged_back_cents > 0 or
                       payment.recorded_cents == payment.reduced_cents do
                    rejected(operation_id, "payment_not_chargeable")
                  else
                    charged_back =
                      payment.held_cents + payment.refunded_cents + payment.retained_cents +
                        payment.converted_to_credit_cents

                    outstanding =
                      totals_from_details(room_accounting(group)).outstanding_deposit_cents

                    revision = group.revision + 1

                    case charge_back_transaction(group, payment, charged_back, revision) do
                      :ok ->
                        applied(operation_id,
                          payment_operation_id: target_id,
                          group_id: group_id,
                          charged_back_cents: charged_back,
                          outstanding_deposit_cents: outstanding + payment.held_cents,
                          revision: revision
                        )

                      :conflict ->
                        stale_result(
                          operation_id,
                          group_id,
                          operation,
                          current_revision(group_id)
                        )
                    end
                  end
              end
          end
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp charge_back_transaction(group, payment, charged_back, revision) do
    case Repo.transaction(fn ->
           prepared = prepare_room_accounting(group)

           if payment.held_cents > 0,
             do: remove_cash_amount!(prepared, payment.payment_operation_id, payment.held_cents)

           revoke_credit_entitlements!(payment.payment_operation_id)

           payment
           |> Ecto.Changeset.change(
             held_cents: 0,
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             charged_back_cents: charged_back
           )
           |> Repo.update!()

           case update_group_row(prepared, revision, []) do
             :ok -> :ok
             :conflict -> Repo.rollback(:conflict)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :conflict} -> :conflict
    end
  end

  defp target_payment(target_id) do
    case get_operation(target_id) do
      nil ->
        {:error, "operation_not_found"}

      %Operation{operation_type: "record_cash_payment"} = operation ->
        result = operation_json(operation)

        if result["status"] == "applied" do
          group = Repo.get_by(Group, group_id: result["group_id"])

          if group && group.room_accounting_initialized == false do
            prepare_room_accounting(group)
          end

          case Repo.get_by(CashPayment, payment_operation_id: target_id) do
            %CashPayment{} = payment -> {:ok, operation, result, payment}
            nil -> {:error, "payment_not_reducible"}
          end
        else
          {:error, "payment_not_reducible"}
        end

      %Operation{} ->
        {:error, "payment_not_reducible"}
    end
  end

  defp cancellation_room_ids(group, nil) do
    {:ok, room_specs(group) |> Enum.filter(&(&1.status == "active")) |> Enum.map(& &1.room_id)}
  end

  defp cancellation_room_ids(_group, :missing_room_ids), do: {:error, "invalid_rooms"}

  defp cancellation_room_ids(group, room_ids) when is_list(room_ids) do
    rooms = room_specs(group)

    if room_ids != [] and length(room_ids) == length(Enum.uniq(room_ids)) and
         Enum.all?(room_ids, &is_binary/1) and
         Enum.all?(room_ids, fn room_id ->
           Enum.any?(rooms, &(&1.room_id == room_id and &1.status == "active"))
         end) do
      {:ok, Enum.map(rooms, & &1.room_id) |> Enum.filter(&(&1 in room_ids))}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp cancellation_room_ids(_group, _room_ids), do: {:error, "invalid_rooms"}

  defp funding_plan(group, amount) do
    details = room_accounting(group)

    {remaining, plan} =
      Enum.reduce_while(details, {amount, []}, fn detail, {left, acc} ->
        capacity =
          if detail.room.status == "active" do
            max(
              detail.room.deposit_due_cents - detail.cash_paid_cents - detail.credit_paid_cents,
              0
            )
          else
            0
          end

        allocation = min(left, capacity)
        next = if allocation > 0, do: [{detail.room.room_id, allocation} | acc], else: acc

        if left - allocation == 0,
          do: {:halt, {0, next}},
          else: {:cont, {left - allocation, next}}
      end)

    if remaining == 0, do: Enum.reverse(plan), else: :error
  end

  defp room_lot_plan(room_plan, lot_plan) do
    {allocations, _lots} =
      Enum.reduce(room_plan, {[], lot_plan}, fn {room_id, room_amount}, {acc, lots} ->
        {room_allocations, remaining_lots} = take_from_lots(lots, room_amount, room_id, [])
        {acc ++ room_allocations, remaining_lots}
      end)

    allocations
  end

  defp take_from_lots([{lot, left} | rest], amount, room_id, acc) do
    taken = min(left, amount)
    next_acc = if taken > 0, do: acc ++ [{room_id, lot, taken}], else: acc

    if taken == amount do
      {next_acc, [{lot, left - taken} | rest]}
    else
      {more, remaining} = take_from_lots(rest, amount - taken, room_id, [])
      {next_acc ++ more, remaining}
    end
  end

  defp take_from_lots([], _amount, _room_id, acc), do: {acc, []}

  defp consume_credit_lots(lots, amount) do
    {remaining, allocations} =
      Enum.reduce_while(lots, {amount, []}, fn lot, {left, acc} ->
        taken = min(left, lot.remaining_cents)
        next = if taken > 0, do: acc ++ [{lot, taken}], else: acc
        if left - taken == 0, do: {:halt, {0, next}}, else: {:cont, {left - taken, next}}
      end)

    if remaining == 0, do: {:ok, allocations}, else: :error
  end

  defp prepare_room_accounting(%Group{room_accounting_initialized: true} = group), do: group

  defp prepare_room_accounting(%Group{} = group) do
    rooms = room_specs(group)

    current_cash =
      Repo.all(from allocation in CashAllocation, where: allocation.group_id == ^group.group_id)

    events = historical_funding_events(group)

    if events == [] do
      cash_total = Enum.sum(Enum.map(current_cash, & &1.amount_cents))

      legacy_cash =
        if group.status == "active", do: max(group_cash_value(group) - cash_total, 0), else: 0

      if legacy_cash > 0 do
        Enum.each(legacy_funding_plan(rooms, legacy_cash), fn {room_id, amount} ->
          Repo.insert!(%CashAllocation{
            group_id: group.group_id,
            room_id: room_id,
            amount_cents: amount
          })
        end)
      end

      allocate_legacy_credit_allocations(group, rooms, legacy_cash)
    else
      backfill_historical_funding!(group, rooms, current_cash, events)
    end

    Repo.update_all(from(persisted_group in Group, where: persisted_group.id == ^group.id),
      set: [room_accounting_initialized: true]
    )

    %{group | room_accounting_initialized: true}
  end

  defp historical_funding_events(group) do
    Repo.all(from operation in Operation, order_by: [asc: operation.commit_sequence])
    |> Enum.flat_map(fn operation ->
      result = Jason.decode!(operation.result_json)

      if result["status"] == "applied" and result["group_id"] == group.group_id and
           operation.operation_type in ["record_cash_payment", "apply_hotel_credit"] and
           is_integer(result["amount_cents"]) and result["amount_cents"] > 0 do
        [{operation.operation_type, operation.operation_id, result["amount_cents"]}]
      else
        []
      end
    end)
  end

  defp backfill_historical_funding!(group, rooms, current_cash, events) do
    if group.status == "cancelled" do
      backfill_cancelled_historical_funding!(group, events)
    else
      backfill_active_historical_funding!(group, rooms, current_cash, events)
    end
  end

  defp backfill_active_historical_funding!(group, rooms, current_cash, events) do
    recorded_cash =
      events
      |> Enum.filter(&(elem(&1, 0) == "record_cash_payment"))
      |> Enum.sum_by(&elem(&1, 2))

    recorded_credit =
      events
      |> Enum.filter(&(elem(&1, 0) == "apply_hotel_credit"))
      |> Enum.sum_by(&elem(&1, 2))

    current_cash_total = Enum.sum(Enum.map(current_cash, & &1.amount_cents))

    legacy_cash =
      if group.status == "active",
        do: max(group_cash_value(group) - current_cash_total - recorded_cash, 0),
        else: 0

    used =
      legacy_funding_plan(rooms, legacy_cash)
      |> Enum.reduce(%{}, fn {room_id, amount}, used ->
        Repo.insert!(%CashAllocation{
          group_id: group.group_id,
          room_id: room_id,
          amount_cents: amount
        })

        Map.put(used, room_id, amount)
      end)

    credit_rows =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group.group_id and is_nil(allocation.room_id),
          order_by: [asc: allocation.id]
      )

    credit_total = Enum.sum(Enum.map(credit_rows, & &1.amount_cents))
    legacy_credit = max(credit_total - recorded_credit, 0)

    Repo.delete_all(
      from allocation in HotelCreditAllocation,
        where: allocation.group_id == ^group.group_id and is_nil(allocation.room_id)
    )

    source_lots = Enum.map(credit_rows, &{&1.lot_id, &1.amount_cents})

    {used, source_lots} =
      materialize_credit_event!(group, rooms, used, source_lots, legacy_credit, nil)

    {_, _source_lots} =
      Enum.reduce(events, {used, source_lots}, fn {type, operation_id, amount},
                                                  {used, source_lots} ->
        case type do
          "record_cash_payment" ->
            plan = allocate_credit_to_rooms(rooms, used, amount) |> elem(0)

            if Enum.sum(Enum.map(plan, &elem(&1, 1))) == amount do
              unless Repo.get_by(CashPayment, payment_operation_id: operation_id) do
                Repo.insert!(%CashPayment{
                  payment_operation_id: operation_id,
                  group_id: group.group_id,
                  recorded_cents: amount,
                  held_cents: amount
                })
              end

              Enum.each(plan, fn {room_id, room_amount} ->
                Repo.insert!(%CashAllocation{
                  group_id: group.group_id,
                  room_id: room_id,
                  payment_operation_id: operation_id,
                  amount_cents: room_amount
                })
              end)

              {add_room_amounts(used, plan), source_lots}
            else
              {used, source_lots}
            end

          "apply_hotel_credit" ->
            materialize_credit_event!(group, rooms, used, source_lots, amount, operation_id)
        end
      end)
  end

  defp backfill_cancelled_historical_funding!(group, events) do
    cash_events = Enum.filter(events, &(elem(&1, 0) == "record_cash_payment"))

    classification = %{
      refunded: group.cash_refunded_cents || 0,
      retained: group.cash_retained_cents || 0,
      converted: group.cash_converted_to_credit_cents || 0
    }

    {converted_payments, _remaining} =
      Enum.reduce(cash_events, {[], classification}, fn {_type, operation_id, amount},
                                                        {converted, remaining} ->
        {refunded, remaining} = take_classification(remaining, :refunded, amount)
        {retained, remaining} = take_classification(remaining, :retained, amount - refunded)

        {converted_amount, remaining} =
          take_classification(remaining, :converted, amount - refunded - retained)

        Repo.insert!(%CashPayment{
          payment_operation_id: operation_id,
          group_id: group.group_id,
          recorded_cents: amount,
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: converted_amount
        })

        if converted_amount > 0,
          do: {[{operation_id, converted_amount} | converted], remaining},
          else: {converted, remaining}
      end)

    converted_payments = Enum.reverse(converted_payments)

    Enum.each(
      Repo.all(
        from operation in Operation,
          where: operation.operation_type == "cancel_group",
          order_by: [asc: operation.commit_sequence]
      ),
      fn cancellation ->
        result = Jason.decode!(cancellation.result_json)

        if result["group_id"] == group.group_id and result["credit_issued_cents"] > 0 do
          case Repo.get_by(HotelCreditLot, source_operation_id: cancellation.operation_id) do
            %HotelCreditLot{} = lot -> create_entitlements_for_payments!(lot, converted_payments)
            nil -> :ok
          end
        end
      end
    )
  end

  defp take_classification(remaining, key, amount) when amount > 0 do
    taken = min(Map.get(remaining, key, 0), amount)
    {taken, Map.update!(remaining, key, &(&1 - taken))}
  end

  defp take_classification(remaining, _key, _amount), do: {0, remaining}

  defp create_entitlements_for_payments!(lot, payments) do
    Enum.reduce(payments, 0, fn {payment_id, amount}, cumulative ->
      next = cumulative + amount
      entitlement = bonus_adjusted_value(next) - bonus_adjusted_value(cumulative)

      Repo.insert!(%CreditLotEntitlement{
        lot_id: lot.id,
        payment_operation_id: payment_id,
        amount_cents: entitlement
      })

      next
    end)
  end

  defp materialize_credit_event!(_group, _rooms, used, source_lots, amount, _operation_id)
       when amount <= 0,
       do: {used, source_lots}

  defp materialize_credit_event!(group, rooms, used, source_lots, amount, operation_id) do
    room_plan = allocate_credit_to_rooms(rooms, used, amount) |> elem(0)

    if Enum.sum(Enum.map(room_plan, &elem(&1, 1))) != amount do
      {used, source_lots}
    else
      {lot_slices, remaining_lots} = take_source_lots(source_lots, amount)

      if Enum.sum(Enum.map(lot_slices, &elem(&1, 1))) != amount do
        {used, source_lots}
      else
        insert_room_credit_slices!(group, room_plan, lot_slices, operation_id)
        {add_room_amounts(used, room_plan), remaining_lots}
      end
    end
  end

  defp take_source_lots(lots, amount), do: take_source_lots(lots, amount, [])

  defp take_source_lots([{lot_id, left} | rest], amount, taken) when amount > 0 do
    part = min(left, amount)
    next_taken = if part > 0, do: taken ++ [{lot_id, part}], else: taken
    next_lots = if left - part > 0, do: [{lot_id, left - part} | rest], else: rest

    if amount - part == 0,
      do: {next_taken, next_lots},
      else: take_source_lots(next_lots, amount - part, next_taken)
  end

  defp take_source_lots(lots, _amount, taken), do: {taken, lots}

  defp insert_room_credit_slices!(group, room_plan, lot_slices, operation_id) do
    Enum.reduce(room_plan, lot_slices, fn {room_id, room_amount}, lots ->
      {room_slices, remaining_lots} = take_source_lots(lots, room_amount)

      Enum.each(room_slices, fn {lot_id, amount} ->
        Repo.insert!(%HotelCreditAllocation{
          group_id: group.group_id,
          lot_id: lot_id,
          room_id: room_id,
          operation_id: operation_id,
          amount_cents: amount
        })
      end)

      remaining_lots
    end)
  end

  defp add_room_amounts(used, plan),
    do:
      Enum.reduce(plan, used, fn {room_id, amount}, used ->
        Map.update(used, room_id, amount, &(&1 + amount))
      end)

  defp allocate_legacy_credit_allocations(group, rooms, legacy_cash) do
    rows =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group.group_id and is_nil(allocation.room_id),
          order_by: [asc: allocation.id]
      )

    initial_cash = Map.new(legacy_funding_plan(rooms, legacy_cash))

    Enum.reduce(rows, initial_cash, fn row, used_amounts ->
      {assignments, new_used} = allocate_credit_to_rooms(rooms, used_amounts, row.amount_cents)

      case assignments do
        [{first_room, _first_amount} | rest] ->
          Repo.update!(Ecto.Changeset.change(row, room_id: first_room))

          Enum.each(rest, fn {room_id, amount} ->
            Repo.insert!(%HotelCreditAllocation{
              group_id: row.group_id,
              lot_id: row.lot_id,
              room_id: room_id,
              operation_id: row.operation_id,
              amount_cents: amount
            })
          end)

        [] ->
          :ok
      end

      new_used
    end)
  end

  defp allocate_credit_to_rooms(rooms, used, amount) do
    {assignments, used, _left} =
      Enum.reduce_while(rooms, {[], used, amount}, fn room, {assignments, used, left} ->
        capacity =
          if room.status == "active" do
            max(room.deposit_due_cents - Map.get(used, room.room_id, 0), 0)
          else
            0
          end

        taken = min(capacity, left)

        if taken > 0 do
          new_assignments = assignments ++ [{room.room_id, taken}]
          new_used = Map.update(used, room.room_id, taken, &(&1 + taken))

          if left - taken == 0,
            do: {:halt, {new_assignments, new_used, 0}},
            else: {:cont, {new_assignments, new_used, left - taken}}
        else
          {:cont, {assignments, used, left}}
        end
      end)

    {assignments, used}
  end

  defp legacy_funding_plan(rooms, amount) do
    {_, plan} =
      Enum.reduce_while(rooms, {amount, []}, fn room, {left, acc} ->
        if room.status != "active" do
          {:cont, {left, acc}}
        else
          taken = min(left, room.deposit_due_cents)
          next = if taken > 0, do: [{room.room_id, taken} | acc], else: acc
          if left - taken == 0, do: {:halt, {0, next}}, else: {:cont, {left - taken, next}}
        end
      end)

    Enum.reverse(plan)
  end

  defp room_accounting(%Group{} = group) do
    rooms = room_specs(group)

    credit_rows =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group.group_id and not is_nil(allocation.room_id)
      )

    cash_rows =
      Repo.all(from allocation in CashAllocation, where: allocation.group_id == ^group.group_id)

    if group.room_accounting_initialized do
      cash_by_room = sum_by_room(cash_rows)
      credit_by_room = sum_by_room(credit_rows)

      Enum.map(rooms, fn room ->
        %{
          room: room,
          cash_paid_cents:
            if(room.status == "active", do: Map.get(cash_by_room, room.room_id, 0), else: 0),
          credit_paid_cents:
            if(room.status == "active", do: Map.get(credit_by_room, room.room_id, 0), else: 0)
        }
      end)
    else
      virtual_legacy_accounting(group, rooms, cash_rows)
    end
  end

  defp virtual_legacy_accounting(group, rooms, cash_rows) do
    cash_total =
      case cash_rows do
        [] -> if(group.status == "active", do: group_cash_value(group), else: 0)
        rows -> Enum.sum(Enum.map(rows, & &1.amount_cents))
      end

    cash_by_room = Map.new(legacy_funding_plan(rooms, cash_total))

    credit_total =
      Enum.sum(
        Repo.all(
          from allocation in HotelCreditAllocation,
            where: allocation.group_id == ^group.group_id,
            select: allocation.amount_cents
        )
      )

    credit_total = if credit_total > 0, do: credit_total, else: group.credit_paid_cents || 0

    {_, credit_by_room} =
      Enum.reduce(rooms, {credit_total, %{}}, fn room, {left, acc} ->
        if room.status != "active" do
          {left, acc}
        else
          capacity = max(room.deposit_due_cents - Map.get(cash_by_room, room.room_id, 0), 0)
          taken = min(left, capacity)
          {left - taken, Map.put(acc, room.room_id, taken)}
        end
      end)

    Enum.map(rooms, fn room ->
      %{
        room: room,
        cash_paid_cents:
          if(room.status == "active", do: Map.get(cash_by_room, room.room_id, 0), else: 0),
        credit_paid_cents:
          if(room.status == "active", do: Map.get(credit_by_room, room.room_id, 0), else: 0)
      }
    end)
  end

  defp sum_by_room(rows),
    do:
      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(acc, row.room_id, row.amount_cents, &(&1 + row.amount_cents))
      end)

  defp totals_from_details(details) do
    active = Enum.filter(details, &(&1.room.status == "active"))
    due = Enum.sum(Enum.map(active, & &1.room.deposit_due_cents))
    cash = Enum.sum(Enum.map(active, & &1.cash_paid_cents))
    credit = Enum.sum(Enum.map(active, & &1.credit_paid_cents))

    %{
      lodging_total_cents: Enum.sum(Enum.map(active, & &1.room.lodging_total_cents)),
      deposit_due_cents: due,
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      outstanding_deposit_cents: max(due - cash - credit, 0)
    }
  end

  defp deposit_fields(group, cash_amount, credit_amount) do
    [
      deposit_paid_cents: (group.deposit_paid_cents || 0) + cash_amount + credit_amount,
      cash_paid_cents: group_cash_value(group) + cash_amount,
      credit_paid_cents: (group.credit_paid_cents || 0) + credit_amount
    ]
  end

  defp update_group_row(%Group{} = group, revision, attrs) do
    set = Keyword.put(attrs, :revision, revision)

    query =
      from persisted_group in Group,
        where: persisted_group.id == ^group.id and persisted_group.revision == ^group.revision,
        update: [set: ^set]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp cash_allocations_for_rooms(group_id, room_ids) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
        order_by: [asc: allocation.id]
    )
  end

  defp credit_allocations_for_rooms(group_id, room_ids) do
    Repo.all(
      from allocation in HotelCreditAllocation,
        where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
        order_by: [asc: allocation.id]
    )
  end

  defp remove_cash_amount!(group, payment_id, amount) do
    room_order =
      group
      |> room_specs()
      |> Enum.with_index()
      |> Map.new(fn {room, index} -> {room.room_id, index} end)

    rows =
      Repo.all(
        from allocation in CashAllocation,
          where:
            allocation.group_id == ^group.group_id and
              allocation.payment_operation_id == ^payment_id,
          order_by: [asc: allocation.id]
      )
      |> Enum.sort_by(fn row -> {Map.get(room_order, row.room_id, -1), row.id} end, :desc)

    {remaining, _} =
      Enum.reduce_while(rows, {amount, :ok}, fn row, {left, _} ->
        removed = min(left, row.amount_cents)

        if removed == row.amount_cents do
          Repo.delete!(row)
        else
          Repo.update!(Ecto.Changeset.change(row, amount_cents: row.amount_cents - removed))
        end

        if left - removed == 0, do: {:halt, {0, :ok}}, else: {:cont, {left - removed, :ok}}
      end)

    if remaining > 0, do: Repo.rollback(:conflict)
  end

  defp restore_credit_lot!(%HotelCreditLot{} = lot, amount, occurred_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents || 0)
    excess = amount - absorbed
    available = if Date.compare(lot.expires_on, occurred_on) == :gt, do: excess, else: 0

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents + available,
      unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed
    )
    |> Repo.update!()
  end

  defp new_credit_lot!(group, operation_id, occurred_on, amount) do
    %HotelCreditLot{}
    |> HotelCreditLot.changeset(%{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: amount,
      issued_on: occurred_on,
      expires_on: Date.add(occurred_on, @credit_expiry_days)
    })
    |> Repo.insert!()
  end

  defp create_lot_entitlements!(lot, cash_rows) do
    cash_rows
    |> Enum.group_by(& &1.payment_operation_id)
    |> ordered_cash_blocks()
    |> Enum.reduce({0, 0}, fn {payment_id, amount}, {_previous, cumulative} ->
      next_cumulative = cumulative + amount

      entitlement = bonus_adjusted_value(next_cumulative) - bonus_adjusted_value(cumulative)

      if entitlement > 0 do
        Repo.insert!(%CreditLotEntitlement{
          lot_id: lot.id,
          payment_operation_id: payment_id,
          amount_cents: entitlement
        })
      end

      {next_cumulative, next_cumulative}
    end)
  end

  defp ordered_cash_blocks(cash_by_payment) do
    legacy = Map.get(cash_by_payment, nil, []) |> Enum.sum_by(& &1.amount_cents)
    payment_ids = cash_by_payment |> Map.keys() |> Enum.reject(&is_nil/1)

    sequences =
      Repo.all(
        from operation in Operation,
          where: operation.operation_id in ^payment_ids,
          select: {operation.operation_id, operation.commit_sequence}
      )
      |> Map.new()

    durable =
      payment_ids
      |> Enum.sort_by(&Map.get(sequences, &1, 0))
      |> Enum.map(fn payment_id ->
        {payment_id,
         Enum.sum(Enum.map(Map.fetch!(cash_by_payment, payment_id), & &1.amount_cents))}
      end)

    if legacy > 0, do: [{nil, legacy} | durable], else: durable
  end

  defp revoke_credit_entitlements!(payment_id) do
    Repo.all(
      from entitlement in CreditLotEntitlement,
        where: entitlement.payment_operation_id == ^payment_id
    )
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(HotelCreditLot, entitlement.lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          (lot.unrecovered_clawback_cents || 0) + entitlement.amount_cents - removed
      )
      |> Repo.update!()
    end)
  end

  defp update_credit_lot(%HotelCreditLot{} = lot, remaining_cents) do
    query =
      from persisted_lot in HotelCreditLot,
        where:
          persisted_lot.id == ^lot.id and persisted_lot.remaining_cents == ^lot.remaining_cents,
        update: [set: [remaining_cents: ^remaining_cents]]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
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

  defp room_specs(%Group{} = group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    group.rooms_json
    |> Jason.decode!()
    |> Enum.map(fn room ->
      rate = room["nightly_rate_cents"]
      lodging = room["lodging_total_cents"] || nights * rate
      due = room["deposit_due_cents"] || calculate_room_deposit(lodging, group.rate_plan)
      status = room["status"] || if(group.status == "active", do: "active", else: "cancelled")

      %{
        room_id: room["room_id"],
        nightly_rate_cents: rate,
        lodging_total_cents: lodging,
        deposit_due_cents: due,
        status: status
      }
    end)
  end

  defp room_json(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_total_cents: room.lodging_total_cents,
      deposit_due_cents: room.deposit_due_cents,
      status: Map.get(room, :status, "active")
    }
  end

  defp calculate_rooms(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging_total_cents = nights * room.nightly_rate_cents

      Map.merge(room, %{
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: calculate_room_deposit(lodging_total_cents, rate_plan),
        status: "active"
      })
    end)
  end

  defp calculate_room_deposit(lodging, "flexible"), do: round_percentage(lodging, 20, 100)
  defp calculate_room_deposit(lodging, "advance_purchase"), do: lodging

  defp policy_version_for_booking("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for_booking("flexible", booked_on) do
    if Date.compare(booked_on, @new_policy_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp group_policy_version(%Group{policy_version: version}) when version in @policy_versions,
    do: version

  defp group_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version_for_booking(rate_plan, booked_on)

  defp refundable_until(%Group{} = group),
    do: refundable_until(group_policy_version(group), group.arrival_on)

  defp refundable_until("advance-nonrefundable", _arrival_on), do: nil

  defp refundable_until(policy_version, arrival_on),
    do: arrival_on |> Date.add(-cancellation_window(policy_version)) |> Date.to_iso8601()

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30

  defp refundable?(group, occurred_on) do
    case refundable_until(group_policy_version(group), group.arrival_on) do
      nil -> false
      date -> Date.compare(occurred_on, Date.from_iso8601!(date)) != :gt
    end
  end

  defp group_cash_value(%Group{cash_paid_cents: cash}) when is_integer(cash), do: cash

  defp group_cash_value(%Group{deposit_paid_cents: deposit, credit_paid_cents: credit}),
    do: max(deposit - (credit || 0), 0)

  defp validate_stay(%Date{} = arrival, %Date{} = departure),
    do: if(Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, "invalid_stay"})

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
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
    |> case do
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
      {:error, _} -> :error
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
        _ -> {:error, "invalid_operation"}
      end
    else
      {:ok, "cash"}
    end
  end

  defp stale_revision(operation, %Group{revision: actual}) do
    if key_present?(operation, "expected_revision") and
         value(operation, "expected_revision") != actual,
       do: {:stale, actual},
       else: :ok
  end

  defp stale_result(operation_id, group_id, operation, actual) do
    rejected(operation_id, "stale_revision",
      group_id: group_id,
      expected_revision: value(operation, "expected_revision"),
      actual_revision: actual
    )
  end

  defp current_revision(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{revision: revision} -> revision
      nil -> nil
    end
  end

  defp round_percentage(amount, numerator, denominator),
    do: div(amount * numerator * 2 + denominator, denominator * 2)

  defp bonus_adjusted_value(amount), do: amount + round_percentage(amount, 10, 100)

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp value(_map, _key), do: nil

  defp key_present?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp key_present?(_map, _key), do: false

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))

  defp rejected(operation_id, code, fields \\ []),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))
end
