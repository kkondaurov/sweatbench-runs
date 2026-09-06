defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    AllocationOrder,
    CashAllocation,
    CashPayment,
    CashPaymentDisposition,
    CreditApplication,
    CreditLot,
    CreditLotEntitlement,
    FinanceEntry,
    FinanceReporting,
    Group,
    PartnerOperation,
    Room,
    RoomCreditAllocation
  }

  @rate_plans ["flexible", "advance_purchase"]
  @flex_30_start ~D[2027-01-01]
  @finance_context_key {__MODULE__, :finance_context}
  @reported_financial_operations [
    "record_cash_payment",
    "apply_hotel_credit",
    "cancel_group",
    "cancel_rooms",
    "reduce_cash_payment",
    "charge_back_payment",
    "transfer_deposit"
  ]
  @cash_movement_fields %{
    "cash_received" => "received_cents",
    "cash_transferred_in" => "transferred_in_cents",
    "cash_transferred_out" => "transferred_out_cents",
    "cash_refunded" => "refunded_cents",
    "cash_retained" => "retained_cents",
    "cash_converted_to_credit" => "converted_to_credit_cents",
    "cash_reduced" => "reduced_cents",
    "cash_charged_back" => "charged_back_cents"
  }
  @credit_movement_fields %{
    "credit_issued" => "issued_cents",
    "credit_expired" => "expired_cents",
    "credit_consumed" => "consumed_cents",
    "credit_revoked" => "revoked_cents",
    "credit_absorbed" => "absorbed_cents"
  }

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def fetch_group(group_id) when is_binary(group_id) do
    case group_by_partner_id(group_id) do
      nil ->
        :not_found

      group ->
        ensure_room_allocations(group)
        {:ok, group_by_partner_id(group_id) |> group_payload()}
    end
  end

  def fetch_group(_), do: :not_found

  def fetch_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> :not_found
      operation -> {:ok, operation.result}
    end
  end

  def fetch_operation(_), do: :not_found

  def fetch_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
      nil ->
        :not_found

      %PartnerOperation{operation_type: "record_cash_payment", result: %{"status" => "applied"}} =
          operation ->
        case cash_payment_for_operation(operation) do
          nil ->
            :not_reconcilable

          payment ->
            statement = %{
              "payment_operation_id" => payment.payment_operation_id,
              "original_group_id" => operation.result["group_id"],
              "recorded_cents" => payment.recorded_cents,
              "held_cents" => held_cash_for_payment(payment.payment_operation_id),
              "refunded_cents" => payment.refunded_cents,
              "retained_cents" => payment.retained_cents,
              "converted_to_credit_cents" => payment.converted_to_credit_cents,
              "reduced_cents" => payment.reduced_cents,
              "charged_back_cents" => payment.charged_back_cents
            }

            statement =
              if payment.transfer_participated do
                Map.put(
                  statement,
                  "held_by_group",
                  held_cash_by_group(payment.payment_operation_id)
                )
              else
                statement
              end

            {:ok, statement}
        end

      _ ->
        :not_reconcilable
    end
  end

  def fetch_payment(_), do: :not_found

  def ledger(on \\ Date.utc_today()) do
    totals =
      Repo.one(
        from group in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    group.status,
                    group.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(group.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.retained_cents), 0),
            cash_converted_to_credit_cents:
              coalesce(sum(group.cash_converted_to_credit_cents), 0),
            cash_reduced_cents: coalesce(sum(group.cash_reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(group.cash_charged_back_cents), 0)
          }
      )

    (totals ||
       %{
         cash_held_cents: 0,
         cash_refunded_cents: 0,
         cash_retained_cents: 0,
         cash_converted_to_credit_cents: 0,
         cash_reduced_cents: 0,
         cash_charged_back_cents: 0
       })
    |> Map.put(:credit_liability_cents, credit_liability(on))
    |> Map.put(:credit_shortfall_cents, credit_shortfall())
  end

  def daily_finance_report(date) when is_struct(date, Date) do
    case finance_reporting() do
      nil ->
        :not_available

      %FinanceReporting{} = reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          :not_available
        else
          entries =
            Repo.all(
              from entry in FinanceEntry,
                where: entry.reporting_id == ^reporting.id
            )

          {:ok,
           %{
             "date" => Date.to_iso8601(date),
             "status" => "open",
             "cash" => daily_cash_report(entries, date),
             "credit" => daily_credit_report(entries, date, reporting.starts_on)
           }}
        end
    end
  end

  def daily_finance_report(_date), do: :not_available

  defp daily_cash_report(entries, date) do
    entries
    |> Enum.filter(&String.starts_with?(&1.kind, "cash_"))
    |> Enum.group_by(& &1.property_id)
    |> Enum.reject(fn {property_id, _entries} -> is_nil(property_id) end)
    |> Enum.map(fn {property_id, property_entries} ->
      opening =
        Enum.reduce(property_entries, 0, fn entry, total ->
          if entry.kind == "cash_opening" or Date.compare(entry.posting_on, date) == :lt do
            total + cash_balance_change(entry)
          else
            total
          end
        end)

      movements =
        Enum.reduce(property_entries, empty_cash_movements(), fn entry, totals ->
          if entry.posting_on == date do
            case Map.get(@cash_movement_fields, entry.kind) do
              nil -> totals
              field -> Map.update!(totals, field, &(&1 + entry.amount_cents))
            end
          else
            totals
          end
        end)

      closing = opening + cash_movement_balance_change(movements)

      {property_id,
       %{
         "property_id" => property_id,
         "opening_held_cents" => opening,
         "movements" => movements,
         "closing_held_cents" => closing
       }}
    end)
    |> Enum.reject(fn {_property_id, entry} ->
      entry["opening_held_cents"] == 0 and entry["closing_held_cents"] == 0 and
        Enum.all?(entry["movements"], fn {_field, amount} -> amount == 0 end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp daily_credit_report(entries, date, starts_on) do
    entries = entries ++ automatic_credit_expirations(entries, date, starts_on)

    opening =
      Enum.reduce(entries, 0, fn entry, total ->
        if entry.kind == "credit_opening" or Date.compare(entry.posting_on, date) == :lt do
          total + credit_balance_change(entry)
        else
          total
        end
      end)

    movements =
      Enum.reduce(entries, empty_credit_movements(), fn entry, totals ->
        if entry.posting_on == date do
          case Map.get(@credit_movement_fields, entry.kind) do
            nil -> totals
            field -> Map.update!(totals, field, &(&1 + entry.amount_cents))
          end
        else
          totals
        end
      end)

    %{
      "opening_liability_cents" => opening,
      "movements" => movements,
      "closing_liability_cents" => opening + credit_movement_balance_change(movements)
    }
  end

  defp empty_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp empty_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp cash_balance_change(%FinanceEntry{kind: "cash_opening", amount_cents: amount}), do: amount

  defp cash_balance_change(%FinanceEntry{kind: kind, amount_cents: amount})
       when kind in ["cash_received", "cash_transferred_in"],
       do: amount

  defp cash_balance_change(%FinanceEntry{kind: kind, amount_cents: amount})
       when kind in [
              "cash_transferred_out",
              "cash_refunded",
              "cash_retained",
              "cash_converted_to_credit",
              "cash_reduced",
              "cash_charged_back"
            ],
       do: -amount

  defp cash_balance_change(_entry), do: 0

  defp cash_movement_balance_change(movements) do
    movements["received_cents"] + movements["transferred_in_cents"] -
      movements["transferred_out_cents"] - movements["refunded_cents"] -
      movements["retained_cents"] - movements["converted_to_credit_cents"] -
      movements["reduced_cents"] - movements["charged_back_cents"]
  end

  defp credit_balance_change(%FinanceEntry{kind: "credit_opening", amount_cents: amount}),
    do: amount

  defp credit_balance_change(%{kind: "credit_issued", amount_cents: amount}), do: amount

  defp credit_balance_change(%{kind: kind, amount_cents: amount})
       when kind in ["credit_expired", "credit_consumed", "credit_revoked", "credit_absorbed"],
       do: -amount

  defp credit_balance_change(_entry), do: 0

  defp credit_movement_balance_change(movements) do
    movements["issued_cents"] - movements["expired_cents"] - movements["consumed_cents"] -
      movements["revoked_cents"] - movements["absorbed_cents"]
  end

  defp automatic_credit_expirations(entries, date, starts_on) do
    entries
    |> Enum.filter(&String.starts_with?(&1.kind, "credit_available_"))
    |> Enum.reject(&is_nil(&1.expires_on))
    |> Enum.group_by(&{&1.credit_lot_id, &1.expires_on})
    |> Enum.flat_map(fn {{credit_lot_id, expires_on}, lot_entries} ->
      posting_on = later_date(Date.add(expires_on, 1), starts_on)

      if Date.compare(posting_on, date) != :gt do
        availability_through = later_date(expires_on, starts_on)

        available_cents =
          lot_entries
          |> Enum.filter(&(Date.compare(&1.posting_on, availability_through) != :gt))
          |> Enum.sum_by(& &1.amount_cents)

        if available_cents > 0 do
          [
            %{
              kind: "credit_expired",
              credit_lot_id: credit_lot_id,
              posting_on: posting_on,
              amount_cents: available_cents
            }
          ]
        else
          []
        end
      else
        []
      end
    end)
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum_by(lots, & &1.remaining_cents),
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

  # This remains callable from the release migration so groups created before room-level
  # accounting get the same allocation order as newly recorded funding.
  def backfill_legacy_room_accounting do
    Repo.transaction(fn ->
      Repo.all(
        from group in Group, preload: [rooms: ^from(room in Room, order_by: room.position)]
      )
      |> Enum.each(&backfill_group_payment_records/1)

      Repo.all(
        from group in Group, preload: [rooms: ^from(room in Room, order_by: room.position)]
      )
      |> Enum.each(&ensure_room_allocations/1)
    end)
  end

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if valid_identifier?(operation_id) do
      with_operation_lock(operation_id, fn -> apply_or_replay(operation, operation_id) end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_operation(_), do: rejected(nil, "invalid_operation")

  defp apply_or_replay(operation, operation_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(PartnerOperation, operation_id: operation_id) do
             nil -> remember_new_operation(operation, operation_id)
             remembered -> replay_or_conflict(remembered, operation, operation_id)
           end
         end) do
      {:ok, result} -> result
      {:error, :operation_id_raced} -> apply_or_replay(operation, operation_id)
    end
  end

  defp remember_new_operation(operation, operation_id) do
    attrs = %{
      operation_id: operation_id,
      operation_type: operation_type(operation),
      payload: operation,
      result: %{}
    }

    case Repo.insert(PartnerOperation.changeset(%PartnerOperation{}, attrs)) do
      {:ok, remembered} ->
        result = run_domain_operation(operation, operation_id)

        case Repo.update(PartnerOperation.changeset(remembered, %{result: result})) do
          {:ok, _remembered} ->
            result

          {:error, changeset} ->
            raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
        end

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :operation_id) do
          Repo.rollback(:operation_id_raced)
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp replay_or_conflict(remembered, operation, operation_id) do
    if remembered.payload == operation do
      remembered.result
    else
      rejected(operation_id, "operation_id_conflict")
    end
  end

  defp run_domain_operation(operation, operation_id) do
    case finance_context(operation) do
      {:error, code} ->
        rejected(operation_id, code)

      {:ok, context} ->
        Process.put(@finance_context_key, context)

        try do
          result = operation |> dispatch() |> Map.put("operation_id", operation_id)

          if result["status"] == "applied" do
            persist_finance_entries(operation_id)
          end

          result
        after
          Process.delete(@finance_context_key)
        end
    end
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)

  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp dispatch(%{"type" => "cancel_rooms"} = operation), do: cancel_rooms(operation)

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation),
    do: reduce_cash_payment(operation)

  defp dispatch(%{"type" => "charge_back_payment"} = operation),
    do: charge_back_payment(operation)

  defp dispatch(%{"type" => "transfer_deposit"} = operation), do: transfer_deposit(operation)

  defp dispatch(%{"type" => "start_finance_reporting"} = operation),
    do: start_finance_reporting(operation)

  defp dispatch(_), do: reject("invalid_operation")

  defp start_finance_reporting(operation) do
    with {:ok, starts_on} <- reporting_date(operation),
         nil <- finance_reporting(),
         {:ok, reporting} <-
           Repo.insert(
             FinanceReporting.changeset(%FinanceReporting{}, %{
               starts_on: starts_on,
               start_operation_id: operation["operation_id"]
             })
           ),
         :ok <- record_finance_opening(reporting, operation["operation_id"]) do
      applied(%{"starts_on" => Date.to_iso8601(starts_on)})
    else
      %FinanceReporting{} -> reject("reporting_already_started")
      {:error, :invalid_reporting_date} -> reject("invalid_reporting_date")
      {:error, %Ecto.Changeset{} = changeset} -> unexpected_changeset!(changeset)
    end
  end

  defp finance_context(operation) do
    case finance_reporting() do
      nil ->
        {:ok, nil}

      reporting ->
        if operation_type(operation) in @reported_financial_operations do
          case operation_date(operation) do
            {:ok, occurred_on} ->
              {:ok,
               %{
                 reporting_id: reporting.id,
                 posting_on: later_date(occurred_on, reporting.starts_on),
                 entries: []
               }}

            {:error, :invalid_operation_date} ->
              {:error, "invalid_operation"}
          end
        else
          {:ok, nil}
        end
    end
  end

  defp finance_reporting do
    Repo.one(from reporting in FinanceReporting, limit: 1)
  end

  defp reporting_date(operation) do
    case date_value(operation, "starts_on") do
      {:ok, date} -> {:ok, date}
      {:error, :invalid_stay} -> {:error, :invalid_reporting_date}
    end
  end

  defp later_date(left, right) do
    if Date.compare(left, right) == :lt, do: right, else: left
  end

  defp record_finance_opening(reporting, operation_id) do
    cash_openings =
      Repo.all(
        from group in Group,
          where: group.status == "active" and group.cash_paid_cents > 0,
          group_by: group.property_id,
          select: {group.property_id, sum(group.cash_paid_cents)}
      )
      |> Enum.map(fn {property_id, amount_cents} ->
        %{kind: "cash_opening", property_id: property_id, amount_cents: amount_cents}
      end)

    credit_opening =
      if credit_liability(reporting.starts_on) > 0 do
        [%{kind: "credit_opening", amount_cents: credit_liability(reporting.starts_on)}]
      else
        []
      end

    available_credit_openings =
      Repo.all(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^reporting.starts_on
      )
      |> Enum.map(fn lot ->
        %{
          kind: "credit_available_opening",
          credit_lot_id: lot.id,
          expires_on: lot.expires_on,
          amount_cents: lot.remaining_cents
        }
      end)

    insert_finance_entries(
      reporting.id,
      operation_id,
      reporting.starts_on,
      cash_openings ++ credit_opening ++ available_credit_openings
    )
  end

  defp queue_finance_entry(kind, amount_cents, attrs \\ %{})

  defp queue_finance_entry(_kind, 0, _attrs), do: :ok

  defp queue_finance_entry(kind, amount_cents, attrs) when is_integer(amount_cents) do
    case Process.get(@finance_context_key) do
      nil ->
        :ok

      context ->
        entry = Map.merge(%{kind: kind, amount_cents: amount_cents}, attrs)
        Process.put(@finance_context_key, %{context | entries: [entry | context.entries]})
        :ok
    end
  end

  defp queue_cash_movement(kind, property_id, amount_cents) do
    queue_finance_entry(kind, amount_cents, %{property_id: property_id})
  end

  defp queue_credit_availability(kind, lot, amount_cents) do
    queue_finance_entry(kind, amount_cents, %{credit_lot_id: lot.id, expires_on: lot.expires_on})
  end

  defp queue_credit_revocation(lot, amount_cents) do
    case Process.get(@finance_context_key) do
      %{posting_on: posting_on} when is_integer(amount_cents) ->
        if Date.compare(posting_on, lot.expires_on) != :gt do
          queue_finance_entry("credit_revoked", amount_cents)
          queue_credit_availability("credit_available_revoked", lot, -amount_cents)
        end

      _ ->
        :ok
    end
  end

  defp persist_finance_entries(operation_id) do
    case Process.get(@finance_context_key) do
      nil ->
        :ok

      %{reporting_id: reporting_id, posting_on: posting_on, entries: entries} ->
        insert_finance_entries(reporting_id, operation_id, posting_on, Enum.reverse(entries))
    end
  end

  defp insert_finance_entries(reporting_id, operation_id, posting_on, entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, entry_index}, :ok ->
      attrs =
        entry
        |> Map.merge(%{
          reporting_id: reporting_id,
          partner_operation_id: operation_id,
          entry_index: entry_index,
          posting_on: posting_on
        })

      case Repo.insert(FinanceEntry.changeset(%FinanceEntry{}, attrs)) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, changeset} -> unexpected_changeset!(changeset)
    end
  end

  defp open_group(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id"),
         nil <- group_by_partner_id(group_id),
         {:ok, attrs, room_attrs} <- opening_attrs(operation, group_id),
         {:ok, group} <- Repo.insert(Group.changeset(%Group{}, attrs)),
         :ok <- insert_rooms(group, room_attrs) do
      applied(%{
        "group_id" => group.group_id,
        "deposit_due_cents" => group.deposit_due_cents,
        "revision" => group.revision
      })
    else
      %Group{} -> reject("group_already_exists", group_result(operation))
      {:error, code} when is_binary(code) -> reject(code)
      {:error, {:room_insert_failed, changeset}} -> unexpected_changeset!(changeset)
      {:error, %Ecto.Changeset{}} -> reject("group_already_exists", group_result(operation))
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, _occurred_on} <- operation_date(operation),
         {:ok, amount} <- positive_amount(operation, "amount_cents"),
         :ok <- payment_within_outstanding?(group, amount),
         {:ok, _payment} <- create_cash_payment(group, operation["operation_id"], amount),
         :ok <- allocate_cash(group, operation["operation_id"], amount),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             cash_paid_cents: group.cash_paid_cents + amount,
             revision: group.revision + 1
           })
           |> Repo.update(),
         :ok <- queue_cash_movement("cash_received", group.property_id, amount) do
      applied(%{
        "group_id" => updated_group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        reject("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:error, :invalid_operation_date} ->
        reject("invalid_operation", group_result(operation))

      {:error, :invalid_amount} ->
        reject("invalid_amount", group_result(operation))

      {:error, :payment_exceeds_outstanding} ->
        reject("payment_exceeds_outstanding", group_result(operation))

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)

      {:stale, details} ->
        reject("stale_revision", details)

      :inactive ->
        reject("group_not_active", group_result(operation))
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, amount} <- positive_amount(operation, "amount_cents"),
         :ok <- payment_within_outstanding?(group, amount),
         {:ok, consumed_lots} <- consume_credit(group, amount, occurred_on),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             credit_paid_cents: group.credit_paid_cents + amount,
             revision: group.revision + 1
           })
           |> Repo.update(),
         :ok <- record_credit_application_for_reporting(consumed_lots) do
      applied(%{
        "group_id" => updated_group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        reject("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:error, :invalid_operation_date} ->
        reject("invalid_operation", group_result(operation))

      {:error, :invalid_amount} ->
        reject("invalid_amount", group_result(operation))

      {:error, :payment_exceeds_outstanding} ->
        reject("payment_exceeds_outstanding", group_result(operation))

      {:error, :insufficient_credit} ->
        reject("insufficient_credit", group_result(operation))

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)

      {:stale, details} ->
        reject("stale_revision", details)

      :inactive ->
        reject("group_not_active", group_result(operation))
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, new_arrival_on} <- date_value(operation, "new_arrival_on"),
         :ok <- future_arrival?(new_arrival_on, occurred_on),
         new_departure_on <-
           Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)),
         {:ok, updated_group} <-
           group
           |> Group.changeset(%{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: group.revision + 1
           })
           |> Repo.update() do
      applied(%{
        "group_id" => updated_group.group_id,
        "new_arrival_on" => Date.to_iso8601(updated_group.arrival_on),
        "new_departure_on" => Date.to_iso8601(updated_group.departure_on),
        "policy_version" => updated_group.policy_version,
        "refundable_until" => refundable_until_payload(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} -> reject("group_not_found", group_result(operation))
      {:error, :invalid_identifier} -> reject("invalid_operation")
      {:error, :invalid_operation_date} -> reject("invalid_operation", group_result(operation))
      {:error, :invalid_stay} -> reject("invalid_stay", group_result(operation))
      {:error, %Ecto.Changeset{} = changeset} -> unexpected_changeset!(changeset)
      {:stale, details} -> reject("stale_revision", details)
      :inactive -> reject("group_not_active", group_result(operation))
    end
  end

  defp cancel_group(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- refund_method_available?(group, occurred_on, refund_method),
         {:ok, settlement, updated_group} <-
           settle_rooms(
             group,
             Enum.filter(group.rooms, &(&1.status == "active")),
             occurred_on,
             refund_method,
             operation["operation_id"]
           ) do
      applied(%{
        "group_id" => updated_group.group_id,
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        reject("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:error, :invalid_operation_date} ->
        reject("invalid_operation", group_result(operation))

      {:error, :invalid_refund_method} ->
        reject("invalid_operation", group_result(operation))

      {:error, :refund_method_not_available} ->
        reject("refund_method_not_available", group_result(operation))

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)

      {:stale, details} ->
        reject("stale_revision", details)

      :inactive ->
        reject("group_not_active", group_result(operation))
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group} <- group_for_operation(operation),
         :ok <- revision_matches?(group, operation),
         :ok <- active?(group),
         {:ok, occurred_on} <- operation_date(operation),
         {:ok, refund_method} <- refund_method(operation),
         :ok <- refund_method_available?(group, occurred_on, refund_method),
         {:ok, rooms} <- selected_active_rooms(group, operation),
         {:ok, settlement, updated_group} <-
           settle_rooms(group, rooms, occurred_on, refund_method, operation["operation_id"]) do
      applied(%{
        "group_id" => updated_group.group_id,
        "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
        "refunded_cents" => settlement.refunded_cents,
        "retained_cents" => settlement.retained_cents,
        "credit_issued_cents" => settlement.credit_issued_cents,
        "revision" => updated_group.revision
      })
    else
      {:error, :not_found} ->
        reject("group_not_found", group_result(operation))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:error, :invalid_operation_date} ->
        reject("invalid_operation", group_result(operation))

      {:error, :invalid_refund_method} ->
        reject("invalid_operation", group_result(operation))

      {:error, :refund_method_not_available} ->
        reject("refund_method_not_available", group_result(operation))

      {:error, :invalid_rooms} ->
        reject("invalid_rooms", group_result(operation))

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)

      {:stale, details} ->
        reject("stale_revision", details)

      :inactive ->
        reject("group_not_active", group_result(operation))
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment, group} <- payment_and_group(operation),
         :ok <- revision_matches?(group, operation),
         {:ok, amount} <- positive_amount(operation, "amount_cents"),
         held_cents <- held_cash_for_payment(payment.payment_operation_id),
         :ok <- reducible_amount?(held_cents, amount),
         {:ok, removed_by_group} <- remove_held_cash(payment.payment_operation_id, amount),
         {:ok, _payment} <-
           Repo.update(
             CashPayment.changeset(payment, %{reduced_cents: payment.reduced_cents + amount})
           ),
         {:ok, updated_group} <-
           refresh_groups(group, group_history_for(removed_by_group, :cash_reduced_cents)),
         :ok <- record_cash_by_group_for_reporting("cash_reduced", removed_by_group) do
      applied(%{
        "payment_operation_id" => payment.payment_operation_id,
        "group_id" => updated_group.group_id,
        "amount_cents" => amount,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :operation_not_found} -> reject("operation_not_found")
      {:error, :invalid_identifier} -> reject("invalid_operation")
      {:error, :payment_not_reducible} -> reject("payment_not_reducible")
      {:error, :invalid_amount} -> reject("invalid_amount")
      {:error, :reduction_exceeds_held_cash} -> reject("reduction_exceeds_held_cash")
      {:error, %Ecto.Changeset{} = changeset} -> unexpected_changeset!(changeset)
      {:stale, details} -> reject("stale_revision", details)
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment, group} <- payment_and_group(operation),
         :ok <- revision_matches?(group, operation),
         held_cents <- held_cash_for_payment(payment.payment_operation_id),
         chargeable_cents <-
           held_cents + payment.refunded_cents + payment.retained_cents +
             payment.converted_to_credit_cents,
         :ok <- chargeable?(payment, chargeable_cents),
         {:ok, removed_by_group} <- remove_held_cash(payment.payment_operation_id, held_cents),
         :ok <- revoke_credit_entitlements(payment.payment_operation_id),
         {:ok, _payment} <-
           Repo.update(
             CashPayment.changeset(payment, %{
               refunded_cents: 0,
               retained_cents: 0,
               converted_to_credit_cents: 0,
               charged_back_cents: payment.charged_back_cents + chargeable_cents
             })
           ),
         {:ok, updated_group} <-
           refresh_groups(group, chargeback_history(group, payment, removed_by_group)),
         :ok <- record_chargeback_for_reporting(group, payment, removed_by_group) do
      applied(%{
        "payment_operation_id" => payment.payment_operation_id,
        "group_id" => updated_group.group_id,
        "charged_back_cents" => chargeable_cents,
        "outstanding_deposit_cents" => outstanding_deposit(updated_group),
        "revision" => updated_group.revision
      })
    else
      {:error, :operation_not_found} -> reject("operation_not_found")
      {:error, :invalid_identifier} -> reject("invalid_operation")
      {:error, :payment_not_reducible} -> reject("payment_not_chargeable")
      {:error, :payment_not_chargeable} -> reject("payment_not_chargeable")
      {:error, %Ecto.Changeset{} = changeset} -> unexpected_changeset!(changeset)
      {:stale, details} -> reject("stale_revision", details)
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source} <- transfer_group(operation, "source_group_id"),
         {:ok, destination} <- transfer_group(operation, "destination_group_id"),
         :ok <- revision_matches?(source, operation, "expected_revision"),
         :ok <- revision_matches?(destination, operation, "destination_expected_revision"),
         :ok <- valid_transfer?(source, destination),
         :ok <- active?(source, :source),
         :ok <- active?(destination, :destination),
         {:ok, amount} <- positive_amount(operation, "amount_cents"),
         :ok <- transfer_within_held_funding?(source, amount),
         :ok <- transfer_within_outstanding?(destination, amount),
         {:ok, moved_cash_cents} <- move_held_funding(source, destination, amount),
         {:ok, updated_source} <- refresh_group(source, %{}),
         {:ok, updated_destination} <- refresh_group(destination, %{}),
         :ok <-
           record_cash_transfer_for_reporting(
             source.property_id,
             destination.property_id,
             moved_cash_cents
           ) do
      applied(%{
        "source_group_id" => updated_source.group_id,
        "destination_group_id" => updated_destination.group_id,
        "amount_cents" => amount,
        "source_outstanding_deposit_cents" => outstanding_deposit(updated_source),
        "destination_outstanding_deposit_cents" => outstanding_deposit(updated_destination),
        "source_revision" => updated_source.revision,
        "destination_revision" => updated_destination.revision
      })
    else
      {:error, {:not_found, key}} ->
        reject("group_not_found", transfer_group_result(operation, key))

      {:error, :invalid_identifier} ->
        reject("invalid_operation")

      {:stale, details} ->
        reject("stale_revision", details)

      {:error, :invalid_transfer} ->
        reject("invalid_transfer")

      :inactive_source ->
        reject("group_not_active", transfer_group_result(operation, "source_group_id"))

      :inactive_destination ->
        reject("group_not_active", transfer_group_result(operation, "destination_group_id"))

      {:error, :invalid_amount} ->
        reject("invalid_amount")

      {:error, :transfer_exceeds_held_funding} ->
        reject("transfer_exceeds_held_funding")

      {:error, :transfer_exceeds_outstanding} ->
        reject("transfer_exceeds_outstanding")

      {:error, %Ecto.Changeset{} = changeset} ->
        unexpected_changeset!(changeset)
    end
  end

  defp transfer_group(operation, key) do
    with {:ok, group_id} <- required_identifier(operation, key) do
      case group_by_partner_id(group_id) do
        nil ->
          {:error, {:not_found, key}}

        group ->
          ensure_room_allocations(group)
          {:ok, group_by_partner_id(group_id)}
      end
    end
  end

  defp valid_transfer?(%Group{id: source_id}, %Group{id: source_id}),
    do: {:error, :invalid_transfer}

  defp valid_transfer?(%Group{guest_id: guest_id}, %Group{guest_id: guest_id}), do: :ok
  defp valid_transfer?(_source, _destination), do: {:error, :invalid_transfer}

  defp active?(%Group{status: "active"}, :source), do: :ok
  defp active?(%Group{status: "active"}, :destination), do: :ok
  defp active?(_group, :source), do: :inactive_source
  defp active?(_group, :destination), do: :inactive_destination

  defp transfer_within_held_funding?(source, amount) do
    if held_funding_for_group(source) >= amount,
      do: :ok,
      else: {:error, :transfer_exceeds_held_funding}
  end

  defp transfer_within_outstanding?(destination, amount) do
    if amount <= outstanding_deposit(destination),
      do: :ok,
      else: {:error, :transfer_exceeds_outstanding}
  end

  defp move_held_funding(source, destination, amount) do
    source
    |> held_funding_allocations()
    |> Enum.reduce_while({:ok, {amount, 0}}, fn allocation,
                                                {:ok, {remaining, moved_cash_cents}} ->
      moved_cents = min(allocation.amount_cents, remaining)

      moved_cash_cents =
        if allocation.kind == :cash, do: moved_cash_cents + moved_cents, else: moved_cash_cents

      with :ok <- remove_funding_allocation(allocation, moved_cents),
           :ok <- move_credit_application(source, destination, allocation, moved_cents),
           :ok <- mark_cash_payment_transferred(allocation, moved_cents),
           :ok <-
             allocate_to_rooms(destination, moved_cents, allocation.kind, allocation.source_id) do
        if moved_cents == remaining do
          {:halt, {:ok, {0, moved_cash_cents}}}
        else
          {:cont, {:ok, {remaining - moved_cents, moved_cash_cents}}}
        end
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, {0, moved_cash_cents}} -> {:ok, moved_cash_cents}
      {:ok, {_remaining, _moved_cash_cents}} -> {:error, :transfer_exceeds_held_funding}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp held_funding_for_group(group) do
    group
    |> held_funding_allocations()
    |> Enum.sum_by(& &1.amount_cents)
  end

  defp held_funding_allocations(group) do
    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.group_db_id == ^group.id,
          select: %{
            kind: :cash,
            id: allocation.id,
            room_db_id: allocation.room_db_id,
            source_id: allocation.payment_operation_id,
            amount_cents: allocation.amount_cents,
            allocation_order_id: allocation.allocation_order_id
          }
      )

    credit_allocations =
      Repo.all(
        from allocation in RoomCreditAllocation,
          where: allocation.group_db_id == ^group.id,
          select: %{
            kind: :credit,
            id: allocation.id,
            room_db_id: allocation.room_db_id,
            source_id: allocation.credit_lot_id,
            amount_cents: allocation.amount_cents,
            allocation_order_id: allocation.allocation_order_id
          }
      )

    Enum.sort_by(cash_allocations ++ credit_allocations, & &1.allocation_order_id, :desc)
  end

  defp remove_funding_allocation(%{kind: :cash} = allocation, amount_cents) do
    with %CashAllocation{} = record <- Repo.get(CashAllocation, allocation.id),
         :ok <- update_allocation_amount(record, amount_cents),
         :ok <- update_room_funding(allocation.room_db_id, :cash, -amount_cents) do
      :ok
    else
      nil -> {:error, :transfer_exceeds_held_funding}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp remove_funding_allocation(%{kind: :credit} = allocation, amount_cents) do
    with %RoomCreditAllocation{} = record <- Repo.get(RoomCreditAllocation, allocation.id),
         :ok <- update_allocation_amount(record, amount_cents),
         :ok <- update_room_funding(allocation.room_db_id, :credit, -amount_cents) do
      :ok
    else
      nil -> {:error, :transfer_exceeds_held_funding}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp update_allocation_amount(record, amount_cents) do
    result =
      if amount_cents == record.amount_cents do
        Repo.delete(record)
      else
        record
        |> Ecto.Changeset.change(amount_cents: record.amount_cents - amount_cents)
        |> Repo.update()
      end

    case result do
      {:ok, _record} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp update_room_funding(room_db_id, :cash, change_cents) do
    update_room_funding(room_db_id, :cash_paid_cents, change_cents)
  end

  defp update_room_funding(room_db_id, :credit, change_cents) do
    update_room_funding(room_db_id, :credit_paid_cents, change_cents)
  end

  defp update_room_funding(room_db_id, field, change_cents) do
    room = Repo.get!(Room, room_db_id)

    case Repo.update(Room.changeset(room, %{field => Map.fetch!(room, field) + change_cents})) do
      {:ok, _room} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp move_credit_application(_source, _destination, %{kind: :cash}, _amount_cents), do: :ok

  defp move_credit_application(source, destination, %{source_id: credit_lot_id}, amount_cents) do
    with :ok <- remove_credit_application(source.id, credit_lot_id, amount_cents),
         :ok <- add_credit_application(destination.id, credit_lot_id, amount_cents) do
      :ok
    end
  end

  defp add_credit_application(group_db_id, credit_lot_id, amount_cents) do
    case Repo.get_by(CreditApplication, group_db_id: group_db_id, credit_lot_id: credit_lot_id) do
      nil ->
        case Repo.insert(
               CreditApplication.changeset(%CreditApplication{}, %{
                 group_db_id: group_db_id,
                 credit_lot_id: credit_lot_id,
                 amount_cents: amount_cents
               })
             ) do
          {:ok, _application} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      application ->
        case Repo.update(
               CreditApplication.changeset(application, %{
                 amount_cents: application.amount_cents + amount_cents
               })
             ) do
          {:ok, _application} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp mark_cash_payment_transferred(%{kind: :credit}, _amount_cents), do: :ok
  defp mark_cash_payment_transferred(%{source_id: nil}, _amount_cents), do: :ok

  defp mark_cash_payment_transferred(%{source_id: payment_operation_id}, _amount_cents) do
    {updated, _} =
      Repo.update_all(
        from(payment in CashPayment,
          where: payment.payment_operation_id == ^payment_operation_id
        ),
        set: [transfer_participated: true]
      )

    if updated == 1, do: :ok, else: {:error, :transfer_exceeds_held_funding}
  end

  defp opening_attrs(operation, group_id) do
    with {:ok, guest_id} <- required_identifier(operation, "guest_id"),
         {:ok, property_id} <- required_identifier(operation, "property_id"),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, arrival_on} <- date_value(operation, "arrival_on"),
         {:ok, departure_on} <- date_value(operation, "departure_on"),
         :ok <- valid_stay?(arrival_on, departure_on),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, rooms, lodging_total_cents, deposit_due_cents} <-
           rooms(operation, arrival_on, departure_on, rate_plan) do
      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: booked_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         policy_version: policy_for(rate_plan, booked_on),
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
         revision: 1
       }, rooms}
    else
      {:error, :invalid_operation_date} -> {:error, "invalid_operation"}
      {:error, :invalid_stay} -> {:error, "invalid_stay"}
      {:error, :invalid_rate_plan} -> {:error, "invalid_rate_plan"}
      {:error, :invalid_rooms} -> {:error, "invalid_rooms"}
      {:error, :invalid_identifier} -> {:error, "invalid_operation"}
    end
  end

  defp group_for_operation(operation) do
    with {:ok, group_id} <- required_identifier(operation, "group_id") do
      case group_by_partner_id(group_id) do
        nil ->
          {:error, :not_found}

        group ->
          ensure_room_allocations(group)
          {:ok, group_by_partner_id(group_id)}
      end
    end
  end

  defp group_by_partner_id(group_id) do
    Repo.one(
      from group in Group,
        where: group.group_id == ^group_id,
        preload: [rooms: ^from(room in Room, order_by: room.position)]
    )
  end

  defp insert_rooms(group, room_attrs) do
    Enum.reduce_while(room_attrs, :ok, fn room_attrs, :ok ->
      attrs = Map.put(room_attrs, :group_db_id, group.id)

      case Repo.insert(Room.changeset(%Room{}, attrs)) do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, {:room_insert_failed, changeset}}}
      end
    end)
  end

  defp rooms(%{"rooms" => rooms}, arrival_on, departure_on, rate_plan)
       when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({[], MapSet.new(), 0, 0}, fn {room, position},
                                                      {attrs, room_ids, lodging_total,
                                                       deposit_total} ->
      case room_attrs(room, position, room_ids, nights, rate_plan) do
        {:ok, room_attrs, room_id, lodging_cents, deposit_cents} ->
          {:cont,
           {[room_attrs | attrs], MapSet.put(room_ids, room_id), lodging_total + lodging_cents,
            deposit_total + deposit_cents}}

        {:error, :invalid_rooms} ->
          {:halt, :invalid_rooms}
      end
    end)
    |> case do
      :invalid_rooms ->
        {:error, :invalid_rooms}

      {attrs, _room_ids, lodging_total, deposit_total} ->
        {:ok, Enum.reverse(attrs), lodging_total, deposit_total}
    end
  end

  defp rooms(_, _, _, _), do: {:error, :invalid_rooms}

  defp room_attrs(
         %{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents},
         position,
         room_ids,
         nights,
         rate_plan
       )
       when is_binary(room_id) and room_id != "" and is_integer(nightly_rate_cents) and
              nightly_rate_cents >= 0 do
    if MapSet.member?(room_ids, room_id) do
      {:error, :invalid_rooms}
    else
      lodging_cents = nights * nightly_rate_cents
      deposit_cents = deposit_for(lodging_cents, rate_plan)

      {:ok,
       %{
         room_id: room_id,
         nightly_rate_cents: nightly_rate_cents,
         position: position,
         status: "active",
         lodging_total_cents: lodging_cents,
         deposit_due_cents: deposit_cents,
         cash_paid_cents: 0,
         credit_paid_cents: 0
       }, room_id, lodging_cents, deposit_cents}
    end
  end

  defp room_attrs(_, _, _, _, _), do: {:error, :invalid_rooms}

  defp deposit_for(lodging_cents, "flexible"), do: div(lodging_cents * 20 + 50, 100)
  defp deposit_for(lodging_cents, "advance_purchase"), do: lodging_cents

  defp rate_plan(%{"rate_plan" => rate_plan}) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp rate_plan(_), do: {:error, :invalid_rate_plan}

  defp valid_stay?(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp future_arrival?(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, :invalid_stay}
  end

  defp positive_amount(operation, key) do
    case Map.get(operation, key) do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp payment_within_outstanding?(group, amount) do
    if amount <= outstanding_deposit(group),
      do: :ok,
      else: {:error, :payment_exceeds_outstanding}
  end

  defp active?(%Group{status: "active"}), do: :ok
  defp active?(_), do: :inactive

  defp revision_matches?(group, operation),
    do: revision_matches?(group, operation, "expected_revision")

  defp revision_matches?(group, operation, key) do
    case Map.fetch(operation, key) do
      :error ->
        :ok

      {:ok, expected_revision} when is_integer(expected_revision) ->
        if expected_revision == group.revision do
          :ok
        else
          {:stale,
           %{
             "group_id" => group.group_id,
             "expected_revision" => expected_revision,
             "actual_revision" => group.revision
           }}
        end

      {:ok, _} ->
        {:error, :invalid_identifier}
    end
  end

  defp operation_date(operation) do
    case date_value(operation, "occurred_on") do
      {:ok, date} -> {:ok, date}
      {:error, :invalid_stay} -> {:error, :invalid_operation_date}
    end
  end

  defp date_value(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _} -> {:error, :invalid_stay}
        end

      _ ->
        {:error, :invalid_stay}
    end
  end

  defp required_identifier(operation, key) do
    case Map.get(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_identifier}
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp consume_credit(group, amount, occurred_on) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
      )

    if Enum.sum_by(lots, & &1.remaining_cents) < amount do
      {:error, :insufficient_credit}
    else
      consume_credit_lots(lots, group, amount)
    end
  end

  defp consume_credit_lots(lots, group, amount) do
    lots
    |> Enum.reduce_while({:ok, {amount, []}}, fn lot, {:ok, {remaining, consumed_lots}} ->
      applied_cents = min(lot.remaining_cents, remaining)

      with {:ok, _lot} <-
             Repo.update(
               CreditLot.changeset(lot, %{remaining_cents: lot.remaining_cents - applied_cents})
             ),
           {:ok, _application} <-
             Repo.insert(
               CreditApplication.changeset(%CreditApplication{}, %{
                 group_db_id: group.id,
                 credit_lot_id: lot.id,
                 amount_cents: applied_cents
               })
             ),
           :ok <- allocate_credit(group, lot.id, applied_cents) do
        if applied_cents == remaining do
          {:halt, {:ok, {0, [{lot, applied_cents} | consumed_lots]}}}
        else
          {:cont, {:ok, {remaining - applied_cents, [{lot, applied_cents} | consumed_lots]}}}
        end
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, {0, consumed_lots}} -> {:ok, Enum.reverse(consumed_lots)}
      {:ok, {_remaining, _consumed_lots}} -> {:error, :insufficient_credit}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp record_credit_application_for_reporting(consumed_lots) do
    Enum.each(consumed_lots, fn {lot, amount_cents} ->
      queue_credit_availability("credit_available_applied", lot, -amount_cents)
    end)

    :ok
  end

  defp create_cash_payment(group, operation_id, amount) do
    Repo.insert(
      CashPayment.changeset(%CashPayment{}, %{
        payment_operation_id: operation_id,
        group_db_id: group.id,
        recorded_cents: amount
      })
    )
  end

  defp allocate_cash(group, payment_operation_id, amount) do
    allocate_to_rooms(group, amount, :cash, payment_operation_id)
  end

  defp allocate_credit(group, credit_lot_id, amount) do
    allocate_to_rooms(group, amount, :credit, credit_lot_id)
  end

  defp allocate_to_rooms(group, amount, kind, source_id) do
    Repo.all(
      from room in Room,
        where: room.group_db_id == ^group.id and room.status == "active",
        order_by: room.position
    )
    |> Enum.reduce_while({:ok, amount}, fn room, {:ok, remaining} ->
      capacity = max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)
      allocated_cents = min(capacity, remaining)

      if allocated_cents == 0 do
        {:cont, {:ok, remaining}}
      else
        room_attrs =
          case kind do
            :cash -> %{cash_paid_cents: room.cash_paid_cents + allocated_cents}
            :credit -> %{credit_paid_cents: room.credit_paid_cents + allocated_cents}
          end

        allocation =
          case kind do
            :cash ->
              CashAllocation.changeset(%CashAllocation{}, %{
                group_db_id: group.id,
                room_db_id: room.id,
                payment_operation_id: source_id,
                amount_cents: allocated_cents
              })

            :credit ->
              RoomCreditAllocation.changeset(%RoomCreditAllocation{}, %{
                group_db_id: group.id,
                room_db_id: room.id,
                credit_lot_id: source_id,
                amount_cents: allocated_cents
              })
          end

        with {:ok, _room} <- Repo.update(Room.changeset(room, room_attrs)),
             {:ok, allocation} <- Repo.insert(allocation),
             :ok <- assign_allocation_order(allocation, kind) do
          if allocated_cents == remaining do
            {:halt, :ok}
          else
            {:cont, {:ok, remaining - allocated_cents}}
          end
        else
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end
    end)
    |> case do
      :ok -> :ok
      {:ok, _remaining} -> {:error, :payment_exceeds_outstanding}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp assign_allocation_order(allocation, kind) do
    if allocation_orders_available?() do
      allocation_type = if kind == :cash, do: "cash", else: "credit"

      with {:ok, order} <-
             Repo.insert(
               AllocationOrder.changeset(%AllocationOrder{}, %{
                 allocation_type: allocation_type,
                 allocation_db_id: to_string(allocation.id)
               })
             ),
           :ok <- attach_allocation_order(allocation, kind, order.id) do
        :ok
      else
        {:error, changeset} -> {:error, changeset}
      end
    else
      :ok
    end
  end

  defp attach_allocation_order(allocation, kind, order_id) do
    if allocation_order_column_available?(kind) do
      case Repo.update(Ecto.Changeset.change(allocation, allocation_order_id: order_id)) do
        {:ok, _allocation} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    else
      :ok
    end
  end

  defp allocation_orders_available? do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'allocation_orders'"
         ) do
      {:ok, %{num_rows: 1}} -> true
      _ -> false
    end
  end

  defp allocation_order_column_available?(kind) do
    table = if kind == :cash, do: "room_cash_allocations", else: "room_credit_allocations"

    case Ecto.Adapters.SQL.query(Repo, "PRAGMA table_info(#{table})") do
      {:ok, %{rows: rows}} ->
        Enum.any?(rows, fn [_position, name | _details] -> name == "allocation_order_id" end)

      _ ->
        false
    end
  end

  defp selected_active_rooms(group, %{"room_ids" => room_ids})
       when is_list(room_ids) and room_ids != [] do
    valid_ids? = Enum.all?(room_ids, &(is_binary(&1) and &1 != ""))

    if valid_ids? and MapSet.size(MapSet.new(room_ids)) == length(room_ids) do
      selected_ids = MapSet.new(room_ids)

      rooms =
        Enum.filter(group.rooms, fn room ->
          room.status == "active" and MapSet.member?(selected_ids, room.room_id)
        end)

      if length(rooms) == length(room_ids), do: {:ok, rooms}, else: {:error, :invalid_rooms}
    else
      {:error, :invalid_rooms}
    end
  end

  defp selected_active_rooms(_group, _operation), do: {:error, :invalid_rooms}

  defp settle_rooms(group, rooms, occurred_on, refund_method, operation_id) do
    room_ids = Enum.map(rooms, & &1.id)

    cash_allocations =
      Repo.all(
        from allocation in CashAllocation,
          where: allocation.room_db_id in ^room_ids,
          order_by: allocation.id
      )

    cash_cents = Enum.sum_by(cash_allocations, & &1.amount_cents)
    refundable = refundable?(group, occurred_on)

    with :ok <- settle_room_credit(group, room_ids, occurred_on, refundable),
         {:ok, credit_issued_cents} <-
           issue_credit(group, refund_method, operation_id, occurred_on, cash_allocations),
         :ok <- settle_cash_dispositions(group, cash_allocations, refundable, refund_method),
         :ok <- delete_cash_allocations(cash_allocations),
         :ok <- cancel_room_records(rooms),
         {:ok, updated_group} <-
           refresh_group(group, cancellation_totals(group, cash_cents, refundable, refund_method)),
         :ok <-
           record_cash_settlement_for_reporting(
             group.property_id,
             cash_cents,
             refundable,
             refund_method
           ) do
      refunded_cents = if refundable and refund_method == "cash", do: cash_cents, else: 0
      retained_cents = if refundable, do: 0, else: cash_cents

      {:ok,
       %{
         refunded_cents: refunded_cents,
         retained_cents: retained_cents,
         credit_issued_cents: credit_issued_cents
       }, updated_group}
    end
  end

  defp cancellation_totals(group, cash_cents, true, "cash"),
    do: %{refunded_cents: group.refunded_cents + cash_cents}

  defp cancellation_totals(group, cash_cents, true, "hotel_credit"),
    do: %{cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + cash_cents}

  defp cancellation_totals(group, cash_cents, false, _refund_method),
    do: %{retained_cents: group.retained_cents + cash_cents}

  defp settle_room_credit(group, room_ids, occurred_on, refundable) do
    allocations =
      Repo.all(
        from allocation in RoomCreditAllocation,
          where: allocation.room_db_id in ^room_ids,
          preload: [:credit_lot]
      )

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.reduce_while(:ok, fn {_lot_id, lot_allocations}, :ok ->
      [allocation | _] = lot_allocations
      amount_cents = Enum.sum_by(lot_allocations, & &1.amount_cents)

      with :ok <- remove_credit_application(group.id, allocation.credit_lot_id, amount_cents),
           :ok <-
             settle_credit_for_reporting(
               allocation.credit_lot,
               amount_cents,
               occurred_on,
               refundable
             ),
           :ok <- delete_room_credit_allocations(lot_allocations) do
        {:cont, :ok}
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp settle_credit_for_reporting(_lot, amount_cents, _occurred_on, false) do
    queue_finance_entry("credit_consumed", amount_cents)
    :ok
  end

  defp settle_credit_for_reporting(lot, amount_cents, occurred_on, true) do
    absorbed_cents = min(lot.unrecovered_clawback_cents, amount_cents)
    available_cents = amount_cents - absorbed_cents

    available_cents =
      if Date.compare(lot.expires_on, occurred_on) != :lt, do: available_cents, else: 0

    expired_cents = amount_cents - absorbed_cents - available_cents

    case Repo.update(
           CreditLot.changeset(lot, %{
             remaining_cents: lot.remaining_cents + available_cents,
             unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed_cents
           })
         ) do
      {:ok, _lot} ->
        queue_finance_entry("credit_absorbed", absorbed_cents)
        queue_finance_entry("credit_expired", expired_cents)
        queue_credit_availability("credit_available_restored", lot, available_cents)
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp remove_credit_application(group_db_id, credit_lot_id, amount_cents) do
    Repo.all(
      from application in CreditApplication,
        where:
          application.group_db_id == ^group_db_id and application.credit_lot_id == ^credit_lot_id,
        order_by: application.id
    )
    |> Enum.reduce_while({:ok, amount_cents}, fn application, {:ok, remaining} ->
      removed_cents = min(application.amount_cents, remaining)

      result =
        if removed_cents == application.amount_cents do
          Repo.delete(application)
        else
          Repo.update(
            CreditApplication.changeset(application, %{
              amount_cents: application.amount_cents - removed_cents
            })
          )
        end

      case result do
        {:ok, _application} when removed_cents == remaining -> {:halt, :ok}
        {:ok, _application} -> {:cont, {:ok, remaining - removed_cents}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      :ok -> :ok
      {:ok, _remaining} -> {:error, :invalid_rooms}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp delete_room_credit_allocations(allocations) do
    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      case Repo.delete(allocation) do
        {:ok, _allocation} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp issue_credit(_group, "cash", _operation_id, _occurred_on, _cash_allocations), do: {:ok, 0}

  defp issue_credit(group, "hotel_credit", operation_id, occurred_on, cash_allocations) do
    cash_cents = Enum.sum_by(cash_allocations, & &1.amount_cents)
    credit_issued_cents = cash_cents + bonus_for(cash_cents)

    if credit_issued_cents == 0 do
      {:ok, 0}
    else
      with {:ok, lot} <-
             Repo.insert(
               CreditLot.changeset(%CreditLot{}, %{
                 guest_id: group.guest_id,
                 source_operation_id: operation_id,
                 remaining_cents: credit_issued_cents,
                 expires_on: Date.add(occurred_on, 365),
                 unrecovered_clawback_cents: 0
               })
             ),
           :ok <- create_credit_entitlements(lot, cash_allocations),
           :ok <- record_credit_issuance_for_reporting(lot, credit_issued_cents) do
        {:ok, credit_issued_cents}
      end
    end
  end

  defp record_cash_settlement_for_reporting(property_id, cash_cents, true, "cash") do
    queue_cash_movement("cash_refunded", property_id, cash_cents)
  end

  defp record_cash_settlement_for_reporting(property_id, cash_cents, true, "hotel_credit") do
    queue_cash_movement("cash_converted_to_credit", property_id, cash_cents)
  end

  defp record_cash_settlement_for_reporting(property_id, cash_cents, false, _refund_method) do
    queue_cash_movement("cash_retained", property_id, cash_cents)
  end

  defp record_credit_issuance_for_reporting(lot, amount_cents) do
    queue_finance_entry("credit_issued", amount_cents)
    queue_credit_availability("credit_available_issued", lot, amount_cents)
    :ok
  end

  defp record_cash_by_group_for_reporting(kind, amounts_by_group) do
    Enum.each(amounts_by_group, fn {group_db_id, amount_cents} ->
      group = Repo.get!(Group, group_db_id)
      queue_cash_movement(kind, group.property_id, amount_cents)
    end)

    :ok
  end

  defp record_cash_transfer_for_reporting(
         source_property_id,
         destination_property_id,
         amount_cents
       ) do
    queue_cash_movement("cash_transferred_out", source_property_id, amount_cents)
    queue_cash_movement("cash_transferred_in", destination_property_id, amount_cents)
    :ok
  end

  defp record_chargeback_for_reporting(original_group, payment, held_by_group) do
    record_cash_by_group_for_reporting("cash_charged_back", held_by_group)

    tracked_by_field =
      Repo.all(
        from disposition in CashPaymentDisposition,
          where: disposition.payment_operation_id == ^payment.payment_operation_id
      )
      |> Enum.reduce(%{}, fn disposition, tracked ->
        group = Repo.get!(Group, disposition.group_db_id)
        kind = payment_disposition_kind(disposition.disposition)

        queue_cash_movement(kind, group.property_id, -disposition.amount_cents)
        queue_cash_movement("cash_charged_back", group.property_id, disposition.amount_cents)

        Map.update(
          tracked,
          payment_disposition_field(disposition.disposition),
          disposition.amount_cents,
          &(&1 + disposition.amount_cents)
        )
      end)

    [
      {:refunded_cents, payment.refunded_cents},
      {:retained_cents, payment.retained_cents},
      {:cash_converted_to_credit_cents, payment.converted_to_credit_cents}
    ]
    |> Enum.each(fn {field, payment_cents} ->
      untracked_cents = payment_cents - Map.get(tracked_by_field, field, 0)

      if untracked_cents > 0 do
        queue_cash_movement(
          payment_history_kind(field),
          original_group.property_id,
          -untracked_cents
        )

        queue_cash_movement("cash_charged_back", original_group.property_id, untracked_cents)
      end
    end)

    :ok
  end

  defp payment_disposition_kind("refunded"), do: "cash_refunded"
  defp payment_disposition_kind("retained"), do: "cash_retained"
  defp payment_disposition_kind("converted_to_credit"), do: "cash_converted_to_credit"

  defp payment_history_kind(:refunded_cents), do: "cash_refunded"
  defp payment_history_kind(:retained_cents), do: "cash_retained"

  defp payment_history_kind(:cash_converted_to_credit_cents),
    do: "cash_converted_to_credit"

  defp create_credit_entitlements(lot, cash_allocations) do
    cash_allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.map(fn {payment_operation_id, allocations} ->
      {payment_operation_id, Enum.sum_by(allocations, & &1.amount_cents)}
    end)
    |> order_cash_sources()
    |> create_credit_entitlements_from_sources(lot)
  end

  defp create_credit_entitlements_from_sources(sources, lot) do
    sources
    |> Enum.reduce_while({:ok, 0}, fn {payment_operation_id, amount_cents}, {:ok, prior_cents} ->
      total_cents = prior_cents + amount_cents
      entitlement_cents = amount_cents + bonus_for(total_cents) - bonus_for(prior_cents)

      case Repo.insert(
             CreditLotEntitlement.changeset(%CreditLotEntitlement{}, %{
               credit_lot_id: lot.id,
               payment_operation_id: payment_operation_id,
               entitlement_cents: entitlement_cents
             })
           ) do
        {:ok, _entitlement} -> {:cont, {:ok, total_cents}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, _total_cents} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp settle_cash_dispositions(group, cash_allocations, refundable, refund_method) do
    field =
      cond do
        refundable and refund_method == "cash" -> :refunded_cents
        refundable -> :converted_to_credit_cents
        true -> :retained_cents
      end

    cash_allocations
    |> Enum.reject(&is_nil(&1.payment_operation_id))
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.reduce_while(:ok, fn {payment_operation_id, allocations}, :ok ->
      payment = Repo.get_by!(CashPayment, payment_operation_id: payment_operation_id)
      amount_cents = Enum.sum_by(allocations, & &1.amount_cents)

      with {:ok, _payment} <-
             Repo.update(
               CashPayment.changeset(payment, %{
                 field => Map.fetch!(payment, field) + amount_cents
               })
             ),
           :ok <-
             record_cash_payment_disposition(group, payment_operation_id, field, amount_cents) do
        {:cont, :ok}
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp record_cash_payment_disposition(group, payment_operation_id, field, amount_cents) do
    disposition =
      case field do
        :refunded_cents -> "refunded"
        :retained_cents -> "retained"
        :converted_to_credit_cents -> "converted_to_credit"
      end

    case Repo.get_by(CashPaymentDisposition,
           payment_operation_id: payment_operation_id,
           group_db_id: group.id,
           disposition: disposition
         ) do
      nil ->
        case Repo.insert(
               CashPaymentDisposition.changeset(%CashPaymentDisposition{}, %{
                 payment_operation_id: payment_operation_id,
                 group_db_id: group.id,
                 disposition: disposition,
                 amount_cents: amount_cents
               })
             ) do
          {:ok, _disposition} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      record ->
        case Repo.update(
               CashPaymentDisposition.changeset(record, %{
                 amount_cents: record.amount_cents + amount_cents
               })
             ) do
          {:ok, _disposition} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp delete_cash_allocations(allocations) do
    Enum.reduce_while(allocations, :ok, fn allocation, :ok ->
      case Repo.delete(allocation) do
        {:ok, _allocation} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp cancel_room_records(rooms) do
    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      case Repo.update(
             Room.changeset(room, %{
               status: "cancelled",
               deposit_due_cents: 0,
               cash_paid_cents: 0,
               credit_paid_cents: 0
             })
           ) do
        {:ok, _room} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp payment_and_group(operation) do
    with {:ok, payment_operation_id} <- required_identifier(operation, "payment_operation_id") do
      case Repo.get_by(PartnerOperation, operation_id: payment_operation_id) do
        nil ->
          {:error, :operation_not_found}

        partner_operation ->
          case cash_payment_for_operation(partner_operation) do
            nil ->
              {:error, :payment_not_reducible}

            payment ->
              case partner_operation.result["group_id"] do
                group_id when is_binary(group_id) ->
                  case group_by_partner_id(group_id) do
                    nil ->
                      {:error, :payment_not_reducible}

                    group ->
                      ensure_room_allocations(group)
                      {:ok, payment, group_by_partner_id(group_id)}
                  end

                _ ->
                  {:error, :payment_not_reducible}
              end
          end
      end
    else
      {:error, :invalid_identifier} -> {:error, :invalid_identifier}
    end
  end

  defp cash_payment_for_operation(%PartnerOperation{
         operation_type: "record_cash_payment",
         result: %{"status" => "applied"},
         operation_id: operation_id
       }) do
    Repo.get_by(CashPayment, payment_operation_id: operation_id)
  end

  defp cash_payment_for_operation(_operation), do: nil

  defp held_cash_for_payment(payment_operation_id) do
    Repo.one(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        select: coalesce(sum(allocation.amount_cents), 0)
    )
  end

  defp held_cash_by_group(payment_operation_id) do
    Repo.all(
      from allocation in CashAllocation,
        join: group in Group,
        on: group.id == allocation.group_db_id,
        where:
          allocation.payment_operation_id == ^payment_operation_id and group.status == "active",
        group_by: group.group_id,
        order_by: group.group_id,
        select: {group.group_id, sum(allocation.amount_cents)}
    )
    |> Enum.map(fn {group_id, amount_cents} ->
      %{"group_id" => group_id, "amount_cents" => amount_cents}
    end)
  end

  defp reducible_amount?(0, _amount_cents), do: {:error, :payment_not_reducible}

  defp reducible_amount?(held_cents, amount_cents) when amount_cents > held_cents,
    do: {:error, :reduction_exceeds_held_cash}

  defp reducible_amount?(_held_cents, _amount_cents), do: :ok

  defp chargeable?(%CashPayment{charged_back_cents: charged_back_cents}, _chargeable_cents)
       when charged_back_cents > 0,
       do: {:error, :payment_not_chargeable}

  defp chargeable?(_payment, 0), do: {:error, :payment_not_chargeable}
  defp chargeable?(_payment, _chargeable_cents), do: :ok

  defp remove_held_cash(_payment_operation_id, 0), do: {:ok, %{}}

  defp remove_held_cash(payment_operation_id, amount_cents) do
    Repo.all(
      from allocation in CashAllocation,
        where: allocation.payment_operation_id == ^payment_operation_id,
        order_by: [desc: allocation.allocation_order_id]
    )
    |> Enum.reduce_while({:ok, {amount_cents, %{}}}, fn allocation,
                                                        {:ok, {remaining, removed_by_group}} ->
      removed_cents = min(allocation.amount_cents, remaining)

      with :ok <- update_allocation_amount(allocation, removed_cents),
           :ok <- update_room_funding(allocation.room_db_id, :cash, -removed_cents) do
        removed_by_group =
          Map.update(
            removed_by_group,
            allocation.group_db_id,
            removed_cents,
            &(&1 + removed_cents)
          )

        if removed_cents == remaining do
          {:halt, {:ok, {0, removed_by_group}}}
        else
          {:cont, {:ok, {remaining - removed_cents, removed_by_group}}}
        end
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, {0, removed_by_group}} -> {:ok, removed_by_group}
      {:ok, {_remaining, _removed_by_group}} -> {:error, :payment_not_reducible}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp revoke_credit_entitlements(payment_operation_id) do
    Repo.all(
      from entitlement in CreditLotEntitlement,
        where: entitlement.payment_operation_id == ^payment_operation_id,
        preload: [:credit_lot]
    )
    |> Enum.reduce_while(:ok, fn entitlement, :ok ->
      lot = entitlement.credit_lot
      removed_cents = min(lot.remaining_cents, entitlement.entitlement_cents)
      unrecovered_cents = entitlement.entitlement_cents - removed_cents

      case Repo.update(
             CreditLot.changeset(lot, %{
               remaining_cents: lot.remaining_cents - removed_cents,
               unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered_cents
             })
           ) do
        {:ok, _lot} ->
          queue_credit_revocation(lot, removed_cents)
          {:cont, :ok}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp refresh_group(group, history_changes) do
    active_rooms =
      Repo.all(
        from room in Room,
          where: room.group_db_id == ^group.id and room.status == "active"
      )

    cash_paid_cents = Enum.sum_by(active_rooms, & &1.cash_paid_cents)
    credit_paid_cents = Enum.sum_by(active_rooms, & &1.credit_paid_cents)

    attrs =
      Map.merge(
        %{
          status: if(active_rooms == [], do: "cancelled", else: "active"),
          lodging_total_cents: Enum.sum_by(active_rooms, & &1.lodging_total_cents),
          deposit_due_cents: Enum.sum_by(active_rooms, & &1.deposit_due_cents),
          cash_paid_cents: cash_paid_cents,
          credit_paid_cents: credit_paid_cents,
          deposit_paid_cents: cash_paid_cents + credit_paid_cents,
          revision: group.revision + 1
        },
        history_changes
      )

    Repo.update(Group.changeset(group, attrs))
  end

  defp refresh_groups(original_group, history_by_group) do
    history_by_group = Map.put_new(history_by_group, original_group.id, %{})

    history_by_group
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, nil}, fn group_db_id, {:ok, updated_original_group} ->
      group =
        if group_db_id == original_group.id,
          do: original_group,
          else: Repo.get!(Group, group_db_id)

      history_changes =
        history_by_group
        |> Map.fetch!(group_db_id)
        |> Map.new(fn {field, change_cents} ->
          {field, Map.fetch!(group, field) + change_cents}
        end)

      case refresh_group(group, history_changes) do
        {:ok, updated_group} ->
          updated_original_group =
            if group_db_id == original_group.id, do: updated_group, else: updated_original_group

          {:cont, {:ok, updated_original_group}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp group_history_for(amounts_by_group, field) do
    Map.new(amounts_by_group, fn {group_db_id, amount_cents} ->
      {group_db_id, %{field => amount_cents}}
    end)
  end

  defp chargeback_history(original_group, payment, held_by_group) do
    history_by_group = group_history_for(held_by_group, :cash_charged_back_cents)

    {history_by_group, tracked_by_field} =
      Repo.all(
        from disposition in CashPaymentDisposition,
          where: disposition.payment_operation_id == ^payment.payment_operation_id
      )
      |> Enum.reduce({history_by_group, %{}}, fn disposition, {history, tracked} ->
        field = payment_disposition_field(disposition.disposition)

        history =
          history
          |> add_history(disposition.group_db_id, field, -disposition.amount_cents)
          |> add_history(
            disposition.group_db_id,
            :cash_charged_back_cents,
            disposition.amount_cents
          )

        {history,
         Map.update(tracked, field, disposition.amount_cents, &(&1 + disposition.amount_cents))}
      end)

    [
      {:refunded_cents, payment.refunded_cents},
      {:retained_cents, payment.retained_cents},
      {:cash_converted_to_credit_cents, payment.converted_to_credit_cents}
    ]
    |> Enum.reduce(history_by_group, fn {field, payment_cents}, history ->
      untracked_cents = payment_cents - Map.get(tracked_by_field, field, 0)

      if untracked_cents == 0 do
        history
      else
        history
        |> add_history(original_group.id, field, -untracked_cents)
        |> add_history(original_group.id, :cash_charged_back_cents, untracked_cents)
      end
    end)
  end

  defp payment_disposition_field("refunded"), do: :refunded_cents
  defp payment_disposition_field("retained"), do: :retained_cents
  defp payment_disposition_field("converted_to_credit"), do: :cash_converted_to_credit_cents

  defp add_history(history_by_group, group_db_id, field, amount_cents) do
    Map.update(history_by_group, group_db_id, %{field => amount_cents}, fn changes ->
      Map.update(changes, field, amount_cents, &(&1 + amount_cents))
    end)
  end

  defp order_cash_sources(sources) do
    durable_positions =
      sources
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] ->
          %{}

        operation_ids ->
          Repo.all(
            from operation in PartnerOperation,
              where: operation.operation_id in ^operation_ids,
              order_by: operation.id,
              select: {operation.operation_id, operation.id}
          )
          |> Map.new()
      end

    Enum.sort_by(sources, fn
      {nil, _amount_cents} -> {0, 0}
      {operation_id, _amount_cents} -> {1, Map.fetch!(durable_positions, operation_id)}
    end)
  end

  defp backfill_group_payment_records(group) do
    operations = durable_cash_operations(group)
    dispositions = historical_payment_dispositions(group, operations)

    Enum.each(operations, fn operation ->
      if is_nil(Repo.get_by(CashPayment, payment_operation_id: operation.operation_id)) do
        attrs =
          Map.merge(
            %{
              payment_operation_id: operation.operation_id,
              group_db_id: group.id,
              recorded_cents: operation.result["amount_cents"]
            },
            Map.get(dispositions, operation.operation_id, %{})
          )

        case Repo.insert(CashPayment.changeset(%CashPayment{}, attrs)) do
          {:ok, _payment} -> :ok
          {:error, changeset} -> unexpected_changeset!(changeset)
        end
      end
    end)

    backfill_credit_entitlements(group, operations)
  end

  defp historical_payment_dispositions(%Group{status: "active"}, _operations), do: %{}

  defp historical_payment_dispositions(group, operations) do
    {field, total_cents} =
      cond do
        group.refunded_cents > 0 ->
          {:refunded_cents, group.refunded_cents}

        group.retained_cents > 0 ->
          {:retained_cents, group.retained_cents}

        group.cash_converted_to_credit_cents > 0 ->
          {:converted_to_credit_cents, group.cash_converted_to_credit_cents}

        true ->
          {nil, 0}
      end

    if field do
      durable_cents = Enum.sum_by(operations, & &1.result["amount_cents"])
      legacy_cents = max(total_cents - durable_cents, 0)

      {_, dispositions} =
        Enum.reduce(operations, {legacy_cents, %{}}, fn operation,
                                                        {allocated_cents, dispositions} ->
          payment_cents = min(operation.result["amount_cents"], total_cents - allocated_cents)

          {allocated_cents + payment_cents,
           Map.put(dispositions, operation.operation_id, %{field => payment_cents})}
        end)

      dispositions
    else
      %{}
    end
  end

  defp backfill_credit_entitlements(group, operations) do
    if group.cash_converted_to_credit_cents > 0 do
      cancellation =
        Repo.all(from operation in PartnerOperation, order_by: [desc: operation.id])
        |> Enum.find(fn operation ->
          operation.operation_type == "cancel_group" and
            get_in(operation.result, ["status"]) == "applied" and
            get_in(operation.result, ["group_id"]) == group.group_id and
            is_integer(get_in(operation.result, ["credit_issued_cents"])) and
            operation.result["credit_issued_cents"] > 0
        end)

      with %PartnerOperation{} = cancellation <- cancellation,
           %CreditLot{} = lot <-
             Repo.get_by(CreditLot, source_operation_id: cancellation.operation_id),
           0 <-
             Repo.aggregate(
               from(entitlement in CreditLotEntitlement,
                 where: entitlement.credit_lot_id == ^lot.id
               ),
               :count
             ) do
        durable_cents = Enum.sum_by(operations, & &1.result["amount_cents"])
        legacy_cents = max(group.cash_converted_to_credit_cents - durable_cents, 0)

        sources =
          [
            {nil, legacy_cents}
            | Enum.map(operations, &{&1.operation_id, &1.result["amount_cents"]})
          ]
          |> Enum.reject(fn {_operation_id, amount_cents} -> amount_cents == 0 end)
          |> take_cash_sources(group.cash_converted_to_credit_cents)
          |> order_cash_sources()

        case create_credit_entitlements_from_sources(sources, lot) do
          :ok -> :ok
          {:error, changeset} -> unexpected_changeset!(changeset)
        end
      else
        _ -> :ok
      end
    end
  end

  defp take_cash_sources(sources, total_cents) do
    {taken, _remaining} =
      Enum.reduce_while(sources, {[], total_cents}, fn {operation_id, amount_cents},
                                                       {taken, remaining} ->
        taken_cents = min(amount_cents, remaining)

        if taken_cents == remaining do
          {:halt, {[{operation_id, taken_cents} | taken], 0}}
        else
          {:cont, {[{operation_id, taken_cents} | taken], remaining - taken_cents}}
        end
      end)

    Enum.reverse(taken)
  end

  defp ensure_room_allocations(%Group{status: "active"} = group) do
    cash_allocated? =
      Repo.aggregate(
        from(allocation in CashAllocation, where: allocation.group_db_id == ^group.id),
        :count
      ) > 0

    credit_allocated? =
      Repo.aggregate(
        from(allocation in RoomCreditAllocation, where: allocation.group_db_id == ^group.id),
        :count
      ) > 0

    if (not cash_allocated? and group.cash_paid_cents > 0) or
         (not credit_allocated? and group.credit_paid_cents > 0) do
      backfill_room_funding(group, cash_allocated?, credit_allocated?)
    end
  end

  defp ensure_room_allocations(_group), do: :ok

  defp backfill_room_funding(group, cash_allocated?, credit_allocated?) do
    operations = durable_funding_operations(group)
    applications = credit_applications_for_group(group.id)

    durable_cash_cents =
      operations
      |> Enum.filter(&(&1.operation_type == "record_cash_payment"))
      |> Enum.sum_by(& &1.result["amount_cents"])

    durable_credit_cents =
      operations
      |> Enum.filter(&(&1.operation_type == "apply_hotel_credit"))
      |> Enum.sum_by(& &1.result["amount_cents"])

    legacy_cash_cents = max(group.cash_paid_cents - durable_cash_cents, 0)
    legacy_credit_cents = max(group.credit_paid_cents - durable_credit_cents, 0)

    {legacy_credit_applications, durable_credit_applications} =
      take_credit_applications(applications, legacy_credit_cents)

    if not cash_allocated? and legacy_cash_cents > 0 do
      allocate_cash(group, nil, legacy_cash_cents)
    end

    if not credit_allocated? do
      Enum.each(legacy_credit_applications, fn {credit_lot_id, amount_cents} ->
        allocate_credit(group, credit_lot_id, amount_cents)
      end)
    end

    Enum.reduce(operations, durable_credit_applications, fn operation, remaining_applications ->
      case operation.operation_type do
        "record_cash_payment" ->
          if not cash_allocated? do
            allocate_cash(group, operation.operation_id, operation.result["amount_cents"])
          end

          remaining_applications

        "apply_hotel_credit" ->
          {operation_applications, remaining_applications} =
            take_credit_applications(remaining_applications, operation.result["amount_cents"])

          if not credit_allocated? do
            Enum.each(operation_applications, fn {credit_lot_id, amount_cents} ->
              allocate_credit(group, credit_lot_id, amount_cents)
            end)
          end

          remaining_applications
      end
    end)
  end

  defp durable_funding_operations(group) do
    Repo.all(from operation in PartnerOperation, order_by: operation.id)
    |> Enum.filter(fn operation ->
      operation.operation_type in ["record_cash_payment", "apply_hotel_credit"] and
        get_in(operation.result, ["status"]) == "applied" and
        get_in(operation.result, ["group_id"]) == group.group_id and
        is_integer(get_in(operation.result, ["amount_cents"]))
    end)
  end

  defp durable_cash_operations(group) do
    durable_funding_operations(group)
    |> Enum.filter(&(&1.operation_type == "record_cash_payment"))
  end

  defp credit_applications_for_group(group_db_id) do
    Repo.all(
      from application in CreditApplication,
        where: application.group_db_id == ^group_db_id,
        order_by: [asc: application.inserted_at, asc: application.id]
    )
  end

  defp take_credit_applications(applications, total_cents) when total_cents <= 0,
    do: {[], applications}

  defp take_credit_applications([], _total_cents), do: {[], []}

  defp take_credit_applications([application | remaining_applications], total_cents) do
    if application.amount_cents <= total_cents do
      {taken, remaining} =
        take_credit_applications(remaining_applications, total_cents - application.amount_cents)

      {[{application.credit_lot_id, application.amount_cents} | taken], remaining}
    else
      {[{application.credit_lot_id, total_cents}],
       [
         %{application | amount_cents: application.amount_cents - total_cents}
         | remaining_applications
       ]}
    end
  end

  defp bonus_for(cash_cents), do: div(cash_cents * 10 + 50, 100)

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, :invalid_refund_method}
    end
  end

  defp refund_method_available?(group, occurred_on, "hotel_credit") do
    if refundable?(group, occurred_on),
      do: :ok,
      else: {:error, :refund_method_not_available}
  end

  defp refund_method_available?(_group, _occurred_on, "cash"), do: :ok

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_start) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(%Group{}), do: nil

  defp refundable_until_payload(group) do
    case refundable_until(group) do
      nil -> nil
      date -> Date.to_iso8601(date)
    end
  end

  defp credit_liability(on) do
    available_cents =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from application in CreditApplication,
          join: group in Group,
          on: group.id == application.group_db_id,
          where: group.status == "active",
          select: coalesce(sum(application.amount_cents), 0)
      )

    available_cents + applied_cents
  end

  defp credit_shortfall do
    Repo.all(from lot in CreditLot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.sum_by(fn lot ->
      applied_cents =
        Repo.one(
          from application in CreditApplication,
            join: group in Group,
            on: group.id == application.group_db_id,
            where: group.status == "active" and application.credit_lot_id == ^lot.id,
            select: coalesce(sum(application.amount_cents), 0)
        )

      min(lot.unrecovered_clawback_cents, applied_cents)
    end)
  end

  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  # Partner operations mutate connected funding and revision state, so one durable-operation lock
  # keeps cross-group transfers and payment corrections atomic without nested global locks.
  defp with_operation_lock(_operation_id, fun) do
    :global.trans({__MODULE__, :operations}, fun)
  end

  defp group_payload(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group.policy_version,
      "refundable_until" => refundable_until_payload(group),
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

  defp applied(fields), do: Map.merge(%{"status" => "applied"}, fields)

  defp reject(code, fields \\ %{}), do: rejected(nil, code, fields)

  defp unexpected_changeset!(changeset) do
    raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
  end

  defp rejected(operation_id, code, fields \\ %{}) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
    |> Map.merge(fields)
  end

  defp group_result(operation) do
    case Map.get(operation, "group_id") do
      group_id when is_binary(group_id) -> %{"group_id" => group_id}
      _ -> %{}
    end
  end

  defp transfer_group_result(operation, key) do
    case Map.get(operation, key) do
      group_id when is_binary(group_id) -> %{"group_id" => group_id}
      _ -> %{}
    end
  end
end
