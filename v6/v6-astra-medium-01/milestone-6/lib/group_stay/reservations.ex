defmodule GroupStay.Reservations do
  @moduledoc "Applies ordered partner operations and maintains reservation deposit accounting."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, HotelCredit, Operation, Repo, RoomAccounting}

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status rooms revision lodging_total_cents deposit_due_cents deposit_paid_cents cash_paid_cents credit_paid_cents policy_version)a
  @required %{
    "start_finance_reporting" => [],
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "apply_hotel_credit" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "cancel_group" => [],
    "cancel_rooms" => ~w(room_ids),
    "reduce_cash_payment" => ~w(amount_cents),
    "charge_back_payment" => [],
    "transfer_deposit" => ~w(amount_cents)
  }

  def batch(operations), do: Enum.map(operations, &apply_operation/1)

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def guest_credit(id, on \\ Date.utc_today()), do: HotelCredit.balance(id, on)

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
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
                cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
                cash_retained_cents: coalesce(sum(g.retained_cents), 0),
                cash_converted_to_credit_cents:
                  coalesce(sum(g.cash_converted_to_credit_cents), 0),
                cash_reduced_cents: coalesce(sum(g.cash_reduced_cents), 0),
                cash_charged_back_cents: coalesce(sum(g.cash_charged_back_cents), 0)
              }
          )

        cash
        |> Map.put(:credit_liability_cents, HotelCredit.liability(on))
        |> Map.put(:credit_shortfall_cents, HotelCredit.shortfall())
      end)

    totals
  end

  def get_payment(id), do: RoomAccounting.statement(id)

  def get_operation(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> nil
      record -> record.result
    end
  end

  defp apply_operation(op) do
    operation_id = if is_map(op), do: Map.get(op, "operation_id"), else: nil

    # Reserve the SQLite writer before either the deduplication or revision read.
    # The increasing record id therefore also reflects first commit order.
    {:ok, result} =
      Repo.transaction(
        fn ->
          if identifier?(operation_id) do
            case Repo.get_by(Operation, operation_id: operation_id) do
              nil ->
                finance_before = GroupStay.FinanceReporting.capture()
                result = process_operation(op, operation_id)
                GroupStay.FinanceReporting.record(finance_before, op, result)

                Repo.insert!(%Operation{
                  operation_id: operation_id,
                  type: if(is_binary(op["type"]), do: op["type"]),
                  submission: op,
                  result: Jason.decode!(Jason.encode!(result))
                })

                result

              record ->
                if record.submission === op do
                  # Only keys produced by this module are converted, never submission keys.
                  Map.new(record.result, fn {key, value} ->
                    {String.to_existing_atom(key), value}
                  end)
                else
                  %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
                end
            end
          else
            process_operation(op, operation_id)
          end
        end,
        mode: :immediate
      )

    result
  end

  defp process_operation(op, operation_id) do
    result =
      with :ok <- validate_operation(op),
           {:ok, fields} <- dispatch(op) do
        Map.merge(fields, %{status: "applied"})
      else
        {:error, code} ->
          %{status: "rejected", code: code}

        {:error, code, group_id} ->
          %{status: "rejected", code: code, group_id: group_id}

        {:stale, group, expected} ->
          %{
            status: "rejected",
            code: "stale_revision",
            group_id: group.group_id,
            expected_revision: expected,
            actual_revision: group.revision
          }

        {:stale, group} ->
          %{
            status: "rejected",
            code: "stale_revision",
            group_id: group.group_id,
            expected_revision: op["expected_revision"],
            actual_revision: group.revision
          }
      end

    Map.put(result, :operation_id, operation_id)
  end

  defp validate_operation(op) when is_map(op) do
    required = Map.get(@required, op["type"])

    targets =
      case op["type"] do
        "start_finance_reporting" ->
          []

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          ["payment_operation_id"]

        "transfer_deposit" ->
          ["source_group_id", "destination_group_id"]

        _ ->
          ["group_id"]
      end

    if required != nil and Enum.all?(["operation_id" | targets], &identifier?(op[&1])) and
         Map.has_key?(op, "occurred_on") and Enum.all?(required, &Map.has_key?(op, &1)) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_operation(_), do: {:error, "invalid_operation"}

  defp dispatch(%{"type" => "start_finance_reporting"} = op) do
    with {:ok, _} <- parse_date(op["occurred_on"], "invalid_operation") do
      GroupStay.FinanceReporting.start(op["starts_on"])
    end
  end

  defp dispatch(%{"type" => "open_group"} = op) do
    cond do
      Repo.get(Group, op["group_id"]) != nil ->
        {:error, "group_already_exists"}

      not identifier?(op["guest_id"]) or not identifier?(op["property_id"]) ->
        {:error, "invalid_operation"}

      true ->
        open(op)
    end
  end

  defp dispatch(%{"type" => "transfer_deposit"} = op) do
    with {:ok, source} <- transfer_group(op["source_group_id"]),
         {:ok, destination} <- transfer_group(op["destination_group_id"]),
         :ok <- revision_guard(source, op, "expected_revision"),
         :ok <- revision_guard(destination, op, "destination_expected_revision"),
         :ok <-
           ensure(
             source.group_id != destination.group_id and source.guest_id == destination.guest_id,
             "invalid_transfer"
           ),
         :ok <- active_transfer_group(source),
         :ok <- active_transfer_group(destination),
         :ok <-
           ensure(is_integer(op["amount_cents"]) and op["amount_cents"] > 0, "invalid_amount"),
         :ok <-
           ensure(
             op["amount_cents"] <= source.deposit_paid_cents,
             "transfer_exceeds_held_funding"
           ),
         :ok <-
           ensure(op["amount_cents"] <= outstanding(destination), "transfer_exceeds_outstanding"),
         {:ok, _} <- parse_date(op["occurred_on"], "invalid_operation") do
      {debited, funded} = RoomAccounting.transfer(source, destination, op["amount_cents"])
      source = update(source, RoomAccounting.totals(debited.rooms))

      destination =
        update(destination, RoomAccounting.totals(funded.rooms))

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: op["amount_cents"],
         source_outstanding_deposit_cents: outstanding(source),
         destination_outstanding_deposit_cents: outstanding(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp dispatch(%{"type" => type} = op)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    code =
      if type == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    case RoomAccounting.payment(op["payment_operation_id"]) do
      {:error, "operation_not_found"} = error ->
        error

      {:error, _} ->
        {:error, code}

      {:ok, payment} ->
        group = Repo.get!(Group, payment.result["group_id"])

        if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
          {:stale, group}
        else
          with {:ok, on} <- parse_date(op["occurred_on"], "invalid_operation") do
            change(group, op, on)
          end
        end
    end
  end

  defp dispatch(op) do
    case Repo.get(Group, op["group_id"]) do
      nil ->
        {:error, "group_not_found"}

      group ->
        cond do
          Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision ->
            {:stale, group}

          group.status != "active" ->
            {:error, "group_not_active"}

          true ->
            with {:ok, occurred_on} <- parse_date(op["occurred_on"], "invalid_operation") do
              change(group, op, occurred_on)
            end
        end
    end
  end

  defp transfer_group(id) do
    case Repo.get(Group, id) do
      nil -> {:error, "group_not_found", id}
      group -> {:ok, group}
    end
  end

  defp active_transfer_group(%{status: "active"}), do: :ok
  defp active_transfer_group(group), do: {:error, "group_not_active", group.group_id}

  defp revision_guard(group, op, key) do
    if Map.has_key?(op, key) and op[key] !== group.revision,
      do: {:stale, group, op[key]},
      else: :ok
  end

  defp open(op) do
    with {:ok, booked} <- parse_date(op["occurred_on"], "invalid_operation"),
         {:ok, arrival} <- parse_date(op["arrival_on"], "invalid_stay"),
         {:ok, departure} <- parse_date(op["departure_on"], "invalid_stay"),
         :ok <- ensure(Date.diff(departure, arrival) > 0, "invalid_stay"),
         :ok <- ensure(valid_rooms?(op["rooms"]), "invalid_rooms"),
         :ok <- ensure(op["rate_plan"] in ["flexible", "advance_purchase"], "invalid_rate_plan") do
      rooms = Enum.map(op["rooms"], &Map.take(&1, ~w(room_id nightly_rate_cents)))
      rooms = RoomAccounting.rooms(rooms, Date.diff(departure, arrival), op["rate_plan"])
      due = Enum.sum(Enum.map(rooms, & &1["deposit_due_cents"]))

      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: booked,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          policy_version: policy_version(op["rate_plan"], booked),
          rooms: rooms,
          lodging_total_cents: Enum.sum(Enum.map(rooms, & &1["lodging_total_cents"])),
          deposit_due_cents: due
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}}
    end
  end

  defp change(group, %{"type" => "record_cash_payment"} = op, _) do
    amount = op["amount_cents"]

    with :ok <- ensure(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- ensure(amount <= outstanding(group), "payment_exceeds_outstanding") do
      funded = RoomAccounting.allocate(group, amount, op["operation_id"])
      updated = update(group, RoomAccounting.totals(funded.rooms))

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp change(group, %{"type" => "apply_hotel_credit"} = op, occurred_on) do
    amount = op["amount_cents"]

    with :ok <- ensure(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- ensure(amount <= outstanding(group), "payment_exceeds_outstanding") do
      lots = HotelCredit.available_lots(group.guest_id, occurred_on)

      with :ok <-
             ensure(
               Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount,
               "insufficient_credit"
             ) do
        funded = HotelCredit.redeem(group, lots, amount, op["operation_id"])
        updated = update(group, RoomAccounting.totals(funded.rooms))

        {:ok,
         %{
           group_id: group.group_id,
           amount_cents: amount,
           outstanding_deposit_cents: outstanding(updated),
           revision: updated.revision
         }}
      end
    end
  end

  defp change(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    with {:ok, arrival} <- parse_date(op["new_arrival_on"], "invalid_stay"),
         :ok <- ensure(Date.compare(arrival, occurred_on) == :gt, "invalid_stay") do
      departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
      updated = update(group, arrival_on: arrival, departure_on: departure)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: arrival,
         new_departure_on: departure,
         policy_version: updated.policy_version,
         refundable_until: refundable_until(updated),
         revision: updated.revision
       }}
    end
  end

  defp change(group, %{"type" => type} = op, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    active_ids = for r <- group.rooms, r["status"] == "active", do: r["room_id"]
    ids = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    valid =
      is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
        Enum.all?(ids, &(&1 in active_ids))

    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred_on, cutoff) != :gt
    method = Map.get(op, "refund_method", "cash")

    with :ok <- ensure(valid, "invalid_rooms"),
         :ok <- ensure(method in ["cash", "hotel_credit"], "invalid_operation"),
         :ok <- ensure(method != "hotel_credit" or refundable, "refund_method_not_available") do
      ids = Enum.filter(active_ids, &(&1 in ids))

      {attrs, result} =
        RoomAccounting.settle(group, ids, refundable, method, op["operation_id"], occurred_on)

      updated = update(group, attrs)
      result = Map.merge(result, %{group_id: group.group_id, revision: updated.revision})

      {:ok,
       if(type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, ids), else: result)}
    end
  end

  defp change(group, %{"type" => "reduce_cash_payment"} = op, _) do
    id = op["payment_operation_id"]
    {:ok, statement} = RoomAccounting.statement(id)
    amount = op["amount_cents"]

    with :ok <- ensure(statement.held_cents > 0, "payment_not_reducible"),
         :ok <- ensure(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- ensure(amount <= statement.held_cents, "reduction_exceeds_held_cash") do
      groups = RoomAccounting.remove_held(group, id, amount, "reduced")

      groups =
        Map.update!(groups, group.group_id, fn original ->
          %{original | cash_reduced_cents: original.cash_reduced_cents + amount}
        end)

      updated = persist_groups(groups)[group.group_id]

      {:ok,
       %{
         payment_operation_id: id,
         group_id: group.group_id,
         amount_cents: amount,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp change(group, %{"type" => "charge_back_payment"} = op, _) do
    id = op["payment_operation_id"]
    {:ok, statement} = RoomAccounting.statement(id)

    with :ok <-
           ensure(
             statement.charged_back_cents == 0 and
               statement.recorded_cents > statement.reduced_cents,
             "payment_not_chargeable"
           ) do
      {groups, amount} = RoomAccounting.charge_back(group, id, statement)
      updated = persist_groups(groups)[group.group_id]

      {:ok,
       %{
         payment_operation_id: id,
         group_id: group.group_id,
         charged_back_cents: amount,
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp persist_groups(groups) do
    Map.new(groups, fn {id, changed} ->
      original = Repo.get!(Group, id)

      attrs =
        RoomAccounting.totals(changed.rooms) ++
          Map.to_list(
            Map.take(changed, [
              :refunded_cents,
              :retained_cents,
              :cash_converted_to_credit_cents,
              :cash_reduced_cents,
              :cash_charged_back_cents
            ])
          )

      {id, update(original, attrs)}
    end)
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked) do
    if Date.compare(booked, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))
  end

  defp update(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(%{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0
  defp ensure(true, _), do: :ok
  defp ensure(false, code), do: {:error, code}

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, code}
    end
  end

  defp parse_date(_, code), do: {:error, code}

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      is_map(room) and identifier?(room["room_id"]) and
        is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] >= 0
    end) and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
end
