defmodule GroupStay.Groups do
  import Ecto.Query

  alias GroupStay.{
    AllocationSequence,
    CashAllocation,
    CashPaymentDisposition,
    CashPaymentSettlement,
    CreditApplication,
    CreditLot,
    CreditLotContribution,
    FinanceReporting,
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

  def daily_reporting_date(%{"date" => date}) do
    case parse_date(date) do
      {:ok, parsed_date} -> {:ok, parsed_date}
      _ -> :error
    end
  end

  def daily_reporting_date(_params), do: :error

  def daily_finance_report(date) when is_struct(date, Date),
    do: FinanceReporting.daily_report(date)

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
  defp operation_work(%{"type" => "start_finance_reporting"}), do: &start_finance_reporting/1
  defp operation_work(%{"type" => "record_cash_payment"}), do: &record_cash_payment/1
  defp operation_work(%{"type" => "apply_hotel_credit"}), do: &apply_hotel_credit/1
  defp operation_work(%{"type" => "reschedule_group"}), do: &reschedule_group/1
  defp operation_work(%{"type" => "cancel_group"}), do: &cancel_group/1
  defp operation_work(%{"type" => "cancel_rooms"}), do: &cancel_rooms/1
  defp operation_work(%{"type" => "transfer_deposit"}), do: &transfer_deposit/1
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

  defp start_finance_reporting(operation) do
    case FinanceReporting.start(operation) do
      {:ok, starts_on} ->
        {:ok, applied(operation, %{"starts_on" => Date.to_iso8601(starts_on)})}

      error ->
        error
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
          with :ok <- FinanceReporting.cash(operation, updated_group, "received", amount) do
            {:ok,
             applied(operation, %{
               "group_id" => updated_group.group_id,
               "amount_cents" => amount,
               "outstanding_deposit_cents" => outstanding_deposit(updated_group),
               "revision" => updated_group.revision
             })}
          end

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
          with :ok <- report_credit_application(operation, allocations) do
            {:ok,
             applied(operation, %{
               "group_id" => updated_group.group_id,
               "amount_cents" => amount,
               "outstanding_deposit_cents" => outstanding_deposit(updated_group),
               "revision" => updated_group.revision
             })}
          end

        other ->
          other
      end
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source_group} <- fetch_transfer_group(operation, "source_group_id"),
         {:ok, destination_group} <- fetch_transfer_group(operation, "destination_group_id"),
         :ok <- check_expected_revision(source_group, operation),
         :ok <-
           check_expected_revision(destination_group, operation, "destination_expected_revision"),
         :ok <- ensure_valid_transfer(source_group, destination_group),
         :ok <- ensure_group_active(source_group),
         :ok <- ensure_group_active(destination_group),
         {:ok, amount} <- transfer_amount(operation),
         :ok <- ensure_transfer_within_held_funding(source_group, amount),
         :ok <- ensure_transfer_within_outstanding(destination_group, amount),
         {:ok, transferred_cash_payment_ids, transferred_cash_cents} <-
           transfer_funding(source_group, destination_group, amount),
         :ok <- mark_transferred_cash_payments(transferred_cash_payment_ids),
         {:ok, updated_source} <- sync_group(source_group, %{}, operation),
         {:ok, updated_destination} <-
           sync_group(destination_group, %{}, operation, "destination_expected_revision") do
      with :ok <-
             FinanceReporting.cash(
               operation,
               updated_source,
               "transferred_out",
               transferred_cash_cents
             ),
           :ok <-
             FinanceReporting.cash(
               operation,
               updated_destination,
               "transferred_in",
               transferred_cash_cents
             ) do
        {:ok,
         applied(operation, %{
           "source_group_id" => updated_source.group_id,
           "destination_group_id" => updated_destination.group_id,
           "amount_cents" => amount,
           "source_outstanding_deposit_cents" => outstanding_deposit(updated_source),
           "destination_outstanding_deposit_cents" => outstanding_deposit(updated_destination),
           "source_revision" => updated_source.revision,
           "destination_revision" => updated_destination.revision
         })}
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
    with :ok <- settle_room_credit(rooms, refundable?, occurred_on, operation),
         {:ok, cash_total, contributions} <-
           settle_room_cash(group, rooms, refundable?, refund_method),
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
          with :ok <-
                 report_cash_settlement(
                   operation,
                   updated_group,
                   cash_total,
                   refundable?,
                   refund_method
                 ),
               :ok <- report_credit_issuance(operation, credit_issued_cents) do
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
          end

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
         {:ok, affected_groups} <-
           remove_cash_allocations(disposition.payment_operation_id, amount),
         :ok <-
           update_disposition(disposition, %{
             held_cents: disposition.held_cents - amount,
             reduced_cents: disposition.reduced_cents + amount
           }),
         result <-
           sync_cash_change_groups(
             group,
             affected_groups,
             %{group.id => %{cash_reduced_cents: amount}},
             operation
           ) do
      case result do
        {:ok, updated_groups} ->
          updated_group = Map.fetch!(updated_groups, group.id)

          with :ok <- report_cash_changes(operation, affected_groups, "reduced") do
            {:ok,
             applied(operation, %{
               "payment_operation_id" => disposition.payment_operation_id,
               "group_id" => updated_group.group_id,
               "amount_cents" => amount,
               "outstanding_deposit_cents" => outstanding_deposit(updated_group),
               "revision" => updated_group.revision
             })}
          end

        other ->
          other
      end
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, disposition, group} <- reducible_payment(operation, "payment_not_chargeable"),
         :ok <- check_expected_revision(group, operation),
         :ok <- ensure_chargeable(disposition),
         {:ok, held_groups} <-
           remove_cash_allocations(disposition.payment_operation_id, disposition.held_cents),
         {:ok, settlement_deltas} <-
           charge_back_payment_settlements(disposition.payment_operation_id),
         {:ok, revoked_credit} <- revoke_credit_entitlements(disposition.payment_operation_id),
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
           sync_cash_change_groups(
             group,
             held_groups,
             add_held_charge_back_deltas(settlement_deltas, held_groups),
             operation
           ) do
      case result do
        {:ok, updated_groups} ->
          updated_group = Map.fetch!(updated_groups, group.id)

          with :ok <- report_cash_changes(operation, held_groups, "charged_back"),
               :ok <- report_charge_back_settlements(operation, settlement_deltas),
               :ok <- report_credit_revocations(operation, revoked_credit) do
            {:ok,
             applied(operation, %{
               "payment_operation_id" => disposition.payment_operation_id,
               "group_id" => updated_group.group_id,
               "charged_back_cents" => charged_back_cents,
               "outstanding_deposit_cents" => outstanding_deposit(updated_group),
               "revision" => updated_group.revision
             })}
          end

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

  defp fetch_transfer_group(operation, field) do
    case operation[field] do
      group_id when is_binary(group_id) ->
        case Repo.get_by(Group, group_id: group_id) do
          nil -> {:error, "group_not_found", %{"group_id" => group_id}}
          group -> {:ok, preload_rooms(group)}
        end

      _ ->
        {:error, "invalid_operation", %{}}
    end
  end

  defp preload_rooms(group),
    do: Repo.preload(group, rooms: from(room in Room, order_by: room.position))

  defp check_expected_revision(group, operation, expected_key \\ "expected_revision") do
    if Map.has_key?(operation, expected_key) and operation[expected_key] !== group.revision do
      {:error, "stale_revision",
       stale_fields(operation, group.revision, group.group_id, expected_key)}
    else
      :ok
    end
  end

  defp ensure_active(%Group{status: "active"}, _operation), do: :ok
  defp ensure_active(_group, operation), do: {:error, "group_not_active", group_fields(operation)}

  defp ensure_group_active(%Group{status: "active"}), do: :ok

  defp ensure_group_active(group),
    do: {:error, "group_not_active", %{"group_id" => group.group_id}}

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

  defp transfer_amount(%{"amount_cents" => amount}) when is_integer(amount) and amount > 0,
    do: {:ok, amount}

  defp transfer_amount(%{"amount_cents" => _amount}), do: {:error, "invalid_amount", %{}}
  defp transfer_amount(_operation), do: {:error, "invalid_operation", %{}}

  defp ensure_valid_transfer(source_group, destination_group) do
    if source_group.id == destination_group.id or
         source_group.guest_id != destination_group.guest_id do
      {:error, "invalid_transfer", %{}}
    else
      :ok
    end
  end

  defp ensure_transfer_within_held_funding(source_group, amount) do
    if amount <= source_group.deposit_paid_cents do
      :ok
    else
      {:error, "transfer_exceeds_held_funding", %{}}
    end
  end

  defp ensure_transfer_within_outstanding(destination_group, amount) do
    if amount <= outstanding_deposit(destination_group) do
      :ok
    else
      {:error, "transfer_exceeds_outstanding", %{}}
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

  defp settle_room_credit(rooms, refundable?, occurred_on, operation) do
    room_ids = Enum.map(rooms, & &1.id)

    credit_applications_for_rooms(room_ids)
    |> Enum.reduce_while(:ok, fn {application, lot}, :ok ->
      restore_result =
        if refundable? do
          restore_credit(lot, application.amount_cents, occurred_on)
        else
          {:ok, nil}
        end

      with {:ok, restoration} <- restore_result,
           {1, _} <-
             Repo.delete_all(
               from(current in CreditApplication, where: current.id == ^application.id)
             ),
           {1, _} <-
             Repo.update_all(
               from(room in Room, where: room.id == ^application.room_id),
               inc: [credit_paid_cents: -application.amount_cents]
             ),
           :ok <-
             report_credit_settlement(
               operation,
               lot,
               application.amount_cents,
               refundable?,
               restoration
             ) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "invalid_operation", %{}}}
      end
    end)
  end

  defp settle_room_cash(group, rooms, refundable?, refund_method) do
    room_ids = Enum.map(rooms, & &1.id)

    allocations =
      Repo.all(
        from(allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.room_id in ^room_ids,
          order_by: allocation.allocation_order,
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
         :ok <- settle_payment_dispositions(payment_amounts, group, refundable?, refund_method) do
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

  defp settle_payment_dispositions(payment_amounts, group, refundable?, refund_method) do
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

          with :ok <- update_disposition(disposition, attrs),
               :ok <-
                 record_payment_settlement(
                   payment_id,
                   group.id,
                   amount,
                   refundable?,
                   refund_method
                 ) do
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
      end
    end)
  end

  defp record_payment_settlement(
         payment_operation_id,
         group_id,
         amount,
         refundable?,
         refund_method
       ) do
    attrs =
      %{
        group_id: group_id,
        payment_operation_id: payment_operation_id,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0
      }
      |> add_cash_settlement(amount, refundable?, refund_method)

    case Repo.insert(CashPaymentSettlement.changeset(%CashPaymentSettlement{}, attrs),
           on_conflict: [
             inc: [
               refunded_cents: attrs.refunded_cents,
               retained_cents: attrs.retained_cents,
               converted_to_credit_cents: attrs.converted_to_credit_cents
             ]
           ],
           conflict_target: [:payment_operation_id, :group_id]
         ) do
      {:ok, _settlement} -> :ok
      {:error, _changeset} -> {:error, "invalid_operation", %{}}
    end
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
      available? = restored > 0 and credit_available?(current_lot, occurred_on)
      expired = if available?, do: 0, else: restored

      attrs = %{unrecovered_clawback_cents: current_lot.unrecovered_clawback_cents - absorbed}

      attrs =
        if available? do
          Map.put(attrs, :remaining_cents, current_lot.remaining_cents + restored)
        else
          attrs
        end

      case Repo.update(CreditLot.changeset(current_lot, attrs)) do
        {:ok, _lot} ->
          {:ok,
           %{
             absorbed: absorbed,
             restored: if(available?, do: restored, else: 0),
             expired: expired
           }}

        {:error, _changeset} ->
          {:error, "invalid_operation", %{}}
      end
    else
      {:error, "invalid_operation", %{}}
    end
  end

  defp report_credit_application(operation, allocations) do
    Enum.reduce_while(allocations, :ok, fn {lot, amount}, :ok ->
      case FinanceReporting.credit(operation, lot, nil, 0, -amount, amount) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp report_credit_settlement(operation, lot, amount, false, _restoration),
    do: FinanceReporting.credit(operation, lot, "consumed", amount, 0, -amount)

  defp report_credit_settlement(operation, lot, _amount, true, restoration) do
    with :ok <-
           FinanceReporting.credit(
             operation,
             lot,
             nil,
             0,
             restoration.restored,
             -restoration.restored
           ),
         :ok <-
           FinanceReporting.credit(
             operation,
             lot,
             "absorbed",
             restoration.absorbed,
             0,
             -restoration.absorbed
           ),
         :ok <-
           FinanceReporting.credit(
             operation,
             lot,
             "expired",
             restoration.expired,
             0,
             -restoration.expired
           ) do
      :ok
    end
  end

  defp report_cash_settlement(operation, group, cash_total, true, "cash"),
    do: FinanceReporting.cash(operation, group, "refunded", cash_total)

  defp report_cash_settlement(operation, group, cash_total, true, "hotel_credit"),
    do: FinanceReporting.cash(operation, group, "converted_to_credit", cash_total)

  defp report_cash_settlement(operation, group, cash_total, false, _refund_method),
    do: FinanceReporting.cash(operation, group, "retained", cash_total)

  defp report_credit_issuance(_operation, 0), do: :ok

  defp report_credit_issuance(operation, issued_cents) do
    case Repo.get_by(CreditLot, source_operation_id: operation["operation_id"]) do
      nil -> {:error, "invalid_operation", %{}}
      lot -> FinanceReporting.credit(operation, lot, "issued", issued_cents, issued_cents, 0)
    end
  end

  defp report_cash_changes(operation, group_amounts, category) do
    Enum.reduce_while(group_amounts, :ok, fn {group_id, amount}, :ok ->
      case FinanceReporting.cash_for_group_id(operation, group_id, category, amount) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp report_charge_back_settlements(operation, settlement_deltas) do
    Enum.reduce_while(settlement_deltas, :ok, fn {group_id, deltas}, :ok ->
      with :ok <-
             FinanceReporting.cash_for_group_id(
               operation,
               group_id,
               "refunded",
               Map.get(deltas, :cash_refunded_cents, 0)
             ),
           :ok <-
             FinanceReporting.cash_for_group_id(
               operation,
               group_id,
               "retained",
               Map.get(deltas, :cash_retained_cents, 0)
             ),
           :ok <-
             FinanceReporting.cash_for_group_id(
               operation,
               group_id,
               "converted_to_credit",
               Map.get(deltas, :cash_converted_to_credit_cents, 0)
             ),
           :ok <-
             FinanceReporting.cash_for_group_id(
               operation,
               group_id,
               "charged_back",
               Map.get(deltas, :cash_charged_back_cents, 0)
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp report_credit_revocations(operation, revoked_credit) do
    Enum.reduce_while(revoked_credit, :ok, fn {lot, removed}, :ok ->
      case FinanceReporting.credit_revocation(operation, lot, removed) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp allocate_cash(group, amount, payment_operation_id) do
    segments = cash_room_segments(group.rooms, amount)

    if Enum.sum_by(segments, &elem(&1, 1)) == amount do
      Enum.reduce_while(segments, :ok, fn {room, applied}, :ok ->
        with {:ok, allocation_order} <- next_allocation_order(),
             attrs = %{
               room_id: room.id,
               payment_operation_id: payment_operation_id,
               amount_cents: applied,
               allocation_order: allocation_order
             },
             {:ok, _allocation} <- Repo.insert(CashAllocation.changeset(%CashAllocation{}, attrs)),
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

  defp transfer_funding(source_group, destination_group, amount) do
    with {:ok, funding} <- drawn_funding(source_group, amount),
         :ok <- remove_transferred_funding(funding),
         {:ok, segments} <- transfer_room_segments(destination_group.rooms, funding),
         {:ok, cash_payment_ids} <- insert_transferred_funding(destination_group, segments) do
      transferred_cash_cents =
        Enum.sum_by(funding, fn
          {:cash, _allocation, moved} -> moved
          {:credit, _application, _moved} -> 0
        end)

      {:ok, cash_payment_ids, transferred_cash_cents}
    end
  end

  defp drawn_funding(source_group, amount) do
    room_ids = Enum.map(source_group.rooms, & &1.id)

    cash_allocations =
      Repo.all(
        from(allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.id in ^room_ids and room.status == "active",
          select: allocation
        )
      )
      |> Enum.map(&{:cash, &1, &1.amount_cents})

    credit_applications =
      Repo.all(
        from(application in CreditApplication,
          join: room in Room,
          on: room.id == application.room_id,
          where:
            application.group_id == ^source_group.id and room.id in ^room_ids and
              room.status == "active",
          select: application
        )
      )
      |> Enum.map(&{:credit, &1, &1.amount_cents})

    {funding, remaining} =
      (cash_allocations ++ credit_applications)
      |> Enum.sort_by(fn {kind, allocation, _amount} ->
        {-(allocation.allocation_order || 0), kind, -allocation.id}
      end)
      |> Enum.reduce_while({[], amount}, fn {kind, allocation, available}, {drawn, remaining} ->
        moved = min(available, remaining)
        next_drawn = [{kind, allocation, moved} | drawn]

        if moved == remaining do
          {:halt, {next_drawn, 0}}
        else
          {:cont, {next_drawn, remaining - moved}}
        end
      end)

    if remaining == 0 do
      {:ok, Enum.reverse(funding)}
    else
      {:error, "transfer_exceeds_held_funding", %{}}
    end
  end

  defp remove_transferred_funding(funding) do
    Enum.reduce_while(funding, :ok, fn
      {:cash, allocation, amount}, :ok ->
        case remove_cash_allocation(allocation, amount) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {:credit, application, amount}, :ok ->
        case remove_credit_application(application, amount) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
  end

  defp remove_cash_allocation(allocation, amount) do
    result =
      if amount == allocation.amount_cents do
        case Repo.delete(allocation) do
          {:ok, _allocation} -> :ok
          {:error, _changeset} -> :error
        end
      else
        case Repo.update(
               CashAllocation.changeset(allocation, %{
                 amount_cents: allocation.amount_cents - amount
               })
             ) do
          {:ok, _allocation} -> :ok
          {:error, _changeset} -> :error
        end
      end

    with :ok <- result,
         {1, _} <-
           Repo.update_all(from(room in Room, where: room.id == ^allocation.room_id),
             inc: [cash_paid_cents: -amount]
           ) do
      :ok
    else
      _ -> {:error, "invalid_operation", %{}}
    end
  end

  defp remove_credit_application(application, amount) do
    result =
      if amount == application.amount_cents do
        case Repo.delete(application) do
          {:ok, _application} -> :ok
          {:error, _changeset} -> :error
        end
      else
        case Repo.update(
               CreditApplication.changeset(application, %{
                 amount_cents: application.amount_cents - amount
               })
             ) do
          {:ok, _application} -> :ok
          {:error, _changeset} -> :error
        end
      end

    with :ok <- result,
         {1, _} <-
           Repo.update_all(from(room in Room, where: room.id == ^application.room_id),
             inc: [credit_paid_cents: -amount]
           ) do
      :ok
    else
      _ -> {:error, "invalid_operation", %{}}
    end
  end

  defp transfer_room_segments(rooms, funding) do
    {remaining, segments} =
      Enum.reduce(rooms, {funding, []}, fn room, {sources, segments} ->
        {next_sources, room_segments} =
          consume_transfer_sources(sources, active_room_capacity(room), [])

        {next_sources,
         segments ++
           Enum.map(room_segments, fn {kind, allocation, amount} ->
             {room, kind, allocation, amount}
           end)}
      end)

    if remaining == [], do: {:ok, segments}, else: {:error, "invalid_operation", %{}}
  end

  defp consume_transfer_sources(sources, 0, segments), do: {sources, Enum.reverse(segments)}
  defp consume_transfer_sources([], _capacity, segments), do: {[], Enum.reverse(segments)}

  defp consume_transfer_sources([{kind, allocation, available} | rest], capacity, segments) do
    applied = min(available, capacity)

    next_sources =
      if applied == available,
        do: rest,
        else: [{kind, allocation, available - applied} | rest]

    consume_transfer_sources(
      next_sources,
      capacity - applied,
      [{kind, allocation, applied} | segments]
    )
  end

  defp insert_transferred_funding(destination_group, segments) do
    Enum.reduce_while(segments, {:ok, MapSet.new()}, fn
      {room, :cash, allocation, amount}, {:ok, payment_ids} ->
        with {:ok, allocation_order} <- next_allocation_order(),
             {:ok, _allocation} <-
               Repo.insert(
                 CashAllocation.changeset(%CashAllocation{}, %{
                   room_id: room.id,
                   payment_operation_id: allocation.payment_operation_id,
                   amount_cents: amount,
                   allocation_order: allocation_order
                 })
               ),
             {1, _} <-
               Repo.update_all(from(current in Room, where: current.id == ^room.id),
                 inc: [cash_paid_cents: amount]
               ) do
          next_payment_ids =
            if is_binary(allocation.payment_operation_id) do
              MapSet.put(payment_ids, allocation.payment_operation_id)
            else
              payment_ids
            end

          {:cont, {:ok, next_payment_ids}}
        else
          _ -> {:halt, {:error, "invalid_operation", %{}}}
        end

      {room, :credit, application, amount}, {:ok, payment_ids} ->
        with {:ok, allocation_order} <- next_allocation_order(),
             {:ok, _application} <-
               Repo.insert(
                 CreditApplication.changeset(%CreditApplication{}, %{
                   group_id: destination_group.id,
                   room_id: room.id,
                   credit_lot_id: application.credit_lot_id,
                   amount_cents: amount,
                   allocation_order: allocation_order
                 })
               ),
             {1, _} <-
               Repo.update_all(from(current in Room, where: current.id == ^room.id),
                 inc: [credit_paid_cents: amount]
               ) do
          {:cont, {:ok, payment_ids}}
        else
          _ -> {:halt, {:error, "invalid_operation", %{}}}
        end
    end)
    |> case do
      {:ok, payment_ids} -> {:ok, MapSet.to_list(payment_ids)}
      error -> error
    end
  end

  defp mark_transferred_cash_payments([]), do: :ok

  defp mark_transferred_cash_payments(payment_operation_ids) do
    {updated, _} =
      Repo.update_all(
        from(disposition in CashPaymentDisposition,
          where: disposition.payment_operation_id in ^payment_operation_ids
        ),
        set: [has_transferred_funding: true]
      )

    if updated == length(payment_operation_ids),
      do: :ok,
      else: {:error, "invalid_operation", %{}}
  end

  defp next_allocation_order do
    case Repo.insert(%AllocationSequence{}) do
      {:ok, sequence} -> {:ok, sequence.id}
      {:error, _changeset} -> {:error, "invalid_operation", %{}}
    end
  end

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
      with {:ok, allocation_order} <- next_allocation_order(),
           attrs = %{
             group_id: group.id,
             room_id: room.id,
             credit_lot_id: lot.id,
             amount_cents: amount,
             allocation_order: allocation_order
           },
           {:ok, _application} <-
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

  defp remove_cash_allocations(_payment_operation_id, 0), do: {:ok, %{}}

  defp remove_cash_allocations(payment_operation_id, amount) do
    allocations =
      Repo.all(
        from(allocation in CashAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: allocation.payment_operation_id == ^payment_operation_id,
          order_by: [desc: allocation.allocation_order, desc: allocation.id],
          select: {allocation, room.group_id}
        )
      )

    {remaining, affected_groups, result} =
      Enum.reduce_while(allocations, {amount, %{}, :ok}, fn {allocation, group_id},
                                                            {remaining, affected_groups, :ok} ->
        removed = min(remaining, allocation.amount_cents)

        case remove_cash_allocation(allocation, removed) do
          :ok ->
            next_affected_groups = Map.update(affected_groups, group_id, removed, &(&1 + removed))

            if remaining == removed do
              {:halt, {0, next_affected_groups, :ok}}
            else
              {:cont, {remaining - removed, next_affected_groups, :ok}}
            end

          _error ->
            {:halt, {remaining, affected_groups, :error}}
        end
      end)

    if result == :ok and remaining == 0,
      do: {:ok, affected_groups},
      else: {:error, "invalid_operation", %{}}
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

  defp charge_back_payment_settlements(payment_operation_id) do
    Repo.all(
      from(settlement in CashPaymentSettlement,
        where: settlement.payment_operation_id == ^payment_operation_id
      )
    )
    |> Enum.reduce_while({:ok, %{}}, fn settlement, {:ok, deltas} ->
      attrs = %{refunded_cents: 0, retained_cents: 0, converted_to_credit_cents: 0}

      case Repo.update(CashPaymentSettlement.changeset(settlement, attrs)) do
        {:ok, _settlement} ->
          settlement_delta = %{
            cash_refunded_cents: -settlement.refunded_cents,
            cash_retained_cents: -settlement.retained_cents,
            cash_converted_to_credit_cents: -settlement.converted_to_credit_cents,
            cash_charged_back_cents:
              settlement.refunded_cents + settlement.retained_cents +
                settlement.converted_to_credit_cents
          }

          {:cont,
           {:ok, merge_group_counter_deltas(deltas, settlement.group_id, settlement_delta)}}

        {:error, _changeset} ->
          {:halt, {:error, "invalid_operation", %{}}}
      end
    end)
  end

  defp add_held_charge_back_deltas(deltas, held_groups) do
    Enum.reduce(held_groups, deltas, fn {group_id, amount}, current_deltas ->
      merge_group_counter_deltas(current_deltas, group_id, %{cash_charged_back_cents: amount})
    end)
  end

  defp merge_group_counter_deltas(deltas, group_id, additions) do
    Map.update(deltas, group_id, additions, fn current ->
      Map.merge(current, additions, fn _field, left, right -> left + right end)
    end)
  end

  defp sync_cash_change_groups(addressed_group, affected_groups, counter_deltas, operation) do
    group_ids =
      [addressed_group.id | Map.keys(affected_groups) ++ Map.keys(counter_deltas)]
      |> Enum.uniq()

    Enum.reduce_while(group_ids, {:ok, %{}}, fn group_id, {:ok, updated_groups} ->
      group =
        if group_id == addressed_group.id do
          addressed_group
        else
          Repo.get(Group, group_id)
        end

      if group do
        attrs = counter_attrs(group, Map.get(counter_deltas, group_id, %{}))
        expected_key = if group_id == addressed_group.id, do: "expected_revision", else: nil

        case sync_group(group, attrs, operation, expected_key) do
          {:ok, updated_group} ->
            {:cont, {:ok, Map.put(updated_groups, group_id, updated_group)}}

          error ->
            {:halt, error}
        end
      else
        {:halt, {:error, "invalid_operation", %{}}}
      end
    end)
  end

  defp counter_attrs(group, deltas) do
    Enum.reduce(deltas, %{}, fn {field, amount}, attrs ->
      Map.put(attrs, field, Map.fetch!(group, field) + amount)
    end)
  end

  defp revoke_credit_entitlements(payment_operation_id) do
    Repo.all(
      from(contribution in CreditLotContribution,
        where: contribution.payment_operation_id == ^payment_operation_id,
        order_by: contribution.id
      )
    )
    |> Enum.reduce_while({:ok, []}, fn contribution, {:ok, revoked} ->
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
            {:ok, _lot} -> {:cont, {:ok, [{lot, removed} | revoked]}}
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

  defp sync_group(group, extra_attrs, operation, expected_key \\ "expected_revision") do
    update_group(
      group,
      Map.merge(active_group_attrs(group.id), extra_attrs),
      operation,
      expected_key
    )
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

  defp update_group(group, attrs, operation, expected_key \\ "expected_revision") do
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
      update_conflict(operation, group, expected_key)
    end
  end

  defp update_conflict(operation, group, expected_key) do
    if expected_key && Map.has_key?(operation, expected_key) do
      actual_revision =
        case Repo.get_by(Group, group_id: group.group_id) do
          nil -> group.revision
          current_group -> current_group.revision
        end

      {:error, "stale_revision",
       stale_fields(operation, actual_revision, group.group_id, expected_key)}
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
    data = %{
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

    if disposition.has_transferred_funding do
      Map.put(data, "held_by_group", held_cash_by_group(disposition.payment_operation_id))
    else
      data
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from(allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.group_id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and room.status == "active" and
            group.status == "active",
        group_by: group.group_id,
        order_by: group.group_id,
        select: {group.group_id, sum(allocation.amount_cents)}
      )
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
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

  defp stale_fields(operation, actual_revision, group_id, expected_key) do
    %{
      "group_id" => group_id,
      "expected_revision" => Map.get(operation, expected_key),
      "actual_revision" => actual_revision
    }
  end
end
