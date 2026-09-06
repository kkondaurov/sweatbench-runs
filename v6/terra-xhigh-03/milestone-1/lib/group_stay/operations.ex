defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations and exposes the group's operational read models.

  Each operation is committed in its own transaction so a rejected operation cannot
  affect earlier or later operations in the same partner batch.
  """

  import Ecto.Query

  alias GroupStay.{GroupReservation, GroupRoom, Repo}

  @rate_plans ["flexible", "advance_purchase"]
  @max_conflict_retries 3

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &run_operation/1)
  end

  def fetch_group(group_id) when is_binary(group_id) do
    case find_group(group_id) do
      nil -> :not_found
      group -> {:ok, serialize_group(Repo.preload(group, rooms: rooms_query()))}
    end
  end

  def ledger_totals do
    GroupReservation
    |> group_by([group], group.status)
    |> select([group], {
      group.status,
      coalesce(sum(group.cash_paid_cents), 0),
      coalesce(sum(group.refunded_cents), 0),
      coalesce(sum(group.retained_cents), 0)
    })
    |> Repo.all()
    |> Enum.reduce(empty_ledger(), fn {status, paid, refunded, retained}, totals ->
      totals
      |> put_active_cash(status, paid)
      |> Map.update!("cash_refunded_cents", &(&1 + refunded))
      |> Map.update!("cash_retained_cents", &(&1 + retained))
    end)
  end

  defp run_operation(operation), do: run_operation(operation, @max_conflict_retries)

  defp run_operation(operation, retries_left) do
    case Repo.transaction(fn ->
           case apply_operation(operation) do
             {:applied, result} ->
               result

             {:rejected, result} ->
               Repo.rollback({:result, result})

             {:stale_conflict, group_id, expected_revision} ->
               Repo.rollback({:stale_conflict, group_id, expected_revision})

             :retry ->
               Repo.rollback(:retry)
           end
         end) do
      {:ok, result} ->
        result

      {:error, {:result, result}} ->
        result

      {:error, {:stale_conflict, group_id, expected_revision}} ->
        case find_group(group_id) do
          %GroupReservation{} = group -> stale_revision(operation, group, expected_revision)
          nil -> group_not_found(operation, group_id)
        end

      {:error, :retry} when retries_left > 0 ->
        run_operation(operation, retries_left - 1)

      {:error, :retry} ->
        rejected(operation, "invalid_operation")

      {:error, _reason} ->
        rejected(operation, "invalid_operation")
    end
  end

  defp apply_operation(operation) do
    with {:ok, operation_id} <- operation_id(operation),
         {:ok, type} <- operation_type(operation) do
      case type do
        "open_group" -> open_group(operation, operation_id)
        "record_cash_payment" -> record_cash_payment(operation, operation_id)
        "reschedule_group" -> reschedule_group(operation, operation_id)
        "cancel_group" -> cancel_group(operation, operation_id)
        _ -> {:rejected, rejected(operation, "invalid_operation")}
      end
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         nil <- find_group(group_id),
         {:ok, booked_on} <- date_field(operation, "occurred_on"),
         {:ok, guest_id} <- string_field(operation, "guest_id"),
         {:ok, property_id} <- string_field(operation, "property_id"),
         {:ok, rate_plan} <- rate_plan(operation),
         {:ok, arrival_on} <- date_field(operation, "arrival_on"),
         {:ok, departure_on} <- date_field(operation, "departure_on"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rooms} <- rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)

      calculated_rooms =
        Enum.map(rooms, fn room ->
          lodging_cents = nights * room.nightly_rate_cents

          deposit_cents =
            case rate_plan do
              "flexible" -> round_percent(lodging_cents, 20)
              "advance_purchase" -> lodging_cents
            end

          Map.merge(room, %{lodging_cents: lodging_cents, deposit_cents: deposit_cents})
        end)

      attrs = %{
        group_id: group_id,
        guest_id: guest_id,
        property_id: property_id,
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        status: "active",
        lodging_total_cents: Enum.sum(Enum.map(calculated_rooms, & &1.lodging_cents)),
        deposit_due_cents: Enum.sum(Enum.map(calculated_rooms, & &1.deposit_cents)),
        cash_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        revision: 1
      }

      case Repo.insert(GroupReservation.create_changeset(%GroupReservation{}, attrs)) do
        {:ok, group} ->
          insert_rooms!(group, calculated_rooms)

          {:applied,
           applied(operation_id, %{
             "group_id" => group.group_id,
             "deposit_due_cents" => group.deposit_due_cents,
             "revision" => group.revision
           })}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            {:rejected, rejected(operation, "group_already_exists", %{"group_id" => group_id})}
          else
            {:rejected, rejected(operation, "invalid_operation")}
          end
      end
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      %GroupReservation{} ->
        {:rejected,
         rejected(operation, "group_already_exists", %{"group_id" => operation["group_id"]})}

      {:error, "invalid_rate_plan"} ->
        {:rejected, rejected(operation, "invalid_rate_plan")}

      {:error, "invalid_stay"} ->
        {:rejected, rejected(operation, "invalid_stay")}

      {:error, "invalid_rooms"} ->
        {:rejected, rejected(operation, "invalid_rooms")}
    end
  end

  defp record_cash_payment(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, _occurred_on} <- date_field(operation, "occurred_on"),
         {:ok, amount_cents} <- positive_integer_field(operation, "amount_cents"),
         :ok <- active(group),
         :ok <- amount_within_outstanding(amount_cents, group) do
      case update_group(group, %{cash_paid_cents: group.cash_paid_cents + amount_cents}) do
        :ok ->
          {:applied,
           applied(operation_id, %{
             "group_id" => group.group_id,
             "amount_cents" => amount_cents,
             "outstanding_deposit_cents" => outstanding_deposit(group) - amount_cents,
             "revision" => group.revision + 1
           })}

        :conflict ->
          conflict_result(operation, group)
      end
    else
      :error ->
        {:rejected, rejected(operation, "invalid_operation")}

      nil ->
        {:rejected, group_not_found(operation, operation["group_id"])}

      {:error, result} when is_map(result) ->
        {:rejected, result}

      {:error, "invalid_amount"} ->
        {:rejected, rejected(operation, "invalid_amount")}

      {:error, "group_not_active"} ->
        {:rejected, rejected(operation, "group_not_active")}

      {:error, "payment_exceeds_outstanding"} ->
        {:rejected, rejected(operation, "payment_exceeds_outstanding")}
    end
  end

  defp reschedule_group(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, occurred_on} <- date_field(operation, "occurred_on"),
         {:ok, new_arrival_on} <- date_field(operation, "new_arrival_on"),
         :ok <- new_arrival_after_operation(new_arrival_on, occurred_on),
         :ok <- active(group) do
      new_departure_on = Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on))

      case update_group(group, %{arrival_on: new_arrival_on, departure_on: new_departure_on}) do
        :ok ->
          {:applied,
           applied(operation_id, %{
             "group_id" => group.group_id,
             "new_arrival_on" => Date.to_iso8601(new_arrival_on),
             "new_departure_on" => Date.to_iso8601(new_departure_on),
             "revision" => group.revision + 1
           })}

        :conflict ->
          conflict_result(operation, group)
      end
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
      nil -> {:rejected, group_not_found(operation, operation["group_id"])}
      {:error, result} when is_map(result) -> {:rejected, result}
      {:error, "invalid_stay"} -> {:rejected, rejected(operation, "invalid_stay")}
      {:error, "group_not_active"} -> {:rejected, rejected(operation, "group_not_active")}
    end
  end

  defp cancel_group(operation, operation_id) do
    with {:ok, group_id} <- string_field(operation, "group_id"),
         %GroupReservation{} = group <- find_group(group_id),
         :ok <- revision_matches(operation, group),
         {:ok, occurred_on} <- date_field(operation, "occurred_on"),
         :ok <- active(group) do
      refunded_cents = refundable_cash(group, occurred_on)
      retained_cents = group.cash_paid_cents - refunded_cents

      case update_group(group, %{
             status: "cancelled",
             deposit_due_cents: 0,
             refunded_cents: refunded_cents,
             retained_cents: retained_cents
           }) do
        :ok ->
          {:applied,
           applied(operation_id, %{
             "group_id" => group.group_id,
             "refunded_cents" => refunded_cents,
             "retained_cents" => retained_cents,
             "revision" => group.revision + 1
           })}

        :conflict ->
          conflict_result(operation, group)
      end
    else
      :error -> {:rejected, rejected(operation, "invalid_operation")}
      nil -> {:rejected, group_not_found(operation, operation["group_id"])}
      {:error, result} when is_map(result) -> {:rejected, result}
      {:error, "group_not_active"} -> {:rejected, rejected(operation, "group_not_active")}
    end
  end

  defp conflict_result(operation, group) do
    if Map.has_key?(operation, "expected_revision") do
      {:stale_conflict, group.group_id, operation["expected_revision"]}
    else
      :retry
    end
  end

  defp update_group(group, attrs) do
    updates =
      Map.to_list(attrs) ++
        [
          revision: group.revision + 1,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]

    case Repo.update_all(
           from(group_row in GroupReservation,
             where: group_row.id == ^group.id and group_row.revision == ^group.revision
           ),
           set: updates
         ) do
      {1, _} -> :ok
      {0, _} -> :conflict
    end
  end

  defp find_group(group_id) do
    Repo.one(from group in GroupReservation, where: group.group_id == ^group_id)
  end

  defp rooms_query, do: from(room in GroupRoom, order_by: [asc: room.position])

  defp insert_rooms!(group, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.each(fn {room, position} ->
      Repo.insert!(
        GroupRoom.create_changeset(%GroupRoom{}, %{
          group_reservation_id: group.id,
          position: position,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents
        })
      )
    end)
  end

  defp operation_id(%{"operation_id" => operation_id}) when is_binary(operation_id),
    do: {:ok, operation_id}

  defp operation_id(_operation), do: :error

  defp operation_type(%{"type" => type}) when is_binary(type), do: {:ok, type}
  defp operation_type(_operation), do: :error

  defp string_field(%{} = operation, field) do
    case operation do
      %{^field => value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp string_field(_operation, _field), do: :error

  defp date_field(operation, field) do
    with {:ok, value} <- string_field(operation, field),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp positive_integer_field(%{} = operation, field) do
    case operation do
      %{^field => value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "invalid_amount"}
    end
  end

  defp rate_plan(%{"rate_plan" => rate_plan}) when rate_plan in @rate_plans,
    do: {:ok, rate_plan}

  defp rate_plan(_operation), do: {:error, "invalid_rate_plan"}

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp new_arrival_after_operation(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:error, "invalid_stay"}
  end

  defp rooms(%{"rooms" => rooms}) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.reduce_while({:ok, []}, fn room, {:ok, parsed_rooms} ->
      case room(room) do
        {:ok, parsed_room} -> {:cont, {:ok, [parsed_room | parsed_rooms]}}
        :error -> {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, parsed_rooms} ->
        parsed_rooms = Enum.reverse(parsed_rooms)

        if parsed_rooms |> Enum.map(& &1.room_id) |> Enum.uniq() |> length() ==
             length(parsed_rooms) do
          {:ok, parsed_rooms}
        else
          {:error, "invalid_rooms"}
        end

      error ->
        error
    end
  end

  defp rooms(_operation), do: {:error, "invalid_rooms"}

  defp room(%{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents})
       when is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 do
    {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate_cents}}
  end

  defp room(_room), do: :error

  defp revision_matches(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:error, stale_revision(operation, group, expected_revision)}
    end
  end

  defp active(%GroupReservation{status: "active"}), do: :ok
  defp active(_group), do: {:error, "group_not_active"}

  defp amount_within_outstanding(amount_cents, group) do
    if amount_cents <= outstanding_deposit(group),
      do: :ok,
      else: {:error, "payment_exceeds_outstanding"}
  end

  defp refundable_cash(%GroupReservation{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14, do: group.cash_paid_cents, else: 0
  end

  defp refundable_cash(_group, _occurred_on), do: 0

  defp round_percent(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)

  defp outstanding_deposit(%GroupReservation{status: "cancelled"}), do: 0

  defp outstanding_deposit(group),
    do: max(group.deposit_due_cents - group.cash_paid_cents, 0)

  defp serialize_group(group) do
    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "status" => group.status,
      "rooms" =>
        Enum.map(group.rooms, fn room ->
          %{
            "room_id" => room.room_id,
            "nightly_rate_cents" => room.nightly_rate_cents
          }
        end),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.cash_paid_cents,
      "outstanding_deposit_cents" => outstanding_deposit(group)
    }
  end

  defp empty_ledger do
    %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0
    }
  end

  defp put_active_cash(totals, "active", cash_paid_cents),
    do: Map.update!(totals, "cash_held_cents", &(&1 + cash_paid_cents))

  defp put_active_cash(totals, _status, _cash_paid_cents), do: totals

  defp applied(operation_id, fields) do
    Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)
  end

  defp group_not_found(operation, group_id) do
    rejected(operation, "group_not_found", %{"group_id" => group_id})
  end

  defp stale_revision(operation, group, expected_revision) do
    rejected(operation, "stale_revision", %{
      "group_id" => group.group_id,
      "expected_revision" => expected_revision,
      "actual_revision" => group.revision
    })
  end

  defp rejected(operation, code, fields \\ %{}) do
    operation_id =
      case operation do
        %{"operation_id" => value} when is_binary(value) -> %{"operation_id" => value}
        _ -> %{}
      end

    operation_id
    |> Map.merge(%{"status" => "rejected", "code" => code})
    |> Map.merge(fields)
  end
end
