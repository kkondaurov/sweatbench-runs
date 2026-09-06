defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, Room}

  @rate_plans ["flexible", "advance_purchase"]

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, group_response(group)}
    end
  end

  def ledger do
    %{
      cash_held_cents: sum_for(:deposit_paid_cents, status: "active"),
      cash_refunded_cents: sum_for(:refunded_cents),
      cash_retained_cents: sum_for(:retained_cents)
    }
  end

  defp process_operation(operation) do
    case Repo.transaction(fn ->
           result = apply_operation(operation)

           if result.status == "rejected" do
             Repo.rollback(result)
           else
             result
           end
         end) do
      {:ok, result} -> result
      {:error, %{code: "retry"}} -> process_operation(operation)
      {:error, result} -> result
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp apply_operation(_operation), do: %{status: "rejected", code: "invalid_operation"}

  defp open_group(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <-
           require_keys(
             operation,
             ~w(group_id guest_id property_id occurred_on arrival_on departure_on rate_plan rooms)
           ),
         :ok <- valid_open_identifiers(operation),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- valid_stay(arrival_on, departure_on),
         :ok <- valid_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- valid_rooms(operation["rooms"]),
         :ok <- group_is_new(operation["group_id"]),
         {:ok, group} <- create_group(operation, booked_on, arrival_on, departure_on, rooms) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        deposit_due_cents: group.deposit_due_cents,
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ~w(occurred_on amount_cents)),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- does_not_exceed_outstanding(operation["amount_cents"], group),
         {:ok, group} <-
           update_group(
             group,
             %{deposit_paid_cents: group.deposit_paid_cents + operation["amount_cents"]},
             operation
           ) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp reschedule_group(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ~w(occurred_on new_arrival_on)),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- valid_reschedule(new_arrival_on, occurred_on),
         new_departure_on =
           Date.add(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)),
         {:ok, group} <-
           update_group(
             group,
             %{arrival_on: new_arrival_on, departure_on: new_departure_on},
             operation
           ) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(group.arrival_on),
        new_departure_on: Date.to_iso8601(group.departure_on),
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp cancel_group(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ["occurred_on"]),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {refunded_cents, retained_cents} <- settlement(group, occurred_on),
         {:ok, group} <-
           update_group(
             group,
             %{
               status: "cancelled",
               refunded_cents: refunded_cents,
               retained_cents: retained_cents
             },
             operation
           ) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp common_operation(operation) do
    with :ok <- require_keys(operation, ~w(operation_id type)),
         true <- is_binary(operation["operation_id"]) do
      {:ok, %{operation_id: operation["operation_id"]}}
    else
      _ -> {:rejected, "invalid_operation"}
    end
  end

  defp require_keys(operation, keys) do
    if Enum.all?(keys, &Map.has_key?(operation, &1)) do
      :ok
    else
      {:rejected, "invalid_operation"}
    end
  end

  defp parse_date(value, error_code \\ "invalid_stay")

  defp parse_date(value, error_code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:rejected, error_code}
    end
  end

  defp parse_date(_value, error_code), do: {:rejected, error_code}

  defp valid_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt,
      do: :ok,
      else: {:rejected, "invalid_stay"}
  end

  defp valid_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp valid_rate_plan(_rate_plan), do: {:rejected, "invalid_rate_plan"}

  defp valid_open_identifiers(operation) do
    if Enum.all?(~w(group_id guest_id property_id), &is_binary(operation[&1])) do
      :ok
    else
      {:rejected, "invalid_operation"}
    end
  end

  defp valid_rooms(rooms) when is_list(rooms) and rooms != [] do
    with true <- Enum.all?(rooms, &valid_room?/1),
         room_ids <- Enum.map(rooms, & &1["room_id"]),
         true <- length(room_ids) == length(Enum.uniq(room_ids)) do
      {:ok, rooms}
    else
      _ -> {:rejected, "invalid_rooms"}
    end
  end

  defp valid_rooms(_rooms), do: {:rejected, "invalid_rooms"}

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => nightly_rate_cents}) do
    is_binary(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents >= 0
  end

  defp valid_room?(_room), do: false

  defp group_is_new(group_id) when is_binary(group_id) do
    if Repo.get(Group, group_id), do: {:rejected, "group_already_exists"}, else: :ok
  end

  defp group_is_new(_group_id), do: {:rejected, "invalid_operation"}

  defp create_group(operation, booked_on, arrival_on, departure_on, rooms) do
    nights = Date.diff(departure_on, arrival_on)

    lodging_total_cents =
      Enum.reduce(rooms, 0, fn room, total -> total + nights * room["nightly_rate_cents"] end)

    deposit_due_cents =
      Enum.reduce(rooms, 0, fn room, total ->
        total + room_deposit(room["nightly_rate_cents"], nights, operation["rate_plan"])
      end)

    group = %Group{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0
    }

    with {:ok, group} <- Repo.insert(group),
         :ok <- create_rooms(group.group_id, rooms) do
      {:ok, group}
    else
      {:error, _changeset} -> {:rejected, "group_already_exists"}
      {:rejected, _code} = rejection -> rejection
    end
  end

  defp create_rooms(group_id, rooms) do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {room, position}, :ok ->
      case Repo.insert(%Room{
             group_id: group_id,
             room_id: room["room_id"],
             nightly_rate_cents: room["nightly_rate_cents"],
             position: position
           }) do
        {:ok, _room} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:rejected, "invalid_rooms"}}
      end
    end)
  end

  defp room_deposit(nightly_rate_cents, nights, "flexible") do
    div(nightly_rate_cents * nights + 2, 5)
  end

  defp room_deposit(nightly_rate_cents, nights, "advance_purchase") do
    nightly_rate_cents * nights
  end

  defp fetch_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:rejected, "group_not_found"}
      group -> {:ok, group}
    end
  end

  defp fetch_group(_group_id), do: {:rejected, "invalid_operation"}

  defp check_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:rejected, "stale_revision",
       %{expected_revision: operation["expected_revision"], actual_revision: group.revision}}
    else
      :ok
    end
  end

  defp active_group(%Group{status: "active"}), do: :ok
  defp active_group(_group), do: {:rejected, "group_not_active"}

  defp valid_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0, do: :ok
  defp valid_amount(_amount_cents), do: {:rejected, "invalid_amount"}

  defp does_not_exceed_outstanding(amount_cents, group) do
    if amount_cents <= outstanding_deposit(group),
      do: :ok,
      else: {:rejected, "payment_exceeds_outstanding"}
  end

  defp valid_reschedule(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt,
      do: :ok,
      else: {:rejected, "invalid_stay"}
  end

  defp settlement(%Group{rate_plan: "flexible"} = group, occurred_on) do
    if Date.diff(group.arrival_on, occurred_on) >= 14 do
      {group.deposit_paid_cents, 0}
    else
      {0, group.deposit_paid_cents}
    end
  end

  defp settlement(group, _occurred_on), do: {0, group.deposit_paid_cents}

  defp update_group(group, changes, operation) do
    changes =
      changes
      |> Map.put(:revision, group.revision + 1)
      |> Map.put(:updated_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    query =
      from current_group in Group,
        where:
          current_group.group_id == ^group.group_id and current_group.revision == ^group.revision

    case Repo.update_all(query, set: Map.to_list(changes)) do
      {1, _} ->
        {:ok, Repo.get!(Group, group.group_id)}

      {0, _} ->
        current_group = Repo.get!(Group, group.group_id)

        if Map.has_key?(operation, "expected_revision") do
          {:rejected, "stale_revision",
           %{
             expected_revision: operation["expected_revision"],
             actual_revision: current_group.revision
           }}
        else
          {:rejected, "retry"}
        end
    end
  end

  defp outstanding_deposit(%Group{status: "cancelled"}), do: 0

  defp outstanding_deposit(group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp group_response(group) do
    rooms =
      Room
      |> where([room], room.group_id == ^group.group_id)
      |> order_by([room], asc: room.position)
      |> Repo.all()
      |> Enum.map(fn room ->
        %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
      end)

    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      status: group.status,
      revision: group.revision,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp sum_for(field, filters \\ []) do
    Group
    |> where(^filters)
    |> select([group], coalesce(sum(field(group, ^field)), 0))
    |> Repo.one()
  end

  defp reject(operation, code, details \\ %{}) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id"), else: nil

    %{status: "rejected", code: code}
    |> maybe_put(:operation_id, operation_id)
    |> maybe_put(:group_id, if(is_map(operation), do: Map.get(operation, "group_id"), else: nil))
    |> Map.merge(details)
  end

  defp maybe_put(result, _key, nil), do: result
  defp maybe_put(result, key, value), do: Map.put(result, key, value)
end
