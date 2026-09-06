defmodule GroupStay.Operations do
  @moduledoc false

  alias GroupStay.Accounting
  alias GroupStay.Credit
  alias GroupStay.Groups
  alias GroupStay.Operations.Operation
  alias GroupStay.Policies
  alias GroupStay.Repo

  @operation_types ~w(
    open_group
    record_cash_payment
    reschedule_group
    cancel_group
    cancel_rooms
    apply_hotel_credit
    reduce_cash_payment
    charge_back_payment
    transfer_deposit
  )
  @rate_plans ~w(flexible advance_purchase)
  @refund_methods ~w(cash hotel_credit)

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def apply_operation(operation) when not is_map(operation) do
    reject(operation, "invalid_operation")
  end

  def apply_operation(%{"operation_id" => operation_id} = operation)
      when is_binary(operation_id) do
    apply_idempotent(operation, operation_id)
  end

  def apply_operation(%{} = operation) do
    run(operation)
  end

  @doc "Returns the stored result for an operation identifier, or nil."
  def get_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      record -> Jason.decode!(record.result)
    end
  end

  defp apply_idempotent(operation, operation_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(Operation, operation_id: operation_id) do
             nil ->
               result = run(operation)
               remember(operation, operation_id, result)
               result

             record ->
               if content_json(operation) == record.content do
                 Jason.decode!(record.result)
               else
                 reject(operation, "operation_id_conflict")
               end
           end
         end) do
      {:ok, result} ->
        result

      {:error, %{__exception__: true} = exception} ->
        raise exception

      {:error, reason} ->
        raise "unexpected operation failure: #{inspect(reason)}"
    end
  end

  defp remember(operation, operation_id, result) do
    Repo.insert!(%Operation{
      operation_id: operation_id,
      type: operation_type(operation),
      content: content_json(operation),
      result: Jason.encode!(result)
    })
  end

  defp operation_type(operation) do
    case operation["type"] do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp run(operation) do
    case prepare(operation) do
      {:ok, _} -> dispatch(operation)
      {:error, code} -> reject(operation, code)
    end
  end

  def deposit_for_room(nights, nightly_rate_cents, rate_plan) do
    Accounting.room_deposit(nights, nightly_rate_cents, rate_plan)
  end

  def round_cents_half_up(numer, denom) do
    Accounting.round_cents_half_up(numer, denom)
  end

  defp prepare(operation) do
    case operation["type"] do
      type when type in @operation_types ->
        with :ok <- require_string(operation, "operation_id"),
             :ok <- require_date_string(operation, "occurred_on"),
             :ok <- require_typed(type, operation) do
          {:ok, operation}
        else
          _ -> {:error, "invalid_operation"}
        end

      _ ->
        {:error, "invalid_operation"}
    end
  end

  defp require_string(operation, key) do
    if is_binary(operation[key]), do: :ok, else: :error
  end

  defp require_date_string(operation, key) do
    with true <- is_binary(operation[key]) do
      case Date.from_iso8601(operation[key]) do
        {:ok, _date} -> :ok
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp require_typed("open_group", operation) do
    with :ok <- require_string(operation, "group_id"),
         :ok <- require_string(operation, "guest_id"),
         :ok <- require_string(operation, "property_id"),
         :ok <- require_string(operation, "arrival_on"),
         :ok <- require_string(operation, "departure_on"),
         :ok <- require_string(operation, "rate_plan"),
         true <- is_list(operation["rooms"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("record_cash_payment", operation) do
    with :ok <- require_string(operation, "group_id"),
         true <- is_integer(operation["amount_cents"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("reschedule_group", operation) do
    with :ok <- require_string(operation, "group_id"),
         :ok <- require_string(operation, "new_arrival_on") do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("cancel_group", operation) do
    with :ok <- require_string(operation, "group_id"),
         :ok <- require_optional_refund_method(operation) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("cancel_rooms", operation) do
    with :ok <- require_string(operation, "group_id"),
         true <- is_list(operation["room_ids"]),
         :ok <- require_optional_refund_method(operation) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("apply_hotel_credit", operation) do
    with :ok <- require_string(operation, "group_id"),
         true <- is_integer(operation["amount_cents"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("reduce_cash_payment", operation) do
    with :ok <- require_string(operation, "payment_operation_id"),
         true <- is_integer(operation["amount_cents"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("charge_back_payment", operation) do
    with :ok <- require_string(operation, "payment_operation_id") do
      :ok
    else
      _ -> :error
    end
  end

  defp require_typed("transfer_deposit", operation) do
    with :ok <- require_string(operation, "source_group_id"),
         :ok <- require_string(operation, "destination_group_id"),
         true <- is_integer(operation["amount_cents"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp require_optional_refund_method(operation) do
    case operation["refund_method"] do
      nil -> :ok
      method when method in @refund_methods -> :ok
      _ -> :error
    end
  end

  defp dispatch(%{"type" => "open_group"} = operation), do: run_open(operation)
  defp dispatch(%{"type" => "record_cash_payment"} = operation), do: run_payment(operation)
  defp dispatch(%{"type" => "reschedule_group"} = operation), do: run_reschedule(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: run_cancel(operation)
  defp dispatch(%{"type" => "cancel_rooms"} = operation), do: run_cancel_rooms(operation)
  defp dispatch(%{"type" => "apply_hotel_credit"} = operation), do: run_credit(operation)

  defp dispatch(%{"type" => "reduce_cash_payment"} = operation),
    do: run_reduce_cash(operation)

  defp dispatch(%{"type" => "charge_back_payment"} = operation),
    do: run_charge_back(operation)

  defp dispatch(%{"type" => "transfer_deposit"} = operation), do: run_transfer(operation)

  defp run_open(operation) do
    with {:ok, arrival} <- parse_date(operation["arrival_on"]),
         {:ok, departure} <- parse_date(operation["departure_on"]),
         {:ok, nights} <- ensure_nights(arrival, departure),
         :ok <- ensure_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      room_attrs =
        Enum.map(rooms, fn room ->
          %{
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents,
            lodging_cents: nights * room.nightly_rate_cents,
            deposit_due_cents:
              deposit_for_room(nights, room.nightly_rate_cents, operation["rate_plan"])
          }
        end)

      lodging = Enum.reduce(room_attrs, 0, &(&2 + &1.lodging_cents))
      deposit = Enum.reduce(room_attrs, 0, &(&2 + &1.deposit_due_cents))

      if Groups.get_group(operation["group_id"]) do
        reject(operation, "group_already_exists")
      else
        group =
          Groups.create_group!(
            %{
              group_id: operation["group_id"],
              guest_id: operation["guest_id"],
              property_id: operation["property_id"],
              status: "active",
              rate_plan: operation["rate_plan"],
              booked_on: parse_date!(operation["occurred_on"]),
              arrival_on: arrival,
              departure_on: departure,
              revision: 1,
              lodging_total_cents: lodging,
              deposit_due_cents: deposit,
              deposit_paid_cents: 0,
              credit_paid_cents: 0,
              refunded_cents: 0,
              retained_cents: 0,
              converted_to_credit_cents: 0
            },
            room_attrs
          )

        accept(operation, %{
          "group_id" => group.group_id,
          "deposit_due_cents" => group.deposit_due_cents,
          "revision" => group.revision
        })
      end
    else
      {:error, code} -> reject(operation, code)
    end
  end

  defp run_payment(operation) do
    group_operation(operation, fn operation, group ->
      cond do
        group.status != "active" ->
          reject(operation, "group_not_active")

        operation["amount_cents"] <= 0 ->
          reject(operation, "invalid_amount")

        operation["amount_cents"] > Accounting.outstanding(group) ->
          reject(operation, "payment_exceeds_outstanding")

        true ->
          amount = operation["amount_cents"]

          Accounting.allocate!(group, [
            %{
              kind: "cash",
              amount_cents: amount,
              source_operation_id: operation["operation_id"],
              lot_id: nil
            }
          ])

          group =
            Groups.update_group!(group,
              deposit_paid_cents: group.deposit_paid_cents + amount,
              revision: group.revision + 1
            )

          accept(operation, %{
            "group_id" => group.group_id,
            "amount_cents" => amount,
            "outstanding_deposit_cents" => Accounting.outstanding(group),
            "revision" => group.revision
          })
      end
    end)
  end

  defp run_reschedule(operation) do
    group_operation(operation, fn operation, group ->
      if group.status != "active" do
        reject(operation, "group_not_active")
      else
        case Date.from_iso8601(operation["new_arrival_on"]) do
          {:ok, new_arrival} -> apply_reschedule(operation, group, new_arrival)
          _ -> reject(operation, "invalid_stay")
        end
      end
    end)
  end

  defp apply_reschedule(operation, group, new_arrival) do
    occurred = parse_date!(operation["occurred_on"])

    if Date.compare(new_arrival, occurred) != :gt do
      reject(operation, "invalid_stay")
    else
      shift = Date.diff(group.departure_on, group.arrival_on)

      try do
        new_departure = Date.add(new_arrival, shift)

        group =
          Groups.update_group!(group,
            arrival_on: new_arrival,
            departure_on: new_departure,
            revision: group.revision + 1
          )

        version = Policies.policy_version(group.rate_plan, group.booked_on)

        accept(operation, %{
          "group_id" => group.group_id,
          "new_arrival_on" => Date.to_iso8601(new_arrival),
          "new_departure_on" => Date.to_iso8601(new_departure),
          "policy_version" => version,
          "refundable_until" => date_iso(Policies.refundable_until(version, group.arrival_on)),
          "revision" => group.revision
        })
      rescue
        _error -> reject(operation, "invalid_stay")
      end
    end
  end

  defp run_cancel(operation) do
    group_operation(operation, fn operation, group ->
      if group.status != "active" do
        reject(operation, "group_not_active")
      else
        occurred = parse_date!(operation["occurred_on"])
        method = refund_method(operation)
        refundable? = refundable?(group, occurred)

        cond do
          method == "hotel_credit" and not refundable? ->
            reject(operation, "refund_method_not_available")

          true ->
            rooms = Enum.filter(group.rooms, &(&1.status == "active"))
            settle(operation, group, rooms, occurred, method, refundable?, :group_cancel)
        end
      end
    end)
  end

  defp run_cancel_rooms(operation) do
    group_operation(operation, fn operation, group ->
      supplied = operation["room_ids"]

      cond do
        group.status != "active" ->
          reject(operation, "group_not_active")

        supplied == [] or not Enum.all?(supplied, &is_binary/1) or
            length(Enum.uniq(supplied)) != length(supplied) ->
          reject(operation, "invalid_rooms")

        true ->
          rooms_by_id = Map.new(group.rooms, &{&1.room_id, &1})
          sought = Enum.map(supplied, &Map.get(rooms_by_id, &1))

          cond do
            Enum.any?(sought, &is_nil/1) ->
              reject(operation, "invalid_rooms")

            Enum.any?(sought, &(&1.status != "active")) ->
              reject(operation, "invalid_rooms")

            true ->
              occurred = parse_date!(operation["occurred_on"])
              method = refund_method(operation)
              refundable? = refundable?(group, occurred)

              if method == "hotel_credit" and not refundable? do
                reject(operation, "refund_method_not_available")
              else
                ids = MapSet.new(supplied)
                rooms = Enum.filter(group.rooms, &MapSet.member?(ids, &1.room_id))
                settle(operation, group, rooms, occurred, method, refundable?, :cancel_rooms)
              end
          end
      end
    end)
  end

  defp settle(operation, group, rooms, occurred, method, refundable?, mode) do
    {refunded, retained, converted, credit_issued} =
      Accounting.settle_rooms!(
        operation["operation_id"],
        group,
        rooms,
        occurred,
        method,
        refundable?
      )

    active_before = Enum.count(group.rooms, &(&1.status == "active"))
    status = if active_before - length(rooms) == 0, do: "cancelled", else: "active"

    group =
      Groups.update_group!(group,
        status: status,
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        converted_to_credit_cents: group.converted_to_credit_cents + converted,
        revision: group.revision + 1
      )

    fields =
      case mode do
        :group_cancel ->
          if method == "hotel_credit" and refundable? do
            %{
              "group_id" => group.group_id,
              "refunded_cents" => refunded,
              "retained_cents" => retained,
              "credit_issued_cents" => credit_issued,
              "revision" => group.revision
            }
          else
            %{
              "group_id" => group.group_id,
              "refunded_cents" => refunded,
              "retained_cents" => retained,
              "revision" => group.revision
            }
          end

        :cancel_rooms ->
          %{
            "group_id" => group.group_id,
            "cancelled_room_ids" => Enum.map(rooms, & &1.room_id),
            "refunded_cents" => refunded,
            "retained_cents" => retained,
            "credit_issued_cents" => credit_issued,
            "revision" => group.revision
          }
      end

    accept(operation, fields)
  end

  defp run_credit(operation) do
    group_operation(operation, fn operation, group ->
      occurred = parse_date!(operation["occurred_on"])
      amount = operation["amount_cents"]

      cond do
        group.status != "active" ->
          reject(operation, "group_not_active")

        amount <= 0 ->
          reject(operation, "invalid_amount")

        amount > Accounting.outstanding(group) ->
          reject(operation, "payment_exceeds_outstanding")

        Credit.available_cents(group.guest_id, occurred) < amount ->
          reject(operation, "insufficient_credit")

        true ->
          {:ok, takes} = Credit.consume!(group, amount, occurred)

          events =
            Enum.map(takes, fn take ->
              %{
                kind: "credit",
                amount_cents: take.amount_cents,
                source_operation_id: operation["operation_id"],
                lot_id: take.lot_id
              }
            end)

          Accounting.allocate!(group, events)

          group =
            Groups.update_group!(group,
              credit_paid_cents: group.credit_paid_cents + amount,
              revision: group.revision + 1
            )

          accept(operation, %{
            "group_id" => group.group_id,
            "amount_cents" => amount,
            "outstanding_deposit_cents" => Accounting.outstanding(group),
            "revision" => group.revision
          })
      end
    end)
  end

  defp run_reduce_cash(operation) do
    payment_operation_id = operation["payment_operation_id"]

    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        reject(operation, "operation_not_found")

      record ->
        content = Jason.decode!(record.content)
        payment? = record.type == "record_cash_payment" and Accounting.applied?(record.result)

        cond do
          not payment? ->
            reject(operation, "payment_not_reducible")

          true ->
            case Groups.get_group(content["group_id"]) do
              nil ->
                reject(operation, "payment_not_reducible")

              group ->
                case check_revision(operation, group) do
                  :ok ->
                    amount = operation["amount_cents"]
                    held = Accounting.cash_held_for_source(payment_operation_id)

                    cond do
                      amount <= 0 ->
                        reject(operation, "invalid_amount")

                      held <= 0 ->
                        reject(operation, "payment_not_reducible")

                      amount > held ->
                        reject(operation, "reduction_exceeds_held_cash")

                      true ->
                        affected = Accounting.reduce_cash!(group, payment_operation_id, amount)

                        group = Groups.update_group!(group, revision: group.revision + 1)
                        Groups.increment_revisions!(affected -- [group.id])

                        accept(operation, %{
                          "payment_operation_id" => payment_operation_id,
                          "group_id" => group.group_id,
                          "amount_cents" => amount,
                          "outstanding_deposit_cents" => Accounting.outstanding(group),
                          "revision" => group.revision
                        })
                    end

                  {:rejected, code, extra} ->
                    reject(operation, code, extra)
                end
            end
        end
    end
  end

  defp run_charge_back(operation) do
    payment_operation_id = operation["payment_operation_id"]

    case Repo.get_by(Operation, operation_id: payment_operation_id) do
      nil ->
        reject(operation, "operation_not_found")

      record ->
        content = Jason.decode!(record.content)
        payment? = record.type == "record_cash_payment" and Accounting.applied?(record.result)

        cond do
          not payment? ->
            reject(operation, "payment_not_chargeable")

          true ->
            case Groups.get_group(content["group_id"]) do
              nil ->
                reject(operation, "payment_not_chargeable")

              group ->
                case check_revision(operation, group) do
                  :ok ->
                    recorded = content["amount_cents"]
                    reduced = Accounting.source_disposition_total(payment_operation_id, "reduced")

                    charged_before =
                      Accounting.source_disposition_total(payment_operation_id, "charged_back")

                    cond do
                      reduced >= recorded ->
                        reject(operation, "payment_not_chargeable")

                      charged_before > 0 ->
                        reject(operation, "payment_not_chargeable")

                      true ->
                        {charged_back, held_group_ids, moved_by_group} =
                          Accounting.charge_back!(group, payment_operation_id)

                        moved_here =
                          Map.get(moved_by_group, group.id, %{
                            "refunded" => 0,
                            "retained" => 0,
                            "converted" => 0
                          })

                        other_ids =
                          (held_group_ids ++ Map.keys(moved_by_group))
                          |> Enum.uniq()
                          |> List.delete(group.id)

                        group =
                          Groups.update_group!(group,
                            revision: group.revision + 1,
                            refunded_cents: group.refunded_cents - moved_here["refunded"],
                            retained_cents: group.retained_cents - moved_here["retained"],
                            converted_to_credit_cents:
                              group.converted_to_credit_cents - moved_here["converted"]
                          )

                        for other_id <- other_ids do
                          moved =
                            Map.get(moved_by_group, other_id, %{
                              "refunded" => 0,
                              "retained" => 0,
                              "converted" => 0
                            })

                          Groups.adjust_settled!(
                            other_id,
                            moved["refunded"],
                            moved["retained"],
                            moved["converted"]
                          )
                        end

                        accept(operation, %{
                          "payment_operation_id" => payment_operation_id,
                          "group_id" => group.group_id,
                          "charged_back_cents" => charged_back,
                          "outstanding_deposit_cents" => Accounting.outstanding(group),
                          "revision" => group.revision
                        })
                    end

                  {:rejected, code, extra} ->
                    reject(operation, code, extra)
                end
            end
        end
    end
  end

  defp run_transfer(operation) do
    amount = operation["amount_cents"]

    case Groups.get_group(operation["source_group_id"]) do
      nil ->
        reject(operation, "group_not_found", %{"group_id" => operation["source_group_id"]})

      source ->
        case Groups.get_group(operation["destination_group_id"]) do
          nil ->
            reject(operation, "group_not_found", %{
              "group_id" => operation["destination_group_id"]
            })

          destination ->
            with :ok <- check_revision_key(operation, "expected_revision", source),
                 :ok <-
                   check_revision_key(operation, "destination_expected_revision", destination) do
              apply_transfer(operation, source, destination, amount)
            else
              {:rejected, code, extra} -> reject(operation, code, extra)
            end
        end
    end
  end

  defp apply_transfer(operation, source, destination, amount) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        reject(operation, "invalid_transfer")

      source.status != "active" ->
        reject(operation, "group_not_active", %{"group_id" => source.group_id})

      destination.status != "active" ->
        reject(operation, "group_not_active", %{"group_id" => destination.group_id})

      amount <= 0 ->
        reject(operation, "invalid_amount")

      amount > Accounting.cash_held(source) + Accounting.credit_held(source) ->
        reject(operation, "transfer_exceeds_held_funding")

      amount > Accounting.outstanding(destination) ->
        reject(operation, "transfer_exceeds_outstanding")

      true ->
        Accounting.transfer!(source, destination, amount)

        source = Groups.update_group!(source, revision: source.revision + 1)
        destination = Groups.update_group!(destination, revision: destination.revision + 1)

        accept(operation, %{
          "source_group_id" => source.group_id,
          "destination_group_id" => destination.group_id,
          "amount_cents" => amount,
          "source_outstanding_deposit_cents" => Accounting.outstanding(source),
          "destination_outstanding_deposit_cents" => Accounting.outstanding(destination),
          "source_revision" => source.revision,
          "destination_revision" => destination.revision
        })
    end
  end

  defp refundable?(group, occurred) do
    version = Policies.policy_version(group.rate_plan, group.booked_on)
    Policies.refundable?(version, group.arrival_on, occurred)
  end

  defp refund_method(operation), do: operation["refund_method"] || "cash"

  defp date_iso(nil), do: nil
  defp date_iso(date), do: Date.to_iso8601(date)

  defp group_operation(operation, fun) do
    case Groups.get_group(operation["group_id"]) do
      nil ->
        reject(operation, "group_not_found")

      group ->
        case check_revision(operation, group) do
          :ok -> fun.(operation, group)
          {:rejected, code, extra} -> reject(operation, code, extra)
        end
    end
  end

  defp check_revision(operation, group),
    do: check_revision_key(operation, "expected_revision", group)

  defp check_revision_key(operation, key, group) do
    case operation[key] do
      nil ->
        :ok

      expected ->
        cond do
          not positive_integer?(expected) ->
            {:rejected, "invalid_operation", %{}}

          expected == group.revision ->
            :ok

          true ->
            {:rejected, "stale_revision",
             %{
               "group_id" => group.group_id,
               "expected_revision" => expected,
               "actual_revision" => group.revision
             }}
        end
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp parse_date!(value) do
    {:ok, date} = Date.from_iso8601(value)
    date
  end

  defp ensure_nights(arrival, departure) do
    case Date.diff(departure, arrival) do
      nights when nights >= 1 -> {:ok, nights}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp ensure_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, "invalid_rate_plan"}
  end

  defp validate_rooms([]), do: {:error, "invalid_rooms"}

  defp validate_rooms(rooms) do
    cond do
      not Enum.all?(rooms, &valid_room?/1) ->
        {:error, "invalid_rooms"}

      not unique_room_ids?(rooms) ->
        {:error, "invalid_rooms"}

      true ->
        {:ok,
         Enum.map(rooms, fn room ->
           %{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
         end)}
    end
  end

  defp valid_room?(room) do
    case room do
      %{"room_id" => room_id, "nightly_rate_cents" => rate}
      when is_binary(room_id) and is_integer(rate) and rate > 0 ->
        true

      _ ->
        false
    end
  end

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1["room_id"])
    length(Enum.uniq(ids)) == length(ids)
  end

  defp accept(operation, fields) do
    %{"status" => "applied"}
    |> put_operation_id(operation)
    |> Map.merge(fields)
  end

  defp reject(operation, code, extra \\ %{}) do
    %{"status" => "rejected", "code" => code}
    |> put_operation_id(operation)
    |> Map.merge(extra)
  end

  defp put_operation_id(result, %{"operation_id" => operation_id}) when is_binary(operation_id) do
    Map.put(result, "operation_id", operation_id)
  end

  defp put_operation_id(result, _operation), do: result

  defp content_json(operation) do
    operation
    |> canonical()
    |> IO.iodata_to_binary()
  end

  defp canonical(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, val} -> [Jason.encode!(to_string(key)), ?:, canonical(val)] end)
      |> Enum.sort()
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp canonical(value) when is_list(value) do
    [?[, value |> Enum.map(&canonical/1) |> Enum.intersperse(?,), ?]]
  end

  defp canonical(value) do
    Jason.encode!(value)
  end
end
