defmodule GroupStay.FinanceReporting do
  @moduledoc "Durable opening positions and signed finance movements, written with partner operations."
  import Ecto.Query
  alias GroupStay.{Repo, Group, CashAllocation, CreditAllocation, CreditLot}

  @cash ~w(received transferred_in transferred_out refunded retained converted_to_credit reduced charged_back)
  @credit ~w(issued expired consumed revoked absorbed)

  def configuration do
    Repo.one(
      from r in "finance_reporting",
        select: %{starts_on: type(r.starts_on, :date), opening: type(r.opening, :map)}
    )
  end

  def snapshot do
    properties = Map.new(Repo.all(Group), &{&1.group_id, &1.property_id})

    allocations = Repo.all(CashAllocation)

    cash =
      Enum.reduce(allocations, %{}, fn a, acc ->
        Map.update(
          acc,
          {Map.fetch!(properties, a.group_id), a.disposition},
          a.amount_cents,
          &(&1 + a.amount_cents)
        )
      end)

    applied =
      Enum.reduce(Repo.all(CreditAllocation), %{}, fn a, acc ->
        Map.update(acc, a.credit_lot_id, a.amount_cents, &(&1 + a.amount_cents))
      end)

    lots =
      Map.new(Repo.all(CreditLot), fn l ->
        {l.id,
         %{
           remaining: l.remaining_cents,
           applied: Map.get(applied, l.id, 0),
           clawback: l.unrecovered_clawback_cents,
           expiry: Date.add(l.expires_on, 1)
         }}
      end)

    held =
      Enum.reduce(allocations, %{}, fn a, acc ->
        if a.disposition == "held",
          do: Map.update(acc, a.group_id, a.amount_cents, &(&1 + a.amount_cents)),
          else: acc
      end)

    %{cash: cash, lots: lots, properties: properties, held_by_group: held}
  end

  def start(on) do
    state = snapshot()
    cash = for {{property, "held"}, amount} <- state.cash, into: %{}, do: {property, amount}
    liability = Enum.sum(for {_, lot} <- state.lots, do: liability(lot, on))

    Repo.insert_all("finance_reporting", [
      %{
        id: 1,
        starts_on: Date.to_iso8601(on),
        opening: Jason.encode!(%{cash: cash, credit: liability})
      }
    ])

    for {_, lot} <- state.lots, Date.compare(lot.expiry, on) == :gt do
      movement(lot.expiry, nil, "expired", lot.remaining)
    end

    %{starts_on: on}
  end

  def record(config, before, op) do
    after_state = snapshot()
    on = later(Date.from_iso8601!(op["occurred_on"]), config.starts_on)
    properties = Map.values(after_state.properties) |> Enum.uniq()

    for property <- properties do
      delta = fn disposition ->
        Map.get(after_state.cash, {property, disposition}, 0) -
          Map.get(before.cash, {property, disposition}, 0)
      end

      for kind <- ~w(refunded retained converted_to_credit reduced charged_back),
          do: movement(on, property, kind, delta.(kind))

      if op["type"] == "record_cash_payment",
        do: movement(on, property, "received", delta.("held"))
    end

    if op["type"] == "transfer_deposit" do
      source = before.properties[op["source_group_id"]]
      destination = before.properties[op["destination_group_id"]]
      # Cash totals by property cannot reveal a transfer within one property.
      amount = transfer_cash(op, before, after_state)
      movement(on, source, "transferred_out", amount)
      movement(on, destination, "transferred_in", amount)
    end

    consuming = op["type"] in ~w(cancel_group cancel_rooms) and not refundable?(op)

    for {id, lot} <- after_state.lots do
      old = Map.get(before.lots, id, %{remaining: 0, applied: 0, clawback: 0, expiry: lot.expiry})
      issued = if Map.has_key?(before.lots, id), do: 0, else: lot.remaining + lot.applied
      absorbed = max(old.clawback - lot.clawback, 0)

      consumed = if consuming, do: max(old.applied - lot.applied, 0), else: 0

      revoked =
        if op["type"] == "charge_back_payment" and Date.compare(on, lot.expiry) == :lt,
          do: max(old.remaining - lot.remaining, 0),
          else: 0

      # Changes in available credit adjust its scheduled expiry. If already expired
      # at posting, the residual records immediate expiry (or a signed reversal for
      # a backdated application), so every posting reconciles to dated liability.
      expired = issued - consumed - revoked - absorbed - (liability(lot, on) - liability(old, on))

      for {kind, amount} <- [
            {"issued", issued},
            {"consumed", consumed},
            {"revoked", revoked},
            {"absorbed", absorbed},
            {"expired", expired}
          ],
          do: movement(on, nil, kind, amount)

      if Date.compare(lot.expiry, on) == :gt,
        do: movement(lot.expiry, nil, "expired", lot.remaining - old.remaining)
    end
  end

  defp refundable?(op) do
    group = Repo.get!(Group, op["group_id"])

    window =
      case group.policy_version do
        "flex-14" -> 14
        "flex-30" -> 30
        _ -> nil
      end

    window != nil and
      Date.compare(Date.from_iso8601!(op["occurred_on"]), Date.add(group.arrival_on, -window)) !=
        :gt
  end

  defp transfer_cash(op, before, after_state) do
    # Snapshot includes source held cash separately to preserve gross same-property transfers.
    Map.get(before.held_by_group, op["source_group_id"], 0) -
      Map.get(after_state.held_by_group, op["source_group_id"], 0)
  end

  defp liability(lot, on),
    do: lot.applied + if(Date.compare(on, lot.expiry) == :lt, do: lot.remaining, else: 0)

  defp later(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
  defp movement(_, _, _, 0), do: :ok

  defp movement(on, property, kind, amount),
    do:
      Repo.insert_all("finance_movements", [
        %{
          posting_on: Date.to_iso8601(on),
          property_id: property,
          classification: kind,
          amount_cents: amount
        }
      ])

  def report(on) do
    Repo.transaction(fn ->
      case configuration() do
        nil ->
          {:error, "report_not_available"}

        config ->
          if Date.compare(on, config.starts_on) == :lt,
            do: {:error, "report_not_available"},
            else: {:ok, build(config, on)}
      end
    end)
    |> elem(1)
  end

  defp build(config, on) do
    rows =
      Repo.all(
        from m in "finance_movements",
          where: m.posting_on <= type(^on, :date),
          select: %{
            on: type(m.posting_on, :date),
            property: m.property_id,
            kind: m.classification,
            amount: m.amount_cents
          }
      )

    properties =
      (Map.keys(config.opening["cash"]) ++ Enum.map(rows, & &1.property))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    cash =
      for property <- properties do
        {opening, movements, closing} =
          balances(
            rows,
            property,
            on,
            Map.get(config.opening["cash"], property, 0),
            @cash,
            ~w(received transferred_in)
          )

        %{
          property_id: property,
          opening_held_cents: opening,
          movements: movements,
          closing_held_cents: closing
        }
      end
      |> Enum.reject(fn entry ->
        entry.opening_held_cents == 0 and entry.closing_held_cents == 0 and
          Enum.all?(entry.movements, fn {_, v} -> v == 0 end)
      end)

    {opening, movements, closing} =
      balances(rows, nil, on, config.opening["credit"], @credit, ~w(issued))

    %{
      date: on,
      status: "open",
      cash: cash,
      credit: %{
        opening_liability_cents: opening,
        movements: movements,
        closing_liability_cents: closing
      }
    }
  end

  defp balances(rows, property, on, initial, kinds, incoming) do
    relevant = Enum.filter(rows, &(&1.property == property))
    effect = fn row -> if row.kind in incoming, do: row.amount, else: -row.amount end

    opening =
      initial + Enum.sum(for row <- relevant, Date.compare(row.on, on) == :lt, do: effect.(row))

    movements =
      Map.new(kinds, fn kind ->
        {kind <> "_cents",
         Enum.sum(for row <- relevant, row.on == on and row.kind == kind, do: row.amount)}
      end)

    closing = opening + Enum.sum(for row <- relevant, row.on == on, do: effect.(row))
    {opening, movements, closing}
  end
end
