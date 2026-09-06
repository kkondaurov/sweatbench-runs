defmodule GroupStay.Reservations do
  @moduledoc """
  Group reservations, their deposits, and the finance totals derived from them.

  Every partner operation is applied through `apply_operation/1`, which either applies the whole
  operation or leaves the database exactly as it was.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Money
  alias GroupStay.Partner.Journal
  alias GroupStay.Partner.Operation
  alias GroupStay.Repo
  alias GroupStay.Reservations.CashAllocation
  alias GroupStay.Reservations.Credit
  alias GroupStay.Reservations.Funding
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Policy
  alias GroupStay.Reservations.Room

  @flexible_deposit_percent 20

  # These operations name a payment rather than a group: the group they address is the one the
  # payment was recorded against.
  @payment_addressed [:reduce_cash_payment, :charge_back_payment]

  @doc """
  Returns the group with the given partner identifier, with its rooms in their original order.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> Repo.preload(:rooms)
  end

  @doc """
  Cash totals across all groups, plus the credit liability as of the given date.
  """
  def ledger_totals(on) do
    cash = Funding.cash_totals()

    %{
      cash_held_cents: cash_total(cash, CashAllocation.held()),
      cash_refunded_cents: cash_total(cash, "refunded"),
      cash_retained_cents: cash_total(cash, "retained"),
      cash_converted_to_credit_cents: cash_total(cash, "converted"),
      cash_reduced_cents: cash_total(cash, "reduced"),
      cash_charged_back_cents: cash_total(cash, "charged_back"),
      credit_liability_cents: Credit.liability_cents(on),
      credit_shortfall_cents: Credit.shortfall_cents()
    }
  end

  defp cash_total(totals, status), do: Map.get(totals, status) || 0

  @doc """
  The hotel credit a guest can still spend on the given date, with its remaining lots.
  """
  def guest_credit(guest_id, on) when is_binary(guest_id), do: Credit.available(guest_id, on)

  @doc """
  Where the cash of one durably recorded payment currently sits.

  Returns `{:error, :operation_not_found}` when the identifier was never recorded, and
  `{:error, :payment_not_reconcilable}` when it names something other than an applied cash
  payment. Reading a statement never changes anything.
  """
  def payment_statement(payment_operation_id) when is_binary(payment_operation_id) do
    with {:ok, payment} <- fetch_payment(payment_operation_id, :payment_not_reconcilable) do
      dispositions = Funding.dispositions(payment_operation_id)

      # Every cent the payment recorded is sitting in exactly one of these, so what it recorded is
      # what they add up to.
      settlement = %{
        held_cents: cash_total(dispositions, CashAllocation.held()),
        refunded_cents: cash_total(dispositions, "refunded"),
        retained_cents: cash_total(dispositions, "retained"),
        converted_to_credit_cents: cash_total(dispositions, "converted"),
        reduced_cents: cash_total(dispositions, "reduced"),
        charged_back_cents: cash_total(dispositions, "charged_back")
      }

      {:ok,
       settlement
       |> Map.put(:payment_operation_id, payment_operation_id)
       |> Map.put(:original_group_id, payment.group_id)
       |> Map.put(:recorded_cents, settlement |> Map.values() |> Enum.sum())
       |> put_held_by_group(payment_operation_id)}
    end
  end

  # Cash only sits outside the group it was recorded against once a transfer has moved it, so the
  # statement only says where the held cash is once that has happened.
  defp put_held_by_group(statement, payment_operation_id) do
    if Funding.transferred?(payment_operation_id) do
      Map.put(statement, :held_by_group, Funding.held_by_group(payment_operation_id))
    else
      statement
    end
  end

  @doc """
  Applies a parsed partner operation.

  Runs inside the transaction its caller commits the operation in, and either applies the whole
  operation or leaves the database exactly as it was.

  Returns `{:ok, result}` with the fields the API reports for an applied operation, or
  `{:error, code, details}` where `details` carries any extra fields the rejection reports.
  """
  def apply_operation(%Operation{type: :open_group} = operation) do
    attempt(fn -> open_group(operation) end)
  end

  def apply_operation(%Operation{type: type} = operation) when type in @payment_addressed do
    attempt(fn ->
      # The payment is resolved first, because it is what names the group whose revision is
      # checked. A stale revision is still rejected before any rule about the payment itself.
      with {:ok, payment} <- fetch_payment(operation, target_code(type)),
           {:ok, group} <- fetch_group(payment.group_id),
           :ok <- check_revision(group, operation.expected_revision) do
        apply_to_payment(operation, payment, group)
      end
    end)
  end

  def apply_operation(%Operation{type: :transfer_deposit} = operation) do
    attempt(fn ->
      # A transfer addresses two groups, so both are resolved and then both are guarded, source
      # first, before any rule about the transfer itself.
      with {:ok, source} <- fetch_named_group(operation.group_id),
           {:ok, destination} <- fetch_named_group(operation.data["destination_group_id"]),
           :ok <- check_revision(source, operation.expected_revision),
           :ok <- check_revision(destination, operation.destination_expected_revision) do
        transfer_deposit(operation, source, destination)
      end
    end)
  end

  def apply_operation(%Operation{} = operation) do
    attempt(fn ->
      # Existence is resolved first, and a stale revision is rejected before any other domain rule.
      with {:ok, group} <- fetch_group(operation.group_id),
           :ok <- check_revision(group, operation.expected_revision) do
        apply_to_group(operation, group)
      end
    end)
  end

  defp apply_to_group(%Operation{type: :record_cash_payment} = operation, group),
    do: record_cash_payment(operation, group)

  defp apply_to_group(%Operation{type: :apply_hotel_credit} = operation, group),
    do: apply_hotel_credit(operation, group)

  defp apply_to_group(%Operation{type: :reschedule_group} = operation, group),
    do: reschedule_group(operation, group)

  defp apply_to_group(%Operation{type: :cancel_group} = operation, group),
    do: cancel_group(operation, group)

  defp apply_to_group(%Operation{type: :cancel_rooms} = operation, group),
    do: cancel_rooms(operation, group)

  defp apply_to_payment(%Operation{type: :reduce_cash_payment} = operation, payment, group),
    do: reduce_cash_payment(operation, payment, group)

  defp apply_to_payment(%Operation{type: :charge_back_payment} = operation, payment, group),
    do: charge_back_payment(operation, payment, group)

  ## Opening a group

  defp open_group(%Operation{data: data} = operation) do
    with :ok <- ensure_group_absent(operation.group_id),
         {:ok, arrival_on, departure_on, nights} <- validate_stay(data),
         {:ok, rooms} <- validate_rooms(data["rooms"]),
         {:ok, rate_plan} <- validate_rate_plan(data["rate_plan"]) do
      priced = Enum.map(rooms, &price_room(&1, nights, rate_plan))

      group =
        Repo.insert!(%Group{
          group_id: operation.group_id,
          guest_id: data["guest_id"],
          property_id: data["property_id"],
          booked_on: operation.occurred_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: rate_plan,
          # The policy the group is sold under is fixed here and never moves again.
          policy_version: Policy.version(rate_plan, operation.occurred_on),
          status: "active",
          revision: 1,
          lodging_total_cents: Enum.sum(Enum.map(priced, & &1.lodging_cents)),
          deposit_due_cents: Enum.sum(Enum.map(priced, & &1.deposit_cents)),
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          rooms: priced
        })

      {:ok,
       %{
         group_id: group.group_id,
         deposit_due_cents: group.deposit_due_cents,
         revision: group.revision
       }}
    end
  end

  defp price_room(room, nights, rate_plan) do
    lodging_cents = nights * room.nightly_rate_cents

    %Room{
      room_id: room.room_id,
      nightly_rate_cents: room.nightly_rate_cents,
      lodging_cents: lodging_cents,
      deposit_cents: room_deposit_cents(lodging_cents, rate_plan),
      position: room.position,
      status: "active"
    }
  end

  defp room_deposit_cents(lodging_cents, "advance_purchase"), do: lodging_cents

  defp room_deposit_cents(lodging_cents, "flexible"),
    do: Money.percent_of(lodging_cents, @flexible_deposit_percent)

  defp ensure_group_absent(group_id) do
    if Repo.exists?(from g in Group, where: g.group_id == ^group_id) do
      {:error, :group_already_exists}
    else
      :ok
    end
  end

  defp validate_stay(data) do
    with {:ok, arrival_on} <- parse_date(data["arrival_on"]),
         {:ok, departure_on} <- parse_date(data["departure_on"]),
         nights when nights >= 1 <- Date.diff(departure_on, arrival_on) do
      {:ok, arrival_on, departure_on, nights}
    else
      _ -> {:error, :invalid_stay}
    end
  end

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: :error

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    rooms
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {room, index}, {:ok, acc} ->
      case validate_room(room, index, acc) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_rooms(_rooms), do: {:error, :invalid_rooms}

  defp validate_room(%{"room_id" => room_id, "nightly_rate_cents" => rate}, index, seen)
       when is_binary(room_id) and is_integer(rate) and rate >= 0 do
    cond do
      String.trim(room_id) == "" -> {:error, :invalid_rooms}
      Enum.any?(seen, &(&1.room_id == room_id)) -> {:error, :invalid_rooms}
      true -> {:ok, %{room_id: room_id, nightly_rate_cents: rate, position: index}}
    end
  end

  defp validate_room(_room, _index, _seen), do: {:error, :invalid_rooms}

  defp validate_rate_plan(rate_plan) when is_binary(rate_plan) do
    if rate_plan in Group.rate_plans() do
      {:ok, rate_plan}
    else
      {:error, :invalid_rate_plan}
    end
  end

  defp validate_rate_plan(_rate_plan), do: {:error, :invalid_rate_plan}

  ## Funding a deposit

  defp record_cash_payment(%Operation{operation_id: operation_id, data: data}, group) do
    with {:ok, amount_cents} <- validate_funding(group, data["amount_cents"]) do
      # The cash is held against the rooms it funds under the payment's own identifier, which is
      # what a later reduction or chargeback names.
      Funding.allocate_cash(group, operation_id, amount_cents)

      group
      |> commit()
      |> funding_result(amount_cents)
    end
  end

  defp apply_hotel_credit(%Operation{data: data, occurred_on: occurred_on}, group) do
    with {:ok, amount_cents} <- validate_funding(group, data["amount_cents"]),
         :ok <- Credit.redeem(group, amount_cents, occurred_on) do
      group
      |> commit()
      |> funding_result(amount_cents)
    end
  end

  # Cash and credit fund the same deposit, so they share the payment validation the API describes.
  defp validate_funding(group, amount) do
    with :ok <- ensure_active(group),
         {:ok, amount_cents} <- validate_amount(amount),
         :ok <- ensure_within_outstanding(group, amount_cents) do
      {:ok, amount_cents}
    end
  end

  defp funding_result(group, amount_cents) do
    {:ok,
     %{
       group_id: group.group_id,
       amount_cents: amount_cents,
       outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
       revision: group.revision
     }}
  end

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  defp validate_amount(_amount), do: {:error, :invalid_amount}

  defp ensure_within_outstanding(group, amount_cents) do
    if amount_cents > Group.outstanding_deposit_cents(group) do
      {:error, :payment_exceeds_outstanding}
    else
      :ok
    end
  end

  ## Rescheduling

  defp reschedule_group(%Operation{data: data} = operation, group) do
    with :ok <- ensure_active(group),
         {:ok, new_arrival_on} <- validate_new_arrival(data["new_arrival_on"], operation) do
      # The stay keeps its length, so the departure moves by the same number of calendar days.
      new_departure_on = Date.add(group.departure_on, Date.diff(new_arrival_on, group.arrival_on))

      group = commit(group, arrival_on: new_arrival_on, departure_on: new_departure_on)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: group.arrival_on,
         new_departure_on: group.departure_on,
         # Moving the stay moves the refundable date with it, never the policy behind it.
         policy_version: group.policy_version,
         refundable_until: Policy.refundable_until(group),
         revision: group.revision
       }}
    end
  end

  defp validate_new_arrival(value, %Operation{occurred_on: occurred_on}) do
    case parse_date(value) do
      {:ok, new_arrival_on} ->
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          {:ok, new_arrival_on}
        else
          {:error, :invalid_stay}
        end

      _ ->
        {:error, :invalid_stay}
    end
  end

  ## Cancelling

  defp cancel_group(%Operation{} = operation, group) do
    refund_method = refund_method(operation)
    refundable? = Policy.refundable?(group, operation.occurred_on)

    with :ok <- ensure_active(group),
         :ok <- ensure_refund_method_available(refund_method, refundable?) do
      # Rooms settled earlier are already accounted for; a cancellation settles what is left.
      settlement =
        Funding.settle_rooms(
          group,
          Funding.active_rooms(group),
          refund_method,
          refundable?,
          operation
        )

      group = commit(group, status: "cancelled")

      {:ok,
       %{
         group_id: group.group_id,
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: group.revision
       }}
    end
  end

  defp cancel_rooms(%Operation{data: data} = operation, group) do
    refund_method = refund_method(operation)
    refundable? = Policy.refundable?(group, operation.occurred_on)

    with :ok <- ensure_active(group),
         {:ok, rooms} <- select_rooms(group, data["room_ids"]),
         :ok <- ensure_refund_method_available(refund_method, refundable?) do
      settlement = Funding.settle_rooms(group, rooms, refund_method, refundable?, operation)

      # A group with nothing left to stay in is cancelled by the last room that leaves it.
      group = commit(group, status: remaining_status(group))

      {:ok,
       %{
         group_id: group.group_id,
         cancelled_room_ids: Enum.map(rooms, & &1.room_id),
         refunded_cents: settlement.refunded_cents,
         retained_cents: settlement.retained_cents,
         credit_issued_cents: settlement.credit_issued_cents,
         revision: group.revision
       }}
    end
  end

  # The rooms to settle, in the group's own room order whatever order they were supplied in.
  defp select_rooms(group, room_ids) when is_list(room_ids) and room_ids != [] do
    selected = Enum.filter(Funding.active_rooms(group), &(&1.room_id in room_ids))

    if length(selected) == length(room_ids) and room_ids == Enum.uniq(room_ids) do
      {:ok, selected}
    else
      {:error, :invalid_rooms}
    end
  end

  defp select_rooms(_group, _room_ids), do: {:error, :invalid_rooms}

  # The rooms just settled are already cancelled, so what is left is what the group still holds.
  defp remaining_status(group) do
    if Funding.active_rooms(group) == [], do: "cancelled", else: "active"
  end

  defp refund_method(%Operation{data: data}), do: Map.get(data, "refund_method", "cash")

  # Hotel credit is a choice offered to a refundable guest, not a way around a non-refundable
  # policy.
  defp ensure_refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp ensure_refund_method_available(_refund_method, _refundable?), do: :ok

  ## Transferring a deposit

  defp transfer_deposit(%Operation{data: data}, source, destination) do
    with :ok <- ensure_transferable(source, destination),
         :ok <- ensure_named_group_active(source),
         :ok <- ensure_named_group_active(destination),
         {:ok, amount_cents} <- validate_amount(data["amount_cents"]),
         :ok <- ensure_within_held_funding(source, amount_cents),
         :ok <- ensure_within_destination_outstanding(destination, amount_cents) do
      Funding.transfer(source, destination, amount_cents)

      # The transfer changes what both groups hold, so both of them move on a revision.
      source = commit(source)
      destination = commit(destination)

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: amount_cents,
         source_outstanding_deposit_cents: Group.outstanding_deposit_cents(source),
         destination_outstanding_deposit_cents: Group.outstanding_deposit_cents(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  # A transfer moves a deposit between two reservations of one guest. Moving funding to the same
  # group, or to another guest's group, is not something the partner can mean.
  defp ensure_transferable(%Group{id: id}, %Group{id: id}), do: {:error, :invalid_transfer}

  defp ensure_transferable(source, destination) do
    if source.guest_id == destination.guest_id, do: :ok, else: {:error, :invalid_transfer}
  end

  # Held funding is the cash and hotel credit currently allocated to the group's active rooms,
  # which is exactly what its rooms report as paid.
  defp ensure_within_held_funding(source, amount_cents) do
    if amount_cents > Group.deposit_paid_cents(source) do
      {:error, :transfer_exceeds_held_funding}
    else
      :ok
    end
  end

  defp ensure_within_destination_outstanding(destination, amount_cents) do
    if amount_cents > Group.outstanding_deposit_cents(destination) do
      {:error, :transfer_exceeds_outstanding}
    else
      :ok
    end
  end

  ## Correcting a recorded payment

  defp reduce_cash_payment(%Operation{data: data}, payment, group) do
    held_cents = Funding.held_cash_cents(payment.operation_id)

    with :ok <- ensure_reducible(held_cents),
         {:ok, amount_cents} <- validate_amount(data["amount_cents"]),
         :ok <- ensure_within_held(held_cents, amount_cents) do
      # A payment's cash can have been transferred, so a reduction can reopen the deposit of a
      # group the request never named. Every group it changes moves on a revision; the result
      # reports the one the operation addressed.
      group = payment.operation_id |> Funding.reduce(amount_cents) |> commit_all(group)

      {:ok,
       %{
         payment_operation_id: payment.operation_id,
         group_id: group.group_id,
         amount_cents: amount_cents,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  # Cash that has already been refunded, retained, converted, or reduced is settled history: a
  # payment with nothing held can never accept a reduction, whatever amount is asked for.
  defp ensure_reducible(0), do: {:error, :payment_not_reducible}
  defp ensure_reducible(_held_cents), do: :ok

  defp ensure_within_held(held_cents, amount_cents) do
    if amount_cents > held_cents, do: {:error, :reduction_exceeds_held_cash}, else: :ok
  end

  defp charge_back_payment(%Operation{}, payment, group) do
    with :ok <- ensure_chargeable(Funding.reversible_cash_cents(payment.operation_id)) do
      {charged_back_cents, held_group_ids} = Funding.charge_back(payment.operation_id)
      group = commit_all(held_group_ids, group)

      {:ok,
       %{
         payment_operation_id: payment.operation_id,
         group_id: group.group_id,
         charged_back_cents: charged_back_cents,
         outstanding_deposit_cents: Group.outstanding_deposit_cents(group),
         revision: group.revision
       }}
    end
  end

  # A payment that has already been charged back, or reduced away entirely, has no disposition
  # left to reverse.
  defp ensure_chargeable(0), do: {:error, :payment_not_chargeable}
  defp ensure_chargeable(_reversible_cents), do: :ok

  defp target_code(:reduce_cash_payment), do: :payment_not_reducible
  defp target_code(:charge_back_payment), do: :payment_not_chargeable

  # Only a durably recorded, applied cash payment can be corrected. Funding from before durable
  # records has no operation identity at all, so nothing can name it.
  defp fetch_payment(%Operation{data: data}, code),
    do: fetch_payment(data["payment_operation_id"], code)

  defp fetch_payment(payment_operation_id, _code) when not is_binary(payment_operation_id),
    do: {:error, :operation_not_found}

  defp fetch_payment(payment_operation_id, code) do
    with {:ok, record} <- Journal.fetch(payment_operation_id),
         result = Journal.decode_result(record),
         true <- record.type == "record_cash_payment" and result["status"] == "applied" do
      {:ok, %{operation_id: payment_operation_id, group_id: result["group_id"]}}
    else
      :error -> {:error, :operation_not_found}
      false -> {:error, code}
    end
  end

  ## Shared group handling

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  # An operation addressing more than one group has to say which of them a rejection is about.
  defp fetch_named_group(group_id) do
    with {:error, :group_not_found} <- fetch_group(group_id) do
      {:error, {:group_not_found, %{group_id: group_id}}}
    end
  end

  defp check_revision(_group, nil), do: :ok

  defp check_revision(%Group{revision: revision}, expected) when revision == expected, do: :ok

  defp check_revision(%Group{} = group, expected) do
    {:error,
     {:stale_revision,
      %{
        group_id: group.group_id,
        expected_revision: expected,
        actual_revision: group.revision
      }}}
  end

  defp ensure_active(group) do
    if Group.active?(group), do: :ok, else: {:error, :group_not_active}
  end

  # A rejection about one of two addressed groups has to say which of them it is about.
  defp ensure_named_group_active(group) do
    with {:error, :group_not_active} <- ensure_active(group) do
      {:error, {:group_not_active, %{group_id: group.group_id}}}
    end
  end

  # Every applied operation addressed to an existing group increments its revision exactly once,
  # even when it leaves the visible booking fields alone. The group's totals are a projection of
  # its rooms, so they are brought back into step before the operation reports its outcome.
  defp commit(group, changes \\ []) do
    Funding.refresh(group)

    Group
    |> Repo.get!(group.id)
    |> change(changes)
    |> Repo.update!()
  end

  # Every group an operation changed moves on a revision, and the group it addressed does so even
  # when the operation left it alone. The addressed group is the one whose revision is reported.
  defp commit_all(group_ids, addressed) do
    for id <- Enum.sort(group_ids), id != addressed.id do
      Group |> Repo.get!(id) |> commit()
    end

    commit(addressed)
  end

  # The revision is also the optimistic lock, so the write refuses to run over a row that moved
  # underneath it. Forcing the revision change keeps `Repo.update` from skipping an otherwise
  # empty update.
  defp change(group, changes) do
    group
    |> Changeset.change(changes)
    |> Changeset.optimistic_lock(:revision)
    |> Changeset.force_change(:revision, group.revision + 1)
  end

  ## Applying an operation

  # An operation is applied whole or not at all, so a rejection leaves the database exactly as it
  # was. The undo is a savepoint rather than the surrounding transaction, because that transaction
  # also carries the operation's durable record: a rejected operation must still be remembered.
  defp attempt(fun) do
    Repo.query!("SAVEPOINT operation")

    case fun.() do
      {:ok, result} ->
        Repo.query!("RELEASE SAVEPOINT operation")
        {:ok, result}

      {:error, reason} ->
        Repo.query!("ROLLBACK TO SAVEPOINT operation")
        Repo.query!("RELEASE SAVEPOINT operation")
        rejection(reason)
    end
  end

  defp rejection({code, details}), do: {:error, code, details}
  defp rejection(code), do: {:error, code, %{}}
end
