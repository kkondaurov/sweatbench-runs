defmodule GroupStay.Operations do
  import Ecto.Query

  alias GroupStay.Accounting.CreditEntitlement
  alias GroupStay.Accounting.Payment
  alias GroupStay.Accounting.RoomFunding
  alias GroupStay.Credit.Application, as: CreditApplication
  alias GroupStay.Credit.Lot, as: CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Record, as: OperationRecord
  alias GroupStay.Repo

  @domain_savepoint "group_stay_operation_domain"
  @policy_cutover ~D[2027-01-01]
  @open_fields [
    "operation_id",
    "type",
    "occurred_on",
    "group_id",
    "guest_id",
    "property_id",
    "arrival_on",
    "departure_on",
    "rate_plan",
    "rooms"
  ]
  @common_fields ["operation_id", "type", "occurred_on"]

  @doc "Applies a partner batch in order. Handled rejections do not stop the batch."
  def process_batch(operations) when is_list(operations),
    do: Enum.map(operations, &process_operation/1)

  @doc "Applies one operation and returns its public result."
  def process_operation(operation) when is_map(operation) do
    case field_value(operation, "operation_id") do
      operation_id when is_binary(operation_id) and byte_size(operation_id) > 0 ->
        transact(operation)

      _operation_id ->
        rejected(operation, "invalid_operation")
    end
  end

  def process_operation(operation), do: rejected(operation, "invalid_operation")

  @doc "Returns a serialized group or a group_not_found error."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, %{code: "group_not_found"}}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, %{code: "group_not_found"}}

  @doc "Returns the stored result for a durably received operation."
  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> {:error, %{code: "operation_not_found"}}
      record -> {:ok, decode_result(record.result_json)}
    end
  end

  def get_operation(_operation_id), do: {:error, %{code: "operation_not_found"}}

  @doc "Returns the current reconciliation statement for an applied cash payment."
  def get_payment(payment_operation_id) when is_binary(payment_operation_id) do
    case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
      nil ->
        {:error, %{code: "operation_not_found"}}

      %OperationRecord{type: "record_cash_payment"} = record ->
        result = decode_result(record.result_json)

        case {result[:status], Repo.get_by(Payment, payment_operation_id: payment_operation_id)} do
          {"applied", %Payment{} = payment} ->
            {:ok,
             %{
               payment_operation_id: payment.payment_operation_id,
               original_group_id: payment.group_id,
               recorded_cents: payment.recorded_cents,
               held_cents: payment.held_cents,
               refunded_cents: payment.refunded_cents,
               retained_cents: payment.retained_cents,
               converted_to_credit_cents: payment.converted_to_credit_cents,
               reduced_cents: payment.reduced_cents,
               charged_back_cents: payment.charged_back_cents
             }}

          _other ->
            {:error, %{code: "payment_not_reconcilable"}}
        end

      _record ->
        {:error, %{code: "payment_not_reconcilable"}}
    end
  end

  def get_payment(_payment_operation_id), do: {:error, %{code: "operation_not_found"}}

  @doc "Parses the optional date used by read endpoints."
  def parse_as_of(nil), do: {:ok, Date.utc_today()}

  def parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_date"}
    end
  end

  def parse_as_of(_value), do: {:error, "invalid_date"}

  @doc "Returns finance totals, including current credit liability and shortfall."
  def ledger_totals, do: ledger_totals(Date.utc_today())

  def ledger_totals(%Date{} = as_of) do
    totals =
      Repo.all(
        from group in Group,
          select:
            {group.status, group.cash_paid_cents, group.refunded_cents, group.retained_cents,
             group.cash_converted_to_credit_cents, group.cash_reduced_cents,
             group.cash_charged_back_cents}
      )
      |> Enum.reduce(
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          cash_reduced_cents: 0,
          cash_charged_back_cents: 0
        },
        fn {status, held, refunded, retained, converted, reduced, charged_back}, totals ->
          %{
            totals
            | cash_held_cents: totals.cash_held_cents + if(status == "active", do: held, else: 0),
              cash_refunded_cents: totals.cash_refunded_cents + refunded,
              cash_retained_cents: totals.cash_retained_cents + retained,
              cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents + converted,
              cash_reduced_cents: totals.cash_reduced_cents + reduced,
              cash_charged_back_cents: totals.cash_charged_back_cents + charged_back
          }
        end
      )

    totals
    |> Map.put(:credit_liability_cents, credit_liability(as_of))
    |> Map.put(:credit_shortfall_cents, credit_shortfall())
  end

  @doc "Returns a guest's unexpired, available credit lots."
  def get_guest_credit(guest_id, %Date{} = as_of) when is_binary(guest_id) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^as_of,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

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

  def get_guest_credit(guest_id, _as_of) when is_binary(guest_id),
    do: get_guest_credit(guest_id, Date.utc_today())

  def get_guest_credit(_guest_id, _as_of), do: {:error, %{code: "guest_not_found"}}

  defp credit_liability(as_of) do
    available =
      Repo.all(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.expires_on >= ^as_of,
          select: lot.remaining_cents
      )
      |> Enum.sum()

    applied =
      Repo.all(
        from application in CreditApplication,
          join: group in Group,
          on: group.group_id == application.group_id,
          where: group.status == "active",
          select: application.amount_cents
      )
      |> Enum.sum()

    available + applied
  end

  defp credit_shortfall do
    Repo.all(
      from lot in CreditLot,
        join: application in CreditApplication,
        on: application.credit_lot_id == lot.id,
        join: group in Group,
        on: group.group_id == application.group_id,
        where: lot.unrecovered_clawback_cents > 0 and group.status == "active",
        group_by: [lot.id, lot.unrecovered_clawback_cents],
        select: {lot.unrecovered_clawback_cents, sum(application.amount_cents)}
    )
    |> Enum.reduce(0, fn {unrecovered, applied}, total ->
      total + min(unrecovered, applied || 0)
    end)
  end

  defp transact(operation) do
    payload_json = canonical_json(operation)

    case Repo.transaction(
           fn ->
             case Repo.get_by(OperationRecord,
                    operation_id: field_value(operation, "operation_id")
                  ) do
               %OperationRecord{} = record ->
                 if record.payload_json == payload_json do
                   decode_result(record.result_json)
                 else
                   rejected(operation, "operation_id_conflict")
                 end

               nil ->
                 remember_new_operation(operation, payload_json)
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise "operation transaction rolled back unexpectedly: #{inspect(reason)}"
    end
  end

  defp remember_new_operation(operation, payload_json) do
    Repo.query!("SAVEPOINT #{@domain_savepoint}")

    case dispatch(operation) do
      {:ok, result} ->
        Repo.query!("RELEASE SAVEPOINT #{@domain_savepoint}")
        remember_result(operation, payload_json, result)

      {:error, code, details} ->
        Repo.query!("ROLLBACK TO SAVEPOINT #{@domain_savepoint}")
        Repo.query!("RELEASE SAVEPOINT #{@domain_savepoint}")
        result = rejected(operation, code, details)
        remember_result(operation, payload_json, result)
    end
  end

  defp dispatch(operation) do
    case field_value(operation, "type") do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "cancel_rooms" -> cancel_rooms(operation)
      "reduce_cash_payment" -> reduce_cash_payment(operation)
      "charge_back_payment" -> charge_back_payment(operation)
      _type -> error("invalid_operation")
    end
  end

  defp remember_result(operation, payload_json, result) do
    OperationRecord.changeset(%OperationRecord{}, %{
      operation_id: field_value(operation, "operation_id"),
      type: operation_type(operation),
      payload_json: payload_json,
      result_json: canonical_json(result)
    })
    |> Repo.insert!()

    result
  end

  defp operation_type(operation) do
    case field_value(operation, "type") do
      type when is_binary(type) -> type
      _type -> nil
    end
  end

  defp decode_result(result_json), do: Jason.decode!(result_json, keys: :atoms!)

  defp canonical_json(value), do: value |> canonical_json_term() |> Jason.encode!()

  defp canonical_json_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} ->
      {canonical_json_key(key), canonical_json_term(nested_value)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical_json_term(value) when is_list(value), do: Enum.map(value, &canonical_json_term/1)
  defp canonical_json_term(value), do: value

  defp canonical_json_key(key) when is_binary(key), do: key
  defp canonical_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_json_key(key), do: to_string(key)

  defp open_group(operation) do
    with :ok <- required_fields(operation, @open_fields),
         :ok <-
           valid_identifiers(operation, ["operation_id", "group_id", "guest_id", "property_id"]),
         {:ok, group_id} <- field(operation, "group_id") do
      case Repo.get(Group, group_id) do
        %Group{} -> error("group_already_exists", %{group_id: group_id})
        nil -> build_and_insert_group(operation)
      end
    end
  end

  defp build_and_insert_group(operation) do
    with {:ok, booked_on} <- parse_date(field_value(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field_value(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field_value(operation, "departure_on")),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- valid_rate_plan(field_value(operation, "rate_plan")),
         {:ok, room_data} <-
           parse_rooms(field_value(operation, "rooms"), arrival_on, departure_on, rate_plan),
         {:ok, group_id} <- field(operation, "group_id"),
         {:ok, guest_id} <- field(operation, "guest_id"),
         {:ok, property_id} <- field(operation, "property_id"),
         policy_version <- policy_version(rate_plan, booked_on),
         {:ok, group} <-
           insert_group(%{
             group_id: group_id,
             guest_id: guest_id,
             property_id: property_id,
             booked_on: booked_on,
             arrival_on: arrival_on,
             departure_on: departure_on,
             rate_plan: rate_plan,
             policy_version: policy_version,
             status: "active",
             revision: 1,
             lodging_total_cents: room_data.lodging_total_cents,
             deposit_due_cents: room_data.deposit_due_cents,
             deposit_paid_cents: 0,
             cash_paid_cents: 0,
             credit_paid_cents: 0,
             refunded_cents: 0,
             retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             cash_reduced_cents: 0,
             cash_charged_back_cents: 0
           }),
         :ok <- insert_rooms(group.group_id, room_data.rooms) do
      applied(operation, %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, _occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- usable_amount(field_value(operation, "amount_cents")),
         outstanding <- outstanding_deposit(group),
         :ok <- within_outstanding(amount_cents, outstanding),
         {:ok, _payment} <- insert_payment(group, operation, amount_cents),
         :ok <-
           allocate_funding_to_rooms(
             group,
             "cash",
             "cash_payment",
             field_value(operation, "operation_id"),
             nil,
             amount_cents
           ),
         {:ok, updated_group} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount_cents,
             cash_paid_cents: group.cash_paid_cents + amount_cents,
             revision: group.revision + 1
           }) do
      applied(operation, %{
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding - amount_cents,
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {:ok, amount_cents} <- usable_amount(field_value(operation, "amount_cents")),
         outstanding <- outstanding_deposit(group),
         :ok <- within_outstanding(amount_cents, outstanding),
         :ok <- apply_credit_to_group(group, amount_cents, occurred_on, operation),
         {:ok, updated_group} <-
           update_group(group, %{
             deposit_paid_cents: group.deposit_paid_cents + amount_cents,
             credit_paid_cents: group.credit_paid_cents + amount_cents,
             revision: group.revision + 1
           }) do
      applied(operation, %{
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding - amount_cents,
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {:ok, new_arrival_on} <- parse_date(field_value(operation, "new_arrival_on")),
         :ok <- after_operation_date(new_arrival_on, occurred_on),
         day_shift <- Date.diff(new_arrival_on, group.arrival_on),
         new_departure_on <- Date.add(group.departure_on, day_shift),
         {:ok, updated_group} <-
           update_group(group, %{
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: group.revision + 1
           }) do
      applied(operation, %{
        group_id: updated_group.group_id,
        new_arrival_on: Date.to_iso8601(updated_group.arrival_on),
        new_departure_on: Date.to_iso8601(updated_group.departure_on),
        policy_version: effective_policy_version(updated_group),
        refundable_until: refundable_until(updated_group),
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp cancel_group(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {:ok, refund_method} <- refund_method(operation),
         refundable <- refundable?(group, occurred_on),
         :ok <- refund_method_available(refundable, refund_method),
         {:ok, rooms} <- selected_rooms(group, nil),
         {:ok, settlement} <-
           settle_selected_rooms(group, rooms, occurred_on, refund_method, operation),
         {:ok, updated_group} <- settle_group(group, settlement) do
      applied(operation, %{
        group_id: updated_group.group_id,
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp cancel_rooms(operation) do
    with {:ok, group} <- existing_group(operation),
         :ok <- expected_revision(operation, group),
         {:ok, occurred_on} <- common_operation(operation),
         :ok <- active_group(group),
         {:ok, refund_method} <- refund_method(operation),
         refundable <- refundable?(group, occurred_on),
         :ok <- refund_method_available(refundable, refund_method),
         {:ok, rooms} <- selected_rooms(group, field_value(operation, "room_ids")),
         {:ok, settlement} <-
           settle_selected_rooms(group, rooms, occurred_on, refund_method, operation),
         {:ok, updated_group} <- settle_group(group, settlement) do
      applied(operation, %{
        group_id: updated_group.group_id,
        cancelled_room_ids: Enum.map(rooms, & &1.room_id),
        refunded_cents: settlement.refunded_cents,
        retained_cents: settlement.retained_cents,
        credit_issued_cents: settlement.credit_issued_cents,
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp reduce_cash_payment(operation) do
    with {:ok, payment, group} <- load_target_payment(operation, "payment_not_reducible"),
         :ok <- expected_revision(operation, group),
         {:ok, _occurred_on} <- common_operation(operation),
         :ok <- payment_reducible(payment),
         {:ok, amount_cents} <- usable_amount(field_value(operation, "amount_cents")),
         :ok <- reduction_within(amount_cents, payment.held_cents),
         :ok <- remove_cash_allocations(payment, amount_cents),
         {:ok, _updated_payment} <-
           update_payment(payment, %{
             held_cents: payment.held_cents - amount_cents,
             reduced_cents: payment.reduced_cents + amount_cents
           }),
         {:ok, updated_group} <-
           update_group(group, %{
             deposit_paid_cents: max(group.deposit_paid_cents - amount_cents, 0),
             cash_paid_cents: max(group.cash_paid_cents - amount_cents, 0),
             cash_reduced_cents: group.cash_reduced_cents + amount_cents,
             revision: group.revision + 1
           }) do
      applied(operation, %{
        payment_operation_id: payment.payment_operation_id,
        group_id: updated_group.group_id,
        amount_cents: amount_cents,
        outstanding_deposit_cents: outstanding_deposit(updated_group),
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp charge_back_payment(operation) do
    with {:ok, payment, group} <- load_target_payment(operation, "payment_not_chargeable"),
         :ok <- expected_revision(operation, group),
         {:ok, _occurred_on} <- common_operation(operation),
         :ok <- payment_chargeable(payment),
         :ok <- remove_cash_allocations(payment, payment.held_cents),
         :ok <- revoke_payment_entitlements(payment.payment_operation_id),
         charged_back_cents <-
           payment.held_cents + payment.refunded_cents + payment.retained_cents +
             payment.converted_to_credit_cents,
         {:ok, _updated_payment} <-
           update_payment(payment, %{
             held_cents: 0,
             refunded_cents: 0,
             retained_cents: 0,
             converted_to_credit_cents: 0,
             charged_back_cents: payment.charged_back_cents + charged_back_cents
           }),
         {:ok, updated_group} <-
           update_group(group, %{
             deposit_paid_cents: max(group.deposit_paid_cents - payment.held_cents, 0),
             cash_paid_cents: max(group.cash_paid_cents - payment.held_cents, 0),
             refunded_cents: max(group.refunded_cents - payment.refunded_cents, 0),
             retained_cents: max(group.retained_cents - payment.retained_cents, 0),
             cash_converted_to_credit_cents:
               max(group.cash_converted_to_credit_cents - payment.converted_to_credit_cents, 0),
             cash_charged_back_cents: group.cash_charged_back_cents + charged_back_cents,
             revision: group.revision + 1
           }) do
      applied(operation, %{
        payment_operation_id: payment.payment_operation_id,
        group_id: updated_group.group_id,
        charged_back_cents: charged_back_cents,
        outstanding_deposit_cents: outstanding_deposit(updated_group),
        revision: updated_group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp existing_group(operation) do
    with :ok <- required_fields(operation, ["group_id"]),
         :ok <- valid_identifiers(operation, ["group_id"]),
         {:ok, group_id} <- field(operation, "group_id") do
      case Repo.get(Group, group_id) do
        nil -> error("group_not_found", %{group_id: group_id})
        group -> {:ok, group}
      end
    end
  end

  defp load_target_payment(operation, invalid_target_code) do
    with :ok <- required_fields(operation, ["payment_operation_id"]),
         :ok <- valid_identifiers(operation, ["payment_operation_id"]),
         {:ok, payment_operation_id} <- field(operation, "payment_operation_id") do
      case Repo.get_by(OperationRecord, operation_id: payment_operation_id) do
        nil ->
          error("operation_not_found")

        %OperationRecord{type: "record_cash_payment"} = record ->
          result = decode_result(record.result_json)

          if result[:status] == "applied" do
            case {Repo.get_by(Payment, payment_operation_id: payment_operation_id),
                  result[:group_id]} do
              {%Payment{} = payment, _group_id} ->
                case Repo.get(Group, payment.group_id) do
                  %Group{} = group -> {:ok, payment, group}
                  nil -> error(invalid_target_code)
                end

              _other ->
                error(invalid_target_code)
            end
          else
            error(invalid_target_code)
          end

        _record ->
          error(invalid_target_code)
      end
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
    end
  end

  defp common_operation(operation) do
    with :ok <- required_fields(operation, @common_fields),
         :ok <- valid_identifiers(operation, ["operation_id"]),
         {:ok, occurred_on} <- parse_date(field_value(operation, "occurred_on")) do
      {:ok, occurred_on}
    end
  end

  defp expected_revision(operation, group) do
    case field(operation, "expected_revision") do
      :missing ->
        :ok

      {:ok, expected} when is_integer(expected) and expected == group.revision ->
        :ok

      {:ok, expected} when is_integer(expected) ->
        error("stale_revision", %{
          group_id: group.group_id,
          expected_revision: expected,
          actual_revision: group.revision
        })

      {:ok, _expected} ->
        error("invalid_operation")
    end
  end

  defp payment_reducible(%Payment{held_cents: held}) when held > 0, do: :ok
  defp payment_reducible(_payment), do: error("payment_not_reducible")

  defp payment_chargeable(%Payment{
         recorded_cents: recorded,
         reduced_cents: reduced,
         charged_back_cents: charged_back
       })
       when reduced < recorded and charged_back == 0,
       do: :ok

  defp payment_chargeable(_payment), do: error("payment_not_chargeable")

  defp reduction_within(amount, held) when amount <= held, do: :ok
  defp reduction_within(_amount, _held), do: error("reduction_exceeds_held_cash")

  defp active_group(%Group{status: "active"}), do: :ok

  defp active_group(%Group{group_id: group_id}),
    do: error("group_not_active", %{group_id: group_id})

  defp usable_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp usable_amount(_amount_cents), do: error("invalid_amount")

  defp within_outstanding(amount_cents, outstanding) when amount_cents <= outstanding, do: :ok
  defp within_outstanding(_amount_cents, _outstanding), do: error("payment_exceeds_outstanding")

  defp outstanding_deposit(%Group{status: "active"} = group) do
    totals = active_totals(group.group_id)
    totals.deposit_due_cents - totals.deposit_paid_cents
  end

  defp outstanding_deposit(%Group{}), do: 0

  defp refund_method(operation) do
    case field(operation, "refund_method") do
      :missing -> {:ok, "cash"}
      {:ok, "cash"} -> {:ok, "cash"}
      {:ok, "hotel_credit"} -> {:ok, "hotel_credit"}
      {:ok, _method} -> error("invalid_operation")
    end
  end

  defp refund_method_available(true, _refund_method), do: :ok
  defp refund_method_available(false, "cash"), do: :ok
  defp refund_method_available(false, "hotel_credit"), do: error("refund_method_not_available")

  defp selected_rooms(group, nil) do
    rooms = active_rooms(group.group_id)
    if rooms == [], do: error("invalid_rooms"), else: {:ok, rooms}
  end

  defp selected_rooms(group, room_ids) when is_list(room_ids) and room_ids != [] do
    valid_ids = Enum.all?(room_ids, &valid_identifier?/1)

    if not valid_ids or length(Enum.uniq(room_ids)) != length(room_ids) do
      error("invalid_rooms")
    else
      selected = Enum.filter(active_rooms(group.group_id), &(&1.room_id in room_ids))
      if length(selected) == length(room_ids), do: {:ok, selected}, else: error("invalid_rooms")
    end
  end

  defp selected_rooms(_group, _room_ids), do: error("invalid_rooms")

  defp settle_selected_rooms(group, rooms, occurred_on, refund_method, operation) do
    room_ids = Enum.map(rooms, & &1.room_id)

    allocations =
      Repo.all(
        from allocation in RoomFunding,
          where: allocation.group_id == ^group.group_id and allocation.room_id in ^room_ids,
          order_by: [asc: allocation.id]
      )

    cash_contributions = cash_contributions(allocations)
    cash_total = Enum.sum(Enum.map(cash_contributions, &elem(&1, 2)))

    credit_total =
      allocations
      |> Enum.filter(&(&1.funding_type == "credit"))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

    refundable = refundable?(group, occurred_on)

    cash_disposition =
      cond do
        refundable and refund_method == "cash" -> :refunded
        refundable and refund_method == "hotel_credit" -> :converted_to_credit
        true -> :retained
      end

    with :ok <- settle_cash_contributions(cash_contributions, cash_disposition),
         :ok <- settle_credit_allocations(allocations, occurred_on, refundable),
         {:ok, credit_issued_cents} <-
           maybe_issue_credit(
             group,
             cash_total,
             cash_contributions,
             occurred_on,
             refund_method,
             refundable,
             operation
           ),
         :ok <- delete_allocations(allocations),
         :ok <- mark_rooms_cancelled(rooms) do
      {:ok,
       %{
         rooms: rooms,
         room_lodging_cents: Enum.sum(Enum.map(rooms, & &1.lodging_total_cents)),
         room_due_cents: Enum.sum(Enum.map(rooms, & &1.deposit_due_cents)),
         cash_cents: cash_total,
         credit_cents: credit_total,
         refunded_cents: if(cash_disposition == :refunded, do: cash_total, else: 0),
         retained_cents: if(cash_disposition == :retained, do: cash_total, else: 0),
         converted_cents: if(cash_disposition == :converted_to_credit, do: cash_total, else: 0),
         credit_issued_cents: credit_issued_cents
       }}
    end
  end

  defp settle_group(group, settlement) do
    new_status = if active_rooms(group.group_id) == [], do: "cancelled", else: "active"

    update_group(group, %{
      status: new_status,
      lodging_total_cents: max(group.lodging_total_cents - settlement.room_lodging_cents, 0),
      deposit_due_cents: max(group.deposit_due_cents - settlement.room_due_cents, 0),
      deposit_paid_cents:
        max(group.deposit_paid_cents - settlement.cash_cents - settlement.credit_cents, 0),
      cash_paid_cents: max(group.cash_paid_cents - settlement.cash_cents, 0),
      credit_paid_cents: max(group.credit_paid_cents - settlement.credit_cents, 0),
      refunded_cents: group.refunded_cents + settlement.refunded_cents,
      retained_cents: group.retained_cents + settlement.retained_cents,
      cash_converted_to_credit_cents:
        group.cash_converted_to_credit_cents + settlement.converted_cents,
      revision: group.revision + 1
    })
  end

  defp cash_contributions(allocations) do
    Enum.reduce(allocations, [], fn allocation, contributions ->
      if allocation.funding_type != "cash" do
        contributions
      else
        key = {allocation.source_type, allocation.source_id}

        case Enum.find_index(contributions, &(elem(&1, 0) == key)) do
          nil ->
            contributions ++ [{key, allocation.source_type, allocation.amount_cents}]

          index ->
            {source_key, source_type, amount} = Enum.at(contributions, index)

            List.replace_at(
              contributions,
              index,
              {source_key, source_type, amount + allocation.amount_cents}
            )
        end
      end
    end)
  end

  defp settle_cash_contributions(contributions, disposition) do
    Enum.reduce_while(contributions, :ok, fn {{_source_type, source_id}, source_type, amount},
                                             :ok ->
      if source_type == "cash_payment" do
        case Repo.get_by(Payment, payment_operation_id: source_id) do
          %Payment{} = payment ->
            attrs =
              %{held_cents: max(payment.held_cents - amount, 0)}
              |> Map.put(
                disposition_field(disposition),
                disposition_amount(payment, disposition) + amount
              )

            case update_payment(payment, attrs) do
              {:ok, _payment} -> {:cont, :ok}
              {:error, code, details} -> {:halt, {:error, code, details}}
            end

          nil ->
            {:halt, error("invalid_operation")}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp disposition_field(:refunded), do: :refunded_cents
  defp disposition_field(:retained), do: :retained_cents
  defp disposition_field(:converted_to_credit), do: :converted_to_credit_cents

  defp disposition_amount(payment, :refunded), do: payment.refunded_cents
  defp disposition_amount(payment, :retained), do: payment.retained_cents
  defp disposition_amount(payment, :converted_to_credit), do: payment.converted_to_credit_cents

  defp settle_credit_allocations(allocations, occurred_on, refundable) do
    allocations
    |> Enum.filter(&(&1.funding_type == "credit" and not is_nil(&1.credit_application_id)))
    |> Enum.reduce_while(:ok, fn allocation, :ok ->
      case Repo.get(CreditApplication, allocation.credit_application_id) do
        %CreditApplication{} = application ->
          amount = min(application.amount_cents, allocation.amount_cents)
          new_amount = application.amount_cents - amount

          with {:ok, _application} <- update_application(application, new_amount),
               :ok <-
                 maybe_restore_credit(application.credit_lot_id, amount, occurred_on, refundable) do
            {:cont, :ok}
          else
            {:error, code, details} -> {:halt, {:error, code, details}}
          end

        nil ->
          {:halt, error("invalid_operation")}
      end
    end)
  end

  defp maybe_restore_credit(_lot_id, _amount, _occurred_on, false), do: :ok

  defp maybe_restore_credit(lot_id, amount, occurred_on, true) do
    case Repo.get(CreditLot, lot_id) do
      %CreditLot{} = lot -> restore_credit_lot(lot, amount, occurred_on)
      nil -> error("invalid_operation")
    end
  end

  defp restore_credit_lot(lot, amount, occurred_on) do
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    remaining_amount = amount - absorbed

    available_amount =
      if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt], do: remaining_amount, else: 0

    case update_credit_lot(lot, %{
           remaining_cents: lot.remaining_cents + available_amount,
           unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
         }) do
      {:ok, _lot} -> :ok
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp maybe_issue_credit(
         _group,
         0,
         _contributions,
         _occurred_on,
         _method,
         _refundable,
         _operation
       ),
       do: {:ok, 0}

  defp maybe_issue_credit(
         group,
         cash_total,
         contributions,
         occurred_on,
         "hotel_credit",
         true,
         operation
       ),
       do: issue_credit_lot(group, cash_total, contributions, occurred_on, operation)

  defp maybe_issue_credit(
         _group,
         _cash_total,
         _contributions,
         _occurred_on,
         _method,
         _refundable,
         _operation
       ),
       do: {:ok, 0}

  defp issue_credit_lot(group, cash_total, contributions, occurred_on, operation) do
    credit_issued_cents = bonus_value(cash_total)

    with {:ok, lot} <-
           insert_credit_lot(%{
             guest_id: group.guest_id,
             source_operation_id: field_value(operation, "operation_id"),
             remaining_cents: credit_issued_cents,
             expires_on: Date.add(occurred_on, 365),
             unrecovered_clawback_cents: 0
           }),
         :ok <- insert_credit_entitlements(lot, contributions) do
      {:ok, credit_issued_cents}
    end
  end

  defp insert_credit_entitlements(lot, contributions) do
    {_, _, result} =
      Enum.reduce(contributions, {0, 0, :ok}, fn
        {{"cash_payment", payment_id}, _type, amount}, {previous_cash, previous_credit, :ok} ->
          current_cash = previous_cash + amount
          current_credit = bonus_value(current_cash)
          entitlement = current_credit - previous_credit

          case insert_credit_entitlement(%{
                 credit_lot_id: lot.id,
                 payment_operation_id: payment_id,
                 entitlement_cents: entitlement,
                 revoked_cents: 0
               }) do
            {:ok, _entitlement} -> {current_cash, current_credit, :ok}
            {:error, code, details} -> {current_cash, current_credit, {:error, code, details}}
          end

        {_other, _type, amount}, {previous_cash, _previous_credit, :ok} ->
          current_cash = previous_cash + amount
          {current_cash, bonus_value(current_cash), :ok}

        {_other, _type, _amount}, state ->
          state
      end)

    result
  end

  defp bonus_value(cash_cents), do: cash_cents + round_percentage(cash_cents, 10)

  defp delete_allocations(allocations) do
    ids = Enum.map(allocations, & &1.id)

    if ids != [],
      do: Repo.delete_all(from allocation in RoomFunding, where: allocation.id in ^ids)

    :ok
  end

  defp mark_rooms_cancelled(rooms) do
    Enum.reduce_while(rooms, :ok, fn room, :ok ->
      case update_room(room, %{status: "cancelled"}) do
        {:ok, _room} -> {:cont, :ok}
        {:error, code, details} -> {:halt, {:error, code, details}}
      end
    end)
  end

  defp active_rooms(group_id) do
    Repo.all(
      from room in Room,
        where: room.group_id == ^group_id and room.status == "active",
        order_by: [asc: room.room_index, asc: room.id]
    )
  end

  defp active_totals(group_id) do
    active_rooms(group_id)
    |> Enum.reduce(
      %{
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0
      },
      fn room, totals ->
        %{
          lodging_total_cents: totals.lodging_total_cents + room.lodging_total_cents,
          deposit_due_cents: totals.deposit_due_cents + room.deposit_due_cents,
          deposit_paid_cents:
            totals.deposit_paid_cents + room.cash_paid_cents + room.credit_paid_cents,
          cash_paid_cents: totals.cash_paid_cents + room.cash_paid_cents,
          credit_paid_cents: totals.credit_paid_cents + room.credit_paid_cents
        }
      end
    )
  end

  defp allocate_funding_to_rooms(
         group,
         funding_type,
         source_type,
         source_id,
         credit_application_id,
         amount_cents
       ) do
    {remaining, result} =
      Enum.reduce_while(active_rooms(group.group_id), {amount_cents, :ok}, fn room,
                                                                              {remaining, :ok} ->
        if remaining == 0 do
          {:halt, {remaining, :ok}}
        else
          capacity =
            max(room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents, 0)

          amount = min(remaining, capacity)

          if amount == 0 do
            {:cont, {remaining, :ok}}
          else
            room_attrs =
              case funding_type do
                "cash" -> %{cash_paid_cents: room.cash_paid_cents + amount}
                "credit" -> %{credit_paid_cents: room.credit_paid_cents + amount}
              end

            with {:ok, _room} <- update_room(room, room_attrs),
                 {:ok, _allocation} <-
                   insert_room_funding(%{
                     group_id: group.group_id,
                     room_id: room.room_id,
                     funding_type: funding_type,
                     source_type: source_type,
                     source_id: source_id,
                     credit_application_id: credit_application_id,
                     amount_cents: amount
                   }) do
              {:cont, {remaining - amount, :ok}}
            else
              {:error, code, details} -> {:halt, {remaining, {:error, code, details}}}
            end
          end
        end
      end)

    case result do
      :ok when remaining == 0 -> :ok
      :ok -> error("invalid_operation")
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp remove_cash_allocations(_payment, 0), do: :ok

  defp remove_cash_allocations(payment, amount_cents) do
    allocations =
      Repo.all(
        from allocation in RoomFunding,
          where:
            allocation.source_type == "cash_payment" and
              allocation.source_id == ^payment.payment_operation_id,
          order_by: [desc: allocation.id]
      )

    {remaining, result} =
      Enum.reduce_while(allocations, {amount_cents, :ok}, fn allocation, {remaining, :ok} ->
        if remaining == 0 do
          {:halt, {remaining, :ok}}
        else
          amount = min(remaining, allocation.amount_cents)
          room = Repo.get_by(Room, group_id: allocation.group_id, room_id: allocation.room_id)

          with %Room{} <- room,
               {:ok, _room} <-
                 update_room(room, %{cash_paid_cents: max(room.cash_paid_cents - amount, 0)}),
               :ok <- update_or_delete_allocation(allocation, amount) do
            {:cont, {remaining - amount, :ok}}
          else
            nil -> {:halt, {remaining, error("invalid_operation")}}
            {:error, code, details} -> {:halt, {remaining, {:error, code, details}}}
          end
        end
      end)

    case result do
      :ok when remaining == 0 -> :ok
      :ok -> error("invalid_operation")
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp update_or_delete_allocation(allocation, amount) when amount == allocation.amount_cents do
    Repo.delete!(allocation)
    :ok
  end

  defp update_or_delete_allocation(allocation, amount) do
    case Repo.update(
           Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount)
         ) do
      {:ok, _allocation} -> :ok
      {:error, changeset} -> error("invalid_operation", %{errors: inspect(changeset.errors)})
    end
  end

  defp revoke_payment_entitlements(payment_operation_id) do
    entitlements =
      Repo.all(
        from entitlement in CreditEntitlement,
          where:
            entitlement.payment_operation_id == ^payment_operation_id and
              entitlement.revoked_cents < entitlement.entitlement_cents,
          order_by: [asc: entitlement.id]
      )

    Enum.reduce_while(entitlements, :ok, fn entitlement, :ok ->
      amount = entitlement.entitlement_cents - entitlement.revoked_cents

      case Repo.get(CreditLot, entitlement.credit_lot_id) do
        %CreditLot{} = lot ->
          available = min(lot.remaining_cents, amount)
          unrecovered = amount - available

          with {:ok, _lot} <-
                 update_credit_lot(lot, %{
                   remaining_cents: lot.remaining_cents - available,
                   unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
                 }),
               {:ok, _entitlement} <-
                 update_credit_entitlement(entitlement, %{
                   revoked_cents: entitlement.entitlement_cents
                 }) do
            {:cont, :ok}
          else
            {:error, code, details} -> {:halt, {:error, code, details}}
          end

        nil ->
          {:halt, error("invalid_operation")}
      end
    end)
  end

  defp insert_payment(group, operation, amount_cents) do
    Payment.changeset(%Payment{}, %{
      payment_operation_id: field_value(operation, "operation_id"),
      group_id: group.group_id,
      recorded_cents: amount_cents,
      held_cents: amount_cents,
      refunded_cents: 0,
      retained_cents: 0,
      converted_to_credit_cents: 0,
      reduced_cents: 0,
      charged_back_cents: 0
    })
    |> Repo.insert()
    |> case do
      {:ok, payment} -> {:ok, payment}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp update_payment(payment, attrs) do
    case Repo.update(Payment.changeset(payment, attrs)) do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp insert_room_funding(attrs) do
    case Repo.insert(RoomFunding.changeset(%RoomFunding{}, attrs)) do
      {:ok, allocation} -> {:ok, allocation}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp insert_credit_lot(attrs) do
    case Repo.insert(CreditLot.changeset(%CreditLot{}, attrs)) do
      {:ok, lot} -> {:ok, lot}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp update_credit_lot(lot, attrs) do
    case Repo.update(CreditLot.changeset(lot, attrs)) do
      {:ok, updated_lot} -> {:ok, updated_lot}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp insert_credit_entitlement(attrs) do
    case Repo.insert(CreditEntitlement.changeset(%CreditEntitlement{}, attrs)) do
      {:ok, entitlement} -> {:ok, entitlement}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp update_credit_entitlement(entitlement, attrs) do
    case Repo.update(CreditEntitlement.changeset(entitlement, attrs)) do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp insert_group(attrs) do
    case Repo.insert(Group.changeset(%Group{}, attrs)) do
      {:ok, group} -> {:ok, group}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp insert_rooms(group_id, rooms) do
    rows = Enum.map(rooms, &Map.put(&1, :group_id, group_id))
    _ = Repo.insert_all(Room, rows)
    :ok
  end

  defp update_group(group, attrs) do
    case Repo.update(Group.changeset(group, attrs)) do
      {:ok, updated_group} -> {:ok, updated_group}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp update_room(room, attrs) do
    case Repo.update(Ecto.Changeset.change(room, attrs)) do
      {:ok, updated_room} -> {:ok, updated_room}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: [asc: room.room_index, asc: room.id]
      )

    totals = active_totals(group.group_id)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: effective_policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_total_cents: room.lodging_total_cents,
            status: room.status,
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
      outstanding_deposit_cents: totals.deposit_due_cents - totals.deposit_paid_cents
    }
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> error("invalid_stay")
    end
  end

  defp parse_date(_value), do: error("invalid_stay")

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: error("invalid_stay")
  end

  defp valid_rate_plan(rate_plan) when rate_plan in ["flexible", "advance_purchase"],
    do: {:ok, rate_plan}

  defp valid_rate_plan(_rate_plan), do: error("invalid_rate_plan")

  defp parse_rooms(rooms, arrival_on, departure_on, rate_plan)
       when is_list(rooms) and rooms != [] do
    nights = Date.diff(departure_on, arrival_on)

    parsed =
      Enum.with_index(rooms)
      |> Enum.reduce_while(
        {:ok, %{rooms: [], room_ids: MapSet.new(), lodging_total_cents: 0, deposit_due_cents: 0}},
        fn
          {room, room_index}, {:ok, totals} when is_map(room) ->
            room_id = field_value(room, "room_id")
            nightly_rate_cents = field_value(room, "nightly_rate_cents")

            cond do
              not valid_identifier?(room_id) ->
                {:halt, error("invalid_rooms")}

              not (is_integer(nightly_rate_cents) and nightly_rate_cents > 0) ->
                {:halt, error("invalid_rooms")}

              MapSet.member?(totals.room_ids, room_id) ->
                {:halt, error("invalid_rooms")}

              true ->
                lodging_cents = nights * nightly_rate_cents

                deposit_cents =
                  case rate_plan do
                    "advance_purchase" -> lodging_cents
                    "flexible" -> round_percentage(lodging_cents, 20)
                  end

                room_attrs = %{
                  room_id: room_id,
                  nightly_rate_cents: nightly_rate_cents,
                  room_index: room_index,
                  lodging_total_cents: lodging_cents,
                  deposit_due_cents: deposit_cents,
                  status: "active",
                  cash_paid_cents: 0,
                  credit_paid_cents: 0
                }

                {:cont,
                 {:ok,
                  %{
                    rooms: [room_attrs | totals.rooms],
                    room_ids: MapSet.put(totals.room_ids, room_id),
                    lodging_total_cents: totals.lodging_total_cents + lodging_cents,
                    deposit_due_cents: totals.deposit_due_cents + deposit_cents
                  }}}
            end

          {_room, _room_index}, _totals ->
            {:halt, error("invalid_rooms")}
        end
      )

    case parsed do
      {:ok, totals} -> {:ok, %{totals | rooms: Enum.reverse(totals.rooms)}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp parse_rooms(_rooms, _arrival_on, _departure_on, _rate_plan), do: error("invalid_rooms")

  defp round_percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp effective_policy_version(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp effective_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

  defp refundable?(group, occurred_on) do
    case effective_policy_version(group) do
      "flex-14" -> Date.diff(group.arrival_on, occurred_on) >= 14
      "flex-30" -> Date.diff(group.arrival_on, occurred_on) >= 30
      "advance-nonrefundable" -> false
    end
  end

  defp refundable_until(%Group{} = group) do
    case effective_policy_version(group) do
      "advance-nonrefundable" -> nil
      "flex-14" -> Date.to_iso8601(Date.add(group.arrival_on, -14))
      "flex-30" -> Date.to_iso8601(Date.add(group.arrival_on, -30))
    end
  end

  defp after_operation_date(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: error("invalid_stay")
  end

  defp apply_credit_to_group(group, amount_cents, occurred_on, operation) do
    lots =
      Repo.all(
        from lot in CreditLot,
          where:
            lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
              lot.expires_on >= ^occurred_on,
          order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount_cents do
      error("insufficient_credit")
    else
      consume_credit_lots(lots, group, amount_cents, operation)
    end
  end

  defp consume_credit_lots(lots, group, amount_cents, operation) do
    {_remaining, result} =
      Enum.reduce_while(lots, {amount_cents, :ok}, fn lot, {remaining, :ok} ->
        if remaining == 0 do
          {:halt, {remaining, :ok}}
        else
          consumed = min(remaining, lot.remaining_cents)

          with {:ok, _updated_lot} <-
                 update_credit_lot(lot, %{remaining_cents: lot.remaining_cents - consumed}),
               {:ok, application} <-
                 insert_credit_application(%{
                   group_id: group.group_id,
                   credit_lot_id: lot.id,
                   amount_cents: consumed,
                   funding_operation_id: field_value(operation, "operation_id")
                 }),
               :ok <-
                 allocate_funding_to_rooms(
                   group,
                   "credit",
                   "credit_application",
                   field_value(operation, "operation_id"),
                   application.id,
                   consumed
                 ) do
            {:cont, {remaining - consumed, :ok}}
          else
            {:error, code, details} -> {:halt, {remaining, {:error, code, details}}}
          end
        end
      end)

    result
  end

  defp insert_credit_application(attrs) do
    case Repo.insert(CreditApplication.changeset(%CreditApplication{}, attrs)) do
      {:ok, application} -> {:ok, application}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp update_application(application, 0), do: Repo.delete(application) |> delete_result()

  defp update_application(application, amount) do
    case Repo.update(Ecto.Changeset.change(application, amount_cents: amount)) do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp delete_result({:ok, _application}), do: {:ok, nil}
  defp delete_result({:error, _changeset}), do: error("invalid_operation")

  defp required_fields(operation, fields) do
    if Enum.all?(fields, &present?(operation, &1)), do: :ok, else: error("invalid_operation")
  end

  defp valid_identifiers(operation, fields) do
    if Enum.all?(fields, &valid_identifier?(field_value(operation, &1))),
      do: :ok,
      else: error("invalid_operation")
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp present?(operation, key) do
    case field(operation, key) do
      {:ok, value} -> not is_nil(value)
      :missing -> false
    end
  end

  defp field(operation, key) when is_map(operation) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(operation, key) -> {:ok, Map.get(operation, key)}
      Map.has_key?(operation, atom_key) -> {:ok, Map.get(operation, atom_key)}
      true -> :missing
    end
  end

  defp field(_operation, _key), do: :missing

  defp field_value(operation, key) do
    case field(operation, key) do
      {:ok, value} -> value
      :missing -> nil
    end
  end

  defp error(code, details \\ %{}), do: {:error, code, details}

  defp applied(operation, details),
    do:
      {:ok,
       Map.merge(
         %{operation_id: field_value(operation, "operation_id"), status: "applied"},
         details
       )}

  defp rejected(operation, code, details \\ %{}),
    do:
      Map.merge(
        %{operation_id: field_value(operation, "operation_id"), status: "rejected", code: code},
        details
      )
end
