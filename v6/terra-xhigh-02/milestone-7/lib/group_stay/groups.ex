defmodule GroupStay.Groups do
  @moduledoc """
  The group-deposit domain and its transaction boundary.

  A batch intentionally does not share a transaction. Each operation commits its own domain
  changes and durable result record together, allowing later operations to observe earlier
  successful operations while preserving retry outcomes.
  """

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Groups.{
    CashAllocation,
    CashPaymentDisposition,
    CashPaymentTransfer,
    CreditAllocation,
    CreditEntitlement,
    CreditLot,
    FinanceCashMovement,
    FinanceCashOpening,
    FinanceDailyReport,
    FinanceCreditLotChange,
    FinanceCreditLotOpening,
    FinanceCreditMovement,
    FinancePeriodClose,
    FinanceReportingStart,
    Group,
    PartnerOperation,
    Room
  }

  @group_operation_types [
    "record_cash_payment",
    "reschedule_group",
    "cancel_group",
    "cancel_rooms",
    "apply_hotel_credit"
  ]
  @flex_30_policy_start ~D[2027-01-01]

  @doc "Processes partner operations in their submitted order."
  def process_batch(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

  @doc "Returns a group in the Partner API representation."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> :not_found
      group -> {:ok, group |> Repo.preload(rooms: rooms_in_original_order()) |> group_data()}
    end
  end

  def get_group(_group_id), do: :not_found

  @doc "Returns the result retained for a durably handled partner operation."
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> :not_found
      operation -> {:ok, Jason.decode!(operation.result_json)}
    end
  end

  def get_operation(_operation_id), do: :not_found

  @doc "Returns the current reconciliation of one durably recorded cash payment."
  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil -> :not_found
      operation -> payment_reconciliation(operation)
    end
  end

  def get_payment(_payment_operation_id), do: :not_found

  @doc "Returns finance totals, evaluating available credit expiry on the supplied date."
  def ledger(on \\ Date.utc_today()) do
    Group
    |> Repo.all()
    |> Enum.reduce(
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0
      },
      fn group, totals ->
        %{
          cash_held_cents:
            totals.cash_held_cents +
              if(group.status == "active", do: cash_paid_cents(group), else: 0),
          cash_refunded_cents: totals.cash_refunded_cents + group.refunded_cents,
          cash_retained_cents: totals.cash_retained_cents + group.retained_cents,
          cash_converted_to_credit_cents:
            totals.cash_converted_to_credit_cents + cash_converted_to_credit_cents(group),
          cash_reduced_cents: totals.cash_reduced_cents + cash_reduced_cents(group),
          cash_charged_back_cents: totals.cash_charged_back_cents + cash_charged_back_cents(group)
        }
      end
    )
    |> Map.put(:credit_liability_cents, credit_liability_cents(on))
    |> Map.put(:credit_shortfall_cents, credit_shortfall_cents())
  end

  @doc "Returns the current or durably published daily finance report for one calendar date."
  def daily_finance_report(%Date{} = date) do
    case reporting_start() do
      nil ->
        :not_available

      %FinanceReportingStart{starts_on: starts_on} = start ->
        if Date.compare(date, starts_on) == :lt do
          :not_available
        else
          case Repo.get_by(FinanceDailyReport, reporting_start_id: start.id, report_date: date) do
            nil -> {:ok, build_daily_finance_report(start, date)}
            report -> {:ok, Jason.decode!(report.data_json)}
          end
        end
    end
  end

  @doc "Returns a guest's credit that has not expired on the supplied date."
  def get_guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots = available_credit_lots(guest_id, on)

    {:ok,
     %{
       "guest_id" => guest_id,
       "available_cents" => Enum.sum(Enum.map(lots, & &1.remaining_cents)),
       "lots" =>
         Enum.map(lots, fn lot ->
           %{
             "source_operation_id" => lot.source_operation_id,
             "remaining_cents" => lot.remaining_cents,
             "expires_on" => Date.to_iso8601(lot.expires_on)
           }
         end)
     }}
  end

  defp process_operation(operation) when is_map(operation) do
    if identifier?(Map.get(operation, "operation_id")) do
      process_durable_operation(operation)
    else
      process_non_durable_operation(operation)
    end
  end

  defp process_operation(operation), do: process_non_durable_operation(operation)

  # A durable record and the domain work share this transaction. Handled rejections return a
  # result normally, while optimistic-write retries roll the whole attempt back before retrying.
  defp process_durable_operation(operation) do
    submission_json = Jason.encode!(operation)

    case Repo.transaction(fn -> durable_operation_result(operation, submission_json) end) do
      {:ok, result} ->
        result

      {:error, reason} when reason in [:write_conflict, :operation_record_conflict] ->
        process_durable_operation(operation)
    end
  end

  defp durable_operation_result(operation, submission_json) do
    case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
      nil ->
        operation
        |> execute_operation()
        |> persist_operation_result(operation, submission_json)

      stored_operation ->
        if Jason.decode!(stored_operation.submission_json) == operation do
          Jason.decode!(stored_operation.result_json)
        else
          rejected(operation, "operation_id_conflict")
        end
    end
  end

  defp persist_operation_result(result, operation, submission_json) do
    attrs = %{
      operation_id: operation["operation_id"],
      operation_type: audit_operation_type(operation),
      submission_json: submission_json,
      result_json: Jason.encode!(result)
    }

    case Repo.insert(PartnerOperation.changeset(%PartnerOperation{}, attrs), mode: :savepoint) do
      {:ok, _operation} ->
        result

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :operation_id) do
          rollback(:operation_record_conflict)
        else
          raise "unable to persist partner operation: #{inspect(changeset.errors)}"
        end
    end
  end

  defp audit_operation_type(%{"type" => type}) when is_binary(type), do: type
  defp audit_operation_type(operation), do: Jason.encode!(Map.get(operation, "type"))

  defp process_non_durable_operation(operation) do
    case Repo.transaction(fn -> execute_operation(operation) end) do
      {:ok, result} -> result
      {:error, :write_conflict} -> process_non_durable_operation(operation)
    end
  end

  defp execute_operation(operation) when is_map(operation) do
    case Map.get(operation, "type") do
      "open_group" -> process_open_group(operation)
      "start_finance_reporting" -> start_finance_reporting(operation)
      "close_finance_period" -> close_finance_period(operation)
      type when type in @group_operation_types -> process_group_operation(operation, type)
      "transfer_deposit" -> transfer_deposit(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      _ -> rejected(operation, "invalid_operation")
    end
  end

  defp execute_operation(_operation), do: rejected(%{}, "invalid_operation")

  defp process_open_group(operation) do
    with true <- identifier?(Map.get(operation, "group_id")) do
      case Repo.get_by(Group, group_id: operation["group_id"]) do
        %Group{} -> rejected(operation, "group_already_exists")
        nil -> create_group(operation)
      end
    else
      _ -> rejected(operation, "invalid_operation")
    end
  end

  # Reporting has a single, durable inception point. The snapshot deliberately reflects the
  # already-committed database state, rather than replaying occurred_on dates: late partner
  # submissions before this operation are part of the opening position by definition.
  defp start_finance_reporting(operation) do
    with true <- identifier?(Map.get(operation, "operation_id")),
         {:ok, starts_on} <- reporting_date(operation) do
      case reporting_start() do
        %FinanceReportingStart{} ->
          rejected(operation, "reporting_already_started")

        nil ->
          start_changeset =
            %FinanceReportingStart{}
            |> FinanceReportingStart.changeset(%{
              singleton: 1,
              starts_on: starts_on,
              opening_credit_liability_cents: credit_liability_cents(starts_on)
            })

          case Repo.insert(start_changeset) do
            {:ok, start} ->
              snapshot_finance_opening!(start, starts_on)
              applied(operation, %{"starts_on" => Date.to_iso8601(starts_on)})

            {:error, changeset} ->
              if Keyword.has_key?(changeset.errors, :singleton) do
                rejected(operation, "reporting_already_started")
              else
                raise "unable to start finance reporting: #{inspect(changeset.errors)}"
              end
          end
      end
    else
      _ -> rejected(operation, "invalid_reporting_date")
    end
  end

  defp close_finance_period(operation) do
    with true <- identifier?(Map.get(operation, "operation_id")),
         {:ok, period_end_on} <- period_end_date(operation),
         %FinanceReportingStart{} = start <- reporting_start(),
         :ok <- valid_period_end?(start, period_end_on) do
      case Repo.insert(
             FinancePeriodClose.changeset(%FinancePeriodClose{}, %{period_end_on: period_end_on}),
             mode: :savepoint
           ) do
        {:ok, _close} ->
          snapshot_closed_reports!(start, period_end_on)
          applied(operation, %{"period_end_on" => Date.to_iso8601(period_end_on)})

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :period_end_on) do
            rejected(operation, "invalid_period")
          else
            raise "unable to close finance period: #{inspect(changeset.errors)}"
          end
      end
    else
      _ -> rejected(operation, "invalid_period")
    end
  end

  defp valid_period_end?(start, period_end_on) do
    latest_end_on = latest_period_end_on()

    cond do
      Date.compare(period_end_on, start.starts_on) == :lt ->
        {:error, :invalid_period}

      latest_end_on && Date.compare(period_end_on, latest_end_on) != :gt ->
        {:error, :invalid_period}

      true ->
        :ok
    end
  end

  defp snapshot_closed_reports!(start, period_end_on) do
    start.starts_on
    |> Date.range(period_end_on)
    |> Enum.each(fn date ->
      report =
        start
        |> build_daily_finance_report(date)
        |> Map.put("status", "closed")

      Repo.insert!(
        FinanceDailyReport.changeset(%FinanceDailyReport{}, %{
          reporting_start_id: start.id,
          report_date: date,
          data_json: Jason.encode!(report)
        }),
        on_conflict: :nothing,
        conflict_target: [:reporting_start_id, :report_date]
      )
    end)
  end

  defp snapshot_finance_opening!(start, starts_on) do
    cash_held_by_property()
    |> Enum.each(fn {property_id, opening_held_cents} ->
      Repo.insert!(
        FinanceCashOpening.changeset(%FinanceCashOpening{}, %{
          reporting_start_id: start.id,
          property_id: property_id,
          opening_held_cents: opening_held_cents
        })
      )
    end)

    from(lot in CreditLot, where: lot.expires_on > ^starts_on)
    |> Repo.all()
    |> Enum.each(fn lot ->
      Repo.insert!(
        FinanceCreditLotOpening.changeset(%FinanceCreditLotOpening{}, %{
          reporting_start_id: start.id,
          credit_lot_id: lot.id,
          opening_available_cents: lot.remaining_cents,
          expires_on: lot.expires_on
        })
      )
    end)
  end

  defp create_group(operation) do
    case open_group_attributes(operation) do
      {:ok, group_attrs, room_attrs} ->
        case Repo.insert(Group.create_changeset(%Group{}, group_attrs), mode: :savepoint) do
          {:ok, group} ->
            insert_rooms!(group, room_attrs)

            applied(operation, %{
              "group_id" => group.group_id,
              "deposit_due_cents" => group.deposit_due_cents,
              "revision" => group.revision
            })

          {:error, changeset} ->
            if Keyword.has_key?(changeset.errors, :group_id) do
              rejected(operation, "group_already_exists")
            else
              rejected(operation, "invalid_operation")
            end
        end

      {:error, code} ->
        rejected(operation, code)
    end
  end

  defp insert_rooms!(group, room_attrs) do
    Enum.each(room_attrs, fn attrs ->
      attrs
      |> Map.put(:reservation_id, group.id)
      |> then(&Room.changeset(%Room{}, &1))
      |> Repo.insert!()
    end)
  end

  defp process_group_operation(operation, type) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
        apply_group_operation(operation, type, group_id)

      _ ->
        rejected(operation, "invalid_operation")
    end
  end

  defp apply_group_operation(operation, type, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil ->
        rejected(operation, "group_not_found")

      group ->
        with :ok <- valid_expected_revision?(operation),
             :ok <- expected_revision_matches?(operation, group),
             {:ok, occurred_on} <- common_operation_data(operation) do
          apply_active_group_operation(operation, type, group, occurred_on)
        else
          {:error, :invalid_expected_revision} ->
            rejected(operation, "invalid_operation")

          {:error, {:stale_revision, expected, stale_group}} ->
            rejected(operation, "stale_revision", %{
              "group_id" => stale_group.group_id,
              "expected_revision" => expected,
              "actual_revision" => stale_group.revision
            })

          {:error, :invalid_operation} ->
            rejected(operation, "invalid_operation")
        end
    end
  end

  defp apply_active_group_operation(operation, type, group, occurred_on) do
    if group.status != "active" do
      rejected(operation, "group_not_active")
    else
      case type do
        "record_cash_payment" -> record_cash_payment(operation, group)
        "reschedule_group" -> reschedule_group(operation, group, occurred_on)
        "cancel_group" -> cancel_group(operation, group, occurred_on)
        "cancel_rooms" -> cancel_rooms(operation, group, occurred_on)
        "apply_hotel_credit" -> apply_hotel_credit(operation, group, occurred_on)
      end
    end
  end

  defp record_cash_payment(operation, group) do
    with {:ok, amount_cents} <- payment_amount(operation),
         outstanding = outstanding_deposit(group),
         true <- amount_cents <= outstanding do
      allocate_cash!(group, operation["operation_id"], amount_cents)
      report_cash_movement!(operation, group.property_id, "received", amount_cents)

      update_group(
        group,
        %{
          deposit_paid_cents: group.deposit_paid_cents + amount_cents,
          cash_paid_cents: cash_paid_cents(group) + amount_cents
        },
        fn updated ->
          applied(operation, %{
            "group_id" => updated.group_id,
            "amount_cents" => amount_cents,
            "outstanding_deposit_cents" => outstanding_deposit(updated),
            "revision" => updated.revision
          })
        end
      )
    else
      {:error, :invalid_operation} -> rejected(operation, "invalid_operation")
      {:error, :invalid_amount} -> rejected(operation, "invalid_amount")
      false -> rejected(operation, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation, group, occurred_on) do
    with {:ok, new_arrival_on} <- new_arrival_on(operation),
         :gt <- Date.compare(new_arrival_on, occurred_on) do
      length_of_stay = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, length_of_stay)

      update_group(
        group,
        %{arrival_on: new_arrival_on, departure_on: new_departure_on},
        fn updated ->
          applied(operation, %{
            "group_id" => updated.group_id,
            "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated.departure_on),
            "policy_version" => policy_version(updated),
            "refundable_until" => iso8601_date(refundable_until(updated)),
            "revision" => updated.revision
          })
        end
      )
    else
      {:error, :invalid_operation} -> rejected(operation, "invalid_operation")
      _ -> rejected(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation, group, occurred_on) do
    settle_selected_rooms(operation, group, occurred_on, active_rooms(group), :group)
  end

  defp cancel_rooms(operation, group, occurred_on) do
    case selected_active_rooms(group, operation) do
      {:ok, rooms} -> settle_selected_rooms(operation, group, occurred_on, rooms, :rooms)
      {:error, :invalid_operation} -> rejected(operation, "invalid_operation")
      {:error, :invalid_rooms} -> rejected(operation, "invalid_rooms")
    end
  end

  defp settle_selected_rooms(operation, group, occurred_on, rooms, kind) do
    with {:ok, refund_method} <- refund_method(operation),
         refundable? = refundable?(group, occurred_on),
         :ok <- refund_method_available?(refund_method, refundable?) do
      room_ids = Enum.map(rooms, & &1.id)
      cash_allocations = cash_allocations_for_rooms(group, room_ids)
      credit_allocations = credit_allocations_for_rooms(group, room_ids)
      cash_total = Enum.sum(Enum.map(cash_allocations, & &1.amount_cents))

      credit_total =
        Enum.sum(
          Enum.map(credit_allocations, fn {allocation, _lot} -> allocation.amount_cents end)
        )

      all_active_rooms_selected? = Enum.count(active_rooms(group)) == length(rooms)
      credit_issued_cents = credit_issued_cents(cash_total, refundable?, refund_method)

      issued_lot =
        issue_credit_lot!(
          group.guest_id,
          operation["operation_id"],
          credit_issued_cents,
          occurred_on,
          operation
        )

      settle_cash_allocations!(cash_allocations, group, refundable?, refund_method, issued_lot)
      settle_credit_allocations!(credit_allocations, occurred_on, refundable?, operation)
      cancel_rooms!(rooms)

      refunded_cents = if refundable? and refund_method == "cash", do: cash_total, else: 0
      retained_cents = if refundable?, do: 0, else: cash_total

      converted_cents =
        if refundable? and refund_method == "hotel_credit", do: cash_total, else: 0

      cash_movement_kind =
        cond do
          refundable? and refund_method == "cash" -> "refunded"
          refundable? -> "converted_to_credit"
          true -> "retained"
        end

      report_cash_movement!(operation, group.property_id, cash_movement_kind, cash_total)
      if not refundable?, do: report_credit_movement!(operation, "consumed", credit_total)

      attrs = %{
        status: if(all_active_rooms_selected?, do: "cancelled", else: "active"),
        lodging_total_cents:
          group.lodging_total_cents - Enum.sum(Enum.map(rooms, & &1.lodging_total_cents)),
        deposit_due_cents:
          group.deposit_due_cents - Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
        deposit_paid_cents: group.deposit_paid_cents - cash_total - credit_total,
        cash_paid_cents: cash_paid_cents(group) - cash_total,
        credit_paid_cents: credit_paid_cents(group) - credit_total,
        refunded_cents: group.refunded_cents + refunded_cents,
        retained_cents: group.retained_cents + retained_cents,
        cash_converted_to_credit_cents: cash_converted_to_credit_cents(group) + converted_cents
      }

      update_group(group, attrs, fn updated ->
        fields = %{
          "group_id" => updated.group_id,
          "refunded_cents" => refunded_cents,
          "retained_cents" => retained_cents,
          "credit_issued_cents" => credit_issued_cents,
          "revision" => updated.revision
        }

        fields =
          if kind == :rooms do
            Map.put(fields, "cancelled_room_ids", Enum.map(rooms, & &1.room_id))
          else
            fields
          end

        applied(operation, fields)
      end)
    else
      {:error, :invalid_operation} -> rejected(operation, "invalid_operation")
      {:error, :refund_method_not_available} -> rejected(operation, "refund_method_not_available")
    end
  end

  defp apply_hotel_credit(operation, group, occurred_on) do
    with {:ok, amount_cents} <- payment_amount(operation),
         outstanding = outstanding_deposit(group),
         true <- amount_cents <= outstanding do
      lots = available_credit_lots(group.guest_id, occurred_on)

      if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount_cents do
        allocate_credit!(lots, group, amount_cents, operation)

        update_group(
          group,
          %{
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            credit_paid_cents: credit_paid_cents(group) + amount_cents
          },
          fn updated ->
            applied(operation, %{
              "group_id" => updated.group_id,
              "amount_cents" => amount_cents,
              "outstanding_deposit_cents" => outstanding_deposit(updated),
              "revision" => updated.revision
            })
          end
        )
      else
        rejected(operation, "insufficient_credit")
      end
    else
      {:error, :invalid_operation} -> rejected(operation, "invalid_operation")
      {:error, :invalid_amount} -> rejected(operation, "invalid_amount")
      false -> rejected(operation, "payment_exceeds_outstanding")
    end
  end

  defp transfer_deposit(operation) do
    with true <- identifier?(Map.get(operation, "operation_id")),
         {:ok, source_group_id} <- transfer_group_id(operation, "source_group_id"),
         {:ok, source} <- transfer_group(source_group_id),
         {:ok, destination_group_id} <- transfer_group_id(operation, "destination_group_id"),
         {:ok, destination} <- transfer_group(destination_group_id),
         :ok <- valid_expected_revision?(operation),
         :ok <- expected_revision_matches?(operation, source),
         :ok <- valid_destination_expected_revision?(operation),
         :ok <- destination_expected_revision_matches?(operation, destination),
         :ok <- valid_transfer_groups?(source, destination),
         :ok <- active_transfer_groups?(source, destination),
         {:ok, amount_cents} <- payment_amount(operation) do
      allocations = held_allocations_in_reverse_order(source)
      held_cents = Enum.sum(Enum.map(allocations, & &1.amount_cents))
      outstanding_cents = outstanding_deposit(destination)

      cond do
        amount_cents > held_cents ->
          rejected(operation, "transfer_exceeds_held_funding")

        amount_cents > outstanding_cents ->
          rejected(operation, "transfer_exceeds_outstanding")

        true ->
          drawn = remove_held_allocations!(allocations, amount_cents)

          %{cash_cents: cash_cents, credit_cents: credit_cents} =
            allocate_transferred_funding!(destination, drawn)

          mark_transferred_cash_payments!(drawn)
          report_cash_movement!(operation, source.property_id, "transferred_out", cash_cents)
          report_cash_movement!(operation, destination.property_id, "transferred_in", cash_cents)

          changes =
            %{}
            |> add_group_change(source, %{
              deposit_paid_cents: -amount_cents,
              cash_paid_cents: -cash_cents,
              credit_paid_cents: -credit_cents
            })
            |> add_group_change(destination, %{
              deposit_paid_cents: amount_cents,
              cash_paid_cents: cash_cents,
              credit_paid_cents: credit_cents
            })

          updated_groups = apply_group_changes!(changes)
          updated_source = Map.fetch!(updated_groups, source.id)
          updated_destination = Map.fetch!(updated_groups, destination.id)

          applied(operation, %{
            "source_group_id" => source.group_id,
            "destination_group_id" => destination.group_id,
            "amount_cents" => amount_cents,
            "source_outstanding_deposit_cents" => outstanding_deposit(updated_source),
            "destination_outstanding_deposit_cents" => outstanding_deposit(updated_destination),
            "source_revision" => updated_source.revision,
            "destination_revision" => updated_destination.revision
          })
      end
    else
      false ->
        rejected(operation, "invalid_operation")

      {:error, :invalid_operation} ->
        rejected(operation, "invalid_operation")

      {:error, {:group_not_found, group_id}} ->
        rejected(operation, "group_not_found", %{"group_id" => group_id})

      {:error, {:stale_revision, expected, group}} ->
        stale_revision_rejection(operation, expected, group)

      {:error, {:group_not_active, group}} ->
        rejected(operation, "group_not_active", %{"group_id" => group.group_id})

      {:error, :invalid_transfer} ->
        rejected(operation, "invalid_transfer")

      {:error, :invalid_amount} ->
        rejected(operation, "invalid_amount")
    end
  end

  defp transfer_group_id(operation, field) do
    case Map.get(operation, field) do
      group_id when is_binary(group_id) and byte_size(group_id) > 0 -> {:ok, group_id}
      _ -> {:error, :invalid_operation}
    end
  end

  defp transfer_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, {:group_not_found, group_id}}
      group -> {:ok, group}
    end
  end

  defp valid_destination_expected_revision?(operation) do
    case Map.fetch(operation, "destination_expected_revision") do
      :error -> :ok
      {:ok, revision} when is_integer(revision) -> :ok
      {:ok, _revision} -> {:error, :invalid_operation}
    end
  end

  defp destination_expected_revision_matches?(operation, group) do
    case Map.fetch(operation, "destination_expected_revision") do
      :error -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:error, {:stale_revision, expected_revision, group}}
    end
  end

  defp valid_transfer_groups?(source, destination) do
    if source.id == destination.id or source.guest_id != destination.guest_id do
      {:error, :invalid_transfer}
    else
      :ok
    end
  end

  defp active_transfer_groups?(source, destination) do
    cond do
      source.status != "active" -> {:error, {:group_not_active, source}}
      destination.status != "active" -> {:error, {:group_not_active, destination}}
      true -> :ok
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment_operation_id} <- payment_operation_id(operation),
         {:ok, payment, result} <-
           applied_cash_payment(payment_operation_id, :payment_not_reducible),
         {:ok, group} <- payment_group(result),
         :ok <- valid_expected_revision?(operation),
         :ok <- expected_revision_matches?(operation, group),
         {:ok, amount_cents} <- reduction_amount(operation) do
      held_cents = held_cash_cents(payment_operation_id)

      cond do
        held_cents == 0 ->
          rejected(operation, "payment_not_reducible")

        amount_cents > held_cents ->
          rejected(operation, "reduction_exceeds_held_cash")

        true ->
          removed_by_group = remove_cash_allocations!(payment_operation_id, amount_cents)
          record_cash_disposition!(group, payment.operation_id, "reduced", amount_cents)

          Enum.each(removed_by_group, fn {_group_id,
                                          %{group: allocation_group, amount_cents: removed_cents}} ->
            report_cash_movement!(
              operation,
              allocation_group.property_id,
              "reduced",
              removed_cents
            )
          end)

          changes =
            removed_by_group
            |> Enum.reduce(%{}, fn {_group_id,
                                    %{group: allocation_group, amount_cents: removed_cents}},
                                   changes ->
              add_group_change(changes, allocation_group, %{
                deposit_paid_cents: -removed_cents,
                cash_paid_cents: -removed_cents
              })
            end)
            |> add_group_change(group, %{cash_reduced_cents: amount_cents})

          updated = apply_group_changes!(changes) |> Map.fetch!(group.id)

          applied(operation, %{
            "payment_operation_id" => payment_operation_id,
            "group_id" => updated.group_id,
            "amount_cents" => amount_cents,
            "outstanding_deposit_cents" => outstanding_deposit(updated),
            "revision" => updated.revision
          })
      end
    else
      {:error, :invalid_operation} ->
        rejected(operation, "invalid_operation")

      :operation_not_found ->
        rejected(operation, "operation_not_found")

      :payment_not_reducible ->
        rejected(operation, "payment_not_reducible")

      :group_not_found ->
        rejected(operation, "group_not_found")

      {:error, :invalid_expected_revision} ->
        rejected(operation, "invalid_operation")

      {:error, {:stale_revision, expected, group}} ->
        stale_revision_rejection(operation, expected, group)

      {:error, :invalid_amount} ->
        rejected(operation, "invalid_amount")
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment_operation_id} <- payment_operation_id(operation),
         {:ok, _payment, result} <-
           applied_cash_payment(payment_operation_id, :payment_not_chargeable),
         {:ok, group} <- payment_group(result),
         :ok <- valid_expected_revision?(operation),
         :ok <- expected_revision_matches?(operation, group) do
      recorded_cents = result["amount_cents"]
      held_cents = held_cash_cents(payment_operation_id)
      totals = payment_disposition_totals(payment_operation_id)

      if totals.charged_back > 0 or totals.reduced >= recorded_cents do
        rejected(operation, "payment_not_chargeable")
      else
        removed_by_group = remove_cash_allocations!(payment_operation_id, held_cents)
        history_by_group = payment_history_by_group(payment_operation_id)

        Enum.each(removed_by_group, fn {_group_id,
                                        %{group: allocation_group, amount_cents: removed_cents}} ->
          record_cash_disposition!(
            allocation_group,
            payment_operation_id,
            "charged_back",
            removed_cents
          )

          report_cash_movement!(
            operation,
            allocation_group.property_id,
            "charged_back",
            removed_cents
          )
        end)

        report_chargeback_history!(operation, history_by_group)
        reclassify_payment_history!(payment_operation_id)
        revoke_credit_entitlements!(payment_operation_id, operation)

        charged_back_cents =
          held_cents + totals.refunded + totals.retained + totals.converted

        changes =
          removed_by_group
          |> Enum.reduce(%{}, fn {_group_id,
                                  %{group: allocation_group, amount_cents: removed_cents}},
                                 changes ->
            add_group_change(changes, allocation_group, %{
              deposit_paid_cents: -removed_cents,
              cash_paid_cents: -removed_cents
            })
          end)
          |> add_payment_history_changes(history_by_group)
          |> add_group_change(group, %{cash_charged_back_cents: charged_back_cents})

        updated = apply_group_changes!(changes) |> Map.fetch!(group.id)

        applied(operation, %{
          "payment_operation_id" => payment_operation_id,
          "group_id" => updated.group_id,
          "charged_back_cents" => charged_back_cents,
          "outstanding_deposit_cents" => outstanding_deposit(updated),
          "revision" => updated.revision
        })
      end
    else
      {:error, :invalid_operation} ->
        rejected(operation, "invalid_operation")

      :operation_not_found ->
        rejected(operation, "operation_not_found")

      :payment_not_chargeable ->
        rejected(operation, "payment_not_chargeable")

      :group_not_found ->
        rejected(operation, "group_not_found")

      {:error, :invalid_expected_revision} ->
        rejected(operation, "invalid_operation")

      {:error, {:stale_revision, expected, group}} ->
        stale_revision_rejection(operation, expected, group)
    end
  end

  defp payment_operation_id(operation) do
    case Map.get(operation, "payment_operation_id") do
      operation_id when is_binary(operation_id) and byte_size(operation_id) > 0 ->
        {:ok, operation_id}

      _ ->
        {:error, :invalid_operation}
    end
  end

  defp applied_cash_payment(payment_operation_id, rejection) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        :operation_not_found

      %PartnerOperation{operation_type: "record_cash_payment"} = payment ->
        result = Jason.decode!(payment.result_json)

        if result["status"] == "applied" and is_binary(result["group_id"]) and
             is_integer(result["amount_cents"]) and result["amount_cents"] > 0 do
          {:ok, payment, result}
        else
          rejection
        end

      _payment ->
        rejection
    end
  end

  defp payment_group(result) do
    case Repo.get_by(Group, group_id: result["group_id"]) do
      nil -> :group_not_found
      group -> {:ok, group}
    end
  end

  defp reduction_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, :invalid_operation}

      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, :invalid_amount}
    end
  end

  defp refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, method} when method in ["cash", "hotel_credit"] -> {:ok, method}
      {:ok, _method} -> {:error, :invalid_operation}
    end
  end

  defp refund_method_available?("hotel_credit", false), do: {:error, :refund_method_not_available}
  defp refund_method_available?(_refund_method, _refundable?), do: :ok

  defp credit_issued_cents(cash_paid_cents, true, "hotel_credit"),
    do: cash_paid_cents + round_percentage(cash_paid_cents, 10)

  defp credit_issued_cents(_cash_paid_cents, _refundable?, _refund_method), do: 0
  defp issue_credit_lot!(_guest_id, _source_operation_id, 0, _cancelled_on, _operation), do: nil

  defp issue_credit_lot!(guest_id, source_operation_id, amount_cents, cancelled_on, operation) do
    lot =
      Repo.insert!(
        CreditLot.create_changeset(%CreditLot{}, %{
          guest_id: guest_id,
          source_operation_id: source_operation_id,
          remaining_cents: amount_cents,
          unrecovered_clawback_cents: 0,
          expires_on: Date.add(cancelled_on, 366),
          revision: 1
        })
      )

    report_credit_lot_issued!(operation, lot)
    lot
  end

  defp allocate_cash!(group, payment_operation_id, amount_cents) do
    starting_order = next_allocation_order()

    {remaining, _next_order} =
      active_rooms(group)
      |> Enum.reduce({amount_cents, starting_order}, fn room, {remaining, allocation_order} ->
        used_cents = min(room_available_cents(room), remaining)

        if used_cents == 0 do
          {remaining, allocation_order}
        else
          update_room!(room, %{cash_paid_cents: room.cash_paid_cents + used_cents})

          Repo.insert!(
            CashAllocation.changeset(%CashAllocation{}, %{
              reservation_id: group.id,
              room_id: room.id,
              payment_operation_id: payment_operation_id,
              amount_cents: used_cents,
              position: allocation_order,
              allocation_order: allocation_order
            })
          )

          {remaining - used_cents, allocation_order + 1}
        end
      end)

    if remaining != 0, do: raise("cash allocation exceeded active room capacity")
  end

  defp allocate_credit!(lots, group, amount_cents, operation) do
    {remaining, _next_order} =
      Enum.reduce_while(lots, {amount_cents, next_allocation_order()}, fn lot,
                                                                          {remaining_cents,
                                                                           next_order} ->
        used_cents = min(lot.remaining_cents, remaining_cents)

        if used_cents == 0 do
          {:cont, {remaining_cents, next_order}}
        else
          update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents - used_cents})
          report_credit_lot_availability_change!(operation, lot, -used_cents)
          next_order = allocate_lot_credit_to_rooms!(group, lot, used_cents, next_order)

          case remaining_cents - used_cents do
            0 -> {:halt, {0, next_order}}
            next_remaining -> {:cont, {next_remaining, next_order}}
          end
        end
      end)

    if remaining != 0, do: raise("credit allocation exceeded available credit")
  end

  defp allocate_lot_credit_to_rooms!(group, lot, amount_cents, starting_order) do
    {remaining, next_order} =
      active_rooms(group)
      |> Enum.reduce({amount_cents, starting_order}, fn room, {remaining, next_order} ->
        used_cents = min(room_available_cents(room), remaining)

        if used_cents == 0 do
          {remaining, next_order}
        else
          update_room!(room, %{credit_paid_cents: room.credit_paid_cents + used_cents})

          Repo.insert!(
            CreditAllocation.changeset(%CreditAllocation{}, %{
              reservation_id: group.id,
              credit_lot_id: lot.id,
              room_id: room.id,
              amount_cents: used_cents,
              allocation_order: next_order
            })
          )

          {remaining - used_cents, next_order + 1}
        end
      end)

    if remaining != 0, do: raise("credit lot allocation exceeded active room capacity")
    next_order
  end

  defp selected_active_rooms(group, operation) do
    case Map.fetch(operation, "room_ids") do
      :error ->
        {:error, :invalid_operation}

      {:ok, room_ids} when is_list(room_ids) and room_ids != [] ->
        if Enum.all?(room_ids, &identifier?/1) and Enum.uniq(room_ids) == room_ids do
          rooms = active_rooms(group)
          selected = Enum.filter(rooms, &(&1.room_id in room_ids))

          if length(selected) == length(room_ids) do
            {:ok, selected}
          else
            {:error, :invalid_rooms}
          end
        else
          {:error, :invalid_rooms}
        end

      {:ok, _room_ids} ->
        {:error, :invalid_rooms}
    end
  end

  defp cash_allocations_for_rooms(group, room_ids) do
    from(allocation in CashAllocation,
      where: allocation.reservation_id == ^group.id and allocation.room_id in ^room_ids,
      order_by: [asc: allocation.allocation_order]
    )
    |> Repo.all()
  end

  defp credit_allocations_for_rooms(group, room_ids) do
    from(allocation in CreditAllocation,
      join: lot in CreditLot,
      on: lot.id == allocation.credit_lot_id,
      where: allocation.reservation_id == ^group.id and allocation.room_id in ^room_ids,
      select: {allocation, lot}
    )
    |> Repo.all()
  end

  defp settle_cash_allocations!(allocations, group, refundable?, refund_method, issued_lot) do
    kind =
      cond do
        refundable? and refund_method == "cash" -> "refunded"
        refundable? -> "converted"
        true -> "retained"
      end

    Enum.group_by(allocations, & &1.payment_operation_id)
    |> Enum.each(fn
      {nil, _allocations} ->
        :ok

      {payment_operation_id, payment_allocations} ->
        amount_cents = Enum.sum(Enum.map(payment_allocations, & &1.amount_cents))
        record_cash_disposition!(group, payment_operation_id, kind, amount_cents, issued_lot)
    end)

    if issued_lot, do: record_credit_entitlements!(issued_lot, allocations)
    Enum.each(allocations, &Repo.delete!/1)
  end

  defp record_cash_disposition!(
         group,
         payment_operation_id,
         kind,
         amount_cents,
         credit_lot \\ nil
       ) do
    Repo.insert!(
      CashPaymentDisposition.changeset(%CashPaymentDisposition{}, %{
        reservation_id: group.id,
        credit_lot_id: if(credit_lot, do: credit_lot.id),
        payment_operation_id: payment_operation_id,
        kind: kind,
        amount_cents: amount_cents
      })
    )
  end

  defp record_credit_entitlements!(lot, allocations) do
    allocations
    |> Enum.sort_by(& &1.allocation_order)
    |> Enum.chunk_by(& &1.payment_operation_id)
    |> Enum.reduce(0, fn payment_allocations, settled_before ->
      payment_operation_id = hd(payment_allocations).payment_operation_id
      settled_cents = Enum.sum(Enum.map(payment_allocations, & &1.amount_cents))
      settled_through = settled_before + settled_cents
      entitlement_cents = credit_value(settled_through) - credit_value(settled_before)

      if payment_operation_id do
        Repo.insert!(
          CreditEntitlement.changeset(%CreditEntitlement{}, %{
            credit_lot_id: lot.id,
            payment_operation_id: payment_operation_id,
            amount_cents: entitlement_cents
          })
        )
      end

      settled_through
    end)
  end

  defp settle_credit_allocations!(allocations, occurred_on, true, operation) do
    allocations
    |> Enum.group_by(fn {_allocation, lot} -> lot.id end)
    |> Enum.each(fn {_lot_id, lot_allocations} ->
      {_allocation, lot} = hd(lot_allocations)

      amount_cents =
        Enum.sum(Enum.map(lot_allocations, fn {allocation, _lot} -> allocation.amount_cents end))

      restore_credit_to_lot!(lot, amount_cents, occurred_on, operation)
    end)

    Enum.each(allocations, fn {allocation, _lot} -> Repo.delete!(allocation) end)
  end

  defp settle_credit_allocations!(allocations, _occurred_on, false, _operation) do
    Enum.each(allocations, fn {allocation, _lot} -> Repo.delete!(allocation) end)
  end

  defp restore_credit_to_lot!(lot, amount_cents, occurred_on, operation) do
    absorbed_cents = min(lot.unrecovered_clawback_cents, amount_cents)
    restored_cents = amount_cents - absorbed_cents

    available_cents =
      if Date.compare(lot.expires_on, occurred_on) == :gt, do: restored_cents, else: 0

    update_credit_lot!(lot, %{
      remaining_cents: lot.remaining_cents + available_cents,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents
    })

    reporting_available_cents =
      case reporting_posting_date(operation) do
        nil ->
          0

        posted_on ->
          if(Date.compare(lot.expires_on, posted_on) == :gt, do: restored_cents, else: 0)
      end

    report_credit_lot_availability_change!(operation, lot, reporting_available_cents)
    report_credit_movement!(operation, "absorbed", absorbed_cents)
    report_credit_movement!(operation, "expired", restored_cents - reporting_available_cents)
  end

  defp cancel_rooms!(rooms) do
    Enum.each(rooms, fn room ->
      update_room!(room, %{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
    end)
  end

  defp held_cash_cents(payment_operation_id) do
    from(allocation in CashAllocation,
      where: allocation.payment_operation_id == ^payment_operation_id,
      select: sum(allocation.amount_cents)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp held_cash_by_group(payment_operation_id) do
    from(allocation in CashAllocation,
      join: group in Group,
      on: group.id == allocation.reservation_id,
      where: allocation.payment_operation_id == ^payment_operation_id,
      group_by: [group.group_id],
      order_by: [asc: group.group_id],
      select: {group.group_id, sum(allocation.amount_cents)}
    )
    |> Repo.all()
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp held_allocations_in_reverse_order(group) do
    cash_allocations =
      from(allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.reservation_id == ^group.id and room.status == "active",
        select: {allocation, room}
      )
      |> Repo.all()
      |> Enum.map(fn {allocation, room} ->
        %{
          kind: :cash,
          allocation: allocation,
          room: room,
          group: group,
          amount_cents: allocation.amount_cents,
          allocation_order: allocation.allocation_order,
          payment_operation_id: allocation.payment_operation_id
        }
      end)

    credit_allocations =
      from(allocation in CreditAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        where: allocation.reservation_id == ^group.id and room.status == "active",
        select: {allocation, room}
      )
      |> Repo.all()
      |> Enum.map(fn {allocation, room} ->
        %{
          kind: :credit,
          allocation: allocation,
          room: room,
          group: group,
          amount_cents: allocation.amount_cents,
          allocation_order: allocation.allocation_order,
          credit_lot_id: allocation.credit_lot_id
        }
      end)

    Enum.sort_by(cash_allocations ++ credit_allocations, & &1.allocation_order, :desc)
  end

  defp remove_held_allocations!(allocations, amount_cents) do
    {remaining, drawn, room_removals} =
      Enum.reduce_while(allocations, {amount_cents, [], %{}}, fn holding,
                                                                 {remaining, drawn, room_removals} ->
        if remaining == 0 do
          {:halt, {0, drawn, room_removals}}
        else
          removed_cents = min(holding.amount_cents, remaining)
          remove_allocation_amount!(holding, removed_cents)

          drawn_holding =
            holding
            |> Map.take([:kind, :payment_operation_id, :credit_lot_id, :group])
            |> Map.put(:amount_cents, removed_cents)

          {:cont,
           {remaining - removed_cents, [drawn_holding | drawn],
            add_room_removal(room_removals, holding, removed_cents)}}
        end
      end)

    if remaining != 0, do: raise("held allocation removal exceeded available funding")
    apply_room_removals!(room_removals)
    Enum.reverse(drawn)
  end

  defp remove_allocation_amount!(holding, removed_cents) do
    allocation = holding.allocation

    if removed_cents == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      changeset =
        case holding.kind do
          :cash ->
            CashAllocation.update_changeset(allocation, %{
              amount_cents: allocation.amount_cents - removed_cents
            })

          :credit ->
            CreditAllocation.update_changeset(allocation, %{
              amount_cents: allocation.amount_cents - removed_cents
            })
        end

      Repo.update!(changeset)
    end
  end

  defp add_room_removal(room_removals, holding, amount_cents) do
    key = holding.room.id

    Map.update(
      room_removals,
      key,
      %{
        room: holding.room,
        cash_cents: if(holding.kind == :cash, do: amount_cents, else: 0),
        credit_cents: if(holding.kind == :credit, do: amount_cents, else: 0)
      },
      fn removal ->
        %{
          removal
          | cash_cents: removal.cash_cents + if(holding.kind == :cash, do: amount_cents, else: 0),
            credit_cents:
              removal.credit_cents + if(holding.kind == :credit, do: amount_cents, else: 0)
        }
      end
    )
  end

  defp apply_room_removals!(room_removals) do
    Enum.each(room_removals, fn {_room_id, removal} ->
      room = removal.room

      update_room!(room, %{
        cash_paid_cents: room.cash_paid_cents - removal.cash_cents,
        credit_paid_cents: room.credit_paid_cents - removal.credit_cents
      })
    end)
  end

  defp allocate_transferred_funding!(group, drawn) do
    original_rooms = active_rooms(group)
    starting_order = next_allocation_order()

    {rooms, allocations, _next_order} =
      Enum.reduce(drawn, {original_rooms, [], starting_order}, fn holding,
                                                                  {rooms, allocations, next_order} ->
        {updated_rooms, holding_allocations, next_order} =
          allocate_transferred_holding(rooms, holding, next_order)

        {updated_rooms, allocations ++ holding_allocations, next_order}
      end)

    original_rooms
    |> Enum.zip(rooms)
    |> Enum.each(fn {original_room, updated_room} ->
      if original_room.cash_paid_cents != updated_room.cash_paid_cents or
           original_room.credit_paid_cents != updated_room.credit_paid_cents do
        update_room!(original_room, %{
          cash_paid_cents: updated_room.cash_paid_cents,
          credit_paid_cents: updated_room.credit_paid_cents
        })
      end
    end)

    Enum.each(allocations, &insert_transferred_allocation!(group, &1))

    %{
      cash_cents:
        allocations
        |> Enum.filter(&(&1.kind == :cash))
        |> Enum.sum_by(& &1.amount_cents),
      credit_cents:
        allocations
        |> Enum.filter(&(&1.kind == :credit))
        |> Enum.sum_by(& &1.amount_cents)
    }
  end

  defp allocate_transferred_holding(rooms, holding, starting_order) do
    {updated_rooms, remaining, allocations, next_order} =
      Enum.reduce(rooms, {[], holding.amount_cents, [], starting_order}, fn room,
                                                                            {updated_rooms,
                                                                             remaining,
                                                                             allocations,
                                                                             next_order} ->
        used_cents = min(room_available_cents(room), remaining)

        if used_cents == 0 do
          {[room | updated_rooms], remaining, allocations, next_order}
        else
          updated_room =
            case holding.kind do
              :cash -> %{room | cash_paid_cents: room.cash_paid_cents + used_cents}
              :credit -> %{room | credit_paid_cents: room.credit_paid_cents + used_cents}
            end

          allocation =
            holding
            |> Map.put(:room_id, room.id)
            |> Map.put(:amount_cents, used_cents)
            |> Map.put(:allocation_order, next_order)

          {[updated_room | updated_rooms], remaining - used_cents, [allocation | allocations],
           next_order + 1}
        end
      end)

    if remaining != 0, do: raise("transferred funding exceeded destination capacity")
    {Enum.reverse(updated_rooms), Enum.reverse(allocations), next_order}
  end

  defp insert_transferred_allocation!(group, %{kind: :cash} = allocation) do
    Repo.insert!(
      CashAllocation.changeset(%CashAllocation{}, %{
        reservation_id: group.id,
        room_id: allocation.room_id,
        payment_operation_id: allocation.payment_operation_id,
        amount_cents: allocation.amount_cents,
        position: allocation.allocation_order,
        allocation_order: allocation.allocation_order
      })
    )
  end

  defp insert_transferred_allocation!(group, %{kind: :credit} = allocation) do
    Repo.insert!(
      CreditAllocation.changeset(%CreditAllocation{}, %{
        reservation_id: group.id,
        room_id: allocation.room_id,
        credit_lot_id: allocation.credit_lot_id,
        amount_cents: allocation.amount_cents,
        allocation_order: allocation.allocation_order
      })
    )
  end

  defp mark_transferred_cash_payments!(drawn) do
    drawn
    |> Enum.filter(&(&1.kind == :cash and identifier?(Map.get(&1, :payment_operation_id))))
    |> Enum.map(& &1.payment_operation_id)
    |> Enum.uniq()
    |> Enum.each(fn payment_operation_id ->
      Repo.insert!(
        CashPaymentTransfer.changeset(%CashPaymentTransfer{}, %{
          payment_operation_id: payment_operation_id
        }),
        on_conflict: :nothing,
        conflict_target: :payment_operation_id
      )
    end)
  end

  defp add_group_change(changes, group, deltas) do
    Map.update(
      changes,
      group.id,
      %{group: group, deltas: deltas},
      fn change -> %{change | deltas: merge_accounting_deltas(change.deltas, deltas)} end
    )
  end

  defp merge_accounting_deltas(existing, additions) do
    Map.merge(existing, additions, fn _field, existing_delta, added_delta ->
      existing_delta + added_delta
    end)
  end

  defp apply_group_changes!(changes) do
    Enum.reduce(changes, %{}, fn {group_id, %{group: group, deltas: deltas}}, updated_groups ->
      attrs =
        Map.new(deltas, fn {field, delta} ->
          {field, Map.fetch!(group, field) + delta}
        end)

      updated_group = update_group(group, attrs, & &1)
      Map.put(updated_groups, group_id, updated_group)
    end)
  end

  defp remove_cash_allocations!(payment_operation_id, amount_cents) do
    allocations =
      from(allocation in CashAllocation,
        join: room in Room,
        on: room.id == allocation.room_id,
        join: group in Group,
        on: group.id == allocation.reservation_id,
        where: allocation.payment_operation_id == ^payment_operation_id,
        order_by: [desc: allocation.allocation_order],
        select: {allocation, room, group}
      )
      |> Repo.all()
      |> Enum.map(fn {allocation, room, group} ->
        %{
          kind: :cash,
          allocation: allocation,
          room: room,
          group: group,
          amount_cents: allocation.amount_cents,
          allocation_order: allocation.allocation_order,
          payment_operation_id: allocation.payment_operation_id
        }
      end)

    allocations
    |> remove_held_allocations!(amount_cents)
    |> Enum.reduce(%{}, fn holding, removed_by_group ->
      Map.update(
        removed_by_group,
        holding.group.id,
        %{group: holding.group, amount_cents: holding.amount_cents},
        fn removed ->
          %{removed | amount_cents: removed.amount_cents + holding.amount_cents}
        end
      )
    end)
  end

  defp payment_disposition_totals(payment_operation_id) do
    from(disposition in CashPaymentDisposition,
      where: disposition.payment_operation_id == ^payment_operation_id,
      group_by: disposition.kind,
      select: {disposition.kind, sum(disposition.amount_cents)}
    )
    |> Repo.all()
    |> Enum.reduce(
      %{refunded: 0, retained: 0, converted: 0, reduced: 0, charged_back: 0},
      fn {kind, amount}, totals -> Map.put(totals, String.to_existing_atom(kind), amount) end
    )
  end

  defp payment_history_by_group(payment_operation_id) do
    from(disposition in CashPaymentDisposition,
      where:
        disposition.payment_operation_id == ^payment_operation_id and
          disposition.kind in ["refunded", "retained", "converted"],
      group_by: [disposition.reservation_id, disposition.kind],
      select: {disposition.reservation_id, disposition.kind, sum(disposition.amount_cents)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {reservation_id, kind, amount_cents}, histories ->
      group = Repo.get!(Group, reservation_id)

      Map.update(
        histories,
        reservation_id,
        %{group: group, refunded_cents: 0, retained_cents: 0, cash_converted_to_credit_cents: 0},
        & &1
      )
      |> Map.update!(reservation_id, fn history ->
        Map.update!(history, payment_history_field(kind), &(&1 + amount_cents))
      end)
    end)
  end

  defp payment_history_field("refunded"), do: :refunded_cents
  defp payment_history_field("retained"), do: :retained_cents
  defp payment_history_field("converted"), do: :cash_converted_to_credit_cents

  defp add_payment_history_changes(changes, history_by_group) do
    Enum.reduce(history_by_group, changes, fn {_group_id, history}, changes ->
      add_group_change(changes, history.group, %{
        refunded_cents: -history.refunded_cents,
        retained_cents: -history.retained_cents,
        cash_converted_to_credit_cents: -history.cash_converted_to_credit_cents
      })
    end)
  end

  defp reclassify_payment_history!(payment_operation_id) do
    from(disposition in CashPaymentDisposition,
      where:
        disposition.payment_operation_id == ^payment_operation_id and
          disposition.kind in ["refunded", "retained", "converted"]
    )
    |> Repo.all()
    |> Enum.each(fn disposition ->
      Repo.update!(CashPaymentDisposition.update_changeset(disposition, %{kind: "charged_back"}))
    end)
  end

  defp report_chargeback_history!(operation, history_by_group) do
    Enum.each(history_by_group, fn {_group_id, history} ->
      for {kind, amount_cents} <- [
            {"refunded", history.refunded_cents},
            {"retained", history.retained_cents},
            {"converted_to_credit", history.cash_converted_to_credit_cents}
          ] do
        report_cash_movement!(operation, history.group.property_id, kind, -amount_cents)
        report_cash_movement!(operation, history.group.property_id, "charged_back", amount_cents)
      end
    end)
  end

  defp revoke_credit_entitlements!(payment_operation_id, operation) do
    from(entitlement in CreditEntitlement,
      where: entitlement.payment_operation_id == ^payment_operation_id
    )
    |> Repo.all()
    |> Enum.each(fn entitlement ->
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removable_cents = min(lot.remaining_cents, entitlement.amount_cents)
      unrecovered_cents = entitlement.amount_cents - removable_cents

      update_credit_lot!(lot, %{
        remaining_cents: lot.remaining_cents - removable_cents,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered_cents
      })

      report_credit_lot_availability_change!(operation, lot, -removable_cents)

      # Expired available credit has already left liability through the calendar-expiry report.
      # Removing its retained row later is still necessary for the clawback audit, but it is not
      # a second liability movement.
      reportable_revocation_cents =
        case reporting_posting_date(operation) do
          nil ->
            0

          posted_on ->
            if(Date.compare(lot.expires_on, posted_on) == :gt, do: removable_cents, else: 0)
        end

      report_credit_movement!(operation, "revoked", reportable_revocation_cents)
    end)
  end

  defp payment_reconciliation(
         %PartnerOperation{operation_type: "record_cash_payment"} = operation
       ) do
    result = Jason.decode!(operation.result_json)

    if result["status"] == "applied" and is_binary(result["group_id"]) and
         is_integer(result["amount_cents"]) do
      totals = payment_disposition_totals(operation.operation_id)

      statement = %{
        "payment_operation_id" => operation.operation_id,
        "original_group_id" => result["group_id"],
        "recorded_cents" => result["amount_cents"],
        "held_cents" => held_cash_cents(operation.operation_id),
        "refunded_cents" => totals.refunded,
        "retained_cents" => totals.retained,
        "converted_to_credit_cents" => totals.converted,
        "reduced_cents" => totals.reduced,
        "charged_back_cents" => totals.charged_back
      }

      statement =
        if Repo.get_by(CashPaymentTransfer, payment_operation_id: operation.operation_id) do
          Map.put(statement, "held_by_group", held_cash_by_group(operation.operation_id))
        else
          statement
        end

      {:ok, statement}
    else
      :not_reconcilable
    end
  end

  defp payment_reconciliation(_operation), do: :not_reconcilable

  defp update_room!(room, attrs) do
    case Repo.update(Room.update_changeset(room, attrs)) do
      {:ok, updated} -> updated
      {:error, changeset} -> raise "unable to update room: #{inspect(changeset.errors)}"
    end
  end

  defp update_credit_lot!(lot, attrs) do
    case Repo.update(CreditLot.update_changeset(lot, attrs), stale_error_field: :revision) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :revision) do
          rollback(:write_conflict)
        else
          raise "unable to update credit lot: #{inspect(changeset.errors)}"
        end
    end
  end

  defp update_group(group, attrs, result) do
    case Repo.update(Group.update_changeset(group, attrs), stale_error_field: :revision) do
      {:ok, updated} ->
        result.(updated)

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :revision) do
          rollback(:write_conflict)
        else
          raise "unable to update group: #{inspect(changeset.errors)}"
        end
    end
  end

  defp open_group_attributes(operation) do
    with {:ok, booked_on} <- common_operation_data(operation),
         :ok <- open_group_identifiers?(operation),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, arrival_on, departure_on, nights} <- opening_stay(operation),
         {:ok, rooms} <- opening_rooms(operation) do
      rooms =
        Enum.map(rooms, fn room ->
          lodging_total_cents = room.nightly_rate_cents * nights

          deposit_due_cents =
            if rate_plan == "advance_purchase" do
              lodging_total_cents
            else
              round_percentage(lodging_total_cents, 20)
            end

          Map.merge(room, %{
            lodging_total_cents: lodging_total_cents,
            deposit_due_cents: deposit_due_cents,
            cash_paid_cents: 0,
            credit_paid_cents: 0,
            status: "active"
          })
        end)

      lodging_total_cents = Enum.sum(Enum.map(rooms, & &1.lodging_total_cents))
      deposit_due_cents = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

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
         lodging_total_cents: lodging_total_cents,
         deposit_due_cents: deposit_due_cents,
         deposit_paid_cents: 0,
         cash_paid_cents: 0,
         credit_paid_cents: 0,
         refunded_cents: 0,
         retained_cents: 0,
         cash_converted_to_credit_cents: 0,
         cash_reduced_cents: 0,
         cash_charged_back_cents: 0,
         policy_version: policy_version(rate_plan, booked_on),
         revision: 1
       }, rooms}
    else
      {:error, _reason} = error -> error
      false -> {:error, "invalid_operation"}
    end
  end

  defp open_group_identifiers?(operation) do
    if identifier?(operation["operation_id"]) and identifier?(operation["guest_id"]) and
         identifier?(operation["property_id"]) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp rate_plan(operation) do
    case Map.fetch(operation, "rate_plan") do
      :error -> {:error, "invalid_operation"}
      {:ok, rate_plan} when rate_plan in ["flexible", "advance_purchase"] -> {:ok, rate_plan}
      {:ok, _rate_plan} -> {:error, "invalid_rate_plan"}
    end
  end

  defp opening_stay(operation) do
    with {:ok, arrival_on} <- required_date(operation, "arrival_on"),
         {:ok, departure_on} <- required_date(operation, "departure_on"),
         nights = Date.diff(departure_on, arrival_on),
         true <- nights > 0 do
      {:ok, arrival_on, departure_on, nights}
    else
      {:error, :missing} -> {:error, "invalid_operation"}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp opening_rooms(operation) do
    case Map.fetch(operation, "rooms") do
      :error ->
        {:error, "invalid_operation"}

      {:ok, rooms} when is_list(rooms) and rooms != [] ->
        rooms
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {room, position}, {:ok, valid_rooms} ->
          case room_attributes(room, position) do
            {:ok, attributes} -> {:cont, {:ok, [attributes | valid_rooms]}}
            :error -> {:halt, {:error, "invalid_rooms"}}
          end
        end)
        |> case do
          {:ok, valid_rooms} ->
            valid_rooms = Enum.reverse(valid_rooms)

            if valid_rooms |> Enum.map(& &1.room_id) |> Enum.uniq() |> length() ==
                 length(valid_rooms) do
              {:ok, valid_rooms}
            else
              {:error, "invalid_rooms"}
            end

          error ->
            error
        end

      {:ok, _rooms} ->
        {:error, "invalid_rooms"}
    end
  end

  defp room_attributes(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position
       )
       when is_binary(room_id) and byte_size(room_id) > 0 and is_integer(nightly_rate_cents) and
              nightly_rate_cents > 0 do
    {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents, position: position}}
  end

  defp room_attributes(_room, _position), do: :error

  # Inputs are non-negative integer cents. Adding half the denominator implements the required
  # nearest-cent rule with exact halves rounded up.
  defp round_percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)
  defp credit_value(cash_cents), do: cash_cents + round_percentage(cash_cents, 10)

  defp common_operation_data(operation) do
    with true <- identifier?(operation["operation_id"]),
         {:ok, occurred_on} <- required_date(operation, "occurred_on") do
      {:ok, occurred_on}
    else
      _ -> {:error, :invalid_operation}
    end
  end

  defp valid_expected_revision?(operation) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, revision} when is_integer(revision) -> :ok
      {:ok, _revision} -> {:error, :invalid_expected_revision}
    end
  end

  defp expected_revision_matches?(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:error, {:stale_revision, expected_revision, group}}
    end
  end

  defp payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, :invalid_operation}

      {:ok, amount_cents} when is_integer(amount_cents) and amount_cents > 0 ->
        {:ok, amount_cents}

      {:ok, _amount_cents} ->
        {:error, :invalid_amount}
    end
  end

  defp new_arrival_on(operation) do
    case required_date(operation, "new_arrival_on") do
      {:error, :missing} -> {:error, :invalid_operation}
      {:error, :invalid} -> {:error, :invalid_stay}
      result -> result
    end
  end

  defp required_date(operation, field) do
    case Map.fetch(operation, field) do
      :error ->
        {:error, :missing}

      {:ok, date} when is_binary(date) ->
        case Date.from_iso8601(date) do
          {:ok, parsed_date} -> {:ok, parsed_date}
          {:error, _reason} -> {:error, :invalid}
        end

      {:ok, _date} ->
        {:error, :invalid}
    end
  end

  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp room_available_cents(room),
    do: room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

  defp cash_paid_cents(group), do: group.cash_paid_cents || group.deposit_paid_cents
  defp credit_paid_cents(group), do: group.credit_paid_cents || 0
  defp cash_converted_to_credit_cents(group), do: group.cash_converted_to_credit_cents || 0
  defp cash_reduced_cents(group), do: group.cash_reduced_cents || 0
  defp cash_charged_back_cents(group), do: group.cash_charged_back_cents || 0

  defp policy_version(%Group{policy_version: policy_version}) when is_binary(policy_version),
    do: policy_version

  defp policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_policy_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      deadline -> Date.compare(occurred_on, deadline) != :gt
    end
  end

  defp iso8601_date(nil), do: nil
  defp iso8601_date(date), do: Date.to_iso8601(date)

  defp active_rooms(group) do
    from(room in Room,
      where: room.reservation_id == ^group.id and room.status == "active",
      order_by: [asc: room.position]
    )
    |> Repo.all()
  end

  defp next_allocation_order do
    cash_order =
      from(allocation in CashAllocation,
        select: max(allocation.allocation_order)
      )
      |> Repo.one()
      |> Kernel.||(-1)

    credit_order =
      from(allocation in CreditAllocation, select: max(allocation.allocation_order))
      |> Repo.one()
      |> Kernel.||(-1)

    max(cash_order, credit_order) + 1
  end

  defp available_credit_lots(guest_id, on) do
    from(lot in CreditLot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
    |> Repo.all()
  end

  defp credit_liability_cents(on) do
    available_cents =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on > ^on,
        select: sum(lot.remaining_cents)
      )
      |> Repo.one()
      |> Kernel.||(0)

    allocated_cents =
      from(allocation in CreditAllocation,
        join: group in Group,
        on: group.id == allocation.reservation_id,
        where: group.status == "active",
        select: sum(allocation.amount_cents)
      )
      |> Repo.one()
      |> Kernel.||(0)

    available_cents + allocated_cents
  end

  defp credit_shortfall_cents do
    from(lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total ->
      allocated_cents =
        from(allocation in CreditAllocation,
          join: group in Group,
          on: group.id == allocation.reservation_id,
          where: allocation.credit_lot_id == ^lot.id and group.status == "active",
          select: sum(allocation.amount_cents)
        )
        |> Repo.one()
        |> Kernel.||(0)

      total + min(lot.unrecovered_clawback_cents, allocated_cents)
    end)
  end

  defp rooms_in_original_order, do: from(room in Room, order_by: [asc: room.position])

  defp group_data(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
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
      "cash_paid_cents" => cash_paid_cents(group),
      "credit_paid_cents" => credit_paid_cents(group),
      "policy_version" => policy_version(group),
      "refundable_until" => iso8601_date(refundable_until(group)),
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  @cash_report_kinds [
    "received",
    "transferred_in",
    "transferred_out",
    "refunded",
    "retained",
    "converted_to_credit",
    "reduced",
    "charged_back"
  ]
  @credit_report_kinds ["issued", "expired", "consumed", "revoked", "absorbed"]

  defp build_daily_finance_report(start, date) do
    {cash, late_cash} = cash_daily_entries(start, date)
    {credit, late_credit} = credit_daily_entry(start, date)

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash,
      "credit" => credit,
      "late_adjustments" => %{"cash" => late_cash, "credit" => late_credit}
    }
  end

  defp cash_daily_entries(start, date) do
    openings =
      from(opening in FinanceCashOpening,
        where: opening.reporting_start_id == ^start.id,
        select: {opening.property_id, opening.opening_held_cents}
      )
      |> Repo.all()
      |> Map.new()

    movements =
      from(movement in FinanceCashMovement,
        where: movement.posted_on <= ^date,
        select: {
          movement.property_id,
          movement.kind,
          movement.amount_cents,
          movement.posted_on,
          movement.late_adjustment
        }
      )
      |> Repo.all()

    properties =
      Map.keys(openings) ++
        Enum.map(movements, fn {property_id, _kind, _amount, _date, _late_adjustment} ->
          property_id
        end)

    entries =
      properties
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn property_id ->
        inception_opening = Map.get(openings, property_id, 0)

        opening =
          inception_opening +
            (movements
             |> Enum.filter(fn {property, _kind, _amount, posted_on, _late_adjustment} ->
               property == property_id and Date.compare(posted_on, date) == :lt
             end)
             |> Enum.sum_by(fn {_property, kind, amount_cents, _posted_on, _late_adjustment} ->
               cash_movement_effect(kind, amount_cents)
             end))

        movements_on_date =
          Enum.filter(movements, fn {_property, _kind, _amount, posted_on, _late_adjustment} ->
            posted_on == date
          end)

        ordinary_movements =
          movements_on_date
          |> Enum.reject(fn {_property, _kind, _amount, _posted_on, late_adjustment} ->
            late_adjustment
          end)
          |> cash_movement_map(property_id)

        late_movements =
          movements_on_date
          |> Enum.filter(fn {_property, _kind, _amount, _posted_on, late_adjustment} ->
            late_adjustment
          end)
          |> cash_movement_map(property_id)

        total_movements = combine_movement_maps(ordinary_movements, late_movements)

        closing =
          opening +
            Enum.sum_by(total_movements, fn {kind, amount_cents} ->
              cash_movement_effect(kind, amount_cents)
            end)

        %{
          property_id: property_id,
          opening: opening,
          movements: ordinary_movements,
          late_movements: late_movements,
          closing: closing
        }
      end)
      |> Enum.reject(fn entry ->
        entry.opening == 0 and entry.closing == 0 and
          Enum.all?(entry.movements, fn {_kind, amount} -> amount == 0 end) and
          Enum.all?(entry.late_movements, fn {_kind, amount} -> amount == 0 end)
      end)

    cash =
      Enum.map(entries, fn entry ->
        %{
          "property_id" => entry.property_id,
          "opening_held_cents" => entry.opening,
          "movements" => cash_movement_data(entry.movements),
          "closing_held_cents" => entry.closing
        }
      end)

    late_adjustments =
      entries
      |> Enum.reject(fn entry ->
        Enum.all?(entry.late_movements, fn {_kind, amount} -> amount == 0 end)
      end)
      |> Enum.map(fn entry ->
        %{
          "property_id" => entry.property_id,
          "movements" => cash_movement_data(entry.late_movements)
        }
      end)

    {cash, late_adjustments}
  end

  defp cash_movement_map(movements, property_id) do
    movements
    |> Enum.reduce(empty_movement_map(@cash_report_kinds), fn
      {^property_id, kind, amount_cents, _posted_on, _late_adjustment}, totals ->
        Map.update!(totals, kind, &(&1 + amount_cents))

      _movement, totals ->
        totals
    end)
  end

  defp cash_movement_data(movements) do
    Map.new(@cash_report_kinds, fn kind -> {"#{kind}_cents", Map.fetch!(movements, kind)} end)
  end

  defp cash_movement_effect("received", amount_cents), do: amount_cents
  defp cash_movement_effect("transferred_in", amount_cents), do: amount_cents
  defp cash_movement_effect("transferred_out", amount_cents), do: -amount_cents
  defp cash_movement_effect("refunded", amount_cents), do: -amount_cents
  defp cash_movement_effect("retained", amount_cents), do: -amount_cents
  defp cash_movement_effect("converted_to_credit", amount_cents), do: -amount_cents
  defp cash_movement_effect("reduced", amount_cents), do: -amount_cents
  defp cash_movement_effect("charged_back", amount_cents), do: -amount_cents

  defp credit_daily_entry(start, date) do
    movements =
      from(movement in FinanceCreditMovement,
        where: movement.posted_on <= ^date,
        select:
          {movement.kind, movement.amount_cents, movement.posted_on, movement.late_adjustment}
      )
      |> Repo.all()

    financial_movements_on_date =
      movements
      |> Enum.filter(fn {_kind, _amount, posted_on, _late_adjustment} -> posted_on == date end)
      |> Enum.reject(fn {_kind, _amount, _posted_on, late_adjustment} -> late_adjustment end)
      |> credit_movement_map()

    movements_on_date =
      Map.update!(financial_movements_on_date, "expired", &(&1 + expired_credit_on(start, date)))

    late_movements_on_date =
      movements
      |> Enum.filter(fn {_kind, _amount, posted_on, late_adjustment} ->
        posted_on == date and late_adjustment
      end)
      |> credit_movement_map()

    prior_financial_movements =
      movements
      |> Enum.filter(fn {_kind, _amount, posted_on, _late_adjustment} ->
        Date.compare(posted_on, date) == :lt
      end)
      |> credit_movement_map()
      |> Map.update!("expired", &(&1 + expired_credit_before(start, date)))

    opening =
      credit_closing_balance(start.opening_credit_liability_cents, prior_financial_movements)

    closing =
      movements_on_date
      |> combine_movement_maps(late_movements_on_date)
      |> then(&credit_closing_balance(opening, &1))

    {%{
       "opening_liability_cents" => opening,
       "movements" => credit_movement_data(movements_on_date),
       "closing_liability_cents" => closing
     }, credit_movement_data(late_movements_on_date)}
  end

  defp credit_closing_balance(opening, movements) do
    opening + movements["issued"] - movements["expired"] - movements["consumed"] -
      movements["revoked"] - movements["absorbed"]
  end

  defp credit_movement_map(movements) do
    Enum.reduce(movements, empty_movement_map(@credit_report_kinds), fn {_kind, _amount,
                                                                         _posted_on,
                                                                         _late_adjustment} =
                                                                          movement,
                                                                        totals ->
      {kind, amount_cents, _posted_on, _late_adjustment} = movement
      Map.update!(totals, kind, &(&1 + amount_cents))
    end)
  end

  defp credit_movement_data(movements) do
    Map.new(@credit_report_kinds, fn kind -> {"#{kind}_cents", Map.fetch!(movements, kind)} end)
  end

  defp empty_movement_map(kinds), do: Map.new(kinds, &{&1, 0})

  defp combine_movement_maps(first, second) do
    Map.merge(first, second, fn _kind, first_amount, second_amount ->
      first_amount + second_amount
    end)
  end

  defp expired_credit_before(start, date) do
    FinanceCreditLotOpening
    |> where(
      [opening],
      opening.reporting_start_id == ^start.id and opening.expires_on >= ^start.starts_on and
        opening.expires_on < ^date
    )
    |> credit_expiry_total()
  end

  defp expired_credit_on(start, date) do
    FinanceCreditLotOpening
    |> where(
      [opening],
      opening.reporting_start_id == ^start.id and opening.expires_on == ^date and
        opening.expires_on >= ^start.starts_on
    )
    |> credit_expiry_total()
  end

  defp credit_expiry_total(openings_query) do
    from(opening in openings_query,
      left_join: change in FinanceCreditLotChange,
      on:
        change.credit_lot_id == opening.credit_lot_id and
          change.posted_on <= opening.expires_on,
      group_by: [opening.id, opening.opening_available_cents],
      select: {opening.opening_available_cents, coalesce(sum(change.available_delta_cents), 0)}
    )
    |> Repo.all()
    |> Enum.sum_by(fn {opening_cents, changes_cents} -> max(opening_cents + changes_cents, 0) end)
  end

  defp reporting_start do
    Repo.one(from(start in FinanceReportingStart, limit: 1))
  end

  defp latest_period_end_on do
    from(close in FinancePeriodClose,
      order_by: [desc: close.period_end_on],
      limit: 1,
      select: close.period_end_on
    )
    |> Repo.one()
  end

  defp cash_held_by_property do
    from(allocation in CashAllocation,
      join: room in Room,
      on: room.id == allocation.room_id,
      join: group in Group,
      on: group.id == allocation.reservation_id,
      where: group.status == "active" and room.status == "active",
      group_by: group.property_id,
      select: {group.property_id, sum(allocation.amount_cents)}
    )
    |> Repo.all()
  end

  # Finance movements are inserted in the same operation transaction as their domain change.
  # A durable replay never reaches these helpers, so it cannot duplicate a movement.
  defp report_cash_movement!(_operation, _property_id, _kind, 0), do: :ok

  defp report_cash_movement!(operation, property_id, kind, amount_cents) do
    case reporting_posting(operation) do
      nil ->
        :ok

      %{posted_on: posted_on, late_adjustment: late_adjustment} ->
        Repo.insert!(
          FinanceCashMovement.changeset(%FinanceCashMovement{}, %{
            property_id: property_id,
            kind: kind,
            amount_cents: amount_cents,
            posted_on: posted_on,
            late_adjustment: late_adjustment
          })
        )
    end
  end

  defp report_credit_movement!(_operation, _kind, 0), do: :ok

  defp report_credit_movement!(operation, kind, amount_cents) do
    case reporting_posting(operation) do
      nil ->
        :ok

      %{posted_on: posted_on, late_adjustment: late_adjustment} ->
        Repo.insert!(
          FinanceCreditMovement.changeset(%FinanceCreditMovement{}, %{
            kind: kind,
            amount_cents: amount_cents,
            posted_on: posted_on,
            late_adjustment: late_adjustment
          })
        )
    end
  end

  defp report_credit_lot_issued!(operation, lot) do
    case reporting_start_and_posting_date(operation) do
      nil ->
        :ok

      {start, posted_on} ->
        Repo.insert!(
          FinanceCreditLotOpening.changeset(%FinanceCreditLotOpening{}, %{
            reporting_start_id: start.id,
            credit_lot_id: lot.id,
            opening_available_cents: 0,
            expires_on: lot.expires_on
          })
        )

        report_credit_lot_availability_change!(operation, lot, lot.remaining_cents)
        report_credit_movement!(operation, "issued", lot.remaining_cents)

        # A backdated cancellation can issue a lot already expired by its reporting posting
        # date. Both effects belong to that one open report rather than a pre-inception day.
        if Date.compare(lot.expires_on, posted_on) == :lt do
          report_credit_movement!(operation, "expired", lot.remaining_cents)
        end
    end
  end

  defp report_credit_lot_availability_change!(_operation, _lot, 0), do: :ok

  defp report_credit_lot_availability_change!(operation, lot, available_delta_cents) do
    case reporting_posting_date(operation) do
      nil ->
        :ok

      posted_on ->
        Repo.insert!(
          FinanceCreditLotChange.changeset(%FinanceCreditLotChange{}, %{
            credit_lot_id: lot.id,
            available_delta_cents: available_delta_cents,
            posted_on: posted_on
          })
        )
    end
  end

  defp reporting_start_and_posting_date(operation) do
    case reporting_start() do
      nil -> nil
      start -> {start, reporting_posting_date(start, operation)}
    end
  end

  defp reporting_posting_date(operation) do
    case reporting_posting(operation) do
      nil -> nil
      %{posted_on: posted_on} -> posted_on
    end
  end

  defp reporting_posting_date(start, operation) do
    reporting_posting(start, operation).posted_on
  end

  defp reporting_posting(operation) do
    case reporting_start() do
      nil -> nil
      start -> reporting_posting(start, operation)
    end
  end

  defp reporting_posting(start, operation) do
    occurred_on =
      case required_date(operation, "occurred_on") do
        {:ok, date} -> date
        _ -> start.starts_on
      end

    occurred_or_start =
      if Date.compare(occurred_on, start.starts_on) == :lt, do: start.starts_on, else: occurred_on

    first_open_day =
      case latest_period_end_on() do
        nil -> occurred_or_start
        period_end_on -> Date.add(period_end_on, 1)
      end

    posted_on =
      if Date.compare(occurred_or_start, first_open_day) == :lt,
        do: first_open_day,
        else: occurred_or_start

    %{posted_on: posted_on, late_adjustment: posted_on != occurred_or_start}
  end

  defp reporting_date(operation) do
    case required_date(operation, "starts_on") do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_reporting_date}
    end
  end

  defp period_end_date(operation) do
    case required_date(operation, "period_end_on") do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_period}
    end
  end

  defp stale_revision_rejection(operation, expected, group) do
    rejected(operation, "stale_revision", %{
      "group_id" => group.group_id,
      "expected_revision" => expected,
      "actual_revision" => group.revision
    })
  end

  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp rollback(result), do: Repo.rollback(result)

  defp applied(operation, fields) do
    Map.merge(
      %{"operation_id" => Map.get(operation, "operation_id"), "status" => "applied"},
      fields
    )
  end

  defp rejected(operation, code, fields \\ %{}) do
    Map.merge(
      %{
        "operation_id" => Map.get(operation, "operation_id"),
        "status" => "rejected",
        "code" => code
      },
      fields
    )
  end
end
