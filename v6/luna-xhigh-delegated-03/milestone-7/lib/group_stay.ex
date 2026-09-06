defmodule GroupStay do
  @moduledoc """
  The group-deposit domain and its partner batch operations.
  """

  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditLot,
    CreditLotContribution,
    FinancePeriodClose,
    FinancePosting,
    FinanceReportSnapshot,
    FinanceReporting,
    FinanceReportingCreditOpening,
    FinanceReportingOpening,
    Group,
    GroupRoom,
    Ledger,
    OperationRecord,
    PaymentDisposition,
    Repo
  }

  @operation_types ~w(
    open_group
    record_cash_payment
    reschedule_group
    cancel_group
    apply_hotel_credit
    cancel_rooms
    reduce_cash_payment
    charge_back_payment
    transfer_deposit
    start_finance_reporting
    close_finance_period
  )
  @rate_plans ~w(flexible advance_purchase)
  @policy_cutover ~D[2027-01-01]
  @key_atoms %{
    "operations" => :operations,
    "operation_id" => :operation_id,
    "type" => :type,
    "group_id" => :group_id,
    "source_group_id" => :source_group_id,
    "destination_group_id" => :destination_group_id,
    "guest_id" => :guest_id,
    "property_id" => :property_id,
    "occurred_on" => :occurred_on,
    "arrival_on" => :arrival_on,
    "departure_on" => :departure_on,
    "new_arrival_on" => :new_arrival_on,
    "rate_plan" => :rate_plan,
    "rooms" => :rooms,
    "room_id" => :room_id,
    "nightly_rate_cents" => :nightly_rate_cents,
    "amount_cents" => :amount_cents,
    "expected_revision" => :expected_revision,
    "destination_expected_revision" => :destination_expected_revision,
    "refund_method" => :refund_method,
    "room_ids" => :room_ids,
    "payment_operation_id" => :payment_operation_id,
    "on" => :on,
    "starts_on" => :starts_on,
    "period_end_on" => :period_end_on,
    "date" => :date
  }

  @doc "Applies operations in order, committing each operation independently."
  def process_batch(params) do
    case field(params, "operations") do
      operations when is_list(operations) ->
        %{results: Enum.map(operations, &process_operation/1)}

      _ ->
        {:error, :invalid_batch}
    end
  end

  @doc "Returns the public representation of a group, or `nil`."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil ->
        nil

      group ->
        ensure_room_accounting!(group)
        public_group(group)
    end
  end

  def get_group(_group_id), do: nil

  @doc "Returns the current finance totals, reporting credit expiry as of the requested date."
  def ledger, do: ledger(%{})

  def ledger(params) when is_map(params) do
    with {:ok, as_of} <- parse_as_of(params) do
      ledger_as_of(as_of)
    end
  end

  @doc "Returns a guest's unexpired, unexhausted credit lots."
  def get_guest_credit(guest_id, params \\ %{})

  def get_guest_credit(guest_id, params) when is_binary(guest_id) and is_map(params) do
    with {:ok, as_of} <- parse_as_of(params) do
      lots = available_credit_lots(guest_id, as_of)

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
  end

  @doc "Returns the stored result for an operation, or `nil`."
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      operation -> decode_result(operation.result)
    end
  end

  def get_operation(_operation_id), do: nil

  @doc "Returns the current reconciliation statement for an applied cash payment."
  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        nil

      record ->
        case applied_cash_payment?(record) do
          true ->
            group_id = decode_result(record.result)[:group_id]
            disposition = payment_disposition_snapshot(record, group_id)
            public_payment(disposition)

          false ->
            {:error, :payment_not_reconcilable}
        end
    end
  end

  def get_payment(_payment_operation_id), do: nil

  @doc "Returns the daily finance report for a date."
  def daily_finance_report(params) when is_map(params) do
    case parse_reporting_date(field(params, "date")) do
      {:error, :invalid_reporting_date} ->
        {:error, :invalid_reporting_date}

      {:ok, date} ->
        case Repo.get(FinanceReporting, 1) do
          nil ->
            {:error, :report_not_available}

          %{starts_on: starts_on} = reporting ->
            if Date.compare(date, starts_on) == :lt do
              {:error, :report_not_available}
            else
              case closed_finance_report(date) do
                nil -> build_daily_finance_report(reporting, date)
                snapshot -> decode_result(snapshot.data)
              end
            end
        end
    end
  end

  defp process_operation(operation) when is_map(operation) do
    operation_id = field(operation, "operation_id")

    cond do
      not valid_identifier?(operation_id) -> rejected(operation_id, "invalid_operation")
      true -> process_durable_operation(operation, operation_id)
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_durable_operation(operation, operation_id) do
    payload = canonical_json(operation)

    Repo.transaction(
      fn ->
        case Repo.get_by(OperationRecord, operation_id: operation_id) do
          nil ->
            result = process_operation_once(operation, operation_id)

            Repo.insert!(%OperationRecord{
              operation_id: operation_id,
              type: durable_type(operation),
              payload: payload,
              result: Jason.encode!(result)
            })

            result

          %OperationRecord{payload: ^payload, result: result} ->
            decode_result(result)

          %OperationRecord{} ->
            rejected(operation_id, "operation_id_conflict")
        end
      end,
      mode: :immediate
    )
    |> transaction_result()
  end

  defp process_operation_once(operation, operation_id) do
    type = field(operation, "type")

    cond do
      type not in @operation_types ->
        rejected(operation_id, "invalid_operation")

      type == "open_group" ->
        process_open_group(operation, operation_id)

      type == "start_finance_reporting" ->
        process_start_finance_reporting(operation, operation_id)

      type == "close_finance_period" ->
        process_close_finance_period(operation, operation_id)

      type in ["reduce_cash_payment", "charge_back_payment"] ->
        process_payment_operation(operation, operation_id, type)

      type == "transfer_deposit" ->
        process_transfer_operation(operation, operation_id)

      true ->
        process_group_operation(operation, operation_id, type)
    end
  end

  defp process_start_finance_reporting(operation, operation_id) do
    case parse_reporting_date(field(operation, "starts_on")) do
      {:error, :invalid_reporting_date} ->
        rejected(operation_id, "invalid_reporting_date")

      {:ok, starts_on} ->
        if Repo.get(FinanceReporting, 1) do
          rejected(operation_id, "reporting_already_started")
        else
          start_finance_reporting!(starts_on)

          %{
            operation_id: operation_id,
            status: "applied",
            starts_on: Date.to_iso8601(starts_on)
          }
        end
    end
  end

  defp process_close_finance_period(operation, operation_id) do
    case parse_reporting_date(field(operation, "period_end_on")) do
      {:error, :invalid_reporting_date} ->
        rejected(operation_id, "invalid_period")

      {:ok, period_end_on} ->
        case Repo.get(FinanceReporting, 1) do
          nil ->
            rejected(operation_id, "invalid_period")

          %{starts_on: starts_on} = reporting ->
            latest_close = latest_finance_close()

            invalid_period? =
              Date.compare(period_end_on, starts_on) == :lt or
                (not is_nil(latest_close) and
                   Date.compare(period_end_on, latest_close.period_end_on) != :gt)

            if invalid_period? do
              rejected(operation_id, "invalid_period")
            else
              publish_finance_reports!(reporting, period_end_on, latest_close)

              Repo.insert!(%FinancePeriodClose{period_end_on: period_end_on})

              %{
                operation_id: operation_id,
                status: "applied",
                period_end_on: Date.to_iso8601(period_end_on)
              }
            end
        end
    end
  end

  defp latest_finance_close do
    FinancePeriodClose
    |> order_by([close], desc: close.period_end_on, desc: close.id)
    |> limit(1)
    |> Repo.one()
  end

  defp closed_finance_report(date) do
    FinanceReportSnapshot
    |> where([snapshot], snapshot.report_date == ^date)
    |> Repo.one()
  end

  defp publish_finance_reports!(reporting, period_end_on, latest_close) do
    first_date =
      case latest_close do
        nil -> reporting.starts_on
        close -> Date.add(close.period_end_on, 1)
      end

    if Date.compare(first_date, period_end_on) != :gt do
      first_date
      |> Date.range(period_end_on)
      |> Enum.each(fn date ->
        report = build_daily_finance_report(reporting, date, "closed")

        Repo.insert!(%FinanceReportSnapshot{
          report_date: date,
          data: Jason.encode!(report)
        })
      end)
    end
  end

  defp start_finance_reporting!(starts_on) do
    # Hydrate legacy groups before taking the snapshot.  This changes only the
    # room-level representation; the aggregate financial position is unchanged.
    Group
    |> Repo.all()
    |> Enum.each(&ensure_room_accounting!/1)

    backfill_reporting_settlement_history!(starts_on)

    openings =
      from(allocation in CashAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: group.status == "active",
        group_by: group.property_id,
        select: {group.property_id, sum(allocation.amount_cents)},
        order_by: group.property_id
      )
      |> Repo.all()

    Enum.each(openings, fn {property_id, amount_cents} ->
      Repo.insert!(%FinanceReportingOpening{
        property_id: property_id,
        opening_held_cents: amount_cents || 0
      })
    end)

    credit_openings = finance_credit_openings(starts_on)

    opening_credit_liability_cents =
      Enum.reduce(credit_openings, 0, fn opening, total ->
        total + opening.available_cents + opening.applied_cents
      end)

    Repo.insert!(%FinanceReporting{
      id: 1,
      starts_on: starts_on,
      opening_credit_liability_cents: opening_credit_liability_cents
    })

    Enum.each(credit_openings, fn opening ->
      Repo.insert!(%FinanceReportingCreditOpening{
        credit_lot_id: opening.credit_lot_id,
        available_cents: opening.available_cents,
        applied_cents: opening.applied_cents,
        expires_on: opening.expires_on
      })
    end)
  end

  defp finance_credit_openings(starts_on) do
    applied_by_lot =
      from(allocation in CreditAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: group.status == "active",
        group_by: allocation.credit_lot_id,
        select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
      )
      |> Repo.all()
      |> Map.new(fn {lot_id, amount_cents} -> {lot_id, amount_cents || 0} end)

    CreditLot
    |> Repo.all()
    |> Enum.map(fn lot ->
      available_cents =
        if Date.compare(lot.expires_on, starts_on) == :gt, do: lot.remaining_cents, else: 0

      %{
        credit_lot_id: lot.id,
        available_cents: available_cents,
        applied_cents: Map.get(applied_by_lot, lot.id, 0),
        expires_on: lot.expires_on
      }
    end)
    |> Enum.filter(&(&1.available_cents > 0 or &1.applied_cents > 0))
  end

  defp backfill_reporting_settlement_history!(starts_on) do
    historical_posting_on = Date.add(starts_on, -1)

    OperationRecord
    |> order_by([record], asc: record.id)
    |> Repo.all()
    |> Enum.each(fn record ->
      if applied_cash_payment?(record) do
        disposition = ensure_payment_disposition!(record)

        if disposition.refunded_cents > 0 or disposition.retained_cents > 0 or
             disposition.converted_to_credit_cents > 0 do
          Repo.insert!(%FinancePosting{
            operation_id: record.operation_id,
            posting_on: historical_posting_on,
            original_posting_on: historical_posting_on,
            property_id: payment_settlement_property(record.operation_id, disposition),
            payment_operation_id: record.operation_id,
            refunded_cents: disposition.refunded_cents,
            retained_cents: disposition.retained_cents,
            converted_to_credit_cents: disposition.converted_to_credit_cents
          })
        end
      end
    end)
  end

  defp process_open_group(operation, operation_id) do
    group_id = field(operation, "group_id")

    cond do
      not valid_identifier?(group_id) ->
        rejected(operation_id, "invalid_operation")

      not valid_identifier?(field(operation, "guest_id")) ->
        rejected(operation_id, "invalid_operation")

      not valid_identifier?(field(operation, "property_id")) ->
        rejected(operation_id, "invalid_operation")

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation")

      true ->
        if Repo.get(Group, group_id) do
          rejected(operation_id, "group_already_exists", %{group_id: group_id})
        else
          apply_open_group(operation, operation_id, group_id)
        end
    end
  end

  defp apply_open_group(operation, operation_id, group_id) do
    with {:ok, booked_on} <- parse_date(field(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(field(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")) do
      nights = Date.diff(departure_on, arrival_on)
      rate_plan = field(operation, "rate_plan")

      room_rows =
        Enum.map(rooms, fn room ->
          lodging_total_cents = nights * room.nightly_rate_cents

          deposit_due_cents =
            case rate_plan do
              "advance_purchase" -> lodging_total_cents
              "flexible" -> round_half_up(lodging_total_cents * 20, 100)
            end

          Map.merge(room, %{
            lodging_total_cents: lodging_total_cents,
            deposit_due_cents: deposit_due_cents
          })
        end)

      deposit_due_cents = Enum.reduce(room_rows, 0, &(&1.deposit_due_cents + &2))
      fixed_policy = policy_version(rate_plan, booked_on)

      group = %Group{
        group_id: group_id,
        guest_id: field(operation, "guest_id"),
        property_id: field(operation, "property_id"),
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: fixed_policy,
        refundable_until: refundable_until(fixed_policy, arrival_on),
        status: "active",
        revision: 1,
        lodging_total_cents: Enum.reduce(room_rows, 0, &(&1.lodging_total_cents + &2)),
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      }

      Repo.insert!(group)

      Enum.each(Enum.with_index(room_rows), fn {room, position} ->
        Repo.insert!(%GroupRoom{
          group_id: group_id,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          lodging_total_cents: room.lodging_total_cents,
          deposit_due_cents: room.deposit_due_cents,
          status: "active",
          cash_paid_cents: 0,
          credit_paid_cents: 0
        })
      end)

      applied(operation_id, %{
        group_id: group_id,
        deposit_due_cents: deposit_due_cents,
        revision: 1
      })
    else
      {:error, :invalid_stay} ->
        rejected(operation_id, "invalid_stay", %{group_id: group_id})

      {:error, :invalid_rooms} ->
        rejected(operation_id, "invalid_rooms", %{group_id: group_id})

      {:error, :invalid_rate_plan} ->
        rejected(operation_id, "invalid_rate_plan", %{group_id: group_id})
    end
  end

  defp process_group_operation(operation, operation_id, type) do
    group_id = field(operation, "group_id")

    if not valid_identifier?(group_id) do
      rejected(operation_id, "invalid_operation")
    else
      case Repo.get(Group, group_id) do
        nil ->
          rejected(operation_id, "group_not_found", %{group_id: group_id})

        group ->
          case check_expected_revision(operation, group, operation_id) do
            :ok ->
              apply_group_operation(operation, operation_id, type, group)

            rejection ->
              rejection
          end
      end
    end
  end

  defp process_transfer_operation(operation, operation_id) do
    source_group_id = field(operation, "source_group_id")
    destination_group_id = field(operation, "destination_group_id")

    cond do
      not valid_identifier?(source_group_id) or not valid_identifier?(destination_group_id) ->
        rejected(operation_id, "invalid_operation")

      true ->
        case Repo.get(Group, source_group_id) do
          nil ->
            rejected(operation_id, "group_not_found", %{group_id: source_group_id})

          source_group ->
            case Repo.get(Group, destination_group_id) do
              nil ->
                rejected(operation_id, "group_not_found", %{group_id: destination_group_id})

              destination_group ->
                with :ok <- check_expected_revision(operation, source_group, operation_id),
                     :ok <-
                       check_expected_revision(
                         operation,
                         destination_group,
                         operation_id,
                         "destination_expected_revision"
                       ) do
                  apply_transfer_operation(
                    operation,
                    operation_id,
                    source_group,
                    destination_group
                  )
                else
                  rejection -> rejection
                end
            end
        end
    end
  end

  defp apply_transfer_operation(operation, operation_id, source_group, destination_group) do
    cond do
      source_group.group_id == destination_group.group_id or
          source_group.guest_id != destination_group.guest_id ->
        rejected(operation_id, "invalid_transfer")

      source_group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: source_group.group_id})

      destination_group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: destination_group.group_id})

      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation")

      not valid_payment_amount?(field(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount")

      field(operation, "amount_cents") > held_funding(source_group) ->
        rejected(operation_id, "transfer_exceeds_held_funding")

      field(operation, "amount_cents") > stored_outstanding_deposit(destination_group) ->
        rejected(operation_id, "transfer_exceeds_outstanding")

      true ->
        # Legacy groups may not have room allocations yet.  Hydrate them only
        # after all rejection-only checks have passed so a handled rejection
        # remains state-preserving.
        ensure_room_accounting!(source_group)
        ensure_room_accounting!(destination_group)

        amount_cents = field(operation, "amount_cents")

        {payment_ids, _destination_rooms, moved} =
          transfer_funding!(source_group, destination_group, amount_cents)

        Enum.each(payment_ids, &mark_payment_transferred!/1)

        record_transfer_postings!(
          operation_id,
          operation,
          source_group,
          destination_group,
          moved.cash
        )

        sync_group_totals!(source_group)
        sync_group_totals!(destination_group)

        applied(operation_id, %{
          source_group_id: source_group.group_id,
          destination_group_id: destination_group.group_id,
          amount_cents: amount_cents,
          source_outstanding_deposit_cents: outstanding_deposit(source_group),
          destination_outstanding_deposit_cents: outstanding_deposit(destination_group),
          source_revision: source_group.revision + 1,
          destination_revision: destination_group.revision + 1
        })
    end
  end

  defp process_payment_operation(operation, operation_id, type) do
    payment_operation_id = field(operation, "payment_operation_id")

    cond do
      not valid_identifier?(payment_operation_id) ->
        rejected(operation_id, "invalid_operation")

      true ->
        case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
          nil ->
            rejected(operation_id, "operation_not_found")

          record ->
            if applied_cash_payment?(record) do
              group_id = decode_result(record.result)[:group_id]

              case Repo.get(Group, group_id) do
                nil ->
                  rejected(operation_id, "group_not_found", %{group_id: group_id})

                group ->
                  case check_expected_revision(operation, group, operation_id) do
                    :ok ->
                      case Repo.get(PaymentDisposition, payment_operation_id) do
                        nil ->
                          code =
                            if type == "reduce_cash_payment",
                              do: "payment_not_reducible",
                              else: "payment_not_chargeable"

                          rejected(operation_id, code)

                        _disposition ->
                          apply_group_operation(operation, operation_id, type, group)
                      end

                    rejection ->
                      rejection
                  end
              end
            else
              code =
                if type == "reduce_cash_payment",
                  do: "payment_not_reducible",
                  else: "payment_not_chargeable"

              rejected(operation_id, code)
            end
        end
    end
  end

  defp check_expected_revision(operation, group, operation_id, key \\ "expected_revision") do
    case field(operation, key) do
      nil ->
        :ok

      expected_revision when expected_revision === group.revision ->
        :ok

      expected_revision ->
        rejected(operation_id, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        })
    end
  end

  defp apply_group_operation(operation, operation_id, "record_cash_payment", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_payment_amount?(field(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", %{group_id: group.group_id})

      field(operation, "amount_cents") > stored_outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        amount_cents = field(operation, "amount_cents")
        ensure_room_accounting!(group)
        allocate_cash!(group, operation_id, amount_cents)
        sync_group_totals!(group)

        Repo.insert!(%PaymentDisposition{
          payment_operation_id: operation_id,
          original_group_id: group.group_id,
          recorded_cents: amount_cents,
          held_cents: amount_cents
        })

        ledger = ensure_ledger!()
        update_ledger!(ledger, %{cash_held_cents: ledger.cash_held_cents + amount_cents})

        record_finance_posting!(operation_id, operation, %{
          property_id: group.property_id,
          payment_operation_id: operation_id,
          received_cents: amount_cents
        })

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount_cents,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision + 1
        })
    end
  end

  defp apply_group_operation(operation, operation_id, "reschedule_group", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      true ->
        with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
             {:ok, new_arrival_on} <- parse_date(field(operation, "new_arrival_on")),
             true <- Date.compare(new_arrival_on, occurred_on) == :gt do
          nights = Date.diff(group.departure_on, group.arrival_on)
          new_departure_on = Date.add(new_arrival_on, nights)
          fixed_policy = policy_version(group)
          new_refundable_until = refundable_until(fixed_policy, new_arrival_on)

          update_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            policy_version: fixed_policy,
            refundable_until: new_refundable_until
          })

          applied(operation_id, %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            policy_version: fixed_policy,
            refundable_until: date_to_iso8601(new_refundable_until),
            revision: group.revision + 1
          })
        else
          _ -> rejected(operation_id, "invalid_stay", %{group_id: group.group_id})
        end
    end
  end

  defp apply_group_operation(operation, operation_id, "cancel_group", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_refund_method?(field(operation, "refund_method")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      true ->
        case parse_date(field(operation, "occurred_on")) do
          {:ok, occurred_on} ->
            refundable? = refundable_on?(group, occurred_on)
            method = refund_method(field(operation, "refund_method"))

            if not refundable? and method == "hotel_credit" do
              rejected(operation_id, "refund_method_not_available", %{group_id: group.group_id})
            else
              ensure_room_accounting!(group)
              active_room_ids = active_rooms(group.group_id) |> Enum.map(& &1.room_id)

              settlement =
                settle_selected_rooms!(
                  group,
                  active_room_ids,
                  operation_id,
                  operation,
                  occurred_on,
                  refundable?,
                  method
                )

              applied(
                operation_id,
                Map.merge(settlement, %{group_id: group.group_id, revision: group.revision + 1})
              )
            end

          {:error, :invalid_stay} ->
            rejected(operation_id, "invalid_stay", %{group_id: group.group_id})
        end
    end
  end

  defp apply_group_operation(operation, operation_id, "cancel_rooms", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      is_nil(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_refund_method?(field(operation, "refund_method")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_room_id_list?(field(operation, "room_ids")) ->
        rejected(operation_id, "invalid_rooms", %{group_id: group.group_id})

      true ->
        requested_ids = field(operation, "room_ids")
        rooms = active_rooms(group.group_id)

        if Enum.any?(requested_ids, fn room_id ->
             not Enum.any?(rooms, &(&1.room_id == room_id))
           end) or
             length(Enum.uniq(requested_ids)) != length(requested_ids) do
          rejected(operation_id, "invalid_rooms", %{group_id: group.group_id})
        else
          case parse_date(field(operation, "occurred_on")) do
            {:ok, occurred_on} ->
              refundable? = refundable_on?(group, occurred_on)
              method = refund_method(field(operation, "refund_method"))

              if not refundable? and method == "hotel_credit" do
                rejected(operation_id, "refund_method_not_available", %{group_id: group.group_id})
              else
                ensure_room_accounting!(group)

                selected_ids =
                  rooms |> Enum.filter(&(&1.room_id in requested_ids)) |> Enum.map(& &1.room_id)

                settlement =
                  settle_selected_rooms!(
                    group,
                    selected_ids,
                    operation_id,
                    operation,
                    occurred_on,
                    refundable?,
                    method
                  )

                applied(
                  operation_id,
                  Map.merge(settlement, %{
                    group_id: group.group_id,
                    cancelled_room_ids: selected_ids,
                    revision: group.revision + 1
                  })
                )
              end

            {:error, :invalid_stay} ->
              rejected(operation_id, "invalid_stay", %{group_id: group.group_id})
          end
        end
    end
  end

  defp apply_group_operation(operation, operation_id, "apply_hotel_credit", %Group{} = group) do
    cond do
      group.status != "active" ->
        rejected(operation_id, "group_not_active", %{group_id: group.group_id})

      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_payment_amount?(field(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", %{group_id: group.group_id})

      field(operation, "amount_cents") > stored_outstanding_deposit(group) ->
        rejected(operation_id, "payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        {:ok, occurred_on} = parse_date(field(operation, "occurred_on"))
        amount_cents = field(operation, "amount_cents")
        lots = available_credit_lots(group.guest_id, occurred_on)
        available_cents = Enum.reduce(lots, 0, &(&1.remaining_cents + &2))

        if available_cents < amount_cents do
          rejected(operation_id, "insufficient_credit", %{group_id: group.group_id})
        else
          ensure_room_accounting!(group)
          allocate_credit!(group, operation_id, lots, amount_cents)
          sync_group_totals!(group)

          record_credit_application_postings!(operation_id, operation)

          applied(operation_id, %{
            group_id: group.group_id,
            amount_cents: amount_cents,
            outstanding_deposit_cents: outstanding_deposit(group),
            revision: group.revision + 1
          })
        end
    end
  end

  defp apply_group_operation(operation, operation_id, "reduce_cash_payment", %Group{} = group) do
    payment_operation_id = field(operation, "payment_operation_id")
    disposition = Repo.get!(PaymentDisposition, payment_operation_id)
    held_cents = held_cash_for_payment(payment_operation_id)

    cond do
      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      not valid_payment_amount?(field(operation, "amount_cents")) ->
        rejected(operation_id, "invalid_amount", %{group_id: group.group_id})

      held_cents == 0 or disposition.charged_back ->
        rejected(operation_id, "payment_not_reducible", %{group_id: group.group_id})

      field(operation, "amount_cents") > held_cents ->
        rejected(operation_id, "reduction_exceeds_held_cash", %{group_id: group.group_id})

      true ->
        amount_cents = field(operation, "amount_cents")

        {affected_group_ids, removed_by_group} =
          remove_cash_allocations!(payment_operation_id, amount_cents)

        update_payment_disposition!(disposition, %{
          held_cents: disposition.held_cents - amount_cents,
          reduced_cents: disposition.reduced_cents + amount_cents
        })

        ledger = ensure_ledger!()

        update_ledger!(ledger, %{
          cash_held_cents: ledger.cash_held_cents - amount_cents,
          cash_reduced_cents: ledger.cash_reduced_cents + amount_cents
        })

        sync_affected_groups!(group, affected_group_ids)

        record_reduction_postings!(operation_id, operation, removed_by_group)

        applied(operation_id, %{
          payment_operation_id: payment_operation_id,
          group_id: group.group_id,
          amount_cents: amount_cents,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision + 1
        })
    end
  end

  defp apply_group_operation(operation, operation_id, "charge_back_payment", %Group{} = group) do
    payment_operation_id = field(operation, "payment_operation_id")
    disposition = Repo.get!(PaymentDisposition, payment_operation_id)

    cond do
      not valid_operation_date?(field(operation, "occurred_on")) ->
        rejected(operation_id, "invalid_operation", %{group_id: group.group_id})

      disposition.charged_back or disposition.recorded_cents == disposition.reduced_cents ->
        rejected(operation_id, "payment_not_chargeable", %{group_id: group.group_id})

      true ->
        held_cents = disposition.held_cents
        refunded_cents = disposition.refunded_cents
        retained_cents = disposition.retained_cents
        converted_cents = disposition.converted_to_credit_cents
        charged_back_cents = held_cents + refunded_cents + retained_cents + converted_cents

        {affected_group_ids, removed_by_group} =
          if held_cents > 0 do
            remove_cash_allocations!(payment_operation_id, held_cents)
          else
            {[], %{}}
          end

        {:ok, occurred_on} = parse_date(field(operation, "occurred_on"))

        revoked_credit =
          if converted_cents > 0,
            do: revoke_payment_credit!(payment_operation_id, occurred_on),
            else: []

        update_payment_disposition!(disposition, %{
          held_cents: 0,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0,
          charged_back_cents: disposition.charged_back_cents + charged_back_cents,
          charged_back: true
        })

        ledger = ensure_ledger!()

        update_ledger!(ledger, %{
          cash_held_cents: ledger.cash_held_cents - held_cents,
          cash_refunded_cents: ledger.cash_refunded_cents - refunded_cents,
          cash_retained_cents: ledger.cash_retained_cents - retained_cents,
          cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents - converted_cents,
          cash_charged_back_cents: ledger.cash_charged_back_cents + charged_back_cents
        })

        sync_affected_groups!(group, affected_group_ids)

        record_chargeback_postings!(
          operation_id,
          operation,
          payment_operation_id,
          removed_by_group,
          revoked_credit,
          refunded_cents,
          retained_cents,
          converted_cents
        )

        applied(operation_id, %{
          payment_operation_id: payment_operation_id,
          group_id: group.group_id,
          charged_back_cents: charged_back_cents,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision + 1
        })
    end
  end

  defp apply_group_operation(_operation, operation_id, _type, _group),
    do: rejected(operation_id, "invalid_operation")

  defp settle_selected_rooms!(
         group,
         room_ids,
         operation_id,
         operation,
         occurred_on,
         refundable?,
         method
       ) do
    rooms =
      GroupRoom
      |> where([room], room.group_id == ^group.group_id and room.room_id in ^room_ids)
      |> order_by([room], asc: room.position)
      |> Repo.all()

    cash_allocations = cash_allocations_for_rooms(group.group_id, room_ids)
    credit_allocations = credit_allocations_for_rooms(group.group_id, room_ids)
    cash_paid_cents = Enum.reduce(cash_allocations, 0, &(&1.amount_cents + &2))

    credit_events =
      Enum.map(credit_allocations, fn {allocation, _lot} ->
        if refundable? do
          restored =
            restore_credit_amount!(
              Repo.get!(CreditLot, allocation.credit_lot_id),
              allocation.amount_cents,
              occurred_on
            )

          Map.merge(restored, %{
            credit_lot_id: allocation.credit_lot_id,
            credit_applied_delta_cents: -allocation.amount_cents
          })
        else
          %{
            credit_lot_id: allocation.credit_lot_id,
            credit_applied_delta_cents: -allocation.amount_cents,
            consumed_cents: allocation.amount_cents
          }
        end
      end)

    Enum.each(rooms, fn room ->
      {cash_paid, credit_paid} = room_current_paid(room)

      update_room!(room, %{
        status: "cancelled",
        cash_paid_cents: cash_paid,
        credit_paid_cents: credit_paid
      })
    end)

    Enum.each(cash_allocations, &Repo.delete!/1)

    Enum.each(credit_allocations, fn {allocation, _lot} ->
      Repo.delete!(allocation)
    end)

    {refunded_cents, retained_cents, credit_issued_cents, credit_lot_id} =
      cond do
        not refundable? ->
          settle_payment_cash!(cash_allocations, :retained)
          {0, cash_paid_cents, 0, nil}

        method == "hotel_credit" ->
          {issued, lot_id} =
            issue_credit_lot!(group.guest_id, operation_id, cash_allocations, occurred_on)

          settle_payment_cash!(cash_allocations, :converted)
          {0, 0, issued, lot_id}

        true ->
          settle_payment_cash!(cash_allocations, :refunded)
          {cash_paid_cents, 0, 0, nil}
      end

    if Enum.empty?(active_rooms(group.group_id)) do
      update_group!(group, %{
        status: "cancelled",
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      })
    else
      sync_group_totals!(group)
    end

    ledger = ensure_ledger!()

    update_ledger!(ledger, %{
      cash_held_cents: ledger.cash_held_cents - cash_paid_cents,
      cash_refunded_cents: ledger.cash_refunded_cents + refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents + retained_cents,
      cash_converted_to_credit_cents:
        ledger.cash_converted_to_credit_cents +
          if(method == "hotel_credit" and refundable?, do: cash_paid_cents, else: 0)
    })

    cash_movement =
      cond do
        not refundable? -> :retained_cents
        method == "hotel_credit" -> :converted_to_credit_cents
        true -> :refunded_cents
      end

    cash_events =
      cash_allocations
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {payment_operation_id, allocations} ->
        Map.put(
          %{payment_operation_id: payment_operation_id},
          cash_movement,
          Enum.reduce(allocations, 0, &(&1.amount_cents + &2))
        )
      end)

    credit_events =
      if credit_lot_id do
        [
          %{
            credit_lot_id: credit_lot_id,
            issued_cents: credit_issued_cents,
            credit_available_delta_cents: credit_issued_cents
          }
          | credit_events
        ]
      else
        credit_events
      end

    record_settlement_postings!(
      operation_id,
      operation,
      group.property_id,
      cash_events,
      credit_events
    )

    %{
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents
    }
  end

  defp settle_payment_cash!(allocations, disposition) do
    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.each(fn {payment_operation_id, grouped_allocations} ->
      amount_cents = Enum.reduce(grouped_allocations, 0, &(&1.amount_cents + &2))

      if payment_operation_id do
        payment = Repo.get!(PaymentDisposition, payment_operation_id)

        changes =
          case disposition do
            :refunded ->
              %{
                held_cents: payment.held_cents - amount_cents,
                refunded_cents: payment.refunded_cents + amount_cents
              }

            :retained ->
              %{
                held_cents: payment.held_cents - amount_cents,
                retained_cents: payment.retained_cents + amount_cents
              }

            :converted ->
              %{
                held_cents: payment.held_cents - amount_cents,
                converted_to_credit_cents: payment.converted_to_credit_cents + amount_cents
              }
          end

        update_payment_disposition!(payment, changes)
      end
    end)
  end

  defp allocate_cash!(group, payment_operation_id, amount_cents) do
    distribute_funding!(group, amount_cents, fn room, amount ->
      insert_cash_allocation!(%CashAllocation{
        group_id: group.group_id,
        room_id: room.room_id,
        payment_operation_id: payment_operation_id,
        amount_cents: amount
      })

      update_room!(room, %{cash_paid_cents: room.cash_paid_cents + amount})
    end)
  end

  defp allocate_credit!(group, operation_id, lots, amount_cents) do
    room_chunks = funding_chunks(group, amount_cents)
    lot_remaining = Map.new(lots, &{&1.id, &1.remaining_cents})

    Enum.reduce(room_chunks, lot_remaining, fn {room, room_amount}, remaining_lots ->
      {next_lots, _remaining_room} =
        Enum.reduce_while(lots, {remaining_lots, room_amount}, fn lot, {balances, needed} ->
          amount_from_lot = min(needed, Map.get(balances, lot.id, 0))

          if amount_from_lot == 0 do
            {:cont, {balances, needed}}
          else
            Repo.update!(
              Ecto.Changeset.change(lot, %{
                remaining_cents: Map.fetch!(balances, lot.id) - amount_from_lot
              })
            )

            insert_credit_allocation!(%CreditAllocation{
              group_id: group.group_id,
              credit_lot_id: lot.id,
              room_id: room.room_id,
              source_operation_id: operation_id,
              amount_cents: amount_from_lot
            })

            balances = Map.put(balances, lot.id, Map.fetch!(balances, lot.id) - amount_from_lot)
            needed = needed - amount_from_lot
            if needed == 0, do: {:halt, {balances, needed}}, else: {:cont, {balances, needed}}
          end
        end)

      update_room!(room, %{credit_paid_cents: room.credit_paid_cents + room_amount})
      next_lots
    end)

    :ok
  end

  defp distribute_funding!(group, amount_cents, update_fun) do
    Enum.each(funding_chunks(group, amount_cents), fn {room, amount} ->
      update_fun.(room, amount)
    end)

    :ok
  end

  defp funding_chunks(group, amount_cents) do
    active_rooms(group.group_id)
    |> Enum.reduce_while({amount_cents, []}, fn room, {remaining, chunks} ->
      capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
      amount_for_room = min(remaining, capacity)

      if amount_for_room == 0 do
        {:cont, {remaining, chunks}}
      else
        next = remaining - amount_for_room
        result = {next, [{room, amount_for_room} | chunks]}
        if next == 0, do: {:halt, result}, else: {:cont, result}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp cash_allocations_for_rooms(group_id, room_ids) do
    CashAllocation
    |> where([allocation], allocation.group_id == ^group_id and allocation.room_id in ^room_ids)
    |> order_by([allocation], asc: allocation.allocation_order, asc: allocation.id)
    |> Repo.all()
  end

  defp credit_allocations_for_rooms(group_id, room_ids) do
    from(allocation in CreditAllocation,
      join: lot in CreditLot,
      on: lot.id == allocation.credit_lot_id,
      where: allocation.group_id == ^group_id and allocation.room_id in ^room_ids,
      order_by: [asc: allocation.allocation_order, asc: allocation.id],
      select: {allocation, lot}
    )
    |> Repo.all()
  end

  defp held_funding(%Group{} = group),
    do: max(group.cash_paid_cents || 0, 0) + max(group.credit_paid_cents || 0, 0)

  defp stored_outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp stored_outstanding_deposit(%Group{} = group),
    do: max((group.deposit_due_cents || 0) - (group.deposit_paid_cents || 0), 0)

  defp transfer_funding!(source_group, destination_group, amount_cents) do
    allocations = held_allocations(source_group.group_id)
    destination_rooms = active_rooms(destination_group.group_id)

    {remaining, destination_rooms, payment_ids, moved} =
      Enum.reduce_while(
        allocations,
        {amount_cents, destination_rooms, MapSet.new(), %{cash: 0, credit: 0}},
        fn entry, {remaining, rooms, payment_ids, moved} ->
          amount = min(remaining, entry.amount_cents)
          consume_allocation!(entry, amount)

          {rooms, payment_ids} =
            place_transferred_funding!(
              destination_group.group_id,
              rooms,
              entry,
              amount,
              payment_ids
            )

          moved = Map.update!(moved, entry.kind, &(&1 + amount))

          next_remaining = remaining - amount

          if next_remaining == 0 do
            {:halt, {next_remaining, rooms, payment_ids, moved}}
          else
            {:cont, {next_remaining, rooms, payment_ids, moved}}
          end
        end
      )

    if remaining != 0, do: raise("transfer allocation invariant violated")
    {MapSet.to_list(payment_ids), destination_rooms, moved}
  end

  defp held_allocations(group_id) do
    cash =
      CashAllocation
      |> where([allocation], allocation.group_id == ^group_id and not is_nil(allocation.room_id))
      |> Repo.all()
      |> Enum.map(fn allocation ->
        %{
          kind: :cash,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          allocation_order: allocation.allocation_order || 0,
          id: allocation.id
        }
      end)

    credit =
      CreditAllocation
      |> where([allocation], allocation.group_id == ^group_id and not is_nil(allocation.room_id))
      |> Repo.all()
      |> Enum.map(fn allocation ->
        %{
          kind: :credit,
          allocation: allocation,
          amount_cents: allocation.amount_cents,
          allocation_order: allocation.allocation_order || 0,
          id: allocation.id
        }
      end)

    Enum.sort_by(
      cash ++ credit,
      fn entry ->
        {entry.allocation_order, allocation_kind_order(entry.kind), entry.id}
      end,
      :desc
    )
  end

  defp allocation_kind_order(:cash), do: 1
  defp allocation_kind_order(:credit), do: 0

  defp consume_allocation!(%{kind: :cash, allocation: allocation}, amount_cents) do
    room = Repo.get_by!(GroupRoom, group_id: allocation.group_id, room_id: allocation.room_id)
    update_room!(room, %{cash_paid_cents: room.cash_paid_cents - amount_cents})

    if amount_cents == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, %{amount_cents: allocation.amount_cents - amount_cents})
      )
    end
  end

  defp consume_allocation!(%{kind: :credit, allocation: allocation}, amount_cents) do
    room = Repo.get_by!(GroupRoom, group_id: allocation.group_id, room_id: allocation.room_id)
    update_room!(room, %{credit_paid_cents: room.credit_paid_cents - amount_cents})

    if amount_cents == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, %{amount_cents: allocation.amount_cents - amount_cents})
      )
    end
  end

  defp place_transferred_funding!(group_id, rooms, entry, amount_cents, payment_ids) do
    {remaining, rooms, payment_ids} =
      Enum.reduce_while(rooms, {amount_cents, rooms, payment_ids}, fn room,
                                                                      {remaining, current_rooms,
                                                                       payment_ids} ->
        capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
        amount = min(remaining, capacity)

        if amount == 0 do
          {:cont, {remaining, current_rooms, payment_ids}}
        else
          insert_transferred_allocation!(group_id, room, entry, amount)

          updated_room =
            case entry.kind do
              :cash -> update_room!(room, %{cash_paid_cents: room.cash_paid_cents + amount})
              :credit -> update_room!(room, %{credit_paid_cents: room.credit_paid_cents + amount})
            end

          current_rooms =
            Enum.map(current_rooms, fn current ->
              if current.id == room.id, do: updated_room, else: current
            end)

          payment_ids =
            if entry.kind == :cash and entry.allocation.payment_operation_id do
              MapSet.put(payment_ids, entry.allocation.payment_operation_id)
            else
              payment_ids
            end

          next_remaining = remaining - amount

          if next_remaining == 0,
            do: {:halt, {next_remaining, current_rooms, payment_ids}},
            else: {:cont, {next_remaining, current_rooms, payment_ids}}
        end
      end)

    if remaining != 0, do: raise("destination allocation invariant violated")
    {rooms, payment_ids}
  end

  defp insert_transferred_allocation!(
         group_id,
         room,
         %{kind: :cash, allocation: allocation},
         amount
       ) do
    insert_cash_allocation!(%CashAllocation{
      group_id: group_id,
      room_id: room.room_id,
      payment_operation_id: allocation.payment_operation_id,
      amount_cents: amount
    })
  end

  defp insert_transferred_allocation!(
         group_id,
         room,
         %{kind: :credit, allocation: allocation},
         amount
       ) do
    insert_credit_allocation!(%CreditAllocation{
      group_id: group_id,
      room_id: room.room_id,
      credit_lot_id: allocation.credit_lot_id,
      source_operation_id: allocation.source_operation_id,
      amount_cents: amount
    })
  end

  defp insert_cash_allocation!(%CashAllocation{} = allocation) do
    Repo.insert!(%{allocation | allocation_order: next_allocation_order!()})
  end

  defp insert_credit_allocation!(%CreditAllocation{} = allocation) do
    Repo.insert!(%{allocation | allocation_order: next_allocation_order!()})
  end

  defp next_allocation_order! do
    [[next_order]] =
      Repo.query!("""
      SELECT COALESCE(MAX(allocation_order), 0) + 1
      FROM (
        SELECT allocation_order FROM cash_allocations
        UNION ALL
        SELECT allocation_order FROM credit_allocations
      )
      """).rows

    next_order
  end

  defp remove_cash_allocations!(payment_operation_id, amount_cents) do
    allocations =
      CashAllocation
      |> where([allocation], allocation.payment_operation_id == ^payment_operation_id)
      |> order_by([allocation], desc: allocation.allocation_order, desc: allocation.id)
      |> Repo.all()

    {_remaining, group_ids, amounts_by_group} =
      Enum.reduce_while(allocations, {amount_cents, MapSet.new(), %{}}, fn allocation,
                                                                           {remaining, group_ids,
                                                                            amounts_by_group} ->
        amount = min(remaining, allocation.amount_cents)
        room = Repo.get_by!(GroupRoom, group_id: allocation.group_id, room_id: allocation.room_id)
        update_room!(room, %{cash_paid_cents: room.cash_paid_cents - amount})

        if amount == allocation.amount_cents do
          Repo.delete!(allocation)
        else
          Repo.update!(
            Ecto.Changeset.change(allocation, %{amount_cents: allocation.amount_cents - amount})
          )
        end

        next = remaining - amount
        group_ids = MapSet.put(group_ids, allocation.group_id)

        amounts_by_group =
          Map.update(amounts_by_group, allocation.group_id, amount, &(&1 + amount))

        if next == 0,
          do: {:halt, {next, group_ids, amounts_by_group}},
          else: {:cont, {next, group_ids, amounts_by_group}}
      end)

    {MapSet.to_list(group_ids), amounts_by_group}
  end

  defp held_cash_for_payment(payment_operation_id) do
    CashAllocation
    |> where([allocation], allocation.payment_operation_id == ^payment_operation_id)
    |> select([allocation], sum(allocation.amount_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp issue_credit_lot!(_guest_id, _operation_id, [], _cancellation_date), do: {0, nil}

  defp issue_credit_lot!(guest_id, operation_id, cash_allocations, cancellation_date) do
    contributions = cash_contributions(cash_allocations)
    cash_cents = Enum.reduce(contributions, 0, fn {_source, amount}, total -> total + amount end)
    credit_issued_cents = credit_value(cash_cents)

    lot =
      Repo.insert!(%CreditLot{
        guest_id: guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued_cents,
        expires_on: Date.add(cancellation_date, 366),
        unrecovered_clawback_cents: 0
      })

    Enum.reduce(contributions, {0, 0}, fn {source, amount}, {running_cash, running_credit} ->
      next_cash = running_cash + amount
      next_credit = credit_value(next_cash)
      entitlement = next_credit - running_credit

      Repo.insert!(%CreditLotContribution{
        credit_lot_id: lot.id,
        payment_operation_id: source,
        entitlement_cents: entitlement
      })

      {next_cash, next_credit}
    end)

    {credit_issued_cents, lot.id}
  end

  defp cash_contributions(allocations) do
    Enum.reduce(allocations, [], fn allocation, contributions ->
      case List.last(contributions) do
        {source, _amount} when source == allocation.payment_operation_id ->
          List.update_at(contributions, -1, fn {same_source, amount} ->
            {same_source, amount + allocation.amount_cents}
          end)

        _ ->
          contributions ++ [{allocation.payment_operation_id, allocation.amount_cents}]
      end
    end)
  end

  defp restore_credit_amount!(lot, amount_cents, cancellation_date) do
    absorbed = min(amount_cents, lot.unrecovered_clawback_cents || 0)
    remaining_to_restore = amount_cents - absorbed

    restored =
      if remaining_to_restore > 0 and Date.compare(lot.expires_on, cancellation_date) == :gt do
        remaining_to_restore
      else
        0
      end

    expired = remaining_to_restore - restored
    changes = %{unrecovered_clawback_cents: (lot.unrecovered_clawback_cents || 0) - absorbed}

    changes =
      if restored > 0 do
        Map.put(changes, :remaining_cents, lot.remaining_cents + restored)
      else
        changes
      end

    Repo.update!(Ecto.Changeset.change(lot, changes))

    %{
      absorbed_cents: absorbed,
      expired_cents: expired,
      credit_available_delta_cents: restored
    }
  end

  defp revoke_payment_credit!(payment_operation_id, occurred_on) do
    CreditLotContribution
    |> where([contribution], contribution.payment_operation_id == ^payment_operation_id)
    |> Repo.all()
    |> Enum.map(fn contribution ->
      lot = Repo.get!(CreditLot, contribution.credit_lot_id)
      removed = min(lot.remaining_cents, contribution.entitlement_cents)

      reportable_removed =
        if Date.compare(lot.expires_on, occurred_on) == :gt, do: removed, else: 0

      Repo.update!(
        Ecto.Changeset.change(lot, %{
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents:
            (lot.unrecovered_clawback_cents || 0) + contribution.entitlement_cents - removed
        })
      )

      %{
        credit_lot_id: lot.id,
        revoked_cents: reportable_removed,
        credit_available_delta_cents: -reportable_removed
      }
    end)
  end

  defp active_rooms(group_id) do
    GroupRoom
    |> where([room], room.group_id == ^group_id and room.status == "active")
    |> order_by([room], asc: room.position)
    |> Repo.all()
  end

  defp room_current_paid(room) do
    cash =
      CashAllocation
      |> where(
        [allocation],
        allocation.group_id == ^room.group_id and allocation.room_id == ^room.room_id
      )
      |> select([allocation], sum(allocation.amount_cents))
      |> Repo.one()
      |> Kernel.||(0)

    credit =
      CreditAllocation
      |> where(
        [allocation],
        allocation.group_id == ^room.group_id and allocation.room_id == ^room.room_id
      )
      |> select([allocation], sum(allocation.amount_cents))
      |> Repo.one()
      |> Kernel.||(0)

    {cash, credit}
  end

  defp update_room!(room, changes), do: Repo.update!(Ecto.Changeset.change(room, changes))

  defp update_group!(%Group{} = group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp sync_group_totals!(%Group{} = group) do
    totals = active_totals(group.group_id)

    update_group!(group, %{
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents
    })
  end

  defp sync_affected_groups!(%Group{} = addressed_group, affected_group_ids) do
    addressed_group_id = addressed_group.group_id

    [addressed_group_id | affected_group_ids]
    |> Enum.uniq()
    |> Enum.each(fn group_id ->
      group =
        if group_id == addressed_group_id, do: addressed_group, else: Repo.get!(Group, group_id)

      sync_group_totals!(group)
    end)
  end

  defp active_totals(group_id) do
    rooms = active_rooms(group_id)
    cash = Enum.reduce(rooms, 0, &(&1.cash_paid_cents + &2))
    credit = Enum.reduce(rooms, 0, &(&1.credit_paid_cents + &2))

    %{
      lodging_total_cents: Enum.reduce(rooms, 0, &(&1.lodging_total_cents + &2)),
      deposit_due_cents: Enum.reduce(rooms, 0, &(&1.deposit_due_cents + &2)),
      deposit_paid_cents: cash + credit,
      cash_paid_cents: cash,
      credit_paid_cents: credit
    }
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(%Group{} = group) do
    totals = active_totals(group.group_id)
    max(totals.deposit_due_cents - totals.deposit_paid_cents, 0)
  end

  defp ensure_ledger!, do: Repo.get(Ledger, 1) || Repo.insert!(%Ledger{id: 1})

  defp update_ledger!(%Ledger{} = ledger, changes),
    do: Repo.update!(Ecto.Changeset.change(ledger, changes))

  defp ensure_room_accounting!(%Group{} = group) do
    rooms =
      GroupRoom
      |> where([room], room.group_id == ^group.group_id)
      |> order_by([room], asc: room.position)
      |> Repo.all()

    if group.status == "cancelled" do
      hydrate_cancelled_rooms!(group, rooms)
    else
      durable_sources = durable_funding_sources(group.group_id)
      ensure_durable_payment_dispositions!(durable_sources.cash)
      cash_total = aggregate_cash_paid(group)
      credit_total = aggregate_credit_paid(group)
      cash_allocated = sum_cash_allocations(group.group_id)
      cash_missing = max(cash_total - cash_allocated, 0)

      legacy_cash_total =
        max(cash_total - Enum.reduce(durable_sources.cash, 0, &(&1.amount + &2)), 0)

      legacy_cash = min(cash_missing, legacy_cash_total)

      if legacy_cash > 0,
        do:
          allocate_cash_sources!(group, [%{operation_id: nil, amount: legacy_cash}], legacy_cash)

      tag_legacy_credit_sources!(group.group_id, credit_total, durable_sources.credit)
      assign_unroomed_credit_allocations!(group, nil)

      Enum.reduce(durable_sources.ordered, cash_missing - legacy_cash, fn source,
                                                                          remaining_cash ->
        case source.type do
          :cash ->
            amount = min(source.amount, remaining_cash)

            if amount > 0,
              do:
                allocate_cash_sources!(
                  group,
                  [%{operation_id: source.operation_id, amount: amount}],
                  amount
                )

            remaining_cash - amount

          :credit ->
            assign_unroomed_credit_allocations!(group, source.operation_id)
            remaining_cash
        end
      end)
    end

    :ok
  end

  defp ensure_durable_payment_dispositions!(cash_sources) do
    Enum.each(cash_sources, fn source ->
      if record = Repo.get_by(OperationRecord, operation_id: source.operation_id) do
        ensure_payment_disposition!(record)
      end
    end)
  end

  defp hydrate_cancelled_rooms!(group, rooms) do
    if Enum.any?(rooms, &(&1.status == "active")) do
      cash_total = aggregate_cash_paid(group)
      credit_total = aggregate_credit_paid(group)

      Enum.reduce(rooms, {cash_total, credit_total}, fn room, {cash_left, credit_left} ->
        due = room.deposit_due_cents || 0
        cash = min(cash_left, due)
        credit = min(credit_left, max(due - cash, 0))

        update_room!(room, %{
          status: "cancelled",
          cash_paid_cents: cash,
          credit_paid_cents: credit
        })

        {cash_left - cash, credit_left - credit}
      end)
    end
  end

  defp allocate_cash_sources!(group, sources, amount_to_allocate) do
    sources =
      sources
      |> Enum.reject(fn source -> source.amount <= 0 end)
      |> Enum.reduce({amount_to_allocate, []}, fn source, {remaining, result} ->
        take = min(remaining, source.amount)
        {remaining - take, result ++ [{source.operation_id, take}]}
      end)
      |> elem(1)

    Enum.each(sources, fn {source, amount} ->
      distribute_funding!(group, amount, fn room, room_amount ->
        insert_cash_allocation!(%CashAllocation{
          group_id: group.group_id,
          room_id: room.room_id,
          payment_operation_id: source,
          amount_cents: room_amount
        })

        update_room!(room, %{cash_paid_cents: room.cash_paid_cents + room_amount})
      end)
    end)
  end

  defp tag_legacy_credit_sources!(group_id, credit_total, durable_sources) do
    untagged =
      CreditAllocation
      |> where(
        [allocation],
        allocation.group_id == ^group_id and is_nil(allocation.source_operation_id) and
          is_nil(allocation.room_id)
      )
      |> order_by([allocation], asc: allocation.id)
      |> Repo.all()

    legacy_amount = max(credit_total - Enum.reduce(durable_sources, 0, &(&1.amount + &2)), 0)

    source_amounts = [
      {nil, legacy_amount} | Enum.map(durable_sources, &{&1.operation_id, &1.amount})
    ]

    Enum.reduce(untagged, source_amounts, fn allocation, sources ->
      {segments, remaining_sources} = split_source_amount(allocation.amount_cents, sources)
      [{first_source, first_amount} | rest] = segments

      Repo.update!(
        Ecto.Changeset.change(allocation, %{
          amount_cents: first_amount,
          source_operation_id: first_source
        })
      )

      Enum.each(rest, fn {source, amount} ->
        insert_credit_allocation!(%CreditAllocation{
          group_id: allocation.group_id,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: amount,
          source_operation_id: source
        })
      end)

      remaining_sources
    end)

    :ok
  end

  defp split_source_amount(0, sources, segments), do: {Enum.reverse(segments), sources}

  defp split_source_amount(amount, [{_source, 0} | rest], segments),
    do: split_source_amount(amount, rest, segments)

  defp split_source_amount(amount, [{source, available} | rest], segments) do
    take = min(amount, available)
    sources = [{source, available - take} | rest]
    split_source_amount(amount - take, sources, [{source, take} | segments])
  end

  defp split_source_amount(amount, [], segments),
    do: {Enum.reverse([{nil, amount} | segments]), []}

  defp split_source_amount(amount, sources), do: split_source_amount(amount, sources, [])

  defp assign_unroomed_credit_allocations!(group, source_operation_id) do
    unroomed_query =
      CreditAllocation
      |> where(
        [allocation],
        allocation.group_id == ^group.group_id and is_nil(allocation.room_id)
      )

    unroomed_query =
      if is_nil(source_operation_id) do
        where(unroomed_query, [allocation], is_nil(allocation.source_operation_id))
      else
        where(
          unroomed_query,
          [allocation],
          allocation.source_operation_id == ^source_operation_id
        )
      end

    unroomed = unroomed_query |> order_by([allocation], asc: allocation.id) |> Repo.all()

    Enum.each(unroomed, fn allocation ->
      room =
        Enum.find(active_rooms(group.group_id), fn room ->
          room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents > 0
        end)

      if room do
        capacity = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(capacity, allocation.amount_cents)

        Repo.update!(
          Ecto.Changeset.change(allocation, %{room_id: room.room_id, amount_cents: amount})
        )

        update_room!(room, %{credit_paid_cents: room.credit_paid_cents + amount})

        if amount < allocation.amount_cents do
          insert_credit_allocation!(%CreditAllocation{
            group_id: allocation.group_id,
            credit_lot_id: allocation.credit_lot_id,
            amount_cents: allocation.amount_cents - amount,
            source_operation_id: allocation.source_operation_id
          })
        end
      end
    end)
  end

  defp sum_cash_allocations(group_id) do
    CashAllocation
    |> where([allocation], allocation.group_id == ^group_id)
    |> select([allocation], sum(allocation.amount_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp aggregate_cash_paid(%Group{cash_paid_cents: amount}) when is_integer(amount), do: amount

  defp aggregate_cash_paid(%Group{} = group),
    do: max(group.deposit_paid_cents - aggregate_credit_paid(group), 0)

  defp aggregate_credit_paid(%Group{credit_paid_cents: amount}) when is_integer(amount),
    do: amount

  defp aggregate_credit_paid(%Group{} = group) do
    CreditAllocation
    |> where([allocation], allocation.group_id == ^group.group_id)
    |> select([allocation], sum(allocation.amount_cents))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp durable_funding_sources(group_id) do
    OperationRecord
    |> order_by([record], asc: record.id)
    |> Repo.all()
    |> Enum.reduce(%{cash: [], credit: [], ordered: []}, fn record, sources ->
      result = decode_result(record.result)

      if result[:status] == "applied" and result[:group_id] == group_id do
        cond do
          record.type == "record_cash_payment" ->
            %{
              sources
              | cash:
                  sources.cash ++
                    [%{operation_id: record.operation_id, amount: result[:amount_cents]}],
                ordered:
                  sources.ordered ++
                    [
                      %{
                        type: :cash,
                        operation_id: record.operation_id,
                        amount: result[:amount_cents]
                      }
                    ]
            }

          record.type == "apply_hotel_credit" ->
            %{
              sources
              | credit:
                  sources.credit ++
                    [%{operation_id: record.operation_id, amount: result[:amount_cents]}],
                ordered:
                  sources.ordered ++
                    [
                      %{
                        type: :credit,
                        operation_id: record.operation_id,
                        amount: result[:amount_cents]
                      }
                    ]
            }

          true ->
            sources
        end
      else
        sources
      end
    end)
  end

  defp ensure_payment_disposition!(record) do
    case Repo.get(PaymentDisposition, record.operation_id) do
      nil ->
        result = decode_result(record.result)
        group = Repo.get(Group, result[:group_id])

        {held, refunded, retained, converted} =
          historical_payment_settlement(group, record, result[:amount_cents])

        if converted > 0 and group do
          backfill_historical_credit_contributions!(group)
        end

        Repo.insert!(%PaymentDisposition{
          payment_operation_id: record.operation_id,
          original_group_id: result[:group_id],
          recorded_cents: result[:amount_cents],
          held_cents: held,
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: converted
        })

      disposition ->
        disposition
    end
  end

  defp payment_disposition_snapshot(record, group_id) do
    case Repo.get(PaymentDisposition, record.operation_id) do
      nil ->
        result = decode_result(record.result)
        group = Repo.get(Group, group_id)

        {held, refunded, retained, converted} =
          historical_payment_settlement(group, record, result[:amount_cents])

        %PaymentDisposition{
          payment_operation_id: record.operation_id,
          original_group_id: group_id,
          recorded_cents: result[:amount_cents],
          held_cents: held,
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: converted
        }

      disposition ->
        disposition
    end
  end

  defp historical_payment_settlement(group, record, amount_cents) do
    held_cents = held_cash_for_payment(record.operation_id)

    case latest_cancellation(group.group_id) do
      nil ->
        # A legacy group may not have room allocations until it is first
        # accessed, so retain the historical all-held fallback when there is
        # no settlement record to explain a missing allocation.
        {max(held_cents, amount_cents), 0, 0, 0}

      cancellation ->
        settled_cents = max(amount_cents - held_cents, 0)

        case decode_result(cancellation.result) do
          %{refunded_cents: refunded} when refunded > 0 ->
            {held_cents, settled_cents, 0, 0}

          %{retained_cents: retained} when retained > 0 ->
            {held_cents, 0, settled_cents, 0}

          %{credit_issued_cents: issued} when issued > 0 ->
            {held_cents, 0, 0, settled_cents}

          _ ->
            {held_cents, 0, 0, 0}
        end
    end
  end

  defp latest_cancellation(group_id) do
    OperationRecord
    |> order_by([record], desc: record.id)
    |> Repo.all()
    |> Enum.find(fn record ->
      result = decode_result(record.result)

      record.type in ["cancel_group", "cancel_rooms"] and
        result[:status] == "applied" and
        result[:group_id] == group_id
    end)
  end

  defp backfill_historical_credit_contributions!(group) do
    cancellation =
      OperationRecord
      |> order_by([record], desc: record.id)
      |> Repo.all()
      |> Enum.find(fn record ->
        result = decode_result(record.result)

        record.type in ["cancel_group", "cancel_rooms"] and
          result[:status] == "applied" and
          result[:group_id] == group.group_id
      end)

    if cancellation do
      lot =
        Repo.get_by(CreditLot,
          source_operation_id: cancellation.operation_id,
          guest_id: group.guest_id
        )

      if lot do
        lot_id = lot.id

        if Repo.aggregate(
             from(contribution in CreditLotContribution,
               where: contribution.credit_lot_id == ^lot_id
             ),
             :count,
             :id
           ) == 0 do
          sources = durable_funding_sources(group.group_id)
          durable_cash = Enum.reduce(sources.cash, 0, &(&1.amount + &2))
          legacy_cash = max(aggregate_cash_paid(group) - durable_cash, 0)
          contributions = [%{operation_id: nil, amount: legacy_cash} | sources.cash]
          insert_credit_contributions!(lot, contributions)
        end
      end
    end
  end

  defp insert_credit_contributions!(lot, sources) do
    {_, _} =
      Enum.reduce(Enum.reject(sources, &(&1.amount <= 0)), {0, 0}, fn source,
                                                                      {running_cash,
                                                                       running_credit} ->
        next_cash = running_cash + source.amount
        next_credit = credit_value(next_cash)

        Repo.insert!(%CreditLotContribution{
          credit_lot_id: lot.id,
          payment_operation_id: source.operation_id,
          entitlement_cents: next_credit - running_credit
        })

        {next_cash, next_credit}
      end)
  end

  defp applied_cash_payment?(%OperationRecord{type: "record_cash_payment", result: result}),
    do: decode_result(result)[:status] == "applied"

  defp applied_cash_payment?(_record), do: false

  defp public_group(group) do
    ensure_room_accounting!(group)

    rooms =
      GroupRoom
      |> where([room], room.group_id == ^group.group_id)
      |> order_by([room], asc: room.position)
      |> Repo.all()

    totals =
      Enum.reduce(rooms, %{lodging: 0, due: 0, cash: 0, credit: 0}, fn room, totals ->
        if room.status == "active" do
          %{
            lodging: totals.lodging + room.lodging_total_cents,
            due: totals.due + room.deposit_due_cents,
            cash: totals.cash + room.cash_paid_cents,
            credit: totals.credit + room.credit_paid_cents
          }
        else
          totals
        end
      end)

    fixed_policy = policy_version(group)

    fixed_refundable_until =
      group.refundable_until || refundable_until(fixed_policy, group.arrival_on)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: fixed_policy,
      refundable_until: date_to_iso8601(fixed_refundable_until),
      status: group.status,
      revision: group.revision,
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
      lodging_total_cents: totals.lodging,
      deposit_due_cents: totals.due,
      deposit_paid_cents: totals.cash + totals.credit,
      cash_paid_cents: totals.cash,
      credit_paid_cents: totals.credit,
      outstanding_deposit_cents: max(totals.due - totals.cash - totals.credit, 0)
    }
  end

  defp public_payment(disposition) do
    payment = %{
      payment_operation_id: disposition.payment_operation_id,
      original_group_id: disposition.original_group_id,
      recorded_cents: disposition.recorded_cents,
      held_cents: disposition.held_cents,
      refunded_cents: disposition.refunded_cents,
      retained_cents: disposition.retained_cents,
      converted_to_credit_cents: disposition.converted_to_credit_cents,
      reduced_cents: disposition.reduced_cents,
      charged_back_cents: disposition.charged_back_cents
    }

    if disposition.transferred do
      Map.put(payment, :held_by_group, held_cash_by_group(disposition.payment_operation_id))
    else
      payment
    end
  end

  defp held_cash_by_group(payment_operation_id) do
    from(allocation in CashAllocation,
      where: allocation.payment_operation_id == ^payment_operation_id,
      group_by: allocation.group_id,
      order_by: [asc: allocation.group_id],
      select: {allocation.group_id, sum(allocation.amount_cents)}
    )
    |> Repo.all()
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
  end

  defp mark_payment_transferred!(payment_operation_id) do
    disposition =
      case Repo.get(PaymentDisposition, payment_operation_id) do
        nil ->
          record = Repo.get_by!(OperationRecord, operation_id: payment_operation_id)
          ensure_payment_disposition!(record)
          Repo.get!(PaymentDisposition, payment_operation_id)

        disposition ->
          disposition
      end

    unless disposition.transferred do
      update_payment_disposition!(disposition, %{transferred: true})
    end
  end

  defp update_payment_disposition!(disposition, changes),
    do: Repo.update!(Ecto.Changeset.change(disposition, changes))

  defp record_finance_posting!(operation_id, operation, attrs) do
    case Repo.get(FinanceReporting, 1) do
      nil ->
        :ok

      %{starts_on: starts_on} ->
        {:ok, occurred_on} = parse_date(field(operation, "occurred_on"))
        original_posting_on = later_date(occurred_on, starts_on)
        posting_on = finance_posting_date(original_posting_on)
        attrs = adjust_issued_credit_for_posting(attrs, posting_on)

        if finance_posting_effect?(attrs) do
          Repo.insert!(
            struct!(
              FinancePosting,
              Map.merge(
                %{
                  operation_id: operation_id,
                  posting_on: posting_on,
                  original_posting_on: original_posting_on
                },
                attrs
              )
            )
          )
        end
    end
  end

  defp finance_posting_date(original_posting_on) do
    case latest_finance_close() do
      nil ->
        original_posting_on

      close ->
        first_open_date = Date.add(close.period_end_on, 1)

        if Date.compare(original_posting_on, first_open_date) == :lt,
          do: first_open_date,
          else: original_posting_on
    end
  end

  defp adjust_issued_credit_for_posting(
         %{credit_lot_id: credit_lot_id, issued_cents: issued} = attrs,
         posting_on
       )
       when is_integer(issued) and issued > 0 do
    lot = Repo.get!(CreditLot, credit_lot_id)

    if Date.compare(lot.expires_on, posting_on) == :lt do
      attrs
      |> Map.put(:expired_cents, Map.get(attrs, :expired_cents, 0) + issued)
      |> Map.put(:credit_available_delta_cents, 0)
    else
      attrs
    end
  end

  defp adjust_issued_credit_for_posting(attrs, _posting_on), do: attrs

  defp finance_posting_effect?(attrs) do
    Enum.any?(
      [
        :received_cents,
        :transferred_in_cents,
        :transferred_out_cents,
        :refunded_cents,
        :retained_cents,
        :converted_to_credit_cents,
        :reduced_cents,
        :charged_back_cents,
        :issued_cents,
        :expired_cents,
        :consumed_cents,
        :revoked_cents,
        :absorbed_cents,
        :credit_available_delta_cents,
        :credit_applied_delta_cents
      ],
      &(Map.get(attrs, &1, 0) != 0)
    )
  end

  defp record_transfer_postings!(_operation_id, _operation, _source_group, _destination_group, 0),
    do: :ok

  defp record_transfer_postings!(operation_id, operation, source_group, destination_group, amount) do
    record_finance_posting!(operation_id, operation, %{
      property_id: source_group.property_id,
      transferred_out_cents: amount
    })

    record_finance_posting!(operation_id, operation, %{
      property_id: destination_group.property_id,
      transferred_in_cents: amount
    })
  end

  defp record_credit_application_postings!(operation_id, operation) do
    CreditAllocation
    |> where([allocation], allocation.source_operation_id == ^operation_id)
    |> group_by([allocation], allocation.credit_lot_id)
    |> select([allocation], {allocation.credit_lot_id, sum(allocation.amount_cents)})
    |> Repo.all()
    |> Enum.each(fn {credit_lot_id, amount_cents} ->
      record_finance_posting!(operation_id, operation, %{
        credit_lot_id: credit_lot_id,
        credit_available_delta_cents: -amount_cents,
        credit_applied_delta_cents: amount_cents
      })
    end)
  end

  defp record_settlement_postings!(
         operation_id,
         operation,
         property_id,
         cash_events,
         credit_events
       ) do
    Enum.each(cash_events, fn event ->
      record_finance_posting!(
        operation_id,
        operation,
        Map.put(event, :property_id, property_id)
      )
    end)

    Enum.each(credit_events, fn event ->
      record_finance_posting!(operation_id, operation, event)
    end)
  end

  defp record_reduction_postings!(operation_id, operation, removed_by_group) do
    Enum.each(removed_by_group, fn {group_id, amount_cents} ->
      group = Repo.get!(Group, group_id)

      record_finance_posting!(operation_id, operation, %{
        property_id: group.property_id,
        payment_operation_id: field(operation, "payment_operation_id"),
        reduced_cents: amount_cents
      })
    end)
  end

  defp record_chargeback_postings!(
         operation_id,
         operation,
         payment_operation_id,
         removed_by_group,
         revoked_credit,
         refunded_cents,
         retained_cents,
         converted_cents
       ) do
    Enum.each(removed_by_group, fn {group_id, amount_cents} ->
      group = Repo.get!(Group, group_id)

      record_finance_posting!(operation_id, operation, %{
        property_id: group.property_id,
        payment_operation_id: payment_operation_id,
        charged_back_cents: amount_cents
      })
    end)

    history =
      FinancePosting
      |> where([posting], posting.payment_operation_id == ^payment_operation_id)
      |> where(
        [posting],
        posting.refunded_cents != 0 or posting.retained_cents != 0 or
          posting.converted_to_credit_cents != 0
      )
      |> order_by([posting], asc: posting.id)
      |> Repo.all()

    Enum.each(history, fn posting ->
      record_finance_posting!(operation_id, operation, %{
        property_id: posting.property_id,
        payment_operation_id: payment_operation_id,
        refunded_cents: -posting.refunded_cents,
        retained_cents: -posting.retained_cents,
        converted_to_credit_cents: -posting.converted_to_credit_cents,
        charged_back_cents:
          posting.refunded_cents + posting.retained_cents + posting.converted_to_credit_cents
      })
    end)

    record_chargeback_fallback_posting!(
      operation_id,
      operation,
      payment_operation_id,
      history,
      %{
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        converted_to_credit_cents: converted_cents
      }
    )

    Enum.each(revoked_credit, fn event ->
      record_finance_posting!(operation_id, operation, event)
    end)
  end

  defp record_chargeback_fallback_posting!(
         operation_id,
         operation,
         payment_operation_id,
         history,
         settled_amounts
       ) do
    disposition = Repo.get!(PaymentDisposition, payment_operation_id)

    settled =
      Enum.reduce(history, %{refunded: 0, retained: 0, converted: 0}, fn posting, totals ->
        %{
          refunded: totals.refunded + posting.refunded_cents,
          retained: totals.retained + posting.retained_cents,
          converted: totals.converted + posting.converted_to_credit_cents
        }
      end)

    fallback_property_id = payment_settlement_property(payment_operation_id, disposition)

    missing = %{
      refunded_cents: max(settled_amounts.refunded_cents - settled.refunded, 0),
      retained_cents: max(settled_amounts.retained_cents - settled.retained, 0),
      converted_to_credit_cents:
        max(settled_amounts.converted_to_credit_cents - settled.converted, 0)
    }

    amount_cents =
      missing.refunded_cents + missing.retained_cents + missing.converted_to_credit_cents

    if amount_cents > 0 do
      record_finance_posting!(
        operation_id,
        operation,
        Map.merge(missing, %{
          property_id: fallback_property_id,
          payment_operation_id: payment_operation_id,
          charged_back_cents: amount_cents
        })
      )
    end
  end

  defp payment_settlement_property(payment_operation_id, disposition) do
    property_id_from_credit =
      CreditLotContribution
      |> where([contribution], contribution.payment_operation_id == ^payment_operation_id)
      |> order_by([contribution], asc: contribution.id)
      |> Repo.all()
      |> Enum.find_value(fn contribution ->
        lot = Repo.get!(CreditLot, contribution.credit_lot_id)
        cancellation = Repo.get_by(OperationRecord, operation_id: lot.source_operation_id)

        if cancellation do
          result = decode_result(cancellation.result)
          group = Repo.get(Group, result[:group_id])
          if group, do: group.property_id
        end
      end)

    original_group = Repo.get!(Group, disposition.original_group_id)

    property_id_from_cancellation =
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          nil

        payment_record ->
          OperationRecord
          |> order_by([record], desc: record.id)
          |> Repo.all()
          |> Enum.find_value(fn cancellation ->
            result = decode_result(cancellation.result)

            if cancellation.id > payment_record.id and
                 cancellation.type in ["cancel_group", "cancel_rooms"] and
                 result[:status] == "applied" do
              group = Repo.get(Group, result[:group_id])

              if group && group.guest_id == original_group.guest_id do
                group.property_id
              end
            end
          end)
      end

    property_id_from_credit || property_id_from_cancellation || original_group.property_id
  end

  defp ledger_as_of(as_of) do
    ledger = Repo.get(Ledger, 1) || %Ledger{id: 1}
    public_ledger(ledger, as_of)
  end

  defp available_credit_lots(guest_id, as_of) do
    CreditLot
    |> where(
      [lot],
      lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^as_of
    )
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id)
    |> Repo.all()
  end

  defp credit_liability(as_of) do
    available_cents =
      CreditLot
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on > ^as_of)
      |> select([lot], sum(lot.remaining_cents))
      |> Repo.one()
      |> Kernel.||(0)

    applied_cents =
      from(allocation in CreditAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: group.status == "active",
        select: sum(allocation.amount_cents)
      )
      |> Repo.one()
      |> Kernel.||(0)

    available_cents + applied_cents
  end

  defp credit_shortfall do
    from(lot in CreditLot,
      left_join: allocation in CreditAllocation,
      on: allocation.credit_lot_id == lot.id,
      left_join: group in Group,
      on: group.group_id == allocation.group_id and group.status == "active",
      group_by: lot.id,
      select:
        {lot.unrecovered_clawback_cents,
         sum(
           fragment(
             "CASE WHEN ? IS NULL THEN 0 ELSE ? END",
             group.group_id,
             allocation.amount_cents
           )
         )}
    )
    |> Repo.all()
    |> Enum.reduce(0, fn {unrecovered, applied}, total ->
      total + min(unrecovered || 0, applied || 0)
    end)
  end

  defp public_ledger(ledger, as_of) do
    %{
      cash_held_cents: ledger.cash_held_cents,
      cash_refunded_cents: ledger.cash_refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents,
      cash_converted_to_credit_cents: ledger.cash_converted_to_credit_cents,
      cash_reduced_cents: ledger.cash_reduced_cents,
      cash_charged_back_cents: ledger.cash_charged_back_cents,
      credit_liability_cents: credit_liability(as_of),
      credit_shortfall_cents: credit_shortfall()
    }
  end

  defp build_daily_finance_report(%FinanceReporting{} = reporting, date, status \\ "open") do
    postings =
      FinancePosting
      |> where(
        [posting],
        posting.posting_on >= ^reporting.starts_on and posting.posting_on <= ^date
      )
      |> order_by([posting], asc: posting.id)
      |> Repo.all()

    {cash, late_cash} = daily_cash_report(reporting, postings, date)
    {credit, late_credit} = daily_credit_report(reporting, postings, date)

    %{
      date: Date.to_iso8601(date),
      status: status,
      cash: cash,
      credit: credit,
      late_adjustments: %{cash: late_cash, credit: late_credit}
    }
  end

  defp daily_cash_report(_reporting, postings, date) do
    opening =
      FinanceReportingOpening
      |> Repo.all()
      |> Map.new(&{&1.property_id, &1.opening_held_cents})

    daily_postings = Enum.filter(postings, &(Date.compare(&1.posting_on, date) == :eq))
    {late_postings, ordinary_postings} = Enum.split_with(daily_postings, &late_posting?/1)

    movement_by_property =
      Enum.reduce(postings, %{}, fn posting, by_property ->
        if posting.property_id do
          Map.update(
            by_property,
            posting.property_id,
            cash_movement(posting),
            &add_cash_movements(&1, cash_movement(posting))
          )
        else
          by_property
        end
      end)

    daily_movement_by_property = cash_movements_by_property(ordinary_postings)
    late_movement_by_property = cash_movements_by_property(late_postings)

    properties =
      (Map.keys(opening) ++
         Map.keys(movement_by_property) ++
         Map.keys(daily_movement_by_property) ++
         Map.keys(late_movement_by_property))
      |> Enum.uniq()
      |> Enum.sort()

    cash_report =
      Enum.flat_map(properties, fn property_id ->
        opening_held_cents = Map.get(opening, property_id, 0)
        movements = Map.get(daily_movement_by_property, property_id, empty_cash_movements())
        late_movements = Map.get(late_movement_by_property, property_id, empty_cash_movements())
        cumulative_movements = Map.get(movement_by_property, property_id, empty_cash_movements())
        closing_held_cents = cash_closing(opening_held_cents, cumulative_movements)

        if opening_held_cents == 0 and closing_held_cents == 0 and
             Enum.all?(Map.values(movements), &(&1 == 0)) and
             Enum.all?(Map.values(late_movements), &(&1 == 0)) do
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

    {cash_report, late_cash_report(late_movement_by_property)}
  end

  defp cash_movements_by_property(postings) do
    Enum.reduce(postings, %{}, fn posting, by_property ->
      if posting.property_id do
        Map.update(
          by_property,
          posting.property_id,
          cash_movement(posting),
          &add_cash_movements(&1, cash_movement(posting))
        )
      else
        by_property
      end
    end)
  end

  defp late_cash_report(movement_by_property) do
    movement_by_property
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {property_id, movements} ->
      if Enum.all?(Map.values(movements), &(&1 == 0)) do
        []
      else
        [%{property_id: property_id, movements: movements}]
      end
    end)
  end

  defp late_posting?(%FinancePosting{original_posting_on: nil}), do: false

  defp late_posting?(%FinancePosting{} = posting),
    do: Date.compare(posting.posting_on, posting.original_posting_on) == :gt

  defp cash_movement(posting) do
    %{
      received_cents: posting.received_cents,
      transferred_in_cents: posting.transferred_in_cents,
      transferred_out_cents: posting.transferred_out_cents,
      refunded_cents: posting.refunded_cents,
      retained_cents: posting.retained_cents,
      converted_to_credit_cents: posting.converted_to_credit_cents,
      reduced_cents: posting.reduced_cents,
      charged_back_cents: posting.charged_back_cents
    }
  end

  defp empty_cash_movements do
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

  defp add_cash_movements(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.fetch!(right, key)} end)
  end

  defp cash_closing(opening_held_cents, movements) do
    opening_held_cents + movements.received_cents + movements.transferred_in_cents -
      movements.transferred_out_cents - movements.refunded_cents - movements.retained_cents -
      movements.converted_to_credit_cents - movements.reduced_cents - movements.charged_back_cents
  end

  defp daily_credit_report(reporting, postings, date) do
    daily_postings = Enum.filter(postings, &(Date.compare(&1.posting_on, date) == :eq))
    {late_postings, ordinary_postings} = Enum.split_with(daily_postings, &late_posting?/1)
    today_expired = automatic_expired_cents(reporting, postings, date)
    cumulative_expired = automatic_expired_cents(reporting, postings, date, :cumulative)
    movements = credit_movements(ordinary_postings, today_expired)
    late_expiry_adjustment_cents = late_expiry_correction(reporting, postings, date)

    late_movements =
      late_postings
      |> credit_movements(0)
      |> Map.update!(:expired_cents, &(&1 + late_expiry_adjustment_cents))

    cumulative = credit_movements(postings, cumulative_expired)
    cumulative_expiry_adjustment_cents = cumulative_expiry_correction(reporting, postings, date)

    cumulative =
      Map.update!(cumulative, :expired_cents, &(&1 + cumulative_expiry_adjustment_cents))

    opening_liability_cents = reporting.opening_credit_liability_cents

    {
      %{
        opening_liability_cents: opening_liability_cents,
        movements: movements,
        closing_liability_cents:
          opening_liability_cents + cumulative.issued_cents - cumulative.expired_cents -
            cumulative.consumed_cents - cumulative.revoked_cents - cumulative.absorbed_cents
      },
      late_movements
    }
  end

  defp credit_movements(postings, automatic_expired_cents) do
    %{
      issued_cents: sum_posting_field(postings, :issued_cents),
      expired_cents: sum_posting_field(postings, :expired_cents) + automatic_expired_cents,
      consumed_cents: sum_posting_field(postings, :consumed_cents),
      revoked_cents: sum_posting_field(postings, :revoked_cents),
      absorbed_cents: sum_posting_field(postings, :absorbed_cents)
    }
  end

  defp sum_posting_field(postings, field),
    do: Enum.reduce(postings, 0, &(&1 |> Map.fetch!(field) |> Kernel.+(&2)))

  defp automatic_expired_cents(reporting, postings, date),
    do: automatic_expired_cents(reporting, postings, date, :daily)

  defp automatic_expired_cents(reporting, postings, date, mode) do
    automatic_expired_cents(reporting, postings, date, mode, &posting_expiry_date/1)
  end

  defp automatic_expired_cents(reporting, postings, date, mode, expiry_date_fun) do
    lots = reporting_credit_lots(reporting, postings)

    Enum.reduce(lots, 0, fn lot, total ->
      expiry_date = Date.add(lot.expires_on, 1)

      include? =
        case mode do
          :daily ->
            expiry_date == date

          :cumulative ->
            Date.compare(expiry_date, reporting.starts_on) != :lt and
              Date.compare(expiry_date, date) != :gt
        end

      if include? do
        available_at_expiry =
          lot.available_cents +
            Enum.reduce(postings, 0, fn posting, delta ->
              if posting.credit_lot_id == lot.credit_lot_id and
                   Date.compare(expiry_date_fun.(posting), lot.expires_on) != :gt do
                delta + posting.credit_available_delta_cents
              else
                delta
              end
            end)

        total + max(available_at_expiry, 0)
      else
        total
      end
    end)
  end

  defp cumulative_expiry_correction(reporting, postings, date) do
    posted_expired = automatic_expired_cents(reporting, postings, date, :cumulative)

    original_expired =
      automatic_expired_cents(
        reporting,
        postings,
        date,
        :cumulative,
        &credit_delta_expiry_date/1
      )

    original_expired - posted_expired
  end

  defp late_expiry_correction(reporting, postings, date) do
    if Enum.any?(postings, fn posting ->
         Date.compare(posting.posting_on, date) == :eq and late_posting?(posting)
       end) do
      current_correction = cumulative_expiry_correction(reporting, postings, date)

      previous_postings =
        Enum.reject(postings, &(Date.compare(&1.posting_on, date) == :eq))

      previous_correction =
        cumulative_expiry_correction(reporting, previous_postings, Date.add(date, -1))

      current_correction - previous_correction
    else
      0
    end
  end

  defp posting_expiry_date(posting), do: posting.posting_on

  defp credit_delta_expiry_date(
         %FinancePosting{original_posting_on: original_posting_on} = posting
       ) do
    if late_posting?(posting), do: original_posting_on, else: posting.posting_on
  end

  defp reporting_credit_lots(_reporting, postings) do
    opening_lots =
      FinanceReportingCreditOpening
      |> Repo.all()
      |> Map.new(fn opening ->
        {opening.credit_lot_id,
         %{
           credit_lot_id: opening.credit_lot_id,
           available_cents: opening.available_cents,
           applied_cents: opening.applied_cents,
           expires_on: opening.expires_on
         }}
      end)

    issue_lot_ids =
      postings
      |> Enum.filter(&(&1.issued_cents > 0 and &1.credit_lot_id))
      |> Enum.map(& &1.credit_lot_id)

    Enum.reduce(Enum.uniq(issue_lot_ids), opening_lots, fn credit_lot_id, lots ->
      if Map.has_key?(lots, credit_lot_id) do
        lots
      else
        lot = Repo.get!(CreditLot, credit_lot_id)

        Map.put(lots, credit_lot_id, %{
          credit_lot_id: credit_lot_id,
          available_cents: 0,
          applied_cents: 0,
          expires_on: lot.expires_on
        })
      end
    end)
    |> Map.values()
  end

  defp parse_as_of(params) do
    case field(params, "on") do
      nil ->
        {:ok, Date.utc_today()}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  end

  defp parse_reporting_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_reporting_date}
    end
  end

  defp parse_reporting_date(_value), do: {:error, :invalid_reporting_date}

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version(_rate_plan, _booked_on), do: nil

  defp policy_version(%Group{
         policy_version: version,
         rate_plan: rate_plan,
         booked_on: booked_on
       }),
       do: version || policy_version(rate_plan, booked_on)

  defp refundable_until("flex-14", arrival_on), do: Date.add(arrival_on, -14)
  defp refundable_until("flex-30", arrival_on), do: Date.add(arrival_on, -30)
  defp refundable_until(_policy_version, _arrival_on), do: nil

  defp refundable_on?(group, occurred_on) do
    policy_version(group) in ["flex-14", "flex-30"] and
      Date.compare(occurred_on, refundable_until(policy_version(group), group.arrival_on)) != :gt
  end

  defp date_to_iso8601(nil), do: nil
  defp date_to_iso8601(date), do: Date.to_iso8601(date)
  defp valid_refund_method?(nil), do: true
  defp valid_refund_method?(method), do: method in ["cash", "hotel_credit"]
  defp refund_method(nil), do: "cash"
  defp refund_method(method), do: method

  defp validate_stay({:ok, arrival_on}, {:ok, departure_on}),
    do: validate_stay(arrival_on, departure_on)

  defp validate_stay(arrival_on, departure_on),
    do: if(Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay})

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and unique_room_ids?(rooms) do
      {:ok,
       Enum.map(rooms, fn room ->
         %{room_id: field(room, "room_id"), nightly_rate_cents: field(room, "nightly_rate_cents")}
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp valid_room?(room) when is_map(room),
    do:
      valid_identifier?(field(room, "room_id")) and is_integer(field(room, "nightly_rate_cents")) and
        field(room, "nightly_rate_cents") > 0

  defp valid_room?(_room), do: false

  defp unique_room_ids?(rooms) do
    room_ids = Enum.map(rooms, &field(&1, "room_id"))
    length(room_ids) == length(Enum.uniq(room_ids))
  end

  defp valid_room_id_list?(room_ids),
    do: is_list(room_ids) and room_ids != [] and Enum.all?(room_ids, &valid_identifier?/1)

  defp valid_payment_amount?(amount_cents), do: is_integer(amount_cents) and amount_cents > 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_stay}
  defp valid_operation_date?(value), do: match?({:ok, _date}, parse_date(value))
  defp credit_value(cash_cents), do: cash_cents + round_half_up(cash_cents * 10, 100)

  defp round_half_up(numerator, denominator),
    do: div(numerator + div(denominator, 2), denominator)

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, result}), do: result
  defp decode_result(result), do: result |> Jason.decode!() |> atomize_result_keys()

  defp atomize_result_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {String.to_existing_atom(key), atomize_result_keys(value)} end)
  end

  defp atomize_result_keys(list) when is_list(list), do: Enum.map(list, &atomize_result_keys/1)
  defp atomize_result_keys(value), do: value

  defp durable_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) -> type
      type -> canonical_json(type)
    end
  end

  defp canonical_json(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, nested_value} -> {to_string(key), nested_value} end)
      |> Enum.sort_by(&elem(&1, 0))

    encoded_pairs =
      Enum.map_join(pairs, ",", fn {key, nested_value} ->
        Jason.encode!(key) <> ":" <> canonical_json(nested_value)
      end)

    "{" <> encoded_pairs <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp rejected(operation_id, code, fields \\ %{}),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, fields)

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, fields)

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@key_atoms, key))
    end
  end

  defp field(_map, _key), do: nil
  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0
end
