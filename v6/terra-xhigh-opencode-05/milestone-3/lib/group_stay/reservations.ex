defmodule GroupStay.Reservations do
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CreditApplication, CreditLot, Group, PartnerOperation, Room}

  @rate_plans ["flexible", "advance_purchase"]
  @policy_cutover ~D[2027-01-01]

  def process_batch(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> :not_found
      group -> {:ok, group_response(group)}
    end
  end

  def get_operation(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> :not_found
      operation -> {:ok, Jason.decode!(operation.result)}
    end
  end

  def ledger(on \\ Date.utc_today()) do
    %{
      cash_held_cents: sum_for(:cash_paid_cents, status: "active"),
      cash_refunded_cents: sum_for(:refunded_cents),
      cash_retained_cents: sum_for(:retained_cents),
      cash_converted_to_credit_cents: sum_for(:cash_converted_to_credit_cents),
      credit_liability_cents: credit_liability(on)
    }
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum_by(lots, & &1.remaining_cents),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  defp process_operation(operation) when is_map(operation) do
    case Map.get(operation, "operation_id") do
      operation_id when is_binary(operation_id) ->
        process_identified_operation(operation, canonical_json(operation))

      _ ->
        process_unidentified_operation(operation)
    end
  end

  defp process_operation(operation), do: process_unidentified_operation(operation)

  defp process_identified_operation(operation, submitted_payload) do
    case Repo.transaction(
           fn ->
             case Repo.get_by(PartnerOperation, operation_id: operation["operation_id"]) do
               nil ->
                 result = apply_operation(operation)

                 if Map.get(result, :code) == "retry" do
                   Repo.rollback(:retry)
                 end

                 remember_operation(operation, submitted_payload, result)
                 result

               existing_operation ->
                 if existing_operation.submitted_payload == submitted_payload do
                   Jason.decode!(existing_operation.result)
                 else
                   reject(operation, "operation_id_conflict")
                 end
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, :retry} -> process_identified_operation(operation, submitted_payload)
    end
  end

  defp process_unidentified_operation(operation) do
    case Repo.transaction(
           fn ->
             result = apply_operation(operation)

             if result.status == "rejected" do
               Repo.rollback(result)
             else
               result
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, %{code: "retry"}} -> process_unidentified_operation(operation)
      {:error, result} -> result
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> record_cash_payment(operation)
      "reschedule_group" -> reschedule_group(operation)
      "cancel_group" -> cancel_group(operation)
      "apply_hotel_credit" -> apply_hotel_credit(operation)
      _ -> reject(operation, "invalid_operation")
    end
  end

  defp apply_operation(_operation), do: %{status: "rejected", code: "invalid_operation"}

  defp remember_operation(operation, submitted_payload, result) do
    Repo.insert!(%PartnerOperation{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submitted_payload: submitted_payload,
      result: Jason.encode!(result)
    })
  end

  defp operation_type(operation) do
    case Map.get(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} ->
        {Jason.encode!(key), canonical_json(nested_value)}
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested_value} -> key <> ":" <> nested_value end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

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
             %{
               deposit_paid_cents: group.deposit_paid_cents + operation["amount_cents"],
               cash_paid_cents: group.cash_paid_cents + operation["amount_cents"]
             },
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
        policy_version: policy_version(group),
        refundable_until: refundable_until(group),
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
         {:ok, refund_method} <- refund_method(operation),
         refundable? <- refundable?(group, occurred_on),
         :ok <- hotel_credit_available(refund_method, refundable?),
         {refunded_cents, retained_cents, cash_converted_to_credit_cents, credit_issued_cents} <-
           cancellation_settlement(group, refund_method, refundable?),
         :ok <- settle_applied_credit(group, occurred_on, refundable?),
         :ok <-
           issue_hotel_credit(
             group,
             common.operation_id,
             occurred_on,
             credit_issued_cents
           ),
         {:ok, group} <-
           update_group(
             group,
             %{
               status: "cancelled",
               refunded_cents: refunded_cents,
               retained_cents: retained_cents,
               cash_converted_to_credit_cents: cash_converted_to_credit_cents
             },
             operation
           ) do
      %{
        operation_id: common.operation_id,
        status: "applied",
        group_id: group.group_id,
        refunded_cents: refunded_cents,
        retained_cents: retained_cents,
        credit_issued_cents: credit_issued_cents,
        revision: group.revision
      }
    else
      {:rejected, code} -> reject(operation, code)
      {:rejected, code, details} -> reject(operation, code, details)
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, common} <- common_operation(operation),
         :ok <- require_keys(operation, ["group_id"]),
         {:ok, group} <- fetch_group(operation["group_id"]),
         :ok <- check_revision(operation, group),
         :ok <- active_group(group),
         :ok <- require_keys(operation, ~w(occurred_on amount_cents)),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"], "invalid_operation"),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- does_not_exceed_outstanding(operation["amount_cents"], group),
         :ok <- consume_hotel_credit(group, operation["amount_cents"], occurred_on),
         {:ok, group} <-
           update_group(
             group,
             %{
               deposit_paid_cents: group.deposit_paid_cents + operation["amount_cents"],
               credit_paid_cents: group.credit_paid_cents + operation["amount_cents"]
             },
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
      policy_version: policy_for(operation["rate_plan"], booked_on),
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents,
      deposit_paid_cents: 0,
      cash_paid_cents: 0,
      credit_paid_cents: 0,
      refunded_cents: 0,
      retained_cents: 0,
      cash_converted_to_credit_cents: 0
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
    |> Enum.each(fn {room, position} ->
      Repo.insert!(%Room{
        group_id: group_id,
        room_id: room["room_id"],
        nightly_rate_cents: room["nightly_rate_cents"],
        position: position
      })
    end)

    :ok
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

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:rejected, "invalid_operation"}
    end
  end

  defp hotel_credit_available("hotel_credit", false),
    do: {:rejected, "refund_method_not_available"}

  defp hotel_credit_available(_refund_method, _refundable?), do: :ok

  defp cancellation_settlement(group, "cash", true), do: {group.cash_paid_cents, 0, 0, 0}

  defp cancellation_settlement(group, "hotel_credit", true) do
    credit_issued_cents = group.cash_paid_cents + percentage_bonus(group.cash_paid_cents)
    {0, 0, group.cash_paid_cents, credit_issued_cents}
  end

  defp cancellation_settlement(group, _refund_method, false), do: {0, group.cash_paid_cents, 0, 0}

  defp percentage_bonus(cash_paid_cents), do: div(cash_paid_cents + 5, 10)

  defp refundable?(group, occurred_on) do
    case refundable_until_date(group) do
      nil -> false
      refundable_until -> Date.compare(occurred_on, refundable_until) != :gt
    end
  end

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp policy_version(%Group{policy_version: policy_version})
       when policy_version in ["flex-14", "flex-30", "advance-nonrefundable"],
       do: policy_version

  defp policy_version(group), do: policy_for(group.rate_plan, group.booked_on)

  defp refundable_until(group) do
    group
    |> refundable_until_date()
    |> date_string()
  end

  defp refundable_until_date(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      "advance-nonrefundable" -> nil
    end
  end

  defp date_string(nil), do: nil
  defp date_string(date), do: Date.to_iso8601(date)

  defp issue_hotel_credit(_group, _operation_id, _occurred_on, 0), do: :ok

  defp issue_hotel_credit(group, operation_id, occurred_on, credit_issued_cents) do
    case Repo.insert(%CreditLot{
           guest_id: group.guest_id,
           source_operation_id: operation_id,
           remaining_cents: credit_issued_cents,
           # Credit is usable for the 365 days following cancellation and expires the next day.
           expires_on: Date.add(occurred_on, 366)
         }) do
      {:ok, _lot} -> :ok
      {:error, _changeset} -> {:rejected, "retry"}
    end
  end

  defp consume_hotel_credit(group, amount_cents, occurred_on) do
    lots = available_lots(group.guest_id, occurred_on)

    with :ok <- enough_credit(lots, amount_cents),
         {:ok, allocations} <- credit_allocations(lots, amount_cents),
         :ok <- decrement_lots(allocations, occurred_on),
         :ok <- create_credit_applications(group.group_id, allocations) do
      :ok
    end
  end

  defp enough_credit(lots, amount_cents) do
    if Enum.sum_by(lots, & &1.remaining_cents) >= amount_cents,
      do: :ok,
      else: {:rejected, "insufficient_credit"}
  end

  defp credit_allocations(lots, amount_cents) do
    {remaining_cents, allocations} =
      Enum.reduce_while(lots, {amount_cents, []}, fn lot, {remaining_cents, allocations} ->
        applied_cents = min(lot.remaining_cents, remaining_cents)

        if applied_cents == remaining_cents do
          {:halt, {0, [{lot, applied_cents} | allocations]}}
        else
          {:cont, {remaining_cents - applied_cents, [{lot, applied_cents} | allocations]}}
        end
      end)

    if remaining_cents == 0,
      do: {:ok, Enum.reverse(allocations)},
      else: {:rejected, "insufficient_credit"}
  end

  defp decrement_lots(allocations, occurred_on) do
    Enum.reduce_while(allocations, :ok, fn {lot, applied_cents}, :ok ->
      query =
        from current_lot in CreditLot,
          where:
            current_lot.id == ^lot.id and
              current_lot.remaining_cents >= ^applied_cents and
              current_lot.expires_on > ^occurred_on

      case Repo.update_all(query, inc: [remaining_cents: -applied_cents]) do
        {1, _} -> {:cont, :ok}
        {0, _} -> {:halt, {:rejected, "retry"}}
      end
    end)
  end

  defp create_credit_applications(group_id, allocations) do
    Enum.reduce_while(allocations, :ok, fn {lot, applied_cents}, :ok ->
      case Repo.insert(%CreditApplication{
             group_id: group_id,
             credit_lot_id: lot.id,
             amount_cents: applied_cents
           }) do
        {:ok, _application} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:rejected, "retry"}}
      end
    end)
  end

  defp settle_applied_credit(group, occurred_on, true) do
    group
    |> applied_credit_by_lot()
    |> Enum.each(fn {lot_id, expires_on, amount_cents} ->
      if Date.compare(expires_on, occurred_on) == :gt do
        CreditLot
        |> where([lot], lot.id == ^lot_id)
        |> Repo.update_all(inc: [remaining_cents: amount_cents])
      end
    end)

    delete_credit_applications(group.group_id)
  end

  defp settle_applied_credit(group, _occurred_on, false) do
    delete_credit_applications(group.group_id)
  end

  defp applied_credit_by_lot(group) do
    CreditApplication
    |> join(:inner, [application], lot in CreditLot, on: lot.id == application.credit_lot_id)
    |> where([application], application.group_id == ^group.group_id)
    |> group_by([_application, lot], [lot.id, lot.expires_on])
    |> select([application, lot], {lot.id, lot.expires_on, sum(application.amount_cents)})
    |> Repo.all()
  end

  defp delete_credit_applications(group_id) do
    CreditApplication
    |> where([application], application.group_id == ^group_id)
    |> Repo.delete_all()

    :ok
  end

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
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      revision: group.revision,
      rooms: rooms,
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp sum_for(field, filters \\ []) do
    Group
    |> where(^filters)
    |> select([group], coalesce(sum(field(group, ^field)), 0))
    |> Repo.one()
  end

  defp available_lots(guest_id, on) do
    CreditLot
    |> where(
      [lot],
      lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on > ^on
    )
    |> order_by([lot], asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id)
    |> Repo.all()
  end

  defp credit_liability(on) do
    available_cents =
      CreditLot
      |> where([lot], lot.remaining_cents > 0 and lot.expires_on > ^on)
      |> select([lot], coalesce(sum(lot.remaining_cents), 0))
      |> Repo.one()

    applied_cents =
      CreditApplication
      |> join(:inner, [application], group in Group, on: group.group_id == application.group_id)
      |> where([_application, group], group.status == "active")
      |> select([application], coalesce(sum(application.amount_cents), 0))
      |> Repo.one()

    available_cents + applied_cents
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
