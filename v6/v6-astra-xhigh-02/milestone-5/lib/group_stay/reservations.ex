defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations and owns reservation deposits, credit and settlements.

  Each operation has its own transaction, so rejections cannot undo earlier operations.
  SQLite's immediate transactions acquire the write lock before reading a revision or
  balance, making validation and the resulting update atomic across connections.
  """

  import Ecto.Query
  alias GroupStay.{PartnerOperations, Repo}
  alias GroupStay.Reservations.{Group, HotelCredit, Payments, Room, RoomAccounting}

  @operation_types ~w(open_group record_cash_payment apply_hotel_credit reschedule_group cancel_group cancel_rooms)
  @payment_operation_types ~w(reduce_cash_payment charge_back_payment)
  @max_cents 9_223_372_036_854_775_807
  @group_fields ~w(group_id guest_id property_id revision booked_on arrival_on departure_on
                   rate_plan policy_version status lodging_total_cents deposit_due_cents
                   deposit_paid_cents cash_paid_cents credit_paid_cents)a

  def process_batch(operations) when is_list(operations) do
    Enum.map(operations, fn operation ->
      PartnerOperations.process(operation, &apply_operation/1)
    end)
  end

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> serialize_group(group)
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = HotelCredit.available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def ledger(on \\ Date.utc_today()) do
    # Use one read snapshot so a concurrent redemption cannot be counted in both
    # a lot and a group (or neither). Sum in Elixir to avoid SQLite SUM overflow.
    {:ok, totals} =
      Repo.transact(fn ->
        fields = [
          cash_paid_cents: :cash_held_cents,
          cash_refunded_cents: :cash_refunded_cents,
          cash_retained_cents: :cash_retained_cents,
          cash_converted_to_credit_cents: :cash_converted_to_credit_cents,
          credit_paid_cents: :credit_liability_cents
        ]

        totals = fields |> Enum.map(fn {_, output} -> {output, 0} end) |> Map.new()
        totals = Map.merge(totals, Payments.reversal_totals())

        totals =
          Map.merge(totals, %{
            credit_liability_cents: HotelCredit.available_total(on),
            credit_shortfall_cents: HotelCredit.shortfall_total()
          })

        balances = Repo.all(from g in Group, select: map(g, ^Keyword.keys(fields)))

        {:ok,
         Enum.reduce(balances, totals, fn group, totals ->
           Enum.reduce(fields, totals, fn {field, output}, totals ->
             Map.update!(totals, output, &(&1 + Map.fetch!(group, field)))
           end)
         end)}
      end)

    totals
  end

  def read_date(params) do
    case Map.fetch(params, "on") do
      :error -> {:ok, Date.utc_today()}
      {:ok, value} -> parse_date(value, "invalid_date")
    end
  end

  defp apply_operation(operation) when is_map(operation) do
    cond do
      not identifier?(operation["operation_id"]) ->
        reject("invalid_operation")

      operation["type"] == "transfer_deposit" and
        identifier?(operation["source_group_id"]) and
          identifier?(operation["destination_group_id"]) ->
        transfer_deposit(operation)

      operation["type"] in @payment_operation_types and
          identifier?(operation["payment_operation_id"]) ->
        update_payment(operation)

      operation["type"] in @operation_types and identifier?(operation["group_id"]) ->
        if operation["type"] == "open_group",
          do: open_group(operation),
          else: update_group(operation)

      true ->
        reject("invalid_operation")
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp open_group(operation) do
    with :ok <- new_group(operation["group_id"]),
         :ok <-
           required_fields(
             operation,
             ~w(guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         :ok <- guest_and_property(operation),
         {:ok, booked_on} <- operation_date(operation),
         {:ok, {arrival_on, departure_on}} <- stay(operation),
         :ok <- rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- rooms(operation["rooms"], Date.diff(departure_on, arrival_on)) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_amounts = Enum.map(rooms, &(&1.nightly_rate_cents * nights))

      rooms =
        Enum.zip_with(rooms, lodging_amounts, fn room, lodging ->
          due =
            if operation["rate_plan"] == "flexible",
              do: div(lodging * 20 + 50, 100),
              else: lodging

          %{room | lodging_total_cents: lodging, deposit_due_cents: due}
        end)

      deposit_due = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

      group =
        Repo.insert!(%Group{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          policy_version: policy_version(operation["rate_plan"], booked_on),
          rooms: rooms,
          lodging_total_cents: Enum.sum(lodging_amounts),
          deposit_due_cents: deposit_due
        })

      applied(group, %{deposit_due_cents: deposit_due})
    end
  end

  defp update_group(operation) do
    with {:ok, group} <- find_group(operation["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, occurred_on} <- operation_date(operation),
         :ok <- active(group) do
      case operation["type"] do
        "record_cash_payment" -> record_cash_payment(group, operation)
        "apply_hotel_credit" -> apply_hotel_credit(group, operation, occurred_on)
        "reschedule_group" -> reschedule_group(group, operation, occurred_on)
        "cancel_group" -> cancel_group(group, operation, occurred_on)
        "cancel_rooms" -> cancel_rooms(group, operation, occurred_on)
      end
    end
  end

  defp record_cash_payment(group, operation) do
    with :ok <- required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(operation["amount_cents"]),
         :ok <- within_outstanding(group, operation["amount_cents"]) do
      RoomAccounting.allocate(group, [
        %{
          payment_operation_id: operation["operation_id"],
          amount_cents: operation["amount_cents"]
        }
      ])

      group = save_group(group, RoomAccounting.totals(group))

      applied(group, %{
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: outstanding(group)
      })
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source} <- transfer_group(operation["source_group_id"]),
         {:ok, destination} <- transfer_group(operation["destination_group_id"]),
         :ok <- check_revision(source, operation),
         :ok <- check_revision(destination, operation, "destination_expected_revision"),
         {:ok, _on} <- operation_date(operation),
         :ok <- transfer_participants(source, destination),
         :ok <- required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(operation["amount_cents"]),
         :ok <- transfer_capacity(source, destination, operation["amount_cents"]) do
      RoomAccounting.transfer(source, destination, operation["amount_cents"])
      source = save_group(source, RoomAccounting.totals(source))
      destination = save_group(destination, RoomAccounting.totals(destination))

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: operation["amount_cents"],
         source_outstanding_deposit_cents: outstanding(source),
         destination_outstanding_deposit_cents: outstanding(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp transfer_group(group_id) do
    case find_group(group_id) do
      {:error, fields} -> {:error, Map.put(fields, :group_id, group_id)}
      found -> found
    end
  end

  defp transfer_participants(source, destination) do
    cond do
      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        reject("invalid_transfer")

      source.status != "active" ->
        {:error, %{code: "group_not_active", group_id: source.group_id}}

      destination.status != "active" ->
        {:error, %{code: "group_not_active", group_id: destination.group_id}}

      true ->
        :ok
    end
  end

  defp transfer_capacity(source, destination, amount) do
    cond do
      amount > source.deposit_paid_cents -> reject("transfer_exceeds_held_funding")
      amount > outstanding(destination) -> reject("transfer_exceeds_outstanding")
      true -> :ok
    end
  end

  defp apply_hotel_credit(group, operation, occurred_on) do
    with :ok <- required_fields(operation, ["amount_cents"]),
         :ok <- payment_amount(operation["amount_cents"]),
         :ok <- within_outstanding(group, operation["amount_cents"]),
         {:ok, chunks} <- HotelCredit.redeem(group, operation["amount_cents"], occurred_on) do
      RoomAccounting.allocate(group, chunks)
      group = save_group(group, RoomAccounting.totals(group))

      applied(group, %{
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: outstanding(group)
      })
    end
  end

  defp reschedule_group(group, operation, occurred_on) do
    with :ok <- required_fields(operation, ["new_arrival_on"]),
         {:ok, arrival_on} <- parse_date(operation["new_arrival_on"], "invalid_stay"),
         :ok <- future_arrival(arrival_on, occurred_on),
         {:ok, departure_on} <- shift_departure(group, arrival_on) do
      group = save_group(group, arrival_on: arrival_on, departure_on: departure_on)

      applied(group, %{
        new_arrival_on: arrival_on,
        new_departure_on: departure_on,
        policy_version: group.policy_version,
        refundable_until: refundable_until(group)
      })
    end
  end

  defp cancel_group(group, operation, occurred_on) do
    settle_rooms(group, active_room_ids(group), operation, occurred_on)
  end

  defp cancel_rooms(group, operation, occurred_on) do
    ids = operation["room_ids"]
    active_ids = active_room_ids(group)

    cond do
      not Map.has_key?(operation, "room_ids") ->
        reject("invalid_operation")

      not is_list(ids) or ids == [] ->
        reject("invalid_rooms")

      length(Enum.uniq(ids)) != length(ids) or not Enum.all?(ids, &(&1 in active_ids)) ->
        reject("invalid_rooms")

      true ->
        ordered_ids = Enum.filter(active_ids, &(&1 in ids))

        with {:ok, result} <- settle_rooms(group, ordered_ids, operation, occurred_on) do
          {:ok, Map.put(result, :cancelled_room_ids, ordered_ids)}
        end
    end
  end

  defp active_room_ids(group),
    do: for(room <- group.rooms, room.status == "active", do: room.room_id)

  defp settle_rooms(group, ids, operation, occurred_on) do
    deadline = refundable_until(group)
    refundable? = deadline != nil and Date.compare(occurred_on, deadline) != :gt
    method = Map.get(operation, "refund_method", "cash")
    selected = Enum.filter(RoomAccounting.held(group.group_id), &(&1.room_id in ids))
    {cash, credit} = Enum.split_with(selected, &is_nil(&1.credit_lot_id))
    cash_amount = RoomAccounting.total(cash)

    with :ok <- refund_method(method, refundable?),
         {:ok, expires_on} <- credit_expiry(cash_amount, method, occurred_on) do
      refunded = if refundable? and method == "cash", do: cash_amount, else: 0
      retained = if refundable?, do: 0, else: cash_amount
      converted = if method == "hotel_credit", do: cash_amount, else: 0

      issued =
        if converted > 0,
          do: HotelCredit.issue(group, cash, operation["operation_id"], expires_on),
          else: 0

      if refundable?, do: HotelCredit.restore(credit, occurred_on)

      disposition =
        cond do
          converted > 0 -> "converted_to_credit"
          refundable? -> "refunded"
          true -> "retained"
        end

      for allocation <- cash,
          do: RoomAccounting.move(allocation, allocation.amount_cents, disposition)

      for allocation <- credit do
        RoomAccounting.move(
          allocation,
          allocation.amount_cents,
          if(refundable?, do: "restored", else: "consumed")
        )
      end

      group =
        save_group(
          group,
          RoomAccounting.totals(group, ids) ++
            [
              cash_refunded_cents: group.cash_refunded_cents + refunded,
              cash_retained_cents: group.cash_retained_cents + retained,
              cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted
            ]
        )

      applied(group, %{
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: issued
      })
    end
  end

  defp update_payment(operation) do
    chargeback? = operation["type"] == "charge_back_payment"
    invalid_code = if chargeback?, do: "payment_not_chargeable", else: "payment_not_reducible"

    with {:ok, payment} <- Payments.find(operation["payment_operation_id"], invalid_code),
         {:ok, group} <- find_group(payment.result["group_id"]),
         :ok <- check_revision(group, operation),
         {:ok, _on} <- operation_date(operation) do
      allocations = Payments.allocations(payment)
      held = allocations |> Enum.filter(&(&1.disposition == "held")) |> RoomAccounting.total()

      if chargeback? do
        remaining =
          allocations |> Enum.filter(&(&1.disposition != "reduced")) |> RoomAccounting.total()

        if remaining == 0 or Enum.any?(allocations, &(&1.disposition == "charged_back")) do
          reject(invalid_code)
        else
          {changes, amount} = Payments.charge_back(payment, allocations)
          group = save_payment_groups(group, changes)

          applied(group, %{
            payment_operation_id: payment.operation_id,
            charged_back_cents: amount,
            outstanding_deposit_cents: outstanding(group)
          })
        end
      else
        with :ok <- reducible(held),
             :ok <- required_fields(operation, ["amount_cents"]),
             :ok <- payment_amount(operation["amount_cents"]),
             :ok <- within_held(held, operation["amount_cents"]) do
          group =
            save_payment_groups(group, Payments.reduce(allocations, operation["amount_cents"]))

          applied(group, %{
            payment_operation_id: payment.operation_id,
            amount_cents: operation["amount_cents"],
            outstanding_deposit_cents: outstanding(group)
          })
        end
      end
    end
  end

  defp save_payment_groups(addressed_group, changes_by_group) do
    changes_by_group
    |> Map.put_new(addressed_group.group_id, [])
    |> Map.new(fn {group_id, deltas} ->
      group =
        if group_id == addressed_group.group_id,
          do: addressed_group,
          else: Repo.get!(Group, group_id)

      changes =
        Enum.map(deltas, fn {field, delta} -> {field, Map.fetch!(group, field) + delta} end)

      {group_id, save_group(group, RoomAccounting.totals(group) ++ changes)}
    end)
    |> Map.fetch!(addressed_group.group_id)
  end

  defp reducible(held) when held > 0, do: :ok
  defp reducible(_), do: reject("payment_not_reducible")
  defp within_held(held, amount) when amount <= held, do: :ok
  defp within_held(_, _), do: reject("reduction_exceeds_held_cash")

  defp refund_method("hotel_credit", false), do: reject("refund_method_not_available")
  defp refund_method(method, _) when method in ["cash", "hotel_credit"], do: :ok
  defp refund_method(_, _), do: reject("invalid_operation")

  defp credit_expiry(cash, "hotel_credit", on) when cash > 0 do
    parse_date(Date.to_iso8601(Date.add(on, 365)), "invalid_operation")
  end

  defp credit_expiry(_, _, _), do: {:ok, nil}

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    window =
      case group.policy_version do
        "flex-14" -> 14
        "flex-30" -> 30
      end

    Date.add(group.arrival_on, -window)
  end

  defp save_group(group, changes) do
    group
    |> Ecto.Changeset.change(Keyword.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp applied(group, result) do
    {:ok, Map.merge(result, %{group_id: group.group_id, revision: group.revision})}
  end

  defp reject(code), do: {:error, %{code: code}}

  defp new_group(group_id) do
    if Repo.get(Group, group_id), do: reject("group_already_exists"), else: :ok
  end

  defp find_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> reject("group_not_found")
      group -> {:ok, group}
    end
  end

  defp check_revision(group, operation, field \\ "expected_revision") do
    if Map.has_key?(operation, field) and operation[field] !== group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: operation[field],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp required_fields(operation, fields) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)),
      do: :ok,
      else: reject("invalid_operation")
  end

  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp guest_and_property(operation) do
    if identifier?(operation["guest_id"]) and identifier?(operation["property_id"]),
      do: :ok,
      else: reject("invalid_operation")
  end

  defp operation_date(operation), do: parse_date(operation["occurred_on"], "invalid_operation")

  defp parse_date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> reject(code)
    end
  end

  defp parse_date(_, code), do: reject(code)

  defp stay(operation) do
    with {:ok, arrival_on} <- parse_date(operation["arrival_on"], "invalid_stay"),
         {:ok, departure_on} <- parse_date(operation["departure_on"], "invalid_stay") do
      if Date.compare(departure_on, arrival_on) == :gt,
        do: {:ok, {arrival_on, departure_on}},
        else: reject("invalid_stay")
    end
  end

  defp rate_plan(plan) when plan in ["flexible", "advance_purchase"], do: :ok
  defp rate_plan(_), do: reject("invalid_rate_plan")

  defp rooms(rooms, nights) when is_list(rooms) and rooms != [] do
    if Enum.all?(rooms, &valid_room?/1) and
         length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) and
         Enum.sum(Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))) <= @max_cents do
      {:ok,
       Enum.map(rooms, fn room ->
         %Room{room_id: room["room_id"], nightly_rate_cents: room["nightly_rate_cents"]}
       end)}
    else
      reject("invalid_rooms")
    end
  end

  defp rooms(_, _), do: reject("invalid_rooms")

  defp valid_room?(%{"room_id" => room_id, "nightly_rate_cents" => rate}) do
    identifier?(room_id) and is_integer(rate) and rate >= 0 and rate <= @max_cents
  end

  defp valid_room?(_), do: false

  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: reject("group_not_active")

  defp payment_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp payment_amount(_), do: reject("invalid_amount")

  defp within_outstanding(group, amount) do
    if amount <= outstanding(group), do: :ok, else: reject("payment_exceeds_outstanding")
  end

  defp future_arrival(arrival_on, occurred_on) do
    if Date.compare(arrival_on, occurred_on) == :gt, do: :ok, else: reject("invalid_stay")
  end

  defp shift_departure(group, arrival_on) do
    departure_on = Date.add(arrival_on, Date.diff(group.departure_on, group.arrival_on))

    # Date.add can produce years beyond the range accepted by ISO date parsing.
    # Reject those before persisting a date that cannot be read back by Ecto.
    parse_date(Date.to_iso8601(departure_on), "invalid_stay")
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp serialize_group(group) do
    group
    |> Map.take(@group_fields)
    |> Map.put(
      :rooms,
      Enum.map(
        group.rooms,
        &Map.take(&1, [
          :room_id,
          :nightly_rate_cents,
          :status,
          :lodging_total_cents,
          :deposit_due_cents,
          :cash_paid_cents,
          :credit_paid_cents
        ])
      )
    )
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
    |> Map.put(:refundable_until, refundable_until(group))
  end
end
