defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CashPaymentDisposition,
    CreditApplication,
    CreditLot,
    CreditLotContribution,
    Group,
    PartnerOperation,
    Repo,
    Room
  }

  @open_fields [
    "group_id",
    "guest_id",
    "property_id",
    "occurred_on",
    "arrival_on",
    "departure_on",
    "rate_plan",
    "rooms"
  ]

  @doc "Processes a partner batch in order, isolating each operation's changes."
  def process_batch(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> preload_rooms(group)
    end
  end

  def get_group(_group_id), do: nil

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_operation_result(_operation_id), do: nil

  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      %PartnerOperation{operation_type: "record_cash_payment", result: %{"status" => "applied"}} ->
        case Repo.get_by(CashPaymentDisposition, payment_operation_id: payment_operation_id) do
          nil -> :not_reconcilable
          disposition -> {:ok, payment_data(disposition)}
        end

      _operation ->
        :not_reconcilable
    end
  end

  def get_payment(_payment_operation_id), do: :not_found

  def group_data(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => policy_version(group),
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "revision" => group.revision,
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
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => group.cash_paid_cents,
      "credit_paid_cents" => group.credit_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  def reporting_date(%{"on" => on}) do
    case parse_date(on) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def reporting_date(_params), do: {:ok, Date.utc_today()}

  def ledger(on \\ Date.utc_today()) do
    %{
      "cash_held_cents" => total(:cash_paid_cents, status: "active"),
      "cash_refunded_cents" => total(:cash_refunded_cents),
      "cash_retained_cents" => total(:cash_retained_cents),
      "cash_converted_to_credit_cents" => total(:cash_converted_to_credit_cents),
      "cash_reduced_cents" => total(:cash_reduced_cents),
      "cash_charged_back_cents" => total(:cash_charged_back_cents),
      "credit_liability_cents" => available_credit_total(on) + applied_credit_total(),
      "credit_shortfall_cents" => credit_shortfall_total()
    }
  end

  def guest_credit(guest_id, on) when is_binary(guest_id) and is_struct(on, Date) do
    lots = available_lots(guest_id, on)

    %{
      "guest_id" => guest_id,
      "available_cents" => Enum.sum_by(lots, & &1.remaining_cents),
      "lots" =>
        Enum.map(lots, fn lot ->
          %{
            "source_operation_id" => lot.source_operation_id,
            "remaining_cents" => lot.remaining_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    if is_binary(Map.get(operation, "operation_id")) do
      process_durable_operation(operation)
    else
      rejection(operation, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejection(%{}, "invalid_operation")

  defp process_durable_operation(operation) do
    case Repo.transaction(fn ->
           case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
             nil -> remember_new_operation(operation)
             remembered -> replay_or_reject_conflict(remembered, operation)
           end
         end) do
      {:ok, result} -> result
      {:error, :retry} -> process_durable_operation(operation)
    end
  end

  defp remember_new_operation(operation) do
    attrs = %{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      payload: operation,
      result: %{}
    }

    case Repo.insert(PartnerOperation.changeset(%PartnerOperation{}, attrs)) do
      {:ok, remembered} ->
        process_and_remember(operation, remembered)

      {:error, changeset} ->
        if unique_operation_id_conflict?(changeset) do
          Repo.rollback(:retry)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp replay_or_reject_conflict(remembered, operation) do
    if remembered.payload === operation do
      remembered.result
    else
      rejection(operation, "operation_id_conflict")
    end
  end

  defp process_and_remember(operation, remembered) do
    case process_new_operation(operation) do
      {:ok, result} ->
        persist_operation_result(remembered, result)

      {:error, code, fields} ->
        persist_operation_result(remembered, rejection(operation, code, fields))

      {:retry} ->
        Repo.rollback(:retry)
    end
  end

  defp process_new_operation(operation) do
    case operation_work(operation) do
      nil -> {:error, "invalid_operation", %{}}
      work -> process_with_savepoint(operation, work)
    end
  end

  defp operation_work(%{"type" => "open_group"}), do: &open_group/1
  defp operation_work(%{"type" => "record_cash_payment"}), do: &record_cash_payment/1
  defp operation_work(%{"type" => "apply_hotel_credit"}), do: &apply_hotel_credit/1
  defp operation_work(%{"type" => "reschedule_group"}), do: &reschedule_group/1
  defp operation_work(%{"type" => "cancel_group"}), do: &cancel_group/1
  defp operation_work(%{"type" => "cancel_rooms"}), do: &cancel_rooms/1
  defp operation_work(%{"type" => "reduce_cash_payment"}), do: &reduce_cash_payment/1
  defp operation_work(%{"type" => "charge_back_payment"}), do: &charge_back_payment/1
  defp operation_work(_operation), do: nil

  defp process_with_savepoint(operation, work) do
    Repo.query!("SAVEPOINT partner_operation_domain")

    case work.(operation) do
      {:ok, result} ->
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
        {:ok, result}

      {:error, code, fields} ->
        Repo.query!("ROLLBACK TO SAVEPOINT partner_operation_domain")
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
        {:error, code, fields}

      {:retry} ->
        Repo.query!("ROLLBACK TO SAVEPOINT partner_operation_domain")
        Repo.query!("RELEASE SAVEPOINT partner_operation_domain")
        {:retry}
    end
  end

  defp persist_operation_result(remembered, result) do
    case Repo.update(PartnerOperation.changeset(remembered, %{result: result})) do
      {:ok, _remembered} ->
        result

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp unique_operation_id_conflict?(changeset),
    do: Keyword.has_key?(changeset.errors, :operation_id)

  defp open_group(operation) do
    with :ok <- validate_open_input(operation),
         :ok <- ensure_group_available(operation),
         {:ok, dates} <- open_dates(operation),
         :ok <- validate_rate_plan(operation),
         {:ok, rooms, lodging_total, deposit_due} <- open_rooms(operation, dates.nights) do
      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: dates.booked_on,
        arrival_on: dates.arrival_on,
        departure_on: dates.departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version(operation["rate_plan"], dates.booked_on),
        status: "active",
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0,
        revision: 1
      }

      case Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, group} ->
          case insert_rooms(group, rooms) do
            :ok ->
              {:ok,
               applied(operation, %{
                 "group_id" => group.group_id,
                 "deposit_due_cents" => group.deposit_due_cents,
                 "revision" => group.revision
               })}

            {:error, _changeset} ->
              {:error, "invalid_rooms", group_fields(operation)}
          end

        {:error, _changeset} ->
          {:error, "group_already_exists", group_fields(operation)}
      end
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         :ok <- validate_occurred_on(operation),
         {:ok, amount} <- payment_amount(operation),
         :ok <- ensure_payment_within_outstanding(group, amount),
         :ok <- allocate_cash(group, amount, operation["operation_id"]),
         :ok <- insert_payment_disposition(group, operation["operation_id"], amount),
         result <- sync_group(group, %{}, operation) do
      case result do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "group_id" => updated_group.group_id,
             "amount_cents" => amount,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           })}

        other ->
          other
      end
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         :ok <- validate_occurred_on(operation),
         {:ok, amount} <- payment_amount(operation),
         :ok <- ensure_payment_within_outstanding(group, amount),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, allocations} <- allocate_credit(group.guest_id, amount, occurred_on, operation),
         :ok <- apply_credit_allocations(group, allocations),
         result <- sync_group(group, %{}, operation) do
      case result do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "group_id" => updated_group.group_id,
             "amount_cents" => amount,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           })}

        other ->
          other
      end
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         {:ok, new_arrival_on} <- reschedule_date(operation),
         new_departure_on <-
           Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)),
         result <-
           update_group(
             group,
             %{arrival_on: new_arrival_on, departure_on: new_departure_on},
             operation
           ) do
      case result do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "group_id" => updated_group.group_id,
             "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
             "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
             "policy_version" => policy_version(updated_group),
             "refundable_until" => refundable_until(updated_group),
             "revision" => updated_group.revision
           })}

        other ->
          other
      end
    end
  end

  defp cancel_group(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         {:ok, occurred_on} <- cancellation_date(operation),
         {:ok, refund_method} <- refund_method(operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refundable?, refund_method, operation) do
      room_ids = Enum.filter(group.rooms, &(&1.status == "active"))

      settle_cancelled_rooms(
        group,
        room_ids,
        refundable?,
        refund_method,
        occurred_on,
        operation,
        :group
      )
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group} <- fetch_group(operation),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_active(group, operation),
         {:ok, occurred_on} <- cancellation_date(operation),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, rooms} <- selected_active_rooms(group, operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- ensure_refund_method_available(refundable?, refund_method, operation) do
      settle_cancelled_rooms(
        group,
        rooms,
        refundable?,
        refund_method,
        occurred_on,
        operation,
        :rooms
      )
    end
  end

  defp settle_cancelled_rooms(
         group,
         rooms,
         refundable?,
         refund_method,
         occurred_on,
         operation,
         mode
       ) do
    with :ok <- settle_room_credit(rooms, refundable?, occurred_on),
         {:ok, cash_total, contributions} <- settle_room_cash(rooms, refundable?, refund_method),
         {:ok, credit_issued_cents} <-
           issue_cancellation_credit(
             group,
             refundable?,
             refund_method,
             occurred_on,
             operation,
             cash_total,
             contributions
           ),
         :ok <- mark_rooms_cancelled(rooms),
         result <-
           sync_group(
             group,
             settlement_counter_attrs(group, cash_total, refundable?, refund_method),
             operation
           ) do
      case result do
        {:ok, updated_group} ->
          fields = %{
            "group_id" => updated_group.group_id,
            "refunded_cents" => refunded_cash(cash_total, refundable?, refund_method),
            "retained_cents" => retained_cash(cash_total, refundable?),
            "credit_issued_cents" => credit_issued_cents,
            "revision" => updated_group.revision
          }

          fields =
            case mode do
              :group -> fields
              :rooms -> Map.put(fields, "cancelled_room_ids", Enum.map(rooms, & &1.room_id))
            end

          {:ok, applied(operation, fields)}

        other ->
          other
      end
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, disposition, group} <- reducible_payment(operation),
         :ok <- check_expected_revision(group, operation),
         {:ok, amount} <- reduction_amount(operation),
         :ok <- ensure_reducible(disposition),
         :ok <- ensure_reduction_within_held(disposition, amount),
         :ok <- remove_cash_allocations(disposition.payment_operation_id, amount),
         :ok <-
           update_disposition(disposition, %{
             held_cents: disposition.held_cents - amount,
             reduced_cents: disposition.reduced_cents + amount
           }),
         result <-
           sync_group(group, %{cash_reduced_cents: group.cash_reduced_cents + amount}, operation) do
      case result do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "payment_operation_id" => disposition.payment_operation_id,
             "group_id" => updated_group.group_id,
             "amount_cents" => amount,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           })}

        other ->
          other
      end
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, disposition, group} <- reducible_payment(operation, "payment_not_chargeable"),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_chargeable(disposition),
         :ok <- remove_cash_allocations(disposition.payment_operation_id, disposition.held_cents),
         :ok <- revoke_credit_entitlements(disposition.payment_operation_id),
         charged_back_cents <- charge_back_amount(disposition),
         :ok <-
           update_disposition(disposition, %{
             held_cents: 0,
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             charged_back_cents: disposition.charged_back_cents + charged_back_cents
           }),
         result <-
           sync_group(
             group,
             %{
               cash_refunded_cents: group.cash_refunded_cents - disposition.refunded_cents,
               cash_retained_cents: group.cash_retained_cents - disposition.retained_cents,
               cash_converted_to_credit_cents:
                 group.cash_converted_to_credit_cents - disposition.converted_to_credit_cents,
               cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents
             },
             operation
           ) do
      case result do
        {:ok, updated_group} ->
          {:ok,
           applied(operation, %{
             "payment_operation_id" => disposition.payment_operation_id,
             "group_id" => updated_group.group_id,
             "charged_back_cents" => charged_back_cents,
             "outstanding_deposit_cents" => outstanding_deposit(updated_group),
             "revision" => updated_group.revision
           })}

        other ->
          other
      end
    end
  end

  defp validate_open_input(operation) do
    required_values? =
      Enum.all?(@open_fields, &(Map.has_key?(operation, &1) and not is_nil(operation[&1])))

    identifiers? = Enum.all?(["group_id", "guest_id", "property_id"], &is_binary(operation[&1]))
    if required_values? and identifiers?, do: :ok, else: {:error, "invalid_operation", %{}}
  end

  defp ensure_group_available(operation) do
    if Repo.exists?(from(group in Group, where: group.group_id == ^operation["group_id"])) do
      {:error, "group_already_exists", group_fields(operation)}
    else
      :ok
    end
  end

  defp open_dates(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :gt <- Date.compare(departure_on, arrival_on) do
      {:ok,
       %{
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         nights: Date.diff(departure_on, arrival_on)
       }}
    else
      _ -> {:error, "invalid_stay", group_fields(operation)}
    end
  end

  defp validate_rate_plan(%{"rate_plan" => rate_plan})
       when rate_plan in ["flexible", "advance_purchase"], do: :ok

  defp validate_rate_plan(operation), do: {:error, "invalid_rate_plan", group_fields(operation)}

  defp open_rooms(operation, nights) do
    case operation["rooms"] do
      rooms when is_list(rooms) and rooms != [] ->
        build_rooms(rooms, nights, operation["rate_plan"], group_fields(operation))

      _ ->
        {:error, "invalid_rooms", group_fields(operation)}
    end
  end

  defp build_rooms(rooms, nights, rate_plan, fields) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({[], MapSet.new(), 0, 0}, fn {room, position},
                                                      {built, ids, lodging, due} ->
      case room_data(room, position, nights, rate_plan, ids) do
        {:ok, built_room, room_lodging, room_due} ->
          {:cont,
           {[built_room | built], MapSet.put(ids, built_room.room_id), lodging + room_lodging,
            due + room_due}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {built, _ids, lodging, due} -> {:ok, Enum.reverse(built), lodging, due}
      :error -> {:error, "invalid_rooms", fields}
    end
  end

  defp room_data(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate},
         position,
         nights,
         rate_plan,
         ids
       )
       when is_binary(room_id) and is_integer(nightly_rate) and nightly_rate >= 0 do
    if MapSet.member?(ids, room_id) do
      :error
    else
      lodging = nights * nightly_rate

      due =
        case rate_plan do
          "flexible" -> rounded_percentage(lodging, 20)
          "advance_purchase" -> lodging
        end

      {:ok,
       %{
         room_id: room_id,
         nightly_rate_cents: nightly_rate,
         position: position,
         status: "active",
         lodging_total_cents: lodging,
         deposit_due_cents: due,
         cash_paid_cents: 0,
         credit_paid_cents: 0
       }, lodging, due}
    end
  end

  defp room_data(_room, _position, _nights, _rate_plan, _ids), do: :error

  defp insert_rooms(group, rooms) do
    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      case Repo.insert(Room.changeset(%Room{}, Map.put(room, :group_id, group.id))) do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp fetch_group(operation) do
    case operation["group_id"] do
      group_id when is_binary(group_id) ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, "group_not_found", group_fields(operation)}
          group -> {:ok, preload_rooms(group)}
        end

      _ ->
        {:error, "invalid_operation", %{}}
    end
  end

  defp preload_rooms(group),
    do: Repo.preload(group, rooms: from(room in Room, order_by: room.position))

  defp check_expected_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      {:error, "stale_revision", stale_fields(operation, group.revision, group.group_id)}
    else
      :ok
    end
  end

  defp ensure_active(%Group{status: "active"}, _operation), do: :ok
  defp ensure_active(_group, operation), do: {:error, "group_not_active", group_fields(operation)}

  defp validate_occurred_on(operation) do
    if Map.has_key?(operation, "occurred_on") and
         match?({:ok, _}, parse_date(operation["occurred_on"])) do
      :ok
    else
      {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp payment_amount(operation) do
    case operation do
      %{"amount_cents" => amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      %{"amount_cents" => _amount} -> {:error, "invalid_amount", group_fields(operation)}
      _ -> {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp reduction_amount(operation) do
    case operation do
      %{"amount_cents" => amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      %{"amount_cents" => _amount} -> {:error, "invalid_amount", %{}}
      _ -> {:error, "invalid_operation", %{}}
    end
  end

  defp ensure_payment_within_outstanding(group, amount) do
    if amount <= outstanding_deposit(group) do
      :ok
    else
      {:error, "payment_exceeds_outstanding", %{"group_id" => group.group_id}}
    end
  end

  defp reschedule_date(operation) do
    if Map.has_key?(operation, "occurred_on") and Map.has_key?(operation, "new_arrival_on") do
      with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
           {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
           :gt <- Date.compare(new_arrival_on, occurred_on) do
        {:ok, new_arrival_on}
      else
        _ -> {:error, "invalid_stay", group_fields(operation)}
      end
    else
      {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp cancellation_date(operation) do
    case parse_date(operation["occurred_on"]) do
      {:ok, occurred_on} -> {:ok, occurred_on}
      _ -> {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp ensure_refund_method_available(false, "hotel_credit", operation),
    do: {:error, "refund_method_not_available", group_fields(operation)}

  defp ensure_refund_method_available(_refundable?, _refund_method, _operation), do: :ok

  defp selected_active_rooms(group, %{"room_ids" => room_ids} = operation)
       when is_list(room_ids) and room_ids != [] do
    requested = MapSet.new(room_ids)
    active_rooms = Enum.filter(group.rooms, &(&1.status == "active"))

    if Enum.all?(room_ids, &is_binary/1) and MapSet.size(requested) == length(room_ids) and
         Enum.count(active_rooms, &MapSet.member?(requested, &1.room_id)) == length(room_ids) do
      {:ok, Enum.filter(active_rooms, &MapSet.member?(requested, &1.room_id))}
    else
      {:error, "invalid_rooms", group_fields(operation)}
    end
  end

  defp selected_active_rooms(_group, operation),
    do: {:error, "invalid_rooms", group_fields(operation)}

  defp settle_room_credit(rooms, refundable?, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)

    credit_applications_for_rooms(room_ids)
    |> Enum.reduce_while(:ok, fn {application, lot}, :ok ->
      result =
        if refundable? do
          restore_credit(lot, application.amount_cents, occurred_on)
        else
          :ok
        end

      with :ok <- result,
           {1, _} <-
             Repo.delete_all(
               from(current in CreditApplication, where: current.id == ^application.id)
             ),
           {1, _} <-
             Repo.update_all(
               from(room in Room, where: room.id == ^application.room_id),
               inc: [credit_paid_cents: -application.amount_cents]
             ) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "invalid_operation", %{}}}
      end
    end)
  end

  defp settle_room_cash(rooms, refundable?, refund_method) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from(allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.room_id in ^room_ids,
          order_by: allocation.id,
          select: {allocation, room}
        )
      )

    payment_amounts =
      Enum.reduce(allocations, %{}, fn {allocation, _room}, amounts ->
        if allocation.payment_operation_id do
          Map.update(
            amounts,
            allocation.payment_operation_id,
            allocation.amount_cents,
            &(&1 + allocation.amount_cents)
          )
        else
          amounts
        end
      end)

    contributions = contribution_amounts(allocations)

    with :ok <- settle_cash_allocations(allocations),
         :ok <- settle_payment_dispositions(payment_amounts, refundable?, refund_method) do
      {:ok, Enum.sum_by(allocations, fn {allocation, _room} -> allocation.amount_cents end),
       contributions}
    end
  end

  defp settle_cash_allocations(allocations) do
    Enum.reduce_while(allocations, :ok, fn {allocation, _room}, :ok ->
      with {1, _} <-
             Repo.delete_all(from(current in CashAllocation, where: current.id == ^allocation.id)),
           {1, _} <-
             Repo.update_all(
               from(room in Room, where: room.id == ^allocation.room_id),
               inc: [cash_paid_cents: -allocation.amount_cents]
             ) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "invalid_operation", %{}}}
      end
    end)
  end

  defp settle_payment_dispositions(payment_amounts, refundable?, refund_method) do
    Enum.reduce_while(payment_amounts, :ok, fn {payment_id, amount}, :ok ->
      case Repo.get_by(CashPaymentDisposition, payment_operation_id: payment_id) do
        nil ->
          {:halt, {:error, "invalid_operation", %{}}}

        disposition ->
          attrs =
            disposition
            |> Map.take([
              :held_cents,
              :refunded_cents,
              :retained_cents,
              :converted_to_credit_cents
            ])
            |> Map.put(:held_cents, disposition.held_cents - amount)
            |> add_cash_settlement(amount, refundable?, refund_method)

          case update_disposition(disposition, attrs) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp add_cash_settlement(attrs, amount, true, "cash"),
    do: Map.update!(attrs, :refunded_cents, &(&1 + amount))

  defp add_cash_settlement(attrs, amount, true, "hotel_credit"),
    do: Map.update!(attrs, :converted_to_credit_cents, &(&1 + amount))

  defp add_cash_settlement(attrs, amount, false, _refund_method),
    do: Map.update!(attrs, :retained_cents, &(&1 + amount))

  defp contribution_amounts(allocations) do
    allocations
    |> Enum.map(fn {allocation, _room} ->
      {allocation.payment_operation_id, allocation.amount_cents}
    end)
    |> Enum.reduce([], fn {payment_id, amount}, contributions ->
      case contributions do
        [{^payment_id, prior_amount} | rest] -> [{payment_id, prior_amount + amount} | rest]
        _ -> [{payment_id, amount} | contributions]
      end
    end)
    |> Enum.reverse()
  end

  defp issue_cancellation_credit(
         _group,
         _refundable?,
         _refund_method,
         _occurred_on,
         _operation,
         0,
         _contributions
       ),
       do: {:ok, 0}

  defp issue_cancellation_credit(
         group,
         true,
         "hotel_credit",
         occurred_on,
         operation,
         cash_total,
         contributions
       ) do
    issued_cents = cash_total + rounded_percentage(cash_total, 10)

    attrs = %{
      guest_id: group.guest_id,
      source_operation_id: operation["operation_id"],
      remaining_cents: issued_cents,
      expires_on: Date.add(occurred_on, 366),
      unrecovered_clawback_cents: 0
    }

    with {:ok, lot} <- Repo.insert(CreditLot.changeset(%CreditLot{}, attrs)),
         :ok <- insert_credit_contributions(lot, contributions) do
      {:ok, issued_cents}
    else
      _ -> {:error, "invalid_operation", group_fields(operation)}
    end
  end

  defp issue_cancellation_credit(
         _group,
         _refundable?,
         _refund_method,
         _occurred_on,
         _operation,
         _cash_total,
         _contributions
       ),
       do: {:ok, 0}

  defp insert_credit_contributions(lot, contributions) do
    {_running, _value, result} =
      Enum.reduce(contributions, {0, 0, :ok}, fn {payment_id, amount},
                                                 {running, previous_value, :ok} ->
        total = running + amount
        value = total + rounded_percentage(total, 10)

        attrs = %{
          credit_lot_id: lot.id,
          payment_operation_id: payment_id,
          converted_cents: amount,
          entitlement_cents: value - previous_value
        }

        case Repo.insert(CreditLotContribution.changeset(%CreditLotContribution{}, attrs)) do
          {:ok, _contribution} -> {total, value, :ok}
          {:error, _changeset} -> {running, previous_value, :error}
        end
      end)

    result
  end

  defp mark_rooms_cancelled(rooms) do
    {updated, _} =
      Repo.update_all(
        from(room in Room,
          where: room.id in ^Enum.map(rooms, & &1.id) and room.status == "active"
        ),
        set: [status: "cancelled"]
      )

    if updated == length(rooms), do: :ok, else: {:error, "invalid_operation", %{}}
  end

  defp settlement_counter_attrs(group, cash_total, refundable?, refund_method) do
    cond do
      refundable? and refund_method == "cash" ->
        %{cash_refunded_cents: group.cash_refunded_cents + cash_total}

      refundable? ->
        %{cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + cash_total}

      true ->
        %{cash_retained_cents: group.cash_retained_cents + cash_total}
    end
  end

  defp refunded_cash(cash_total, true, "cash"), do: cash_total
  defp refunded_cash(_cash_total, _refundable?, _refund_method), do: 0
  defp retained_cash(cash_total, false), do: cash_total
  defp retained_cash(_cash_total, true), do: 0

  defp restore_credit(lot, amount, occurred_on) do
    current_lot = Repo.get(CreditLot, lot.id)

    if current_lot do
      absorbed = min(amount, current_lot.unrecovered_clawback_cents)
      restored = amount - absorbed

      attrs = %{unrecovered_clawback_cents: current_lot.unrecovered_clawback_cents - absorbed}

      attrs =
        if restored > 0 and credit_available?(current_lot, occurred_on) do
          Map.put(attrs, :remaining_cents, current_lot.remaining_cents + restored)
        else
          attrs
        end

      case Repo.update(CreditLot.changeset(current_lot, attrs)) do
        {:ok, _lot} -> :ok
        {:error, _changeset} -> {:error, "invalid_operation", %{}}
      end
    else
      {:error, "invalid_operation", %{}}
    end
  end

  defp allocate_cash(group, amount, payment_operation_id) do
    segments = cash_room_segments(group.rooms, amount)

    if Enum.sum_by(segments, &elem(&1, 1)) == amount do
      Enum.reduce_while(segments, :ok, fn {room, applied}, :ok ->
        attrs = %{
          room_id: room.id,
          payment_operation_id: payment_operation_id,
          amount_cents: applied
        }

        with {:ok, _allocation} <- Repo.insert(CashAllocation.changeset(%CashAllocation{}, attrs)),
             {1, _} <-
               Repo.update_all(from(current in Room, where: current.id == ^room.id),
                 inc: [cash_paid_cents: applied]
               ) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, "invalid_operation", %{}}}
        end
      end)
    else
      {:error, "payment_exceeds_outstanding", %{"group_id" => group.group_id}}
    end
  end

  defp cash_room_segments(rooms, amount) do
    {_remaining, segments} =
      Enum.reduce(rooms, {amount, []}, fn room, {remaining, segments} ->
        capacity = active_room_capacity(room)
        applied = min(capacity, remaining)
        {remaining - applied, if(applied > 0, do: [{room, applied} | segments], else: segments)}
      end)

    Enum.reverse(segments)
  end

  defp active_room_capacity(%Room{status: "active"} = room),
    do: max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

  defp active_room_capacity(_room), do: 0

  defp insert_payment_disposition(group, payment_operation_id, amount) do
    attrs = %{
      group_id: group.id,
      payment_operation_id: payment_operation_id,
      recorded_cents: amount,
      held_cents: amount,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    }

    case Repo.insert(CashPaymentDisposition.changeset(%CashPaymentDisposition{}, attrs)) do
      {:ok, _disposition} -> :ok
      {:error, _changeset} -> {:error, "invalid_operation", %{}}
    end
  end

  defp allocate_credit(guest_id, amount, occurred_on, operation) do
    lots = available_lots(guest_id, occurred_on)

    if Enum.sum_by(lots, & &1.remaining_cents) < amount do
      {:error, "insufficient_credit", group_fields(operation)}
    else
      {:ok, credit_allocations(lots, amount)}
    end
  end

  defp credit_allocations(lots, amount) do
    {allocations, _remaining} =
      Enum.reduce_while(lots, {[], amount}, fn lot, {allocations, remaining} ->
        allocated = min(lot.remaining_cents, remaining)

        if allocated == remaining do
          {:halt, {[{lot, allocated} | allocations], 0}}
        else
          {:cont, {[{lot, allocated} | allocations], remaining - allocated}}
        end
      end)

    Enum.reverse(allocations)
  end

  defp apply_credit_allocations(group, allocations) do
    segments = credit_room_segments(group.rooms, allocations)

    with :ok <- decrement_credit_lots(allocations),
         :ok <- insert_credit_applications(group, segments) do
      :ok
    end
  end

  defp decrement_credit_lots(allocations) do
    Enum.reduce_while(allocations, :ok, fn {lot, amount}, :ok ->
      {updated, _} =
        Repo.update_all(
          from(current in CreditLot,
            where: current.id == ^lot.id and current.remaining_cents >= ^amount
          ),
          inc: [remaining_cents: -amount]
        )

      if updated == 1, do: {:cont, :ok}, else: {:halt, {:error, "insufficient_credit", %{}}}
    end)
  end

  defp insert_credit_applications(group, segments) do
    Enum.reduce_while(segments, :ok, fn {room, lot, amount}, :ok ->
      attrs = %{group_id: group.id, room_id: room.id, credit_lot_id: lot.id, amount_cents: amount}

      with {:ok, _application} <-
             Repo.insert(CreditApplication.changeset(%CreditApplication{}, attrs)),
           {1, _} <-
             Repo.update_all(from(current in Room, where: current.id == ^room.id),
               inc: [credit_paid_cents: amount]
             ) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "insufficient_credit", %{"group_id" => group.group_id}}}
      end
    end)
  end

  defp credit_room_segments(rooms, allocations) do
    {_sources, segments} =
      Enum.reduce(rooms, {allocations, []}, fn room, {sources, segments} ->
        {sources, room_segments} = consume_credit_sources(sources, active_room_capacity(room), [])

        {sources,
         segments ++ Enum.map(room_segments, fn {lot, amount} -> {room, lot, amount} end)}
      end)

    segments
  end

  defp consume_credit_sources(sources, 0, segments), do: {sources, Enum.reverse(segments)}
  defp consume_credit_sources([], _capacity, segments), do: {[], Enum.reverse(segments)}

  defp consume_credit_sources([{lot, available} | rest], capacity, segments) do
    applied = min(available, capacity)
    next_sources = if applied == available, do: rest, else: [{lot, available - applied} | rest]
    consume_credit_sources(next_sources, capacity - applied, [{lot, applied} | segments])
  end

  defp credit_applications_for_rooms(room_ids) do
    Repo.all(
      from(application in CreditApplication,
        join: lot in CreditLot,
        on: lot.id == application.credit_lot_id,
        where: application.room_id in ^room_ids,
        order_by: application.id,
        select: {application, lot}
      )
    )
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from(lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
    )
  end

  defp credit_available?(lot, on), do: Date.compare(lot.expires_on, on) == :gt

  defp reducible_payment(operation, non_payment_code \\ "payment_not_reducible") do
    case operation["payment_operation_id"] do
      payment_operation_id when is_binary(payment_operation_id) ->
        case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
          nil ->
            {:error, "operation_not_found", %{}}

          %PartnerOperation{
            operation_type: "record_cash_payment",
            result: %{"status" => "applied"}
          } ->
            case Repo.get_by(CashPaymentDisposition, payment_operation_id: payment_operation_id) do
              nil ->
                {:error, non_payment_code, %{}}

              disposition ->
                case Repo.get(Group, disposition.group_id) do
                  nil -> {:error, non_payment_code, %{}}
                  group -> {:ok, disposition, preload_rooms(group)}
                end
            end

          _operation ->
            {:error, non_payment_code, %{}}
        end

      _ ->
        {:error, "operation_not_found", %{}}
    end
  end

  defp ensure_reducible(%CashPaymentDisposition{held_cents: held}) when held > 0, do: :ok
  defp ensure_reducible(_disposition), do: {:error, "payment_not_reducible", %{}}

  defp ensure_reduction_within_held(disposition, amount) do
    if amount <= disposition.held_cents do
      :ok
    else
      {:error, "reduction_exceeds_held_cash", %{}}
    end
  end

  defp remove_cash_allocations(_payment_operation_id, 0), do: :ok

  defp remove_cash_allocations(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from(allocation in CashAllocation,
          where: allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: allocation.id]
        )
      )

    {remaining, result} =
      Enum.reduce_while(allocations, {amount, :ok}, fn allocation, {remaining, :ok} ->
        removed = min(remaining, allocation.amount_cents)

        operation =
          if removed == allocation.amount_cents do
            case Repo.delete(allocation) do
              {:ok, _allocation} -> :ok
              {:error, _changeset} -> :error
            end
          else
            case Repo.update(
                   CashAllocation.changeset(allocation, %{
                     amount_cents: allocation.amount_cents - removed
                   })
                 ) do
              {:ok, _allocation} -> :ok
              {:error, _changeset} -> :error
            end
          end

        if operation == :ok do
          {updated, _} =
            Repo.update_all(from(room in Room, where: room.id == ^allocation.room_id),
              inc: [cash_paid_cents: -removed]
            )

          if updated == 1 do
            if remaining == removed,
              do: {:halt, {0, :ok}},
              else: {:cont, {remaining - removed, :ok}}
          else
            {:halt, {remaining, :error}}
          end
        else
          {:halt, {remaining, :error}}
        end
      end)

    if result == :ok and remaining == 0, do: :ok, else: {:error, "invalid_operation", %{}}
  end

  defp update_disposition(disposition, attrs) do
    case Repo.update(CashPaymentDisposition.changeset(disposition, attrs)) do
      {:ok, _disposition} -> :ok
      {:error, _changeset} -> {:error, "invalid_operation", %{}}
    end
  end

  defp ensure_chargeable(disposition) do
    if disposition.charged_back_cents > 0 or
         disposition.recorded_cents == disposition.reduced_cents do
      {:error, "payment_not_chargeable", %{}}
    else
      :ok
    end
  end

  defp charge_back_amount(disposition) do
    disposition.held_cents + disposition.refunded_cents + disposition.retained_cents +
      disposition.converted_to_credit_cents
  end

  defp revoke_credit_entitlements(payment_operation_id) do
    Repo.all(
      from(contribution in CreditLotContribution,
        where: contribution.payment_operation_id == ^payment_operation_id,
        order_by: contribution.id
      )
    )
    |> Enum.reduce_while(:ok, fn contribution, :ok ->
      case Repo.get(CreditLot, contribution.credit_lot_id) do
        nil ->
          {:halt, {:error, "invalid_operation", %{}}}

        lot ->
          removed = min(lot.remaining_cents, contribution.entitlement_cents)
          shortfall = contribution.entitlement_cents - removed

          attrs = %{
            remaining_cents: lot.remaining_cents - removed,
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents + shortfall
          }

          case Repo.update(CreditLot.changeset(lot, attrs)) do
            {:ok, _lot} -> {:cont, :ok}
            {:error, _changeset} -> {:halt, {:error, "invalid_operation", %{}}}
          end
      end
    end)
  end

  defp refundable?(group, occurred_on) do
    case refundable_until_date(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) in [:lt, :eq]
    end
  end

  defp policy_version(%Group{} = group),
    do: group.policy_version || policy_version(group.rate_plan, group.booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) in [:eq, :gt], do: "flex-30", else: "flex-14"
  end

  defp refundable_until(group) do
    case refundable_until_date(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp refundable_until_date(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp rounded_percentage(amount, percentage), do: div(amount * percentage + 50, 100)

  defp sync_group(group, extra_attrs, operation) do
    update_group(group, Map.merge(active_group_attrs(group.id), extra_attrs), operation)
  end

  defp active_group_attrs(group_id) do
    totals =
      Repo.one(
        from(room in Room,
          where: room.group_id == ^group_id and room.status == "active",
          select: %{
            rooms: count(room.id),
            lodging: coalesce(sum(room.lodging_total_cents), 0),
            due: coalesce(sum(room.deposit_due_cents), 0),
            cash: coalesce(sum(room.cash_paid_cents), 0),
            credit: coalesce(sum(room.credit_paid_cents), 0)
          }
        )
      )

    %{
      status: if(totals.rooms == 0, do: "cancelled", else: "active"),
      lodging_total_cents: totals.lodging,
      deposit_due_cents: totals.due,
      deposit_paid_cents: totals.cash + totals.credit,
      cash_paid_cents: totals.cash,
      credit_paid_cents: totals.credit
    }
  end

  defp update_group(group, attrs, operation) do
    {updated, _} =
      Repo.update_all(
        from(current_group in Group,
          where: current_group.id == ^group.id and current_group.revision == ^group.revision
        ),
        set: Map.to_list(attrs) ++ [revision: group.revision + 1]
      )

    if updated == 1 do
      {:ok, struct(group, Map.put(attrs, :revision, group.revision + 1))}
    else
      update_conflict(operation, group)
    end
  end

  defp update_conflict(operation, group) do
    if Map.has_key?(operation, "expected_revision") do
      actual_revision =
        case Repo.get_by(Group, group_id: group.group_id) do
          nil -> group.revision
          current_group -> current_group.revision
        end

      {:error, "stale_revision", stale_fields(operation, actual_revision, group.group_id)}
    else
      {:retry}
    end
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0
  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp total(field, filters \\ []) do
    query = from(group in Group, select: coalesce(sum(field(group, ^field)), 0))

    query =
      case Keyword.get(filters, :status) do
        nil -> query
        status -> from(group in query, where: group.status == ^status)
      end

    Repo.one(query)
  end

  defp available_credit_total(on) do
    Repo.one(
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^on,
        select: coalesce(sum(lot.remaining_cents), 0)
      )
    )
  end

  defp applied_credit_total do
    Repo.one(
      from(application in CreditApplication,
        join: room in Room,
        on: room.id == application.room_id,
        join: group in Group,
        on: group.id == application.group_id,
        where: group.status == "active" and room.status == "active",
        select: coalesce(sum(application.amount_cents), 0)
      )
    )
  end

  defp credit_shortfall_total do
    applied_by_lot =
      Repo.all(
        from(application in CreditApplication,
          join: room in Room,
          on: room.id == application.room_id,
          join: group in Group,
          on: group.id == application.group_id,
          where: group.status == "active" and room.status == "active",
          group_by: application.credit_lot_id,
          select: {application.credit_lot_id, sum(application.amount_cents)}
        )
      )
      |> Map.new()

    Repo.all(from(lot in CreditLot, where: lot.unrecovered_clawback_cents > 0))
    |> Enum.sum_by(fn lot ->
      min(lot.unrecovered_clawback_cents, Map.get(applied_by_lot, lot.id, 0))
    end)
  end

  defp payment_data(disposition) do
    %{
      "payment_operation_id" => disposition.payment_operation_id,
      "original_group_id" => Repo.get!(Group, disposition.group_id).group_id,
      "recorded_cents" => disposition.recorded_cents,
      "held_cents" => disposition.held_cents,
      "refunded_cents" => disposition.refunded_cents,
      "retained_cents" => disposition.retained_cents,
      "converted_to_credit_cents" => disposition.converted_to_credit_cents,
      "reduced_cents" => disposition.reduced_cents,
      "charged_back_cents" => disposition.charged_back_cents
    }
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp applied(operation, fields),
    do:
      Map.merge(
        %{"operation_id" => Map.get(operation, "operation_id"), "status" => "applied"},
        fields
      )

  defp rejection(operation, code, fields \\ %{}) do
    Map.merge(fields, %{
      "operation_id" => Map.get(operation, "operation_id"),
      "status" => "rejected",
      "code" => code
    })
  end

  defp group_fields(operation) do
    case operation["group_id"] do
      group_id when is_binary(group_id) -> %{"group_id" => group_id}
      _ -> %{}
    end
  end

  defp stale_fields(operation, actual_revision, group_id) do
    %{
      "group_id" => group_id,
      "expected_revision" => Map.get(operation, "expected_revision"),
      "actual_revision" => actual_revision
    }
  end
end
