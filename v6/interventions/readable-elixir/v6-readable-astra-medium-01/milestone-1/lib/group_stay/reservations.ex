defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations to group deposit accounts.

  Each operation uses a SQLite immediate transaction, acquiring the writer lock
  before reading the revision. This serializes competing updates and makes the
  revision check and accounting change one atomic operation across processes.
  Ledger totals are derived from the same persisted accounts to avoid a second
  balance that could drift from reservation settlements.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @types ~w(open_group record_cash_payment reschedule_group cancel_group)

  def submit(operations), do: Enum.map(operations, &apply_operation/1)
  def get_group(id), do: Repo.get(Group, id)

  def ledger do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents: coalesce(sum(g.deposit_paid_cents), 0),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0)
        }
    )
  end

  defp apply_operation(operation) do
    {:ok, result} = Repo.transaction(fn -> dispatch(operation) end, mode: :immediate)
    Map.put(result, :operation_id, if(is_map(operation), do: operation["operation_id"]))
  end

  defp dispatch(operation) when is_map(operation) do
    with true <-
           identifier?(operation["operation_id"]) and
             identifier?(operation["group_id"]) and operation["type"] in @types,
         {:ok, occurred_on} <- date(operation["occurred_on"]) do
      if operation["type"] == "open_group" do
        open_group(operation, occurred_on)
      else
        update_group(operation, occurred_on)
      end
    else
      _ -> rejected("invalid_operation")
    end
  end

  defp dispatch(_), do: rejected("invalid_operation")

  defp open_group(op, booked_on) do
    cond do
      not required?(op, ~w(guest_id property_id arrival_on departure_on rate_plan rooms)) ->
        rejected("invalid_operation")

      not identifier?(op["guest_id"]) or not identifier?(op["property_id"]) ->
        rejected("invalid_operation")

      get_group(op["group_id"]) != nil ->
        rejected("group_already_exists")

      true ->
        create_group(op, booked_on)
    end
  end

  defp create_group(op, booked_on) do
    with {:ok, arrival} <- date(op["arrival_on"]),
         {:ok, departure} <- date(op["departure_on"]),
         true <- Date.diff(departure, arrival) > 0 do
      cond do
        not valid_rooms?(op["rooms"]) ->
          rejected("invalid_rooms")

        op["rate_plan"] not in ~w(flexible advance_purchase) ->
          rejected("invalid_rate_plan")

        true ->
          nights = Date.diff(departure, arrival)

          rooms =
            Enum.map(op["rooms"], fn room ->
              %Group.Room{
                room_id: room["room_id"],
                nightly_rate_cents: room["nightly_rate_cents"]
              }
            end)

          lodging = Enum.map(rooms, &(&1.nightly_rate_cents * nights))
          deposit = Enum.sum(Enum.map(lodging, &deposit(&1, op["rate_plan"])))

          group =
            Repo.insert!(%Group{
              group_id: op["group_id"],
              guest_id: op["guest_id"],
              property_id: op["property_id"],
              booked_on: booked_on,
              arrival_on: arrival,
              departure_on: departure,
              rate_plan: op["rate_plan"],
              rooms: rooms,
              lodging_total_cents: Enum.sum(lodging),
              deposit_due_cents: deposit
            })

          applied(group, %{deposit_due_cents: deposit})
      end
    else
      _ -> rejected("invalid_stay")
    end
  end

  defp update_group(op, occurred_on) do
    case get_group(op["group_id"]) do
      nil ->
        rejected("group_not_found")

      group ->
        cond do
          Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
            rejected("stale_revision")
            |> Map.merge(%{
              group_id: group.group_id,
              expected_revision: op["expected_revision"],
              actual_revision: group.revision
            })

          group.status != "active" ->
            rejected("group_not_active")

          true ->
            change_group(group, op, occurred_on)
        end
    end
  end

  defp change_group(group, %{"type" => "record_cash_payment"} = op, _) do
    amount = op["amount_cents"]

    cond do
      not Map.has_key?(op, "amount_cents") ->
        rejected("invalid_operation")

      not is_integer(amount) or amount <= 0 ->
        rejected("invalid_amount")

      amount > Group.outstanding(group) ->
        rejected("payment_exceeds_outstanding")

      true ->
        updated = persist(group, deposit_paid_cents: group.deposit_paid_cents + amount)

        applied(updated, %{
          amount_cents: amount,
          outstanding_deposit_cents: Group.outstanding(updated)
        })
    end
  end

  defp change_group(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    if Map.has_key?(op, "new_arrival_on") do
      with {:ok, arrival} <- date(op["new_arrival_on"]),
           :gt <- Date.compare(arrival, occurred_on) do
        departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
        updated = persist(group, arrival_on: arrival, departure_on: departure)
        applied(updated, %{new_arrival_on: arrival, new_departure_on: departure})
      else
        _ -> rejected("invalid_stay")
      end
    else
      rejected("invalid_operation")
    end
  end

  defp change_group(group, %{"type" => "cancel_group"}, occurred_on) do
    refundable = group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14
    refunded = if refundable, do: group.deposit_paid_cents, else: 0
    retained = group.deposit_paid_cents - refunded

    updated =
      persist(group,
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        refunded_cents: refunded,
        retained_cents: retained
      )

    applied(updated, %{refunded_cents: refunded, retained_cents: retained})
  end

  defp persist(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  # Integer arithmetic rounds each room independently without floating-point loss.
  defp deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp deposit(lodging, "advance_purchase"), do: lodging

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn
      %{"room_id" => id, "nightly_rate_cents" => rate} ->
        identifier?(id) and is_integer(rate) and rate >= 0

      _ ->
        false
    end) and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp required?(op, fields), do: Enum.all?(fields, &Map.has_key?(op, &1))
  defp date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date(_), do: {:error, :invalid_date}
  defp rejected(code), do: %{status: "rejected", code: code}

  defp applied(group, fields),
    do:
      Map.merge(fields, %{status: "applied", group_id: group.group_id, revision: group.revision})
end
