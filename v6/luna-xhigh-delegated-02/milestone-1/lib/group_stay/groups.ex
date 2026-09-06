defmodule GroupStay.Groups do
  @moduledoc """
  Group reservation operations and deposit accounting.

  Each successful operation changes one persisted group row with an atomic
  database write. Rejected operations perform no writes, while successful
  operations earlier in the same batch remain visible to later operations.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)

  @spec process_batch(list()) :: list(map())
  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  @spec process_operation(map()) :: map()
  def process_operation(operation) when is_map(operation) do
    operation_id = value(operation, "operation_id")

    case value(operation, "type") do
      "open_group" -> open_group(operation, operation_id)
      "record_cash_payment" -> record_cash_payment(operation, operation_id)
      "reschedule_group" -> reschedule_group(operation, operation_id)
      "cancel_group" -> cancel_group(operation, operation_id)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  def process_operation(_operation), do: rejected(nil, "invalid_operation")

  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(group_id) when is_binary(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  def get_group(_group_id), do: nil

  @spec group_json(Group.t()) :: map()
  def group_json(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      rooms: Jason.decode!(group.rooms_json),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  @spec ledger() :: map()
  def ledger do
    Repo.all(from group in Group, select: group)
    |> Enum.reduce(
      %{cash_held_cents: 0, cash_refunded_cents: 0, cash_retained_cents: 0},
      fn group, totals ->
        %{
          cash_held_cents:
            totals.cash_held_cents +
              if(group.status == "active", do: group.deposit_paid_cents, else: 0),
          cash_refunded_cents: totals.cash_refunded_cents + group.cash_refunded_cents,
          cash_retained_cents: totals.cash_retained_cents + group.cash_retained_cents
        }
      end
    )
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
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            %Group{} ->
              {:rejected, rejected(operation_id, "group_already_exists", group_id: group_id)}

            nil ->
              nights = Date.diff(departure_on, arrival_on)
              normalized_rooms = calculate_rooms(rooms, nights, rate_plan)
              lodging_total_cents = Enum.sum(Enum.map(normalized_rooms, & &1.lodging_total_cents))
              deposit_due_cents = Enum.sum(Enum.map(normalized_rooms, & &1.deposit_due_cents))

              attrs = %{
                group_id: group_id,
                guest_id: guest_id,
                property_id: property_id,
                booked_on: occurred_on,
                arrival_on: arrival_on,
                departure_on: departure_on,
                rate_plan: rate_plan,
                rooms_json: Jason.encode!(Enum.map(normalized_rooms, &room_json/1)),
                lodging_total_cents: lodging_total_cents,
                deposit_due_cents: deposit_due_cents,
                deposit_paid_cents: 0,
                cash_refunded_cents: 0,
                cash_retained_cents: 0,
                status: "active",
                revision: 1
              }

              case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
                {:ok, _group} ->
                  {:applied,
                   applied(operation_id,
                     group_id: group_id,
                     deposit_due_cents: deposit_due_cents,
                     revision: 1
                   )}

                {:error, _changeset} ->
                  {:rejected, rejected(operation_id, "group_already_exists", group_id: group_id)}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp record_cash_payment(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              {:rejected, rejected(operation_id, "group_not_found", group_id: group_id)}

            %Group{} = group ->
              case stale_revision(operation, group) do
                :ok ->
                  if group.status != "active" do
                    {:rejected, rejected(operation_id, "group_not_active", group_id: group_id)}
                  else
                    case parse_date(value(operation, "occurred_on")) do
                      {:ok, _occurred_on} ->
                        case usable_amount(value(operation, "amount_cents")) do
                          :error ->
                            {:rejected,
                             rejected(operation_id, "invalid_amount", group_id: group_id)}

                          {:ok, amount_cents} ->
                            outstanding = outstanding_deposit(group)

                            if amount_cents > outstanding do
                              {:rejected,
                               rejected(operation_id, "payment_exceeds_outstanding",
                                 group_id: group_id
                               )}
                            else
                              attrs = %{
                                deposit_paid_cents: group.deposit_paid_cents + amount_cents,
                                revision: group.revision + 1
                              }

                              case update_payment(group, attrs.deposit_paid_cents, attrs.revision) do
                                :ok ->
                                  {:applied,
                                   applied(operation_id,
                                     group_id: group_id,
                                     amount_cents: amount_cents,
                                     outstanding_deposit_cents: outstanding - amount_cents,
                                     revision: group.revision + 1
                                   )}

                                :conflict when retries > 0 ->
                                  record_cash_payment(operation, operation_id, retries - 1)

                                :conflict ->
                                  {:rejected,
                                   rejected(operation_id, "stale_revision",
                                     group_id: group_id,
                                     expected_revision: value(operation, "expected_revision"),
                                     actual_revision: current_revision(group_id)
                                   )}
                              end
                            end
                        end

                      :error ->
                        {:rejected,
                         rejected(operation_id, "invalid_operation", group_id: group_id)}
                    end
                  end

                {:stale, actual_revision} ->
                  {:rejected,
                   rejected(operation_id, "stale_revision",
                     group_id: group_id,
                     expected_revision: value(operation, "expected_revision"),
                     actual_revision: actual_revision
                   )}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp reschedule_group(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              {:rejected, rejected(operation_id, "group_not_found", group_id: group_id)}

            %Group{} = group ->
              case stale_revision(operation, group) do
                :ok ->
                  if group.status != "active" do
                    {:rejected, rejected(operation_id, "group_not_active", group_id: group_id)}
                  else
                    case parse_date(value(operation, "new_arrival_on")) do
                      {:ok, new_arrival_on} ->
                        case parse_date(value(operation, "occurred_on")) do
                          {:ok, occurred_on} ->
                            if Date.compare(new_arrival_on, occurred_on) == :gt do
                              stay_length = Date.diff(group.departure_on, group.arrival_on)
                              new_departure_on = Date.add(new_arrival_on, stay_length)
                              revision = group.revision + 1

                              case update_stay(group, new_arrival_on, new_departure_on, revision) do
                                :ok ->
                                  {:applied,
                                   applied(operation_id,
                                     group_id: group_id,
                                     new_arrival_on: Date.to_iso8601(new_arrival_on),
                                     new_departure_on: Date.to_iso8601(new_departure_on),
                                     revision: revision
                                   )}

                                :conflict when retries > 0 ->
                                  reschedule_group(operation, operation_id, retries - 1)

                                :conflict ->
                                  {:rejected,
                                   rejected(operation_id, "stale_revision",
                                     group_id: group_id,
                                     expected_revision: value(operation, "expected_revision"),
                                     actual_revision: current_revision(group_id)
                                   )}
                              end
                            else
                              {:rejected,
                               rejected(operation_id, "invalid_stay", group_id: group_id)}
                            end

                          :error ->
                            {:rejected,
                             rejected(operation_id, "invalid_stay", group_id: group_id)}
                        end

                      :error ->
                        {:rejected, rejected(operation_id, "invalid_stay", group_id: group_id)}
                    end
                  end

                {:stale, actual_revision} ->
                  {:rejected,
                   rejected(operation_id, "stale_revision",
                     group_id: group_id,
                     expected_revision: value(operation, "expected_revision"),
                     actual_revision: actual_revision
                   )}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp cancel_group(operation, operation_id, retries \\ 2) do
    with :ok <- valid_operation_id(operation_id),
         {:ok, group_id} <- required_string(operation, "group_id") do
      run_operation(
        fn ->
          case Repo.get_by(Group, group_id: group_id) do
            nil ->
              {:rejected, rejected(operation_id, "group_not_found", group_id: group_id)}

            %Group{} = group ->
              case stale_revision(operation, group) do
                :ok ->
                  if group.status != "active" do
                    {:rejected, rejected(operation_id, "group_not_active", group_id: group_id)}
                  else
                    case parse_date(value(operation, "occurred_on")) do
                      {:ok, occurred_on} ->
                        refundable? =
                          group.rate_plan == "flexible" and
                            Date.diff(group.arrival_on, occurred_on) >= 14

                        {refunded_cents, retained_cents} =
                          if refundable? do
                            {group.deposit_paid_cents, 0}
                          else
                            {0, group.deposit_paid_cents}
                          end

                        revision = group.revision + 1

                        case update_cancellation(
                               group,
                               refunded_cents,
                               retained_cents,
                               revision
                             ) do
                          :ok ->
                            {:applied,
                             applied(operation_id,
                               group_id: group_id,
                               refunded_cents: refunded_cents,
                               retained_cents: retained_cents,
                               revision: revision
                             )}

                          :conflict when retries > 0 ->
                            cancel_group(operation, operation_id, retries - 1)

                          :conflict ->
                            {:rejected,
                             rejected(operation_id, "stale_revision",
                               group_id: group_id,
                               expected_revision: value(operation, "expected_revision"),
                               actual_revision: current_revision(group_id)
                             )}
                        end

                      :error ->
                        {:rejected,
                         rejected(operation_id, "invalid_operation", group_id: group_id)}
                    end
                  end

                {:stale, actual_revision} ->
                  {:rejected,
                   rejected(operation_id, "stale_revision",
                     group_id: group_id,
                     expected_revision: value(operation, "expected_revision"),
                     actual_revision: actual_revision
                   )}
              end
          end
        end,
        operation_id
      )
    else
      {:error, code} -> rejected(operation_id, code)
    end
  end

  defp calculate_rooms(rooms, nights, rate_plan) do
    Enum.map(rooms, fn room ->
      lodging_total_cents = nights * room.nightly_rate_cents

      deposit_due_cents =
        case rate_plan do
          "flexible" -> round_percentage(lodging_total_cents, 20, 100)
          "advance_purchase" -> lodging_total_cents
        end

      Map.merge(room, %{
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents
      })
    end)
  end

  defp update_payment(%Group{} = group, deposit_paid_cents, revision) do
    query =
      from persisted_group in Group,
        where:
          persisted_group.id == ^group.id and
            persisted_group.revision == ^group.revision,
        update: [set: [deposit_paid_cents: ^deposit_paid_cents, revision: ^revision]]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp update_stay(%Group{} = group, arrival_on, departure_on, revision) do
    query =
      from persisted_group in Group,
        where:
          persisted_group.id == ^group.id and
            persisted_group.revision == ^group.revision,
        update: [set: [arrival_on: ^arrival_on, departure_on: ^departure_on, revision: ^revision]]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp update_cancellation(%Group{} = group, refunded_cents, retained_cents, revision) do
    query =
      from persisted_group in Group,
        where:
          persisted_group.id == ^group.id and
            persisted_group.revision == ^group.revision,
        update: [
          set: [
            cash_refunded_cents: ^refunded_cents,
            cash_retained_cents: ^retained_cents,
            status: "cancelled",
            revision: ^revision
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp current_revision(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{revision: revision} -> revision
      nil -> nil
    end
  end

  defp room_json(room) do
    %{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents
    }
  end

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    result =
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

    case result do
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
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: :error

  defp usable_amount(value), do: positive_integer(value)

  defp valid_operation_id(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp valid_operation_id(_value), do: {:error, "invalid_operation"}

  defp stale_revision(operation, %Group{revision: actual_revision}) do
    if key_present?(operation, "expected_revision") do
      case value(operation, "expected_revision") do
        expected_revision
        when is_integer(expected_revision) and expected_revision == actual_revision ->
          :ok

        _ ->
          {:stale, actual_revision}
      end
    else
      :ok
    end
  end

  defp outstanding_deposit(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding_deposit(%Group{}), do: 0

  defp round_percentage(amount, numerator, denominator) do
    div(amount * numerator * 2 + denominator, denominator * 2)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp value(_map, _key), do: nil

  defp key_present?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))
  end

  defp key_present?(_map, _key), do: false

  defp run_operation(fun, operation_id) do
    case fun.() do
      {status, result} when status in [:applied, :rejected] -> result
      _ -> rejected(operation_id, "invalid_operation")
    end
  rescue
    _ -> rejected(operation_id, "invalid_operation")
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, Map.new(fields))
  end

  defp rejected(operation_id, code, fields \\ []) do
    Map.merge(%{operation_id: operation_id, status: "rejected", code: code}, Map.new(fields))
  end
end
