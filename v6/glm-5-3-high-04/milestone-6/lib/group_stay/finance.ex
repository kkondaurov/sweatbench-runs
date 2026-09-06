defmodule GroupStay.Finance do
  @moduledoc """
  The daily finance report and the posting-date accounting behind it.

  Every applied partner operation that moves held cash or hotel-credit
  liability records signed finance movements, in the same transaction as its
  domain changes. The posting date of an operation processed after reporting
  starts is the later of its `occurred_on` and `starts_on`, and all finance
  effects of that operation use the same posting date, so a later submission
  can change an earlier open report.

  Movements are also recorded for operations processed before reporting
  starts. Those movements never appear in a report — the opening position
  captured by the start operation already contains their effects — but they
  keep the per-property attribution of every payment's settled cash, so a
  later chargeback reverses a disposition at the property where it settled
  instead of the payment's original property.

  Reading reports is pure: reports are computed from the stored movements,
  the opening position, and the current credit lots, and never change a
  report or any domain state.
  """

  import Ecto.Query

  alias GroupStay.Credit.Lot
  alias GroupStay.Finance.CashOpening
  alias GroupStay.Finance.Movement
  alias GroupStay.Finance.Reporting
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @cash_classifications ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)

  @doc """
  True once the first `start_finance_reporting` operation has been applied.
  """
  def reporting_started?, do: Repo.exists?(Reporting)

  @doc """
  Starts finance reporting: snapshots the opening position as the financial
  state of this moment and records the movement floor. Runs inside the start
  operation's transaction.
  """
  def start_reporting!(starts_on) do
    floor_id = Repo.one(from m in Movement, select: coalesce(max(m.id), 0))

    openings =
      Repo.all(
        from g in Group,
          where: g.status == "active",
          group_by: g.property_id,
          select: {g.property_id, coalesce(sum(g.deposit_paid_cents - g.credit_paid_cents), 0)}
      )

    # Lot balances whose expiry is still reportable: a lot leaves the
    # liability through an expiry movement on the date after its expires_on,
    # so lots expiring on or after starts_on are part of the opening
    # position and expire within the reports. Credit applied to active
    # groups counts regardless of its lot's expiry.
    lot_cents =
      Repo.one(
        from l in Lot,
          where: l.expires_on >= ^starts_on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied_cents =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.credit_paid_cents), 0)
      )

    Repo.insert!(%Reporting{
      id: 1,
      starts_on: starts_on,
      opening_credit_liability_cents: lot_cents + applied_cents,
      movement_floor_id: floor_id
    })

    Enum.each(openings, fn {property_id, opening_held_cents} ->
      Repo.insert!(%CashOpening{property_id: property_id, opening_held_cents: opening_held_cents})
    end)

    :ok
  end

  # The posting date of an operation: after reporting starts, the later of
  # its occurred_on and starts_on; before that, its occurred_on (those
  # movements only serve payment attribution).
  defp posting_date(occurred_on) do
    case Repo.one(Reporting) do
      nil -> occurred_on
      %Reporting{starts_on: starts_on} -> later_of(occurred_on, starts_on)
    end
  end

  defp later_of(a, b), do: if(Date.compare(a, b) == :gt, do: a, else: b)

  # Recording movements

  @doc """
  Cash received through one recorded payment, at the paying group's
  property.
  """
  def record_cash_payment!(property_id, operation_id, amount_cents, occurred_on) do
    insert!(posting_date(occurred_on), "cash", "received", amount_cents, %{
      property_id: property_id,
      operation_id: operation_id,
      payment_operation_id: operation_id
    })
  end

  @doc """
  The finance effects of one settlement (a full cancellation or selected
  rooms): each payment's cash disposition, at the settled group's property,
  and the company-wide credit effects of the settlement.
  """
  def record_settlement!(property_id, operation_id, effects, occurred_on) do
    posted_on = posting_date(occurred_on)

    Enum.each(effects.cash, fn %{
                                 payment_operation_id: payment_id,
                                 classification: classification,
                                 amount_cents: amount_cents
                               } ->
      insert!(posted_on, "cash", classification, amount_cents, %{
        property_id: property_id,
        operation_id: operation_id,
        payment_operation_id: payment_id
      })
    end)

    credit = effects.credit

    if credit.issued_cents > 0 do
      insert!(posted_on, "credit", "issued", credit.issued_cents, %{
        operation_id: operation_id,
        credit_lot_id: credit.issued_lot_id
      })
    end

    if credit.consumed_cents > 0 do
      insert!(posted_on, "credit", "consumed", credit.consumed_cents, %{
        operation_id: operation_id
      })
    end

    if credit.absorbed_cents > 0 do
      insert!(posted_on, "credit", "absorbed", credit.absorbed_cents, %{
        operation_id: operation_id
      })
    end

    # Credit restored to a lot whose expiry had already passed leaves the
    # liability: it expires immediately.
    if credit.expired_cents > 0 do
      insert!(posted_on, "credit", "expired", credit.expired_cents, %{operation_id: operation_id})
    end

    :ok
  end

  @doc """
  The cash portion of one deposit transfer: it leaves the source group's
  property and enters the destination group's property in equal amounts.
  """
  def record_transfer!(
        source_property_id,
        destination_property_id,
        operation_id,
        cash_cents,
        occurred_on
      ) do
    if cash_cents > 0 do
      posted_on = posting_date(occurred_on)

      insert!(posted_on, "cash", "transferred_out", cash_cents, %{
        property_id: source_property_id,
        operation_id: operation_id
      })

      insert!(posted_on, "cash", "transferred_in", cash_cents, %{
        property_id: destination_property_id,
        operation_id: operation_id
      })
    end

    :ok
  end

  @doc """
  One provider correction, at each property whose held cash it removed.
  """
  def record_reduction!(per_property, payment_operation_id, operation_id, occurred_on) do
    posted_on = posting_date(occurred_on)

    Enum.each(per_property, fn {property_id, amount_cents} ->
      insert!(posted_on, "cash", "reduced", amount_cents, %{
        property_id: property_id,
        operation_id: operation_id,
        payment_operation_id: payment_operation_id
      })
    end)

    :ok
  end

  @doc """
  One chargeback. Held cash becomes charged back at each property where it
  is held. Earlier refunded, retained, and converted dispositions reverse at
  the properties where they settled — with any portion settled before this
  release, whose property is unknown, reversed at the payment's original
  property. Revoked entitlements leave the credit liability.
  """
  def record_chargeback!(
        fallback_property_id,
        payment_operation_id,
        operation_id,
        info,
        occurred_on
      ) do
    posted_on = posting_date(occurred_on)

    Enum.each(info.held_removed, fn {property_id, amount_cents} ->
      insert!(posted_on, "cash", "charged_back", amount_cents, %{
        property_id: property_id,
        operation_id: operation_id,
        payment_operation_id: payment_operation_id
      })
    end)

    attribution = settlement_attribution(payment_operation_id)

    for {classification, total_cents} <- [
          {"refunded", info.refunded_cents},
          {"retained", info.retained_cents},
          {"converted_to_credit", info.converted_cents}
        ] do
      per_property = Map.get(attribution, classification, %{})
      attributed_cents = Enum.sum(Map.values(per_property))

      reversals =
        Map.to_list(per_property) ++
          if attributed_cents < total_cents,
            do: [{fallback_property_id, total_cents - attributed_cents}],
            else: []

      Enum.each(reversals, fn {property_id, amount_cents} ->
        insert!(posted_on, "cash", classification, -amount_cents, %{
          property_id: property_id,
          operation_id: operation_id,
          payment_operation_id: payment_operation_id
        })

        insert!(posted_on, "cash", "charged_back", amount_cents, %{
          property_id: property_id,
          operation_id: operation_id,
          payment_operation_id: payment_operation_id
        })
      end)
    end

    Enum.each(info.entitlement_removals, fn removal ->
      if removal.amount_cents > 0 do
        insert!(posted_on, "credit", "revoked", removal.amount_cents, %{
          operation_id: operation_id,
          payment_operation_id: payment_operation_id,
          credit_lot_id: removal.credit_lot_id
        })
      end
    end)

    :ok
  end

  # The properties where one payment's cash settled, per disposition
  # classification, from the movements recorded for its settlements.
  defp settlement_attribution(payment_operation_id) do
    Repo.all(
      from m in Movement,
        where:
          m.payment_operation_id == ^payment_operation_id and m.kind == "cash" and
            m.classification in ~w(refunded retained converted_to_credit),
        group_by: [m.classification, m.property_id],
        select: {m.classification, m.property_id, coalesce(sum(m.amount_cents), 0)}
    )
    |> Enum.reduce(%{}, fn {classification, property_id, amount_cents}, acc ->
      Map.update(acc, classification, %{property_id => amount_cents}, fn properties ->
        Map.update(properties, property_id, amount_cents, &(&1 + amount_cents))
      end)
    end)
  end

  defp insert!(posted_on, kind, classification, amount_cents, attrs) do
    Repo.insert!(%Movement{
      posted_on: posted_on,
      kind: kind,
      classification: classification,
      amount_cents: amount_cents,
      property_id: Map.get(attrs, :property_id),
      operation_id: Map.get(attrs, :operation_id),
      payment_operation_id: Map.get(attrs, :payment_operation_id),
      credit_lot_id: Map.get(attrs, :credit_lot_id)
    })
  end

  # Reading one day

  @doc """
  The daily finance report for `date`.

  Returns `{:error, :report_not_available}` before reporting has started or
  for a date before `starts_on`. Reading a report never changes a report or
  any domain state.
  """
  def daily_report(date) do
    case Repo.one(Reporting) do
      nil ->
        {:error, :report_not_available}

      %Reporting{} = reporting ->
        if Date.compare(date, reporting.starts_on) == :lt do
          {:error, :report_not_available}
        else
          {:ok, build_report(reporting, date)}
        end
    end
  end

  defp build_report(reporting, date) do
    movements =
      Repo.all(from m in Movement, where: m.id > ^reporting.movement_floor_id)

    prior_movements =
      Enum.filter(movements, fn movement -> Date.compare(movement.posted_on, date) == :lt end)

    today_movements =
      Enum.filter(movements, fn movement -> Date.compare(movement.posted_on, date) == :eq end)

    openings =
      Repo.all(from(o in CashOpening))
      |> Map.new(&{&1.property_id, &1.opening_held_cents})

    %{
      "date" => Date.to_iso8601(date),
      "status" => "open",
      "cash" => cash_entries(prior_movements, today_movements, openings),
      "credit" => credit_entry(reporting, prior_movements, today_movements, date)
    }
  end

  # One cash entry per property that has a nonzero opening balance, closing
  # balance, or movement on the date, ordered by property_id. A day opens
  # where the previous day closed: the opening balance is the opening
  # position plus every movement posted before the date.
  defp cash_entries(prior_movements, today_movements, openings) do
    prior_net = net_cash_per_property(prior_movements)
    today_sums = sums_per_property(today_movements)

    (Map.keys(openings) ++ Map.keys(prior_net) ++ Map.keys(today_sums))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn property_id ->
      opening = Map.get(openings, property_id, 0) + Map.get(prior_net, property_id, 0)
      sums = Map.get(today_sums, property_id, %{})

      movements_map =
        Map.new(@cash_classifications, fn classification ->
          {classification <> "_cents", Map.get(sums, classification, 0)}
        end)

      {property_id, opening, movements_map, opening + net_cash_cents(sums)}
    end)
    |> Enum.reject(fn {_property_id, opening, movements_map, closing} ->
      opening == 0 and closing == 0 and Enum.all?(Map.values(movements_map), &(&1 == 0))
    end)
    |> Enum.map(fn {property_id, opening, movements_map, closing} ->
      %{
        "property_id" => property_id,
        "opening_held_cents" => opening,
        "movements" => movements_map,
        "closing_held_cents" => closing
      }
    end)
  end

  defp sums_per_property(movements) do
    movements
    |> Enum.filter(&(&1.kind == "cash"))
    |> Enum.group_by(& &1.property_id)
    |> Map.new(fn {property_id, property_movements} ->
      {property_id, classification_sums(property_movements)}
    end)
  end

  defp net_cash_per_property(movements) do
    movements
    |> sums_per_property()
    |> Map.new(fn {property_id, sums} -> {property_id, net_cash_cents(sums)} end)
  end

  defp classification_sums(movements) do
    movements
    |> Enum.group_by(& &1.classification, & &1.amount_cents)
    |> Map.new(fn {classification, amounts} -> {classification, Enum.sum(amounts)} end)
  end

  defp net_cash_cents(sums) do
    Map.get(sums, "received", 0) + Map.get(sums, "transferred_in", 0) -
      Map.get(sums, "transferred_out", 0) - Map.get(sums, "refunded", 0) -
      Map.get(sums, "retained", 0) - Map.get(sums, "converted_to_credit", 0) -
      Map.get(sums, "reduced", 0) - Map.get(sums, "charged_back", 0)
  end

  # The company-wide credit object. Applying or restoring credit has no
  # movement; liability leaves through expiry, consumption, revocation, or
  # shortfall absorption, and enters when issued.
  defp credit_entry(reporting, prior_movements, today_movements, date) do
    lots =
      Repo.all(from(l in Lot))
      |> Map.new(&{&1.id, &1})

    expiries = derived_expiries(reporting, prior_movements ++ today_movements, lots)

    opening_net =
      credit_net(prior_movements, expiries, lots, fn expiry_date ->
        Date.compare(expiry_date, date) == :lt
      end)

    today_net =
      credit_net(today_movements, expiries, lots, fn expiry_date ->
        Date.compare(expiry_date, date) == :eq
      end)

    today_sums = classification_sums(Enum.filter(today_movements, &(&1.kind == "credit")))

    movements_map = %{
      "issued_cents" => Map.get(today_sums, "issued", 0),
      "expired_cents" => Map.get(today_sums, "expired", 0) + today_net[:expired],
      "consumed_cents" => Map.get(today_sums, "consumed", 0),
      "revoked_cents" => visible_revoked_cents(today_movements, lots),
      "absorbed_cents" => Map.get(today_sums, "absorbed", 0)
    }

    %{
      "opening_liability_cents" => reporting.opening_credit_liability_cents + opening_net.total,
      "movements" => movements_map,
      "closing_liability_cents" =>
        reporting.opening_credit_liability_cents + opening_net.total + today_net.total
    }
  end

  # The net credit-liability change of a set of movements together with the
  # derived expiries whose date satisfies `range`, as
  # issued - expired - consumed - revoked - absorbed.
  defp credit_net(movements, expiries, lots, range) do
    sums = classification_sums(Enum.filter(movements, &(&1.kind == "credit")))

    expired_cents =
      expiries
      |> Enum.filter(fn {expiry_date, _amount_cents} -> range.(expiry_date) end)
      |> Enum.sum_by(fn {_expiry_date, amount_cents} -> amount_cents end)

    total_cents =
      Map.get(sums, "issued", 0) - Map.get(sums, "expired", 0) - Map.get(sums, "consumed", 0) -
        visible_revoked_cents(movements, lots) - Map.get(sums, "absorbed", 0) - expired_cents

    %{expired: expired_cents, total: total_cents}
  end

  # A revocation whose posting date is on or after the day after the lot's
  # expires_on removed balance that had already left the liability through
  # expiry: it has no revoked movement and folds into the derived expiry of
  # that date instead.
  defp visible_revoked_cents(movements, lots) do
    movements
    |> Enum.filter(&(&1.kind == "credit" and &1.classification == "revoked"))
    |> Enum.filter(fn movement ->
      case lots[movement.credit_lot_id] do
        %Lot{} = lot ->
          Date.compare(movement.posted_on, Date.add(lot.expires_on, 1)) == :lt

        nil ->
          true
      end
    end)
    |> Enum.sum_by(& &1.amount_cents)
  end

  # Credit that remains unused through its expires_on date expires on the
  # following date, even when no partner operation was submitted that day.
  # The expired amount is the lot's balance of that date: the current
  # balance plus any revocations posted on or after the expiry date, since
  # those removed balance that had already expired and left the liability
  # through this expiry.
  defp derived_expiries(reporting, movements, lots) do
    issued_lot_ids =
      movements
      |> Enum.filter(&(&1.kind == "credit" and &1.classification == "issued"))
      |> MapSet.new(& &1.credit_lot_id)

    revoked =
      Enum.filter(movements, &(&1.kind == "credit" and &1.classification == "revoked"))

    lots
    |> Map.values()
    |> Enum.map(fn lot ->
      expiry_date = lot_expiry_date(reporting, lot, issued_lot_ids)

      if expiry_date do
        expiry_day = Date.add(lot.expires_on, 1)

        removed_after =
          revoked
          |> Enum.filter(fn movement ->
            movement.credit_lot_id == lot.id and
              Date.compare(movement.posted_on, expiry_day) != :lt
          end)
          |> Enum.sum_by(& &1.amount_cents)

        {expiry_date, lot.remaining_cents + removed_after}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn {_expiry_date, amount_cents} -> amount_cents == 0 end)
  end

  # The date a lot's remaining balance expires within the reports. A lot
  # whose expires_on is on or after starts_on was part of the opening
  # position and expires on the following date. A lot issued after reporting
  # started whose credit was already expired when issued never enters the
  # reported liability: its issuance and its expiry both post on starts_on.
  # A lot expired before reporting started that was not issued after the
  # start never appears in a report.
  defp lot_expiry_date(reporting, lot, issued_lot_ids) do
    if Date.compare(lot.expires_on, reporting.starts_on) != :lt do
      Date.add(lot.expires_on, 1)
    else
      if MapSet.member?(issued_lot_ids, lot.id), do: reporting.starts_on
    end
  end
end
