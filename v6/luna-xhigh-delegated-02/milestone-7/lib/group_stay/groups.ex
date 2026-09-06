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
  alias GroupStay.FinanceMovement
  alias GroupStay.FinancePeriodClose
  alias GroupStay.FinanceReporting
  alias GroupStay.FinanceReportSnapshot
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @policy_versions ~w(flex-14 flex-30 advance-nonrefundable)
  @new_policy_start ~D[2027-01-01]
  @credit_expiry_days 366

  @cash_movement_keys ~w(
    received_cents
    transferred_in_cents
    transferred_out_cents
    refunded_cents
    retained_cents
    converted_to_credit_cents
    reduced_cents
    charged_back_cents
  )a
  @credit_movement_keys ~w(issued_cents expired_cents consumed_cents revoked_cents absorbed_cents)a

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
          statement = %{
            payment_operation_id: payment.payment_operation_id,
            original_group_id: payment.group_id,
            recorded_cents: payment.recorded_cents,
            held_cents: payment.held_cents,
            refunded_cents: payment.refunded_cents,
            retained_cents: payment.retained_cents,
            converted_to_credit_cents: payment.converted_to_credit_cents,
            reduced_cents: payment.reduced_cents,
            charged_back_cents: payment.charged_back_cents
          }

          statement =
            if payment.transferred == true,
              do:
                Map.put(
                  statement,
                  :held_by_group,
                  held_cash_by_group(payment.payment_operation_id)
                ),
              else: statement

          {:ok, statement}

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

  @spec parse_reporting_date(String.t() | nil) :: {:ok, Date.t()} | :error
  def parse_reporting_date(value), do: parse_date(value)

  @spec daily_finance_report(Date.t()) :: {:ok, map()} | {:error, String.t()}
  def daily_finance_report(date) when is_struct(date, Date) do
    case Repo.get(FinanceReportSnapshot, date) do
      %FinanceReportSnapshot{data_json: data_json} ->
        {:ok, Jason.decode!(data_json)}

      nil ->
        case Repo.get(FinanceReporting, 1) do
          nil ->
            {:error, "report_not_available"}

          %FinanceReporting{starts_on: starts_on} = reporting ->
            if Date.compare(date, starts_on) == :lt do
              {:error, "report_not_available"}
            else
              {:ok, build_daily_finance_report(reporting, date)}
            end
        end
    end
  end

  def daily_finance_report(_date), do: {:error, "report_not_available"}

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

  @doc """
  Assign a shared, durable creation order to the allocation rows that existed
  before transfer support was installed.
  """
  @spec backfill_allocation_order() :: :ok
  def backfill_allocation_order do
    operations =
      Repo.all(
        from operation in Operation, select: {operation.operation_id, operation.commit_sequence}
      )
      |> Map.new()

    rows =
      (Repo.all(from(allocation in CashAllocation)) |> Enum.map(&{:cash, &1})) ++
        (Repo.all(from(allocation in HotelCreditAllocation)) |> Enum.map(&{:credit, &1}))

    rows
    |> Enum.sort_by(fn {kind, row} ->
      operation_id = if(kind == :cash, do: row.payment_operation_id, else: row.operation_id)

      {Map.get(operations, operation_id, 0), if(kind == :cash, do: 0, else: 1), row.id}
    end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{kind, row}, order} ->
      schema = if kind == :cash, do: CashAllocation, else: HotelCreditAllocation

      query =
        from allocation in schema,
          where: allocation.id == ^row.id,
          update: [set: [allocation_order: ^order]]

      Repo.update_all(query, [])
    end)

    Repo.query!("UPDATE allocation_sequences SET next_order = ? WHERE id = 1", [length(rows)])

    :ok
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
      "transfer_deposit" -> transfer_deposit(operation, operation_id)
      "start_finance_reporting" -> start_finance_reporting(operation, operation_id)
      "close_finance_period" -> close_finance_period(operation, operation_id)
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
              before = finance_snapshot()
              result = process_operation_uncached(operation)
              commit_sequence = next_commit_sequence()

              if result[:status] == "applied" do
                if value(operation, "type") == "start_finance_reporting" do
                  set_reporting_commit_sequence!(commit_sequence)
                end

                record_finance_movements!(
                  operation,
                  result,
                  before,
                  finance_snapshot(),
                  commit_sequence
                )
              end

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

  defp start_finance_reporting(operation, operation_id) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, starts_on} <- parse_date(value(operation, "starts_on")) do
      case Repo.get(FinanceReporting, 1) do
        %FinanceReporting{} ->
          rejected(operation_id, "reporting_already_started")

        nil ->
          opening = finance_opening_position(starts_on)

          %FinanceReporting{}
          |> FinanceReporting.changeset(%{
            id: 1,
            starts_on: starts_on,
            opening_cash_json: Jason.encode!(opening.cash_by_property),
            opening_credit_lots_json: Jason.encode!(opening.credit_lots),
            opening_liability_cents: opening.credit_liability_cents
          })
          |> Repo.insert!()

          applied(operation_id, starts_on: Date.to_iso8601(starts_on))
      end
    else
      {:error, "invalid_operation"} -> rejected(operation_id, "invalid_operation")
      :error -> rejected(operation_id, "invalid_reporting_date")
    end
  end

  defp close_finance_period(operation, operation_id) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, period_end_on} <- parse_date(value(operation, "period_end_on")),
         %FinanceReporting{} = reporting <- Repo.get(FinanceReporting, 1),
         true <- Date.compare(period_end_on, reporting.starts_on) in [:eq, :gt],
         latest <- latest_finance_close(),
         true <- is_nil(latest) or Date.compare(period_end_on, latest.period_end_on) == :gt do
      publish_finance_period!(reporting, operation_id, period_end_on)
      applied(operation_id, period_end_on: Date.to_iso8601(period_end_on))
    else
      {:error, "invalid_operation"} -> rejected(operation_id, "invalid_operation")
      :error -> rejected(operation_id, "invalid_period")
      nil -> rejected(operation_id, "invalid_period")
      false -> rejected(operation_id, "invalid_period")
    end
  end

  defp publish_finance_period!(%FinanceReporting{} = reporting, operation_id, period_end_on) do
    Date.range(reporting.starts_on, period_end_on)
    |> Enum.each(fn report_date ->
      if is_nil(Repo.get(FinanceReportSnapshot, report_date)) do
        data =
          reporting
          |> build_daily_finance_report(report_date)
          |> Map.put(:status, "closed")

        %FinanceReportSnapshot{}
        |> FinanceReportSnapshot.changeset(%{
          report_date: report_date,
          close_period_end_on: period_end_on,
          data_json: Jason.encode!(data)
        })
        |> Repo.insert!()
      end
    end)

    %FinancePeriodClose{}
    |> FinancePeriodClose.changeset(%{
      operation_id: operation_id,
      period_end_on: period_end_on,
      commit_sequence: next_commit_sequence()
    })
    |> Repo.insert!()
  end

  defp set_reporting_commit_sequence!(commit_sequence) do
    Repo.update_all(
      from(reporting in FinanceReporting, where: reporting.id == 1),
      set: [start_commit_sequence: commit_sequence]
    )
  end

  defp finance_opening_position(starts_on) do
    groups = Repo.all(from group in Group, select: group)

    cash_by_property =
      Enum.reduce(groups, %{}, fn group, totals ->
        if group.status == "active" do
          cash = totals_from_details(room_accounting(group)).cash_paid_cents
          Map.update(totals, group.property_id, cash, &(&1 + cash))
        else
          totals
        end
      end)

    active_credit_cents =
      groups
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(fn group -> totals_from_details(room_accounting(group)).credit_paid_cents end)
      |> Enum.sum()

    credit_lots =
      Repo.all(from lot in HotelCreditLot, order_by: [asc: lot.id])
      |> Enum.filter(&(Date.compare(&1.expires_on, starts_on) == :gt))
      |> Enum.map(fn lot ->
        %{
          lot_id: lot.id,
          remaining_cents: lot.remaining_cents,
          expires_on: Date.to_iso8601(lot.expires_on)
        }
      end)

    %{
      cash_by_property: cash_by_property,
      credit_lots: credit_lots,
      credit_liability_cents:
        active_credit_cents + Enum.sum(Enum.map(credit_lots, & &1.remaining_cents))
    }
  end

  defp finance_snapshot do
    groups = Repo.all(from group in Group, select: group)

    group_info =
      Map.new(groups, fn group ->
        active_room_ids =
          group
          |> room_specs()
          |> Enum.filter(&(&1.status == "active"))
          |> Enum.map(& &1.room_id)
          |> MapSet.new()

        details = room_accounting(group)

        {group.group_id,
         %{
           property_id: group.property_id,
           status: group.status,
           active_room_ids: active_room_ids,
           cash_held_cents: totals_from_details(details).cash_paid_cents
         }}
      end)

    %{
      groups: group_info,
      cash_allocations:
        Repo.all(from(allocation in CashAllocation))
        |> Enum.map(fn allocation ->
          %{
            id: allocation.id,
            group_id: allocation.group_id,
            room_id: allocation.room_id,
            payment_operation_id: allocation.payment_operation_id,
            amount_cents: allocation.amount_cents
          }
        end),
      credit_allocations:
        Repo.all(from(allocation in HotelCreditAllocation))
        |> Enum.map(fn allocation ->
          %{
            id: allocation.id,
            group_id: allocation.group_id,
            room_id: allocation.room_id,
            lot_id: allocation.lot_id,
            amount_cents: allocation.amount_cents
          }
        end),
      payments:
        Repo.all(from(payment in CashPayment))
        |> Map.new(fn payment -> {payment.payment_operation_id, payment} end),
      lots:
        Repo.all(from(lot in HotelCreditLot))
        |> Map.new(fn lot ->
          {lot.id,
           %{
             source_operation_id: lot.source_operation_id,
             remaining_cents: lot.remaining_cents,
             unrecovered_clawback_cents: lot.unrecovered_clawback_cents || 0,
             expires_on: lot.expires_on
           }}
        end)
    }
  end

  defp record_finance_movements!(operation, result, before, after_snapshot, commit_sequence) do
    events =
      finance_cash_events(operation, result, before, after_snapshot) ++
        finance_credit_events(operation, result, before, after_snapshot)

    original_posting_on = reporting_base_posting_on(operation)
    posting_on = reporting_posting_on(operation)

    Enum.each(events, fn event ->
      if event.amount_cents != 0 do
        %FinanceMovement{}
        |> FinanceMovement.changeset(
          Map.merge(event, %{
            operation_id: value(operation, "operation_id"),
            commit_sequence: commit_sequence,
            original_posting_on: original_posting_on,
            posting_on: posting_on
          })
        )
        |> Repo.insert!()
      end
    end)
  end

  defp reporting_base_posting_on(operation) do
    occurred_on =
      case parse_date(value(operation, "occurred_on")) do
        {:ok, date} -> date
        :error -> Date.utc_today()
      end

    case Repo.get(FinanceReporting, 1) do
      %FinanceReporting{starts_on: starts_on} ->
        if Date.compare(occurred_on, starts_on) == :lt, do: starts_on, else: occurred_on

      nil ->
        occurred_on
    end
  end

  defp reporting_posting_on(operation) do
    base = reporting_base_posting_on(operation)

    case latest_finance_close() do
      %FinancePeriodClose{period_end_on: period_end_on} ->
        open_on = Date.add(period_end_on, 1)
        if Date.compare(base, open_on) == :lt, do: open_on, else: base

      nil ->
        base
    end
  end

  defp latest_finance_close do
    Repo.one(
      from close in FinancePeriodClose,
        order_by: [desc: close.period_end_on],
        limit: 1
    )
  end

  defp finance_cash_events(operation, result, before, after_snapshot) do
    case value(operation, "type") do
      "record_cash_payment" ->
        [
          cash_event(
            "received_cents",
            result_value(result, "amount_cents"),
            group_property(
              after_snapshot,
              before,
              result_value(result, "group_id")
            )
          )
        ]

      "transfer_deposit" ->
        source_group_id = value(operation, "source_group_id")
        destination_group_id = value(operation, "destination_group_id")
        source_property = group_property(after_snapshot, before, source_group_id)
        destination_property = group_property(after_snapshot, before, destination_group_id)
        source_before = group_cash_held(before, source_group_id)
        source_after = group_cash_held(after_snapshot, source_group_id)
        destination_before = group_cash_held(before, destination_group_id)
        destination_after = group_cash_held(after_snapshot, destination_group_id)

        cash_events = []

        cash_events =
          if source_before > source_after,
            do: [
              cash_event("transferred_out_cents", source_before - source_after, source_property)
            ],
            else: cash_events

        if destination_after > destination_before,
          do:
            cash_events ++
              [
                cash_event(
                  "transferred_in_cents",
                  destination_after - destination_before,
                  destination_property
                )
              ],
          else: cash_events

      "cancel_group" ->
        cancellation_cash_events(operation, before, after_snapshot)

      "cancel_rooms" ->
        cancellation_cash_events(operation, before, after_snapshot)

      "reduce_cash_payment" ->
        payment_cash_delta_events(
          value(operation, "payment_operation_id"),
          before,
          after_snapshot,
          "reduced_cents"
        )

      "charge_back_payment" ->
        chargeback_cash_events(value(operation, "payment_operation_id"), before, after_snapshot)

      _ ->
        []
    end
  end

  defp cancellation_cash_events(operation, before, after_snapshot) do
    property_id =
      group_property(
        after_snapshot,
        before,
        value(operation, "group_id")
      )

    payment_events =
      payment_ids(before, after_snapshot)
      |> Enum.flat_map(fn payment_id ->
        payment_before = Map.get(before.payments, payment_id)
        payment_after = Map.get(after_snapshot.payments, payment_id)

        [
          {"refunded_cents",
           payment_value(payment_after, :refunded_cents) -
             payment_value(payment_before, :refunded_cents)},
          {"retained_cents",
           payment_value(payment_after, :retained_cents) -
             payment_value(payment_before, :retained_cents)},
          {"converted_to_credit_cents",
           payment_value(payment_after, :converted_to_credit_cents) -
             payment_value(payment_before, :converted_to_credit_cents)}
        ]
        |> Enum.flat_map(fn {movement, amount} ->
          if amount > 0, do: [cash_event(movement, amount, property_id, payment_id)], else: []
        end)
      end)

    group_id = value(operation, "group_id")
    before_group = Map.get(before.groups, group_id)
    after_group = Map.get(after_snapshot.groups, group_id)

    legacy_events =
      [
        {:cash_refunded_cents, "refunded_cents"},
        {:cash_retained_cents, "retained_cents"},
        {:cash_converted_to_credit_cents, "converted_to_credit_cents"}
      ]
      |> Enum.flat_map(fn {field, movement} ->
        amount = group_value(after_group, field) - group_value(before_group, field)
        if amount > 0, do: [cash_event(movement, amount, property_id)], else: []
      end)

    payment_events ++ legacy_events
  end

  defp chargeback_cash_events(payment_id, before, after_snapshot) do
    held_events =
      payment_cash_delta_events(payment_id, before, after_snapshot, "charged_back_cents")

    settlement_reversals =
      Repo.all(
        from movement in FinanceMovement,
          where:
            movement.payment_operation_id == ^payment_id and
              movement.category == "cash" and
              movement.movement in ^[
                "refunded_cents",
                "retained_cents",
                "converted_to_credit_cents"
              ]
      )
      |> Enum.flat_map(fn movement ->
        [
          cash_event(
            movement.movement,
            -movement.amount_cents,
            movement.property_id,
            payment_id
          ),
          cash_event(
            "charged_back_cents",
            movement.amount_cents,
            movement.property_id,
            payment_id
          )
        ]
      end)

    fallback_reversal =
      if settlement_reversals == [] do
        payment_before = Map.get(before.payments, payment_id)
        payment_after = Map.get(after_snapshot.payments, payment_id)
        property_id = payment_group_property(before, after_snapshot, payment_id)

        [
          {:refunded_cents, "refunded_cents"},
          {:retained_cents, "retained_cents"},
          {:converted_to_credit_cents, "converted_to_credit_cents"}
        ]
        |> Enum.flat_map(fn {field, movement} ->
          amount = payment_value(payment_before, field) - payment_value(payment_after, field)

          if amount > 0,
            do: [
              cash_event(movement, -amount, property_id, payment_id),
              cash_event("charged_back_cents", amount, property_id, payment_id)
            ],
            else: []
        end)
      else
        []
      end

    held_events ++ settlement_reversals ++ fallback_reversal
  end

  defp payment_cash_delta_events(payment_id, before, after_snapshot, movement) do
    cash_by_property_before = payment_cash_by_property(before, payment_id)
    cash_by_property_after = payment_cash_by_property(after_snapshot, payment_id)

    Map.keys(Map.merge(cash_by_property_before, cash_by_property_after))
    |> Enum.flat_map(fn property_id ->
      amount =
        Map.get(cash_by_property_before, property_id, 0) -
          Map.get(cash_by_property_after, property_id, 0)

      if amount > 0, do: [cash_event(movement, amount, property_id, payment_id)], else: []
    end)
  end

  defp finance_credit_events(operation, _result, before, after_snapshot) do
    case value(operation, "type") do
      "apply_hotel_credit" ->
        lot_deltas(before, after_snapshot, fn lot_id, before_lot, after_lot ->
          amount = before_lot.remaining_cents - after_lot.remaining_cents
          if amount > 0, do: [credit_event("credit_applied", amount, lot_id)], else: []
        end)

      "cancel_group" ->
        cancellation_credit_events(operation, before, after_snapshot)

      "cancel_rooms" ->
        cancellation_credit_events(operation, before, after_snapshot)

      "charge_back_payment" ->
        lot_deltas(before, after_snapshot, fn lot_id, before_lot, after_lot ->
          amount = before_lot.remaining_cents - after_lot.remaining_cents

          if amount > 0 and
               Date.compare(after_lot.expires_on, reporting_posting_on(operation)) == :gt,
             do: [credit_event("revoked_cents", amount, lot_id)],
             else: []
        end)

      _ ->
        []
    end
  end

  defp cancellation_credit_events(operation, before, after_snapshot) do
    group_id = value(operation, "group_id")
    removed_by_lot = credit_allocation_delta_by_lot(before, after_snapshot, group_id)
    refundable? = cancellation_is_refundable?(operation, group_id)

    settlement_events =
      Enum.flat_map(removed_by_lot, fn {lot_id, removed} ->
        before_lot = Map.get(before.lots, lot_id)
        after_lot = Map.get(after_snapshot.lots, lot_id)

        cond do
          removed <= 0 or is_nil(before_lot) or is_nil(after_lot) ->
            []

          refundable? ->
            absorbed =
              max(
                before_lot.unrecovered_clawback_cents -
                  after_lot.unrecovered_clawback_cents,
                0
              )

            if Date.compare(after_lot.expires_on, cancellation_occurred_on(operation)) == :gt do
              restored = max(after_lot.remaining_cents - before_lot.remaining_cents, 0)

              [
                if(restored > 0, do: credit_event("credit_restored", restored, lot_id)),
                if(absorbed > 0, do: credit_event("absorbed_cents", absorbed, lot_id))
              ]
              |> Enum.reject(&is_nil/1)
            else
              expired = max(removed - absorbed, 0)

              [
                if(expired > 0, do: credit_event("expired_cents", expired, lot_id)),
                if(absorbed > 0, do: credit_event("absorbed_cents", absorbed, lot_id))
              ]
              |> Enum.reject(&is_nil/1)
            end

          true ->
            [credit_event("consumed_cents", removed, lot_id)]
        end
      end)

    issued_events =
      after_snapshot.lots
      |> Enum.flat_map(fn {lot_id, lot} ->
        if not Map.has_key?(before.lots, lot_id) and
             lot.source_operation_id == value(operation, "operation_id"),
           do: [credit_event("issued_cents", lot.remaining_cents, lot_id)],
           else: []
      end)

    settlement_events ++ issued_events
  end

  defp lot_deltas(before, after_snapshot, fun) do
    Map.keys(Map.merge(before.lots, after_snapshot.lots))
    |> Enum.flat_map(fn lot_id ->
      case {Map.get(before.lots, lot_id), Map.get(after_snapshot.lots, lot_id)} do
        {%{} = before_lot, %{} = after_lot} ->
          fun.(lot_id, before_lot, after_lot)

        _ ->
          []
      end
    end)
  end

  defp credit_allocation_delta_by_lot(before, after_snapshot, group_id) do
    before_by_lot = credit_allocations_by_lot(before, group_id)
    after_by_lot = credit_allocations_by_lot(after_snapshot, group_id)

    Map.keys(Map.merge(before_by_lot, after_by_lot))
    |> Map.new(fn lot_id ->
      {lot_id, max(Map.get(before_by_lot, lot_id, 0) - Map.get(after_by_lot, lot_id, 0), 0)}
    end)
    |> Enum.reject(fn {_lot_id, amount} -> amount == 0 end)
  end

  defp credit_allocations_by_lot(snapshot, group_id) do
    snapshot.credit_allocations
    |> Enum.filter(&(&1.group_id == group_id))
    |> Enum.group_by(& &1.lot_id)
    |> Map.new(fn {lot_id, rows} -> {lot_id, Enum.sum(Enum.map(rows, & &1.amount_cents))} end)
  end

  defp credit_event(movement, amount, lot_id),
    do: %{
      category:
        if(String.starts_with?(movement, "credit_"), do: "credit_internal", else: "credit"),
      movement: movement,
      amount_cents: amount,
      lot_id: lot_id
    }

  defp cash_event(movement, amount, property_id, payment_id \\ nil),
    do: %{
      category: "cash",
      movement: movement,
      amount_cents: amount,
      property_id: property_id,
      payment_operation_id: payment_id
    }

  defp cancellation_is_refundable?(operation, group_id) do
    case {Repo.get_by(Group, group_id: group_id), cancellation_occurred_on(operation)} do
      {%Group{} = group, occurred_on} -> refundable?(group, occurred_on)
      _ -> false
    end
  end

  defp cancellation_occurred_on(operation) do
    case parse_date(value(operation, "occurred_on")) do
      {:ok, date} -> date
      :error -> reporting_posting_on(operation)
    end
  end

  defp build_daily_finance_report(%FinanceReporting{} = reporting, date) do
    start_commit_sequence = reporting.start_commit_sequence || 0

    movements =
      Repo.all(
        from movement in FinanceMovement,
          where: movement.commit_sequence > ^start_commit_sequence,
          order_by: [asc: movement.id]
      )

    cash_movements = Enum.filter(movements, &(&1.category == "cash"))
    credit_movements = Enum.filter(movements, &(&1.category in ["credit", "credit_internal"]))
    opening_cash = Jason.decode!(reporting.opening_cash_json)
    opening_lots = Jason.decode!(reporting.opening_credit_lots_json)

    %{
      date: Date.to_iso8601(date),
      status: "open",
      cash:
        build_cash_report(
          opening_cash,
          cash_movements,
          date
        ),
      credit:
        build_credit_report(
          reporting,
          opening_lots,
          credit_movements,
          date
        ),
      late_adjustments: build_late_adjustments(cash_movements, credit_movements, date)
    }
  end

  defp build_cash_report(opening_cash, movements, date) do
    eligible_movements = Enum.filter(movements, &(Date.compare(&1.posting_on, date) != :gt))

    properties =
      (Map.keys(opening_cash) ++ Enum.map(eligible_movements, & &1.property_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(properties, fn property_id ->
      opening_movements =
        Enum.filter(eligible_movements, fn movement ->
          movement.property_id == property_id and Date.compare(movement.posting_on, date) == :lt
        end)

      today_movements =
        Enum.filter(eligible_movements, fn movement ->
          movement.property_id == property_id and
            Date.compare(movement.posting_on, date) == :eq and
            not late_adjustment_movement?(movement)
        end)

      late_movements =
        Enum.filter(eligible_movements, fn movement ->
          movement.property_id == property_id and
            Date.compare(movement.posting_on, date) == :eq and
            late_adjustment_movement?(movement)
        end)

      opening_held = Map.get(opening_cash, property_id, 0) + cash_effect(opening_movements)
      movements_json = cash_movements_json(today_movements)
      closing_held = opening_held + cash_effect(today_movements) + cash_effect(late_movements)

      if opening_held != 0 or closing_held != 0 or cash_movements_nonzero?(movements_json) do
        [
          %{
            property_id: property_id,
            opening_held_cents: opening_held,
            movements: movements_json,
            closing_held_cents: closing_held
          }
        ]
      else
        []
      end
    end)
  end

  defp build_late_adjustments(cash_movements, credit_movements, date) do
    late_cash =
      cash_movements
      |> Enum.filter(fn movement ->
        Date.compare(movement.posting_on, date) == :eq and
          late_adjustment_movement?(movement)
      end)

    late_credit =
      credit_movements
      |> Enum.filter(fn movement ->
        Date.compare(movement.posting_on, date) == :eq and
          late_adjustment_movement?(movement)
      end)

    %{
      cash: late_cash_movements_json(late_cash),
      credit: late_credit_movements_json(late_credit)
    }
  end

  defp late_cash_movements_json(movements) do
    movements
    |> Enum.group_by(& &1.property_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {property_id, property_movements} ->
      movement_totals = cash_movements_json(property_movements)

      if cash_movements_nonzero?(movement_totals),
        do: [%{property_id: property_id, movements: movement_totals}],
        else: []
    end)
  end

  defp late_credit_movements_json(movements) do
    movements
    |> Enum.filter(&(&1.category == "credit"))
    |> credit_movements_json(0)
  end

  defp late_adjustment_movement?(%FinanceMovement{} = movement) do
    original_posting_on = movement.original_posting_on || movement.posting_on
    Date.compare(original_posting_on, movement.posting_on) == :lt
  end

  defp build_credit_report(reporting, opening_lots, movements, date) do
    eligible_movements = Enum.filter(movements, &(Date.compare(&1.posting_on, date) != :gt))

    {expiry_before, expiry_today} =
      credit_expiry_totals(reporting, opening_lots, eligible_movements, date)

    opening_movements =
      Enum.filter(eligible_movements, fn movement ->
        Date.compare(movement.posting_on, date) == :lt
      end)

    today_movements =
      Enum.filter(eligible_movements, fn movement ->
        Date.compare(movement.posting_on, date) == :eq
      end)

    opening_credit =
      reporting.opening_liability_cents +
        credit_effect(opening_movements) - expiry_before

    movements_json =
      today_movements
      |> Enum.reject(&late_adjustment_movement?/1)
      |> credit_movements_json(expiry_today)

    closing_credit = opening_credit + credit_effect(today_movements) - expiry_today

    %{
      opening_liability_cents: opening_credit,
      movements: movements_json,
      closing_liability_cents: closing_credit
    }
  end

  defp cash_movements_json(movements) do
    Enum.reduce(movements, empty_cash_movements(), fn movement, totals ->
      key = String.to_existing_atom(movement.movement)
      Map.update!(totals, key, &(&1 + movement.amount_cents))
    end)
  end

  defp credit_movements_json(movements, expired_cents) do
    totals =
      movements
      |> Enum.filter(&(&1.category == "credit"))
      |> Enum.reduce(empty_credit_movements(), fn movement, totals ->
        key = String.to_existing_atom(movement.movement)
        Map.update!(totals, key, &(&1 + movement.amount_cents))
      end)

    Map.update!(totals, :expired_cents, &(&1 + expired_cents))
  end

  defp empty_cash_movements, do: Map.new(@cash_movement_keys, &{&1, 0})
  defp empty_credit_movements, do: Map.new(@credit_movement_keys, &{&1, 0})

  defp cash_movements_nonzero?(movements),
    do: Enum.any?(movements, fn {_key, amount} -> amount != 0 end)

  defp cash_effect(movements) do
    Enum.reduce(movements, 0, fn movement, total ->
      sign = if movement.movement in ["received_cents", "transferred_in_cents"], do: 1, else: -1
      total + sign * movement.amount_cents
    end)
  end

  defp credit_effect(movements) do
    movements
    |> Enum.filter(&(&1.category == "credit"))
    |> Enum.reduce(0, fn movement, total ->
      if movement.movement == "issued_cents",
        do: total + movement.amount_cents,
        else: total - movement.amount_cents
    end)
  end

  defp credit_expiry_totals(reporting, opening_lots, movements, date) do
    opening_lots = Map.new(opening_lots, &{&1["lot_id"], &1})
    report_start = reporting.starts_on

    lot_ids =
      Map.keys(opening_lots) ++
        (movements
         |> Enum.map(& &1.lot_id)
         |> Enum.reject(&is_nil/1))

    lots =
      Repo.all(from lot in HotelCreditLot, where: lot.id in ^Enum.uniq(lot_ids))

    Enum.reduce(lots, {0, 0}, fn lot, {before_total, today_total} ->
      if Date.compare(lot.expires_on, report_start) != :lt and
           Date.compare(lot.expires_on, date) != :gt do
        expired = credit_available_at_expiry(lot, opening_lots, movements)

        if Date.compare(lot.expires_on, date) == :lt,
          do: {before_total + expired, today_total},
          else: {before_total, today_total + expired}
      else
        {before_total, today_total}
      end
    end)
  end

  defp credit_available_at_expiry(lot, opening_lots, movements) do
    base =
      case Map.get(opening_lots, lot.id) do
        nil -> 0
        opening_lot -> opening_lot["remaining_cents"]
      end

    issue =
      movements
      |> Enum.filter(fn movement ->
        movement.category == "credit" and movement.movement == "issued_cents" and
          movement.lot_id == lot.id and Date.compare(movement.posting_on, lot.expires_on) != :gt
      end)
      |> Enum.sum_by(& &1.amount_cents)

    adjustments =
      movements
      |> Enum.filter(fn movement ->
        movement.category == "credit_internal" and movement.lot_id == lot.id and
          Date.compare(movement.posting_on, lot.expires_on) != :gt
      end)
      |> Enum.reduce(0, fn movement, total ->
        case movement.movement do
          "credit_applied" -> total - movement.amount_cents
          "credit_restored" -> total + movement.amount_cents
          "revoked_cents" -> total - movement.amount_cents
          _ -> total
        end
      end)

    max(base + issue + adjustments, 0)
  end

  defp group_property(after_snapshot, before, group_id) do
    case Map.get(after_snapshot.groups, group_id) || Map.get(before.groups, group_id) do
      %{property_id: property_id} -> property_id
      _ -> nil
    end
  end

  defp group_cash_held(snapshot, group_id),
    do: get_in(snapshot, [:groups, group_id, :cash_held_cents]) || 0

  defp payment_ids(before, after_snapshot),
    do: Map.keys(Map.merge(before.payments, after_snapshot.payments))

  defp payment_value(nil, _field), do: 0
  defp payment_value(payment, field), do: Map.get(payment, field) || 0

  defp group_value(nil, _field), do: 0
  defp group_value(group, field), do: Map.get(group, field) || 0

  defp payment_group_property(before, after_snapshot, payment_id) do
    payment =
      Map.get(after_snapshot.payments, payment_id) || Map.get(before.payments, payment_id)

    if payment do
      group_property(after_snapshot, before, payment.group_id)
    end
  end

  defp payment_cash_by_property(snapshot, payment_id) do
    snapshot.cash_allocations
    |> Enum.filter(&(&1.payment_operation_id == payment_id))
    |> Enum.filter(&active_allocation?(snapshot, &1.group_id, &1.room_id))
    |> Enum.group_by(&group_property(snapshot, %{}, &1.group_id))
    |> Map.new(fn {property_id, rows} ->
      {property_id, Enum.sum(Enum.map(rows, & &1.amount_cents))}
    end)
  end

  defp active_allocation?(snapshot, group_id, room_id) do
    case Map.get(snapshot.groups, group_id) do
      %{status: "active", active_room_ids: room_ids} -> MapSet.member?(room_ids, room_id)
      _ -> false
    end
  end

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
             insert_cash_allocation!(%{
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
             insert_credit_allocation!(%{
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

  defp transfer_deposit(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, source_group_id} <- required_string(operation, "source_group_id") do
      case Repo.get_by(Group, group_id: source_group_id) do
        nil ->
          rejected(operation_id, "group_not_found", group_id: source_group_id)

        %Group{} = source_group ->
          case required_string(operation, "destination_group_id") do
            {:error, code} ->
              rejected(operation_id, code)

            {:ok, destination_group_id} ->
              case Repo.get_by(Group, group_id: destination_group_id) do
                nil ->
                  rejected(operation_id, "group_not_found", group_id: destination_group_id)

                %Group{} = destination_group ->
                  with :ok <- transfer_source_revision(operation, source_group),
                       :ok <- transfer_destination_revision(operation, destination_group),
                       :ok <- active_transfer_group(source_group),
                       :ok <- active_transfer_group(destination_group),
                       :ok <- valid_transfer_groups(source_group, destination_group),
                       :ok <- valid_transfer_occurred_on(operation),
                       {:ok, amount} <- transfer_amount(value(operation, "amount_cents")),
                       :ok <- transfer_has_capacity(source_group, destination_group, amount) do
                    case transfer_transaction(source_group, destination_group, amount) do
                      {:ok, transfer} ->
                        applied(operation_id,
                          source_group_id: source_group_id,
                          destination_group_id: destination_group_id,
                          amount_cents: amount,
                          source_outstanding_deposit_cents:
                            transfer.source_outstanding_deposit_cents,
                          destination_outstanding_deposit_cents:
                            transfer.destination_outstanding_deposit_cents,
                          source_revision: transfer.source_revision,
                          destination_revision: transfer.destination_revision
                        )

                      :conflict when retries > 0 ->
                        transfer_deposit(operation, operation_id, retries - 1)

                      :conflict ->
                        transfer_stale_result(
                          operation_id,
                          source_group_id,
                          value(operation, "expected_revision"),
                          current_revision(source_group_id)
                        )

                      {:error, code} ->
                        rejected(operation_id, code)
                    end
                  else
                    {:error, code} ->
                      rejected(operation_id, code)

                    {:error, code, error_group_id} ->
                      rejected(operation_id, code, group_id: error_group_id)

                    {:stale, group_id, expected, actual} ->
                      transfer_stale_result(operation_id, group_id, expected, actual)
                  end
              end
          end
      end
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp transfer_source_revision(operation, %Group{} = group) do
    case stale_revision_value(operation, "expected_revision", group) do
      :ok -> :ok
      {:stale, expected, actual} -> {:stale, group.group_id, expected, actual}
    end
  end

  defp transfer_destination_revision(operation, %Group{} = group) do
    case stale_revision_value(operation, "destination_expected_revision", group) do
      :ok -> :ok
      {:stale, expected, actual} -> {:stale, group.group_id, expected, actual}
    end
  end

  defp active_transfer_group(%Group{status: "active"}), do: :ok

  defp active_transfer_group(%Group{group_id: group_id}),
    do: {:error, "group_not_active", group_id}

  defp valid_transfer_groups(%Group{group_id: group_id}, %Group{group_id: group_id}),
    do: {:error, "invalid_transfer"}

  defp valid_transfer_groups(%Group{guest_id: guest_id}, %Group{guest_id: guest_id}), do: :ok
  defp valid_transfer_groups(_source, _destination), do: {:error, "invalid_transfer"}

  defp transfer_has_capacity(source_group, destination_group, amount) do
    source_held = transfer_held_funding(source_group)
    destination_outstanding = transfer_outstanding(destination_group)

    cond do
      source_held < amount -> {:error, "transfer_exceeds_held_funding"}
      destination_outstanding < amount -> {:error, "transfer_exceeds_outstanding"}
      true -> :ok
    end
  end

  defp transfer_amount(value) do
    case usable_amount(value) do
      {:ok, amount} -> {:ok, amount}
      :error -> {:error, "invalid_amount"}
    end
  end

  defp valid_transfer_occurred_on(operation) do
    case parse_date(value(operation, "occurred_on")) do
      {:ok, _date} -> :ok
      :error -> {:error, "invalid_operation"}
    end
  end

  defp transfer_transaction(source_group, destination_group, amount) do
    case Repo.transaction(fn ->
           source = prepare_room_accounting(source_group)
           destination = prepare_room_accounting(destination_group)
           source_rows = held_funding_allocations(source)
           destination_outstanding = transfer_outstanding(destination)

           cond do
             Enum.sum(Enum.map(source_rows, fn {_kind, row} -> row.amount_cents end)) < amount ->
               Repo.rollback({:rejected, "transfer_exceeds_held_funding"})

             destination_outstanding < amount ->
               Repo.rollback({:rejected, "transfer_exceeds_outstanding"})

             true ->
               source_units = take_funding_units(source_rows, amount)
               destination_plan = funding_plan(destination, amount)

               if destination_plan == :error do
                 Repo.rollback({:rejected, "transfer_exceeds_outstanding"})
               end

               assignments = transfer_assignments(source_units, destination_plan)
               remove_funding_units!(source_units)

               Enum.each(assignments, fn {kind, row, room_id, allocation_amount} ->
                 case kind do
                   :cash ->
                     insert_cash_allocation!(%{
                       group_id: destination.group_id,
                       room_id: room_id,
                       payment_operation_id: row.payment_operation_id,
                       amount_cents: allocation_amount
                     })

                   :credit ->
                     insert_credit_allocation!(%{
                       group_id: destination.group_id,
                       lot_id: row.lot_id,
                       room_id: room_id,
                       operation_id: row.operation_id,
                       amount_cents: allocation_amount
                     })
                 end
               end)

               source_units
               |> Enum.filter(fn {kind, row, _amount} ->
                 kind == :cash and is_binary(row.payment_operation_id)
               end)
               |> Enum.map(fn {_kind, row, _amount} -> row.payment_operation_id end)
               |> Enum.uniq()
               |> Enum.each(fn payment_id ->
                 query =
                   from payment in CashPayment,
                     where: payment.payment_operation_id == ^payment_id,
                     update: [set: [transferred: true]]

                 Repo.update_all(query, [])
               end)

               source_revision = source.revision + 1
               destination_revision = destination.revision + 1

               if update_group_row(source, source_revision, []) != :ok or
                    update_group_row(destination, destination_revision, []) != :ok do
                 Repo.rollback(:conflict)
               end

               source_totals = totals_from_details(room_accounting(source))
               destination_totals = totals_from_details(room_accounting(destination))

               %{
                 source_outstanding_deposit_cents: source_totals.outstanding_deposit_cents,
                 destination_outstanding_deposit_cents:
                   destination_totals.outstanding_deposit_cents,
                 source_revision: source_revision,
                 destination_revision: destination_revision
               }
           end
         end) do
      {:ok, transfer} -> {:ok, transfer}
      {:error, :conflict} -> :conflict
      {:error, {:rejected, code}} -> {:error, code}
    end
  end

  defp transfer_stale_result(operation_id, group_id, expected, actual),
    do:
      rejected(operation_id, "stale_revision",
        group_id: group_id,
        expected_revision: expected,
        actual_revision: actual
      )

  defp stale_revision_value(operation, key, %Group{revision: actual}) do
    if key_present?(operation, key) and value(operation, key) != actual,
      do: {:stale, value(operation, key), actual},
      else: :ok
  end

  defp transfer_held_funding(%Group{room_accounting_initialized: false} = group),
    do: transfer_outstanding_funding(room_accounting(group))

  defp transfer_held_funding(group),
    do:
      Enum.sum(Enum.map(held_funding_allocations(group), fn {_kind, row} -> row.amount_cents end))

  defp transfer_outstanding_funding(details) do
    Enum.sum(Enum.map(details, &(&1.cash_paid_cents + &1.credit_paid_cents)))
  end

  defp transfer_outstanding(group),
    do: totals_from_details(room_accounting(group)).outstanding_deposit_cents

  defp take_funding_units(rows, amount), do: take_funding_units(rows, amount, [])

  defp take_funding_units(_rows, amount, units) when amount <= 0, do: Enum.reverse(units)

  defp take_funding_units([{kind, row} | rest], amount, units) do
    taken = min(row.amount_cents, amount)
    take_funding_units(rest, amount - taken, [{kind, row, taken} | units])
  end

  defp take_funding_units([], _amount, units), do: Enum.reverse(units)

  defp transfer_assignments(units, room_plan) do
    {assignments, _remaining} =
      Enum.reduce(room_plan, {[], units}, fn {room_id, room_amount}, {acc, remaining} ->
        {room_assignments, remaining} = take_transfer_units(remaining, room_amount, room_id, [])
        {acc ++ room_assignments, remaining}
      end)

    assignments
  end

  defp take_transfer_units(units, amount, _room_id, acc) when amount <= 0,
    do: {Enum.reverse(acc), units}

  defp take_transfer_units([{kind, row, left} | rest], amount, room_id, acc) do
    taken = min(left, amount)
    assignment = {kind, row, room_id, taken}

    if taken == left do
      take_transfer_units(rest, amount - taken, room_id, [assignment | acc])
    else
      {Enum.reverse([assignment | acc]), [{kind, row, left - taken} | rest]}
    end
  end

  defp take_transfer_units([], _amount, _room_id, acc), do: {Enum.reverse(acc), []}

  defp remove_funding_units!(units) do
    units
    |> Enum.group_by(fn {kind, row, _amount} -> {kind, row.id} end)
    |> Enum.each(fn {{_kind, _id}, grouped} ->
      row = elem(hd(grouped), 1)
      amount = Enum.sum(Enum.map(grouped, &elem(&1, 2)))

      if amount == row.amount_cents do
        Repo.delete!(row)
      else
        Repo.update!(Ecto.Changeset.change(row, amount_cents: row.amount_cents - amount))
      end
    end)
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
              rejected(operation_id, "payment_not_reducible")

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
                          case reduce_payment_transaction(group, payment, amount) do
                            {:ok, reduction} ->
                              applied(operation_id,
                                payment_operation_id: target_id,
                                group_id: group_id,
                                amount_cents: amount,
                                outstanding_deposit_cents: reduction.outstanding_deposit_cents,
                                revision: reduction.revision
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

  defp reduce_payment_transaction(group, payment, amount) do
    case Repo.transaction(fn ->
           groups = prepare_payment_groups(payment.payment_operation_id, group)
           payment = Repo.get_by!(CashPayment, payment_operation_id: payment.payment_operation_id)
           rows = held_cash_rows(payment.payment_operation_id, groups)
           units = take_funding_units(Enum.map(rows, &{:cash, &1}), amount)

           if Enum.sum(Enum.map(rows, & &1.amount_cents)) != payment.held_cents or
                Enum.sum(Enum.map(units, &elem(&1, 2))) != amount,
              do: Repo.rollback(:conflict)

           remove_funding_units!(units)

           payment
           |> Ecto.Changeset.change(
             held_cents: payment.held_cents - amount,
             reduced_cents: payment.reduced_cents + amount
           )
           |> Repo.update!()

           affected_group_ids = Enum.map(units, fn {_kind, row, _amount} -> row.group_id end)
           revisions = bump_group_revisions!(groups, affected_group_ids ++ [group.group_id])
           original = Map.fetch!(groups, group.group_id)
           outstanding = totals_from_details(room_accounting(original)).outstanding_deposit_cents

           %{
             outstanding_deposit_cents: outstanding,
             revision: Map.fetch!(revisions, group.group_id)
           }
         end) do
      {:ok, reduction} -> {:ok, reduction}
      {:error, :conflict} -> :conflict
    end
  end

  defp charge_back_payment(operation, operation_id) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, target_id} <- required_string(operation, "payment_operation_id") do
      case chargeback_target_payment(target_id) do
        {:error, code} ->
          rejected(operation_id, code)

        {:ok, _target_operation, target_result, payment} ->
          group_id = target_result["group_id"]

          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              rejected(operation_id, "payment_not_chargeable")

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

                    case charge_back_transaction(group, payment, charged_back) do
                      {:ok, chargeback} ->
                        applied(operation_id,
                          payment_operation_id: target_id,
                          group_id: group_id,
                          charged_back_cents: charged_back,
                          outstanding_deposit_cents: chargeback.outstanding_deposit_cents,
                          revision: chargeback.revision
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

  defp charge_back_transaction(group, payment, charged_back) do
    case Repo.transaction(fn ->
           groups = prepare_payment_groups(payment.payment_operation_id, group)
           payment = Repo.get_by!(CashPayment, payment_operation_id: payment.payment_operation_id)
           rows = held_cash_rows(payment.payment_operation_id, groups)

           if Enum.sum(Enum.map(rows, & &1.amount_cents)) != payment.held_cents,
             do: Repo.rollback(:conflict)

           units = Enum.map(rows, &{:cash, &1, &1.amount_cents})
           remove_funding_units!(units)

           revoke_credit_entitlements!(payment.payment_operation_id)

           payment
           |> Ecto.Changeset.change(
             held_cents: 0,
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             charged_back_cents: payment.charged_back_cents + charged_back
           )
           |> Repo.update!()

           affected_group_ids = Enum.map(units, fn {_kind, row, _amount} -> row.group_id end)
           revisions = bump_group_revisions!(groups, affected_group_ids ++ [group.group_id])
           original = Map.fetch!(groups, group.group_id)
           outstanding = totals_from_details(room_accounting(original)).outstanding_deposit_cents

           %{
             outstanding_deposit_cents: outstanding,
             revision: Map.fetch!(revisions, group.group_id)
           }
         end) do
      {:ok, chargeback} -> {:ok, chargeback}
      {:error, :conflict} -> :conflict
    end
  end

  defp prepare_payment_groups(payment_id, original_group) do
    group_ids =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.payment_operation_id == ^payment_id,
          select: allocation.group_id
      )
      |> Enum.uniq()
      |> then(&Enum.uniq([original_group.group_id | &1]))

    Repo.all(from group in Group, where: group.group_id in ^group_ids)
    |> Enum.map(&prepare_room_accounting/1)
    |> Map.new(&{&1.group_id, &1})
  end

  defp held_cash_rows(payment_id, groups) do
    active_rooms =
      Map.new(groups, fn {group_id, group} ->
        {group_id,
         group
         |> room_specs()
         |> Enum.filter(&(&1.status == "active"))
         |> MapSet.new(& &1.room_id)}
      end)

    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_id
    )
    |> Enum.filter(fn row ->
      case Map.get(groups, row.group_id) do
        %Group{status: "active"} ->
          MapSet.member?(Map.get(active_rooms, row.group_id), row.room_id)

        _ ->
          false
      end
    end)
    |> Enum.sort_by(&allocation_order_key/1, :desc)
  end

  defp bump_group_revisions!(groups, group_ids) do
    group_ids
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn group_id, revisions ->
      group = Map.fetch!(groups, group_id)
      revision = group.revision + 1

      if update_group_row(group, revision, []) != :ok,
        do: Repo.rollback(:conflict)

      Map.put(revisions, group_id, revision)
    end)
  end

  defp chargeback_target_payment(target_id) do
    case get_operation(target_id) do
      nil ->
        {:error, "operation_not_found"}

      %Operation{operation_type: "record_cash_payment"} = operation ->
        result = operation_json(operation)

        if result["status"] == "applied" do
          case Repo.get_by(CashPayment, payment_operation_id: target_id) do
            %CashPayment{} = payment ->
              {:ok, operation, result, payment}

            nil ->
              case Repo.get_by(Group, group_id: result["group_id"]) do
                %Group{status: "active", room_accounting_initialized: false} = group ->
                  {:ok, operation, result,
                   %CashPayment{
                     payment_operation_id: target_id,
                     group_id: group.group_id,
                     recorded_cents: result["amount_cents"],
                     held_cents: result["amount_cents"]
                   }}

                _ ->
                  {:error, "payment_not_chargeable"}
              end
          end
        else
          {:error, "payment_not_chargeable"}
        end

      %Operation{} ->
        {:error, "payment_not_chargeable"}
    end
  end

  defp cash_payment_exists?(payment_operation_id) do
    Repo.one(
      from payment in CashPayment,
        where: payment.payment_operation_id == ^payment_operation_id,
        select: 1
    ) == 1
  end

  defp target_payment(target_id) do
    case get_operation(target_id) do
      nil ->
        {:error, "operation_not_found"}

      %Operation{operation_type: "record_cash_payment"} = operation ->
        result = operation_json(operation)

        if result["status"] == "applied" do
          group = Repo.get_by(Group, group_id: result["group_id"])

          case Repo.get_by(CashPayment, payment_operation_id: target_id) do
            %CashPayment{} = payment ->
              {:ok, operation, result, payment}

            nil ->
              case group do
                %Group{status: "active", room_accounting_initialized: false} ->
                  {:ok, operation, result,
                   %CashPayment{
                     payment_operation_id: target_id,
                     group_id: result["group_id"],
                     recorded_cents: result["amount_cents"],
                     held_cents: result["amount_cents"]
                   }}

                _ ->
                  {:error, "payment_not_reducible"}
              end
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

  defp held_funding_allocations(%Group{} = group) do
    active_room_ids =
      group
      |> room_specs()
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(& &1.room_id)

    cash_rows =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^active_room_ids
      )
      |> Enum.map(&{:cash, &1})

    credit_rows =
      Repo.all(
        from allocation in HotelCreditAllocation,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^active_room_ids
      )
      |> Enum.map(&{:credit, &1})

    (cash_rows ++ credit_rows)
    |> Enum.sort_by(fn {_kind, row} -> allocation_order_key(row) end, :desc)
  end

  defp held_cash_by_group(payment_operation_id) do
    rows =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.payment_operation_id == ^payment_operation_id
      )

    groups =
      rows
      |> Enum.map(& &1.group_id)
      |> Enum.uniq()
      |> then(fn group_ids ->
        Repo.all(from group in Group, where: group.group_id in ^group_ids)
        |> Map.new(&{&1.group_id, &1})
      end)

    rows
    |> Enum.filter(fn row ->
      case Map.get(groups, row.group_id) do
        %Group{status: "active"} = group ->
          Enum.any?(room_specs(group), &(&1.room_id == row.room_id and &1.status == "active"))

        _ ->
          false
      end
    end)
    |> Enum.group_by(& &1.group_id)
    |> Enum.map(fn {group_id, group_rows} ->
      %{group_id: group_id, amount_cents: Enum.sum(Enum.map(group_rows, & &1.amount_cents))}
    end)
    |> Enum.sort_by(& &1.group_id)
  end

  defp allocation_order_key(%{allocation_order: order, id: id}) when is_integer(order),
    do: {order, id}

  defp allocation_order_key(%{id: id}), do: {0, id}

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

  defp insert_cash_allocation!(attrs) do
    attrs = allocation_order_attrs(attrs, CashAllocation)

    %CashAllocation{}
    |> CashAllocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_credit_allocation!(attrs) do
    attrs = allocation_order_attrs(attrs, HotelCreditAllocation)

    %HotelCreditAllocation{}
    |> HotelCreditAllocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp update_credit_allocation_room!(row, room_id) do
    query =
      from allocation in HotelCreditAllocation,
        where: allocation.id == ^row.id,
        update: [set: [room_id: ^room_id]]

    Repo.update_all(query, [])
  end

  defp allocation_order_attrs(attrs, schema) do
    if allocation_order_supported?(schema),
      do: Map.put(attrs, :allocation_order, next_allocation_order()),
      else: attrs
  end

  defp allocation_order_supported?(schema) do
    table =
      case schema do
        CashAllocation -> "cash_allocations"
        HotelCreditAllocation -> "hotel_credit_allocations"
      end

    case Repo.query("PRAGMA table_info(#{table})") do
      {:ok, %{rows: rows}} -> Enum.any?(rows, &(Enum.at(&1, 1) == "allocation_order"))
      _ -> false
    end
  end

  defp next_allocation_order do
    case Repo.query("UPDATE allocation_sequences SET next_order = next_order + 1 WHERE id = 1") do
      {:ok, _result} ->
        %{rows: [[next_order]]} =
          Repo.query!("SELECT next_order FROM allocation_sequences WHERE id = 1")

        next_order

      {:error, _error} ->
        cash_max =
          Repo.one(
            from allocation in CashAllocation,
              select: coalesce(max(allocation.allocation_order), 0)
          )

        credit_max =
          Repo.one(
            from allocation in HotelCreditAllocation,
              select: coalesce(max(allocation.allocation_order), 0)
          )

        max(cash_max || 0, credit_max || 0) + 1
    end
  end

  defp prepare_room_accounting(%Group{room_accounting_initialized: true} = group), do: group

  defp prepare_room_accounting(%Group{} = group) do
    rooms = room_specs(group)

    current_cash =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_id == ^group.group_id,
          select: %{
            id: allocation.id,
            group_id: allocation.group_id,
            room_id: allocation.room_id,
            payment_operation_id: allocation.payment_operation_id,
            amount_cents: allocation.amount_cents
          }
      )

    events = historical_funding_events(group)

    if events == [] do
      cash_total = Enum.sum(Enum.map(current_cash, & &1.amount_cents))

      legacy_cash =
        if group.status == "active", do: max(group_cash_value(group) - cash_total, 0), else: 0

      if legacy_cash > 0 do
        Enum.each(legacy_funding_plan(rooms, legacy_cash), fn {room_id, amount} ->
          insert_cash_allocation!(%{
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
        insert_cash_allocation!(%{
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
          order_by: [asc: allocation.id],
          select: %{
            id: allocation.id,
            group_id: allocation.group_id,
            lot_id: allocation.lot_id,
            room_id: allocation.room_id,
            operation_id: allocation.operation_id,
            amount_cents: allocation.amount_cents
          }
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
              unless cash_payment_exists?(operation_id) do
                %CashPayment{}
                |> CashPayment.changeset(%{
                  payment_operation_id: operation_id,
                  group_id: group.group_id,
                  recorded_cents: amount,
                  held_cents: amount
                })
                |> Repo.insert!()
              end

              Enum.each(plan, fn {room_id, room_amount} ->
                insert_cash_allocation!(%{
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

        %CashPayment{}
        |> CashPayment.changeset(%{
          payment_operation_id: operation_id,
          group_id: group.group_id,
          recorded_cents: amount,
          refunded_cents: refunded,
          retained_cents: retained,
          converted_to_credit_cents: converted_amount
        })
        |> Repo.insert!()

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
        insert_credit_allocation!(%{
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
          order_by: [asc: allocation.id],
          select: %{
            id: allocation.id,
            group_id: allocation.group_id,
            lot_id: allocation.lot_id,
            room_id: allocation.room_id,
            operation_id: allocation.operation_id,
            amount_cents: allocation.amount_cents
          }
      )

    initial_cash = Map.new(legacy_funding_plan(rooms, legacy_cash))

    Enum.reduce(rows, initial_cash, fn row, used_amounts ->
      {assignments, new_used} = allocate_credit_to_rooms(rooms, used_amounts, row.amount_cents)

      case assignments do
        [{first_room, _first_amount} | rest] ->
          update_credit_allocation_room!(row, first_room)

          Enum.each(rest, fn {room_id, amount} ->
            insert_credit_allocation!(%{
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

    durable =
      payment_ids
      |> Enum.map(fn payment_id ->
        rows = Map.fetch!(cash_by_payment, payment_id)

        {payment_id, Enum.sum(Enum.map(rows, & &1.amount_cents)),
         Enum.min(Enum.map(rows, &allocation_order_key/1))}
      end)
      |> Enum.sort_by(fn {_payment_id, _amount, order} -> order end)
      |> Enum.map(fn {payment_id, amount, _order} -> {payment_id, amount} end)

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

  defp result_value(result, key) when is_map(result),
    do: Map.get(result, key, Map.get(result, String.to_atom(key)))

  defp result_value(_result, _key), do: nil

  defp key_present?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp key_present?(_map, _key), do: false

  defp applied(operation_id, fields),
    do: Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))

  defp rejected(operation_id, code, fields \\ []),
    do: Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))
end
