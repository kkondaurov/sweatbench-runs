defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations to groups, returning one result map per
  operation suitable for the partner batch endpoint.

  Every applied operation runs inside its own database transaction. A
  handled rejection leaves domain state unchanged but commits its durable
  idempotency record, and processing continues with the next operation.

  Operations are durably idempotent by `operation_id` since this release:
  an exact retry replays the stored result without reading or changing
  domain state, a different payload under the same identifier is rejected
  with `operation_id_conflict`, and both applied and rejected results are
  remembered in the same database transaction as their domain changes.
  Unexpected exceptions roll back everything for the current operation,
  are not remembered, and abort the HTTP request.
  """

  import Ecto.Query

  alias GroupStay.Accounting
  alias GroupStay.Bookings.Group
  alias GroupStay.Bookings.Room
  alias GroupStay.DurableOperations.OperationRecord
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Repo
  alias GroupStay.Reporting

  @operation_types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit start_finance_reporting close_finance_period)
  @payment_correction_types ~w(reduce_cash_payment charge_back_payment)
  @rate_plans Group.rate_plans()
  @refund_methods ~w(cash hotel_credit)
  @revision_not_used :revision_not_used

  defstruct [
    :type,
    :operation_id,
    :occurred_on,
    :group_id,
    :guest_id,
    :property_id,
    :arrival_on,
    :departure_on,
    :rate_plan,
    :rooms,
    :amount_cents,
    :new_arrival_on,
    :refund_method,
    :room_ids,
    :payment_operation_id,
    :source_group_id,
    :destination_group_id,
    :starts_on,
    :period_end_on,
    expected_revision: @revision_not_used,
    destination_expected_revision: @revision_not_used
  ]

  @doc """
  Applies a single raw operation and renders its result map, durably
  idempotent by `operation_id`.
  """
  def apply(raw_op) do
    # The lookup-or-insert of the durable record shares one database
    # transaction with the operation's domain changes, so retries that race
    # with the original commit see the committed record (SQLite serializes
    # writers) and effects land at most once.
    Repo.transaction(fn -> process(raw_op) end)
    |> case do
      {:ok, result} -> result
    end
  end

  defp process(raw_op) do
    operation_id = raw_identifier(raw_op)

    if recordable?(operation_id) do
      payload_json = canonical_json(raw_op)

      case record_for(operation_id) do
        %OperationRecord{} = record ->
          replay(record, payload_json, operation_id)

        nil ->
          {result, type} = execute(raw_op, operation_id)
          remember(operation_id, type, payload_json, result)
          result
      end
    else
      # Without a usable identifier there is nothing to be idempotent about;
      # behavior is unchanged from before this release.
      {result, _type} = execute(raw_op, operation_id)
      result
    end
  end

  defp recordable?(operation_id), do: is_binary(operation_id) and operation_id != ""

  defp raw_identifier(op) when is_map(op), do: Map.get(op, "operation_id")
  defp raw_identifier(_), do: nil

  # Canonical encoding of the complete submitted content: object keys are
  # sorted at every level, so object key order is not significant, while
  # array order and values remain significant.
  defp canonical_json(value)

  defp canonical_json(%{} = map) do
    pairs =
      Enum.map(map, fn {key, inner} -> {Jason.encode!(key), canonical_json(inner)} end)
      |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)

    "{" <> Enum.map_join(pairs, ",", fn {key, encoded} -> key <> ":" <> encoded end) <> "}"
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(other), do: Jason.encode!(other)

  defp record_for(operation_id) do
    Repo.one(from(r in OperationRecord, where: r.operation_id == ^operation_id))
  end

  # An equivalent retry returns the stored result verbatim — including any
  # revision or stale-revision details observed originally — without reading
  # or changing current domain state.
  defp replay(%{payload_json: stored_payload} = record, payload_json, operation_id) do
    if stored_payload == payload_json do
      Jason.decode!(record.result_json)
    else
      rejected(operation_id, :operation_id_conflict)
    end
  end

  # A handled rejection commits its own record too; an unexpected exception
  # propagates and rolls back both domain changes and any record for this
  # operation, leaving it to be processed afresh after a retry.
  defp remember(operation_id, type, payload_json, result) do
    %OperationRecord{}
    |> Ecto.Changeset.change(%{
      operation_id: operation_id,
      type: type,
      payload_json: payload_json,
      result_json: Jason.encode!(result)
    })
    |> Repo.insert!()

    :ok
  end

  ## Execution

  # Domain handlers validate before mutating, so a handled rejection returns
  # as an ordinary value — domain state is untouched and the durable record
  # commits in this same transaction. An unexpected exception (including any
  # write failure) propagates instead: the whole transaction rolls back, no
  # record is remembered, and the HTTP request aborts with 500.
  defp execute(raw_op, operation_id) do
    case parse(raw_op) do
      {:ok, cmd} ->
        cmd = %{cmd | operation_id: operation_id}

        outcome =
          case cmd.type do
            "open_group" -> open_group(cmd)
            "start_finance_reporting" -> start_finance_reporting(cmd)
            "close_finance_period" -> close_finance_period(cmd)
            "transfer_deposit" -> transfer_deposit(cmd)
            type when type in @payment_correction_types -> payment_correction(cmd)
            _ -> apply_to_group(cmd)
          end

        case outcome do
          {:ok, attrs} ->
            {applied(cmd.operation_id, attrs), cmd.type}

          {:error, {code, extra}} ->
            {rejected(cmd.operation_id, code, decorate(code, cmd, extra)), cmd.type}
        end

      {:error, code} ->
        {rejected(operation_id, code), submitted_type(raw_op)}
    end
  end

  defp submitted_type(op) when is_map(op) do
    case Map.get(op, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end

  defp submitted_type(_op), do: nil

  # `stale_revision` rejections carry the group reference shown in the API
  # document; existence is always resolved first, so the group is known here.
  # Payment corrections derive their group from the payment record and
  # already include it.
  defp decorate(:stale_revision, cmd, extra), do: Map.put_new(extra, "group_id", cmd.group_id)
  defp decorate(_code, _cmd, extra), do: extra

  defp applied(operation_id, attrs) do
    %{"operation_id" => operation_id, "status" => "applied"}
    |> Map.merge(attrs)
  end

  defp rejected(operation_id, code, extra \\ %{}) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => to_string(code)}
    |> Map.merge(extra)
  end

  ## start_finance_reporting

  # The first applied start operation enables reporting: the financial state
  # immediately before it is processed becomes the opening position on
  # `starts_on`. Reporting never addresses a group, so there is no revision
  # guard and no revision in the result. A later start is rejected even when
  # it names the same date; retrying the original identifier follows the
  # durable replay and conflict rules before this handler ever runs.
  defp start_finance_reporting(cmd) do
    case Reporting.begin_reporting(cmd.starts_on) do
      :ok ->
        {:ok, %{"starts_on" => Date.to_iso8601(cmd.starts_on)}}

      {:error, :already_started} ->
        {:error, {:reporting_already_started, %{}}}
    end
  end

  ## close_finance_period

  # A close never addresses a group, so it has no revision guard and its
  # applied result is exactly the three fields. It applies only once
  # reporting has started, on or after `starts_on`, and strictly later than
  # the latest successful close; retrying the original identifier follows
  # the durable replay and conflict rules before this handler ever runs.
  defp close_finance_period(cmd) do
    case Reporting.close_period(cmd.period_end_on) do
      :ok ->
        {:ok, %{"period_end_on" => Date.to_iso8601(cmd.period_end_on)}}

      {:error, :invalid_period} ->
        {:error, {:invalid_period, %{}}}
    end
  end

  ## Reporting movements
  #
  # Operations processed after reporting started journal one movement row
  # per finance effect on the operation's reporting posting date:
  # max(occurred_on, starts_on, day after the latest close at the moment it
  # commits). A posting date moved forward by a close is journaled as a late
  # adjustment; the posting date chosen when the operation commits is
  # permanent. Rejections journal nothing, and a durable retry replays its
  # stored result without journaling again.

  defp report_movements(cmd, movements) do
    Reporting.journal(cmd.occurred_on, movements)
  end

  defp property_of(group_id), do: Repo.get!(Group, group_id).property_id

  ## open_group

  defp open_group(cmd) do
    with {:available, false} <- {:available, group_exists?(cmd.group_id)},
         {:inserted, {:ok, group}} <- {:inserted, create_group(cmd)} do
      {:ok,
       %{
         "group_id" => group.group_id,
         "deposit_due_cents" => group.deposit_due_cents,
         "revision" => group.revision
       }}
    else
      {_tag, _other} -> {:error, {:group_already_exists, %{}}}
    end
  end

  defp group_exists?(group_id), do: is_map(Repo.get(Group, group_id))

  defp create_group(cmd) do
    nights = Date.diff(cmd.departure_on, cmd.arrival_on)

    room_deposits =
      Enum.map(cmd.rooms, fn room ->
        room_lodging = room.nightly_rate_cents * nights

        deposit =
          if cmd.rate_plan == "flexible" do
            GroupStay.flexible_room_deposit(room_lodging)
          else
            GroupStay.advance_purchase_room_deposit(room_lodging)
          end

        %{lodging: room_lodging, deposit: deposit}
      end)

    lodging_total = Enum.sum(Enum.map(room_deposits, & &1.lodging))
    deposit_due = Enum.sum(Enum.map(room_deposits, & &1.deposit))

    room_changesets =
      Enum.with_index(cmd.rooms, fn room, position ->
        %Room{}
        |> Ecto.Changeset.change(%{
          group_id: cmd.group_id,
          position: position,
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          status: "active",
          deposit_due_cents: Enum.fetch!(room_deposits, position).deposit
        })
      end)

    %Group{}
    |> Ecto.Changeset.change(%{
      group_id: cmd.group_id,
      guest_id: cmd.guest_id,
      property_id: cmd.property_id,
      booked_on: cmd.occurred_on,
      arrival_on: cmd.arrival_on,
      departure_on: cmd.departure_on,
      rate_plan: cmd.rate_plan,
      status: "active",
      revision: 1,
      lodging_total_cents: lodging_total,
      deposit_due_cents: deposit_due
    })
    |> Ecto.Changeset.put_assoc(:rooms, room_changesets)
    |> Repo.insert()
  end

  ## Operations addressed to an existing group
  #
  # Existence is resolved first, then a supplied expected_revision is compared
  # against the group's revision immediately before this operation, and only
  # then are the operation's domain rules evaluated. A rejection rolls back
  # the transaction without ever incrementing the revision.

  defp apply_to_group(cmd) do
    with {:ok, group} <- find_group(cmd.group_id),
         :current <- check_revision(group, cmd.expected_revision),
         {:ok, attrs} <- apply_domain(cmd, group) do
      {:ok, attrs}
    end
  end

  defp find_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, {:group_not_found, %{}}}
      group -> {:ok, group}
    end
  end

  defp check_revision(_group, @revision_not_used), do: :current

  defp check_revision(%Group{revision: actual}, expected) do
    if expected == actual do
      :current
    else
      {:error, {:stale_revision, %{"expected_revision" => expected, "actual_revision" => actual}}}
    end
  end

  defp apply_domain(%{type: "record_cash_payment", amount_cents: amount} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      Accounting.outstanding(group) < amount ->
        {:error, {:payment_exceeds_outstanding, %{}}}

      true ->
        {group, _chunks} =
          Accounting.allocate(group, "cash", cmd.operation_id, amount, cmd.occurred_on)

        group = bump(group, %{})

        report_movements(cmd, [
          %{scope: "cash", kind: "received", property_id: group.property_id, amount_cents: amount}
        ])

        {:ok,
         %{
           "group_id" => cmd.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => Accounting.outstanding(group),
           "revision" => group.revision
         }}
    end
  end

  defp apply_domain(%{type: "apply_hotel_credit", amount_cents: amount} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      Accounting.outstanding(group) < amount ->
        {:error, {:payment_exceeds_outstanding, %{}}}

      true ->
        # Expiry of available credit is evaluated as of the operation's date.
        case Accounting.apply_group_credit(group, cmd.occurred_on, cmd.operation_id, amount) do
          {:ok, group, lot_draws} ->
            # Applying credit redeems it into the active deposit: liability and
            # revision are the visible effects, so nothing else changes here.
            # The draws are journaled without a report movement so the expiry
            # simulation can pause each lot's balance while it funds a group.
            report_movements(
              cmd,
              for(
                {lot_id, taken} <- lot_draws,
                do: %{scope: "credit", kind: "applied", lot_id: lot_id, amount_cents: taken}
              )
            )

            group = bump(group, %{})

            {:ok,
             %{
               "group_id" => cmd.group_id,
               "amount_cents" => amount,
               "outstanding_deposit_cents" => Accounting.outstanding(group),
               "revision" => group.revision
             }}

          {:error, :insufficient_credit} ->
            {:error, {:insufficient_credit, %{}}}
        end
    end
  end

  defp apply_domain(%{type: "reschedule_group", new_arrival_on: new_arrival} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      Date.compare(new_arrival, cmd.occurred_on) != :gt ->
        {:error, {:invalid_stay, %{}}}

      true ->
        # The departure date shifts by the same number of days, so the length
        # and price of the stay do not change.
        shift = Date.diff(new_arrival, group.arrival_on)
        new_departure = Date.add(group.departure_on, shift)

        updated = bump(group, %{arrival_on: new_arrival, departure_on: new_departure})

        {:ok,
         %{
           "group_id" => cmd.group_id,
           "new_arrival_on" => Date.to_iso8601(new_arrival),
           "new_departure_on" => Date.to_iso8601(new_departure),
           # The policy version stays fixed at what the booking date implies,
           # while the refund window follows the moved arrival.
           "policy_version" => GroupStay.policy_version(group.rate_plan, group.booked_on),
           "refundable_until" =>
             GroupStay.refundable_until(group.rate_plan, group.booked_on, new_arrival),
           "revision" => updated.revision
         }}
    end
  end

  defp apply_domain(%{type: "cancel_group", refund_method: refund_method} = cmd, group) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      not refundable?(group, cmd.occurred_on) and refund_method == "hotel_credit" ->
        # Hotel credit is not a way around a non-refundable policy; the group
        # stays active and the revision does not advance.
        {:error, {:refund_method_not_available, %{}}}

      true ->
        settle_selected(cmd, group, :all)
    end
  end

  defp apply_domain(
         %{type: "cancel_rooms", room_ids: room_ids, refund_method: refund_method} = cmd,
         group
       ) do
    cond do
      group.status != "active" ->
        {:error, {:group_not_active, %{}}}

      not refundable?(group, cmd.occurred_on) and refund_method == "hotel_credit" ->
        {:error, {:refund_method_not_available, %{}}}

      true ->
        rooms = Accounting.active_rooms(group.group_id)
        by_id = Map.new(rooms, &{&1.room_id, &1})

        if Enum.all?(room_ids, &Map.has_key?(by_id, &1)) do
          settle_selected(cmd, group, room_ids)
        else
          # Every supplied identifier must name a distinct, active room of
          # the group; duplicates are already refused during parsing.
          {:error, {:invalid_rooms, %{}}}
        end
    end
  end

  # Settles the selected rooms (all active rooms for a full cancellation)
  # with the same date, policy, refund method, bonus, and restoration rules.
  # Unpaid deposit on the settled rooms ceases to be due; other rooms and
  # their allocations are unchanged. The settlement's finance effects are
  # journaled on the property where the group held and settled its cash,
  # together with the company-wide credit movements.
  defp settle_selected(cmd, group, room_ids) do
    refundable = refundable?(group, cmd.occurred_on)

    selected =
      if room_ids == :all do
        Accounting.active_rooms(group.group_id)
      else
        rooms = Accounting.active_rooms(group.group_id)
        by_id = Map.new(rooms, &{&1.room_id, &1})

        room_ids
        |> Enum.map(&Map.fetch!(by_id, &1))
        |> Enum.sort_by(& &1.position)
      end

    mode =
      cond do
        refundable and cmd.refund_method == "hotel_credit" -> :convert
        refundable -> :refund
        true -> :retain
      end

    {group, cash_total, issued, lot_id, credit_events} =
      Accounting.settle_rooms(
        group,
        selected,
        mode,
        cmd.occurred_on,
        cmd.operation_id,
        refundable
      )

    group = bump(group, %{})

    report_movements(
      cmd,
      settlement_movements(group, mode, cash_total, issued, lot_id, credit_events)
    )

    result =
      %{
        "group_id" => group.group_id,
        "refunded_cents" => if(mode == :refund, do: cash_total, else: 0),
        "retained_cents" => if(mode == :retain, do: cash_total, else: 0),
        "credit_issued_cents" => issued,
        "revision" => group.revision
      }

    result =
      if cmd.type == "cancel_rooms",
        do: Map.put(result, "cancelled_room_ids", Enum.map(selected, & &1.room_id)),
        else: result

    {:ok, result}
  end

  defp settlement_movements(group, mode, cash_total, issued, lot_id, credit_events) do
    cash_kind =
      case mode do
        :convert -> "converted_to_credit"
        :refund -> "refunded"
        :retain -> "retained"
      end

    cash_movements = [
      %{scope: "cash", kind: cash_kind, property_id: group.property_id, amount_cents: cash_total},
      %{scope: "credit", kind: "issued", lot_id: lot_id, amount_cents: issued}
    ]

    credit_movements =
      Enum.flat_map(credit_events, fn
        %{kind: :consumed, amount_cents: consumed} ->
          [%{scope: "credit", kind: "consumed", amount_cents: consumed}]

        %{kind: :restored} = event ->
          [
            %{
              scope: "credit",
              kind: "absorbed",
              lot_id: event.lot_id,
              amount_cents: event.absorbed_cents
            },
            %{
              scope: "credit",
              kind: "expired",
              lot_id: event.lot_id,
              amount_cents: event.expired_cents
            },
            # The portion that actually became available again carries no
            # report movement; it is journaled so expiry can see it return.
            %{
              scope: "credit",
              kind: "returned",
              lot_id: event.lot_id,
              amount_cents: event.returned_cents
            }
          ]
      end)

    # The `returned` rows journal only what actually became available again,
    # so the read-time expiry simulation never double-counts an excess that
    # expired immediately on restoration to an already-expired lot.
    cash_movements ++ Enum.reject(credit_movements, &(&1.amount_cents == 0))
  end

  # Refundability follows the policy version fixed by the group's booking
  # date, and cancellation on the refundable-until date itself is refundable.
  defp refundable?(group, occurred_on) do
    GroupStay.refundable?(group.rate_plan, group.booked_on, occurred_on, group.arrival_on)
  end

  ## Payment corrections
  #
  # Reduce and chargeback address one durably recorded cash payment. The
  # addressed group is the original payment's group: its record is resolved
  # first, then group existence, then the revision contract, and only then
  # the correction's domain rules. The target payment's stored result is
  # never rewritten, so retries of that payment keep their exact original
  # result.

  defp payment_correction(cmd) do
    record = record_for(cmd.payment_operation_id)

    cond do
      is_nil(record) ->
        # Legacy funding has no durable operation identity and therefore no
        # addressable record either.
        {:error, {:operation_not_found, %{}}}

      not applied_cash_payment?(record) ->
        correction_reject(cmd.type)

      true ->
        result = Jason.decode!(record.result_json)
        group = Repo.get(Group, result["group_id"])

        if is_nil(group) do
          {:error, {:group_not_found, %{}}}
        else
          case check_revision(group, cmd.expected_revision) do
            :current ->
              correction_domain(cmd, group, result)

            {:error, {code, extra}} ->
              # The correction derives its group from the payment record, so
              # the stale-revision rejection carries the group itself.
              {:error, {code, Map.put(extra, "group_id", group.group_id)}}
          end
        end
    end
  end

  defp applied_cash_payment?(record) do
    record.type == "record_cash_payment" and
      match?(
        %{"status" => "applied", "group_id" => group} when is_binary(group),
        Jason.decode!(record.result_json)
      )
  rescue
    _ -> false
  end

  defp correction_reject("reduce_cash_payment"), do: {:error, {:payment_not_reducible, %{}}}
  defp correction_reject("charge_back_payment"), do: {:error, {:payment_not_chargeable, %{}}}

  defp correction_domain(
         %{
           type: "reduce_cash_payment",
           amount_cents: amount,
           payment_operation_id: payment_operation_id
         } =
           cmd,
         group,
         _result
       ) do
    held = Accounting.held_total(payment_operation_id)

    cond do
      held == 0 ->
        {:error, {:payment_not_reducible, %{}}}

      amount > held ->
        {:error, {:reduction_exceeds_held_cash, %{}}}

      true ->
        # Held allocations are removed wherever the payment currently funds
        # rooms; every group whose funding changed advances its revision,
        # and the addressed group always does. Each removed piece journals
        # its `reduced` movement on the property where it was held.
        pieces =
          Accounting.reduce_held(payment_operation_id, amount, cmd.occurred_on, group.group_id)

        affected = Enum.map(pieces, & &1.group_id)
        group = addressed_group([group.group_id | affected], group.group_id)

        report_movements(
          cmd,
          for(
            piece <- pieces,
            do: %{
              scope: "cash",
              kind: "reduced",
              property_id: property_of(piece.group_id),
              amount_cents: piece.amount_cents
            }
          )
        )

        {:ok,
         %{
           "payment_operation_id" => payment_operation_id,
           "group_id" => group.group_id,
           "amount_cents" => amount,
           "outstanding_deposit_cents" => Accounting.outstanding(group),
           "revision" => group.revision
         }}
    end
  end

  defp correction_domain(
         %{type: "charge_back_payment", payment_operation_id: payment_operation_id} = cmd,
         group,
         result
       ) do
    charged_back = Accounting.charged_back_total(payment_operation_id)
    reduced = Accounting.reduced_total(payment_operation_id)

    cond do
      charged_back > 0 ->
        {:error, {:payment_not_chargeable, %{}}}

      result["amount_cents"] - reduced <= 0 ->
        # Every cent of the payment is already recorded as reduced.
        {:error, {:payment_not_chargeable, %{}}}

      true ->
        outcome =
          Accounting.charge_back(payment_operation_id, cmd.occurred_on, group.group_id)

        affected = outcome.affected_group_ids
        group = addressed_group([group.group_id | affected], group.group_id)

        report_movements(cmd, chargeback_movements(cmd, outcome))

        {:ok,
         %{
           "payment_operation_id" => payment_operation_id,
           "group_id" => group.group_id,
           "charged_back_cents" => outcome.charged_back_cents,
           "outstanding_deposit_cents" => Accounting.outstanding(group),
           "revision" => group.revision
         }}
    end
  end

  # A chargeback reclassifies every remaining disposition of the payment:
  # held cash journals `charged_back` on the property where it is held,
  # while refunded, retained, and converted portions reverse their prior
  # classification (negative movement) where they were settled and journal
  # `charged_back` in its place. Revoked credit entitlements journal the
  # liability they release — but only while the lot's balance still counts
  # toward liability on the posting date, and with the clawback removal
  # journaled for the expiry simulation.
  defp chargeback_movements(cmd, outcome) do
    posting = Reporting.posting_date(cmd.occurred_on)

    if posting do
      cash_movements(outcome.pieces) ++ credit_movements(outcome.revocations, posting)
    else
      []
    end
  end

  defp cash_movements(pieces) do
    Enum.flat_map(pieces, fn piece ->
      property_id = property_of(piece.group_id)

      charged_back = [
        %{
          scope: "cash",
          kind: "charged_back",
          property_id: property_id,
          amount_cents: piece.amount_cents
        }
      ]

      reversed =
        case piece.from_kind do
          # Held cash is the opening/closing balance itself; only settled
          # classifications reverse their prior movement.
          "held" ->
            []

          "converted" ->
            reversal("converted_to_credit", property_id, piece.amount_cents)

          kind ->
            reversal(kind, property_id, piece.amount_cents)
        end

      charged_back ++ reversed
    end)
  end

  defp reversal(kind, property_id, amount_cents) do
    [%{scope: "cash", kind: kind, property_id: property_id, amount_cents: -amount_cents}]
  end

  defp credit_movements(revocations, posting) do
    Enum.flat_map(revocations, fn %{lot_id: lot_id, removed_cents: removed} ->
      lot = Repo.get!(CreditLot, lot_id)

      if Date.compare(lot.expires_on, posting) != :lt do
        [
          %{scope: "credit", kind: "revoked", lot_id: lot_id, amount_cents: removed},
          %{scope: "credit", kind: "clawback_removed", lot_id: lot_id, amount_cents: removed}
        ]
      else
        []
      end
    end)
  end

  ## Deposit transfers
  #
  # A transfer moves held funding between two active groups of the same
  # guest without moving money through a provider. Source existence is
  # resolved first, then destination existence; both revisions are checked
  # before the transfer rules; neither settle nor revalue happens here, so
  # no ledger total moves — only which active rooms hold the funding.

  defp transfer_deposit(cmd) do
    source = Repo.get(Group, cmd.source_group_id)
    destination = Repo.get(Group, cmd.destination_group_id)

    cond do
      is_nil(source) ->
        {:error, {:group_not_found, %{"group_id" => cmd.source_group_id}}}

      is_nil(destination) ->
        {:error, {:group_not_found, %{"group_id" => cmd.destination_group_id}}}

      revision_mismatch?(cmd.expected_revision, source) ->
        stale_revision(source.group_id, cmd.expected_revision, source.revision)

      revision_mismatch?(cmd.destination_expected_revision, destination) ->
        stale_revision(
          destination.group_id,
          cmd.destination_expected_revision,
          destination.revision
        )

      source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
        {:error, {:invalid_transfer, %{}}}

      source.status != "active" ->
        {:error, {:group_not_active, %{"group_id" => source.group_id}}}

      destination.status != "active" ->
        {:error, {:group_not_active, %{"group_id" => destination.group_id}}}

      cmd.amount_cents <= 0 ->
        {:error, {:invalid_amount, %{}}}

      Accounting.group_held_total(source.group_id) < cmd.amount_cents ->
        {:error, {:transfer_exceeds_held_funding, %{}}}

      Accounting.outstanding(destination) < cmd.amount_cents ->
        {:error, {:transfer_exceeds_outstanding, %{}}}

      true ->
        Accounting.transfer_held(
          source.group_id,
          destination.group_id,
          cmd.amount_cents,
          cmd.occurred_on
        )

        # Both groups change state, so both revisions advance exactly once.
        [source, destination] =
          bump_groups([source.group_id, destination.group_id])

        # The moved funding leaves the source's property and enters the
        # destination's; across all properties the two amounts always match.
        report_movements(cmd, [
          %{
            scope: "cash",
            kind: "transferred_out",
            property_id: source.property_id,
            amount_cents: cmd.amount_cents
          },
          %{
            scope: "cash",
            kind: "transferred_in",
            property_id: destination.property_id,
            amount_cents: cmd.amount_cents
          }
        ])

        {:ok,
         %{
           "source_group_id" => source.group_id,
           "destination_group_id" => destination.group_id,
           "amount_cents" => cmd.amount_cents,
           "source_outstanding_deposit_cents" => Accounting.outstanding(source),
           "destination_outstanding_deposit_cents" => Accounting.outstanding(destination),
           "source_revision" => source.revision,
           "destination_revision" => destination.revision
         }}
    end
  end

  defp revision_mismatch?(@revision_not_used, _group), do: false
  defp revision_mismatch?(expected, %Group{revision: actual}), do: expected != actual

  defp stale_revision(group_id, expected, actual) do
    {:error,
     {:stale_revision,
      %{
        "group_id" => group_id,
        "expected_revision" => expected,
        "actual_revision" => actual
      }}}
  end

  # An applied operation increments the revision of every group whose state
  # it changes, and always the group it is addressed to — even when that
  # group's own allocations did not move.
  defp bump_groups(group_ids) do
    group_ids
    |> Enum.uniq()
    |> Enum.map(&Repo.get!(Group, &1))
    |> Enum.map(&Accounting.recompute_group/1)
    |> Enum.map(&bump(&1, %{}))
  end

  defp addressed_group(group_ids, addressed_id) do
    group_ids
    |> bump_groups()
    |> Enum.find(&(&1.group_id == addressed_id))
  end

  ## Parsing
  #
  # Data needed to identify and apply an operation must be present and usable;
  # anything missing is `invalid_operation`. A value that is present but
  # violates a domain rule is rejected with that rule's stable code.

  defp parse(op) when is_map(op) do
    with {:ok, type} <- parse_type(op) do
      case type do
        # Reporting starts and closes without addressing a group; neither
        # needs an `occurred_on`.
        "start_finance_reporting" -> parse_start_finance_reporting(op)
        "close_finance_period" -> parse_close_finance_period(op)
        _ -> parse_group_operation(op, type)
      end
    end
  end

  defp parse(_op), do: {:error, :invalid_operation}

  defp parse_group_operation(op, type) do
    with {:ok, occurred_on} <- common_date(op, "occurred_on") do
      case type do
        "open_group" -> parse_open_group(op, occurred_on)
        "record_cash_payment" -> parse_record_cash_payment(op, occurred_on)
        "reschedule_group" -> parse_reschedule_group(op, occurred_on)
        "cancel_group" -> parse_cancel_group(op, occurred_on)
        "apply_hotel_credit" -> parse_apply_hotel_credit(op, occurred_on)
        "cancel_rooms" -> parse_cancel_rooms(op, occurred_on)
        "reduce_cash_payment" -> parse_reduce_cash_payment(op, occurred_on)
        "charge_back_payment" -> parse_charge_back_payment(op, occurred_on)
        "transfer_deposit" -> parse_transfer_deposit(op, occurred_on)
      end
    end
  end

  # A missing or unusable `starts_on` is the reporting date's own stable
  # rejection, not a generic invalid operation.
  defp parse_start_finance_reporting(op) do
    case to_date(Map.get(op, "starts_on")) do
      %Date{} = starts_on ->
        {:ok, %__MODULE__{type: "start_finance_reporting", starts_on: starts_on}}

      _ ->
        {:error, :invalid_reporting_date}
    end
  end

  # A missing or unusable `period_end_on` cannot be compared against the
  # reporting calendar, so it takes the close's own stable rejection.
  defp parse_close_finance_period(op) do
    case to_date(Map.get(op, "period_end_on")) do
      %Date{} = period_end_on ->
        {:ok, %__MODULE__{type: "close_finance_period", period_end_on: period_end_on}}

      _ ->
        {:error, :invalid_period}
    end
  end

  defp parse_type(%{"type" => type}) when type in @operation_types, do: {:ok, type}
  defp parse_type(_op), do: {:error, :invalid_operation}

  defp common_date(op, key) do
    case to_date(Map.get(op, key)) do
      %Date{} = date -> {:ok, date}
      _ -> {:error, :invalid_operation}
    end
  end

  defp to_date(%Date{} = date), do: date

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_date(_), do: nil

  defp required_string(op, key) do
    case Map.get(op, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_operation}
    end
  end

  defp stay_date(op, key) do
    case Map.fetch(op, key) do
      :error ->
        {:error, :invalid_operation}

      {:ok, raw} when raw != nil ->
        case to_date(raw) do
          %Date{} = date -> {:ok, date}
          _ -> {:error, :invalid_stay}
        end

      {:ok, _nil} ->
        {:error, :invalid_operation}
    end
  end

  defp rate_plan(op) do
    case Map.fetch(op, "rate_plan") do
      {:ok, plan} when plan in @rate_plans -> {:ok, plan}
      {:ok, nil} -> {:error, :invalid_operation}
      {:ok, _other} -> {:error, :invalid_rate_plan}
      :error -> {:error, :invalid_operation}
    end
  end

  defp rooms(op) do
    case Map.fetch(op, "rooms") do
      :error ->
        {:error, :invalid_operation}

      {:ok, nil} ->
        {:error, :invalid_operation}

      {:ok, list} when is_list(list) and list != [] ->
        with {:ok, entries} <- room_entries(list) do
          if unique_room_ids?(entries), do: {:ok, entries}, else: {:error, :invalid_rooms}
        end

      {:ok, _other} ->
        {:error, :invalid_rooms}
    end
  end

  defp room_entries(list) do
    Enum.reduce_while(list, {:ok, []}, fn room, {:ok, acc} ->
      case room_entry(room) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp room_entry(room) when is_map(room) do
    room_id = room["room_id"]
    nightly_rate = room["nightly_rate_cents"]

    cond do
      not valid_room_id?(room_id) ->
        {:error, :invalid_rooms}

      not (is_integer(nightly_rate) and nightly_rate > 0) ->
        {:error, :invalid_rate_plan}

      true ->
        {:ok, %{room_id: room_id, nightly_rate_cents: nightly_rate}}
    end
  end

  defp room_entry(_room), do: {:error, :invalid_rooms}

  defp valid_room_id?(id), do: is_binary(id) and id != ""

  defp unique_room_ids?(rooms) do
    ids = Enum.map(rooms, & &1.room_id)
    length(ids) == length(Enum.uniq(ids))
  end

  # open_group does not use expected_revision, so it is never parsed there.

  defp parse_open_group(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, guest_id} <- required_string(op, "guest_id"),
         {:ok, property_id} <- required_string(op, "property_id"),
         {:ok, arrival_on} <- stay_date(op, "arrival_on"),
         {:ok, departure_on} <- stay_date(op, "departure_on"),
         {:ok, rate_plan} <- rate_plan(op),
         {:ok, rooms} <- rooms(op),
         :ok <- check_stay_dates(arrival_on, departure_on) do
      {:ok,
       %__MODULE__{
         type: "open_group",
         occurred_on: occurred_on,
         group_id: group_id,
         guest_id: guest_id,
         property_id: property_id,
         arrival_on: arrival_on,
         departure_on: departure_on,
         rate_plan: rate_plan,
         rooms: rooms
       }}
    end
  end

  defp check_stay_dates(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp parse_record_cash_payment(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, amount_cents} <- payment_amount(op) do
      {:ok,
       %__MODULE__{
         type: "record_cash_payment",
         occurred_on: occurred_on,
         group_id: group_id,
         amount_cents: amount_cents,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp payment_amount(op) do
    case Map.fetch(op, "amount_cents") do
      {:ok, amount} when is_integer(amount) and amount > 0 -> {:ok, amount}
      {:ok, nil} -> {:error, :invalid_operation}
      {:ok, _other} -> {:error, :invalid_amount}
      :error -> {:error, :invalid_operation}
    end
  end

  defp parse_reschedule_group(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, new_arrival_on} <- stay_date(op, "new_arrival_on") do
      {:ok,
       %__MODULE__{
         type: "reschedule_group",
         occurred_on: occurred_on,
         group_id: group_id,
         new_arrival_on: new_arrival_on,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp parse_cancel_group(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, refund_method} <- refund_method(op) do
      {:ok,
       %__MODULE__{
         type: "cancel_group",
         occurred_on: occurred_on,
         group_id: group_id,
         # Omitting the method preserves the original cash-settlement behavior.
         refund_method: refund_method,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp refund_method(op) do
    case Map.get(op, "refund_method") do
      nil -> {:ok, "cash"}
      method when method in @refund_methods -> {:ok, method}
      _other -> {:error, :invalid_operation}
    end
  end

  defp parse_apply_hotel_credit(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, amount_cents} <- payment_amount(op) do
      {:ok,
       %__MODULE__{
         type: "apply_hotel_credit",
         occurred_on: occurred_on,
         group_id: group_id,
         amount_cents: amount_cents,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp parse_cancel_rooms(op, occurred_on) do
    with {:ok, group_id} <- required_string(op, "group_id"),
         {:ok, room_ids} <- room_ids(op),
         {:ok, refund_method} <- refund_method(op) do
      {:ok,
       %__MODULE__{
         type: "cancel_rooms",
         occurred_on: occurred_on,
         group_id: group_id,
         room_ids: room_ids,
         refund_method: refund_method,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  # The room identifiers must be distinct; whether they name active rooms of
  # the group is domain validation, evaluated after group and revision.
  defp room_ids(op) do
    case Map.fetch(op, "room_ids") do
      {:ok, list} when is_list(list) and list != [] ->
        if Enum.all?(list, &valid_room_id?/1) and length(list) == length(Enum.uniq(list)),
          do: {:ok, list},
          else: {:error, :invalid_rooms}

      _other ->
        {:error, :invalid_rooms}
    end
  end

  defp parse_reduce_cash_payment(op, occurred_on) do
    with {:ok, payment_operation_id} <- required_string(op, "payment_operation_id"),
         {:ok, amount_cents} <- payment_amount(op) do
      {:ok,
       %__MODULE__{
         type: "reduce_cash_payment",
         occurred_on: occurred_on,
         payment_operation_id: payment_operation_id,
         amount_cents: amount_cents,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp parse_charge_back_payment(op, occurred_on) do
    with {:ok, payment_operation_id} <- required_string(op, "payment_operation_id") do
      {:ok,
       %__MODULE__{
         type: "charge_back_payment",
         occurred_on: occurred_on,
         payment_operation_id: payment_operation_id,
         expected_revision: supplied_revision(op)
       }}
    end
  end

  defp parse_transfer_deposit(op, occurred_on) do
    with {:ok, source_group_id} <- required_string(op, "source_group_id"),
         {:ok, destination_group_id} <- required_string(op, "destination_group_id"),
         {:ok, amount_cents} <- transfer_amount(op) do
      {:ok,
       %__MODULE__{
         type: "transfer_deposit",
         occurred_on: occurred_on,
         source_group_id: source_group_id,
         destination_group_id: destination_group_id,
         amount_cents: amount_cents,
         expected_revision: supplied_revision(op),
         destination_expected_revision: supplied_revision(op, "destination_expected_revision")
       }}
    end
  end

  # Positivity is a transfer rule evaluated after both groups exist and both
  # revisions are checked; only the value's usability is decided here.
  defp transfer_amount(op) do
    case Map.fetch(op, "amount_cents") do
      {:ok, amount} when is_integer(amount) -> {:ok, amount}
      {:ok, nil} -> {:error, :invalid_operation}
      {:ok, _other} -> {:error, :invalid_amount}
      :error -> {:error, :invalid_operation}
    end
  end

  defp supplied_revision(op, key \\ "expected_revision") do
    if Map.has_key?(op, key),
      do: Map.get(op, key),
      else: @revision_not_used
  end

  defp bump(group, changes) do
    group
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.change(revision: group.revision + 1)
    |> Repo.update!()
  end
end
