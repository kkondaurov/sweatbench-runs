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
    Repo
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

  def ledger_totals(on_date \\ utc_today()) do
    cash_totals =
      GroupReservation
      |> group_by([group], group.status)
      |> select([group], {
        group.status,
        coalesce(sum(group.cash_paid_cents), 0),
        coalesce(sum(group.refunded_cents), 0),
        coalesce(sum(group.retained_cents), 0),
        coalesce(sum(group.cash_converted_to_credit_cents), 0)
      })
      |> Repo.all()
      |> Enum.reduce(empty_ledger(), fn {status, paid, refunded, retained, converted}, totals ->
        totals
        |> put_active_cash(status, paid)
        |> Map.update!("cash_refunded_cents", &(&1 + refunded))
        |> Map.update!("cash_retained_cents", &(&1 + retained))
        |> Map.update!("cash_converted_to_credit_cents", &(&1 + converted))
      end)

    Map.put(
      cash_totals,
      "credit_liability_cents",
      available_credit_total(on_date) + active_applied_credit_total()
    )
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
      case redeem_credit(group, amount_cents, occurred_on) do
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
      refundable? = refundable_cancellation?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable? do
        {:rejected, rejected(operation, "refund_method_not_available")}
      else
        refunded_cents =
          if refundable? and refund_method == "cash", do: group.cash_paid_cents, else: 0

        retained_cents = if refundable?, do: 0, else: group.cash_paid_cents

        credit_issued_cents =
          if refundable? and refund_method == "hotel_credit",
            do: credit_value(group.cash_paid_cents),
            else: 0

        cash_converted_to_credit_cents =
          if refundable? and refund_method == "hotel_credit", do: group.cash_paid_cents, else: 0

        case settle_credit(group, occurred_on, refundable?, credit_issued_cents, operation_id) do
          :ok ->
            case update_group(group, %{
                   status: "cancelled",
                   deposit_due_cents: 0,
                   refunded_cents: refunded_cents,
                   retained_cents: retained_cents,
                   cash_converted_to_credit_cents: cash_converted_to_credit_cents
                 }) do
              :ok ->
                {:applied,
                 applied(operation_id, %{
                   "group_id" => group.group_id,
                   "refunded_cents" => refunded_cents,
                   "retained_cents" => retained_cents,
                   "credit_issued_cents" => credit_issued_cents,
                   "revision" => group.revision + 1
                 })}

              :conflict ->
                conflict_result(operation, group)
            end

          :conflict ->
            conflict_result(operation, group)

          :error ->
            {:rejected, rejected(operation, "invalid_operation")}
        end
      end
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
      nil -> {:rejected, group_not_found(operation, operation["group_id"])}
      {:error, result} when is_map(result) -> {:rejected, result}
      {:error, "group_not_active"} -> {:rejected, rejected(operation, "group_not_active")}
      {:error, "invalid_refund_method"} -> {:rejected, rejected(operation, "invalid_operation")}
    end
  end

  defp redeem_credit(group, amount_cents, occurred_on) do
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

          case deduct_lot_and_record_application(group, lot, applied_cents) do
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

  defp deduct_lot_and_record_application(group, lot, amount_cents) do
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
                 amount_cents: amount_cents
               })
             ) do
          {:ok, _application} -> :ok
          {:error, _changeset} -> :error
        end

      {0, _} ->
        :conflict
    end
  end

  defp settle_credit(group, occurred_on, refundable?, credit_issued_cents, operation_id) do
    with :ok <- maybe_restore_credit(group, occurred_on, refundable?),
         :ok <- issue_credit_lot(group, occurred_on, credit_issued_cents, operation_id) do
      :ok
    else
      :conflict -> :conflict
      _ -> :error
    end
  end

  defp maybe_restore_credit(_group, _occurred_on, false), do: :ok

  defp maybe_restore_credit(group, occurred_on, true) do
    group.id
    |> credit_restorations()
    |> Enum.reduce_while(:ok, fn {lot, applied_cents}, :ok ->
      if expired_on?(lot, occurred_on) do
        {:cont, :ok}
      else
        case Repo.update_all(
               from(row in CreditLot,
                 where: row.id == ^lot.id and row.remaining_cents == ^lot.remaining_cents
               ),
               set: [
                 remaining_cents: lot.remaining_cents + applied_cents,
                 updated_at: now()
               ]
             ) do
          {1, _} -> {:cont, :ok}
          {0, _} -> {:halt, :conflict}
        end
      end
    end)
  end

  defp issue_credit_lot(_group, _occurred_on, 0, _operation_id), do: :ok

  defp issue_credit_lot(group, occurred_on, credit_issued_cents, operation_id) do
    expires_on = Date.add(occurred_on, @credit_available_days + 1)

    case Repo.insert(
           CreditLot.create_changeset(%CreditLot{}, %{
             guest_id: group.guest_id,
             source_operation_id: operation_id,
             remaining_cents: credit_issued_cents,
             expires_on: expires_on
           })
         ) do
      {:ok, _lot} -> :ok
      {:error, _changeset} -> :error
    end
  end

  defp credit_applications_with_lots(group_reservation_id) do
    Repo.all(
      from(application in CreditApplication,
        join: lot in CreditLot,
        on: lot.id == application.credit_lot_id,
        where: application.group_reservation_id == ^group_reservation_id,
        select: {application, lot}
      )
    )
  end

  defp credit_restorations(group_reservation_id) do
    group_reservation_id
    |> credit_applications_with_lots()
    |> Enum.reduce(%{}, fn {application, lot}, restorations ->
      Map.update(
        restorations,
        lot.id,
        {lot, application.amount_cents},
        fn {lot, amount_cents} ->
          {lot, amount_cents + application.amount_cents}
        end
      )
    end)
    |> Map.values()
  end

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
          nightly_rate_cents: room.nightly_rate_cents
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
          %{"room_id" => room.room_id, "nightly_rate_cents" => room.nightly_rate_cents}
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
      "credit_liability_cents" => 0
    }
  end

  defp put_active_cash(totals, "active", cash_paid_cents),
    do: Map.update!(totals, "cash_held_cents", &(&1 + cash_paid_cents))

  defp put_active_cash(totals, _status, _cash_paid_cents), do: totals

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
      from(group in GroupReservation,
        where: group.status == "active",
        select: coalesce(sum(group.credit_paid_cents), 0)
      )
    )
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
