defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations and exposes the group's operational read models.

  Each operation and its durable outcome are committed in one transaction. A handled rejection
  records its outcome without changing domain state, so it cannot affect earlier or later
  operations in the same partner batch.
  """

  import Ecto.Query

  alias GroupStay.{
    CreditApplication,
    CreditLot,
    GroupReservation,
    GroupRoom,
    PartnerOperation,
    Repo,
    RoomFundingAllocation
  }

  @rate_plans ["flexible", "advance_purchase"]
  @max_conflict_retries 5
  @flex_30_start ~D[2027-01-01]
  @credit_available_days 365

  def submit_batch(operations) when is_list(operations),
    do: Enum.map(operations, &run_operation/1)

  def fetch_group(group_id) when is_binary(group_id) do
    case find_group(group_id) do
      nil -> :not_found
      group -> {:ok, serialize_group(Repo.preload(group, rooms: rooms_query()))}
    end
  end

  def fetch_operation(operation_id) when is_binary(operation_id) do
    case find_operation(operation_id) do
      nil -> :not_found
      operation -> {:ok, operation.result}
    end
  end

  def fetch_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case find_operation(payment_operation_id) do
      nil ->
        :not_found

      operation ->
        if applied_cash_payment?(operation) do
          {:ok, payment_statement(payment_operation_id, operation.result["group_id"])}
        else
          :not_reconcilable
        end
    end
  end

  def ledger_totals(on_date \\ utc_today()) do
    cash_totals =
      RoomFundingAllocation
      |> where([allocation], allocation.funding_type == "cash")
      |> group_by([allocation], allocation.status)
      |> select([allocation], {allocation.status, coalesce(sum(allocation.amount_cents), 0)})
      |> Repo.all()
      |> Enum.reduce(empty_ledger(), fn {status, amount_cents}, totals ->
        case status do
          "held" ->
            Map.update!(totals, "cash_held_cents", &(&1 + amount_cents))

          "refunded" ->
            Map.update!(totals, "cash_refunded_cents", &(&1 + amount_cents))

          "retained" ->
            Map.update!(totals, "cash_retained_cents", &(&1 + amount_cents))

          "converted" ->
            Map.update!(totals, "cash_converted_to_credit_cents", &(&1 + amount_cents))

          "reduced" ->
            Map.update!(totals, "cash_reduced_cents", &(&1 + amount_cents))

          "charged_back" ->
            Map.update!(totals, "cash_charged_back_cents", &(&1 + amount_cents))

          _ ->
            totals
        end
      end)

    cash_totals
    |> Map.put(
      "credit_liability_cents",
      available_credit_total(on_date) + active_applied_credit_total()
    )
    |> Map.put("credit_shortfall_cents", credit_shortfall_total())
  end

  def guest_credit(guest_id, on_date \\ utc_today()) when is_binary(guest_id) do
    lots =
      available_lots_query(on_date)
      |> where([lot], lot.guest_id == ^guest_id)
      |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
      |> Repo.all()
      |> Enum.map(fn lot ->
        %{
          "source_operation_id" => lot.source_operation_id,
          "remaining_cents" => lot.remaining_cents,
          "expires_on" => Date.to_iso8601(lot.expires_on)
        }
      end)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum(Enum.map(lots, & &1["remaining_cents"])),
      "lots" => lots
    }
  end

  defp run_operation(operation) do
    case operation_id(operation) do
      {:ok, operation_id} -> run_operation(operation, operation_id, @max_conflict_retries)
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp run_operation(operation, operation_id, retries_left) do
    case Repo.transaction(fn -> run_or_replay_operation(operation, operation_id) end) do
      {:ok, result} ->
        result

      {:error, {:stale_conflict, group_id, expected_revision}} ->
        remember_stale_conflict(
          operation,
          operation_id,
          group_id,
          expected_revision,
          retries_left
        )

      {:error, :retry} when retries_left > 0 ->
        run_operation(operation, operation_id, retries_left - 1)

      {:error, :retry} ->
        raise "Unable to serialize partner operation after #{@max_conflict_retries + 1} attempts"

      {:error, reason} ->
        raise "Unexpected partner operation transaction failure: #{inspect(reason)}"
    end
  end

  defp run_or_replay_operation(operation, operation_id) do
    case find_operation(operation_id) do
      %PartnerOperation{} = stored_operation ->
        replay_or_reject_conflict(stored_operation, operation)

      nil ->
        case apply_operation_in_savepoint(operation) do
          {:applied, result} ->
            remember_operation!(operation, operation_id, result)

          {:rejected, result} ->
            remember_operation!(operation, operation_id, result)

          {:stale_conflict, group_id, expected_revision} ->
            Repo.rollback({:stale_conflict, group_id, expected_revision})

          :retry ->
            Repo.rollback(:retry)
        end
    end
  end

  # Domain helpers can perform more than one write before reporting a handled rejection. Roll those
  # writes back while keeping the outer transaction available to store the rejection's durable
  # result. Applied operations and their records still commit together in that outer transaction.
  defp apply_operation_in_savepoint(operation) do
    Repo.query!("SAVEPOINT partner_operation_domain")
    outcome = apply_operation(operation)

    case outcome do
      {:rejected, _result} ->
        Repo.query!("ROLLBACK TO SAVEPOINT partner_operation_domain")
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")

      _ ->
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
    end

    outcome
  end

  defp remember_stale_conflict(operation, operation_id, group_id, expected_revision, retries_left) do
    case find_operation(operation_id) do
      %PartnerOperation{} = stored_operation ->
        replay_or_reject_conflict(stored_operation, operation)

      nil ->
        result =
          case find_group(group_id) do
            %GroupReservation{} = group -> stale_revision(operation, group, expected_revision)
            nil -> group_not_found(operation, group_id)
          end

        remember_result(operation, operation_id, result, retries_left)
    end
  end

  defp remember_result(operation, operation_id, result, retries_left) do
    case Repo.transaction(fn ->
           case find_operation(operation_id) do
             %PartnerOperation{} = stored_operation ->
               replay_or_reject_conflict(stored_operation, operation)

             nil ->
               remember_operation!(operation, operation_id, result)
           end
         end) do
      {:ok, remembered_result} ->
        remembered_result

      {:error, :retry} when retries_left > 0 ->
        remember_result(operation, operation_id, result, retries_left - 1)

      {:error, :retry} ->
        raise "Unable to serialize partner operation after #{@max_conflict_retries + 1} attempts"

      {:error, reason} ->
        raise "Unexpected partner operation transaction failure: #{inspect(reason)}"
    end
  end

  defp remember_operation!(operation, operation_id, result) do
    attrs = %{
      operation_id: operation_id,
      operation_type: submitted_type(operation),
      payload: operation,
      result: result
    }

    case Repo.insert(PartnerOperation.create_changeset(%PartnerOperation{}, attrs)) do
      {:ok, _stored_operation} ->
        result

      {:error, changeset} ->
        if unique_operation_id_error?(changeset) do
          Repo.rollback(:retry)
        else
          raise "Unable to persist partner operation: #{inspect(changeset.errors)}"
        end
    end
  end

  defp replay_or_reject_conflict(stored_operation, operation) do
    if stored_operation.payload == operation do
      stored_operation.result
    else
      rejected(operation, "operation_id_conflict")
    end
  end

  defp unique_operation_id_error?(changeset) do
    Keyword.has_key?(changeset.errors, :operation_id)
  end

  defp apply_operation(operation) do
    with {:ok, operation_id} <- operation_id(operation),
         {:ok, type} <- operation_type(operation) do
      case type do
        "open_group" -> open_group(operation, operation_id)
        "record_cash_payment" -> record_cash_payment(operation, operation_id)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id)
        "reschedule_group" -> reschedule_group(operation, operation_id)
        "cancel_group" -> cancel_group(operation, operation_id)
        "cancel_rooms" -> cancel_rooms(operation, operation_id)
        "reduce_cash_payment" -> reduce_cash_payment(operation, operation_id)
        "charge_back_payment" -> charge_back_payment(operation, operation_id)
        "transfer_deposit" -> transfer_deposit(operation, operation_id)
        _ -> {:rejected, rejected(operation, "invalid_operation")}
      end
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         nil <- find_group(group_id),
         {:ok, booked_on} <- date_field(operation, "occurred_on"),
         {:ok, guest_id} <- string_field(operation, "guest_id"),
         {:ok, property_id} <- string_field(operation, "property_id"),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, arrival_on} <- date_field(operation, "arrival_on"),
         {:ok, departure_on} <- date_field(operation, "departure_on"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rooms} <- rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)

      calculated_rooms =
        Enum.map(rooms, fn room ->
          lodging_cents = nights * room.nightly_rate_cents

          deposit_cents =
            case rate_plan do
              "flexible" -> round_percent(lodging_cents, 20)
              "advance_purchase" -> lodging_cents
            end

          Map.merge(room, %{lodging_cents: lodging_cents, deposit_cents: deposit_cents})
        end)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_for(rate_plan, booked_on),
        status: "active",
        lodging_total_cents: Enum.sum(Enum.map(calculated_rooms, & &1.lodging_cents)),
        deposit_due_cents: Enum.sum(Enum.map(calculated_rooms, & &1.deposit_cents)),
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1
      }

      case Repo.insert(GroupReservation.create_changeset(%GroupReservation{}, attrs)) do
        {:ok, group} ->
          insert_rooms!(group, calculated_rooms)

          {:applied,
           applied(operation_id, %{
             "group_id" => group.group_id,
             "deposit_due_cents" => group.deposit_due_cents,
             "revision" => group.revision
           })}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            {:rejected, rejected(operation, "group_already_exists", %{"group_id" => group_id})}
          else
            {:rejected, rejected(operation, "invalid_operation")}
          end
      end
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      %GroupReservation{} ->
        {:rejected,
         rejected(operation, "group_already_exists", %{"group_id" => operation["group_id"]})}

      {:error, "invalid_rate_plan"} ->
        {:rejected, rejected(operation, "invalid_rate_plan")}

      {:error, "invalid_stay"} ->
        {:rejected, rejected(operation, "invalid_stay")}

      {:error, "invalid_rooms"} ->
        {:rejected, rejected(operation, "invalid_rooms")}
    end
  end

  defp record_cash_payment(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, _occurred_on} <- date_field(operation, "occurred_on"),
         {:ok, amount_cents} <- positive_integer_field(operation, "amount_cents"),
         :ok <- active(group),
         :ok <- amount_within_outstanding(amount_cents, group) do
      case allocate_cash_to_rooms(group, operation_id, amount_cents) do
        :ok ->
          case update_group(group, %{cash_paid_cents: group.cash_paid_cents + amount_cents}) do
            :ok ->
              {:applied,
               applied(operation_id, %{
                 "group_id" => group.group_id,
                 "amount_cents" => amount_cents,
                 "outstanding_deposit_cents" => outstanding_deposit(group) - amount_cents,
                 "revision" => group.revision + 1
               })}

            :conflict ->
              conflict_result(operation, group)
          end

        :error ->
          {:rejected, rejected(operation, "invalid_operation")}
      end
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      nil ->
        {:rejected, group_not_found(operation, operation["group_id"])}

      {:error, result} when is_map(result) ->
        {:rejected, result}

      {:error, "invalid_amount"} ->
        {:rejected, rejected(operation, "invalid_amount")}

      {:error, "group_not_active"} ->
        {:rejected, rejected(operation, "group_not_active")}

      {:error, "payment_exceeds_outstanding"} ->
        {:rejected, rejected(operation, "payment_exceeds_outstanding")}
    end
  end

  defp apply_hotel_credit(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, occurred_on} <- date_field(operation, "occurred_on"),
         {:ok, amount_cents} <- positive_integer_field(operation, "amount_cents"),
         :ok <- active(group),
         :ok <- amount_within_outstanding(amount_cents, group) do
      case redeem_credit(group, operation_id, amount_cents, occurred_on) do
        :ok ->
          case update_group(group, %{credit_paid_cents: group.credit_paid_cents + amount_cents}) do
            :ok ->
              {:applied,
               applied(operation_id, %{
                 "group_id" => group.group_id,
                 "amount_cents" => amount_cents,
                 "outstanding_deposit_cents" => outstanding_deposit(group) - amount_cents,
                 "revision" => group.revision + 1
               })}

            :conflict ->
              conflict_result(operation, group)
          end

        :insufficient_credit ->
          {:rejected, rejected(operation, "insufficient_credit")}

        :conflict ->
          conflict_result(operation, group)

        :error ->
          {:rejected, rejected(operation, "invalid_operation")}
      end
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      nil ->
        {:rejected, group_not_found(operation, operation["group_id"])}

      {:error, result} when is_map(result) ->
        {:rejected, result}

      {:error, "invalid_amount"} ->
        {:rejected, rejected(operation, "invalid_amount")}

      {:error, "group_not_active"} ->
        {:rejected, rejected(operation, "group_not_active")}

      {:error, "payment_exceeds_outstanding"} ->
        {:rejected, rejected(operation, "payment_exceeds_outstanding")}
    end
  end

  defp reschedule_group(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, occurred_on} <- date_field(operation, "occurred_on"),
         {:ok, new_arrival_on} <- date_field(operation, "new_arrival_on"),
         :ok <- new_arrival_after_operation(new_arrival_on, occurred_on),
         :ok <- active(group) do
      new_departure_on = Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))
      updated_group = %{group | arrival_on: new_arrival_on, departure_on: new_departure_on}

      case update_group(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on}) do
        :ok ->
          {:applied,
           applied(operation_id, %{
             "group_id" => group.group_id,
             "new_arrival_on" => Date.to_iso8601(new_arrival_on),
             "new_departure_on" => Date.to_iso8601(new_departure_on),
             "policy_version" => policy_version(updated_group),
             "refundable_until" => refundable_until_string(updated_group),
             "revision" => group.revision + 1
           })}

        :conflict ->
          conflict_result(operation, group)
      end
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
      nil -> {:rejected, group_not_found(operation, operation["group_id"])}
      {:error, result} when is_map(result) -> {:rejected, result}
      {:error, "invalid_stay"} -> {:rejected, rejected(operation, "invalid_stay")}
      {:error, "group_not_active"} -> {:rejected, rejected(operation, "group_not_active")}
    end
  end

  defp cancel_group(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, occurred_on} <- date_field(operation, "occurred_on"),
         :ok <- active(group),
         {:ok, refund_method} <- refund_method(operation) do
      settle_rooms_operation(
        operation,
        operation_id,
        group,
        active_rooms(group),
        occurred_on,
        refund_method
      )
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
      nil -> {:rejected, group_not_found(operation, operation["group_id"])}
      {:error, result} when is_map(result) -> {:rejected, result}
      {:error, "group_not_active"} -> {:rejected, rejected(operation, "group_not_active")}
      {:error, "invalid_refund_method"} -> {:rejected, rejected(operation, "invalid_operation")}
    end
  end

  defp redeem_credit(group, operation_id, amount_cents, occurred_on) do
    lots =
      available_lots_query(occurred_on)
      |> where([lot], lot.guest_id == ^group.guest_id)
      |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
      |> Repo.all()

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      :insufficient_credit
    else
      lots
      |> Enum.reduce_while({:ok, amount_cents}, fn lot, {:ok, remaining_to_apply} ->
        if remaining_to_apply == 0 do
          {:halt, {:ok, 0}}
        else
          applied_cents = min(lot.remaining_cents, remaining_to_apply)

          case deduct_lot_and_record_application(group, operation_id, lot, applied_cents) do
            :ok -> {:cont, {:ok, remaining_to_apply - applied_cents}}
            result -> {:halt, result}
          end
        end
      end)
      |> case do
        {:ok, 0} -> :ok
        :conflict -> :conflict
        _ -> :error
      end
    end
  end

  defp deduct_lot_and_record_application(group, operation_id, lot, amount_cents) do
    case Repo.update_all(
           from(row in CreditLot,
             where: row.id == ^lot.id and row.remaining_cents == ^lot.remaining_cents
           ),
           set: [remaining_cents: lot.remaining_cents - amount_cents, updated_at: now()]
         ) do
      {1, _} ->
        case Repo.insert(
               CreditApplication.create_changeset(%CreditApplication{}, %{
                 group_reservation_id: group.id,
                 credit_lot_id: lot.id,
                 amount_cents: amount_cents,
                 operation_id: operation_id
               })
             ) do
          {:ok, application} -> allocate_credit_application_to_rooms(group, application)
          {:error, _changeset} -> :error
        end

      {0, _} ->
        :conflict
    end
  end

  defp cancel_rooms(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, occurred_on} <- date_field(operation, "occurred_on"),
         :ok <- active(group),
         {:ok, room_ids} <- cancellation_room_ids(operation),
         {:ok, rooms} <- selected_active_rooms(group, room_ids),
         {:ok, refund_method} <- refund_method(operation) do
      settle_rooms_operation(operation, operation_id, group, rooms, occurred_on, refund_method)
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
      nil -> {:rejected, group_not_found(operation, operation["group_id"])}
      {:error, result} when is_map(result) -> {:rejected, result}
      {:error, "group_not_active"} -> {:rejected, rejected(operation, "group_not_active")}
      {:error, "invalid_rooms"} -> {:rejected, rejected(operation, "invalid_rooms")}
      {:error, "invalid_refund_method"} -> {:rejected, rejected(operation, "invalid_operation")}
    end
  end

  defp transfer_deposit(operation, operation_id) do
    with {:ok, source_group_id} <- string_field(operation, "source_group_id"),
         {:ok, source_group} <- transfer_group(operation, source_group_id),
         {:ok, destination_group_id} <- string_field(operation, "destination_group_id"),
         {:ok, destination_group} <- transfer_group(operation, destination_group_id),
         :ok <- revision_matches(operation, source_group),
         :ok <- destination_revision_matches(operation, destination_group),
         :ok <- valid_transfer_groups(source_group, destination_group),
         :ok <- transfer_active(source_group),
         :ok <- transfer_active(destination_group),
         {:ok, amount_cents} <- positive_integer_field(operation, "amount_cents"),
         allocations <- held_group_funding_allocations(source_group.id),
         :ok <- amount_within_held_funding(amount_cents, allocations),
         :ok <- amount_within_destination_outstanding(amount_cents, destination_group),
         :ok <-
           move_held_funding(
             destination_group,
             allocations,
             amount_cents
           ),
         {:ok, source_totals} <- active_room_totals(source_group.id),
         {:ok, destination_totals} <- active_room_totals(destination_group.id),
         :ok <-
           update_transfer_groups(
             operation,
             source_group,
             source_totals,
             destination_group,
             destination_totals
           ) do
      {:applied,
       applied(operation_id, %{
         "source_group_id" => source_group.group_id,
         "destination_group_id" => destination_group.group_id,
         "amount_cents" => amount_cents,
         "source_outstanding_deposit_cents" => outstanding_from_totals(source_totals),
         "destination_outstanding_deposit_cents" => outstanding_from_totals(destination_totals),
         "source_revision" => source_group.revision + 1,
         "destination_revision" => destination_group.revision + 1
       })}
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      {:error, result} when is_map(result) ->
        {:rejected, result}

      {:error, "invalid_transfer"} ->
        {:rejected, rejected(operation, "invalid_transfer")}

      {:error, "group_not_active", group} ->
        {:rejected, rejected(operation, "group_not_active", %{"group_id" => group.group_id})}

      {:error, "invalid_amount"} ->
        {:rejected, rejected(operation, "invalid_amount")}

      {:error, "transfer_exceeds_held_funding"} ->
        {:rejected, rejected(operation, "transfer_exceeds_held_funding")}

      {:error, "transfer_exceeds_outstanding"} ->
        {:rejected, rejected(operation, "transfer_exceeds_outstanding")}

      {:stale_conflict, _group_id, _expected_revision} = stale_conflict ->
        stale_conflict

      :conflict ->
        :retry

      :retry ->
        :retry
    end
  end

  defp settle_rooms_operation(operation, operation_id, group, rooms, occurred_on, refund_method) do
    refundable? = refundable_cancellation?(group, occurred_on)

    if refund_method == "hotel_credit" and not refundable? do
      {:rejected, rejected(operation, "refund_method_not_available")}
    else
      cash_allocations = held_cash_allocations(rooms)
      credit_allocations = held_credit_allocations(rooms)
      cash_total = Enum.sum_by(cash_allocations, & &1.amount_cents)

      cash_status =
        cond do
          refundable? and refund_method == "cash" -> "refunded"
          refundable? -> "converted"
          true -> "retained"
        end

      credit_value_cents = if cash_status == "converted", do: credit_value(cash_total), else: 0

      with {:ok, credit_lot} <-
             maybe_issue_credit_lot(group, occurred_on, credit_value_cents, operation_id),
           :ok <- settle_cash_allocations(cash_allocations, cash_status, credit_lot),
           :ok <- settle_credit_allocations(credit_allocations, occurred_on, refundable?),
           :ok <- cancel_room_rows(rooms),
           {:ok, totals} <- active_room_totals(group.id),
           :ok <- update_group(group, group_update_attrs(totals)) do
        fields = %{
          "group_id" => group.group_id,
          "refunded_cents" => if(cash_status == "refunded", do: cash_total, else: 0),
          "retained_cents" => if(cash_status == "retained", do: cash_total, else: 0),
          "credit_issued_cents" => credit_value_cents,
          "revision" => group.revision + 1
        }

        fields =
          if operation["type"] == "cancel_rooms" do
            Map.put(fields, "cancelled_room_ids", Enum.map(rooms, & &1.room_id))
          else
            fields
          end

        {:applied, applied(operation_id, fields)}
      else
        :conflict -> conflict_result(operation, group)
        _ -> {:rejected, rejected(operation, "invalid_operation")}
      end
    end
  end

  defp reduce_cash_payment(operation, operation_id) do
    with {:ok, payment_operation_id} <- string_field(operation, "payment_operation_id"),
         %PartnerOperation{} = payment <- find_operation(payment_operation_id),
         {:ok, original_group} <- cash_payment_group(payment, "payment_not_reducible"),
         :ok <- revision_matches(operation, original_group),
         {:ok, amount_cents} <- positive_integer_field(operation, "amount_cents"),
         allocations <- held_cash_payment_allocations(payment_operation_id),
         :ok <- reducible_payment(allocations),
         :ok <- amount_within_held_cash(amount_cents, allocations),
         {:ok, changed_group_ids} <- reduce_held_cash_allocations(allocations, amount_cents),
         {:ok, totals_by_group_id} <-
           update_affected_payment_groups(operation, original_group, changed_group_ids) do
      {:applied,
       applied(operation_id, %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => original_group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" =>
           totals_by_group_id |> Map.fetch!(original_group.id) |> outstanding_from_totals(),
         "revision" => original_group.revision + 1
       })}
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      nil ->
        {:rejected, rejected(operation, "operation_not_found")}

      {:error, result} when is_map(result) ->
        {:rejected, result}

      {:error, "payment_not_reducible"} ->
        {:rejected, rejected(operation, "payment_not_reducible")}

      {:error, "reduction_exceeds_held_cash"} ->
        {:rejected, rejected(operation, "reduction_exceeds_held_cash")}

      {:error, "invalid_amount"} ->
        {:rejected, rejected(operation, "invalid_amount")}

      {:stale_conflict, _group_id, _expected_revision} = stale_conflict ->
        stale_conflict

      :conflict ->
        :retry

      :retry ->
        :retry
    end
  end

  defp charge_back_payment(operation, operation_id) do
    with {:ok, payment_operation_id} <- string_field(operation, "payment_operation_id"),
         %PartnerOperation{} = payment <- find_operation(payment_operation_id),
         {:ok, original_group} <- cash_payment_group(payment, "payment_not_chargeable"),
         :ok <- revision_matches(operation, original_group),
         allocations <- chargeable_cash_payment_allocations(payment_operation_id),
         :ok <- chargeable_payment(allocations),
         :ok <- revoke_credit_entitlements(allocations),
         :ok <- charge_back_cash_allocations(allocations),
         {:ok, totals_by_group_id} <-
           update_affected_payment_groups(
             operation,
             original_group,
             Enum.map(allocations, & &1.group_reservation_id)
           ) do
      {:applied,
       applied(operation_id, %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => original_group.group_id,
         "charged_back_cents" => Enum.sum_by(allocations, & &1.amount_cents),
         "outstanding_deposit_cents" =>
           totals_by_group_id |> Map.fetch!(original_group.id) |> outstanding_from_totals(),
         "revision" => original_group.revision + 1
       })}
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      nil ->
        {:rejected, rejected(operation, "operation_not_found")}

      {:error, result} when is_map(result) ->
        {:rejected, result}

      {:error, "payment_not_chargeable"} ->
        {:rejected, rejected(operation, "payment_not_chargeable")}

      {:stale_conflict, _group_id, _expected_revision} = stale_conflict ->
        stale_conflict

      :conflict ->
        :retry

      :retry ->
        :retry
    end
  end

  defp active_rooms(group) do
    Repo.all(
      from(room in GroupRoom,
        where: room.group_reservation_id == ^group.id and room.status == "active",
        order_by: [asc: room.position]
      )
    )
  end

  defp cancellation_room_ids(%{"room_ids" => room_ids})
       when is_list(room_ids) and room_ids != [] do
    if Enum.all?(room_ids, &is_binary/1) and Enum.uniq(room_ids) == room_ids,
      do: {:ok, room_ids},
      else: {:error, "invalid_rooms"}
  end

  defp cancellation_room_ids(_operation), do: {:error, "invalid_rooms"}

  defp selected_active_rooms(group, room_ids) do
    rooms = active_rooms(group)
    by_id = Map.new(rooms, &{&1.room_id, &1})

    if Enum.all?(room_ids, &Map.has_key?(by_id, &1)) do
      {:ok, Enum.filter(rooms, &(&1.room_id in room_ids))}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp transfer_group(operation, group_id) do
    case find_group(group_id) do
      %GroupReservation{} = group -> {:ok, group}
      nil -> {:error, group_not_found(operation, group_id)}
    end
  end

  defp valid_transfer_groups(source_group, destination_group) do
    if source_group.id == destination_group.id or
         source_group.guest_id != destination_group.guest_id,
       do: {:error, "invalid_transfer"},
       else: :ok
  end

  defp transfer_active(%GroupReservation{status: "active"}), do: :ok
  defp transfer_active(group), do: {:error, "group_not_active", group}

  defp destination_revision_matches(operation, group) do
    case Map.fetch(operation, "destination_expected_revision") do
      :error -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:error, stale_revision(operation, group, expected_revision)}
    end
  end

  defp held_group_funding_allocations(group_id) do
    Repo.all(
      from(allocation in RoomFundingAllocation,
        join: room in GroupRoom,
        on: room.id == allocation.group_room_id,
        where:
          allocation.group_reservation_id == ^group_id and allocation.status == "held" and
            allocation.funding_type in ["cash", "credit"] and room.status == "active",
        order_by: [desc: allocation.id]
      )
    )
  end

  defp amount_within_held_funding(amount_cents, allocations) do
    if amount_cents <= Enum.sum_by(allocations, & &1.amount_cents),
      do: :ok,
      else: {:error, "transfer_exceeds_held_funding"}
  end

  defp amount_within_destination_outstanding(amount_cents, group) do
    if amount_cents <= outstanding_deposit(group),
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp move_held_funding(destination_group, allocations, amount_cents) do
    with {:ok, portions} <- transfer_portions(allocations, amount_cents),
         :ok <- remove_transferred_funding(portions),
         :ok <- allocate_transferred_funding(destination_group, portions) do
      :ok
    end
  end

  defp transfer_portions(allocations, amount_cents) do
    allocations
    |> Enum.reduce_while({[], amount_cents}, fn allocation, {portions, remaining} ->
      moved_cents = min(allocation.amount_cents, remaining)
      portions = [{allocation, moved_cents} | portions]

      if moved_cents == remaining,
        do: {:halt, {portions, 0}},
        else: {:cont, {portions, remaining - moved_cents}}
    end)
    |> case do
      {portions, 0} -> {:ok, Enum.reverse(portions)}
      _ -> :error
    end
  end

  defp remove_transferred_funding(portions) do
    Enum.reduce_while(portions, :ok, fn {allocation, amount_cents}, :ok ->
      with :ok <- decrement_room_funding(allocation, amount_cents),
           :ok <- remove_or_split_transferred_allocation(allocation, amount_cents) do
        {:cont, :ok}
      else
        :conflict -> {:halt, :conflict}
        _ -> {:halt, :error}
      end
    end)
  end

  defp decrement_room_funding(%{group_room_id: nil}, _amount_cents), do: :error

  defp decrement_room_funding(allocation, amount_cents) do
    field = funding_field(allocation.funding_type)

    case Repo.update_all(
           from(room in GroupRoom,
             where:
               room.id == ^allocation.group_room_id and room.status == "active" and
                 field(room, ^field) >= ^amount_cents
           ),
           inc: [{field, -amount_cents}],
           set: [updated_at: now()]
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp remove_or_split_transferred_allocation(allocation, amount_cents)
       when amount_cents == allocation.amount_cents do
    case Repo.delete_all(
           from(row in RoomFundingAllocation,
             where:
               row.id == ^allocation.id and row.status == "held" and
                 row.amount_cents == ^allocation.amount_cents
           )
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp remove_or_split_transferred_allocation(allocation, amount_cents) do
    case Repo.update_all(
           from(row in RoomFundingAllocation,
             where:
               row.id == ^allocation.id and row.status == "held" and
                 row.amount_cents == ^allocation.amount_cents
           ),
           set: [amount_cents: allocation.amount_cents - amount_cents, updated_at: now()]
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp allocate_transferred_funding(destination_group, portions) do
    portions
    |> Enum.reduce_while({:ok, active_rooms(destination_group)}, fn {allocation, amount_cents},
                                                                    {:ok, rooms} ->
      case allocate_transferred_portion(destination_group, rooms, allocation, amount_cents) do
        {:ok, updated_rooms} -> {:cont, {:ok, updated_rooms}}
        :conflict -> {:halt, :conflict}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, _rooms} -> :ok
      result -> result
    end
  end

  defp allocate_transferred_portion(destination_group, rooms, allocation, amount_cents) do
    rooms
    |> Enum.reduce_while({[], amount_cents}, fn room, {updated_rooms, remaining} ->
      allocation_cents = min(room_outstanding(room), remaining)

      cond do
        remaining == 0 ->
          {:cont, {[room | updated_rooms], 0}}

        allocation_cents == 0 ->
          {:cont, {[room | updated_rooms], remaining}}

        true ->
          case add_transferred_funding(destination_group, room, allocation, allocation_cents) do
            :ok ->
              field = funding_field(allocation.funding_type)
              updated_room = Map.update!(room, field, &(&1 + allocation_cents))
              {:cont, {[updated_room | updated_rooms], remaining - allocation_cents}}

            :conflict ->
              {:halt, :conflict}

            :error ->
              {:halt, :error}
          end
      end
    end)
    |> case do
      {updated_rooms, 0} -> {:ok, Enum.reverse(updated_rooms)}
      :conflict -> :conflict
      :error -> :error
      _ -> :error
    end
  end

  defp add_transferred_funding(destination_group, room, allocation, amount_cents) do
    field = funding_field(allocation.funding_type)

    with :ok <- increment_room_funding(room, field, amount_cents),
         {:ok, _allocation} <-
           insert_allocation(%{
             group_reservation_id: destination_group.id,
             group_room_id: room.id,
             credit_lot_id: allocation.credit_lot_id,
             credit_application_id: allocation.credit_application_id,
             funding_type: allocation.funding_type,
             payment_operation_id: allocation.payment_operation_id,
             status: "held",
             amount_cents: amount_cents,
             credit_entitlement_cents: allocation.credit_entitlement_cents,
             has_been_transferred: true
           }) do
      :ok
    else
      :conflict -> :conflict
      _ -> :error
    end
  end

  defp funding_field("cash"), do: :cash_paid_cents
  defp funding_field("credit"), do: :credit_paid_cents

  defp update_transfer_groups(
         operation,
         source_group,
         source_totals,
         destination_group,
         destination_totals
       ) do
    case update_group(source_group, group_update_attrs(source_totals)) do
      :ok ->
        case update_group(destination_group, group_update_attrs(destination_totals)) do
          :ok ->
            :ok

          :conflict ->
            transfer_update_conflict(
              operation,
              destination_group,
              "destination_expected_revision"
            )
        end

      :conflict ->
        transfer_update_conflict(operation, source_group, "expected_revision")
    end
  end

  defp transfer_update_conflict(operation, group, revision_field) do
    if Map.has_key?(operation, revision_field),
      do: {:stale_conflict, group.group_id, operation[revision_field]},
      else: :retry
  end

  defp allocate_cash_to_rooms(group, operation_id, amount_cents) do
    allocate_to_rooms(group, amount_cents, fn room, allocation_cents ->
      with :ok <- increment_room_funding(room, :cash_paid_cents, allocation_cents),
           {:ok, _allocation} <-
             insert_allocation(%{
               group_reservation_id: group.id,
               group_room_id: room.id,
               funding_type: "cash",
               payment_operation_id: operation_id,
               status: "held",
               amount_cents: allocation_cents,
               credit_entitlement_cents: 0
             }) do
        :ok
      else
        _ -> :error
      end
    end)
  end

  defp allocate_credit_application_to_rooms(group, application) do
    allocate_to_rooms(group, application.amount_cents, fn room, allocation_cents ->
      with :ok <- increment_room_funding(room, :credit_paid_cents, allocation_cents),
           {:ok, _allocation} <-
             insert_allocation(%{
               group_reservation_id: group.id,
               group_room_id: room.id,
               credit_lot_id: application.credit_lot_id,
               credit_application_id: application.id,
               funding_type: "credit",
               status: "held",
               amount_cents: allocation_cents,
               credit_entitlement_cents: 0
             }) do
        :ok
      else
        _ -> :error
      end
    end)
  end

  defp allocate_to_rooms(group, amount_cents, callback) do
    group
    |> active_rooms()
    |> Enum.reduce_while(amount_cents, fn room, remaining ->
      allocation_cents = min(room_outstanding(room), remaining)

      cond do
        remaining == 0 -> {:halt, {:ok, 0}}
        allocation_cents == 0 -> {:cont, remaining}
        callback.(room, allocation_cents) == :ok -> {:cont, remaining - allocation_cents}
        true -> {:halt, :error}
      end
    end)
    |> case do
      0 -> :ok
      {:ok, 0} -> :ok
      _ -> :error
    end
  end

  defp increment_room_funding(room, field, amount_cents) do
    current = Map.fetch!(room, field)

    case Repo.update_all(
           from(row in GroupRoom, where: row.id == ^room.id and row.status == "active"),
           set: [{field, current + amount_cents}, {:updated_at, now()}]
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp insert_allocation(attrs) do
    Repo.insert(RoomFundingAllocation.create_changeset(%RoomFundingAllocation{}, attrs))
  end

  defp held_cash_allocations(rooms), do: held_allocations(rooms, "cash")
  defp held_credit_allocations(rooms), do: held_allocations(rooms, "credit")

  defp held_allocations([], _type), do: []

  defp held_allocations(rooms, type) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from(allocation in RoomFundingAllocation,
        join: room in GroupRoom,
        on: room.id == allocation.group_room_id,
        where:
          allocation.group_room_id in ^room_ids and allocation.funding_type == ^type and
            allocation.status == "held",
        order_by: [asc: room.position, asc: allocation.id]
      )
    )
  end

  defp maybe_issue_credit_lot(_group, _occurred_on, 0, _operation_id), do: {:ok, nil}

  defp maybe_issue_credit_lot(group, occurred_on, credit_issued_cents, operation_id) do
    expires_on = Date.add(occurred_on, @credit_available_days + 1)

    Repo.insert(
      CreditLot.create_changeset(%CreditLot{}, %{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        expires_on: expires_on,
        unrecovered_clawback_cents: 0
      })
    )
  end

  defp settle_cash_allocations(allocations, status, credit_lot) do
    entitlements =
      if status == "converted" do
        cash_conversion_entitlements(allocations)
      else
        %{}
      end

    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      attrs =
        [status: status, updated_at: now()]
        |> maybe_set_credit_lot(credit_lot)
        |> Keyword.put(:credit_entitlement_cents, Map.get(entitlements, allocation.id, 0))

      case Repo.update_all(
             from(row in RoomFundingAllocation,
               where: row.id == ^allocation.id and row.status == "held"
             ),
             set: attrs
           ) do
        {1, _} -> {:cont, :ok}
        {0, _} -> {:halt, :conflict}
      end
    end)
  end

  defp maybe_set_credit_lot(attrs, nil), do: attrs

  defp maybe_set_credit_lot(attrs, credit_lot),
    do: Keyword.put(attrs, :credit_lot_id, credit_lot.id)

  defp cash_conversion_entitlements(allocations) do
    allocations
    |> Enum.with_index()
    |> Enum.group_by(fn {allocation, _index} -> allocation.payment_operation_id end)
    |> Enum.sort_by(fn {payment_operation_id, indexed_rows} ->
      if payment_operation_id do
        {1, indexed_rows |> Enum.map(&elem(&1, 1)) |> Enum.min()}
      else
        {0, 0}
      end
    end)
    |> Enum.reduce({0, %{}}, fn {_payment_operation_id, indexed_rows}, {running, entitlements} ->
      rows = Enum.map(indexed_rows, &elem(&1, 0))
      principal = Enum.sum_by(rows, & &1.amount_cents)
      entitlement = credit_value(running + principal) - credit_value(running)
      first_allocation = hd(rows)
      {running + principal, Map.put(entitlements, first_allocation.id, entitlement)}
    end)
    |> elem(1)
  end

  defp settle_credit_allocations([], _occurred_on, _refundable?), do: :ok

  defp settle_credit_allocations(allocations, occurred_on, true) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.reduce_while(:ok, fn {credit_lot_id, rows}, :ok ->
      amount_cents = Enum.sum_by(rows, & &1.amount_cents)

      case restore_credit_to_lot(credit_lot_id, amount_cents, occurred_on) do
        :ok -> {:cont, :ok}
        result -> {:halt, result}
      end
    end)
    |> case do
      :ok -> reclassify_credit_allocations(allocations, "restored")
      result -> result
    end
  end

  defp settle_credit_allocations(allocations, _occurred_on, false),
    do: reclassify_credit_allocations(allocations, "consumed")

  defp restore_credit_to_lot(nil, _amount_cents, _occurred_on), do: :error

  defp restore_credit_to_lot(credit_lot_id, amount_cents, occurred_on) do
    case Repo.get(CreditLot, credit_lot_id) do
      nil ->
        :error

      lot ->
        absorbed = min(lot.unrecovered_clawback_cents, amount_cents)
        excess = amount_cents - absorbed
        available_excess = if expired_on?(lot, occurred_on), do: 0, else: excess

        case Repo.update_all(
               from(row in CreditLot,
                 where:
                   row.id == ^lot.id and row.remaining_cents == ^lot.remaining_cents and
                     row.unrecovered_clawback_cents == ^lot.unrecovered_clawback_cents
               ),
               set: [
                 remaining_cents: lot.remaining_cents + available_excess,
                 unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
                 updated_at: now()
               ]
             ) do
          {1, _} -> :ok
          {0, _} -> :conflict
        end
    end
  end

  defp reclassify_credit_allocations(allocations, status) do
    ids = Enum.map(allocations, & &1.id)

    case Repo.update_all(
           from(row in RoomFundingAllocation, where: row.id in ^ids and row.status == "held"),
           set: [status: status, updated_at: now()]
         ) do
      {count, _} when count == length(ids) -> :ok
      _ -> :conflict
    end
  end

  defp cancel_room_rows(rooms) do
    ids = Enum.map(rooms, & &1.id)

    case Repo.update_all(
           from(room in GroupRoom, where: room.id in ^ids and room.status == "active"),
           set: [status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0, updated_at: now()]
         ) do
      {count, _} when count == length(ids) -> :ok
      _ -> :conflict
    end
  end

  defp held_cash_payment_allocations(payment_operation_id) do
    Repo.all(
      from(allocation in RoomFundingAllocation,
        join: room in GroupRoom,
        on: room.id == allocation.group_room_id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.funding_type == "cash" and allocation.status == "held",
        where: room.status == "active",
        order_by: [desc: allocation.id]
      )
    )
  end

  defp chargeable_cash_payment_allocations(payment_operation_id) do
    Repo.all(
      from(allocation in RoomFundingAllocation,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.funding_type == "cash" and
            allocation.status in ["held", "refunded", "retained", "converted"],
        order_by: [desc: allocation.id]
      )
    )
  end

  defp reducible_payment([]), do: {:error, "payment_not_reducible"}
  defp reducible_payment(_allocations), do: :ok
  defp chargeable_payment([]), do: {:error, "payment_not_chargeable"}
  defp chargeable_payment(_allocations), do: :ok

  defp amount_within_held_cash(amount_cents, allocations) do
    if amount_cents <= Enum.sum_by(allocations, & &1.amount_cents),
      do: :ok,
      else: {:error, "reduction_exceeds_held_cash"}
  end

  defp reduce_held_cash_allocations(allocations, amount_cents) do
    allocations
    |> Enum.reduce_while({[], amount_cents}, fn allocation, {group_ids, remaining} ->
      taken = min(allocation.amount_cents, remaining)

      case reduce_cash_allocation(allocation, taken) do
        :ok when taken == remaining -> {:halt, {[allocation.group_reservation_id | group_ids], 0}}
        :ok -> {:cont, {[allocation.group_reservation_id | group_ids], remaining - taken}}
        result -> {:halt, result}
      end
    end)
    |> case do
      {group_ids, 0} -> {:ok, Enum.uniq(group_ids)}
      result -> result
    end
  end

  defp reduce_cash_allocation(allocation, amount_cents) do
    with :ok <- decrement_room_cash(allocation.group_room_id, amount_cents),
         :ok <- split_or_reclassify_cash(allocation, amount_cents, "reduced") do
      :ok
    end
  end

  defp decrement_room_cash(nil, _amount_cents), do: :error

  defp decrement_room_cash(room_id, amount_cents) do
    case Repo.update_all(
           from(room in GroupRoom,
             where:
               room.id == ^room_id and room.status == "active" and
                 room.cash_paid_cents >= ^amount_cents
           ),
           inc: [cash_paid_cents: -amount_cents],
           set: [updated_at: now()]
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp split_or_reclassify_cash(allocation, amount_cents, status)
       when amount_cents == allocation.amount_cents do
    case Repo.update_all(
           from(row in RoomFundingAllocation,
             where: row.id == ^allocation.id and row.status == "held"
           ),
           set: [status: status, updated_at: now()]
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp split_or_reclassify_cash(allocation, amount_cents, status) do
    with {1, _} <-
           Repo.update_all(
             from(row in RoomFundingAllocation,
               where:
                 row.id == ^allocation.id and row.status == "held" and
                   row.amount_cents == ^allocation.amount_cents
             ),
             set: [amount_cents: allocation.amount_cents - amount_cents, updated_at: now()]
           ),
         {:ok, _row} <-
           insert_allocation(%{
             group_reservation_id: allocation.group_reservation_id,
             group_room_id: allocation.group_room_id,
             funding_type: "cash",
             payment_operation_id: allocation.payment_operation_id,
             status: status,
             amount_cents: amount_cents,
             credit_entitlement_cents: 0,
             has_been_transferred: allocation.has_been_transferred
           }) do
      :ok
    else
      {0, _} -> :conflict
      _ -> :error
    end
  end

  defp revoke_credit_entitlements(allocations) do
    allocations
    |> Enum.filter(&(&1.status == "converted" and &1.credit_lot_id))
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.reduce_while(:ok, fn {credit_lot_id, rows}, :ok ->
      entitlement = Enum.sum_by(rows, & &1.credit_entitlement_cents)

      case revoke_lot_entitlement(credit_lot_id, entitlement) do
        :ok -> {:cont, :ok}
        result -> {:halt, result}
      end
    end)
  end

  defp revoke_lot_entitlement(_credit_lot_id, 0), do: :ok

  defp revoke_lot_entitlement(credit_lot_id, entitlement) do
    case Repo.get(CreditLot, credit_lot_id) do
      nil ->
        :error

      lot ->
        revoked_available = min(lot.remaining_cents, entitlement)
        unrecovered = entitlement - revoked_available

        case Repo.update_all(
               from(row in CreditLot,
                 where:
                   row.id == ^lot.id and row.remaining_cents == ^lot.remaining_cents and
                     row.unrecovered_clawback_cents == ^lot.unrecovered_clawback_cents
               ),
               set: [
                 remaining_cents: lot.remaining_cents - revoked_available,
                 unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered,
                 updated_at: now()
               ]
             ) do
          {1, _} -> :ok
          {0, _} -> :conflict
        end
    end
  end

  defp charge_back_cash_allocations(allocations) do
    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      with :ok <- maybe_decrement_held_cash(allocation),
           {1, _} <-
             Repo.update_all(
               from(row in RoomFundingAllocation,
                 where:
                   row.id == ^allocation.id and
                     row.status in ["held", "refunded", "retained", "converted"]
               ),
               set: [status: "charged_back", updated_at: now()]
             ) do
        {:cont, :ok}
      else
        :conflict -> {:halt, :conflict}
        {0, _} -> {:halt, :conflict}
        _ -> {:halt, :error}
      end
    end)
  end

  defp maybe_decrement_held_cash(%{
         status: "held",
         group_room_id: room_id,
         amount_cents: amount_cents
       }),
       do: decrement_room_cash(room_id, amount_cents)

  defp maybe_decrement_held_cash(_allocation), do: :ok

  defp cash_payment_group(payment, rejection_code) do
    if applied_cash_payment?(payment) do
      case find_group(payment.result["group_id"]) do
        %GroupReservation{} = group -> {:ok, group}
        nil -> {:error, rejection_code}
      end
    else
      {:error, rejection_code}
    end
  end

  defp applied_cash_payment?(operation) do
    operation.operation_type == "record_cash_payment" and operation.result["status"] == "applied" and
      is_binary(operation.result["group_id"])
  end

  defp update_affected_payment_groups(operation, original_group, changed_group_ids) do
    group_ids = [original_group.id | changed_group_ids] |> Enum.uniq()

    groups_by_id =
      Repo.all(from(group in GroupReservation, where: group.id in ^group_ids))
      |> Map.new(&{&1.id, &1})

    groups = [
      original_group | Enum.reject(Map.values(groups_by_id), &(&1.id == original_group.id))
    ]

    if map_size(groups_by_id) != length(group_ids) do
      :error
    else
      groups
      |> Enum.reduce_while({:ok, %{}}, fn group, {:ok, totals_by_group_id} ->
        with {:ok, totals} <- active_room_totals(group.id) do
          case update_group(group, group_update_attrs(totals)) do
            :ok -> {:cont, {:ok, Map.put(totals_by_group_id, group.id, totals)}}
            :conflict -> {:halt, payment_group_update_conflict(operation, original_group, group)}
          end
        end
      end)
    end
  end

  defp payment_group_update_conflict(operation, original_group, group) do
    if group.id == original_group.id,
      do: conflict_result(operation, original_group),
      else: :retry
  end

  defp active_room_totals(group_id) do
    {count, lodging, due, cash, credit} =
      Repo.one(
        from(room in GroupRoom,
          where: room.group_reservation_id == ^group_id and room.status == "active",
          select: {
            count(room.id),
            coalesce(sum(room.lodging_total_cents), 0),
            coalesce(sum(room.deposit_due_cents), 0),
            coalesce(sum(room.cash_paid_cents), 0),
            coalesce(sum(room.credit_paid_cents), 0)
          }
        )
      )

    {:ok,
     %{
       active_room_count: count,
       lodging_total_cents: lodging,
       deposit_due_cents: due,
       cash_paid_cents: cash,
       credit_paid_cents: credit
     }}
  end

  defp group_update_attrs(totals) do
    totals
    |> Map.take([:lodging_total_cents, :deposit_due_cents, :cash_paid_cents, :credit_paid_cents])
    |> Map.put(:status, if(totals.active_room_count == 0, do: "cancelled", else: "active"))
  end

  defp room_outstanding(room),
    do: max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

  defp outstanding_from_totals(totals),
    do: max(totals.deposit_due_cents - totals.cash_paid_cents - totals.credit_paid_cents, 0)

  defp conflict_result(operation, group) do
    if Map.has_key?(operation, "expected_revision") do
      {:stale_conflict, group.group_id, operation["expected_revision"]}
    else
      :retry
    end
  end

  defp update_group(group, attrs) do
    updates = Map.to_list(attrs) ++ [revision: group.revision + 1, updated_at: now()]

    case Repo.update_all(
           from(group_row in GroupReservation,
             where: group_row.id == ^group.id and group_row.revision == ^group.revision
           ),
           set: updates
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp find_group(group_id),
    do: Repo.one(from(group in GroupReservation, where: group.group_id == ^group_id))

  defp find_operation(operation_id),
    do:
      Repo.one(
        from(operation in PartnerOperation, where: operation.operation_id == ^operation_id)
      )

  defp rooms_query, do: from(room in GroupRoom, order_by: [asc: room.position])

  defp insert_rooms!(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(
        GroupRoom.create_changeset(%GroupRoom{}, %{
          group_reservation_id: group.id,
          position: position,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: "active",
          lodging_total_cents: room.lodging_cents,
          deposit_due_cents: room.deposit_cents,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      )
    end)
  end

  defp operation_id(%{"operation_id" => operation_id}) when is_binary(operation_id),
    do: {:ok, operation_id}

  defp operation_id(_operation), do: :error
  defp operation_type(%{"type" => type}) when is_binary(type), do: {:ok, type}
  defp operation_type(_operation), do: :error

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  defp string_field(%{} = operation, field) do
    case operation do
      %{^field => value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp string_field(_operation, _field), do: :error

  defp date_field(operation, field) do
    with {:ok, value} <- string_field(operation, field),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp positive_integer_field(%{} = operation, field) do
    case operation do
      %{^field => value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp rate_plan(%{"rate_plan" => rate_plan}) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp rate_plan(_operation), do: {:error, "invalid_rate_plan"}

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_refund_method"}
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp new_arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp rooms(%{"rooms" => rooms}) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.reduce_while({:ok, []}, fn room, {:ok, parsed_rooms} ->
      case room(room) do
        {:ok, parsed_room} -> {:cont, {:ok, [parsed_room | parsed_rooms]}}
        :error -> {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, parsed_rooms} ->
        parsed_rooms = Enum.reverse(parsed_rooms)

        if parsed_rooms |> Enum.map(& &1.room_id) |> Enum.uniq() |> length() ==
             length(parsed_rooms) do
          {:ok, parsed_rooms}
        else
          {:error, "invalid_rooms"}
        end

      error ->
        error
    end
  end

  defp rooms(_operation), do: {:error, "invalid_rooms"}

  defp room(%{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents})
       when is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 do
    {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}}
  end

  defp room(_room), do: :error

  defp revision_matches(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:error, stale_revision(operation, group, expected_revision)}
    end
  end

  defp active(%GroupReservation{status: "active"}), do: :ok
  defp active(_group), do: {:error, "group_not_active"}

  defp amount_within_outstanding(amount_cents, group) do
    if amount_cents <= outstanding_deposit(group),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version(%GroupReservation{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp policy_version(group), do: policy_for(group.rate_plan, group.booked_on)

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable_until_string(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp refundable_cancellation?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
  end

  defp credit_value(cash_paid_cents), do: cash_paid_cents + round_percent(cash_paid_cents, 10)
  defp expired_on?(lot, on_date), do: Date.compare(lot.expires_on, on_date) != :gt
  defp round_percent(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)

  defp outstanding_deposit(%GroupReservation{status: "cancelled"}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.cash_paid_cents - group.credit_paid_cents, 0)

  defp serialize_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until_string(group),
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents,
            "status" => room.status,
            "lodging_total_cents" => room.lodging_total_cents,
            "deposit_due_cents" => room.deposit_due_cents,
            "cash_paid_cents" => room.cash_paid_cents,
            "credit_paid_cents" => room.credit_paid_cents
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "deposit_paid_cents" => group.cash_paid_cents + group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp empty_ledger do
    %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0,
      "cash_converted_to_credit_cents" => 0,
      "cash_reduced_cents" => 0,
      "cash_charged_back_cents" => 0,
      "credit_liability_cents" => 0,
      "credit_shortfall_cents" => 0
    }
  end

  defp available_lots_query(on_date) do
    from(lot in CreditLot, where: lot.remaining_cents > 0 and lot.expires_on > ^on_date)
  end

  defp available_credit_total(on_date) do
    Repo.one(
      from(lot in available_lots_query(on_date), select: coalesce(sum(lot.remaining_cents), 0))
    )
  end

  defp active_applied_credit_total do
    Repo.one(
      from(allocation in RoomFundingAllocation,
        join: room in GroupRoom,
        on: room.id == allocation.group_room_id,
        where:
          allocation.funding_type == "credit" and allocation.status == "held" and
            room.status == "active",
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  defp credit_shortfall_total do
    CreditLot
    |> join(:left, [lot], allocation in RoomFundingAllocation,
      on:
        allocation.credit_lot_id == lot.id and allocation.funding_type == "credit" and
          allocation.status == "held"
    )
    |> join(:left, [lot, allocation], room in GroupRoom,
      on: room.id == allocation.group_room_id and room.status == "active"
    )
    |> group_by([lot], [lot.id, lot.unrecovered_clawback_cents])
    |> select(
      [lot, allocation, room],
      fragment(
        "MIN(?, COALESCE(SUM(CASE WHEN ? IS NULL THEN 0 ELSE ? END), 0))",
        lot.unrecovered_clawback_cents,
        room.id,
        allocation.amount_cents
      )
    )
    |> Repo.all()
    |> Enum.sum()
  end

  defp payment_statement(payment_operation_id, group_id) do
    dispositions =
      Repo.all(
        from(allocation in RoomFundingAllocation,
          where:
            allocation.funding_type == "cash" and
              allocation.payment_operation_id == ^payment_operation_id,
          group_by: allocation.status,
          select: {allocation.status, coalesce(sum(allocation.amount_cents), 0)}
        )
      )
      |> Map.new()

    held = Map.get(dispositions, "held", 0)
    refunded = Map.get(dispositions, "refunded", 0)
    retained = Map.get(dispositions, "retained", 0)
    converted = Map.get(dispositions, "converted", 0)
    reduced = Map.get(dispositions, "reduced", 0)
    charged_back = Map.get(dispositions, "charged_back", 0)

    statement = %{
      "payment_operation_id" => payment_operation_id,
      "original_group_id" => group_id,
      "recorded_cents" => held + refunded + retained + converted + reduced + charged_back,
      "held_cents" => held,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "converted_to_credit_cents" => converted,
      "reduced_cents" => reduced,
      "charged_back_cents" => charged_back
    }

    if payment_participated_in_transfer?(payment_operation_id) do
      Map.put(statement, "held_by_group", held_cash_by_group(payment_operation_id))
    else
      statement
    end
  end

  defp payment_participated_in_transfer?(payment_operation_id) do
    Repo.exists?(
      from(allocation in RoomFundingAllocation,
        where:
          allocation.funding_type == "cash" and
            allocation.payment_operation_id == ^payment_operation_id and
            allocation.has_been_transferred == true
      )
    )
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from(allocation in RoomFundingAllocation,
        join: group in GroupReservation,
        on: group.id == allocation.group_reservation_id,
        where:
          allocation.funding_type == "cash" and allocation.status == "held" and
            allocation.payment_operation_id == ^payment_operation_id,
        group_by: group.group_id,
        order_by: [asc: group.group_id],
        select: {group.group_id, coalesce(sum(allocation.amount_cents), 0)}
      )
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp utc_today, do: DateTime.utc_now() |> DateTime.to_date()
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp applied(operation_id, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

  defp group_not_found(operation, group_id),
    do: rejected(operation, "group_not_found", %{"group_id" => group_id})

  defp stale_revision(operation, group, expected_revision) do
    rejected(operation, "stale_revision", %{
      "group_id" => group.group_id,
      "expected_revision" => expected_revision,
      "actual_revision" => group.revision
    })
  end

  defp rejected(operation, code, fields \\ %{}) do
    operation_id =
      case operation do
        %{"operation_id" => value} when is_binary(value) -> %{"operation_id" => value}
        _ -> %{}
      end

    operation_id
    |> Map.merge(%{"status" => "rejected", "code" => code})
    |> Map.merge(fields)
  end
end
