defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and exposes GroupStay's read models.

  Each operation owns its transaction. That deliberately makes a batch ordered but not atomic:
  a rejected operation cannot leak partial writes, while earlier applied operations remain visible.
  """

  import Ecto.Query

  alias GroupStay.Finance.Ledger
  alias GroupStay.Groups.{Group, Room}
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)
  @max_sqlite_integer 9_223_372_036_854_775_807

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group_view(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def ledger do
    ledger = Repo.get!(Ledger, 1)

    %{
      cash_held_cents: ledger.cash_held_cents,
      cash_refunded_cents: ledger.cash_refunded_cents,
      cash_retained_cents: ledger.cash_retained_cents
    }
  end

  defp process_operation(operation) when is_map(operation) do
    with :ok <- common_shape(operation) do
      case operation["type"] do
        "open_group" -> open_group(operation)
        "record_cash_payment" -> with_group(operation, &record_cash_payment/2)
        "reschedule_group" -> with_group(operation, &reschedule_group/2)
        "cancel_group" -> with_group(operation, &cancel_group/2)
        _unknown -> rejected(operation, "invalid_operation")
      end
    else
      :error -> rejected(operation, "invalid_operation")
    end
  end

  defp process_operation(_operation), do: rejected(%{}, "invalid_operation")

  defp common_shape(operation) do
    if valid_identifier?(operation["operation_id"]) and valid_identifier?(operation["type"]) and
         Map.has_key?(operation, "occurred_on") do
      :ok
    else
      :error
    end
  end

  defp open_group(operation) do
    required = ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if Enum.all?(required, &Map.has_key?(operation, &1)) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      transact(fn -> apply_open_group(operation) end)
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp apply_open_group(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.diff(departure_on, arrival_on) > 0 || {:error, "invalid_stay"},
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         nights = Date.diff(departure_on, arrival_on),
         {lodging_total, deposit_due} <- totals(rooms, nights, operation["rate_plan"]),
         true <-
           (lodging_total <= @max_sqlite_integer and deposit_due <= @max_sqlite_integer) ||
             {:error, "invalid_rooms"},
         attrs = %{
           group_id: operation["group_id"],
           guest_id: operation["guest_id"],
           property_id: operation["property_id"],
           booked_on: booked_on,
           arrival_on: arrival_on,
           departure_on: departure_on,
           rate_plan: operation["rate_plan"],
           status: "active",
           lodging_total_cents: lodging_total,
           deposit_due_cents: deposit_due,
           deposit_paid_cents: 0,
           revision: 1
         },
         {:ok, _group} <- insert_group(attrs),
         {_count, nil} <- insert_rooms(operation["group_id"], rooms) do
      applied(operation, %{
        group_id: operation["group_id"],
        deposit_due_cents: deposit_due,
        revision: 1
      })
    else
      {:error, code} when is_binary(code) -> rollback_rejected(operation, code)
      {:error, _date_error} -> rollback_rejected(operation, "invalid_stay")
    end
  end

  defp with_group(operation, apply_operation) do
    if valid_identifier?(operation["group_id"]) do
      transact(fn ->
        case Repo.get(Group, operation["group_id"]) do
          nil -> rollback_rejected(operation, "group_not_found")
          group -> check_revision_then_apply(operation, group, apply_operation)
        end
      end)
    else
      rejected(operation, "invalid_operation")
    end
  end

  defp check_revision_then_apply(operation, group, apply_operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      Repo.rollback(
        rejected(operation, "stale_revision", %{
          group_id: group.group_id,
          expected_revision: operation["expected_revision"],
          actual_revision: group.revision
        })
      )
    else
      apply_operation.(operation, group)
    end
  end

  defp record_cash_payment(operation, group) do
    cond do
      not Map.has_key?(operation, "amount_cents") ->
        rollback_rejected(operation, "invalid_operation")

      not valid_date?(operation["occurred_on"]) ->
        rollback_rejected(operation, "invalid_operation")

      group.status != "active" ->
        rollback_rejected(operation, "group_not_active")

      not (is_integer(operation["amount_cents"]) and operation["amount_cents"] > 0) ->
        rollback_rejected(operation, "invalid_amount")

      operation["amount_cents"] > outstanding(group) ->
        rollback_rejected(operation, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]
        revision = group.revision + 1

        {1, nil} =
          from(g in Group, where: g.group_id == ^group.group_id)
          |> Repo.update_all(inc: [deposit_paid_cents: amount, revision: 1])

        {1, nil} =
          from(l in Ledger, where: l.id == 1)
          |> Repo.update_all(inc: [cash_held_cents: amount])

        applied(operation, %{
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding(group) - amount,
          revision: revision
        })
    end
  end

  defp reschedule_group(operation, group) do
    cond do
      not Map.has_key?(operation, "new_arrival_on") ->
        rollback_rejected(operation, "invalid_operation")

      group.status != "active" ->
        rollback_rejected(operation, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival} <- parse_date(operation["new_arrival_on"]),
             true <- Date.compare(new_arrival, occurred_on) == :gt || {:error, "invalid_stay"} do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          new_departure = Date.add(new_arrival, stay_length)
          revision = group.revision + 1

          {1, nil} =
            from(g in Group, where: g.group_id == ^group.group_id)
            |> Repo.update_all(
              set: [arrival_on: new_arrival, departure_on: new_departure],
              inc: [revision: 1]
            )

          applied(operation, %{
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(new_arrival),
            new_departure_on: Date.to_iso8601(new_departure),
            revision: revision
          })
        else
          {:error, _reason} -> rollback_rejected(operation, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, group) do
    cond do
      group.status != "active" ->
        rollback_rejected(operation, "group_not_active")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} ->
            paid = group.deposit_paid_cents

            refundable =
              group.rate_plan == "flexible" and Date.diff(group.arrival_on, occurred_on) >= 14

            refunded = if refundable, do: paid, else: 0
            retained = paid - refunded
            revision = group.revision + 1

            {1, nil} =
              from(g in Group, where: g.group_id == ^group.group_id)
              |> Repo.update_all(set: [status: "cancelled"], inc: [revision: 1])

            {1, nil} =
              from(l in Ledger, where: l.id == 1)
              |> Repo.update_all(
                inc: [
                  cash_held_cents: -paid,
                  cash_refunded_cents: refunded,
                  cash_retained_cents: retained
                ]
              )

            applied(operation, %{
              group_id: group.group_id,
              refunded_cents: refunded,
              retained_cents: retained,
              revision: revision
            })

          {:error, _reason} ->
            rollback_rejected(operation, "invalid_operation")
        end
    end
  end

  defp insert_group(attrs) do
    case attrs |> Group.create_changeset() |> Repo.insert() do
      {:ok, group} -> {:ok, group}
      {:error, _changeset} -> {:error, "group_already_exists"}
    end
  end

  defp insert_rooms(group_id, rooms) do
    rows =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        %{
          group_id: group_id,
          position: position,
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"]
        }
      end)

    Repo.insert_all(Room, rows)
  end

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 ->
          true

        _room ->
          false
      end)

    if valid? do
      room_ids = Enum.map(rooms, & &1["room_id"])

      if Enum.uniq(room_ids) == room_ids do
        {:ok, rooms}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp totals(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_total, deposit_total} ->
      lodging = nights * room["nightly_rate_cents"]
      deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
      {lodging_total + lodging, deposit_total + deposit}
    end)
  end

  defp group_view(group) do
    rooms =
      from(r in Room, where: r.group_id == ^group.group_id, order_by: r.position)
      |> Repo.all()
      |> Enum.map(&%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents})

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
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp outstanding(%Group{status: "active"} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  defp outstanding(%Group{}), do: 0

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp valid_date?(value), do: match?({:ok, _date}, parse_date(value))

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, result} -> result
      {:error, result} -> result
    end
  end

  defp rollback_rejected(operation, code), do: Repo.rollback(rejected(operation, code))

  defp rejected(operation, code, extra \\ %{}) do
    Map.merge(
      %{
        operation_id: Map.get(operation, "operation_id"),
        status: "rejected",
        code: code
      },
      extra
    )
  end

  defp applied(operation, fields) do
    Map.merge(%{operation_id: operation["operation_id"], status: "applied"}, fields)
  end

  defp valid_identifier?(value), do: is_binary(value) and value != ""
end
