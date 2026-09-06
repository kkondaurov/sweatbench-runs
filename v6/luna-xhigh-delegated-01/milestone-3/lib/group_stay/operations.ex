defmodule GroupStay.Operations do
  @moduledoc "Applies partner operations in order and returns one outcome per operation."

  import Ecto.Query

  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Credit
  alias GroupStay.Ledger
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @flexible "flexible"
  @advance_purchase "advance_purchase"
  @policy_cutover ~D[2027-01-01]
  @max_sqlite_integer 9_223_372_036_854_775_807

  @type result :: map()

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process/1)
  end

  def process(operation) when not is_map(operation) do
    rejected(nil, "invalid_operation")
  end

  def process(operation) do
    operation_id = value(operation, "operation_id")

    if valid_identifier?(operation_id) do
      process_durably(operation, operation_id)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> Jason.decode!(operation.result_json)
    end
  end

  def get_result(_operation_id), do: nil

  defp process_durably(operation, operation_id) do
    payload_json = Jason.encode!(canonical_json(operation))

    with_write_lock(fn ->
      process_durably_with_retries(operation, operation_id, payload_json, 0)
    end)
  end

  defp process_durably_with_retries(operation, operation_id, payload_json, attempt) do
    transaction =
      Repo.transaction(
        fn ->
          case Repo.get_by(Operation, operation_id: operation_id) do
            nil ->
              result = process_uncached(operation, operation_id)
              persist_operation!(operation, operation_id, payload_json, result)
              result

            stored_operation ->
              if stored_operation.payload_json == payload_json do
                Jason.decode!(stored_operation.result_json)
              else
                rejected(operation_id, "operation_id_conflict")
              end
          end
        end,
        mode: :immediate
      )

    case transaction do
      {:ok, result} ->
        result

      {:error, {:retry, _reason}} when attempt < 10 ->
        process_durably_with_retries(operation, operation_id, payload_json, attempt + 1)

      {:error, {:retry, reason}} ->
        raise "unable to apply operation after retries: #{inspect(reason)}"
    end
  end

  defp process_uncached(operation, operation_id) do
    type = value(operation, "type")

    cond do
      type == "open_group" ->
        process_open(operation, operation_id)

      type in ["record_cash_payment", "reschedule_group", "cancel_group", "apply_hotel_credit"] ->
        process_existing_group_operation(operation, operation_id, type)

      true ->
        rejected(operation_id, "invalid_operation")
    end
  end

  defp process_open(operation, operation_id) do
    group_id = value(operation, "group_id")

    if valid_identifier?(group_id) do
      case Repo.get(Group, group_id) do
        %Group{} -> rejected(operation_id, "group_already_exists")
        nil -> apply_open(operation, operation_id, group_id)
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_existing_group_operation(operation, operation_id, type) do
    group_id = value(operation, "group_id")

    if valid_identifier?(group_id) do
      case Repo.get(Group, group_id) do
        nil ->
          rejected(operation_id, "group_not_found", group_id: group_id)

        group ->
          case stale_revision(operation, group) do
            :ok -> apply_existing_group_operation(operation, operation_id, type, group)
            stale -> rejected(operation_id, "stale_revision", stale)
          end
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp apply_open(operation, operation_id, group_id) do
    with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(value(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(value(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         {:ok, rate_plan} <- validate_rate_plan(value(operation, "rate_plan")),
         {:ok, rooms} <- validate_rooms(value(operation, "rooms")) do
      case calculate_totals(rooms, Date.diff(departure_on, arrival_on), rate_plan) do
        {:ok, lodging_total_cents, deposit_due_cents} ->
          guest_id = value(operation, "guest_id")
          property_id = value(operation, "property_id")

          if valid_identifier?(guest_id) and valid_identifier?(property_id) do
            Repo.insert!(%Group{
              group_id: group_id,
              guest_id: guest_id,
              property_id: property_id,
              booked_on: occurred_on,
              arrival_on: arrival_on,
              departure_on: departure_on,
              rate_plan: rate_plan,
              policy_version: policy_version_for(rate_plan, occurred_on),
              status: Groups.active_status(),
              revision: 1,
              lodging_total_cents: lodging_total_cents,
              deposit_due_cents: deposit_due_cents,
              deposit_paid_cents: 0,
              cash_paid_cents: 0,
              credit_paid_cents: 0
            })

            rooms
            |> Enum.with_index()
            |> Enum.each(fn {room, position} ->
              Repo.insert!(%GroupStay.Groups.Room{
                group_id: group_id,
                position: position,
                room_id: room.room_id,
                nightly_rate_cents: room.nightly_rate_cents
              })
            end)

            %{
              operation_id: operation_id,
              status: "applied",
              group_id: group_id,
              deposit_due_cents: deposit_due_cents,
              revision: 1
            }
          else
            rejected(operation_id, "invalid_operation")
          end

        {:error, :invalid_rooms} ->
          rejected(operation_id, "invalid_rooms")
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay")
      {:error, :invalid_rooms} -> rejected(operation_id, "invalid_rooms")
      {:error, :invalid_rate_plan} -> rejected(operation_id, "invalid_rate_plan")
    end
  end

  defp apply_existing_group_operation(operation, operation_id, "record_cash_payment", group) do
    cond do
      not Groups.active?(group) ->
        rejected(operation_id, "group_not_active", group_id: group.group_id)

      true ->
        apply_payment(operation, operation_id, group)
    end
  end

  defp apply_existing_group_operation(operation, operation_id, "reschedule_group", group) do
    cond do
      not Groups.active?(group) ->
        rejected(operation_id, "group_not_active", group_id: group.group_id)

      true ->
        apply_reschedule(operation, operation_id, group)
    end
  end

  defp apply_existing_group_operation(operation, operation_id, "cancel_group", group) do
    cond do
      not Groups.active?(group) ->
        rejected(operation_id, "group_not_active", group_id: group.group_id)

      true ->
        apply_cancellation(operation, operation_id, group)
    end
  end

  defp apply_existing_group_operation(operation, operation_id, "apply_hotel_credit", group) do
    cond do
      not Groups.active?(group) ->
        rejected(operation_id, "group_not_active", group_id: group.group_id)

      true ->
        apply_hotel_credit(operation, operation_id, group)
    end
  end

  defp apply_payment(operation, operation_id, group) do
    with {:ok, _occurred_on} <- parse_date(value(operation, "occurred_on")) do
      amount_cents = value(operation, "amount_cents")

      cond do
        not usable_amount?(amount_cents) ->
          rejected(operation_id, "invalid_amount", group_id: group.group_id)

        amount_cents > outstanding_deposit(group) ->
          rejected(operation_id, "payment_exceeds_outstanding", group_id: group.group_id)

        true ->
          revision = group.revision + 1

          case Ledger.add_cash(amount_cents) do
            :ok ->
              case update_group(group,
                     deposit_paid_cents: group.deposit_paid_cents + amount_cents,
                     cash_paid_cents: Groups.cash_paid(group) + amount_cents,
                     revision: revision
                   ) do
                :ok ->
                  %{
                    operation_id: operation_id,
                    status: "applied",
                    group_id: group.group_id,
                    amount_cents: amount_cents,
                    outstanding_deposit_cents: outstanding_deposit(group) - amount_cents,
                    revision: revision
                  }

                {:retry, reason} ->
                  Repo.rollback({:retry, reason})
              end

            {:error, :overflow} ->
              rejected(operation_id, "invalid_amount", group_id: group.group_id)
          end
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_reschedule(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")),
         {:ok, new_arrival_on} <- parse_date(value(operation, "new_arrival_on")),
         :ok <- validate_reschedule(occurred_on, new_arrival_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)
      revision = group.revision + 1

      case update_group(group,
             arrival_on: new_arrival_on,
             departure_on: new_departure_on,
             revision: revision
           ) do
        :ok ->
          %{
            operation_id: operation_id,
            status: "applied",
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival_on),
            new_departure_on: Date.to_iso8601(new_departure_on),
            policy_version: Groups.policy_version(group),
            refundable_until:
              format_date(Groups.refundable_until(%{group | arrival_on: new_arrival_on})),
            revision: revision
          }

        {:retry, reason} ->
          Repo.rollback({:retry, reason})
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_hotel_credit(operation, operation_id, group) do
    with {:ok, occurred_on} <- parse_date(value(operation, "occurred_on")) do
      amount_cents = value(operation, "amount_cents")

      cond do
        not usable_amount?(amount_cents) ->
          rejected(operation_id, "invalid_amount", group_id: group.group_id)

        amount_cents > outstanding_deposit(group) ->
          rejected(operation_id, "payment_exceeds_outstanding", group_id: group.group_id)

        true ->
          case Ledger.validate_credit_liability(Credit.liability(occurred_on)) do
            :ok ->
              case Credit.consume(group.guest_id, group.group_id, amount_cents, occurred_on) do
                {:error, :insufficient_credit} ->
                  rejected(operation_id, "insufficient_credit", group_id: group.group_id)

                {:ok, :consumed} ->
                  revision = group.revision + 1

                  case update_group(group,
                         deposit_paid_cents: group.deposit_paid_cents + amount_cents,
                         credit_paid_cents: (group.credit_paid_cents || 0) + amount_cents,
                         revision: revision
                       ) do
                    :ok ->
                      case Ledger.refresh_credit_liability(occurred_on) do
                        :ok ->
                          %{
                            operation_id: operation_id,
                            status: "applied",
                            group_id: group.group_id,
                            amount_cents: amount_cents,
                            outstanding_deposit_cents: outstanding_deposit(group) - amount_cents,
                            revision: revision
                          }

                        {:error, :overflow} ->
                          raise "credit liability changed after validation"
                      end

                    {:retry, reason} ->
                      Repo.rollback({:retry, reason})
                  end
              end

            {:error, :overflow} ->
              rejected(operation_id, "invalid_operation", group_id: group.group_id)
          end
      end
    else
      {:error, :invalid_stay} -> rejected(operation_id, "invalid_stay", group_id: group.group_id)
    end
  end

  defp apply_cancellation(operation, operation_id, group) do
    case parse_date(value(operation, "occurred_on")) do
      {:ok, occurred_on} ->
        refund_method = refund_method(operation)

        case validate_refund_method(refund_method) do
          :ok ->
            refundable? = refundable?(group, occurred_on)

            if refund_method == "hotel_credit" and not refundable? do
              rejected(operation_id, "refund_method_not_available", group_id: group.group_id)
            else
              cash_paid_cents = Groups.cash_paid(group)

              {refunded_cents, retained_cents, converted_cents} =
                cancellation_cash_settlement(cash_paid_cents, refund_method, refundable?)

              credit_issued_cents =
                if refundable? and refund_method == "hotel_credit" do
                  credit_amount(cash_paid_cents)
                else
                  {:ok, 0}
                end

              with {:ok, credit_issued_cents} <- credit_issued_cents do
                case validate_cancellation_settlement(
                       group,
                       occurred_on,
                       refundable?,
                       credit_issued_cents,
                       refunded_cents,
                       retained_cents,
                       converted_cents
                     ) do
                  :ok ->
                    case update_group(group,
                           status: Groups.cancelled_status(),
                           deposit_due_cents: 0,
                           revision: group.revision + 1
                         ) do
                      :ok ->
                        with {:ok, _expired_or_consumed_cents} <-
                               Credit.settle_allocations(
                                 group.group_id,
                                 occurred_on,
                                 refundable?
                               ),
                             :ok <-
                               Ledger.settle_cash(
                                 refunded_cents,
                                 retained_cents,
                                 converted_cents
                               ),
                             :ok <-
                               issue_credit(group, operation_id, credit_issued_cents, occurred_on),
                             :ok <- Ledger.refresh_credit_liability(occurred_on) do
                          %{
                            operation_id: operation_id,
                            status: "applied",
                            group_id: group.group_id,
                            refunded_cents: refunded_cents,
                            retained_cents: retained_cents,
                            credit_issued_cents: credit_issued_cents,
                            revision: group.revision + 1
                          }
                        else
                          {:error, :overflow} ->
                            raise "cancellation settlement changed after validation"
                        end

                      {:retry, reason} ->
                        Repo.rollback({:retry, reason})
                    end

                  {:error, :overflow} ->
                    rejected(operation_id, "invalid_operation", group_id: group.group_id)
                end
              else
                {:error, :overflow} ->
                  rejected(operation_id, "invalid_operation", group_id: group.group_id)
              end
            end

          {:error, :invalid_refund_method} ->
            rejected(operation_id, "invalid_refund_method", group_id: group.group_id)
        end

      {:error, :invalid_stay} ->
        rejected(operation_id, "invalid_stay", group_id: group.group_id)
    end
  end

  defp validate_cancellation_settlement(
         group,
         occurred_on,
         refundable?,
         credit_issued_cents,
         refunded_cents,
         retained_cents,
         converted_cents
       ) do
    with :ok <- Ledger.validate_cash_settlement(refunded_cents, retained_cents, converted_cents),
         :ok <-
           Credit.liability_after_cancellation(
             group.group_id,
             occurred_on,
             refundable?,
             credit_issued_cents
           )
           |> Ledger.validate_credit_liability() do
      :ok
    end
  end

  defp issue_credit(_group, _operation_id, 0, _occurred_on), do: :ok

  defp issue_credit(group, operation_id, amount_cents, occurred_on) do
    Credit.issue(group.guest_id, operation_id, amount_cents, Date.add(occurred_on, 366))
    :ok
  end

  defp credit_amount(0), do: {:ok, 0}

  defp credit_amount(cash_paid_cents) do
    bonus_cents = round_percentage(cash_paid_cents, 10, 100)
    safe_add(cash_paid_cents, bonus_cents)
  end

  defp cancellation_cash_settlement(cash_paid_cents, "cash", true),
    do: {cash_paid_cents, 0, 0}

  defp cancellation_cash_settlement(cash_paid_cents, "hotel_credit", true),
    do: {0, 0, cash_paid_cents}

  defp cancellation_cash_settlement(cash_paid_cents, _refund_method, false),
    do: {0, cash_paid_cents, 0}

  defp refundable?(group, occurred_on) do
    case Groups.refundable_until(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp refund_method(operation) do
    case fetch(operation, "refund_method") do
      :missing -> "cash"
      value -> value
    end
  end

  defp validate_refund_method(method) when method in ["cash", "hotel_credit"], do: :ok
  defp validate_refund_method(_method), do: {:error, :invalid_refund_method}

  defp stale_revision(operation, group) do
    case fetch(operation, "expected_revision") do
      :missing ->
        :ok

      expected_revision when expected_revision == group.revision ->
        :ok

      expected_revision ->
        [
          group_id: group.group_id,
          expected_revision: expected_revision,
          actual_revision: group.revision
        ]
    end
  end

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_stay(_, _), do: {:error, :invalid_stay}

  defp validate_reschedule(%Date{} = occurred_on, %Date{} = new_arrival_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_reschedule(_, _), do: {:error, :invalid_stay}

  defp validate_rate_plan(rate_plan) when rate_plan in [@flexible, @advance_purchase],
    do: {:ok, rate_plan}

  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &is_map/1) do
      room_values =
        Enum.map(
          rooms,
          fn room ->
            {value(room, "room_id"), value(room, "nightly_rate_cents")}
          end
        )

      room_ids = Enum.map(room_values, &elem(&1, 0))

      if Enum.all?(room_values, fn {room_id, rate} ->
           valid_identifier?(room_id) and usable_amount?(rate)
         end) and
           length(room_ids) == length(Enum.uniq(room_ids)) do
        {:ok,
         Enum.map(room_values, fn {room_id, nightly_rate_cents} ->
           %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}
         end)}
      else
        {:error, :invalid_rooms}
      end
    else
      {:error, :invalid_rooms}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp calculate_totals(rooms, nights, rate_plan) do
    Enum.reduce_while(rooms, {:ok, 0, 0}, fn room, {:ok, lodging_total, deposit_total} ->
      with {:ok, lodging_amount} <- safe_multiply(room.nightly_rate_cents, nights),
           deposit_amount <- deposit_amount(lodging_amount, rate_plan),
           {:ok, next_lodging_total} <- safe_add(lodging_total, lodging_amount),
           {:ok, next_deposit_total} <- safe_add(deposit_total, deposit_amount) do
        {:cont, {:ok, next_lodging_total, next_deposit_total}}
      else
        {:error, :overflow} -> {:halt, {:error, :invalid_rooms}}
      end
    end)
  end

  defp deposit_amount(lodging_amount, @flexible), do: round_percentage(lodging_amount, 20, 100)
  defp deposit_amount(lodging_amount, @advance_purchase), do: lodging_amount

  defp round_percentage(amount, numerator, denominator) do
    div(amount * numerator + div(denominator, 2), denominator)
  end

  defp outstanding_deposit(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp usable_amount?(amount),
    do: is_integer(amount) and amount > 0 and amount <= @max_sqlite_integer

  defp valid_identifier?(identifier), do: is_binary(identifier) and byte_size(identifier) > 0

  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_stay}
    end
  end

  defp parse_date(_date), do: {:error, :invalid_stay}

  defp policy_version_for(@advance_purchase, _booked_on), do: "advance-nonrefundable"

  defp policy_version_for(@flexible, booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)

  defp safe_multiply(left, right) do
    result = left * right
    if result <= @max_sqlite_integer, do: {:ok, result}, else: {:error, :overflow}
  end

  defp safe_add(left, right) do
    result = left + right
    if result <= @max_sqlite_integer, do: {:ok, result}, else: {:error, :overflow}
  end

  defp update_group(group, attrs) do
    query =
      from current in Group,
        where: current.group_id == ^group.group_id and current.revision == ^group.revision

    case Repo.update_all(query, set: attrs) do
      {1, _} -> :ok
      {0, _} -> {:retry, :concurrent_update}
    end
  end

  defp persist_operation!(operation, operation_id, payload_json, result) do
    operation_type = value(operation, "type")

    Repo.insert!(%Operation{
      operation_id: operation_id,
      type: stored_type(operation_type),
      payload_json: payload_json,
      result_json: Jason.encode!(canonical_json(result))
    })
  end

  defp stored_type(nil), do: nil
  defp stored_type(type) when is_binary(type), do: type
  defp stored_type(type), do: Jason.encode!(canonical_json(type))

  defp canonical_json(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {if(is_binary(key), do: key, else: to_string(key)), canonical_json(nested_value)}
    end)
  end

  defp canonical_json(value) when is_list(value), do: Enum.map(value, &canonical_json/1)
  defp canonical_json(value), do: value

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp value(_map, _key), do: nil

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> :missing
    end
  end

  defp rejected(operation_id, code, extra \\ []) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(extra))
  end

  defp with_write_lock(fun), do: :global.trans({GroupStay, :write_lock}, fun)
end
