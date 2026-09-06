defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Cash.{Disposition, PaymentAllocation, PaymentState}
  alias GroupStay.Credit.{Allocation, Entitlement, Lot}
  alias GroupStay.Finance.{ClosedReport, ReportEvent, Reporting}
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Ledger.Total
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @active "active"
  @cancelled "cancelled"
  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @policy_cutover ~D[2027-01-01]
  @room_accounting_version 1
  @reporting_singleton_id 1

  @type result :: map()

  @spec parse_as_of(String.t() | nil) :: {:ok, Date.t()} | {:error, atom()}
  def parse_as_of(nil), do: {:ok, Date.utc_today()}

  def parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_as_of(_), do: {:error, :invalid_date}

  @spec submit_batch(list()) :: [result()]
  def submit_batch(operations) when is_list(operations),
    do: Enum.map(operations, &submit_operation/1)

  @spec get_operation(String.t()) :: result() | nil
  def get_operation(operation_id) do
    case Repo.get_by(Record, operation_id: operation_id) do
      nil -> nil
      record -> decode_result(record.result_json)
    end
  end

  @doc false
  def backfill_legacy_room_accounting! do
    ensure_all_room_accounting!()
  end

  @doc false
  def backfill_allocation_orders! do
    record_ids =
      Repo.all(from record in Record, select: {record.operation_id, record.id})
      |> Map.new()

    rows =
      ((Repo.all(from allocation in PaymentAllocation, select: allocation)
        |> Enum.map(&%{kind: :cash, allocation: &1})) ++
         (Repo.all(from allocation in Allocation, select: allocation)
          |> Enum.map(&%{kind: :credit, allocation: &1})))
      |> Enum.sort_by(&backfill_allocation_order_key(&1, record_ids))

    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {%{allocation: allocation}, order} ->
      allocation
      |> Ecto.Changeset.change(allocation_order: order)
      |> Repo.update!()
    end)

    :ok
  end

  @spec get_group(String.t()) :: map() | nil
  def get_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> nil
      group -> group_response(group, rooms_for_group(group.id))
    end
  end

  @spec get_payment(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_payment(payment_operation_id) do
    Repo.transaction(
      fn ->
        case Repo.get_by(Record, operation_id: payment_operation_id) do
          nil ->
            {:error, "operation_not_found"}

          record ->
            result = decode_result(record.result_json)

            if record.operation_type != "record_cash_payment" or result[:status] != "applied" do
              {:error, "payment_not_reconcilable"}
            else
              group = Repo.get_by(Group, group_id: result[:group_id])

              if is_nil(group) do
                {:error, "payment_not_reconcilable"}
              else
                case Repo.get_by(PaymentState, payment_operation_id: payment_operation_id) do
                  nil ->
                    {:error, "payment_not_reconcilable"}

                  state ->
                    statement = %{
                      payment_operation_id: payment_operation_id,
                      original_group_id: group.group_id,
                      recorded_cents: state.recorded_cents,
                      held_cents: state.held_cents,
                      refunded_cents: state.refunded_cents,
                      retained_cents: state.retained_cents,
                      converted_to_credit_cents: state.converted_to_credit_cents,
                      reduced_cents: state.reduced_cents,
                      charged_back_cents: state.charged_back_cents
                    }

                    statement =
                      if state.transferred do
                        Map.put(
                          statement,
                          :held_by_group,
                          held_cash_by_group(payment_operation_id)
                        )
                      else
                        statement
                      end

                    {:ok, statement}
                end
              end
            end
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, {:ok, statement}} -> {:ok, statement}
      {:ok, {:error, code}} -> {:error, code}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_guest_credit(String.t(), Date.t()) :: map()
  def get_guest_credit(guest_id, as_of_date \\ Date.utc_today()) do
    lots =
      Repo.all(
        from lot in Lot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^as_of_date,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
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

  @spec get_ledger(Date.t()) :: map()
  def get_ledger(as_of_date \\ Date.utc_today()) do
    Repo.transaction(
      fn ->
        liability = credit_liability(as_of_date)
        shortfall = credit_shortfall()
        if as_of_date == Date.utc_today(), do: sync_credit_liability(liability, shortfall)
        ledger = Repo.get!(Total, 1)

        %{
          cash_held_cents: ledger.cash_held_cents,
          cash_refunded_cents: ledger.cash_refunded_cents,
          cash_retained_cents: ledger.cash_retained_cents,
          cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents,
          cash_reduced_cents: ledger.cash_reduced_cents,
          cash_charged_back_cents: ledger.cash_charged_back_cents,
          credit_liability_cents: liability,
          credit_shortfall_cents: shortfall
        }
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  @spec get_daily_report(Date.t()) :: {:ok, map()} | {:error, String.t()}
  def get_daily_report(report_date) do
    Repo.transaction(
      fn ->
        case Repo.get(ClosedReport, report_date) do
          %ClosedReport{report_json: report_json} ->
            {:ok, decode_result(report_json)}

          nil ->
            case Repo.get(Reporting, @reporting_singleton_id) do
              nil ->
                {:error, "report_not_available"}

              reporting ->
                if Date.compare(report_date, reporting.starts_on) == :lt do
                  {:error, "report_not_available"}
                else
                  {:ok, build_daily_report(reporting, report_date)}
                end
            end
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_operation(operation) do
    Repo.transaction(
      fn ->
        operation_id = field(operation, "operation_id")

        if valid_operation_id?(operation_id) do
          payload_json = canonical_json(operation)

          case Repo.get_by(Record, operation_id: operation_id) do
            nil ->
              process_new_operation(operation, operation_id, payload_json)

            record when record.payload_json == payload_json ->
              decode_result(record.result_json)

            _record ->
              reject(operation_id, "operation_id_conflict")
          end
        else
          process_unidentified_operation(operation)
        end
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, result}) when is_map(result), do: result

  defp process_new_operation(operation, operation_id, payload_json) do
    report_before = reporting_effect_snapshot(operation)

    case apply_operation(operation) do
      {:ok, result} ->
        sync_credit_liability()
        record_report_event!(operation, result, report_before)
        remember_operation!(operation, operation_id, payload_json, result)
        result

      {:error, result} ->
        remember_operation!(operation, operation_id, payload_json, result)
        result
    end
  end

  defp process_unidentified_operation(operation) do
    case apply_operation(operation) do
      {:ok, result} ->
        sync_credit_liability()
        result

      {:error, result} ->
        result
    end
  end

  defp remember_operation!(operation, operation_id, payload_json, result) do
    Repo.insert!(%Record{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload_json: payload_json,
      result_json: Jason.encode!(result)
    })
  end

  defp decode_result(result_json), do: Jason.decode!(result_json, keys: :atoms!)

  defp operation_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp canonical_json(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, nested_value} -> {json_key(key), canonical_json(nested_value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    "{" <>
      Enum.map_join(pairs, ",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> nested_value
      end) <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  defp apply_operation(operation) when not is_map(operation),
    do: {:error, reject(nil, "invalid_operation")}

  defp apply_operation(operation) do
    operation_id = field(operation, "operation_id")

    with {:ok, type} <- required_type(operation), :ok <- validate_operation_id(operation_id) do
      case type do
        "open_group" ->
          open_group(operation, operation_id)

        "start_finance_reporting" ->
          start_finance_reporting(operation, operation_id)

        "close_finance_period" ->
          close_finance_period(operation, operation_id)

        type
        when type in [
               "record_cash_payment",
               "reschedule_group",
               "cancel_group",
               "cancel_rooms",
               "apply_hotel_credit"
             ] ->
          apply_existing_group_operation(operation, operation_id, type)

        "transfer_deposit" ->
          transfer_deposit(operation, operation_id)

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          apply_payment_operation(operation, operation_id, type)

        _ ->
          {:error, reject(operation_id, "invalid_operation")}
      end
    else
      _ -> {:error, reject(operation_id, "invalid_operation")}
    end
  end

  defp start_finance_reporting(operation, operation_id) do
    with {:ok, starts_on} <- reporting_date(operation, "starts_on") do
      case Repo.get(Reporting, @reporting_singleton_id) do
        nil ->
          opening = opening_finance_snapshot()

          Repo.insert!(%Reporting{
            id: @reporting_singleton_id,
            starts_on: starts_on,
            opening_json: Jason.encode!(opening)
          })

          {:ok,
           applied(operation_id,
             starts_on: Date.to_iso8601(starts_on)
           )}

        _reporting ->
          {:error, reject(operation_id, "reporting_already_started")}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code)}
    end
  end

  defp close_finance_period(operation, operation_id) do
    with {:ok, period_end_on} <- period_end_date(operation),
         reporting when not is_nil(reporting) <- Repo.get(Reporting, @reporting_singleton_id),
         :ok <- validate_period_end(reporting, period_end_on) do
      Enum.each(Date.range(reporting.starts_on, period_end_on), fn report_date ->
        if is_nil(Repo.get(ClosedReport, report_date)) do
          report = build_daily_report(reporting, report_date)

          Repo.insert!(%ClosedReport{
            report_date: report_date,
            report_json: Jason.encode!(Map.put(report, :status, "closed"))
          })
        end
      end)

      reporting
      |> Ecto.Changeset.change(latest_closed_on: period_end_on)
      |> Repo.update!()

      {:ok,
       applied(operation_id,
         period_end_on: Date.to_iso8601(period_end_on)
       )}
    else
      {:error, _code} -> {:error, reject(operation_id, "invalid_period")}
      nil -> {:error, reject(operation_id, "invalid_period")}
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         nil <- Repo.get_by(Group, group_id: group_id) do
      with {:ok, occurred_on} <- required_date(operation, "occurred_on"),
           {:ok, guest_id} <- required_identifier(operation, "guest_id"),
           {:ok, property_id} <- required_identifier(operation, "property_id"),
           {:ok, arrival_on} <- required_date(operation, "arrival_on"),
           {:ok, departure_on} <- required_date(operation, "departure_on"),
           :ok <- validate_stay(arrival_on, departure_on),
           {:ok, rate_plan} <- validate_rate_plan(field(operation, "rate_plan")),
           {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
        nights = Date.diff(departure_on, arrival_on)

        rooms =
          Enum.map(rooms, fn room ->
            lodging_cents = room.nightly_rate_cents * nights

            Map.merge(room, %{
              lodging_cents: lodging_cents,
              deposit_due_cents: deposit_due([%{lodging_cents: lodging_cents}], rate_plan)
            })
          end)

        lodging_total_cents = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
        deposit_due_cents = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))

        group = %Group{
          group_id: group_id,
          guest_id: guest_id,
          property_id: property_id,
          booked_on: occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          policy_version: policy_version(rate_plan, occurred_on),
          status: @active,
          lodging_total_cents: lodging_total_cents,
          deposit_due_cents: deposit_due_cents,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          revision: 1,
          accounting_version: @room_accounting_version
        }

        case Repo.insert(group) do
          {:ok, group} ->
            Repo.insert_all(
              Room,
              Enum.map(rooms, fn room ->
                %{
                  group_id: group.id,
                  room_id: room.room_id,
                  nightly_rate_cents: room.nightly_rate_cents,
                  position: room.position,
                  status: @active,
                  lodging_cents: room.lodging_cents,
                  deposit_due_cents: room.deposit_due_cents,
                  cash_paid_cents: 0,
                  credit_paid_cents: 0
                }
              end)
            )

            {:ok,
             applied(operation_id,
               group_id: group_id,
               deposit_due_cents: deposit_due_cents,
               revision: 1
             )}

          {:error, _changeset} ->
            {:error, reject(operation_id, "group_already_exists", group_id: group_id)}
        end
      else
        {:error, code} -> {:error, reject(operation_id, code, group_id: group_id)}
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code)}

      _group ->
        {:error,
         reject(operation_id, "group_already_exists", group_id: field(operation, "group_id"))}
    end
  end

  defp apply_existing_group_operation(operation, operation_id, type) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         group when not is_nil(group) <- Repo.get_by(Group, group_id: group_id),
         :ok <- check_expected_revision(operation, group) do
      case type do
        "record_cash_payment" -> record_cash_payment(operation, operation_id, group)
        "reschedule_group" -> reschedule_group(operation, operation_id, group)
        "cancel_group" -> cancel_group(operation, operation_id, group)
        "cancel_rooms" -> cancel_rooms(operation, operation_id, group)
        "apply_hotel_credit" -> apply_hotel_credit(operation, operation_id, group)
      end
    else
      {:error, code} ->
        {:error, reject(operation_id, code, group_id: field(operation, "group_id"))}

      nil ->
        {:error, reject(operation_id, "group_not_found", group_id: field(operation, "group_id"))}
    end
  end

  defp transfer_deposit(operation, operation_id) do
    with {:ok, source_group_id} <- required_identifier(operation, "source_group_id") do
      case Repo.get_by(Group, group_id: source_group_id) do
        nil ->
          {:error, reject(operation_id, "group_not_found", group_id: source_group_id)}

        source_group ->
          with {:ok, destination_group_id} <-
                 required_identifier(operation, "destination_group_id") do
            case Repo.get_by(Group, group_id: destination_group_id) do
              nil ->
                {:error, reject(operation_id, "group_not_found", group_id: destination_group_id)}

              destination_group ->
                apply_transfer_with_groups(
                  operation,
                  operation_id,
                  source_group,
                  destination_group
                )
            end
          else
            {:error, code} -> {:error, reject(operation_id, code)}
          end
      end
    else
      {:error, code} -> {:error, reject(operation_id, code)}
    end
  end

  defp apply_transfer_with_groups(operation, operation_id, source_group, destination_group) do
    case check_expected_revision(operation, source_group) do
      :ok ->
        case check_expected_revision(
               operation,
               "destination_expected_revision",
               destination_group
             ) do
          :ok ->
            apply_transfer_rules(operation, operation_id, source_group, destination_group)

          {:error, {:stale_revision, fields}} ->
            {:error,
             reject(
               operation_id,
               "stale_revision",
               Keyword.merge([group_id: destination_group.group_id], fields)
             )}
        end

      {:error, {:stale_revision, fields}} ->
        {:error,
         reject(
           operation_id,
           "stale_revision",
           Keyword.merge([group_id: source_group.group_id], fields)
         )}
    end
  end

  defp apply_transfer_rules(operation, operation_id, source_group, destination_group) do
    with :ok <- validate_transfer_groups(source_group, destination_group),
         :ok <- ensure_active(source_group),
         :ok <- ensure_active(destination_group),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- ensure_transfer_funding(source_group, amount_cents),
         :ok <- ensure_transfer_outstanding(destination_group, amount_cents) do
      move_transfer_funding!(source_group, destination_group, amount_cents)

      source_group = update_group_financials(source_group)
      destination_group = update_group_financials(destination_group)

      {:ok,
       applied(operation_id,
         source_group_id: source_group.group_id,
         destination_group_id: destination_group.group_id,
         amount_cents: amount_cents,
         source_outstanding_deposit_cents:
           active_totals(source_group.id).outstanding_deposit_cents,
         destination_outstanding_deposit_cents:
           active_totals(destination_group.id).outstanding_deposit_cents,
         source_revision: source_group.revision,
         destination_revision: destination_group.revision
       )}
    else
      {:error, code} when code == "group_not_active" ->
        group = if source_group.status != @active, do: source_group, else: destination_group
        {:error, reject(operation_id, code, group_id: group.group_id)}

      {:error, code} ->
        {:error, reject(operation_id, code)}
    end
  end

  defp validate_transfer_groups(source_group, destination_group) do
    if source_group.id == destination_group.id or
         source_group.guest_id != destination_group.guest_id,
       do: {:error, "invalid_transfer"},
       else: :ok
  end

  defp ensure_transfer_funding(group, amount_cents) do
    if held_funding(group.id) >= amount_cents,
      do: :ok,
      else: {:error, "transfer_exceeds_held_funding"}
  end

  defp ensure_transfer_outstanding(group, amount_cents) do
    if active_totals(group.id).outstanding_deposit_cents >= amount_cents,
      do: :ok,
      else: {:error, "transfer_exceeds_outstanding"}
  end

  defp record_cash_payment(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, _occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         {:ok, outstanding} <- payment_outstanding(group, amount_cents) do
      allocate_cash_funding(group, operation_id, amount_cents)

      insert_payment_state!(%{
        payment_operation_id: operation_id,
        group_id: group.id,
        recorded_cents: amount_cents,
        held_cents: amount_cents,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        reduced_cents: 0,
        charged_back_cents: 0,
        transferred: false
      })

      update_ledger(cash_held_cents: amount_cents)
      update_group_financials(group)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding - amount_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         {:ok, outstanding} <- payment_outstanding(group, amount_cents),
         :ok <- ensure_credit_available(group.guest_id, amount_cents, occurred_on) do
      consume_credit(group, operation_id, amount_cents, occurred_on)
      update_group_financials(group)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding - amount_cents,
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp reschedule_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, new_arrival_on} <- required_date(operation, "new_arrival_on"),
         :ok <- validate_reschedule(occurred_on, new_arrival_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)
      update_group(group, arrival_on: new_arrival_on, departure_on: new_departure_on)

      {:ok,
       applied(operation_id,
         group_id: group.group_id,
         new_arrival_on: new_arrival_on,
         new_departure_on: new_departure_on,
         policy_version: policy_version_for(group),
         refundable_until: refundable_until(group, new_arrival_on),
         revision: group.revision + 1
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp cancel_group(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation) do
      refundable = refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable do
        {:error, reject(operation_id, "refund_method_not_available", group_id: group.group_id)}
      else
        room_ids = active_rooms(group.id) |> Enum.map(& &1.room_id)

        settled =
          settle_rooms(group, operation_id, room_ids, occurred_on, refundable, refund_method)

        {:ok,
         applied(operation_id,
           group_id: group.group_id,
           refunded_cents: settled.refunded_cents,
           retained_cents: settled.retained_cents,
           credit_issued_cents: settled.credit_issued_cents,
           revision: group.revision + 1
         )}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp cancel_rooms(operation, operation_id, group) do
    with :ok <- ensure_active(group),
         {:ok, occurred_on} <- required_date(operation, "occurred_on"),
         {:ok, refund_method} <- refund_method(operation),
         {:ok, room_ids} <- selected_room_ids(operation, group.id) do
      refundable = refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable do
        {:error, reject(operation_id, "refund_method_not_available", group_id: group.group_id)}
      else
        settled =
          settle_rooms(group, operation_id, room_ids, occurred_on, refundable, refund_method)

        {:ok,
         applied(operation_id,
           group_id: group.group_id,
           cancelled_room_ids: room_ids,
           refunded_cents: settled.refunded_cents,
           retained_cents: settled.retained_cents,
           credit_issued_cents: settled.credit_issued_cents,
           revision: group.revision + 1
         )}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp settle_rooms(group, operation_id, room_ids, occurred_on, refundable, refund_method) do
    cash_allocations =
      Repo.all(
        from allocation in PaymentAllocation,
          where: allocation.group_id == ^group.id and allocation.room_id in ^room_ids,
          order_by: [asc: allocation.allocation_order, asc: allocation.id]
      )

    credit_allocations =
      Repo.all(
        from allocation in Allocation,
          where: allocation.group_id == ^group.id and allocation.room_id in ^room_ids,
          order_by: [asc: allocation.id]
      )

    cash_total = sum_amount(cash_allocations)

    {refunded_cents, retained_cents, credit_issued_cents} =
      cond do
        refundable and refund_method == "cash" ->
          remove_cash_allocations!(cash_allocations, adjust_rooms?: true)
          update_cash_disposition!(cash_allocations, :refunded_cents)
          restore_credit_allocations!(credit_allocations, occurred_on)
          update_ledger_if_needed(cash_held_cents: -cash_total, cash_refunded_cents: cash_total)
          {cash_total, 0, 0}

        refundable and refund_method == "hotel_credit" ->
          remove_cash_allocations!(cash_allocations, adjust_rooms?: true)
          restore_credit_allocations!(credit_allocations, occurred_on)

          issued =
            issue_credit_for_cash(group, operation_id, cash_allocations, cash_total, occurred_on)

          {0, 0, issued}

        true ->
          remove_cash_allocations!(cash_allocations, adjust_rooms?: true)
          update_cash_disposition!(cash_allocations, :retained_cents)
          consume_credit_allocations!(credit_allocations)
          update_ledger_if_needed(cash_held_cents: -cash_total, cash_retained_cents: cash_total)
          {0, cash_total, 0}
      end

    Enum.each(active_rooms(group.id), fn room ->
      if room.room_id in room_ids,
        do: room |> Ecto.Changeset.change(status: @cancelled) |> Repo.update!()
    end)

    status = if active_rooms(group.id) == [], do: @cancelled, else: @active
    update_group_financials(group, status: status)

    %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents
    }
  end

  defp issue_credit_for_cash(_group, _operation_id, _cash_allocations, 0, _occurred_on), do: 0

  defp issue_credit_for_cash(group, operation_id, cash_allocations, cash_total, occurred_on) do
    credit_issued_cents = credit_with_bonus(cash_total)

    lot =
      create_credit_lot(
        group.guest_id,
        operation_id,
        credit_issued_cents,
        Date.add(occurred_on, 365)
      )

    contributions = cash_contributions(cash_allocations)

    Enum.reduce(contributions, 0, fn {payment_operation_id, principal_cents}, previous_cash ->
      next_cash = previous_cash + principal_cents
      entitlement_cents = credit_with_bonus(next_cash) - credit_with_bonus(previous_cash)

      if is_binary(payment_operation_id) and payment_operation_id != "" do
        Repo.insert!(%Entitlement{
          lot_id: lot.id,
          payment_operation_id: payment_operation_id,
          entitlement_cents: entitlement_cents,
          revoked_cents: 0
        })
      end

      update_payment_state!(payment_operation_id, converted_to_credit_cents: principal_cents)

      record_cash_dispositions!(
        cash_allocations_for_payment(cash_allocations, payment_operation_id),
        "converted_to_credit"
      )

      next_cash
    end)

    update_ledger_if_needed(
      cash_held_cents: -cash_total,
      cash_converted_to_credit_cents: cash_total
    )

    credit_issued_cents
  end

  defp refund_method(operation) do
    if has_field?(operation, "refund_method") do
      case field(operation, "refund_method") do
        "cash" -> {:ok, "cash"}
        "hotel_credit" -> {:ok, "hotel_credit"}
        _ -> {:error, "invalid_refund_method"}
      end
    else
      {:ok, "cash"}
    end
  end

  defp refundable?(group, occurred_on) do
    case policy_version_for(group) do
      "flex-14" -> Date.diff(group.arrival_on, occurred_on) >= 14
      "flex-30" -> Date.diff(group.arrival_on, occurred_on) >= 30
      _ -> false
    end
  end

  defp policy_version(@advance_purchase, _booked_on), do: "advance-nonrefundable"

  defp policy_version(@flexible, booked_on),
    do: if(Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30")

  defp policy_version_for(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"], do: policy_version

  defp policy_version_for(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp refundable_until(group), do: refundable_until(group, group.arrival_on)

  defp refundable_until(group, arrival_on) do
    case policy_version_for(group) do
      "flex-14" -> Date.add(arrival_on, -14)
      "flex-30" -> Date.add(arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp credit_with_bonus(0), do: 0
  defp credit_with_bonus(cash_cents), do: cash_cents + round_half_up(cash_cents * 10, 100)

  defp ensure_credit_available(guest_id, amount_cents, occurred_on) do
    if available_credit(guest_id, occurred_on) >= amount_cents,
      do: :ok,
      else: {:error, "insufficient_credit"}
  end

  defp available_credit(guest_id, as_of_date) do
    Repo.aggregate(
      from(lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^as_of_date
      ),
      :sum,
      :remaining_cents
    ) || 0
  end

  defp consume_credit(group, operation_id, amount_cents, occurred_on) do
    Enum.reduce_while(available_credit_lots(group.guest_id, occurred_on), amount_cents, fn lot,
                                                                                           remaining ->
      amount = min(remaining, lot.remaining_cents)

      if amount > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - amount)
        |> Repo.update!()

        allocate_existing_credit_amount!(group, operation_id, lot.id, amount)
      end

      next_remaining = remaining - amount
      if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
    end)
  end

  defp available_credit_lots(guest_id, as_of_date) do
    Repo.all(
      from lot in Lot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^as_of_date,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp create_credit_lot(guest_id, source_operation_id, amount_cents, expires_on) do
    Repo.insert!(%Lot{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      issued_cents: amount_cents,
      unrecovered_clawback_cents: 0,
      expires_on: expires_on
    })
  end

  defp restore_credit_allocations!(allocations, occurred_on) do
    allocations
    |> Enum.group_by(& &1.lot_id)
    |> Enum.each(fn {lot_id, lot_allocations} ->
      restore_credit_lot!(Repo.get!(Lot, lot_id), sum_amount(lot_allocations), occurred_on)
    end)

    Enum.each(allocations, fn allocation ->
      decrement_room_credit!(allocation.group_id, allocation.room_id, allocation.amount_cents)
      Repo.delete!(allocation)
    end)
  end

  defp restore_credit_lot!(lot, amount_cents, occurred_on) do
    absorbed = min(amount_cents, lot.unrecovered_clawback_cents || 0)
    excess = amount_cents - absorbed

    remaining_cents =
      if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt],
        do: lot.remaining_cents + excess,
        else: lot.remaining_cents

    lot
    |> Ecto.Changeset.change(
      remaining_cents: remaining_cents,
      unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed
    )
    |> Repo.update!()
  end

  defp consume_credit_allocations!(allocations) do
    Enum.each(allocations, fn allocation ->
      decrement_room_credit!(allocation.group_id, allocation.room_id, allocation.amount_cents)
      Repo.delete!(allocation)
    end)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == ^@active,
        order_by: [asc: room.position]
    )
  end

  defp rooms_for_group(group_id),
    do:
      Repo.all(
        from room in Room, where: room.group_id == ^group_id, order_by: [asc: room.position]
      )

  defp held_funding(group_id) do
    cash =
      Repo.aggregate(
        from(allocation in PaymentAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.amount_cents > 0 and
              room.status == ^@active
        ),
        :sum,
        :amount_cents
      ) || 0

    credit =
      Repo.aggregate(
        from(allocation in Allocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.amount_cents > 0 and
              room.status == ^@active
        ),
        :sum,
        :amount_cents
      ) || 0

    cash + credit
  end

  defp move_transfer_funding!(source_group, destination_group, amount_cents) do
    chunks = transfer_chunks(source_group.id, amount_cents)

    Enum.each(chunks, &remove_transfer_source_allocation!/1)
    allocate_transfer_chunks!(destination_group, chunks)

    Enum.each(chunks, fn
      %{kind: :cash, allocation: %{payment_operation_id: payment_operation_id}} ->
        mark_payment_transferred!(payment_operation_id)

      _chunk ->
        :ok
    end)
  end

  defp transfer_chunks(group_id, amount_cents) do
    ordered_held_allocations(group_id)
    |> Enum.reduce_while({amount_cents, []}, fn row, {remaining, chunks} ->
      amount = min(remaining, row.allocation.amount_cents)
      chunk = %{kind: row.kind, allocation: row.allocation, amount_cents: amount}
      next_remaining = remaining - amount

      if next_remaining == 0,
        do: {:halt, {0, [chunk | chunks]}},
        else: {:cont, {next_remaining, [chunk | chunks]}}
    end)
    |> then(fn {_remaining, chunks} -> Enum.reverse(chunks) end)
  end

  defp ordered_held_allocations(group_id) do
    cash_allocations =
      Repo.all(
        from allocation in PaymentAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.amount_cents > 0 and
              room.status == ^@active
      )
      |> Enum.map(&%{kind: :cash, allocation: &1})

    credit_allocations =
      Repo.all(
        from allocation in Allocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.group_id == ^group_id and allocation.amount_cents > 0 and
              room.status == ^@active
      )
      |> Enum.map(&%{kind: :credit, allocation: &1})

    (cash_allocations ++ credit_allocations)
    |> Enum.sort_by(&allocation_order_key/1, :desc)
  end

  defp allocation_order_key(%{kind: kind, allocation: allocation}) do
    {allocation.allocation_order || 0, allocation_timestamp_key(allocation.inserted_at),
     allocation_kind_key(kind), allocation.id}
  end

  defp backfill_allocation_order_key(%{kind: kind, allocation: allocation}, record_ids) do
    operation_id =
      case kind do
        :cash -> allocation.payment_operation_id
        :credit -> allocation.source_operation_id
      end

    case operation_id do
      value when value in [nil, ""] ->
        {allocation.group_id, 0, 0, allocation_kind_key(kind), allocation.id}

      value ->
        {allocation.group_id, 1, Map.get(record_ids, value, 0), allocation_kind_key(kind),
         allocation.id}
    end
  end

  defp allocation_kind_key(%PaymentAllocation{}), do: 0
  defp allocation_kind_key(%Allocation{}), do: 1
  defp allocation_kind_key(:cash), do: 0
  defp allocation_kind_key(:credit), do: 1

  defp allocation_timestamp_key(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp allocation_timestamp_key(%NaiveDateTime{} = timestamp),
    do: NaiveDateTime.to_iso8601(timestamp)

  defp allocation_timestamp_key(nil), do: ""

  defp next_allocation_order! do
    cash_max =
      Repo.one(from allocation in PaymentAllocation, select: max(allocation.allocation_order))

    credit_max = Repo.one(from allocation in Allocation, select: max(allocation.allocation_order))
    max(cash_max || 0, credit_max || 0) + 1
  end

  defp remove_transfer_source_allocation!(%{
         kind: :cash,
         allocation: allocation,
         amount_cents: amount
       }) do
    decrement_room_cash!(allocation.group_id, allocation.room_id, amount)

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end
  end

  defp remove_transfer_source_allocation!(%{
         kind: :credit,
         allocation: allocation,
         amount_cents: amount
       }) do
    decrement_room_credit!(allocation.group_id, allocation.room_id, amount)

    if amount == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end
  end

  defp allocate_transfer_chunks!(group, chunks) do
    rooms = active_rooms(group.id)

    Enum.reduce(chunks, rooms, fn chunk, rooms ->
      {rooms, remaining} =
        Enum.map_reduce(rooms, chunk.amount_cents, fn room, remaining ->
          capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
          amount = min(capacity, remaining)

          if amount > 0 do
            room =
              case chunk.kind do
                :cash ->
                  room
                  |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + amount)
                  |> Repo.update!()

                :credit ->
                  room
                  |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + amount)
                  |> Repo.update!()
              end

            insert_transfer_allocation!(group, room, chunk, amount)
            {room, remaining - amount}
          else
            {room, remaining}
          end
        end)

      if remaining != 0, do: raise("transfer allocation exceeded active room deposit")
      rooms
    end)
  end

  defp insert_transfer_allocation!(group, room, %{kind: :cash, allocation: allocation}, amount) do
    insert_cash_allocation!(%{
      group_id: group.id,
      room_id: room.room_id,
      payment_operation_id: allocation.payment_operation_id,
      amount_cents: amount
    })
  end

  defp insert_transfer_allocation!(group, room, %{kind: :credit, allocation: allocation}, amount) do
    insert_credit_allocation!(%{
      group_id: group.id,
      room_id: room.room_id,
      lot_id: allocation.lot_id,
      source_operation_id: allocation.source_operation_id,
      amount_cents: amount
    })
  end

  defp mark_payment_transferred!(nil), do: :ok
  defp mark_payment_transferred!(""), do: :ok

  defp mark_payment_transferred!(payment_operation_id) do
    case Repo.get_by(PaymentState, payment_operation_id: payment_operation_id) do
      nil ->
        :ok

      %{transferred: true} ->
        :ok

      state ->
        state |> Ecto.Changeset.change(transferred: true) |> Repo.update!()
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in PaymentAllocation,
        join: group in Group,
        on: group.id == allocation.group_id,
        join: room in Room,
        on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and
            allocation.amount_cents > 0 and room.status == ^@active,
        group_by: group.group_id,
        order_by: [asc: group.group_id],
        select: {group.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end

  defp insert_cash_allocation!(attrs) do
    attrs =
      if column_exists?("cash_payment_allocations", "allocation_order"),
        do: Map.put(attrs, :allocation_order, next_allocation_order!()),
        else: attrs

    Ecto.Changeset.change(%PaymentAllocation{}, attrs) |> Repo.insert!()
  end

  defp insert_credit_allocation!(attrs) do
    attrs =
      if column_exists?("hotel_credit_allocations", "allocation_order"),
        do: Map.put(attrs, :allocation_order, next_allocation_order!()),
        else: attrs

    Ecto.Changeset.change(%Allocation{}, attrs) |> Repo.insert!()
  end

  defp insert_payment_state!(attrs) do
    attrs =
      if column_exists?("cash_payment_states", "transferred"),
        do: Map.put_new(attrs, :transferred, false),
        else: Map.delete(attrs, :transferred)

    Ecto.Changeset.change(%PaymentState{}, attrs) |> Repo.insert!()
  end

  defp column_exists?(table, column) do
    %{rows: rows} = Repo.query!("PRAGMA table_info(#{table})")
    Enum.any?(rows, &(Enum.at(&1, 1) == column))
  end

  defp allocate_cash_funding(group, payment_operation_id, amount_cents) do
    remaining =
      Enum.reduce_while(active_rooms(group.id), amount_cents, fn room, remaining ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(capacity, remaining)

        if amount > 0 do
          room
          |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents + amount)
          |> Repo.update!()

          insert_cash_allocation!(%{
            group_id: group.id,
            room_id: room.room_id,
            payment_operation_id: payment_operation_id,
            amount_cents: amount
          })
        end

        next_remaining = remaining - amount
        if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
      end)

    if remaining != 0, do: raise("cash allocation exceeded active room deposit")
    :ok
  end

  defp allocate_existing_credit_amount!(group, source_operation_id, lot_id, amount_cents) do
    remaining =
      Enum.reduce_while(active_rooms(group.id), amount_cents, fn room, remaining ->
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(capacity, remaining)

        if amount > 0 do
          room
          |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents + amount)
          |> Repo.update!()

          insert_credit_allocation!(%{
            group_id: group.id,
            room_id: room.room_id,
            lot_id: lot_id,
            source_operation_id: source_operation_id,
            amount_cents: amount
          })
        end

        next_remaining = remaining - amount
        if next_remaining == 0, do: {:halt, 0}, else: {:cont, next_remaining}
      end)

    if remaining != 0, do: raise("credit allocation exceeded active room deposit")
    :ok
  end

  defp payment_outstanding(group, amount_cents) do
    outstanding = active_totals(group.id).outstanding_deposit_cents

    if amount_cents <= outstanding,
      do: {:ok, outstanding},
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp remove_cash_allocations!(allocations, opts) do
    adjust_rooms? = Keyword.get(opts, :adjust_rooms?, false)

    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {payment_operation_id, grouped} ->
      amount_cents = sum_amount(grouped)

      if adjust_rooms?,
        do: Enum.each(grouped, &decrement_room_cash!(&1.group_id, &1.room_id, &1.amount_cents))

      Enum.each(grouped, &Repo.delete!/1)
      update_payment_state!(payment_operation_id, held_cents: -amount_cents)
    end)
  end

  defp update_cash_disposition!(allocations, field) do
    cash_contributions(allocations)
    |> Enum.each(fn {payment_operation_id, amount_cents} ->
      update_payment_state!(payment_operation_id, [{field, amount_cents}])
    end)

    record_cash_dispositions!(allocations, cash_disposition_category(field))
  end

  defp cash_allocations_for_payment(allocations, payment_operation_id),
    do: Enum.filter(allocations, &(&1.payment_operation_id == payment_operation_id))

  defp cash_disposition_category(:refunded_cents), do: "refunded"
  defp cash_disposition_category(:retained_cents), do: "retained"

  defp record_cash_dispositions!(allocations, category) do
    allocations
    |> Enum.filter(&(is_binary(&1.payment_operation_id) and &1.payment_operation_id != ""))
    |> Enum.group_by(fn allocation ->
      {allocation.payment_operation_id, allocation.group_id}
    end)
    |> Enum.each(fn {{payment_operation_id, group_id}, grouped} ->
      amount_cents = sum_amount(grouped)
      group = Repo.get!(Group, group_id)

      case Repo.get_by(Disposition,
             payment_operation_id: payment_operation_id,
             property_id: group.property_id,
             category: category
           ) do
        nil ->
          Repo.insert!(%Disposition{
            payment_operation_id: payment_operation_id,
            property_id: group.property_id,
            category: category,
            amount_cents: amount_cents
          })

        disposition ->
          disposition
          |> Ecto.Changeset.change(amount_cents: disposition.amount_cents + amount_cents)
          |> Repo.update!()
      end
    end)
  end

  defp remove_cash_allocations_for_payment!(payment_operation_id, amount_cents) do
    allocations =
      Repo.all(
        from allocation in PaymentAllocation,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where:
            allocation.payment_operation_id == ^payment_operation_id and
              room.status == ^@active,
          order_by: [desc: allocation.allocation_order, desc: allocation.id]
      )

    {remaining, affected_group_ids} =
      Enum.reduce_while(allocations, {amount_cents, MapSet.new()}, fn allocation,
                                                                      {remaining, group_ids} ->
        amount = min(remaining, allocation.amount_cents)
        decrement_room_cash!(allocation.group_id, allocation.room_id, amount)

        if amount == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          allocation
          |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
          |> Repo.update!()
        end

        next_remaining = remaining - amount
        group_ids = MapSet.put(group_ids, allocation.group_id)

        if next_remaining == 0,
          do: {:halt, {0, group_ids}},
          else: {:cont, {next_remaining, group_ids}}
      end)

    if remaining != 0, do: raise("cash allocation did not cover payment disposition")
    MapSet.to_list(affected_group_ids)
  end

  defp touch_groups!(group_ids) do
    group_ids
    |> Enum.uniq()
    |> Enum.map(fn group_id -> update_group_financials(Repo.get!(Group, group_id)) end)
  end

  defp decrement_room_cash!(group_id, room_id, amount_cents) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    room
    |> Ecto.Changeset.change(cash_paid_cents: room.cash_paid_cents - amount_cents)
    |> Repo.update!()
  end

  defp decrement_room_credit!(group_id, room_id, amount_cents) do
    room = Repo.get_by!(Room, group_id: group_id, room_id: room_id)

    room
    |> Ecto.Changeset.change(credit_paid_cents: room.credit_paid_cents - amount_cents)
    |> Repo.update!()
  end

  defp update_payment_state!(nil, _attrs), do: :ok
  defp update_payment_state!("", _attrs), do: :ok

  defp update_payment_state!(payment_operation_id, attrs) do
    state = Repo.get_by!(PaymentState, payment_operation_id: payment_operation_id)

    values =
      Enum.reduce(attrs, %{}, fn {field, delta}, acc ->
        Map.put(acc, field, Map.fetch!(state, field) + delta)
      end)

    state |> Ecto.Changeset.change(values) |> Repo.update!()
  end

  defp cash_contributions(allocations) do
    {order, amounts} =
      Enum.reduce(allocations, {[], %{}}, fn allocation, {order, amounts} ->
        payment_operation_id = allocation.payment_operation_id

        order =
          if Map.has_key?(amounts, payment_operation_id),
            do: order,
            else: order ++ [payment_operation_id]

        {order,
         Map.update(
           amounts,
           payment_operation_id,
           allocation.amount_cents,
           &(&1 + allocation.amount_cents)
         )}
      end)

    Enum.map(order, &{&1, Map.fetch!(amounts, &1)})
  end

  defp apply_payment_operation(operation, operation_id, type) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id"),
         record when not is_nil(record) <- Repo.get_by(Record, operation_id: payment_operation_id),
         {:ok, group, state} <- payment_target(record, type) do
      case check_expected_revision(operation, group) do
        :ok ->
          case type do
            "reduce_cash_payment" ->
              reduce_cash_payment(operation, operation_id, payment_operation_id, group, state)

            "charge_back_payment" ->
              charge_back_payment(operation_id, payment_operation_id, group, state)
          end

        {:error, code} ->
          {:error, reject(operation_id, code, group_id: group.group_id)}
      end
    else
      {:error, code} -> {:error, reject(operation_id, code)}
      nil -> {:error, reject(operation_id, "operation_not_found")}
    end
  end

  defp payment_target(record, type) do
    result = decode_result(record.result_json)

    cond do
      record.operation_type != "record_cash_payment" or result[:status] != "applied" ->
        {:error, payment_error_for(type)}

      true ->
        group = Repo.get_by(Group, group_id: result[:group_id])

        if is_nil(group) do
          {:error, payment_error_for(type)}
        else
          case Repo.get_by(PaymentState, payment_operation_id: record.operation_id) do
            nil -> {:error, payment_error_for(type)}
            state -> {:ok, group, state}
          end
        end
    end
  end

  defp payment_error_for("reduce_cash_payment"), do: "payment_not_reducible"
  defp payment_error_for("charge_back_payment"), do: "payment_not_chargeable"

  defp reduce_cash_payment(operation, operation_id, payment_operation_id, group, state) do
    with {:ok, amount_cents} <- usable_amount(field(operation, "amount_cents")),
         :ok <- ensure_payment_reducible(state),
         :ok <- ensure_reduction_fits(state, amount_cents) do
      affected_group_ids =
        remove_cash_allocations_for_payment!(payment_operation_id, amount_cents)

      update_payment_state!(payment_operation_id,
        held_cents: -amount_cents,
        reduced_cents: amount_cents
      )

      update_ledger(cash_held_cents: -amount_cents, cash_reduced_cents: amount_cents)
      updated_groups = touch_groups!([group.id | affected_group_ids])
      group = Enum.find(updated_groups, &(&1.id == group.id))
      outstanding = active_totals(group.id).outstanding_deposit_cents

      {:ok,
       applied(operation_id,
         payment_operation_id: payment_operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: outstanding,
         revision: group.revision
       )}
    else
      {:error, code} -> {:error, reject(operation_id, code, group_id: group.group_id)}
    end
  end

  defp ensure_payment_reducible(%PaymentState{held_cents: held}) when held > 0, do: :ok
  defp ensure_payment_reducible(_), do: {:error, "payment_not_reducible"}

  defp ensure_reduction_fits(%PaymentState{held_cents: held}, amount_cents),
    do: if(amount_cents <= held, do: :ok, else: {:error, "reduction_exceeds_held_cash"})

  defp charge_back_payment(operation_id, payment_operation_id, group, state) do
    chargeable_cents =
      state.held_cents + state.refunded_cents + state.retained_cents +
        state.converted_to_credit_cents

    if chargeable_cents <= 0 or state.charged_back_cents > 0 do
      {:error, reject(operation_id, "payment_not_chargeable")}
    else
      affected_group_ids =
        if state.held_cents > 0,
          do: remove_cash_allocations_for_payment!(payment_operation_id, state.held_cents),
          else: []

      revoke_payment_entitlements!(payment_operation_id)

      Repo.delete_all(
        from disposition in Disposition,
          where: disposition.payment_operation_id == ^payment_operation_id
      )

      update_payment_state!(payment_operation_id,
        held_cents: -state.held_cents,
        refunded_cents: -state.refunded_cents,
        retained_cents: -state.retained_cents,
        converted_to_credit_cents: -state.converted_to_credit_cents,
        charged_back_cents: chargeable_cents
      )

      update_ledger_if_needed(
        cash_held_cents: -state.held_cents,
        cash_refunded_cents: -state.refunded_cents,
        cash_retained_cents: -state.retained_cents,
        cash_converted_to_credit_cents: -state.converted_to_credit_cents,
        cash_charged_back_cents: chargeable_cents
      )

      updated_groups = touch_groups!([group.id | affected_group_ids])
      group = Enum.find(updated_groups, &(&1.id == group.id))
      outstanding = active_totals(group.id).outstanding_deposit_cents

      {:ok,
       applied(operation_id,
         payment_operation_id: payment_operation_id,
         group_id: group.group_id,
         charged_back_cents: chargeable_cents,
         outstanding_deposit_cents: outstanding,
         revision: group.revision
       )}
    end
  end

  defp revoke_payment_entitlements!(payment_operation_id) do
    Repo.all(
      from entitlement in Entitlement,
        where:
          entitlement.payment_operation_id == ^payment_operation_id and
            entitlement.revoked_cents < entitlement.entitlement_cents,
        order_by: [asc: entitlement.id]
    )
    |> Enum.each(fn entitlement ->
      revocable = entitlement.entitlement_cents - entitlement.revoked_cents
      lot = Repo.get!(Lot, entitlement.lot_id)
      removable = min(lot.remaining_cents, revocable)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - removable,
        unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) + revocable - removable
      )
      |> Repo.update!()

      entitlement
      |> Ecto.Changeset.change(revoked_cents: entitlement.entitlement_cents)
      |> Repo.update!()
    end)
  end

  defp check_expected_revision(operation, group),
    do: check_expected_revision(operation, "expected_revision", group)

  defp check_expected_revision(operation, revision_key, group) do
    if has_field?(operation, revision_key) and field(operation, revision_key) !== group.revision do
      {:error,
       {:stale_revision,
        [
          expected_revision: field(operation, revision_key),
          actual_revision: group.revision
        ]}}
    else
      :ok
    end
  end

  defp update_group_financials(group, attrs \\ []) do
    totals = active_totals(group.id)
    stored_totals = Map.drop(totals, [:outstanding_deposit_cents])

    group
    |> Ecto.Changeset.change(
      Map.merge(Map.new(attrs), Map.merge(stored_totals, %{revision: group.revision + 1}))
    )
    |> Repo.update!()
  end

  defp update_group(group, attrs),
    do:
      group
      |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
      |> Repo.update!()

  defp active_totals(group_id) do
    rooms = active_rooms(group_id)
    lodging_total_cents = Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))
    deposit_due_cents = Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2))
    cash_paid_cents = Enum.reduce(rooms, 0, &(&1.cash_paid_cents + &2))
    credit_paid_cents = Enum.reduce(rooms, 0, &(&1.credit_paid_cents + &2))

    %{
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: cash_paid_cents + credit_paid_cents,
      cash_paid_cents: cash_paid_cents,
      credit_paid_cents: credit_paid_cents,
      outstanding_deposit_cents: deposit_due_cents - cash_paid_cents - credit_paid_cents
    }
  end

  defp group_response(group, rooms) do
    totals = active_totals(group.id)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: policy_version_for(group),
      refundable_until: format_date(refundable_until(group)),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            status: room.status,
            lodging_cents: room.lodging_cents,
            deposit_due_cents: room.deposit_due_cents,
            cash_paid_cents: room.cash_paid_cents,
            credit_paid_cents: room.credit_paid_cents
          }
        end),
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents
    }
  end

  defp format_date(nil), do: nil
  defp format_date(date), do: Date.to_iso8601(date)

  defp selected_room_ids(operation, group_id) do
    room_ids = field(operation, "room_ids")
    active = active_rooms(group_id)

    cond do
      not is_list(room_ids) or room_ids == [] ->
        {:error, "invalid_rooms"}

      Enum.any?(room_ids, &(not (is_binary(&1) and &1 != ""))) ->
        {:error, "invalid_rooms"}

      length(Enum.uniq(room_ids)) != length(room_ids) ->
        {:error, "invalid_rooms"}

      Enum.any?(room_ids, fn room_id -> not Enum.any?(active, &(&1.room_id == room_id)) end) ->
        {:error, "invalid_rooms"}

      true ->
        {:ok, active |> Enum.filter(&(&1.room_id in room_ids)) |> Enum.map(& &1.room_id)}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, acc} ->
      if Enum.any?(acc, &(&1.room_id == field(room, "room_id"))) do
        {:halt, {:error, "invalid_rooms"}}
      else
        with {:ok, room_id} <- required_identifier(room, "room_id"),
             {:ok, nightly_rate_cents} <- positive_amount(field(room, "nightly_rate_cents")) do
          {:cont,
           {:ok,
            [
              %{
                room_id: room_id,
                nightly_rate_cents: nightly_rate_cents,
                position: position,
                lodging_cents: 0,
                deposit_due_cents: 0,
                status: @active,
                cash_paid_cents: 0,
                credit_paid_cents: 0
              }
              | acc
            ]}}
        else
          {:error, _} -> {:halt, {:error, "invalid_rooms"}}
        end
      end
    end)
    |> case do
      {:ok, rooms} -> {:ok, Enum.reverse(rooms)}
      error -> error
    end
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp deposit_due(rooms, @flexible),
    do: Enum.reduce(rooms, 0, &(round_half_up(&1.lodging_cents * 20, 100) + &2))

  defp deposit_due(rooms, @advance_purchase), do: Enum.reduce(rooms, 0, &(&1.lodging_cents + &2))

  defp required_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(operation, key) when is_map(operation) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp required_identifier(_, _), do: {:error, "invalid_operation"}

  defp required_date(operation, key) do
    case field(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_stay"}
        end

      _ ->
        if(has_field?(operation, key),
          do: {:error, "invalid_stay"},
          else: {:error, "invalid_operation"}
        )
    end
  end

  defp reporting_date(operation, key) do
    case field(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_reporting_date"}
        end

      _ ->
        {:error, "invalid_reporting_date"}
    end
  end

  defp period_end_date(operation) do
    case field(operation, "period_end_on") do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, "invalid_period"}
        end

      _ ->
        {:error, "invalid_period"}
    end
  end

  defp validate_period_end(reporting, period_end_on) do
    latest_closed_on = reporting.latest_closed_on

    if Date.compare(period_end_on, reporting.starts_on) == :lt or
         (not is_nil(latest_closed_on) and
            Date.compare(period_end_on, latest_closed_on) != :gt) do
      {:error, "invalid_period"}
    else
      :ok
    end
  end

  defp validate_stay(arrival_on, departure_on),
    do: if(Date.after?(departure_on, arrival_on), do: :ok, else: {:error, "invalid_stay"})

  defp validate_reschedule(occurred_on, new_arrival_on),
    do: if(Date.after?(new_arrival_on, occurred_on), do: :ok, else: {:error, "invalid_stay"})

  defp validate_rate_plan(@flexible), do: {:ok, @flexible}
  defp validate_rate_plan(@advance_purchase), do: {:ok, @advance_purchase}
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp usable_amount(amount) do
    case positive_amount(amount) do
      {:ok, amount} -> {:ok, amount}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp positive_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp positive_amount(_), do: {:error, "invalid_amount"}
  defp ensure_active(%Group{status: @active}), do: :ok
  defp ensure_active(_), do: {:error, "group_not_active"}

  defp reject(operation_id, code, fields \\ [])

  defp reject(operation_id, {:stale_revision, fields}, base_fields),
    do: reject(operation_id, "stale_revision", Keyword.merge(base_fields, fields))

  defp reject(operation_id, code, fields),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))

  defp validate_operation_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_operation_id(_), do: {:error, "invalid_operation"}
  defp valid_operation_id?(value), do: validate_operation_id(value) == :ok
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp field(_, _), do: nil

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp has_field?(_, _), do: false
  defp sum_amount(items), do: Enum.reduce(items, 0, &(&1.amount_cents + &2))

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp credit_liability(as_of_date) do
    available_credit_cents =
      Repo.aggregate(
        from(lot in Lot, where: lot.remaining_cents > 0 and lot.expires_on >= ^as_of_date),
        :sum,
        :remaining_cents
      ) || 0

    applied_credit_cents =
      Repo.one(
        from allocation in Allocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: group.status == ^@active and room.status == ^@active,
          select: sum(allocation.amount_cents)
      ) || 0

    available_credit_cents + applied_credit_cents
  end

  defp credit_shortfall do
    applied_by_lot =
      Repo.all(
        from allocation in Allocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: group.status == ^@active and room.status == ^@active,
          group_by: allocation.lot_id,
          select: {allocation.lot_id, sum(allocation.amount_cents)}
      )
      |> Map.new()

    Repo.all(from lot in Lot, select: {lot.unrecovered_clawback_cents, lot.id})
    |> Enum.reduce(0, fn {unrecovered, lot_id}, total ->
      total + min(unrecovered || 0, Map.get(applied_by_lot, lot_id, 0) || 0)
    end)
  end

  defp sync_credit_liability,
    do: sync_credit_liability(credit_liability(Date.utc_today()), credit_shortfall())

  defp sync_credit_liability(liability, shortfall) do
    ledger = Repo.get!(Total, 1)

    if ledger.credit_liability_cents != liability or ledger.credit_shortfall_cents != shortfall do
      ledger
      |> Ecto.Changeset.change(
        credit_liability_cents: liability,
        credit_shortfall_cents: shortfall
      )
      |> Repo.update!()
    end
  end

  defp update_ledger(deltas) do
    ledger = Repo.get!(Total, 1)

    attrs =
      Enum.reduce(deltas, %{}, fn {field, delta}, acc ->
        Map.put(acc, field, Map.fetch!(ledger, field) + delta)
      end)

    ledger |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp update_ledger_if_needed(deltas) do
    case Enum.reject(deltas, fn {_field, delta} -> delta == 0 end) do
      [] -> :ok
      non_empty_deltas -> update_ledger(non_empty_deltas)
    end
  end

  # Existing databases can contain groups and credit allocations from before room accounting.
  # This backfill only adds provenance and room placement; it does not alter aggregate balances.
  defp ensure_all_room_accounting! do
    Repo.all(
      from group in Group,
        where:
          group.accounting_version < ^@room_accounting_version or is_nil(group.accounting_version),
        order_by: [asc: group.id]
    )
    |> Enum.each(&ensure_group_room_accounting!/1)
  end

  defp ensure_group_room_accounting!(%Group{accounting_version: @room_accounting_version} = group) do
    ensure_payment_states_for_group!(group)
    :ok
  end

  defp ensure_group_room_accounting!(group) do
    rooms = rooms_for_group(group.id)
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.each(rooms, fn room ->
      lodging_cents = room.nightly_rate_cents * nights

      room
      |> Ecto.Changeset.change(
        status: if(group.status == @active, do: @active, else: @cancelled),
        lodging_cents: lodging_cents,
        deposit_due_cents: deposit_due([%{lodging_cents: lodging_cents}], group.rate_plan),
        cash_paid_cents: 0,
        credit_paid_cents: 0
      )
      |> Repo.update!()
    end)

    if group.status == @active do
      backfill_active_group_funding!(group)
    else
      ensure_payment_states_for_group!(group)
      backfill_legacy_credit_entitlements!(group)
    end

    totals =
      if group.status == @active,
        do: Map.drop(active_totals(group.id), [:outstanding_deposit_cents]),
        else: %{
          lodging_total_cents: 0,
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0
        }

    group
    |> Ecto.Changeset.change(Map.merge(totals, %{accounting_version: @room_accounting_version}))
    |> Repo.update!()

    ensure_payment_states_for_group!(Repo.get!(Group, group.id))
    :ok
  end

  defp backfill_active_group_funding!(group) do
    cash_records = funding_records(group.group_id, "record_cash_payment")
    credit_records = funding_records(group.group_id, "apply_hotel_credit")

    existing_credit_rows =
      Repo.all(
        from allocation in Allocation,
          where: allocation.group_id == ^group.id,
          order_by: [asc: allocation.id]
      )

    existing_credit_total = sum_amount(existing_credit_rows)
    recorded_cash_total = Enum.reduce(cash_records, 0, &(&1.amount_cents + &2))
    recorded_credit_total = Enum.reduce(credit_records, 0, &(&1.amount_cents + &2))

    legacy_cash =
      max((group.cash_paid_cents || group.deposit_paid_cents || 0) - recorded_cash_total, 0)

    legacy_credit = max(existing_credit_total - recorded_credit_total, 0)

    classified_rows =
      classify_credit_rows(
        existing_credit_rows,
        legacy_credit,
        credit_records,
        existing_credit_total
      )

    Repo.delete_all(from allocation in Allocation, where: allocation.group_id == ^group.id)

    if legacy_cash > 0, do: allocate_cash_funding(group, nil, legacy_cash)
    insert_backfilled_credit_rows!(group, Map.get(classified_rows, nil, []))

    merge_funding_records(cash_records, credit_records)
    |> Enum.each(fn
      {:cash, record, amount_cents} ->
        allocate_cash_funding(group, record.operation_id, amount_cents)

      {:credit, record, _amount_cents} ->
        insert_backfilled_credit_rows!(group, Map.get(classified_rows, record.operation_id, []))
    end)
  end

  defp funding_records(group_id, operation_type) do
    Repo.all(
      from record in Record,
        where: record.operation_type == ^operation_type,
        order_by: [asc: record.id]
    )
    |> Enum.flat_map(fn record ->
      result = decode_result(record.result_json)

      if result[:status] == "applied" and result[:group_id] == group_id and
           is_integer(result[:amount_cents]) and result[:amount_cents] > 0,
         do: [
           %{
             operation_id: record.operation_id,
             amount_cents: result[:amount_cents],
             record: record
           }
         ],
         else: []
    end)
  end

  defp classify_credit_rows(rows, legacy_credit, credit_records, credit_total) do
    segments = [
      {nil, legacy_credit} | Enum.map(credit_records, &{&1.operation_id, &1.amount_cents})
    ]

    segments =
      if credit_total > legacy_credit + Enum.reduce(credit_records, 0, &(&1.amount_cents + &2)),
        do:
          segments ++
            [
              {nil,
               credit_total - legacy_credit -
                 Enum.reduce(credit_records, 0, &(&1.amount_cents + &2))}
            ],
        else: segments

    {classified, _segments} =
      Enum.reduce(rows, {%{}, segments}, fn row, {classified, segments} ->
        {chunks, segments} = consume_segments(row.amount_cents, row.lot_id, segments)

        classified =
          Enum.reduce(chunks, classified, fn chunk, acc ->
            Map.update(acc, chunk.source_operation_id, [chunk], &(&1 ++ [chunk]))
          end)

        {classified, segments}
      end)

    classified
  end

  defp consume_segments(0, _lot_id, segments), do: {[], segments}

  defp consume_segments(amount, lot_id, [{source_operation_id, segment_amount} | rest]) do
    consumed = min(amount, segment_amount)

    remaining_segments =
      if segment_amount == consumed,
        do: rest,
        else: [{source_operation_id, segment_amount - consumed} | rest]

    {tail, remaining_segments} =
      if amount == consumed,
        do: {[], remaining_segments},
        else: consume_segments(amount - consumed, lot_id, remaining_segments)

    {[
       Map.merge(%{lot_id: lot_id, amount_cents: consumed}, %{
         source_operation_id: source_operation_id
       })
       | tail
     ], remaining_segments}
  end

  defp consume_segments(_amount, _lot_id, []), do: {[], []}

  defp merge_funding_records(cash_records, credit_records) do
    (Enum.map(cash_records, &{:cash, &1, &1.amount_cents}) ++
       Enum.map(credit_records, &{:credit, &1, &1.amount_cents}))
    |> Enum.sort_by(fn {_kind, record, _amount} -> record.record.id end)
  end

  defp insert_backfilled_credit_rows!(_group, []), do: :ok

  defp insert_backfilled_credit_rows!(group, rows),
    do:
      Enum.each(
        rows,
        &allocate_existing_credit_amount!(
          group,
          &1.source_operation_id,
          &1.lot_id,
          &1.amount_cents
        )
      )

  defp ensure_payment_states_for_group!(group),
    do:
      Enum.each(
        funding_records(group.group_id, "record_cash_payment"),
        &ensure_payment_state!(&1.record, group)
      )

  defp backfill_legacy_credit_entitlements!(group) do
    cancellation =
      Repo.all(
        from candidate in Record,
          where: candidate.operation_type == "cancel_group",
          order_by: [desc: candidate.id]
      )
      |> Enum.find(fn candidate ->
        result = decode_result(candidate.result_json)

        result[:status] == "applied" and result[:group_id] == group.group_id and
          (result[:credit_issued_cents] || 0) > 0
      end)

    if cancellation do
      case Repo.get_by(Lot, source_operation_id: cancellation.operation_id) do
        nil ->
          :ok

        lot ->
          entitlement_query =
            from entitlement in Entitlement,
              where: entitlement.lot_id == ^lot.id

          if Repo.aggregate(entitlement_query, :count, :id) == 0 do
            payments = funding_records(group.group_id, "record_cash_payment")
            cash_total = group.cash_paid_cents || group.deposit_paid_cents || 0
            recorded_total = Enum.reduce(payments, 0, &(&1.amount_cents + &2))

            contributions = [
              {nil, max(cash_total - recorded_total, 0)}
              | Enum.map(payments, &{&1.operation_id, &1.amount_cents})
            ]

            if lot.issued_cents == 0 do
              result = decode_result(cancellation.result_json)

              lot
              |> Ecto.Changeset.change(issued_cents: result[:credit_issued_cents] || 0)
              |> Repo.update!()
            end

            Enum.reduce(contributions, 0, fn {payment_operation_id, principal_cents},
                                             previous_cash ->
              next_cash = previous_cash + principal_cents
              entitlement_cents = credit_with_bonus(next_cash) - credit_with_bonus(previous_cash)

              if is_binary(payment_operation_id) and payment_operation_id != "" do
                Repo.insert!(%Entitlement{
                  lot_id: lot.id,
                  payment_operation_id: payment_operation_id,
                  entitlement_cents: entitlement_cents,
                  revoked_cents: 0
                })
              end

              next_cash
            end)
          end
      end
    end
  end

  defp ensure_payment_state!(record, group) do
    case Repo.get_by(PaymentState, payment_operation_id: record.operation_id) do
      nil ->
        result = decode_result(record.result_json)
        recorded_cents = result[:amount_cents] || 0

        allocation_query =
          from allocation in PaymentAllocation,
            where:
              allocation.group_id == ^group.id and
                allocation.payment_operation_id == ^record.operation_id

        held_cents = Repo.aggregate(allocation_query, :sum, :amount_cents) || 0

        {refunded_cents, retained_cents, converted_to_credit_cents} =
          infer_legacy_settlement(record, group, recorded_cents, held_cents)

        insert_payment_state!(%{
          payment_operation_id: record.operation_id,
          group_id: group.id,
          recorded_cents: recorded_cents,
          held_cents: held_cents,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          converted_to_credit_cents: converted_to_credit_cents,
          reduced_cents: 0,
          charged_back_cents: 0,
          transferred: false
        })

        Repo.get_by!(PaymentState, payment_operation_id: record.operation_id)

      state ->
        state
    end
  end

  defp infer_legacy_settlement(_record, group, recorded_cents, held_cents) do
    if group.status == @active do
      {0, 0, 0}
    else
      cancellations =
        Repo.all(
          from candidate in Record,
            where: candidate.operation_type == "cancel_group",
            order_by: [desc: candidate.id]
        )

      cancellation =
        Enum.find(cancellations, fn candidate ->
          result = decode_result(candidate.result_json)
          result[:status] == "applied" and result[:group_id] == group.group_id
        end)

      result = if cancellation, do: decode_result(cancellation.result_json), else: %{}

      cond do
        result[:refunded_cents] && result[:refunded_cents] > 0 -> {recorded_cents, 0, 0}
        result[:retained_cents] && result[:retained_cents] > 0 -> {0, recorded_cents, 0}
        result[:credit_issued_cents] && result[:credit_issued_cents] > 0 -> {0, 0, recorded_cents}
        held_cents == 0 -> {0, 0, 0}
        true -> {0, 0, 0}
      end
    end
  end

  # Finance reporting is intentionally append-only.  The inception snapshot is
  # the reporting boundary; each later applied operation contributes one
  # dated effect record.  Reports then remain read-only projections of those
  # records and the immutable credit-lot expiry dates.
  defp reporting_effect_snapshot(operation) do
    if reporting_started?() and field(operation, "type") != "start_finance_reporting" do
      finance_effect_snapshot()
    end
  end

  defp reporting_started?,
    do: not is_nil(Repo.get(Reporting, @reporting_singleton_id))

  defp opening_finance_snapshot do
    snapshot = finance_effect_snapshot()

    %{
      "cash" => cash_property_totals(snapshot.cash),
      "credit_liability_cents" => credit_liability(Date.utc_today()),
      "cash_dispositions" => opening_cash_dispositions(),
      "lots" =>
        Map.new(snapshot.lots, fn {lot_id, lot} ->
          {to_string(lot_id),
           %{
             "remaining_cents" => lot.remaining_cents,
             "expires_on" => Date.to_iso8601(lot.expires_on)
           }}
        end)
    }
  end

  defp opening_cash_dispositions do
    Repo.all(
      from disposition in Disposition,
        select: %{
          payment_operation_id: disposition.payment_operation_id,
          property_id: disposition.property_id,
          category: disposition.category,
          amount_cents: disposition.amount_cents
        }
    )
    |> Enum.map(fn row ->
      cash_line(row.property_id, row.category, row.amount_cents, row.payment_operation_id)
    end)
  end

  defp finance_effect_snapshot do
    cash =
      Repo.all(
        from allocation in PaymentAllocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: group.status == ^@active and room.status == ^@active,
          select: %{
            group_id: group.id,
            property_id: group.property_id,
            payment_operation_id: allocation.payment_operation_id,
            amount_cents: allocation.amount_cents
          }
      )
      |> Enum.reduce(%{}, fn row, acc ->
        key = {row.group_id, row.payment_operation_id}

        Map.update(
          acc,
          key,
          %{group_id: row.group_id, property_id: row.property_id, amount_cents: row.amount_cents},
          &%{&1 | amount_cents: &1.amount_cents + row.amount_cents}
        )
      end)

    credit_allocations =
      Repo.all(
        from allocation in Allocation,
          join: group in Group,
          on: group.id == allocation.group_id,
          join: room in Room,
          on: room.group_id == allocation.group_id and room.room_id == allocation.room_id,
          where: group.status == ^@active and room.status == ^@active,
          select: %{
            group_id: allocation.group_id,
            room_id: allocation.room_id,
            lot_id: allocation.lot_id,
            amount_cents: allocation.amount_cents
          }
      )

    lots =
      Repo.all(from lot in Lot, select: lot)
      |> Map.new(fn lot ->
        {lot.id,
         %{
           remaining_cents: lot.remaining_cents,
           unrecovered_clawback_cents: lot.unrecovered_clawback_cents || 0,
           expires_on: lot.expires_on
         }}
      end)

    %{cash: cash, credit_allocations: credit_allocations, lots: lots}
  end

  defp record_report_event!(_operation, _result, nil), do: :ok

  defp record_report_event!(operation, result, before) do
    if result[:status] == "applied" do
      reporting = Repo.get!(Reporting, @reporting_singleton_id)
      after_snapshot = finance_effect_snapshot()
      posting_on = reporting_posting_date(operation, reporting)
      cash_lines = report_cash_lines(operation, result, before, after_snapshot)
      credit_movements = report_credit_movements(operation, result, before, after_snapshot)
      lot_deltas = report_lot_deltas(before.lots, after_snapshot.lots)
      late_adjustment = late_adjustment?(operation, posting_on, reporting)

      if cash_lines != [] or nonzero_movements?(credit_movements) or lot_deltas != [] do
        Repo.insert!(%ReportEvent{
          operation_id: field(operation, "operation_id"),
          posting_on: posting_on,
          event_json:
            Jason.encode!(%{
              "cash_lines" => cash_lines,
              "credit_movements" => credit_movements,
              "lot_deltas" => lot_deltas,
              "late_adjustment" => late_adjustment
            })
        })
      end
    end

    :ok
  end

  defp reporting_posting_date(operation, reporting) do
    starts_on = reporting.starts_on

    natural_date =
      case field(operation, "occurred_on") do
        value when is_binary(value) ->
          case Date.from_iso8601(value) do
            {:ok, occurred_on} -> max_date(occurred_on, starts_on)
            _ -> starts_on
          end

        _ ->
          starts_on
      end

    case reporting.latest_closed_on do
      nil -> natural_date
      latest_closed_on -> max_date(natural_date, Date.add(latest_closed_on, 1))
    end
  end

  defp late_adjustment?(operation, posting_on, reporting) do
    case reporting.latest_closed_on do
      nil ->
        false

      _latest_closed_on ->
        natural_date =
          case field(operation, "occurred_on") do
            value when is_binary(value) ->
              case Date.from_iso8601(value) do
                {:ok, occurred_on} -> max_date(occurred_on, reporting.starts_on)
                _ -> reporting.starts_on
              end

            _ ->
              reporting.starts_on
          end

        Date.compare(posting_on, natural_date) == :gt
    end
  end

  defp max_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp report_cash_lines(operation, result, before, after_snapshot) do
    type = field(operation, "type")
    deltas = cash_allocation_deltas(before.cash, after_snapshot.cash)

    case type do
      "record_cash_payment" ->
        cash_delta_lines(deltas, "received")

      "transfer_deposit" ->
        cash_delta_lines(deltas, "transferred_out", :negative) ++
          cash_delta_lines(deltas, "transferred_in", :positive)

      "reduce_cash_payment" ->
        cash_delta_lines(deltas, "reduced", :negative)

      "cancel_group" ->
        cancellation_cash_lines(result, deltas)

      "cancel_rooms" ->
        cancellation_cash_lines(result, deltas)

      "charge_back_payment" ->
        chargeback_cash_lines(operation, deltas)

      _ ->
        []
    end
  end

  defp cancellation_cash_lines(result, deltas) do
    category =
      cond do
        (result[:refunded_cents] || 0) != 0 -> "refunded"
        (result[:retained_cents] || 0) != 0 -> "retained"
        (result[:credit_issued_cents] || 0) != 0 -> "converted_to_credit"
        true -> nil
      end

    if category, do: cash_delta_lines(deltas, category, :negative), else: []
  end

  defp cash_delta_lines(deltas, category), do: cash_delta_lines(deltas, category, :positive)

  defp chargeback_cash_lines(operation, deltas) do
    payment_operation_id = field(operation, "payment_operation_id")

    held_lines = cash_delta_lines(deltas, "charged_back", :negative)

    settled_lines =
      payment_operation_id
      |> prior_cash_dispositions()
      |> Enum.flat_map(fn {property_id, category, amount_cents} ->
        [
          cash_line(property_id, category, -amount_cents, payment_operation_id),
          cash_line(property_id, "charged_back", amount_cents, payment_operation_id)
        ]
      end)

    Enum.map(held_lines, &Map.put(&1, "category", "charged_back")) ++ settled_lines
  end

  defp cash_allocation_deltas(before, after_snapshot) do
    keys = MapSet.union(MapSet.new(Map.keys(before)), MapSet.new(Map.keys(after_snapshot)))

    Enum.flat_map(keys, fn key ->
      before_row = Map.get(before, key)
      after_row = Map.get(after_snapshot, key)
      before_amount = if before_row, do: before_row.amount_cents, else: 0
      after_amount = if after_row, do: after_row.amount_cents, else: 0
      delta = after_amount - before_amount

      if delta == 0 do
        []
      else
        row = after_row || before_row
        [%{property_id: row.property_id, payment_operation_id: elem(key, 1), delta: delta}]
      end
    end)
  end

  defp cash_delta_lines(deltas, category, direction) do
    deltas
    |> Enum.filter(fn %{delta: delta} ->
      (direction == :positive and delta > 0) or (direction == :negative and delta < 0)
    end)
    |> Enum.map(fn %{
                     property_id: property_id,
                     payment_operation_id: payment_operation_id,
                     delta: delta
                   } ->
      amount_cents = if direction == :negative, do: -delta, else: delta
      cash_line(property_id, category, amount_cents, payment_operation_id)
    end)
  end

  defp cash_line(property_id, category, amount_cents, payment_operation_id) do
    %{
      "property_id" => property_id,
      "category" => category,
      "amount_cents" => amount_cents,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp prior_cash_dispositions(payment_operation_id) do
    opening_lines =
      Reporting
      |> Repo.get(@reporting_singleton_id)
      |> case do
        nil -> []
        reporting -> Jason.decode!(reporting.opening_json) |> Map.get("cash_dispositions", [])
      end

    event_lines =
      Repo.all(from event in ReportEvent, order_by: [asc: event.id])
      |> Enum.flat_map(fn event ->
        event.event_json
        |> Jason.decode!()
        |> Map.get("cash_lines", [])
      end)

    (opening_lines ++ event_lines)
    |> Enum.filter(fn line ->
      line["payment_operation_id"] == payment_operation_id and
        line["category"] in ["refunded", "retained", "converted_to_credit"]
    end)
    |> Enum.reduce(%{}, fn line, acc ->
      key = {line["property_id"], line["category"]}
      Map.update(acc, key, line["amount_cents"], &(&1 + line["amount_cents"]))
    end)
    |> Enum.filter(fn {_key, amount_cents} -> amount_cents != 0 end)
    |> Enum.map(fn {{property_id, category}, amount_cents} ->
      {property_id, category, amount_cents}
    end)
  end

  defp report_credit_movements(operation, result, before, after_snapshot) do
    movements = zero_credit_movements()

    case field(operation, "type") do
      type when type in ["cancel_group", "cancel_rooms"] ->
        group = Repo.get_by!(Group, group_id: field(operation, "group_id"))
        occurred_on = operation_date!(operation, "occurred_on")

        allocations =
          cancellation_credit_allocations(before.credit_allocations, operation, group.id)

        if refundable?(group, occurred_on) do
          {absorbed, expired} = restored_credit_amounts(allocations, before.lots, occurred_on)

          movements
          |> Map.put(:issued_cents, result[:credit_issued_cents] || 0)
          |> Map.put(:expired_cents, expired)
          |> Map.put(:absorbed_cents, absorbed)
        else
          Map.put(movements, :consumed_cents, sum_amount(allocations))
        end

      "charge_back_payment" ->
        posting_on =
          reporting_posting_date(operation, Repo.get!(Reporting, @reporting_singleton_id))

        revoked =
          Enum.reduce(report_lot_deltas(before.lots, after_snapshot.lots), 0, fn delta, total ->
            if delta.delta_cents < 0 and Date.compare(delta.expires_on, posting_on) != :lt,
              do: total - delta.delta_cents,
              else: total
          end)

        Map.put(movements, :revoked_cents, revoked)

      _ ->
        movements
    end
  end

  defp operation_date!(operation, key) do
    case Date.from_iso8601(field(operation, key)) do
      {:ok, date} -> date
      _ -> raise "invalid operation date"
    end
  end

  defp cancellation_credit_allocations(allocations, operation, group_id) do
    room_ids =
      case field(operation, "type") do
        "cancel_rooms" -> MapSet.new(field(operation, "room_ids"))
        _ -> nil
      end

    Enum.filter(allocations, fn allocation ->
      allocation.group_id == group_id and
        (is_nil(room_ids) or MapSet.member?(room_ids, allocation.room_id))
    end)
  end

  defp restored_credit_amounts(allocations, lots, occurred_on) do
    allocations
    |> Enum.group_by(& &1.lot_id)
    |> Enum.reduce({0, 0}, fn {lot_id, rows}, {absorbed_total, expired_total} ->
      lot = Map.fetch!(lots, lot_id)
      amount_cents = sum_amount(rows)
      absorbed = min(amount_cents, lot.unrecovered_clawback_cents)
      excess = amount_cents - absorbed
      expired = if Date.compare(lot.expires_on, occurred_on) == :lt, do: excess, else: 0
      {absorbed_total + absorbed, expired_total + expired}
    end)
  end

  defp zero_credit_movements do
    %{
      issued_cents: 0,
      expired_cents: 0,
      consumed_cents: 0,
      revoked_cents: 0,
      absorbed_cents: 0
    }
  end

  defp nonzero_movements?(movements),
    do: Enum.any?(movements, fn {_key, value} -> value != 0 end)

  defp report_lot_deltas(before_lots, after_lots) do
    keys = MapSet.union(MapSet.new(Map.keys(before_lots)), MapSet.new(Map.keys(after_lots)))

    Enum.flat_map(keys, fn lot_id ->
      before_lot = Map.get(before_lots, lot_id)
      after_lot = Map.get(after_lots, lot_id)
      before_remaining = if before_lot, do: before_lot.remaining_cents, else: 0
      after_remaining = if after_lot, do: after_lot.remaining_cents, else: 0
      delta_cents = after_remaining - before_remaining

      if delta_cents == 0 do
        []
      else
        lot = after_lot || before_lot

        [
          %{
            "lot_id" => to_string(lot_id),
            "delta_cents" => delta_cents,
            "expires_on" => Date.to_iso8601(lot.expires_on)
          }
        ]
      end
    end)
  end

  defp build_daily_report(reporting, report_date) do
    opening = Jason.decode!(reporting.opening_json)

    events =
      Repo.all(
        from event in ReportEvent,
          where: event.posting_on >= ^reporting.starts_on and event.posting_on <= ^report_date,
          order_by: [asc: event.posting_on, asc: event.id]
      )

    prior_events = Enum.filter(events, &(Date.compare(&1.posting_on, report_date) == :lt))
    today_events = Enum.filter(events, &(Date.compare(&1.posting_on, report_date) == :eq))

    prior_cash = aggregate_cash_events(prior_events, :ordinary)
    prior_late_cash = aggregate_cash_events(prior_events, :late)
    today_cash = aggregate_cash_events(today_events, :ordinary)
    today_late_cash = aggregate_cash_events(today_events, :late)

    opening_cash =
      cash_map_with_delta(
        opening["cash"] || %{},
        merge_cash_movements(prior_cash, prior_late_cash)
      )

    today_cash_total = merge_cash_movements(today_cash, today_late_cash)

    cash =
      cash_properties(opening_cash, today_cash_total)
      |> Enum.sort()
      |> Enum.flat_map(fn property_id ->
        opening_held_cents = Map.get(opening_cash, property_id, 0)
        movements = Map.get(today_cash, property_id, zero_cash_movements())
        late_movements = Map.get(today_late_cash, property_id, zero_cash_movements())

        closing_held_cents =
          cash_closing(
            opening_held_cents,
            Map.get(today_cash_total, property_id, zero_cash_movements())
          )

        if opening_held_cents == 0 and closing_held_cents == 0 and
             Enum.all?(Map.values(merge_cash_movement(movements, late_movements)), &(&1 == 0)) do
          []
        else
          [
            %{
              property_id: property_id,
              opening_held_cents: opening_held_cents,
              movements: movements,
              closing_held_cents: closing_held_cents
            }
          ]
        end
      end)

    prior_credit = aggregate_credit_events(prior_events, :ordinary)
    prior_late_credit = aggregate_credit_events(prior_events, :late)
    today_credit = aggregate_credit_events(today_events, :ordinary)
    today_late_credit = aggregate_credit_events(today_events, :late)
    expiry_before = aggregate_expiry(reporting, prior_events, Date.add(report_date, -1))

    late_expiry_before =
      aggregate_late_expiry(reporting, prior_events, Date.add(report_date, -1), :through)

    expiry_today = aggregate_expiry_on(reporting, events, report_date)
    late_expiry_today = aggregate_late_expiry(reporting, events, report_date, :on)

    opening_liability =
      opening["credit_liability_cents"] +
        credit_delta(
          merge_credit_movements(
            merge_credit_movements(prior_credit, prior_late_credit),
            merge_credit_movements(expiry_before, late_expiry_before)
          )
        )

    credit_movements = merge_credit_movements(today_credit, expiry_today)
    today_late_credit = merge_credit_movements(today_late_credit, late_expiry_today)

    late_adjustments = %{
      cash:
        today_late_cash
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {property_id, movements} ->
          if nonzero_movements?(movements) do
            [%{property_id: property_id, movements: movements}]
          else
            []
          end
        end),
      credit: today_late_credit
    }

    %{
      date: Date.to_iso8601(report_date),
      status: "open",
      cash: cash,
      late_adjustments: late_adjustments,
      credit: %{
        opening_liability_cents: opening_liability,
        movements: credit_movements,
        closing_liability_cents:
          opening_liability +
            credit_delta(merge_credit_movements(credit_movements, today_late_credit))
      }
    }
  end

  defp aggregate_cash_events(events, mode) do
    Enum.reduce(events, %{}, fn event, acc ->
      event_data = Jason.decode!(event.event_json)

      if include_event_mode?(event_data, mode) do
        Enum.reduce(Map.get(event_data, "cash_lines", []), acc, fn line, acc ->
          property_id = line["property_id"]
          category = cash_category_key(line["category"])
          movements = Map.get(acc, property_id, zero_cash_movements())

          Map.put(
            acc,
            property_id,
            Map.update!(movements, category, &(&1 + line["amount_cents"]))
          )
        end)
      else
        acc
      end
    end)
  end

  defp cash_category_key("received"), do: :received_cents
  defp cash_category_key("transferred_in"), do: :transferred_in_cents
  defp cash_category_key("transferred_out"), do: :transferred_out_cents
  defp cash_category_key("refunded"), do: :refunded_cents
  defp cash_category_key("retained"), do: :retained_cents
  defp cash_category_key("converted_to_credit"), do: :converted_to_credit_cents
  defp cash_category_key("reduced"), do: :reduced_cents
  defp cash_category_key("charged_back"), do: :charged_back_cents

  defp aggregate_credit_events(events, mode) do
    Enum.reduce(events, zero_credit_movements(), fn event, acc ->
      event_data = Jason.decode!(event.event_json)

      if include_event_mode?(event_data, mode) do
        movements = Map.get(event_data, "credit_movements", %{})

        Enum.reduce(movements, acc, fn {key, value}, acc ->
          Map.update!(acc, String.to_existing_atom(key), &(&1 + value))
        end)
      else
        acc
      end
    end)
  end

  defp include_event_mode?(event_data, :ordinary),
    do: not Map.get(event_data, "late_adjustment", false)

  defp include_event_mode?(event_data, :late), do: Map.get(event_data, "late_adjustment", false)

  defp aggregate_expiry(reporting, events, report_date) do
    aggregate_expiry(reporting, events, report_date, :through)
  end

  defp aggregate_expiry_on(reporting, events, report_date) do
    aggregate_expiry(reporting, events, report_date, :on)
  end

  defp aggregate_expiry(reporting, events, report_date, mode) do
    if Date.compare(report_date, reporting.starts_on) == :lt do
      zero_credit_movements()
    else
      opening = Jason.decode!(reporting.opening_json)
      opening_lots = opening["lots"] || %{}

      lot_catalog =
        Enum.reduce(events, opening_lots, fn event, acc ->
          event.event_json
          |> Jason.decode!()
          |> Map.get("lot_deltas", [])
          |> Enum.reduce(acc, fn delta, acc ->
            Map.put_new(acc, delta["lot_id"], %{
              "remaining_cents" => 0,
              "expires_on" => delta["expires_on"]
            })
          end)
        end)

      Enum.reduce(lot_catalog, zero_credit_movements(), fn {lot_id, lot}, acc ->
        expires_on = Date.from_iso8601!(lot["expires_on"])
        expiry_on = Date.add(expires_on, 1)

        if Date.compare(expiry_on, reporting.starts_on) != :lt and
             Date.compare(expiry_on, report_date) != :gt and
             (mode == :through or Date.compare(expiry_on, report_date) == :eq) do
          initial_remaining = get_in(opening_lots, [lot_id, "remaining_cents"]) || 0

          delta_before_expiry =
            Enum.reduce(events, 0, fn event, total ->
              if Date.compare(event.posting_on, expires_on) != :gt do
                event.event_json
                |> Jason.decode!()
                |> Map.get("lot_deltas", [])
                |> Enum.reduce(total, fn delta, total ->
                  if delta["lot_id"] == lot_id,
                    do: total + delta["delta_cents"],
                    else: total
                end)
              else
                total
              end
            end)

          expired = max(initial_remaining + delta_before_expiry, 0)

          if expired > 0,
            do: Map.update!(acc, :expired_cents, &(&1 + expired)),
            else: acc
        else
          acc
        end
      end)
    end
  end

  defp aggregate_late_expiry(reporting, events, report_date, mode) do
    if Date.compare(report_date, reporting.starts_on) == :lt do
      zero_credit_movements()
    else
      opening = Jason.decode!(reporting.opening_json)
      opening_lots = opening["lots"] || %{}

      lot_catalog =
        Enum.reduce(events, opening_lots, fn event, acc ->
          event.event_json
          |> Jason.decode!()
          |> Map.get("lot_deltas", [])
          |> Enum.reduce(acc, fn delta, acc ->
            Map.put_new(acc, delta["lot_id"], %{
              "remaining_cents" => 0,
              "expires_on" => delta["expires_on"]
            })
          end)
        end)

      Enum.reduce(lot_catalog, zero_credit_movements(), fn {lot_id, lot}, acc ->
        expires_on = Date.from_iso8601!(lot["expires_on"])

        late_events =
          events
          |> Enum.reduce(%{}, fn event, events_by_date ->
            event_data = Jason.decode!(event.event_json)

            if Map.get(event_data, "late_adjustment", false) and
                 Date.compare(event.posting_on, expires_on) == :gt and
                 (mode == :through or Date.compare(event.posting_on, report_date) == :eq) and
                 (mode == :on or Date.compare(event.posting_on, report_date) != :gt) do
              delta_cents =
                Enum.reduce(Map.get(event_data, "lot_deltas", []), 0, fn delta, total ->
                  if delta["lot_id"] == to_string(lot_id),
                    do: total + delta["delta_cents"],
                    else: total
                end)

              Map.update(events_by_date, event.posting_on, delta_cents, &(&1 + delta_cents))
            else
              events_by_date
            end
          end)

        late_expired =
          late_events
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.reduce({0, 0}, fn {_posting_on, delta_cents}, {_available, expired_total} ->
            expired = max(delta_cents, 0)
            {0, expired_total + expired}
          end)
          |> elem(1)

        if late_expired > 0,
          do: Map.update!(acc, :expired_cents, &(&1 + late_expired)),
          else: acc
      end)
    end
  end

  defp zero_cash_movements do
    %{
      received_cents: 0,
      transferred_in_cents: 0,
      transferred_out_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    }
  end

  defp cash_property_totals(cash) do
    Enum.reduce(cash, %{}, fn {_key, row}, acc ->
      Map.update(acc, row.property_id, row.amount_cents, &(&1 + row.amount_cents))
    end)
  end

  defp cash_map_with_delta(opening_cash, movements) do
    Enum.reduce(movements, opening_cash, fn {property_id, values}, acc ->
      Map.put(acc, property_id, Map.get(acc, property_id, 0) + cash_delta(values))
    end)
  end

  defp merge_cash_movements(left, right) do
    Enum.reduce(right, left, fn {property_id, movements}, acc ->
      Map.update(acc, property_id, movements, &merge_cash_movement(&1, movements))
    end)
  end

  defp merge_cash_movement(left, right),
    do: Enum.reduce(right, left, fn {key, value}, acc -> Map.update!(acc, key, &(&1 + value)) end)

  defp cash_properties(opening_cash, movements),
    do: MapSet.union(MapSet.new(Map.keys(opening_cash)), MapSet.new(Map.keys(movements)))

  defp cash_closing(opening_held_cents, movements),
    do: opening_held_cents + cash_delta(movements)

  defp cash_delta(movements) do
    movements.received_cents + movements.transferred_in_cents - movements.transferred_out_cents -
      movements.refunded_cents - movements.retained_cents - movements.converted_to_credit_cents -
      movements.reduced_cents - movements.charged_back_cents
  end

  defp merge_credit_movements(left, right) do
    Enum.reduce(right, left, fn {key, value}, acc -> Map.update!(acc, key, &(&1 + value)) end)
  end

  defp credit_delta(movements) do
    movements.issued_cents - movements.expired_cents - movements.consumed_cents -
      movements.revoked_cents - movements.absorbed_cents
  end
end
