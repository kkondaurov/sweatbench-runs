defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashEntry,
    CashPayment,
    CashPaymentDisposition,
    CashRoomAllocation,
    CreditApplication,
    CreditLot,
    CreditLotContribution,
    FinanceReport,
    Group,
    Operation,
    Room
  }

  @rate_plans ["flexible", "advance_purchase"]

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, operation.result}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil -> {:error, :operation_not_found}
      %Operation{} = operation -> payment_statement(operation, payment_operation_id)
    end
  end

  def get_payment(_payment_operation_id), do: {:error, :operation_not_found}

  def guest_credit(guest_id, on \\ Date.utc_today())

  def guest_credit(guest_id, on) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    {:ok,
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
     }}
  end

  def guest_credit(_guest_id, _on), do: {:error, :guest_not_found}

  def ledger_totals(on \\ Date.utc_today()) do
    %{
      cash_held_cents: active_cash_held(),
      cash_refunded_cents: cash_total("cash_refund"),
      cash_retained_cents: cash_total("cash_retention"),
      cash_converted_to_credit_cents: cash_total("cash_credit_conversion"),
      cash_reduced_cents: cash_total("cash_reduction"),
      cash_charged_back_cents: cash_total("cash_chargeback"),
      credit_liability_cents: credit_liability(on),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  defp apply_operation(%{"operation_id" => operation_id} = operation)
       when is_binary(operation_id) and byte_size(operation_id) > 0 do
    case Repo.transaction(fn -> claim_or_replay_operation(operation, operation_id) end) do
      {:ok, result} -> result
      {:error, :concurrent_update} -> apply_operation(operation)
    end
  end

  defp apply_operation(operation), do: rejected(operation, "invalid_operation")

  defp claim_or_replay_operation(operation, operation_id) do
    attrs = %{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      submitted_payload: operation,
      result: %{}
    }

    case Repo.insert(Operation.changeset(%Operation{}, attrs)) do
      {:ok, stored_operation} ->
        result =
          case perform_operation(operation) do
            {:applied, result} -> result
            {:rejected, result} -> result
          end

        stored_operation
        |> Operation.changeset(%{result: result})
        |> Repo.update!()

        result

      {:error, changeset} ->
        replay_or_conflict(operation, operation_id, changeset)
    end
  end

  defp replay_or_conflict(operation, operation_id, changeset) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{submitted_payload: payload, result: result} when payload === operation ->
        result

      %Operation{} ->
        rejected(operation, "operation_id_conflict")

      nil ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp perform_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp perform_operation(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp perform_operation(%{"type" => "reschedule_group"} = operation),
    do: reschedule_group(operation)

  defp perform_operation(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp perform_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp perform_operation(%{"type" => "transfer_deposit"} = operation),
    do: transfer_deposit(operation)

  defp perform_operation(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp perform_operation(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp perform_operation(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp perform_operation(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp perform_operation(operation), do: {:rejected, rejected(operation, "invalid_operation")}

  defp start_finance_reporting(operation) do
    with {:ok, starts_on} <- reporting_date(operation),
         {:ok, _reporting} <-
           FinanceReport.start(Map.fetch!(operation, "operation_id"), starts_on) do
      {:applied, applied(operation, %{"starts_on" => Date.to_iso8601(starts_on)})}
    else
      {:error, :already_started} ->
        {:rejected, rejected(operation, "reporting_already_started")}

      {:error, "invalid_reporting_date"} ->
        {:rejected, rejected(operation, "invalid_reporting_date")}
    end
  end

  defp open_group(operation) do
    with {:ok, booked_on} <- validate_common(operation),
         {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, guest_id} <- identifier(operation, "guest_id"),
         {:ok, property_id} <- identifier(operation, "property_id"),
         {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms} <- rooms(operation, arrival_on, departure_on, rate_plan) do
      if Repo.exists?(from group in Group, where: group.group_id == ^group_id) do
        {:rejected, rejected(operation, "group_already_exists")}
      else
        lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
        deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_cents))

        attrs = %{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
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
          policy_version: policy_version(rate_plan, booked_on),
          revision: 1
        }

        case Repo.insert(Group.changeset(%Group{}, attrs)) do
          {:ok, group} ->
            Enum.each(rooms, fn room ->
              Repo.insert!(
                Room.changeset(%Room{}, %{
                  group_id: group.id,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents,
                  position: room.position,
                  status: "active",
                  lodging_total_cents: room.lodging_total_cents,
                  deposit_due_cents: room.deposit_cents,
                  cash_paid_cents: 0,
                  credit_paid_cents: 0
                })
              )
            end)

            {:applied,
             applied(operation, %{
               "group_id" => group.group_id,
               "deposit_due_cents" => deposit_due_cents,
               "revision" => group.revision
             })}

          {:error, _changeset} ->
            {:rejected, rejected(operation, "group_already_exists")}
        end
      end
    else
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- payment_amount(operation),
         :ok <- within_outstanding(amount_cents, group) do
      payment =
        Repo.insert!(
          CashPayment.changeset(%CashPayment{}, %{
            payment_operation_id: Map.fetch!(operation, "operation_id"),
            group_id: group.id,
            recorded_cents: amount_cents
          })
        )

      allocate_cash_to_rooms!(group, payment, amount_cents)
      finance_cash!(operation, occurred_on, "cash_received", group.property_id, amount_cents)
      group = refresh_group!(group, group.revision + 1)

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- arrival_after_operation(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)

      group =
        update_group!(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: group.revision + 1
        })

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "new_arrival_on" => Date.to_iso8601(new_arrival_on),
         "new_departure_on" => Date.to_iso8601(new_departure_on),
         "policy_version" => effective_policy_version(group),
         "refundable_until" => refundable_until(group),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, refund_method} <- refund_method(operation, group, occurred_on) do
      rooms = active_rooms(group)

      {refunded_cents, retained_cents, credit_issued_cents} =
        settle_rooms!(group, rooms, operation, occurred_on, refund_method)

      group = refresh_group!(group, group.revision + 1)

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, rooms} <- selected_active_rooms(operation, group),
         {:ok, refund_method} <- refund_method(operation, group, occurred_on) do
      {refunded_cents, retained_cents, credit_issued_cents} =
        settle_rooms!(group, rooms, operation, occurred_on, refund_method)

      group = refresh_group!(group, group.revision + 1)

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
         "refunded_cents" => refunded_cents,
         "retained_cents" => retained_cents,
         "credit_issued_cents" => credit_issued_cents,
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- identifier(operation, "group_id"),
         {:ok, group} <- existing_group(group_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- payment_amount(operation),
         :ok <- within_outstanding(amount_cents, group),
         {:ok, allocations} <- credit_allocations(group.guest_id, amount_cents, occurred_on) do
      Enum.each(allocations, fn {lot, amount} -> consume_credit_lot!(lot, amount) end)
      allocate_credit_to_rooms!(group, allocations)

      Enum.each(allocations, fn {lot, amount_cents} ->
        finance_credit!(
          operation,
          occurred_on,
          "credit_state",
          0,
          lot,
          -amount_cents,
          amount_cents
        )
      end)

      group = refresh_group!(group, group.revision + 1)

      {:applied,
       applied(operation, %{
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source_group_id} <- identifier(operation, "source_group_id"),
         {:ok, source_group} <- transfer_group(source_group_id),
         {:ok, destination_group_id} <- identifier(operation, "destination_group_id"),
         {:ok, destination_group} <- transfer_group(destination_group_id),
         :ok <- current_revision(operation, source_group),
         :ok <- current_revision(operation, destination_group, "destination_expected_revision"),
         {:ok, occurred_on} <- validate_common(operation),
         :ok <- valid_transfer_groups(source_group, destination_group),
         :ok <- active_transfer_group(source_group),
         :ok <- active_transfer_group(destination_group),
         {:ok, amount_cents} <- payment_amount(operation),
         held_cents when held_cents >= amount_cents <- held_funding(source_group),
         :ok <- transfer_within_outstanding(amount_cents, destination_group) do
      next_order = next_allocation_order()
      moved_allocations = remove_held_funding!(source_group, amount_cents)

      allocate_transferred_funding!(destination_group, moved_allocations, next_order)

      moved_cash_cents =
        moved_allocations
        |> Enum.filter(&(&1.kind == :cash))
        |> Enum.sum_by(& &1.amount_cents)

      finance_cash!(
        operation,
        occurred_on,
        "cash_transferred_out",
        source_group.property_id,
        moved_cash_cents
      )

      finance_cash!(
        operation,
        occurred_on,
        "cash_transferred_in",
        destination_group.property_id,
        moved_cash_cents
      )

      source_group = refresh_group!(source_group, source_group.revision + 1)

      destination_group =
        refresh_group!(destination_group, destination_group.revision + 1)

      {:applied,
       applied(operation, %{
         "source_group_id" => source_group.group_id,
         "destination_group_id" => destination_group.group_id,
         "amount_cents" => amount_cents,
         "source_outstanding_deposit_cents" => outstanding_deposit(source_group),
         "destination_outstanding_deposit_cents" => outstanding_deposit(destination_group),
         "source_revision" => source_group.revision,
         "destination_revision" => destination_group.revision
       })}
    else
      {:error, {:stale_revision, result}} ->
        {:rejected, result}

      {:error, {:group_not_found, group_id}} ->
        {:rejected, rejected(operation, "group_not_found", %{"group_id" => group_id})}

      {:error, {:group_not_active, group_id}} ->
        {:rejected, rejected(operation, "group_not_active", %{"group_id" => group_id})}

      {:error, code} ->
        {:rejected, rejected(operation, code)}

      _held_cents ->
        {:rejected, rejected(operation, "transfer_exceeds_held_funding")}
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment_operation_id} <- identifier(operation, "payment_operation_id"),
         {:ok, payment, group} <- reducible_payment(payment_operation_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         {:ok, amount_cents} <- payment_amount(operation),
         held_cents when held_cents > 0 <- held_cash(payment.id),
         :ok <- reduce_within_held(amount_cents, held_cents) do
      {changed_group_ids, held_cash_by_property} = remove_held_cash!(payment, amount_cents)

      Repo.insert!(
        CashPaymentDisposition.changeset(%CashPaymentDisposition{}, %{
          cash_payment_id: payment.id,
          disposition: "reduced",
          amount_cents: amount_cents
        })
      )

      insert_cash_entry!(group, "cash_reduction", amount_cents, occurred_on, payment)
      finance_cash_by_property!(operation, occurred_on, "cash_reduced", held_cash_by_property)

      group =
        refresh_affected_groups!(group, changed_group_ids)
        |> Map.fetch!(group.id)

      {:applied,
       applied(operation, %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => group.group_id,
         "amount_cents" => amount_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
      0 -> {:rejected, rejected(operation, "payment_not_reducible")}
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment_operation_id} <- identifier(operation, "payment_operation_id"),
         {:ok, payment, group} <- chargeable_payment(payment_operation_id),
         :ok <- current_revision(operation, group),
         {:ok, occurred_on} <- validate_common(operation),
         {charged_back_cents, changed_group_ids} when charged_back_cents > 0 <-
           charge_back_cash!(payment, group, occurred_on, operation),
         group <-
           refresh_affected_groups!(group, changed_group_ids)
           |> Map.fetch!(group.id) do
      {:applied,
       applied(operation, %{
         "payment_operation_id" => payment_operation_id,
         "group_id" => group.group_id,
         "charged_back_cents" => charged_back_cents,
         "outstanding_deposit_cents" => outstanding_deposit(group),
         "revision" => group.revision
       })}
    else
      {:error, {:stale_revision, result}} -> {:rejected, result}
      {:error, code} -> {:rejected, rejected(operation, code)}
      {0, _changed_group_ids} -> {:rejected, rejected(operation, "payment_not_chargeable")}
    end
  end

  defp validate_common(operation) do
    with {:ok, _operation_id} <- identifier(operation, "operation_id"),
         {:ok, occurred_on} <- required_date(operation, "occurred_on") do
      {:ok, occurred_on}
    end
  end

  defp identifier(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_date(operation, key) do
    case Map.fetch(operation, key) do
      :error -> {:error, "invalid_operation"}
      {:ok, nil} -> {:error, "invalid_operation"}
      {:ok, date} when is_binary(date) -> parse_date(date)
      {:ok, _value} -> {:error, "invalid_stay"}
    end
  end

  defp reporting_date(operation) do
    case Map.get(operation, "starts_on") do
      date when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed_date} -> {:ok, parsed_date}
          {:error, _reason} -> {:error, "invalid_reporting_date"}
        end

      _ ->
        {:error, "invalid_reporting_date"}
    end
  end

  defp parse_date(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed_date} -> {:ok, parsed_date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, "invalid_operation"}
      {:ok, rate_plan} when rate_plan in @rate_plans -> {:ok, rate_plan}
      {:ok, _rate_plan} -> {:error, "invalid_rate_plan"}
    end
  end

  defp rooms(operation, arrival_on, departure_on, rate_plan) do
    case Map.fetch(operation, "rooms") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {room, position},
                                                           {:ok, {valid_rooms, ids}} ->
          case room_details(room, position, arrival_on, departure_on, rate_plan, ids) do
            {:ok, valid_room, updated_ids} ->
              {:cont, {:ok, {[valid_room | valid_rooms], updated_ids}}}

            {:error, code} ->
              {:halt, {:error, code}}
          end
        end)
        |> case do
          {:ok, {valid_rooms, _ids}} -> {:ok, Enum.reverse(valid_rooms)}
          {:error, code} -> {:error, code}
        end

      {:ok, _rooms} ->
        {:error, "invalid_rooms"}
    end
  end

  defp room_details(room, position, arrival_on, departure_on, rate_plan, ids) when is_map(room) do
    with room_id when is_binary(room_id) and byte_size(room_id) > 0 <- Map.get(room, "room_id"),
         false <- MapSet.member?(ids, room_id),
         nightly_rate_cents when is_integer(nightly_rate_cents) and nightly_rate_cents >= 0 <-
           Map.get(room, "nightly_rate_cents") do
      lodging_total_cents = Date.diff(departure_on, arrival_on) * nightly_rate_cents

      deposit_cents =
        if rate_plan == "flexible" do
          round_half_up(lodging_total_cents * 20, 100)
        else
          lodging_total_cents
        end

      {:ok,
       %{
         room_id: room_id,
         nightly_rate_cents: nightly_rate_cents,
         lodging_total_cents: lodging_total_cents,
         deposit_cents: deposit_cents,
         position: position
       }, MapSet.put(ids, room_id)}
    else
      _ -> {:error, "invalid_rooms"}
    end
  end

  defp room_details(_room, _position, _arrival_on, _departure_on, _rate_plan, _ids),
    do: {:error, "invalid_rooms"}

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp existing_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, {:group_not_found, group_id}}
      group -> {:ok, group}
    end
  end

  defp current_revision(operation, group, revision_key \\ "expected_revision") do
    if Map.has_key?(operation, revision_key) and
         Map.get(operation, revision_key) != group.revision do
      {:error,
       {:stale_revision,
        rejected(operation, "stale_revision", %{
          "group_id" => group.group_id,
          "expected_revision" => Map.get(operation, revision_key),
          "actual_revision" => group.revision
        })}}
    else
      :ok
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(%Group{}), do: {:error, "group_not_active"}

  defp valid_transfer_groups(source_group, destination_group) do
    if source_group.id == destination_group.id or
         source_group.guest_id != destination_group.guest_id,
       do: {:error, "invalid_transfer"},
       else: :ok
  end

  defp active_transfer_group(%Group{status: "active"}), do: :ok

  defp active_transfer_group(%Group{} = group),
    do: {:error, {:group_not_active, group.group_id}}

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, "invalid_amount"}
    end
  end

  defp within_outstanding(amount_cents, group) do
    if amount_cents <= group.deposit_due_cents - group.deposit_paid_cents do
      :ok
    else
      {:error, "payment_exceeds_outstanding"}
    end
  end

  defp transfer_within_outstanding(amount_cents, group) do
    if amount_cents <= outstanding_deposit(group),
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp effective_policy_version(%Group{policy_version: policy_version})
       when is_binary(policy_version),
       do: policy_version

  defp effective_policy_version(%Group{} = group),
    do: policy_version(group.rate_plan, group.booked_on)

  defp refundable?(group, occurred_on) do
    case cancellation_window(group) do
      nil -> false
      window -> Date.compare(occurred_on, Date.add(group.arrival_on, -window)) != :gt
    end
  end

  defp cancellation_window(%Group{policy_version: "flex-14"}), do: 14
  defp cancellation_window(%Group{policy_version: "flex-30"}), do: 30
  defp cancellation_window(%Group{policy_version: "advance-nonrefundable"}), do: nil

  defp cancellation_window(%Group{} = group),
    do: cancellation_window(policy_version(group.rate_plan, group.booked_on))

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30
  defp cancellation_window("advance-nonrefundable"), do: nil

  defp refundable_until(group) do
    case cancellation_window(group) do
      nil -> nil
      window -> group.arrival_on |> Date.add(-window) |> Date.to_iso8601()
    end
  end

  defp refund_method(operation, group, occurred_on) do
    case Map.get(operation, "refund_method", "cash") do
      "cash" ->
        {:ok, "cash"}

      "hotel_credit" ->
        if refundable?(group, occurred_on),
          do: {:ok, "hotel_credit"},
          else: {:error, "refund_method_not_available"}

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp active_rooms(group) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group.id and room.status == "active",
        order_by: [asc: room.position]
    )
  end

  defp selected_active_rooms(operation, group) do
    case Map.get(operation, "room_ids") do
      room_ids when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &(is_binary(&1) and byte_size(&1) > 0)) and
             length(room_ids) == MapSet.size(MapSet.new(room_ids)) do
          rooms_by_id = Map.new(active_rooms(group), &{&1.room_id, &1})

          room_ids
          |> Enum.map(&Map.get(rooms_by_id, &1))
          |> case do
            rooms ->
              if Enum.all?(rooms, & &1) do
                {:ok, Enum.sort_by(rooms, & &1.position)}
              else
                {:error, "invalid_rooms"}
              end
          end
        else
          {:error, "invalid_rooms"}
        end

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp settle_rooms!(group, rooms, operation, occurred_on, refund_method) do
    refundable? = refundable?(group, occurred_on)
    allocations = cash_allocations_for_rooms(rooms)

    cash_total =
      Enum.sum(Enum.map(allocations, fn {allocation, _payment} -> allocation.amount_cents end))

    credit_lot =
      if refundable? and refund_method == "hotel_credit" and cash_total > 0 do
        Repo.insert!(
          CreditLot.changeset(%CreditLot{}, %{
            guest_id: group.guest_id,
            source_operation_id: Map.fetch!(operation, "operation_id"),
            remaining_cents: credit_value(cash_total),
            expires_on: Date.add(occurred_on, 366),
            unrecovered_clawback_cents: 0
          })
        )
      end

    case {refundable?, refund_method} do
      {true, "cash"} ->
        settle_cash_allocations!(group, allocations, "cash_refund", occurred_on)
        finance_cash!(operation, occurred_on, "cash_refunded", group.property_id, cash_total)

      {true, "hotel_credit"} ->
        create_credit_contributions!(credit_lot, allocations)

        settle_cash_allocations!(
          group,
          allocations,
          "cash_credit_conversion",
          occurred_on,
          credit_lot
        )

        finance_cash!(
          operation,
          occurred_on,
          "cash_converted_to_credit",
          group.property_id,
          cash_total
        )

        if credit_lot do
          finance_credit!(
            operation,
            occurred_on,
            "credit_issued",
            credit_lot.remaining_cents,
            credit_lot,
            credit_lot.remaining_cents
          )
        end

      {false, _} ->
        settle_cash_allocations!(group, allocations, "cash_retention", occurred_on)
        finance_cash!(operation, occurred_on, "cash_retained", group.property_id, cash_total)
    end

    settle_credit_applications!(rooms, refundable?, occurred_on, operation)

    Enum.each(rooms, fn room ->
      Repo.update_all(
        from(current_room in Room, where: current_room.id == ^room.id),
        set: [status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0]
      )
    end)

    credit_issued_cents = if credit_lot, do: credit_lot.remaining_cents, else: 0

    {if(refundable? and refund_method == "cash", do: cash_total, else: 0),
     if(refundable?, do: 0, else: cash_total), credit_issued_cents}
  end

  defp cash_allocations_for_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from allocation in CashRoomAllocation,
        left_join: payment in CashPayment,
        on: payment.id == allocation.cash_payment_id,
        where: allocation.room_id in ^room_ids,
        order_by: [asc: allocation.fill_order],
        select: {allocation, payment}
    )
  end

  defp settle_cash_allocations!(group, allocations, entry_type, occurred_on, credit_lot \\ nil) do
    disposition =
      case entry_type do
        "cash_refund" -> "refunded"
        "cash_retention" -> "retained"
        "cash_credit_conversion" -> "converted"
      end

    Enum.each(allocations, fn {allocation, payment} ->
      if payment do
        Repo.insert!(
          CashPaymentDisposition.changeset(%CashPaymentDisposition{}, %{
            cash_payment_id: payment.id,
            credit_lot_id: credit_lot && credit_lot.id,
            disposition: disposition,
            amount_cents: allocation.amount_cents
          })
        )
      end

      insert_cash_entry!(
        group,
        entry_type,
        allocation.amount_cents,
        occurred_on,
        payment,
        credit_lot
      )

      Repo.delete!(allocation)

      Repo.update_all(
        from(room in Room, where: room.id == ^allocation.room_id),
        inc: [cash_paid_cents: -allocation.amount_cents]
      )
    end)
  end

  defp create_credit_contributions!(nil, _allocations), do: :ok

  defp create_credit_contributions!(credit_lot, allocations) do
    {_principal, _order} =
      Enum.reduce(allocations, {0, 0}, fn {allocation, payment}, {prior_principal, order} ->
        principal = prior_principal + allocation.amount_cents

        Repo.insert!(
          CreditLotContribution.changeset(%CreditLotContribution{}, %{
            credit_lot_id: credit_lot.id,
            cash_payment_id: payment && payment.id,
            principal_cents: allocation.amount_cents,
            entitlement_cents: credit_value(principal) - credit_value(prior_principal),
            funding_order: allocation.fill_order + order
          })
        )

        {principal, order + 1}
      end)

    :ok
  end

  defp settle_credit_applications!(rooms, refundable?, occurred_on, operation) do
    room_ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from application in CreditApplication,
        where: application.room_id in ^room_ids
    )
    |> Enum.each(fn application ->
      lot = Repo.get!(CreditLot, application.credit_lot_id)

      if refundable? do
        %{
          available_cents: available_cents,
          absorbed_cents: absorbed_cents,
          expired_cents: expired_cents
        } =
          restore_credit_lot!(lot, application.amount_cents, occurred_on)

        finance_credit!(
          operation,
          occurred_on,
          "credit_state",
          0,
          lot,
          available_cents,
          -application.amount_cents
        )

        finance_credit!(operation, occurred_on, "credit_absorbed", absorbed_cents, lot)
        finance_credit!(operation, occurred_on, "credit_expired", expired_cents, lot)
      else
        finance_credit!(
          operation,
          occurred_on,
          "credit_consumed",
          application.amount_cents,
          lot,
          0,
          -application.amount_cents
        )
      end

      Repo.delete!(application)

      Repo.update_all(
        from(room in Room, where: room.id == ^application.room_id),
        inc: [credit_paid_cents: -application.amount_cents]
      )
    end)
  end

  defp restore_credit_lot!(lot, amount_cents, occurred_on) do
    absorbed_cents = min(lot.unrecovered_clawback_cents, amount_cents)
    restored_cents = amount_cents - absorbed_cents

    attrs = [unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents]

    attrs =
      if restored_cents > 0 and credit_available_on?(lot, occurred_on) do
        [{:remaining_cents, lot.remaining_cents + restored_cents} | attrs]
      else
        attrs
      end

    Repo.update_all(from(current_lot in CreditLot, where: current_lot.id == ^lot.id), set: attrs)

    available_cents = if credit_available_on?(lot, occurred_on), do: restored_cents, else: 0

    %{
      available_cents: available_cents,
      absorbed_cents: absorbed_cents,
      expired_cents: restored_cents - available_cents
    }
  end

  defp credit_value(principal_cents),
    do: principal_cents + round_half_up(principal_cents * 10, 100)

  defp credit_allocations(guest_id, amount_cents, occurred_on) do
    available_credit_lots(guest_id, occurred_on)
    |> Enum.reduce_while({amount_cents, []}, fn lot, {remaining, allocations} ->
      amount = min(remaining, lot.remaining_cents)
      updated_allocations = [{lot, amount} | allocations]

      if amount == remaining do
        {:halt, {0, updated_allocations}}
      else
        {:cont, {remaining - amount, updated_allocations}}
      end
    end)
    |> case do
      {0, allocations} -> {:ok, Enum.reverse(allocations)}
      {_remaining, _allocations} -> {:error, "insufficient_credit"}
    end
  end

  defp consume_credit_lot!(lot, amount_cents) do
    {updated_count, _} =
      Repo.update_all(
        from(current_lot in CreditLot,
          where: current_lot.id == ^lot.id and current_lot.remaining_cents >= ^amount_cents
        ),
        inc: [remaining_cents: -amount_cents]
      )

    if updated_count != 1, do: Repo.rollback(:concurrent_update)
  end

  defp allocate_cash_to_rooms!(group, payment, amount_cents) do
    next_fill_order = next_allocation_order()

    {0, _fill_order} =
      Enum.reduce(active_rooms(group), {amount_cents, next_fill_order}, fn room,
                                                                           {remaining, fill_order} ->
        amount =
          min(remaining, room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents)

        if amount > 0 do
          Repo.insert!(
            CashRoomAllocation.changeset(%CashRoomAllocation{}, %{
              room_id: room.id,
              cash_payment_id: payment.id,
              amount_cents: amount,
              fill_order: fill_order
            })
          )

          Repo.update_all(
            from(current_room in Room, where: current_room.id == ^room.id),
            inc: [cash_paid_cents: amount]
          )
        end

        {remaining - amount, fill_order + 1}
      end)
  end

  defp allocate_credit_to_rooms!(group, allocations) do
    {_rooms, _next_order} =
      Enum.reduce(allocations, {active_rooms(group), next_allocation_order()}, fn {lot,
                                                                                   amount_cents},
                                                                                  {rooms,
                                                                                   next_order} ->
        {0, rooms, next_order} =
          allocate_credit_lot_to_rooms!(group, lot, amount_cents, rooms, next_order)

        {rooms, next_order}
      end)

    :ok
  end

  defp allocate_credit_lot_to_rooms!(group, lot, amount_cents, rooms, next_order) do
    Enum.reduce(rooms, {amount_cents, [], next_order}, fn room,
                                                          {remaining, updated_rooms, order} ->
      amount =
        min(remaining, room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents)

      if amount > 0 do
        Repo.insert!(
          CreditApplication.changeset(%CreditApplication{}, %{
            group_id: group.id,
            room_id: room.id,
            credit_lot_id: lot.id,
            amount_cents: amount,
            allocation_order: order
          })
        )

        Repo.update_all(
          from(current_room in Room, where: current_room.id == ^room.id),
          inc: [credit_paid_cents: amount]
        )
      end

      {remaining - amount,
       [struct(room, credit_paid_cents: room.credit_paid_cents + amount) | updated_rooms],
       order + if(amount > 0, do: 1, else: 0)}
    end)
    |> then(fn {remaining, updated_rooms, order} ->
      {remaining, Enum.reverse(updated_rooms), order}
    end)
  end

  defp held_funding(group) do
    held_cash_for_group(group) + held_credit_for_group(group)
  end

  defp held_cash_for_group(group) do
    Repo.one(
      from allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.group_id == ^group.id and room.status == "active",
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp held_credit_for_group(group) do
    Repo.one(
      from application in CreditApplication,
        join: room in Room,
        on: room.id == application.room_id,
        where: room.group_id == ^group.id and room.status == "active",
        select: coalesce(sum(application.amount_cents), 0)
    )
  end

  defp remove_held_funding!(group, amount_cents) do
    {0, moved_allocations} =
      transfer_source_allocations(group)
      |> Enum.reduce({amount_cents, []}, fn allocation, {remaining, moved} ->
        amount = min(remaining, allocation.amount_cents)

        if amount > 0 do
          remove_transfer_source_allocation!(allocation, amount)
        end

        moved =
          if amount > 0,
            do: [
              %{kind: allocation.kind, source: allocation.source, amount_cents: amount} | moved
            ],
            else: moved

        {remaining - amount, moved}
      end)

    Enum.reverse(moved_allocations)
  end

  defp transfer_source_allocations(group) do
    cash_allocations =
      Repo.all(
        from allocation in CashRoomAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          left_join: payment in CashPayment,
          on: payment.id == allocation.cash_payment_id,
          where: room.group_id == ^group.id and room.status == "active",
          select: {allocation, payment}
      )
      |> Enum.map(fn {allocation, payment} ->
        %{
          kind: :cash,
          allocation: allocation,
          source: payment,
          amount_cents: allocation.amount_cents,
          order: allocation.fill_order
        }
      end)

    credit_allocations =
      Repo.all(
        from application in CreditApplication,
          join: room in Room,
          on: room.id == application.room_id,
          join: lot in CreditLot,
          on: lot.id == application.credit_lot_id,
          where: room.group_id == ^group.id and room.status == "active",
          select: {application, lot}
      )
      |> Enum.map(fn {application, lot} ->
        %{
          kind: :credit,
          allocation: application,
          source: lot,
          amount_cents: application.amount_cents,
          order: application.allocation_order
        }
      end)

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(& &1.order, :desc)
  end

  defp remove_transfer_source_allocation!(%{kind: :cash} = transfer_allocation, amount_cents) do
    allocation = transfer_allocation.allocation

    if amount_cents == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update_all(
        from(current in CashRoomAllocation, where: current.id == ^allocation.id),
        inc: [amount_cents: -amount_cents]
      )
    end

    if transfer_allocation.source do
      Repo.update_all(
        from(payment in CashPayment, where: payment.id == ^transfer_allocation.source.id),
        set: [has_transferred: true]
      )
    end

    Repo.update_all(
      from(room in Room, where: room.id == ^allocation.room_id),
      inc: [cash_paid_cents: -amount_cents]
    )
  end

  defp remove_transfer_source_allocation!(%{kind: :credit} = transfer_allocation, amount_cents) do
    application = transfer_allocation.allocation

    if amount_cents == application.amount_cents do
      Repo.delete!(application)
    else
      Repo.update_all(
        from(current in CreditApplication, where: current.id == ^application.id),
        inc: [amount_cents: -amount_cents]
      )
    end

    Repo.update_all(
      from(room in Room, where: room.id == ^application.room_id),
      inc: [credit_paid_cents: -amount_cents]
    )
  end

  defp allocate_transferred_funding!(group, moved_allocations, next_order) do
    {_rooms, _next_order} =
      Enum.reduce(moved_allocations, {active_rooms(group), next_order}, fn moved,
                                                                           {rooms, order} ->
        {rooms, order} = allocate_transferred_funding!(group, rooms, moved, order)
        {rooms, order}
      end)

    :ok
  end

  defp allocate_transferred_funding!(group, rooms, moved, next_order) do
    {0, updated_rooms, next_order} =
      Enum.reduce(rooms, {moved.amount_cents, [], next_order}, fn room,
                                                                  {remaining, updated, order} ->
        amount =
          min(remaining, room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents)

        if amount > 0 do
          create_transferred_allocation!(group, room, moved, amount, order)
        end

        updated_room =
          case moved.kind do
            :cash -> struct(room, cash_paid_cents: room.cash_paid_cents + amount)
            :credit -> struct(room, credit_paid_cents: room.credit_paid_cents + amount)
          end

        {remaining - amount, [updated_room | updated], order + if(amount > 0, do: 1, else: 0)}
      end)

    {Enum.reverse(updated_rooms), next_order}
  end

  defp create_transferred_allocation!(
         _group,
         room,
         %{kind: :cash, source: payment},
         amount,
         order
       ) do
    Repo.insert!(
      CashRoomAllocation.changeset(%CashRoomAllocation{}, %{
        room_id: room.id,
        cash_payment_id: payment && payment.id,
        amount_cents: amount,
        fill_order: order
      })
    )

    Repo.update_all(from(current in Room, where: current.id == ^room.id),
      inc: [cash_paid_cents: amount]
    )
  end

  defp create_transferred_allocation!(group, room, %{kind: :credit, source: lot}, amount, order) do
    Repo.insert!(
      CreditApplication.changeset(%CreditApplication{}, %{
        group_id: group.id,
        room_id: room.id,
        credit_lot_id: lot.id,
        amount_cents: amount,
        allocation_order: order
      })
    )

    Repo.update_all(from(current in Room, where: current.id == ^room.id),
      inc: [credit_paid_cents: amount]
    )
  end

  defp next_allocation_order do
    cash_order = Repo.aggregate(CashRoomAllocation, :max, :fill_order) || 0
    credit_order = Repo.aggregate(CreditApplication, :max, :allocation_order) || 0
    max(cash_order, credit_order) + 1
  end

  defp reducible_payment(payment_operation_id) do
    payment_for_action(payment_operation_id, "payment_not_reducible")
  end

  defp chargeable_payment(payment_operation_id) do
    payment_for_action(payment_operation_id, "payment_not_chargeable")
  end

  defp payment_for_action(payment_operation_id, rejection_code) do
    with %Operation{} = operation <- Repo.get_by(Operation, operation_id: payment_operation_id),
         true <-
           operation.operation_type == "record_cash_payment" and
             Map.get(operation.result, "status") == "applied",
         %CashPayment{} = payment <-
           Repo.get_by(CashPayment, payment_operation_id: payment_operation_id),
         %Group{} = group <- Repo.get(Group, payment.group_id) do
      {:ok, payment, group}
    else
      nil -> {:error, "operation_not_found"}
      false -> {:error, rejection_code}
    end
  end

  defp held_cash(payment_id) do
    Repo.one(
      from allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.cash_payment_id == ^payment_id and room.status == "active",
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp reduce_within_held(amount_cents, held_cents) when amount_cents <= held_cents, do: :ok
  defp reduce_within_held(_amount_cents, _held_cents), do: {:error, "reduction_exceeds_held_cash"}

  defp remove_held_cash!(payment, amount_cents) do
    {0, changed_group_ids, held_cash_by_property} =
      Repo.all(
        from allocation in CashRoomAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          join: group in Group,
          on: group.id == room.group_id,
          where: allocation.cash_payment_id == ^payment.id and room.status == "active",
          order_by: [desc: allocation.fill_order],
          select: {allocation, room.group_id, group.property_id}
      )
      |> Enum.reduce({amount_cents, MapSet.new(), %{}}, fn {allocation, group_id, property_id},
                                                           {remaining, changed_groups,
                                                            held_cash_by_property} ->
        amount = min(remaining, allocation.amount_cents)

        if amount > 0 do
          if amount == allocation.amount_cents do
            Repo.delete!(allocation)
          else
            Repo.update_all(
              from(current in CashRoomAllocation, where: current.id == ^allocation.id),
              inc: [amount_cents: -amount]
            )
          end

          Repo.update_all(
            from(room in Room, where: room.id == ^allocation.room_id),
            inc: [cash_paid_cents: -amount]
          )
        end

        changed_groups =
          if amount > 0, do: MapSet.put(changed_groups, group_id), else: changed_groups

        held_cash_by_property =
          if amount > 0,
            do: Map.update(held_cash_by_property, property_id, amount, &(&1 + amount)),
            else: held_cash_by_property

        {remaining - amount, changed_groups, held_cash_by_property}
      end)

    {changed_group_ids, held_cash_by_property}
  end

  defp charge_back_cash!(payment, group, occurred_on, operation) do
    held_cents = held_cash(payment.id)
    dispositions = uncharged_dispositions(payment.id)

    if held_cents == 0 and dispositions == [] do
      {0, MapSet.new()}
    else
      {changed_group_ids, held_cash_by_property} =
        if held_cents > 0 do
          remove_held_cash!(payment, held_cents)
        else
          {MapSet.new(), %{}}
        end

      finance_cash_by_property!(
        operation,
        occurred_on,
        "cash_charged_back",
        held_cash_by_property
      )

      settled_cash_by_property = settled_cash_by_property(payment, dispositions)

      if held_cents > 0 do
        Repo.insert!(
          CashPaymentDisposition.changeset(%CashPaymentDisposition{}, %{
            cash_payment_id: payment.id,
            disposition: "charged_back",
            amount_cents: held_cents
          })
        )

        insert_cash_entry!(group, "cash_chargeback", held_cents, occurred_on, payment)
      end

      dispositions
      |> Enum.filter(&(&1.disposition == "converted"))
      |> Enum.map(& &1.credit_lot_id)
      |> Enum.uniq()
      |> Enum.each(fn credit_lot_id ->
        revoke_credit_for_payment!(payment.id, credit_lot_id, operation, occurred_on)
      end)

      Enum.each(dispositions, fn disposition ->
        Repo.update_all(
          from(current in CashPaymentDisposition, where: current.id == ^disposition.id),
          set: [disposition: "charged_back"]
        )

        # Preserve the original settlement fact and write its current reclassification explicitly.
        insert_cash_entry!(
          group,
          cash_entry_type(disposition.disposition),
          -disposition.amount_cents,
          occurred_on,
          payment
        )

        insert_cash_entry!(
          group,
          "cash_chargeback",
          disposition.amount_cents,
          occurred_on,
          payment
        )
      end)

      Enum.each(settled_cash_by_property, fn {entry_type, property_amounts} ->
        Enum.each(property_amounts, fn {property_id, amount_cents} ->
          finance_cash!(operation, occurred_on, entry_type, property_id, -amount_cents)
          finance_cash!(operation, occurred_on, "cash_charged_back", property_id, amount_cents)
        end)
      end)

      {held_cents + Enum.sum(Enum.map(dispositions, & &1.amount_cents)), changed_group_ids}
    end
  end

  defp uncharged_dispositions(payment_id) do
    Repo.all(
      from disposition in CashPaymentDisposition,
        where:
          disposition.cash_payment_id == ^payment_id and
            disposition.disposition in ["refunded", "retained", "converted"]
    )
  end

  defp cash_entry_type("refunded"), do: "cash_refund"
  defp cash_entry_type("retained"), do: "cash_retention"
  defp cash_entry_type("converted"), do: "cash_credit_conversion"

  defp settled_cash_by_property(payment, dispositions) do
    entry_types =
      dispositions
      |> Enum.map(&cash_entry_type(&1.disposition))
      |> Enum.uniq()

    entries_by_type =
      Repo.all(
        from entry in CashEntry,
          join: group in Group,
          on: group.id == entry.group_id,
          where:
            entry.cash_payment_id == ^payment.id and entry.entry_type in ^entry_types and
              entry.amount_cents > 0,
          group_by: [entry.entry_type, group.property_id],
          select: {entry.entry_type, group.property_id, sum(entry.amount_cents)}
      )
      |> Enum.group_by(
        fn {entry_type, _property_id, _amount_cents} -> finance_cash_entry_type(entry_type) end,
        fn {_entry_type, property_id, amount_cents} -> {property_id, amount_cents} end
      )

    original_property_id = Repo.get!(Group, payment.group_id).property_id

    dispositions
    |> Enum.group_by(&finance_cash_entry_type(cash_entry_type(&1.disposition)), & &1.amount_cents)
    |> Enum.reduce(entries_by_type, fn {entry_type, amounts}, entries_by_type ->
      expected_cents = Enum.sum(amounts)
      actual_cents = entries_by_type |> Map.get(entry_type, []) |> Enum.sum_by(&elem(&1, 1))
      missing_cents = expected_cents - actual_cents

      if missing_cents > 0 do
        Map.update(
          entries_by_type,
          entry_type,
          [{original_property_id, missing_cents}],
          fn entries ->
            [{original_property_id, missing_cents} | entries]
          end
        )
      else
        entries_by_type
      end
    end)
  end

  defp finance_cash_entry_type("cash_refund"), do: "cash_refunded"
  defp finance_cash_entry_type("cash_retention"), do: "cash_retained"
  defp finance_cash_entry_type("cash_credit_conversion"), do: "cash_converted_to_credit"

  defp finance_cash!(operation, occurred_on, event_type, property_id, amount_cents) do
    FinanceReport.record_cash(
      Map.fetch!(operation, "operation_id"),
      occurred_on,
      event_type,
      property_id,
      amount_cents
    )
  end

  defp finance_cash_by_property!(operation, occurred_on, event_type, property_amounts) do
    Enum.each(property_amounts, fn {property_id, amount_cents} ->
      finance_cash!(operation, occurred_on, event_type, property_id, amount_cents)
    end)
  end

  defp finance_credit!(
         operation,
         occurred_on,
         event_type,
         amount_cents,
         credit_lot,
         available_delta_cents \\ 0,
         applied_delta_cents \\ 0
       ) do
    FinanceReport.record_credit(
      Map.fetch!(operation, "operation_id"),
      occurred_on,
      event_type,
      amount_cents,
      credit_lot,
      available_delta_cents,
      applied_delta_cents
    )
  end

  defp revoke_credit_for_payment!(_payment_id, nil, _operation, _occurred_on), do: :ok

  defp revoke_credit_for_payment!(payment_id, credit_lot_id, operation, occurred_on) do
    Repo.all(
      from contribution in CreditLotContribution,
        where:
          contribution.cash_payment_id == ^payment_id and
            contribution.credit_lot_id == ^credit_lot_id
    )
    |> Enum.each(fn contribution ->
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      revoked_from_available = min(lot.remaining_cents, contribution.entitlement_cents)
      unrecovered = contribution.entitlement_cents - revoked_from_available

      Repo.update_all(
        from(current_lot in CreditLot, where: current_lot.id == ^lot.id),
        set: [
          remaining_cents: lot.remaining_cents - revoked_from_available,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
        ]
      )

      finance_credit!(
        operation,
        occurred_on,
        "credit_revoked",
        revoked_from_available,
        lot,
        -revoked_from_available
      )
    end)
  end

  defp update_group!(group, attrs) do
    {updated_count, _} =
      Repo.update_all(
        from(current_group in Group,
          where: current_group.id == ^group.id and current_group.revision == ^group.revision
        ),
        set: Map.to_list(attrs)
      )

    if updated_count == 1 do
      struct(group, attrs)
    else
      Repo.rollback(:concurrent_update)
    end
  end

  defp refresh_group!(group, revision) do
    {room_count, lodging_total_cents, deposit_due_cents, cash_paid_cents, credit_paid_cents} =
      Repo.one(
        from room in Room,
          where: room.group_id == ^group.id and room.status == "active",
          select: {
            count(room.id),
            coalesce(sum(room.lodging_total_cents), 0),
            coalesce(sum(room.deposit_due_cents), 0),
            coalesce(sum(room.cash_paid_cents), 0),
            coalesce(sum(room.credit_paid_cents), 0)
          }
      )

    update_group!(group, %{
      status: if(room_count == 0, do: "cancelled", else: "active"),
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      revision: revision
    })
  end

  defp refresh_affected_groups!(addressed_group, changed_group_ids) do
    group_ids =
      changed_group_ids
      |> MapSet.put(addressed_group.id)
      |> MapSet.to_list()

    Repo.all(from group in Group, where: group.id in ^group_ids)
    |> Map.new(fn group ->
      {group.id, refresh_group!(group, group.revision + 1)}
    end)
  end

  defp insert_cash_entry!(group, entry_type, amount_cents, occurred_on, payment),
    do: insert_cash_entry!(group, entry_type, amount_cents, occurred_on, payment, nil)

  defp insert_cash_entry!(group, entry_type, amount_cents, occurred_on, payment, credit_lot) do
    Repo.insert!(
      CashEntry.changeset(%CashEntry{}, %{
        group_id: group.id,
        cash_payment_id: payment && payment.id,
        credit_lot_id: credit_lot && credit_lot.id,
        entry_type: entry_type,
        amount_cents: amount_cents,
        occurred_on: occurred_on
      })
    )
  end

  defp active_cash_held do
    Repo.one(
      from allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: room.status == "active",
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp cash_total(entry_type) do
    Repo.one(
      from entry in CashEntry,
        where: entry.entry_type == ^entry_type,
        select: coalesce(sum(entry.amount_cents), 0)
    )
  end

  defp available_credit_lots(guest_id, on) do
    Repo.all(
      from lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
  end

  defp credit_available_on?(lot, on), do: Date.compare(lot.expires_on, on) == :gt

  defp credit_liability(on) do
    available_cents =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on > ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from application in CreditApplication,
          join: room in Room,
          on: room.id == application.room_id,
          where: room.status == "active",
          select: coalesce(sum(application.amount_cents), 0)
      )

    available_cents + applied_cents
  end

  defp credit_shortfall do
    Repo.all(
      from lot in CreditLot,
        where: lot.unrecovered_clawback_cents > 0,
        select: {lot.id, lot.unrecovered_clawback_cents}
    )
    |> Enum.sum_by(fn {lot_id, unrecovered_cents} ->
      min(unrecovered_cents, active_applied_credit(lot_id))
    end)
  end

  defp active_applied_credit(credit_lot_id) do
    Repo.one(
      from application in CreditApplication,
        join: room in Room,
        on: room.id == application.room_id,
        where: application.credit_lot_id == ^credit_lot_id and room.status == "active",
        select: coalesce(sum(application.amount_cents), 0)
    )
  end

  defp payment_statement(operation, payment_operation_id) do
    if operation.operation_type == "record_cash_payment" and
         Map.get(operation.result, "status") == "applied" do
      case Repo.get_by(CashPayment, payment_operation_id: payment_operation_id) do
        nil ->
          {:error, :payment_not_reconcilable}

        payment ->
          group = Repo.get!(Group, payment.group_id)

          totals =
            Repo.all(
              from disposition in CashPaymentDisposition,
                where: disposition.cash_payment_id == ^payment.id,
                group_by: disposition.disposition,
                select: {disposition.disposition, sum(disposition.amount_cents)}
            )
            |> Map.new()

          statement = %{
            payment_operation_id: payment_operation_id,
            original_group_id: group.group_id,
            recorded_cents: payment.recorded_cents,
            held_cents: held_cash(payment.id),
            refunded_cents: Map.get(totals, "refunded", 0),
            retained_cents: Map.get(totals, "retained", 0),
            converted_to_credit_cents: Map.get(totals, "converted", 0),
            reduced_cents: Map.get(totals, "reduced", 0),
            charged_back_cents: Map.get(totals, "charged_back", 0)
          }

          statement =
            if payment.has_transferred do
              Map.put(statement, :held_by_group, held_cash_by_group(payment.id))
            else
              statement
            end

          {:ok, statement}
      end
    else
      {:error, :payment_not_reconcilable}
    end
  end

  defp held_cash_by_group(payment_id) do
    Repo.all(
      from allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.group_id,
        where: allocation.cash_payment_id == ^payment_id and room.status == "active",
        group_by: group.group_id,
        order_by: [asc: group.group_id],
        select: {group.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.id,
          order_by: [asc: room.position]
      )

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_total_cents: room.lodging_total_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      policy_version: effective_policy_version(group),
      refundable_until: refundable_until(group),
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0
  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp applied(operation, fields), do: Map.merge(base_result(operation, "applied"), fields)

  defp rejected(operation, code, fields \\ %{}),
    do: Map.merge(base_result(operation, "rejected"), Map.put(fields, "code", code))

  defp base_result(operation, status) when is_map(operation) do
    %{"status" => status}
    |> maybe_put_operation_id(Map.get(operation, "operation_id"))
  end

  defp base_result(_operation, status), do: %{"status" => status}

  defp maybe_put_operation_id(result, operation_id) when is_binary(operation_id),
    do: Map.put(result, "operation_id", operation_id)

  defp maybe_put_operation_id(result, _operation_id), do: result
end
