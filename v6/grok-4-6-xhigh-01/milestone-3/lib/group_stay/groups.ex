defmodule GroupStay.Groups do
  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Operation

  @rate_plans ~w(flexible advance_purchase)
  @policy_cutoff ~D[2027-01-01]
  @refund_methods ~w(cash hotel_credit)

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  def get_by_group_id(group_id) when is_binary(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  def get_by_group_id(_), do: nil

  def get_operation_result(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      %Operation{result: result} -> result
      nil -> nil
    end
  end

  def get_operation_result(_), do: nil

  def ledger_totals(as_of \\ Date.utc_today()) do
    groups =
      Repo.all(
        from g in Group,
          select: {
            g.status,
            g.cash_paid_cents,
            g.refunded_cents,
            g.retained_cents,
            g.cash_converted_to_credit_cents
          }
      )

    cash =
      Enum.reduce(
        groups,
        %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0
        },
        fn
          {"active", cash_paid, _refunded, _retained, _converted}, acc ->
            %{acc | cash_held_cents: acc.cash_held_cents + cash_paid}

          {_status, _paid, refunded, retained, converted}, acc ->
            %{
              acc
              | cash_refunded_cents: acc.cash_refunded_cents + refunded,
                cash_retained_cents: acc.cash_retained_cents + retained,
                cash_converted_to_credit_cents: acc.cash_converted_to_credit_cents + converted
            }
        end
      )

    Map.put(cash, :credit_liability_cents, credit_liability_cents(as_of))
  end

  def guest_credit(guest_id, as_of \\ Date.utc_today()) when is_binary(guest_id) do
    lots =
      from(l in CreditLot,
        where: l.guest_id == ^guest_id and l.remaining_cents > 0 and l.expires_on >= ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end),
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

  def serialize(%Group{} = group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: group.booked_on,
      arrival_on: group.arrival_on,
      departure_on: group.departure_on,
      rate_plan: group.rate_plan,
      policy_version: policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms:
        Enum.map(group.rooms, &%{room_id: &1.room_id, nightly_rate_cents: &1.nightly_rate_cents}),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding(group)
    }
  end

  defp apply_operation(operation) when not is_map(operation) do
    rejected(operation, "invalid_operation")
  end

  defp apply_operation(operation) do
    operation = stringify_keys(operation)

    case rememberable_id(operation) do
      nil ->
        execute(operation)

      operation_id ->
        apply_remembered(operation_id, operation)
    end
  end

  defp apply_remembered(operation_id, operation) do
    case fetch_operation(operation_id) do
      %Operation{} = record ->
        replay_or_conflict(record, operation)

      nil ->
        case persist_first(operation_id, operation) do
          {:ok, result} ->
            result

          {:error, :taken} ->
            case fetch_operation(operation_id) do
              %Operation{} = record ->
                replay_or_conflict(record, operation)

              nil ->
                raise "missing idempotency record for #{operation_id}"
            end
        end
    end
  end

  defp persist_first(operation_id, operation) do
    case Repo.transaction(fn ->
           case fetch_operation(operation_id) do
             %Operation{} = record ->
               replay_or_conflict(record, operation)

             nil ->
               case claim(operation_id) do
                 {:ok, record} ->
                   result = result_of(operation)
                   finalize!(record, operation, result)
                   result

                 {:error, :taken} ->
                   Repo.rollback(:taken)
               end
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :taken} -> {:error, :taken}
    end
  end

  defp execute(operation) do
    case transact(fn -> dispatch(operation) end) do
      {:ok, result} -> canonicalize(result)
      {:error, result} when is_map(result) -> canonicalize(result)
      {:error, code} when is_binary(code) -> canonicalize(rejected(operation, code))
    end
  end

  defp result_of(operation) do
    Repo.query!("SAVEPOINT operation_domain")

    try do
      case dispatch(operation) do
        {:ok, result} ->
          Repo.query!("RELEASE SAVEPOINT operation_domain")
          canonicalize(result)

        {:error, result} when is_map(result) ->
          rollback_domain_savepoint()
          canonicalize(result)

        {:error, code} when is_binary(code) ->
          rollback_domain_savepoint()
          canonicalize(rejected(operation, code))
      end
    rescue
      exception ->
        _ = Repo.query("ROLLBACK TO SAVEPOINT operation_domain")
        reraise exception, __STACKTRACE__
    end
  end

  defp rollback_domain_savepoint do
    Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
    Repo.query!("RELEASE SAVEPOINT operation_domain")
  end

  defp rememberable_id(%{"operation_id" => id}) when is_binary(id) and id != "", do: id
  defp rememberable_id(_), do: nil

  defp fetch_operation(operation_id) do
    Repo.get_by(Operation, operation_id: operation_id)
  end

  defp claim(operation_id) do
    %Operation{}
    |> Operation.changeset(%{
      operation_id: operation_id,
      payload: %{},
      result: %{}
    })
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        if unique_error?(changeset, :operation_id) do
          {:error, :taken}
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp finalize!(record, operation, result) do
    record
    |> Operation.changeset(%{
      type: operation_type(operation),
      payload: canonicalize(operation),
      result: result
    })
    |> Repo.update!()
  end

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_), do: nil

  defp replay_or_conflict(%Operation{} = record, operation) do
    if equivalent_payload?(record.payload, operation) do
      record.result
    else
      canonicalize(%{
        operation_id: record.operation_id,
        status: "rejected",
        code: "operation_id_conflict"
      })
    end
  end

  defp equivalent_payload?(stored, incoming) do
    canonicalize(stored) == canonicalize(incoming)
  end

  defp canonicalize(%Date{} = date), do: Date.to_iso8601(date)

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), canonicalize(value)} end)
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp dispatch(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp dispatch(%{"type" => "record_cash_payment"} = operation),
    do: record_cash_payment(operation)

  defp dispatch(%{"type" => "reschedule_group"} = operation), do: reschedule_group(operation)
  defp dispatch(%{"type" => "cancel_group"} = operation), do: cancel_group(operation)

  defp dispatch(%{"type" => "apply_hotel_credit"} = operation),
    do: apply_hotel_credit(operation)

  defp dispatch(operation), do: {:error, rejected(operation, "invalid_operation")}

  defp open_group(operation) do
    with {:ok, attrs} <- parse_open(operation) do
      case Repo.get_by(Group, group_id: attrs.group_id) do
        %Group{} ->
          {:error, rejected(operation, "group_already_exists")}

        nil ->
          case Repo.insert(Group.insert_changeset(attrs)) do
            {:ok, group} ->
              {:ok,
               applied(operation, %{
                 group_id: group.group_id,
                 deposit_due_cents: group.deposit_due_cents,
                 revision: group.revision
               })}

            {:error, changeset} ->
              if unique_error?(changeset, :group_id) do
                {:error, rejected(operation, "group_already_exists")}
              else
                {:error, rejected(operation, "invalid_operation")}
              end
          end
      end
    end
  end

  defp record_cash_payment(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, amount} <- req_payment_amount(operation) do
      outstanding = outstanding(group)

      cond do
        amount > outstanding ->
          {:error, rejected(operation, "payment_exceeds_outstanding")}

        true ->
          {:ok, group} =
            group
            |> change(%{
              deposit_paid_cents: group.deposit_paid_cents + amount,
              cash_paid_cents: group.cash_paid_cents + amount
            })
            |> optimistic_lock(:revision)
            |> Repo.update()

          {:ok,
           applied(operation, %{
             group_id: group.group_id,
             amount_cents: amount,
             outstanding_deposit_cents: outstanding(group),
             revision: group.revision
           })}
      end
    end
  end

  defp apply_hotel_credit(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, amount} <- req_payment_amount(operation) do
      outstanding = outstanding(group)

      cond do
        amount > outstanding ->
          {:error, rejected(operation, "payment_exceeds_outstanding")}

        true ->
          case consume_credit(group, amount, occurred_on) do
            :ok ->
              {:ok, group} =
                group
                |> change(%{
                  deposit_paid_cents: group.deposit_paid_cents + amount,
                  credit_paid_cents: group.credit_paid_cents + amount
                })
                |> optimistic_lock(:revision)
                |> Repo.update()

              {:ok,
               applied(operation, %{
                 group_id: group.group_id,
                 amount_cents: amount,
                 outstanding_deposit_cents: outstanding(group),
                 revision: group.revision
               })}

            {:error, code} ->
              {:error, rejected(operation, code)}
          end
      end
    end
  end

  defp reschedule_group(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, new_arrival_on} <- req_date(operation, "new_arrival_on", "invalid_stay"),
         :ok <- validate_new_arrival(new_arrival_on, occurred_on) do
      shift = Date.diff(new_arrival_on, group.arrival_on)
      new_departure_on = Date.add(group.departure_on, shift)

      {:ok, group} =
        group
        |> change(%{arrival_on: new_arrival_on, departure_on: new_departure_on})
        |> optimistic_lock(:revision)
        |> Repo.update()

      {:ok,
       applied(operation, %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         policy_version: policy_version(group),
         refundable_until: refundable_until(group),
         revision: group.revision
       })}
    end
  end

  defp cancel_group(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, group} <- fetch_group(operation, group_id),
         :ok <- match_revision(operation, group),
         :ok <- require_active(group),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, refund_method} <- req_refund_method(operation) do
      refundable? = refundable?(group, occurred_on)

      cond do
        refund_method == "hotel_credit" and not refundable? ->
          {:error, rejected(operation, "refund_method_not_available")}

        true ->
          {refunded, retained, converted, credit_issued} =
            settle_cancellation(group, occurred_on, refund_method, refundable?, operation)

          {:ok, group} =
            group
            |> change(%{
              status: "cancelled",
              refunded_cents: refunded,
              retained_cents: retained,
              cash_converted_to_credit_cents: converted
            })
            |> optimistic_lock(:revision)
            |> Repo.update()

          {:ok,
           applied(operation, %{
             group_id: group.group_id,
             refunded_cents: group.refunded_cents,
             retained_cents: group.retained_cents,
             credit_issued_cents: credit_issued,
             revision: group.revision
           })}
      end
    end
  end

  defp parse_open(operation) do
    with {:ok, group_id} <- req_id(operation, "group_id"),
         {:ok, guest_id} <- req_id(operation, "guest_id"),
         {:ok, property_id} <- req_id(operation, "property_id"),
         {:ok, occurred_on} <- req_date(operation, "occurred_on", "invalid_operation"),
         {:ok, rate_plan} <- req_rate_plan(operation),
         {:ok, arrival_on} <- req_date(operation, "arrival_on", "invalid_stay"),
         {:ok, departure_on} <- req_date(operation, "departure_on", "invalid_stay"),
         :ok <- validate_stay_length(arrival_on, departure_on),
         {:ok, rooms} <- req_rooms(operation) do
      nights = Date.diff(departure_on, arrival_on)
      {lodging, deposit} = totals(rooms, nights, rate_plan)

      {:ok,
       %{
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         booked_on: occurred_on,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         policy_version: implied_policy(rate_plan, occurred_on),
         rooms: rooms,
         lodging_total_cents: lodging,
         deposit_due_cents: deposit,
         deposit_paid_cents: 0,
         cash_paid_cents: 0,
         credit_paid_cents: 0,
         refunded_cents: 0,
         retained_cents: 0,
         cash_converted_to_credit_cents: 0,
         status: "active",
         revision: 1
       }}
    else
      {:error, result} -> {:error, result}
    end
  end

  defp totals(rooms, nights, rate_plan) do
    Enum.reduce(rooms, {0, 0}, fn room, {lodging_acc, deposit_acc} ->
      lodging = nights * room.nightly_rate_cents
      deposit = room_deposit(lodging, rate_plan)
      {lodging_acc + lodging, deposit_acc + deposit}
    end)
  end

  defp room_deposit(lodging, "flexible"), do: round_percent(lodging, 20)
  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp round_percent(amount_cents, percent) do
    div(amount_cents * percent + 50, 100)
  end

  defp outstanding(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  defp outstanding(_group), do: 0

  defp policy_version(%Group{policy_version: version} = group)
       when version not in ["flex-14", "flex-30", "advance-nonrefundable"] do
    implied_policy(group.rate_plan, group.booked_on)
  end

  defp policy_version(%Group{policy_version: version}), do: version

  defp implied_policy("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp implied_policy("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  defp implied_policy(_rate_plan, _booked_on), do: "advance-nonrefundable"

  defp refundable_until(group) do
    case policy_version(group) do
      "flex-14" -> Date.add(group.arrival_on, -14)
      "flex-30" -> Date.add(group.arrival_on, -30)
      _ -> nil
    end
  end

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end

  defp settle_cancellation(group, occurred_on, refund_method, refundable?, operation) do
    cash = group.cash_paid_cents

    cond do
      refundable? and refund_method == "hotel_credit" ->
        restore_applied_credit(group, occurred_on)
        issued = issue_credit(group.guest_id, cash, occurred_on, operation["operation_id"])
        {0, 0, cash, issued}

      refundable? ->
        restore_applied_credit(group, occurred_on)
        {cash, 0, 0, 0}

      true ->
        consume_applied_credit(group)
        {0, cash, 0, 0}
    end
  end

  defp issue_credit(_guest_id, cash_cents, _occurred_on, _operation_id) when cash_cents <= 0 do
    0
  end

  defp issue_credit(guest_id, cash_cents, occurred_on, operation_id) do
    issued = cash_cents + round_percent(cash_cents, 10)

    %CreditLot{}
    |> CreditLot.changeset(%{
      guest_id: guest_id,
      source_operation_id: operation_id || "",
      issued_cents: issued,
      remaining_cents: issued,
      expires_on: Date.add(occurred_on, 365)
    })
    |> Repo.insert!()

    issued
  end

  defp consume_credit(group, amount, occurred_on) do
    lots =
      from(l in CreditLot,
        where:
          l.guest_id == ^group.guest_id and l.remaining_cents > 0 and l.expires_on >= ^occurred_on,
        order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )
      |> Repo.all()

    available = Enum.reduce(lots, 0, fn lot, acc -> acc + lot.remaining_cents end)

    if available < amount do
      {:error, "insufficient_credit"}
    else
      take_from_lots(lots, amount, group.group_id)
      :ok
    end
  end

  defp take_from_lots(_lots, 0, _group_id), do: :ok

  defp take_from_lots([lot | rest], remaining, group_id) do
    take = min(lot.remaining_cents, remaining)

    lot
    |> change(%{remaining_cents: lot.remaining_cents - take})
    |> Repo.update!()

    %CreditApplication{}
    |> CreditApplication.changeset(%{
      group_id: group_id,
      credit_lot_id: lot.id,
      amount_cents: take,
      status: "held"
    })
    |> Repo.insert!()

    take_from_lots(rest, remaining - take, group_id)
  end

  defp restore_applied_credit(group, occurred_on) do
    applications =
      from(a in CreditApplication,
        where: a.group_id == ^group.group_id and a.status == "held",
        preload: [:credit_lot]
      )
      |> Repo.all()

    Enum.each(applications, fn application ->
      lot = application.credit_lot

      if Date.compare(lot.expires_on, occurred_on) != :lt do
        lot
        |> change(%{remaining_cents: lot.remaining_cents + application.amount_cents})
        |> Repo.update!()

        application
        |> change(%{status: "restored"})
        |> Repo.update!()
      else
        application
        |> change(%{status: "expired"})
        |> Repo.update!()
      end
    end)
  end

  defp consume_applied_credit(group) do
    from(a in CreditApplication,
      where: a.group_id == ^group.group_id and a.status == "held"
    )
    |> Repo.all()
    |> Enum.each(fn application ->
      application
      |> change(%{status: "consumed"})
      |> Repo.update!()
    end)
  end

  defp credit_liability_cents(as_of) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.remaining_cents > 0 and l.expires_on >= ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    held =
      Repo.one(
        from a in CreditApplication,
          join: g in Group,
          on: g.group_id == a.group_id,
          where: a.status == "held" and g.status == "active",
          select: coalesce(sum(a.amount_cents), 0)
      )

    available + held
  end

  defp fetch_group(operation, group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, rejected(operation, "group_not_found")}
    end
  end

  defp match_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, expected} ->
        if expected === group.revision do
          :ok
        else
          {:error,
           %{
             operation_id: operation["operation_id"],
             status: "rejected",
             code: "stale_revision",
             group_id: group.group_id,
             expected_revision: expected,
             actual_revision: group.revision
           }
           |> drop_nil_operation_id()}
        end
    end
  end

  defp require_active(%Group{status: "active"}), do: :ok
  defp require_active(_group), do: {:error, "group_not_active"}

  defp validate_stay_length(arrival_on, departure_on) do
    if Date.diff(departure_on, arrival_on) >= 1 do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp validate_new_arrival(new_arrival_on, occurred_on) do
    if Date.compare(new_arrival_on, occurred_on) == :gt do
      :ok
    else
      {:error, "invalid_stay"}
    end
  end

  defp req_id(operation, key) do
    case operation[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp req_date(operation, key, code) do
    case parse_date(operation[key]) do
      {:ok, date} ->
        {:ok, date}

      :error ->
        {:error, if(code == "invalid_operation", do: rejected(operation, code), else: code)}
    end
  end

  defp req_rate_plan(operation) do
    case operation["rate_plan"] do
      plan when plan in @rate_plans -> {:ok, plan}
      _ -> {:error, "invalid_rate_plan"}
    end
  end

  defp req_refund_method(operation) do
    case Map.fetch(operation, "refund_method") do
      :error -> {:ok, "cash"}
      {:ok, nil} -> {:ok, "cash"}
      {:ok, method} when method in @refund_methods -> {:ok, method}
      {:ok, _} -> {:error, rejected(operation, "invalid_operation")}
    end
  end

  defp req_rooms(operation) do
    case operation["rooms"] do
      rooms when is_list(rooms) and rooms != [] ->
        parsed = Enum.map(rooms, &parse_room/1)

        cond do
          Enum.any?(parsed, &(&1 == :error)) ->
            {:error, "invalid_rooms"}

          true ->
            rooms = Enum.map(parsed, fn {:ok, room} -> room end)
            ids = Enum.map(rooms, & &1.room_id)

            if ids == Enum.uniq(ids) do
              {:ok, rooms}
            else
              {:error, "invalid_rooms"}
            end
        end

      _ ->
        {:error, "invalid_rooms"}
    end
  end

  defp parse_room(room) when is_map(room) do
    room = stringify_keys(room)
    id = room["room_id"]
    rate = room["nightly_rate_cents"]

    if is_binary(id) and id != "" and is_integer(rate) and rate >= 0 do
      {:ok, %{room_id: id, nightly_rate_cents: rate}}
    else
      :error
    end
  end

  defp parse_room(_), do: :error

  defp req_payment_amount(operation) do
    case Map.fetch(operation, "amount_cents") do
      :error ->
        {:error, rejected(operation, "invalid_operation")}

      {:ok, amount} when is_integer(amount) and amount > 0 ->
        {:ok, amount}

      {:ok, _} ->
        {:error, "invalid_amount"}
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    Date.from_iso8601(value)
  end

  defp parse_date(_), do: :error

  defp applied(operation, fields) do
    Map.merge(%{operation_id: operation["operation_id"], status: "applied"}, fields)
    |> drop_nil_operation_id()
  end

  defp rejected(operation, code) when is_map(operation) do
    %{operation_id: operation["operation_id"], status: "rejected", code: code}
    |> drop_nil_operation_id()
  end

  defp rejected(_operation, code) do
    %{status: "rejected", code: code}
  end

  defp drop_nil_operation_id(%{operation_id: nil} = map), do: Map.delete(map, :operation_id)
  defp drop_nil_operation_id(map), do: map

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp transact(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
