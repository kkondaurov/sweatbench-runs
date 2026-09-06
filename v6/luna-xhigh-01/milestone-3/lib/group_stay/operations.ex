defmodule GroupStay.Operations do
  import Ecto.Query

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

  @doc """
  Applies a partner batch in order. Each operation gets its own transaction so a
  rejection cannot undo an earlier operation or prevent later operations.
  """
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @doc "Applies one operation and returns the public result map."
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

  @doc "Parses the optional date used by read endpoints."
  def parse_as_of(nil), do: {:ok, Date.utc_today()}

  def parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_date"}
    end
  end

  def parse_as_of(_value), do: {:error, "invalid_date"}

  @doc "Returns the current finance totals, including credit liability."
  def ledger_totals, do: ledger_totals(Date.utc_today())

  def ledger_totals(%Date{} = as_of) do
    cash_totals =
      Repo.all(
        from group in Group,
          select:
            {group.status, group.cash_paid_cents, group.refunded_cents, group.retained_cents,
             group.cash_converted_to_credit_cents}
      )
      |> Enum.reduce(
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0
        },
        fn
          {"active", cash_paid, _refunded, _retained, converted}, totals ->
            %{
              totals
              | cash_held_cents: totals.cash_held_cents + cash_paid,
                cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents + converted
            }

          {_status, _cash_paid, refunded, retained, converted}, totals ->
            %{
              totals
              | cash_refunded_cents: totals.cash_refunded_cents + refunded,
                cash_retained_cents: totals.cash_retained_cents + retained,
                cash_converted_to_credit_cents: totals.cash_converted_to_credit_cents + converted
            }
        end
      )

    Map.put(cash_totals, :credit_liability_cents, credit_liability(as_of))
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

    serialized_lots =
      Enum.map(lots, fn lot ->
        %{
          source_operation_id: lot.source_operation_id,
          remaining_cents: lot.remaining_cents,
          expires_on: Date.to_iso8601(lot.expires_on)
        }
      end)

    {:ok,
     %{
       guest_id: guest_id,
       available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
       lots: serialized_lots
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

    applied_to_active_groups =
      Repo.all(
        from application in CreditApplication,
          join: group in Group,
          on: group.group_id == application.group_id,
          where: group.status == "active",
          select: application.amount_cents
      )
      |> Enum.sum()

    available + applied_to_active_groups
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

  defp canonical_json_term(value) when is_list(value),
    do: Enum.map(value, &canonical_json_term/1)

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
             cash_converted_to_credit_cents: 0
           }),
         :ok <- insert_rooms(group.group_id, room_data.rooms) do
      applied(operation, %{
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      })
    else
      {:error, code, details} -> {:error, code, details}
      :missing -> error("invalid_operation")
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
         :ok <- apply_credit_to_group(group, amount_cents, occurred_on),
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
         {:ok, settlement} <- settle_cancellation(group, occurred_on, refund_method, operation),
         {:ok, updated_group} <-
           update_group(group, %{
             status: "cancelled",
             refunded_cents: settlement.refunded_cents,
             retained_cents: settlement.retained_cents,
             cash_converted_to_credit_cents: settlement.cash_converted_to_credit_cents,
             revision: group.revision + 1
           }) do
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

  defp active_group(%Group{status: "active"}), do: :ok

  defp active_group(%Group{group_id: group_id}),
    do: error("group_not_active", %{group_id: group_id})

  defp usable_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0,
    do: {:ok, amount_cents}

  defp usable_amount(_amount_cents), do: error("invalid_amount")

  defp within_outstanding(amount_cents, outstanding) when amount_cents <= outstanding, do: :ok
  defp within_outstanding(_amount_cents, _outstanding), do: error("payment_exceeds_outstanding")

  defp outstanding_deposit(%Group{
         status: "active",
         deposit_due_cents: due,
         deposit_paid_cents: paid
       }),
       do: due - paid

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

  defp refund_method_available(false, "hotel_credit"),
    do: error("refund_method_not_available")

  defp settle_cancellation(group, occurred_on, refund_method, operation) do
    refundable = refundable?(group, occurred_on)
    applications = credit_applications_for(group.group_id)

    cond do
      refundable and refund_method == "cash" ->
        with :ok <- restore_or_expire_credit(applications, occurred_on),
             :ok <- delete_credit_applications(group.group_id) do
          {:ok,
           %{
             refunded_cents: group.cash_paid_cents,
             retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_issued_cents: 0
           }}
        end

      refundable and refund_method == "hotel_credit" ->
        with :ok <- restore_or_expire_credit(applications, occurred_on),
             :ok <- delete_credit_applications(group.group_id),
             {:ok, credit_issued_cents} <-
               issue_credit_lot(group, group.cash_paid_cents, occurred_on, operation) do
          {:ok,
           %{
             refunded_cents: 0,
             retained_cents: 0,
             cash_converted_to_credit_cents: group.cash_paid_cents,
             credit_issued_cents: credit_issued_cents
           }}
        end

      true ->
        with :ok <- delete_credit_applications(group.group_id) do
          {:ok,
           %{
             refunded_cents: 0,
             retained_cents: group.cash_paid_cents,
             cash_converted_to_credit_cents: 0,
             credit_issued_cents: 0
           }}
        end
    end
  end

  defp credit_applications_for(group_id) do
    Repo.all(
      from application in CreditApplication,
        where: application.group_id == ^group_id,
        order_by: [asc: application.id]
    )
  end

  defp restore_or_expire_credit(applications, occurred_on) do
    Enum.reduce_while(applications, :ok, fn application, :ok ->
      case Repo.get(CreditLot, application.credit_lot_id) do
        %CreditLot{} = lot ->
          if Date.compare(lot.expires_on, occurred_on) in [:eq, :gt] do
            case update_credit_lot(lot, %{
                   remaining_cents: lot.remaining_cents + application.amount_cents
                 }) do
              {:ok, _updated_lot} -> {:cont, :ok}
              {:error, code, details} -> {:halt, {:error, code, details}}
            end
          else
            {:cont, :ok}
          end

        nil ->
          {:halt, error("invalid_operation")}
      end
    end)
  end

  defp delete_credit_applications(group_id) do
    Repo.delete_all(
      from application in CreditApplication, where: application.group_id == ^group_id
    )

    :ok
  end

  defp issue_credit_lot(_group, 0, _occurred_on, _operation), do: {:ok, 0}

  defp issue_credit_lot(group, cash_paid_cents, occurred_on, operation) do
    credit_issued_cents = cash_paid_cents + round_percentage(cash_paid_cents, 10)

    attrs = %{
      guest_id: group.guest_id,
      source_operation_id: field_value(operation, "operation_id"),
      remaining_cents: credit_issued_cents,
      expires_on: Date.add(occurred_on, 365)
    }

    case Repo.insert(CreditLot.changeset(%CreditLot{}, attrs)) do
      {:ok, _lot} -> {:ok, credit_issued_cents}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp apply_credit_to_group(group, amount_cents, occurred_on) do
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
      consume_credit_lots(lots, group.group_id, amount_cents)
    end
  end

  defp consume_credit_lots(lots, group_id, amount_cents) do
    {_remaining, result} =
      Enum.reduce_while(lots, {amount_cents, :ok}, fn lot, {remaining, :ok} ->
        if remaining == 0 do
          {:halt, {remaining, :ok}}
        else
          consumed = min(remaining, lot.remaining_cents)

          with {:ok, _updated_lot} <-
                 update_credit_lot(lot, %{remaining_cents: lot.remaining_cents - consumed}),
               {:ok, _application} <-
                 insert_credit_application(%{
                   group_id: group_id,
                   credit_lot_id: lot.id,
                   amount_cents: consumed
                 }) do
            {:cont, {remaining - consumed, :ok}}
          else
            {:error, code, details} -> {:halt, {remaining, {:error, code, details}}}
          end
        end
      end)

    result
  end

  defp refundable?(group, occurred_on) do
    case effective_policy_version(group) do
      "flex-14" -> Date.diff(group.arrival_on, occurred_on) >= 14
      "flex-30" -> Date.diff(group.arrival_on, occurred_on) >= 30
      "advance-nonrefundable" -> false
    end
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp effective_policy_version(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp effective_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version(rate_plan, booked_on)

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
                  room_index: room_index
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

  defp round_percentage(amount_cents, percentage) do
    div(amount_cents * percentage + 50, 100)
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

  defp update_credit_lot(lot, attrs) do
    case Repo.update(CreditLot.changeset(lot, attrs)) do
      {:ok, updated_lot} -> {:ok, updated_lot}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp insert_credit_application(attrs) do
    case Repo.insert(CreditApplication.changeset(%CreditApplication{}, attrs)) do
      {:ok, application} -> {:ok, application}
      {:error, _changeset} -> error("invalid_operation")
    end
  end

  defp serialize_group(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.room_index
      )

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
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp required_fields(operation, fields) do
    if Enum.all?(fields, fn key -> present?(operation, key) end),
      do: :ok,
      else: error("invalid_operation")
  end

  defp valid_identifiers(operation, fields) do
    if Enum.all?(fields, fn key -> valid_identifier?(field_value(operation, key)) end),
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

  defp error(code, details \\ %{}) do
    {:error, code, details}
  end

  defp applied(operation, details) do
    {:ok,
     Map.merge(
       %{operation_id: field_value(operation, "operation_id"), status: "applied"},
       details
     )}
  end

  defp rejected(operation, code, details \\ %{}) do
    Map.merge(
      %{operation_id: field_value(operation, "operation_id"), status: "rejected", code: code},
      details
    )
  end
end
