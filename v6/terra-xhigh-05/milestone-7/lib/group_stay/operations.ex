defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations one at a time. Each mutation is conditional on the
  revision that was read, so a concurrent update cannot silently overwrite it.
  """

  import Ecto.Query

  alias GroupStay.CancellationPolicy
  alias GroupStay.Finance
  alias GroupStay.Groups

  alias GroupStay.Groups.{
    CashPayment,
    CashPaymentDisposition,
    CashRoomAllocation,
    CreditApplication,
    CreditLot,
    CreditLotContribution,
    Group,
    Room,
    RoomCreditAllocation
  }

  alias GroupStay.Operations.PartnerOperation
  alias GroupStay.Repo

  @max_cents 9_223_372_036_854_775_807
  @retry_attempts 3

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def process_operation(operation) when is_map(operation) do
    if valid_identifier?(operation["operation_id"]) do
      process_durably(operation)
    else
      apply_operation(operation)
    end
  end

  def process_operation(_operation),
    do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  def get_operation(operation_id) when is_binary(operation_id) do
    Repo.get_by(PartnerOperation, operation_id: operation_id)
  end

  def get_operation(_operation_id), do: nil

  def payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      operation ->
        case {applied_cash_payment?(operation),
              Repo.get_by(CashPayment, payment_operation_id: payment_operation_id)} do
          {true, %CashPayment{} = payment} ->
            statement =
              %{
                payment_operation_id: payment.payment_operation_id,
                original_group_id: original_group_id(payment),
                recorded_cents: payment.recorded_cents,
                held_cents: held_cash_for_payment(payment.id),
                refunded_cents: payment.refunded_cents,
                retained_cents: payment.retained_cents,
                converted_to_credit_cents: payment.converted_to_credit_cents,
                reduced_cents: payment.reduced_cents,
                charged_back_cents: payment.charged_back_cents
              }

            {:ok, payment_statement_transfer_detail(statement, payment)}

          _ ->
            :not_reconcilable
        end
    end
  end

  def payment_statement(_payment_operation_id), do: :not_found

  # An IMMEDIATE transaction acquires SQLite's writer lock before looking up the
  # idempotency record. That serializes first attempts and concurrent retries,
  # so only one transaction can run the domain mutation for an identifier.
  defp process_durably(operation) do
    fingerprint = payload_fingerprint(operation)

    {:ok, result} =
      Repo.transaction(
        fn ->
          case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
            nil ->
              reporting_snapshot =
                case Finance.reporting() do
                  nil -> nil
                  _setting -> Finance.snapshot()
                end

              result = apply_operation(operation)

              if applied_result?(result) and reporting_snapshot != nil and
                   operation["type"] not in ["start_finance_reporting", "close_finance_period"] do
                Finance.record_operation(operation, result, reporting_snapshot)
              end

              %PartnerOperation{}
              |> PartnerOperation.changeset(%{
                operation_id: operation["operation_id"],
                operation_type: operation_type(operation),
                submitted_payload: operation,
                payload_fingerprint: fingerprint,
                result: result
              })
              |> Repo.insert!()

              result

            %PartnerOperation{payload_fingerprint: ^fingerprint} = remembered ->
              remembered.result

            %PartnerOperation{} ->
              rejected(operation, "operation_id_conflict")
          end
        end,
        mode: :immediate
      )

    result
  end

  defp apply_operation(operation) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation, @retry_attempts)
      "reschedule_group" -> reschedule_group(operation, @retry_attempts)
      "cancel_group" -> cancel_group(operation, @retry_attempts)
      "cancel_rooms" -> cancel_rooms(operation, @retry_attempts)
      "apply_hotel_credit" -> apply_hotel_credit(operation, @retry_attempts)
      "reduce_cash_payment" -> reduce_cash_payment(operation, @retry_attempts)
      "charge_back_payment" -> charge_back_payment(operation, @retry_attempts)
      "transfer_deposit" -> transfer_deposit(operation, @retry_attempts)
      "start_finance_reporting" -> start_finance_reporting(operation)
      "close_finance_period" -> close_finance_period(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp start_finance_reporting(operation) do
    with :ok <- operation_id(operation),
         {:ok, starts_on} <- reporting_start_date(operation),
         :ok <- Finance.start_reporting(starts_on) do
      %{
        operation_id: operation["operation_id"],
        status: "applied",
        starts_on: Date.to_iso8601(starts_on)
      }
    else
      {:error, "reporting_already_started"} -> rejected(operation, "reporting_already_started")
      {:error, "invalid_reporting_date"} -> rejected(operation, "invalid_reporting_date")
      {:error, :invalid_operation} -> rejected(operation, "invalid_operation")
    end
  end

  defp close_finance_period(operation) do
    with :ok <- operation_id(operation),
         {:ok, period_end_on} <- finance_period_end_date(operation),
         :ok <- Finance.close_period(period_end_on) do
      %{
        operation_id: operation["operation_id"],
        status: "applied",
        period_end_on: Date.to_iso8601(period_end_on)
      }
    else
      {:error, "invalid_period"} -> rejected(operation, "invalid_period")
      {:error, :invalid_operation} -> rejected(operation, "invalid_operation")
    end
  end

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
        case record_cash(group, operation["operation_id"], amount_cents) do
          {:ok, outstanding_deposit_cents} ->
            %{
              operation_id: operation["operation_id"],
              status: "applied",
              group_id: group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents: outstanding_deposit_cents,
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
        room_ids = active_rooms(group) |> Enum.map(& &1.room_id)

        case settle_rooms(group, room_ids, operation["operation_id"], occurred_on, refund_method) do
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

  defp cancel_rooms(operation, attempts) do
    with_group(operation, fn group ->
      with {:ok, occurred_on} <- common_date(operation),
           :ok <- active(group),
           {:ok, room_ids} <- room_identifiers(operation),
           {:ok, rooms} <- selected_active_rooms(group, room_ids),
           {:ok, refund_method} <- refund_method(operation),
           :ok <- refund_method_available(group, occurred_on, refund_method) do
        ordered_room_ids = Enum.map(rooms, & &1.room_id)

        case settle_rooms(
               group,
               ordered_room_ids,
               operation["operation_id"],
               occurred_on,
               refund_method
             ) do
          {:ok, result} ->
            Map.merge(
              %{
                operation_id: operation["operation_id"],
                status: "applied",
                group_id: group.group_id,
                cancelled_room_ids: ordered_room_ids,
                revision: group.revision + 1
              },
              result
            )

          :conflict ->
            retry(operation, attempts, &cancel_rooms/2)
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
        case redeem_credit(group, operation["operation_id"], allocations, amount_cents) do
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

  defp reduce_cash_payment(operation, attempts) do
    with_target_cash_payment(operation, "payment_not_reducible", fn payment, group ->
      with {:ok, amount_cents} <- payment_amount(operation),
           held_cents when held_cents > 0 <- held_cash_for_payment(payment.id),
           :ok <- reduction_within_held(amount_cents, held_cents) do
        case reduce_held_cash(group, payment, amount_cents) do
          {:ok, outstanding_deposit_cents} ->
            %{
              operation_id: operation["operation_id"],
              status: "applied",
              payment_operation_id: payment.payment_operation_id,
              group_id: group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents: outstanding_deposit_cents,
              revision: group.revision + 1
            }

          :conflict ->
            retry(operation, attempts, &reduce_cash_payment/2)
        end
      else
        0 -> rejected(operation, "payment_not_reducible")
        {:error, code} -> rejected(operation, code)
      end
    end)
  end

  defp charge_back_payment(operation, attempts) do
    with_target_cash_payment(operation, "payment_not_chargeable", fn payment, group ->
      charged_back_cents = remaining_payment_cents(payment)

      if charged_back_cents > 0 do
        case charge_back(group, payment, charged_back_cents) do
          {:ok, outstanding_deposit_cents} ->
            %{
              operation_id: operation["operation_id"],
              status: "applied",
              payment_operation_id: payment.payment_operation_id,
              group_id: group.group_id,
              charged_back_cents: charged_back_cents,
              outstanding_deposit_cents: outstanding_deposit_cents,
              revision: group.revision + 1
            }

          :conflict ->
            retry(operation, attempts, &charge_back_payment/2)
        end
      else
        rejected(operation, "payment_not_chargeable")
      end
    end)
  end

  defp transfer_deposit(operation, attempts) do
    with :ok <- operation_id(operation),
         {:ok, source} <- transfer_group(operation, "source_group_id"),
         {:ok, destination} <- transfer_group(operation, "destination_group_id"),
         :ok <- expected_revision(operation, source),
         :ok <- expected_revision(operation, destination, "destination_expected_revision"),
         :ok <- valid_transfer(source, destination),
         :ok <- active_for_transfer(source),
         :ok <- active_for_transfer(destination),
         {:ok, amount_cents} <- payment_amount(operation),
         :ok <- transfer_within_held_funding(source, amount_cents),
         :ok <- transfer_within_outstanding(destination, amount_cents) do
      case move_held_funding(source, destination, amount_cents) do
        {:ok, {source_outstanding_deposit_cents, destination_outstanding_deposit_cents}} ->
          %{
            operation_id: operation["operation_id"],
            status: "applied",
            source_group_id: source.group_id,
            destination_group_id: destination.group_id,
            amount_cents: amount_cents,
            source_outstanding_deposit_cents: source_outstanding_deposit_cents,
            destination_outstanding_deposit_cents: destination_outstanding_deposit_cents,
            source_revision: source.revision + 1,
            destination_revision: destination.revision + 1
          }

        :conflict ->
          retry(operation, attempts, &transfer_deposit/2)
      end
    else
      {:error, {:group_not_found, group_id}} ->
        rejected(operation, "group_not_found", %{group_id: group_id})

      {:error, :invalid_operation} ->
        rejected(operation, "invalid_operation")

      {:error, {:stale_revision, group, field}} ->
        rejected(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation[field],
          actual_revision: group.revision
        })

      {:error, {:group_not_active, group_id}} ->
        rejected(operation, "group_not_active", %{group_id: group_id})

      {:error, code} when is_binary(code) ->
        rejected(operation, code)
    end
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

      {:error, {:stale_revision, group, field}} ->
        rejected(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation[field],
          actual_revision: group.revision
        })
    end
  end

  defp with_target_cash_payment(operation, unavailable_code, action) do
    with :ok <- operation_id(operation),
         {:ok, payment_operation_id} <- payment_operation_identifier(operation),
         {:ok, payment, group} <- target_cash_payment(payment_operation_id, unavailable_code),
         :ok <- expected_revision(operation, group) do
      action.(payment, group)
    else
      {:error, code} when is_binary(code) ->
        rejected(operation, code)

      {:error, :invalid_operation} ->
        rejected(operation, "invalid_operation")

      {:error, {:stale_revision, group, field}} ->
        rejected(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation[field],
          actual_revision: group.revision
        })
    end
  end

  defp target_cash_payment(payment_operation_id, unavailable_code) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        {:error, "operation_not_found"}

      operation ->
        if applied_cash_payment?(operation) do
          case Repo.get_by(CashPayment, payment_operation_id: payment_operation_id) do
            nil ->
              {:error, unavailable_code}

            payment ->
              case Repo.get(Group, payment.reservation_id) do
                nil -> {:error, "group_not_found"}
                group -> {:ok, payment, group}
              end
          end
        else
          {:error, unavailable_code}
        end
    end
  end

  defp applied_cash_payment?(%PartnerOperation{
         operation_type: "record_cash_payment",
         result: result
       }) do
    map_value(result, :status) == "applied"
  end

  defp applied_cash_payment?(_operation), do: false

  defp original_group_id(payment) do
    case Repo.get(Group, payment.reservation_id) do
      nil -> nil
      group -> group.group_id
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
    if Repo.in_transaction?() do
      insert_group_records(attrs, rooms)
    else
      Repo.transaction(fn -> insert_group_records(attrs, rooms) end)
      |> case do
        {:ok, result} -> result
        {:error, code} -> {:error, code}
      end
    end
  end

  defp insert_group_records(attrs, rooms) do
    case Repo.insert(Group.changeset(%Group{}, attrs)) do
      {:ok, group} ->
        Enum.each(rooms, fn room ->
          room
          |> Map.put(:reservation_id, group.id)
          |> then(&Room.changeset(%Room{}, &1))
          |> Repo.insert!()
        end)

        {:ok, group}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :group_id) do
          {:error, "group_already_exists"}
        else
          {:error, "invalid_operation"}
        end
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
    if Map.has_key?(operation, "expected_revision") or
         Map.has_key?(operation, "destination_expected_revision") do
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

  defp transfer_group(operation, field) do
    case operation[field] do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        case Repo.get_by(Group, group_id: group_id) do
          %Group{} = group -> {:ok, group}
          nil -> {:error, {:group_not_found, group_id}}
        end

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp payment_operation_identifier(operation) do
    case operation["payment_operation_id"] do
      payment_operation_id
      when is_binary(payment_operation_id) and byte_size(payment_operation_id) > 0 ->
        {:ok, payment_operation_id}

      _ ->
        {:error, :invalid_operation}
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

  defp expected_revision(operation, group),
    do: expected_revision(operation, group, "expected_revision")

  defp expected_revision(operation, group, field) do
    case Map.fetch(operation, field) do
      :error ->
        :ok

      {:ok, revision} when is_integer(revision) and revision > 0 and revision == group.revision ->
        :ok

      {:ok, revision} when is_integer(revision) and revision > 0 ->
        {:error, {:stale_revision, group, field}}

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

  defp reporting_start_date(operation) do
    case Map.fetch(operation, "starts_on") do
      {:ok, starts_on} ->
        case parse_date(starts_on) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_reporting_date"}
        end

      :error ->
        {:error, "invalid_reporting_date"}
    end
  end

  defp finance_period_end_date(operation) do
    case Map.fetch(operation, "period_end_on") do
      {:ok, period_end_on} ->
        case parse_date(period_end_on) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "invalid_period"}
        end

      :error ->
        {:error, "invalid_period"}
    end
  end

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
            room_attrs = %{
              room_id: room_id,
              nightly_rate_cents: rate,
              position: position,
              status: "active",
              lodging_total_cents: room_lodging,
              deposit_due_cents: room_deposit,
              cash_paid_cents: 0,
              credit_paid_cents: 0
            }

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

  defp valid_transfer(source, destination) do
    if source.id != destination.id and source.guest_id == destination.guest_id,
      do: :ok,
      else: {:error, "invalid_transfer"}
  end

  defp active_for_transfer(%Group{status: "active"}), do: :ok

  defp active_for_transfer(%Group{} = group),
    do: {:error, {:group_not_active, group.group_id}}

  defp transfer_within_held_funding(source, amount_cents) do
    if held_funding(source.id) >= amount_cents,
      do: :ok,
      else: {:error, "transfer_exceeds_held_funding"}
  end

  defp transfer_within_outstanding(destination, amount_cents) do
    if Groups.outstanding_deposit(destination) >= amount_cents,
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp held_funding(group_id) do
    held_cash =
      Repo.one(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.reservation_id == ^group_id and room.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
        )
      )

    held_credit =
      Repo.one(
        from(allocation in RoomCreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.reservation_id == ^group_id and room.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
        )
      )

    held_cash + held_credit
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

  defp record_cash(group, operation_id, amount_cents) do
    case Repo.transaction(fn ->
           payment =
             %CashPayment{}
             |> CashPayment.changeset(%{
               reservation_id: group.id,
               payment_operation_id: operation_id,
               recorded_cents: amount_cents
             })
             |> Repo.insert!()

           :ok = allocate_cash_to_rooms(group, payment.id, amount_cents)

           case conditional_update(group,
                  deposit_paid_cents: group.deposit_paid_cents + amount_cents,
                  cash_paid_cents: group.cash_paid_cents + amount_cents
                ) do
             :ok -> group.deposit_due_cents - group.deposit_paid_cents - amount_cents
             :conflict -> Repo.rollback(:conflict)
           end
         end) do
      {:ok, outstanding_deposit_cents} -> {:ok, outstanding_deposit_cents}
      {:error, :conflict} -> :conflict
    end
  end

  defp settle_rooms(group, room_ids, source_operation_id, occurred_on, refund_method) do
    case Repo.transaction(fn ->
           {:ok, rooms} = selected_active_rooms(group, room_ids)
           room_record_ids = Enum.map(rooms, & &1.id)
           cash_allocations = cash_allocations_for_rooms(room_record_ids)
           credit_allocations = credit_room_allocations_for_rooms(room_record_ids)
           cash_paid_cents = Enum.sum_by(cash_allocations, & &1.amount_cents)
           credit_paid_cents = Enum.sum_by(credit_allocations, & &1.amount_cents)

           {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
             cancellation_amounts(group, occurred_on, refund_method, cash_paid_cents)

           settle_cash_allocations(
             cash_allocations,
             group.id,
             refund_method,
             refundable?(group, occurred_on)
           )

           settle_credit_allocations(
             credit_allocations,
             refundable?(group, occurred_on),
             occurred_on
           )

           Repo.delete_all(
             from(allocation in CashRoomAllocation, where: allocation.room_id in ^room_record_ids)
           )

           Repo.delete_all(
             from(allocation in RoomCreditAllocation,
               where: allocation.room_id in ^room_record_ids
             )
           )

           Repo.update_all(
             from(room in Room, where: room.id in ^room_record_ids),
             set: [status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0]
           )

           if credit_issued_cents > 0 do
             create_credit_lot(
               group,
               source_operation_id,
               occurred_on,
               cash_allocations,
               credit_issued_cents
             )
           end

           active_rooms_remaining =
             Repo.aggregate(
               from(room in Room,
                 where: room.reservation_id == ^group.id and room.status == "active"
               ),
               :count
             )

           changes = %{
             lodging_total_cents:
               group.lodging_total_cents - Enum.sum_by(rooms, & &1.lodging_total_cents),
             deposit_due_cents:
               group.deposit_due_cents - Enum.sum_by(rooms, & &1.deposit_due_cents),
             deposit_paid_cents: group.deposit_paid_cents - cash_paid_cents - credit_paid_cents,
             cash_paid_cents: group.cash_paid_cents - cash_paid_cents,
             credit_paid_cents: group.credit_paid_cents - credit_paid_cents,
             status: if(active_rooms_remaining == 0, do: "cancelled", else: "active"),
             cancelled_refunded_cents: group.cancelled_refunded_cents + refunded_cents,
             cancelled_retained_cents: group.cancelled_retained_cents + retained_cents,
             cancelled_cash_converted_to_credit_cents:
               group.cancelled_cash_converted_to_credit_cents + converted_cents
           }

           case conditional_update(group, Map.to_list(changes)) do
             :ok ->
               %{
                 refunded_cents: refunded_cents,
                 retained_cents: retained_cents,
                 credit_issued_cents: credit_issued_cents
               }

             :conflict ->
               Repo.rollback(:conflict)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :conflict} -> :conflict
    end
  end

  defp cancellation_amounts(group, occurred_on, refund_method, cash_paid_cents) do
    if refundable?(group, occurred_on) do
      case refund_method do
        "cash" -> {cash_paid_cents, 0, 0, 0}
        "hotel_credit" -> {0, 0, cash_paid_cents, issued_credit(cash_paid_cents)}
      end
    else
      {0, cash_paid_cents, 0, 0}
    end
  end

  defp create_credit_lot(group, source_operation_id, occurred_on, cash_allocations, issued_cents) do
    lot =
      %CreditLot{}
      |> CreditLot.changeset(%{
        guest_id: group.guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: issued_cents,
        expires_on: Date.add(occurred_on, 365),
        unrecovered_clawback_cents: 0
      })
      |> Repo.insert!()

    cash_allocations
    |> Enum.chunk_by(& &1.cash_payment_id)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {allocations, position}, preceding_principal ->
      principal_cents = Enum.sum_by(allocations, & &1.amount_cents)

      entitlement_cents =
        issued_credit(preceding_principal + principal_cents) - issued_credit(preceding_principal)

      %CreditLotContribution{}
      |> CreditLotContribution.changeset(%{
        credit_lot_id: lot.id,
        cash_payment_id: hd(allocations).cash_payment_id,
        principal_cents: principal_cents,
        entitlement_cents: entitlement_cents,
        position: position
      })
      |> Repo.insert!()

      preceding_principal + principal_cents
    end)
  end

  defp settle_cash_allocations(cash_allocations, reservation_id, refund_method, refundable?) do
    field =
      if refundable? do
        if refund_method == "cash", do: :refunded_cents, else: :converted_to_credit_cents
      else
        :retained_cents
      end

    cash_allocations
    |> Enum.reject(&is_nil(&1.cash_payment_id))
    |> Enum.group_by(& &1.cash_payment_id, & &1.amount_cents)
    |> Enum.each(fn {payment_id, amounts} ->
      amount_cents = Enum.sum(amounts)

      Repo.update_all(
        from(payment in CashPayment, where: payment.id == ^payment_id),
        inc: [{field, amount_cents}]
      )

      %CashPaymentDisposition{}
      |> CashPaymentDisposition.changeset(%{
        cash_payment_id: payment_id,
        reservation_id: reservation_id,
        kind: disposition_kind(field),
        amount_cents: amount_cents
      })
      |> Repo.insert!()
    end)
  end

  defp disposition_kind(:refunded_cents), do: "refunded"
  defp disposition_kind(:retained_cents), do: "retained"
  defp disposition_kind(:converted_to_credit_cents), do: "converted"

  defp settle_credit_allocations(credit_allocations, refundable?, occurred_on) do
    credit_allocations
    |> Enum.group_by(& &1.credit_application_id)
    |> Enum.each(fn {_application_id, allocations} ->
      amount_cents = Enum.sum_by(allocations, & &1.amount_cents)
      application = hd(allocations)

      Repo.update_all(
        from(current in CreditApplication,
          where: current.id == ^application.credit_application_id
        ),
        inc: [amount_cents: -amount_cents]
      )

      Repo.delete_all(
        from(current in CreditApplication,
          where: current.id == ^application.credit_application_id and current.amount_cents == 0
        )
      )

      if refundable? do
        restore_credit_to_lot(
          application.credit_lot_id,
          application.expires_on,
          amount_cents,
          occurred_on
        )
      end
    end)
  end

  defp restore_credit_to_lot(lot_id, expires_on, amount_cents, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed_cents = min(lot.unrecovered_clawback_cents, amount_cents)
    excess_cents = amount_cents - absorbed_cents

    available_cents =
      if Date.compare(expires_on, occurred_on) == :lt, do: 0, else: excess_cents

    Repo.update_all(
      from(current in CreditLot, where: current.id == ^lot_id),
      set: [
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents,
        remaining_cents: lot.remaining_cents + available_cents
      ]
    )
  end

  defp percentage_bonus(amount_cents), do: div(amount_cents * 10 + 50, 100)
  defp issued_credit(amount_cents), do: amount_cents + percentage_bonus(amount_cents)

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

  defp redeem_credit(group, operation_id, allocations, amount_cents) do
    case Repo.transaction(fn ->
           case debit_credit_lots(allocations) do
             :ok ->
               Enum.each(allocations, fn allocation ->
                 application =
                   %CreditApplication{}
                   |> CreditApplication.changeset(%{
                     reservation_id: group.id,
                     credit_lot_id: allocation.lot.id,
                     amount_cents: allocation.amount_cents,
                     source_operation_id: operation_id
                   })
                   |> Repo.insert!()

                 :ok = allocate_credit_to_rooms(group, application.id, allocation.amount_cents)
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

  defp active_rooms(group) do
    Repo.all(
      from(room in Room,
        where: room.reservation_id == ^group.id and room.status == "active",
        order_by: room.position
      )
    )
  end

  defp selected_active_rooms(group, room_ids) do
    rooms =
      Repo.all(
        from(room in Room,
          where:
            room.reservation_id == ^group.id and room.status == "active" and
              room.room_id in ^room_ids,
          order_by: room.position
        )
      )

    if length(rooms) == length(room_ids), do: {:ok, rooms}, else: {:error, "invalid_rooms"}
  end

  defp room_identifiers(operation) do
    case Map.fetch(operation, "room_ids") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &valid_identifier?/1) and
             MapSet.size(MapSet.new(room_ids)) == length(room_ids) do
          {:ok, room_ids}
        else
          {:error, "invalid_rooms"}
        end

      {:ok, _room_ids} ->
        {:error, "invalid_rooms"}
    end
  end

  defp allocate_cash_to_rooms(group, payment_id, amount_cents) do
    allocate_to_rooms(group, amount_cents, fn room, allocated_cents ->
      Repo.update_all(
        from(current in Room, where: current.id == ^room.id and current.status == "active"),
        inc: [cash_paid_cents: allocated_cents]
      )

      %CashRoomAllocation{}
      |> CashRoomAllocation.changeset(%{
        room_id: room.id,
        cash_payment_id: payment_id,
        amount_cents: allocated_cents,
        allocation_sequence: next_allocation_sequence()
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_credit_to_rooms(group, application_id, amount_cents) do
    allocate_to_rooms(group, amount_cents, fn room, allocated_cents ->
      Repo.update_all(
        from(current in Room, where: current.id == ^room.id and current.status == "active"),
        inc: [credit_paid_cents: allocated_cents]
      )

      %RoomCreditAllocation{}
      |> RoomCreditAllocation.changeset(%{
        room_id: room.id,
        credit_application_id: application_id,
        amount_cents: allocated_cents,
        allocation_sequence: next_allocation_sequence()
      })
      |> Repo.insert!()
    end)
  end

  defp allocate_to_rooms(group, amount_cents, apply_allocation) do
    remaining_cents =
      Enum.reduce(active_rooms(group), amount_cents, fn room, remaining_cents ->
        capacity_cents = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        allocated_cents = min(capacity_cents, remaining_cents)

        if allocated_cents > 0 do
          apply_allocation.(room, allocated_cents)
        end

        remaining_cents - allocated_cents
      end)

    if remaining_cents == 0, do: :ok, else: raise("room funding exceeds available deposit")
  end

  defp next_allocation_sequence do
    cash_sequence =
      Repo.one(
        from(allocation in CashRoomAllocation,
          select: coalesce(max(allocation.allocation_sequence), 0)
        )
      )

    credit_sequence =
      Repo.one(
        from(allocation in RoomCreditAllocation,
          select: coalesce(max(allocation.allocation_sequence), 0)
        )
      )

    max(cash_sequence, credit_sequence) + 1
  end

  defp move_held_funding(source, destination, amount_cents) do
    case Repo.transaction(fn ->
           {:ok, drawn} = draw_held_funding(source.id, amount_cents)

           Enum.each(drawn, &place_transferred_funding(destination, &1))

           transferred_cash =
             drawn
             |> Enum.filter(&(&1.kind == :cash))
             |> Enum.sum_by(& &1.amount_cents)

           transferred_credit = amount_cents - transferred_cash

           mark_transferred_cash_payments(drawn)

           case conditional_update(source,
                  deposit_paid_cents: source.deposit_paid_cents - amount_cents,
                  cash_paid_cents: source.cash_paid_cents - transferred_cash,
                  credit_paid_cents: source.credit_paid_cents - transferred_credit
                ) do
             :ok ->
               case conditional_update(destination,
                      deposit_paid_cents: destination.deposit_paid_cents + amount_cents,
                      cash_paid_cents: destination.cash_paid_cents + transferred_cash,
                      credit_paid_cents: destination.credit_paid_cents + transferred_credit
                    ) do
                 :ok ->
                   {
                     Groups.outstanding_deposit(source) + amount_cents,
                     Groups.outstanding_deposit(destination) - amount_cents
                   }

                 :conflict ->
                   Repo.rollback(:conflict)
               end

             :conflict ->
               Repo.rollback(:conflict)
           end
         end) do
      {:ok, outstanding_deposits} -> {:ok, outstanding_deposits}
      {:error, :conflict} -> :conflict
    end
  end

  defp draw_held_funding(source_group_id, amount_cents) do
    {remaining_cents, drawn} =
      source_group_id
      |> held_funding_allocations_reverse()
      |> Enum.reduce_while({amount_cents, []}, fn allocation, {remaining_cents, drawn} ->
        drawn_cents = min(remaining_cents, allocation.amount_cents)

        if drawn_cents > 0 do
          remove_source_allocation(allocation, drawn_cents)
        end

        next = %{allocation | amount_cents: drawn_cents}

        if drawn_cents == remaining_cents do
          {:halt, {0, [next | drawn]}}
        else
          {:cont, {remaining_cents - drawn_cents, [next | drawn]}}
        end
      end)

    if remaining_cents == 0,
      do: {:ok, Enum.reverse(drawn)},
      else: raise("held funding changed while transferring deposit")
  end

  defp held_funding_allocations_reverse(source_group_id) do
    cash_allocations =
      Repo.all(
        from(allocation in CashRoomAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          where: room.reservation_id == ^source_group_id and room.status == "active",
          select: %{
            kind: :cash,
            allocation_id: allocation.id,
            room_id: room.id,
            amount_cents: allocation.amount_cents,
            allocation_sequence: allocation.allocation_sequence,
            cash_payment_id: allocation.cash_payment_id
          }
        )
      )

    credit_allocations =
      Repo.all(
        from(allocation in RoomCreditAllocation,
          join: room in Room,
          on: room.id == allocation.room_id,
          join: application in CreditApplication,
          on: application.id == allocation.credit_application_id,
          where: room.reservation_id == ^source_group_id and room.status == "active",
          select: %{
            kind: :credit,
            allocation_id: allocation.id,
            room_id: room.id,
            amount_cents: allocation.amount_cents,
            allocation_sequence: allocation.allocation_sequence,
            credit_application_id: application.id,
            credit_lot_id: application.credit_lot_id,
            source_operation_id: application.source_operation_id
          }
        )
      )

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(
      fn allocation -> {allocation.allocation_sequence, allocation.allocation_id} end,
      :desc
    )
  end

  defp remove_source_allocation(%{kind: :cash} = allocation, amount_cents) do
    reduce_cash_room_allocation(
      allocation.allocation_id,
      allocation.room_id,
      allocation.amount_cents,
      amount_cents
    )
  end

  defp remove_source_allocation(%{kind: :credit} = allocation, amount_cents) do
    reduce_credit_room_allocation(
      allocation.allocation_id,
      allocation.room_id,
      allocation.credit_application_id,
      allocation.amount_cents,
      amount_cents
    )
  end

  defp reduce_cash_room_allocation(allocation_id, room_id, allocation_amount, amount_cents) do
    if amount_cents == allocation_amount do
      Repo.delete_all(
        from(allocation in CashRoomAllocation, where: allocation.id == ^allocation_id)
      )
    else
      Repo.update_all(
        from(allocation in CashRoomAllocation, where: allocation.id == ^allocation_id),
        inc: [amount_cents: -amount_cents]
      )
    end

    Repo.update_all(from(room in Room, where: room.id == ^room_id),
      inc: [cash_paid_cents: -amount_cents]
    )
  end

  defp reduce_credit_room_allocation(
         allocation_id,
         room_id,
         application_id,
         allocation_amount,
         amount_cents
       ) do
    if amount_cents == allocation_amount do
      Repo.delete_all(
        from(allocation in RoomCreditAllocation, where: allocation.id == ^allocation_id)
      )
    else
      Repo.update_all(
        from(allocation in RoomCreditAllocation, where: allocation.id == ^allocation_id),
        inc: [amount_cents: -amount_cents]
      )
    end

    Repo.update_all(from(room in Room, where: room.id == ^room_id),
      inc: [credit_paid_cents: -amount_cents]
    )

    Repo.update_all(
      from(application in CreditApplication, where: application.id == ^application_id),
      inc: [amount_cents: -amount_cents]
    )

    Repo.delete_all(
      from(application in CreditApplication,
        where: application.id == ^application_id and application.amount_cents == 0
      )
    )
  end

  defp place_transferred_funding(destination, %{kind: :cash} = allocation) do
    allocate_cash_to_rooms(destination, allocation.cash_payment_id, allocation.amount_cents)
  end

  defp place_transferred_funding(destination, %{kind: :credit} = allocation) do
    application =
      %CreditApplication{}
      |> CreditApplication.changeset(%{
        reservation_id: destination.id,
        credit_lot_id: allocation.credit_lot_id,
        amount_cents: allocation.amount_cents,
        source_operation_id: allocation.source_operation_id
      })
      |> Repo.insert!()

    allocate_credit_to_rooms(destination, application.id, allocation.amount_cents)
  end

  defp mark_transferred_cash_payments(drawn) do
    payment_ids =
      drawn
      |> Enum.filter(&(&1.kind == :cash and not is_nil(&1.cash_payment_id)))
      |> Enum.map(& &1.cash_payment_id)
      |> Enum.uniq()

    if payment_ids != [] do
      Repo.update_all(
        from(payment in CashPayment, where: payment.id in ^payment_ids),
        set: [participated_in_transfer: true]
      )
    end
  end

  defp cash_allocations_for_rooms(room_ids) do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.room_id in ^room_ids,
        order_by: [
          asc: allocation.allocation_sequence,
          asc: allocation.id
        ],
        select: %{
          id: allocation.id,
          room_id: room.id,
          cash_payment_id: allocation.cash_payment_id,
          amount_cents: allocation.amount_cents,
          allocation_sequence: allocation.allocation_sequence
        }
      )
    )
  end

  defp credit_room_allocations_for_rooms(room_ids) do
    Repo.all(
      from(allocation in RoomCreditAllocation,
        join: application in CreditApplication,
        on: application.id == allocation.credit_application_id,
        join: lot in CreditLot,
        on: lot.id == application.credit_lot_id,
        where: allocation.room_id in ^room_ids,
        order_by: [asc: allocation.allocation_sequence, asc: allocation.id],
        select: %{
          credit_application_id: application.id,
          credit_lot_id: lot.id,
          expires_on: lot.expires_on,
          amount_cents: allocation.amount_cents,
          allocation_sequence: allocation.allocation_sequence
        }
      )
    )
  end

  defp held_cash_for_payment(payment_id) do
    Repo.one(
      from(allocation in CashRoomAllocation,
        where: allocation.cash_payment_id == ^payment_id,
        select: coalesce(sum(allocation.amount_cents), 0)
      )
    )
  end

  defp payment_statement_transfer_detail(
         statement,
         %CashPayment{participated_in_transfer: true} = payment
       ) do
    Map.put(statement, :held_by_group, held_cash_by_group(payment.id))
  end

  defp payment_statement_transfer_detail(statement, _payment), do: statement

  defp held_cash_by_group(payment_id) do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == room.reservation_id,
        where: allocation.cash_payment_id == ^payment_id and room.status == "active",
        group_by: group.group_id,
        order_by: group.group_id,
        select: {group.group_id, coalesce(sum(allocation.amount_cents), 0)}
      )
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end

  defp reduction_within_held(amount_cents, held_cents) when amount_cents <= held_cents, do: :ok

  defp reduction_within_held(_amount_cents, _held_cents),
    do: {:error, "reduction_exceeds_held_cash"}

  defp reduce_held_cash(group, payment, amount_cents) do
    case Repo.transaction(fn ->
           removed_by_group = remove_held_cash(payment.id, amount_cents)

           Repo.update_all(
             from(current in CashPayment, where: current.id == ^payment.id),
             inc: [reduced_cents: amount_cents]
           )

           case update_payment_groups(group, removed_by_group) do
             :ok ->
               Groups.outstanding_deposit(group) + Map.get(removed_by_group, group.id, 0)

             :conflict ->
               Repo.rollback(:conflict)
           end
         end) do
      {:ok, outstanding_deposit_cents} -> {:ok, outstanding_deposit_cents}
      {:error, :conflict} -> :conflict
    end
  end

  defp remove_held_cash(payment_id, amount_cents) do
    {remaining_cents, removed_by_group} =
      payment_id
      |> held_cash_allocations_reverse()
      |> Enum.reduce({amount_cents, %{}}, fn allocation, {remaining_cents, removed_by_group} ->
        removed_cents = min(remaining_cents, allocation.amount_cents)

        if removed_cents > 0 do
          reduce_cash_room_allocation(
            allocation.id,
            allocation.room_id,
            allocation.amount_cents,
            removed_cents
          )
        end

        {
          remaining_cents - removed_cents,
          Map.update(
            removed_by_group,
            allocation.reservation_id,
            removed_cents,
            &(&1 + removed_cents)
          )
        }
      end)

    if remaining_cents == 0,
      do: removed_by_group,
      else: raise("held cash changed while reducing payment")
  end

  defp held_cash_allocations_reverse(payment_id) do
    Repo.all(
      from(allocation in CashRoomAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.cash_payment_id == ^payment_id,
        order_by: [desc: allocation.allocation_sequence, desc: allocation.id],
        select: %{
          id: allocation.id,
          room_id: room.id,
          reservation_id: room.reservation_id,
          amount_cents: allocation.amount_cents
        }
      )
    )
  end

  defp update_payment_groups(original_group, changes_by_group) do
    changes_by_group = Map.put_new(changes_by_group, original_group.id, 0)

    Enum.reduce_while(changes_by_group, :ok, fn {group_id, held_cents}, :ok ->
      group =
        if group_id == original_group.id, do: original_group, else: Repo.get!(Group, group_id)

      case conditional_update(group,
             deposit_paid_cents: group.deposit_paid_cents - held_cents,
             cash_paid_cents: group.cash_paid_cents - held_cents
           ) do
        :ok -> {:cont, :ok}
        :conflict -> {:halt, :conflict}
      end
    end)
  end

  defp remaining_payment_cents(payment) do
    payment.recorded_cents - payment.reduced_cents - payment.charged_back_cents
  end

  defp charge_back(group, payment, charged_back_cents) do
    case Repo.transaction(fn ->
           removed_by_group = remove_held_cash(payment.id, held_cash_for_payment(payment.id))
           dispositions = payment_dispositions(payment.id)
           revoke_credit_entitlements(payment.id)

           Repo.update_all(
             from(current in CashPayment, where: current.id == ^payment.id),
             set: [
               refunded_cents: 0,
               retained_cents: 0,
               converted_to_credit_cents: 0,
               charged_back_cents: payment.charged_back_cents + charged_back_cents
             ]
           )

           changes_by_group = chargeback_group_changes(removed_by_group, dispositions)

           case update_chargeback_groups(group, changes_by_group) do
             :ok ->
               Repo.delete_all(
                 from(disposition in CashPaymentDisposition,
                   where: disposition.cash_payment_id == ^payment.id
                 )
               )

               if group.status == "active" do
                 Groups.outstanding_deposit(group) + Map.get(removed_by_group, group.id, 0)
               else
                 0
               end

             :conflict ->
               Repo.rollback(:conflict)
           end
         end) do
      {:ok, outstanding_deposit_cents} -> {:ok, outstanding_deposit_cents}
      {:error, :conflict} -> :conflict
    end
  end

  defp payment_dispositions(payment_id) do
    Repo.all(
      from(disposition in CashPaymentDisposition,
        where: disposition.cash_payment_id == ^payment_id,
        select: %{
          reservation_id: disposition.reservation_id,
          kind: disposition.kind,
          amount_cents: disposition.amount_cents
        }
      )
    )
  end

  defp chargeback_group_changes(removed_by_group, dispositions) do
    changes =
      Enum.reduce(removed_by_group, %{}, fn {group_id, held_cents}, changes ->
        Map.put(changes, group_id, %{
          held_cents: held_cents,
          refunded_cents: 0,
          retained_cents: 0,
          converted_cents: 0
        })
      end)

    Enum.reduce(dispositions, changes, fn disposition, changes ->
      Map.update(
        changes,
        disposition.reservation_id,
        %{held_cents: 0, refunded_cents: 0, retained_cents: 0, converted_cents: 0},
        & &1
      )
      |> Map.update!(disposition.reservation_id, fn totals ->
        case disposition.kind do
          "refunded" ->
            %{totals | refunded_cents: totals.refunded_cents + disposition.amount_cents}

          "retained" ->
            %{totals | retained_cents: totals.retained_cents + disposition.amount_cents}

          "converted" ->
            %{totals | converted_cents: totals.converted_cents + disposition.amount_cents}
        end
      end)
    end)
  end

  defp update_chargeback_groups(original_group, changes_by_group) do
    changes_by_group =
      Map.put_new(changes_by_group, original_group.id, %{
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0
      })

    Enum.reduce_while(changes_by_group, :ok, fn {group_id, changes}, :ok ->
      group =
        if group_id == original_group.id, do: original_group, else: Repo.get!(Group, group_id)

      case conditional_update(group,
             deposit_paid_cents: group.deposit_paid_cents - changes.held_cents,
             cash_paid_cents: group.cash_paid_cents - changes.held_cents,
             cancelled_refunded_cents: group.cancelled_refunded_cents - changes.refunded_cents,
             cancelled_retained_cents: group.cancelled_retained_cents - changes.retained_cents,
             cancelled_cash_converted_to_credit_cents:
               group.cancelled_cash_converted_to_credit_cents - changes.converted_cents
           ) do
        :ok -> {:cont, :ok}
        :conflict -> {:halt, :conflict}
      end
    end)
  end

  defp revoke_credit_entitlements(payment_id) do
    Repo.all(
      from(contribution in CreditLotContribution,
        join: lot in CreditLot,
        on: lot.id == contribution.credit_lot_id,
        where: contribution.cash_payment_id == ^payment_id,
        select: %{
          lot_id: lot.id,
          remaining_cents: lot.remaining_cents,
          unrecovered_cents: lot.unrecovered_clawback_cents,
          entitlement_cents: contribution.entitlement_cents
        }
      )
    )
    |> Enum.each(fn contribution ->
      revoked_cents = min(contribution.remaining_cents, contribution.entitlement_cents)
      unrecovered_cents = contribution.entitlement_cents - revoked_cents

      Repo.update_all(
        from(lot in CreditLot, where: lot.id == ^contribution.lot_id),
        set: [
          remaining_cents: contribution.remaining_cents - revoked_cents,
          unrecovered_clawback_cents: contribution.unrecovered_cents + unrecovered_cents
        ]
      )
    end)
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  # JSON object ordering has no semantic meaning, while arrays and scalar values
  # do. Encoding this tagged, recursively ordered representation gives a stable
  # fingerprint without changing the submitted payload retained for audit.
  defp payload_fingerprint(payload) do
    payload
    |> canonical_json()
    |> :erlang.term_to_binary([:deterministic])
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {key, canonical_json(item)} end)
    |> Enum.sort()
    |> then(&{:object, &1})
  end

  defp canonical_json(value) when is_list(value),
    do: {:array, Enum.map(value, &canonical_json/1)}

  defp canonical_json(value), do: value

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp applied_result?(result), do: map_value(result, :status) == "applied"

  defp rejected(operation, code, extra \\ %{}) do
    Map.merge(
      %{operation_id: Map.get(operation, "operation_id"), status: "rejected", code: code},
      extra
    )
  end
end
