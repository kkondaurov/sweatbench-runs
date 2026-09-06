defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.{CreditApplication, CreditLot, Group, OperationRecord, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)
  @group_operation_fields %{
    "record_cash_payment" => ["operation_id", "type", "occurred_on", "group_id", "amount_cents"],
    "apply_hotel_credit" => ["operation_id", "type", "occurred_on", "group_id", "amount_cents"],
    "reschedule_group" => ["operation_id", "type", "occurred_on", "group_id", "new_arrival_on"],
    "cancel_group" => ["operation_id", "type", "occurred_on", "group_id"]
  }

  def process_batch(operations) do
    Enum.map(operations, &process/1)
  end

  def get_group(id) when is_binary(id) do
    case Repo.get(Group, id) do
      nil -> nil
      group -> Repo.preload(group, :rooms)
    end
  end

  def get_group(_), do: nil

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil -> nil
      record -> record.result
    end
  end

  def get_operation(_), do: nil

  def ledger(on \\ Date.utc_today()) do
    cash =
      Repo.one(
        from g in Group,
          select: %{
            cash_held_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.cash_paid_cents
                  )
                ),
                0
              ),
            cash_refunded_cents: coalesce(sum(g.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
          }
      )

    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on > ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from a in CreditApplication,
          join: g in assoc(a, :group),
          where: g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    Map.put(cash, :credit_liability_cents, available + applied)
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on > ^on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: lot.expires_on
          }
        end)
    }
  end

  def read_date(nil), do: {:ok, Date.utc_today()}

  def read_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  def read_date(_), do: :error

  def refundable_until(group) do
    case group.policy_version || policy_version(group.rate_plan, group.booked_on) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp process(operation) when is_map(operation) do
    operation_id = Map.get(operation, "operation_id")

    if is_binary(operation_id) do
      {:ok, result} =
        Repo.transaction(fn -> process_durable(operation_id, operation) end, mode: :immediate)

      result
    else
      format_result(operation_id, process_new(operation))
    end
  end

  defp process(_), do: format_result(nil, {:rejected, "invalid_operation", %{}})

  defp process_durable(operation_id, operation) do
    case Repo.get_by(OperationRecord, operation_id: operation_id) do
      nil ->
        result = format_result(operation_id, process_new(operation))

        Repo.insert!(%OperationRecord{
          operation_id: operation_id,
          operation_type: if(is_binary(operation["type"]), do: operation["type"]),
          submission: operation,
          result: result
        })

        result

      %OperationRecord{submission: stored, result: result} when stored === operation ->
        result

      %OperationRecord{} ->
        format_result(operation_id, {:rejected, "operation_id_conflict", %{}})
    end
  end

  defp process_new(operation) do
    case Map.get(operation, "type") do
      "open_group" -> open_group(operation)
      type when is_map_key(@group_operation_fields, type) -> apply_to_group(type, operation)
      _ -> {:rejected, "invalid_operation", %{}}
    end
  end

  defp open_group(operation) do
    required =
      ~w(operation_id type occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    with :ok <- require_fields(operation, required),
         :ok <-
           require_nonempty_strings(operation, ~w(operation_id group_id guest_id property_id)),
         {:ok, booked_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay"),
         :ok <- valid_stay(arrival_on, departure_on),
         {:ok, rooms} <- validate_rooms(operation["rooms"]),
         {:ok, rate_plan} <- validate_rate_plan(operation["rate_plan"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = Enum.sum(Enum.map(rooms, &(&1.nightly_rate_cents * nights)))

      deposit_due =
        Enum.sum(
          Enum.map(rooms, fn room ->
            lodging = room.nightly_rate_cents * nights
            if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
          end)
        )

      attrs = %{
        id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: rate_plan,
        policy_version: policy_version(rate_plan, booked_on),
        status: "active",
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        revision: 1
      }

      case insert_group(attrs, rooms) do
        group_id when is_binary(group_id) ->
          {:applied, %{group_id: attrs.id, deposit_due_cents: deposit_due, revision: 1}}

        :already_exists ->
          {:rejected, "group_already_exists", %{}}
      end
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp insert_group(attrs, rooms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    group_row =
      Map.merge(attrs, %{
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        inserted_at: now,
        updated_at: now
      })

    case Repo.insert_all(Group, [group_row], on_conflict: :nothing, conflict_target: [:id]) do
      {1, nil} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        room_rows =
          rooms
          |> Enum.with_index()
          |> Enum.map(fn {room, position} ->
            Map.merge(room, %{
              group_id: attrs.id,
              position: position,
              inserted_at: now,
              updated_at: now
            })
          end)

        {_count, nil} = Repo.insert_all(Room, room_rows)
        attrs.id

      {0, nil} ->
        :already_exists
    end
  end

  defp apply_to_group(type, operation) do
    required = Map.fetch!(@group_operation_fields, type)

    with :ok <- require_fields(operation, required),
         :ok <- require_nonempty_strings(operation, ~w(operation_id group_id)) do
      apply_locked(type, operation)
    else
      {:error, code} -> {:rejected, code, %{}}
    end
  end

  defp apply_locked(type, operation) do
    group = Repo.one(from g in Group, where: g.id == ^operation["group_id"])

    cond do
      is_nil(group) ->
        {:rejected, "group_not_found", %{}}

      stale_revision?(operation, group) ->
        {:rejected, "stale_revision",
         %{
           group_id: group.id,
           expected_revision: operation["expected_revision"],
           actual_revision: group.revision
         }}

      invalid_expected_revision?(operation) ->
        {:rejected, "invalid_operation", %{}}

      group.status != "active" ->
        {:rejected, "group_not_active", %{}}

      true ->
        perform(type, operation, group)
    end
  end

  defp perform("record_cash_payment", operation, group) do
    amount = operation["amount_cents"]
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    cond do
      match?({:error, _}, parse_date(operation["occurred_on"], "invalid_operation")) ->
        {:rejected, "invalid_operation", %{}}

      not is_integer(amount) or amount <= 0 ->
        {:rejected, "invalid_amount", %{}}

      amount > outstanding ->
        {:rejected, "payment_exceeds_outstanding", %{}}

      true ->
        revision = group.revision + 1

        update_group!(group, %{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          cash_paid_cents: group.cash_paid_cents + amount,
          revision: revision
        })

        {:applied,
         %{
           group_id: group.id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding - amount,
           revision: revision
         }}
    end
  end

  defp perform("reschedule_group", operation, group) do
    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_stay"),
         {:ok, new_arrival} <- parse_date(operation["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(new_arrival, occurred_on) == :gt do
      shift = Date.diff(new_arrival, group.arrival_on)
      new_departure = Date.add(group.departure_on, shift)
      revision = group.revision + 1

      update_group!(group, %{
        arrival_on: new_arrival,
        departure_on: new_departure,
        revision: revision
      })

      {:applied,
       %{
         group_id: group.id,
         new_arrival_on: new_arrival,
         new_departure_on: new_departure,
         policy_version: group.policy_version || policy_version(group.rate_plan, group.booked_on),
         refundable_until: refundable_until(%{group | arrival_on: new_arrival}),
         revision: revision
       }}
    else
      _ -> {:rejected, "invalid_stay", %{}}
    end
  end

  defp perform("cancel_group", operation, group) do
    case parse_date(operation["occurred_on"], "invalid_operation") do
      {:ok, occurred_on} ->
        refund_method = Map.get(operation, "refund_method", "cash")
        refundable = refundable?(group, occurred_on)

        cond do
          refund_method not in ["cash", "hotel_credit"] ->
            {:rejected, "invalid_operation", %{}}

          refund_method == "hotel_credit" and not refundable ->
            {:rejected, "refund_method_not_available", %{}}

          true ->
            settle_cancellation(group, operation, occurred_on, refundable, refund_method)
        end

      {:error, _code} ->
        {:rejected, "invalid_operation", %{}}
    end
  end

  defp perform("apply_hotel_credit", operation, group) do
    amount = operation["amount_cents"]
    outstanding = group.deposit_due_cents - group.deposit_paid_cents

    with {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation") do
      cond do
        not is_integer(amount) or amount <= 0 ->
          {:rejected, "invalid_amount", %{}}

        amount > outstanding ->
          {:rejected, "payment_exceeds_outstanding", %{}}

        true ->
          lots =
            Repo.all(
              from l in CreditLot,
                where:
                  l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
                    l.expires_on > ^occurred_on,
                order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
            )

          if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
            {:rejected, "insufficient_credit", %{}}
          else
            consume_credit_lots!(lots, group.id, amount)
            revision = group.revision + 1

            update_group!(group, %{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              credit_paid_cents: group.credit_paid_cents + amount,
              revision: revision
            })

            {:applied,
             %{
               group_id: group.id,
               amount_cents: amount,
               outstanding_deposit_cents: outstanding - amount,
               revision: revision
             }}
          end
      end
    else
      _ -> {:rejected, "invalid_operation", %{}}
    end
  end

  defp settle_cancellation(group, operation, occurred_on, refundable, refund_method) do
    applications =
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^group.id
      )

    if refundable do
      Enum.each(applications, &restore_credit!(&1, occurred_on))
    else
      Enum.each(applications, &Repo.delete!/1)
    end

    refunded = if refundable and refund_method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    credit_issued =
      if refundable and refund_method == "hotel_credit" do
        issue_credit!(
          group.guest_id,
          operation["operation_id"],
          group.cash_paid_cents,
          occurred_on
        )
      else
        0
      end

    converted = if credit_issued > 0, do: group.cash_paid_cents, else: 0
    revision = group.revision + 1

    update_group!(group, %{
      status: "cancelled",
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      revision: revision
    })

    {:applied,
     %{
       group_id: group.id,
       refunded_cents: refunded,
       retained_cents: retained,
       credit_issued_cents: credit_issued,
       revision: revision
     }}
  end

  defp consume_credit_lots!(_lots, _group_id, 0), do: :ok

  defp consume_credit_lots!([lot | rest], group_id, amount) do
    used = min(lot.remaining_cents, amount)
    update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents - used})

    Repo.insert!(%CreditApplication{
      group_id: group_id,
      credit_lot_id: lot.id,
      amount_cents: used
    })

    consume_credit_lots!(rest, group_id, amount - used)
  end

  defp restore_credit!(application, occurred_on) do
    # A lot may fund the same group through more than one operation, so reload it before
    # restoring each allocation rather than overwriting a restoration with stale state.
    lot = Repo.get!(CreditLot, application.credit_lot_id)

    if Date.compare(lot.expires_on, occurred_on) == :gt do
      update_credit_lot!(lot, %{remaining_cents: lot.remaining_cents + application.amount_cents})
    end

    Repo.delete!(application)
  end

  defp issue_credit!(_guest_id, _operation_id, 0, _occurred_on), do: 0

  defp issue_credit!(guest_id, operation_id, cash_cents, occurred_on) do
    bonus = div(cash_cents * 10 + 50, 100)
    amount = cash_cents + bonus

    Repo.insert!(%CreditLot{
      guest_id: guest_id,
      source_operation_id: operation_id,
      remaining_cents: amount,
      expires_on: Date.add(occurred_on, 366)
    })

    amount
  end

  defp refundable?(group, occurred_on) do
    until_date = refundable_until(group)
    not is_nil(until_date) and Date.compare(occurred_on, until_date) != :gt
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp update_credit_lot!(lot, attrs) do
    lot |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp update_group!(group, attrs) do
    group |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp stale_revision?(operation, group) do
    Map.has_key?(operation, "expected_revision") and
      operation["expected_revision"] != group.revision and
      is_integer(operation["expected_revision"])
  end

  defp invalid_expected_revision?(operation) do
    Map.has_key?(operation, "expected_revision") and
      not is_integer(operation["expected_revision"])
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => room_id, "nightly_rate_cents" => rate}
        when is_binary(room_id) and room_id != "" and is_integer(rate) and rate > 0 ->
          true

        _ ->
          false
      end)

    ids = Enum.map(rooms, &Map.get(&1, "room_id"))

    if valid and Enum.uniq(ids) == ids do
      {:ok,
       Enum.map(rooms, &%{room_id: &1["room_id"], nightly_rate_cents: &1["nightly_rate_cents"]})}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp validate_rooms(_), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @rate_plans, do: {:ok, rate_plan}
  defp validate_rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp valid_stay(arrival, departure) do
    if Date.compare(departure, arrival) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_, code), do: {:error, code}

  defp require_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp require_nonempty_strings(operation, fields) do
    if Enum.all?(fields, &(is_binary(operation[&1]) and operation[&1] != "")),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp format_result(operation_id, {:applied, fields}) do
    fields |> Map.put(:operation_id, operation_id) |> Map.put(:status, "applied")
  end

  defp format_result(operation_id, {:rejected, code, fields}) do
    fields
    |> Map.put(:operation_id, operation_id)
    |> Map.put(:status, "rejected")
    |> Map.put(:code, code)
  end
end
