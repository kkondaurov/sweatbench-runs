defmodule GroupStay.Operations do
  @moduledoc "Applies partner operations and exposes the resulting group-deposit state."

  import Ecto.Query

  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  def apply_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_), do: {:error, :group_not_found}

  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.deposit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0)
        }
    )
  end

  def serialize_group(group) do
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
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp apply_operation(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    result =
      Repo.transaction(fn ->
        case dispatch(operation) do
          {:ok, result} -> result
          {:error, result} -> Repo.rollback(result)
        end
      end)

    case result do
      {:ok, applied} -> Map.merge(%{operation_id: operation_id, status: "applied"}, applied)
      {:error, rejected} -> Map.merge(%{operation_id: operation_id, status: "rejected"}, rejected)
    end
  end

  defp apply_operation(_),
    do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)
  defp dispatch(%{"type" => "record_cash_payment"} = operation), do: with_group(operation, &pay/3)

  defp dispatch(%{"type" => "reschedule_group"} = operation),
    do: with_group(operation, &reschedule/3)

  defp dispatch(%{"type" => "cancel_group"} = operation), do: with_group(operation, &cancel/3)
  defp dispatch(_), do: reject("invalid_operation")

  defp open_group(operation) do
    with true <-
           required_keys?(
             operation,
             ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         true <- common_valid?(operation),
         {:ok, booked_on} <- date(operation["occurred_on"]),
         true <- valid_identifier?(operation["group_id"]),
         true <- valid_identifier?(operation["guest_id"]),
         true <- valid_identifier?(operation["property_id"]),
         false <- Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]),
         {:ok, arrival_on} <- date(operation["arrival_on"]),
         {:ok, departure_on} <- date(operation["departure_on"]),
         true <- Date.compare(departure_on, arrival_on) == :gt,
         {:ok, rooms} <- rooms(operation["rooms"]),
         true <- operation["rate_plan"] in @rate_plans do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))

      deposit_due =
        case operation["rate_plan"] do
          "flexible" ->
            Enum.sum(Enum.map(rooms, &round_flexible_deposit(&1.nightly_rate_cents * nights)))

          "advance_purchase" ->
            lodging_total
        end

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due
      }

      case Repo.insert(Group.create_changeset(%Group{}, attrs)) do
        {:ok, group} ->
          Enum.each(rooms, fn room ->
            room
            |> Map.put(:group_id, group.id)
            |> then(&Room.changeset(%Room{}, &1))
            |> Repo.insert!()
          end)

          {:ok, %{group_id: group.group_id, deposit_due_cents: deposit_due, revision: 1}}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id),
            do: reject("group_already_exists"),
            else: reject("invalid_operation")
      end
    else
      false -> open_error(operation)
      {:error, :invalid_rooms} -> reject("invalid_rooms")
      {:error, :invalid_date} -> open_error(operation)
    end
  end

  defp open_error(operation) do
    cond do
      not required_keys?(
        operation,
        ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)
      ) ->
        reject("invalid_operation")

      not common_valid?(operation) ->
        reject("invalid_operation")

      not valid_identifier?(operation["group_id"]) ->
        reject("invalid_operation")

      not valid_identifier?(operation["guest_id"]) ->
        reject("invalid_operation")

      not valid_identifier?(operation["property_id"]) ->
        reject("invalid_operation")

      Repo.exists?(from g in Group, where: g.group_id == ^operation["group_id"]) ->
        reject("group_already_exists")

      operation["rate_plan"] not in @rate_plans ->
        reject("invalid_rate_plan")

      not valid_rooms?(operation["rooms"]) ->
        reject("invalid_rooms")

      true ->
        reject("invalid_stay")
    end
  end

  defp with_group(operation, function) do
    with true <- required_keys?(operation, required_fields(operation["type"])),
         true <- common_valid?(operation),
         true <- valid_identifier?(operation["group_id"]),
         %Group{} = group <- Repo.get_by(Group, group_id: operation["group_id"]),
         :ok <- revision_matches(operation, group) do
      function.(operation, group, operation_date(operation))
    else
      false -> reject("invalid_operation")
      nil -> reject("group_not_found", %{group_id: operation["group_id"]})
      {:error, :invalid_date} -> reject("invalid_operation")
      {:error, stale} when is_map(stale) -> {:error, stale}
    end
  end

  defp pay(operation, group, {:ok, _occurred_on}) do
    amount = operation["amount_cents"]

    cond do
      group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      not (is_integer(amount) and amount > 0) ->
        reject("invalid_amount", %{group_id: group.group_id})

      amount > outstanding(group) ->
        reject("payment_exceeds_outstanding", %{group_id: group.group_id})

      true ->
        new_outstanding = outstanding(group) - amount

        {:ok, updated} =
          persist_update(group, %{deposit_paid_cents: group.deposit_paid_cents + amount})

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: new_outstanding,
           revision: updated.revision
         }}
    end
  end

  defp pay(_operation, _group, {:error, :invalid_date}), do: reject("invalid_operation")

  defp reschedule(operation, group, {:ok, occurred_on}) do
    with true <- group.status == "active",
         {:ok, arrival_on} <- date(operation["new_arrival_on"]),
         true <- Date.compare(arrival_on, occurred_on) == :gt do
      departure_on = Date.add(group.departure_on, Date.diff(arrival_on, group.arrival_on))

      {:ok, updated} =
        persist_update(group, %{arrival_on: arrival_on, departure_on: departure_on})

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: Date.to_iso8601(arrival_on),
         new_departure_on: Date.to_iso8601(departure_on),
         revision: updated.revision
       }}
    else
      false when group.status != "active" ->
        reject("group_not_active", %{group_id: group.group_id})

      _ ->
        reject("invalid_stay", %{group_id: group.group_id})
    end
  end

  defp reschedule(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp cancel(_operation, group, {:ok, occurred_on}) do
    if group.status == "active" do
      refundable =
        group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

      refunded = if refundable, do: group.deposit_paid_cents, else: 0
      retained = if refundable, do: 0, else: group.deposit_paid_cents

      {:ok, updated} =
        persist_update(group, %{
          status: "cancelled",
          refunded_cents: refunded,
          retained_cents: retained
        })

      {:ok,
       %{
         group_id: group.group_id,
         refunded_cents: refunded,
         retained_cents: retained,
         revision: updated.revision
       }}
    else
      reject("group_not_active", %{group_id: group.group_id})
    end
  end

  defp cancel(_operation, group, {:error, :invalid_date}),
    do: reject("invalid_operation", %{group_id: group.group_id})

  defp persist_update(group, attrs) do
    group
    |> Group.update_changeset(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update()
  end

  defp revision_matches(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp common_valid?(operation) do
    valid_identifier?(operation["operation_id"]) and
      is_binary(operation["type"]) and
      match?({:ok, _}, date(operation["occurred_on"]))
  end

  defp operation_date(operation), do: date(operation["occurred_on"])

  defp required_fields("record_cash_payment"),
    do: ~w(operation_id type occurred_on group_id amount_cents)

  defp required_fields("reschedule_group"),
    do: ~w(operation_id type occurred_on group_id new_arrival_on)

  defp required_fields("cancel_group"), do: ~w(operation_id type occurred_on group_id)
  defp required_fields(_), do: []

  defp required_keys?(operation, keys), do: Enum.all?(keys, &Map.has_key?(operation, &1))

  defp rooms(value) do
    if valid_rooms?(value) do
      {:ok,
       value
       |> Enum.with_index()
       |> Enum.map(fn {room, position} ->
         %{
           room_id: room["room_id"],
           nightly_rate_cents: room["nightly_rate_cents"],
           position: position
         }
       end)}
    else
      {:error, :invalid_rooms}
    end
  end

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn
      %{"room_id" => room_id, "nightly_rate_cents" => rate} ->
        valid_identifier?(room_id) and is_integer(rate) and rate > 0

      _ ->
        false
    end) and Enum.uniq_by(rooms, & &1["room_id"]) == rooms
  end

  defp valid_rooms?(_), do: false

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp date(_), do: {:error, :invalid_date}

  defp valid_identifier?(value), do: is_binary(value) and value != ""

  defp outstanding(%Group{status: "active"} = group),
    do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  defp outstanding(%Group{}), do: 0
  defp round_flexible_deposit(lodging_cents), do: div(lodging_cents + 2, 5)

  defp reject(code, extra \\ %{}), do: {:error, Map.put(extra, :code, code)}
end
