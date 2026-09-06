defmodule GroupStay.Reservations do
  @moduledoc """
  Group reservations, their deposits, and the finance totals derived from them.

  Every partner operation is applied through `apply_operation/1`, which either applies the whole
  operation or leaves the database exactly as it was.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Money
  alias GroupStay.Partner.Operation
  alias GroupStay.Repo
  alias GroupStay.Reservations.Credit
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Policy
  alias GroupStay.Reservations.Room

  @flexible_deposit_percent 20

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
    active = from(g in Group, where: g.status == "active")

    %{
      cash_held_cents: sum_of(active, :cash_paid_cents),
      cash_refunded_cents: sum_of(Group, :cash_refunded_cents),
      cash_retained_cents: sum_of(Group, :cash_retained_cents),
      cash_converted_to_credit_cents: sum_of(Group, :cash_converted_to_credit_cents),
      credit_liability_cents: Credit.liability_cents(on)
    }
  end

  defp sum_of(queryable, field), do: Repo.aggregate(queryable, :sum, field) || 0

  @doc """
  The hotel credit a guest can still spend on the given date, with its remaining lots.
  """
  def guest_credit(guest_id, on) when is_binary(guest_id), do: Credit.available(guest_id, on)

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
      position: room.position
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

  defp record_cash_payment(%Operation{data: data}, group) do
    with {:ok, amount_cents} <- validate_funding(group, data["amount_cents"]) do
      group
      |> change(cash_paid_cents: group.cash_paid_cents + amount_cents)
      |> Repo.update!()
      |> funding_result(amount_cents)
    end
  end

  defp apply_hotel_credit(%Operation{data: data, occurred_on: occurred_on}, group) do
    with {:ok, amount_cents} <- validate_funding(group, data["amount_cents"]),
         :ok <- Credit.redeem(group, amount_cents, occurred_on) do
      group
      |> change(credit_paid_cents: group.credit_paid_cents + amount_cents)
      |> Repo.update!()
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

      group =
        group
        |> change(arrival_on: new_arrival_on, departure_on: new_departure_on)
        |> Repo.update!()

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
    refund_method = Map.get(operation.data, "refund_method", "cash")
    refundable? = Policy.refundable?(group, operation.occurred_on)

    with :ok <- ensure_active(group),
         :ok <- ensure_refund_method_available(refund_method, refundable?) do
      {cash_settlement, credit_issued_cents} =
        settle_cash(group, refund_method, refundable?, operation)

      settle_credit(group, refundable?, operation.occurred_on)

      group =
        group
        |> change(Map.put(cash_settlement, :status, "cancelled"))
        |> Repo.update!()

      {:ok,
       %{
         group_id: group.group_id,
         refunded_cents: group.cash_refunded_cents,
         retained_cents: group.cash_retained_cents,
         credit_issued_cents: credit_issued_cents,
         revision: group.revision
       }}
    end
  end

  # Hotel credit is a choice offered to a refundable guest, not a way around a non-refundable
  # policy.
  defp ensure_refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp ensure_refund_method_available(_refund_method, _refundable?), do: :ok

  # Only cash settles: it is refunded, converted to credit, or retained. Returns the totals the
  # group records and the credit the cancellation issued, which the lot itself carries.
  defp settle_cash(group, "hotel_credit", true, operation) do
    cash_cents = group.cash_paid_cents

    credit_issued_cents =
      Credit.issue(group, cash_cents, operation.operation_id, operation.occurred_on)

    {%{
       cash_refunded_cents: 0,
       cash_retained_cents: 0,
       cash_converted_to_credit_cents: cash_cents
     }, credit_issued_cents}
  end

  defp settle_cash(group, _refund_method, refundable?, _operation) do
    refunded_cents = if refundable?, do: group.cash_paid_cents, else: 0

    {%{
       cash_refunded_cents: refunded_cents,
       cash_retained_cents: group.cash_paid_cents - refunded_cents,
       cash_converted_to_credit_cents: 0
     }, 0}
  end

  # Credit that funded the group goes back to the lots it came from when the guest is still
  # entitled to a refund, and is kept by the hotel when they are not.
  defp settle_credit(group, true, occurred_on), do: Credit.restore(group, occurred_on)
  defp settle_credit(group, false, _occurred_on), do: Credit.consume(group)

  ## Shared group handling

  defp fetch_group(group_id) do
    case Repo.get_by(Group, group_id: group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
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

  # Every applied operation addressed to an existing group increments its revision exactly once,
  # even when it leaves the visible booking fields alone. The revision is also the optimistic lock,
  # so the write refuses to run over a row that moved underneath it. Forcing the revision change
  # keeps `Repo.update` from skipping an otherwise empty update.
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
