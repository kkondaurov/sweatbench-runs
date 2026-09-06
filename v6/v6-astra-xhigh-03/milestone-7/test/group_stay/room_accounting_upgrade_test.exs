defmodule GroupStay.RoomAccountingUpgradeTest do
  use ExUnit.Case, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{Operation, Repo}
  @moduletag :tmp_dir
  @migrations [
    {20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_905_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics},
    {20_260_905_000_002, GroupStay.Repo.Migrations.CreateOperations},
    {20_260_905_000_003, GroupStay.Repo.Migrations.AddRoomAccounting},
    {20_260_905_000_004, GroupStay.Repo.Migrations.AddDepositTransfers},
    {20_260_905_000_005, GroupStay.Repo.Migrations.AddFinanceReporting},
    {20_260_905_000_006, GroupStay.Repo.Migrations.AddFinancePeriodClose}
  ]

  setup_all do
    for {version, module} <- @migrations, not Code.ensure_loaded?(module) do
      [path] = Path.wildcard("priv/repo/migrations/#{version}_*.exs")
      Code.require_file(path)
    end

    :ok
  end

  setup %{tmp_dir: directory} do
    options = [
      name: __MODULE__,
      database: Path.join(directory, "upgrade.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    start_supervised!(Supervisor.child_spec({Repo, options}, id: __MODULE__))
    Repo.put_dynamic_repo(__MODULE__)
    Ecto.Migrator.run(Repo, @migrations, :up, to: 20_260_905_000_002, log: false)
    %{options: options}
  end

  test "legacy senior cash and lots precede durable funding by retained type and commit order", %{
    options: options
  } do
    old_group("late-source", [100], cash_converted_to_credit_cents: 100, status: "cancelled")
    old_group("early-source", [200], cash_converted_to_credit_cents: 200, status: "cancelled")
    lot(1, "late-source", "legacy-late", "2028-12-01", 110, 10)
    lot(2, "early-source", "legacy-early", "2028-06-01", 220, 110)

    old_group("group-81", [100, 100, 100, 100, 100],
      deposit_paid_cents: 480,
      credit_paid_cents: 210
    )

    old_credit("group-81", 1, 100)
    old_credit("group-81", 2, 110)
    first = remembered("z-first", "record_cash_payment", "group-81", 120, "2027-12-01")
    remembered("a-credit", "apply_hotel_credit", "group-81", 60, "2027-02-01")
    second = remembered("b-last", "record_cash_payment", "group-81", 100, "2026-01-01")
    remembered("rejected", "record_cash_payment", "group-81", 900, "2026-01-01", "rejected")
    audit = Repo.all(Operation)
    before = balances()
    upgrade()
    assert balances() == before

    assert Enum.map(
             GroupStay.get_group("group-81").rooms,
             &{&1.cash_paid_cents, &1.credit_paid_cents}
           ) ==
             [{50, 50}, {0, 100}, {100, 0}, {40, 60}, {80, 0}]

    assert GroupStay.ledger(~D[2027-12-01]).credit_liability_cents == 330
    assert {:ok, %{recorded_cents: 120, held_cents: 120}} = GroupStay.get_payment("z-first")
    assert Repo.all(Operation) == audit

    assert GroupStay.submit_operations([first, second]) ==
             Enum.map([Enum.at(audit, 0), Enum.at(audit, 2)], &Operation.replay_result/1)

    assert [%{cancelled_room_ids: ["r-0", "r-2"], refunded_cents: 150}] =
             GroupStay.submit_operations([
               operation("cancel_rooms", %{"room_ids" => ["r-2", "r-0"]})
             ])

    assert {:ok, %{held_cents: 20, refunded_cents: 100}} = GroupStay.get_payment("z-first")

    assert [%{amount_cents: 20}] =
             GroupStay.submit_operations([
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => "z-first",
                 "amount_cents" => 20
               })
             ])

    assert {:ok, %{held_cents: 0, refunded_cents: 100, reduced_cents: 20}} =
             GroupStay.get_payment("z-first")

    assert {:ok, %{held_cents: 100}} = GroupStay.get_payment("b-last")

    assert [%{code: "operation_not_found"}] =
             GroupStay.submit_operations([
               operation("reduce_cash_payment", %{
                 "payment_operation_id" => "legacy-cash",
                 "amount_cents" => 1
               })
             ])

    expected =
      {GroupStay.get_group("group-81"), GroupStay.get_payment("z-first"),
       GroupStay.ledger(~D[2027-12-01])}

    stop_supervised!(__MODULE__)
    start_supervised!(Supervisor.child_spec({Repo, options}, id: __MODULE__))
    assert upgrade() == []

    assert {GroupStay.get_group("group-81"), GroupStay.get_payment("z-first"),
            GroupStay.ledger(~D[2027-12-01])} == expected
  end

  test "previously settled payments reconcile and converted entitlements include senior legacy cash" do
    old_group("group-81", [5, 5, 5], cash_converted_to_credit_cents: 15, status: "cancelled")
    lot(1, "group-81", "legacy-conversion", "2027-11-26", 17, 7)
    old_group("target", [10], deposit_paid_cents: 10, credit_paid_cents: 10)
    old_credit("target", 1, 10)
    remembered("first", "record_cash_payment", "group-81", 5, "2026-11-26")
    remembered("second", "record_cash_payment", "group-81", 5, "2026-01-01")

    for {id, field} <- [{"refunded", :cash_refunded_cents}, {"retained", :cash_retained_cents}] do
      old_group(id, [100], [{field, 100}, {:status, "cancelled"}])
      remembered("pay-#{id}", "record_cash_payment", id, 60, "2026-11-26")
    end

    before = balances()
    upgrade()
    assert balances() == before
    assert GroupStay.get_group("group-81").lodging_total_cents == 0
    assert {:ok, %{converted_to_credit_cents: 5, held_cents: 0}} = GroupStay.get_payment("first")
    assert {:ok, %{refunded_cents: 60}} = GroupStay.get_payment("pay-refunded")
    assert {:ok, %{retained_cents: 60}} = GroupStay.get_payment("pay-retained")
    target = GroupStay.get_group("target")

    GroupStay.submit_operations([
      operation("charge_back_payment", %{"payment_operation_id" => "first"})
    ])

    assert GroupStay.guest_credit("guest-22", ~D[2026-11-26]).available_cents == 2

    GroupStay.submit_operations([
      operation("charge_back_payment", %{"payment_operation_id" => "second"})
    ])

    assert GroupStay.ledger(~D[2026-11-26]).credit_shortfall_cents == 4
    assert GroupStay.ledger(~D[2026-11-26]).credit_liability_cents == 10
    assert GroupStay.get_group("target") == target
    GroupStay.submit_operations([operation("cancel_group", %{"group_id" => "target"})])
    assert GroupStay.guest_credit("guest-22", ~D[2026-11-26]).available_cents == 6
    assert GroupStay.ledger(~D[2026-11-26]).credit_shortfall_cents == 0

    GroupStay.submit_operations(
      for id <- ~w(refunded retained),
          do: operation("charge_back_payment", %{"payment_operation_id" => "pay-#{id}"})
    )

    assert GroupStay.ledger().cash_refunded_cents == 40
    assert GroupStay.ledger().cash_retained_cents == 40
    assert GroupStay.ledger().cash_charged_back_cents == 130
  end

  test "credit cannot be assigned to a lot issued after the recorded application" do
    old_group("old-source", [100], cash_converted_to_credit_cents: 100, status: "cancelled")
    old_group("new-source", [100], cash_converted_to_credit_cents: 100, status: "cancelled")
    lot(1, "old-source", "old-lot", "2028-11-26", 110, 60)
    lot(2, "new-source", "new-lot", "2027-11-26", 110, 60)
    old_group("group-81", [50, 50], deposit_paid_cents: 100, credit_paid_cents: 100)
    old_credit("group-81", 1, 50)
    old_credit("group-81", 2, 50)
    remembered("credit-first", "apply_hotel_credit", "group-81", 50, "2026-11-26")
    remembered("new-lot", "cancel_group", "new-source", 0, "2026-11-26")
    remembered("credit-last", "apply_hotel_credit", "group-81", 50, "2026-11-26")
    upgrade()

    GroupStay.submit_operations([
      operation("cancel_rooms", %{"room_ids" => ["r-0"], "occurred_on" => "2028-01-01"})
      |> Map.put("occurred_on", "2026-11-26")
    ])

    assert Repo.query!("SELECT remaining_cents FROM credit_lots ORDER BY id").rows == [
             [110],
             [60]
           ]
  end

  test "legacy reconstruction reserves unexpired lots needed by a later recorded application" do
    old_group("late-source", [100], cash_converted_to_credit_cents: 100, status: "cancelled")
    old_group("early-source", [100], cash_converted_to_credit_cents: 100, status: "cancelled")
    lot(1, "late-source", "legacy-late", "2028-12-01", 110, 10)
    lot(2, "early-source", "legacy-early", "2027-06-01", 110, 60)
    old_group("group-81", [50, 50, 50], deposit_paid_cents: 150, credit_paid_cents: 150)
    old_credit("group-81", 1, 100)
    old_credit("group-81", 2, 50)
    remembered("credit", "apply_hotel_credit", "group-81", 50, "2027-12-01")
    before = balances()
    upgrade()
    assert balances() == before
    GroupStay.submit_operations([operation("cancel_rooms", %{"room_ids" => ["r-1"]})])

    assert Repo.query!("SELECT remaining_cents FROM credit_lots ORDER BY id").rows == [
             [10],
             [110]
           ]

    GroupStay.submit_operations([operation("cancel_rooms", %{"room_ids" => ["r-2"]})])

    assert Repo.query!("SELECT remaining_cents FROM credit_lots ORDER BY id").rows == [
             [60],
             [110]
           ]
  end

  test "room-accounting databases upgrade without balance changes and transfer legacy provenance" do
    old_group("issuer", [100], cash_converted_to_credit_cents: 100, status: "cancelled")
    lot(1, "issuer", "legacy-lot", "2027-11-26", 110, 30)
    old_group("group-81", [100, 100], deposit_paid_cents: 200, credit_paid_cents: 80)
    old_credit("group-81", 1, 80)
    old_group("destination", [100, 100], [])
    remembered("pay", "record_cash_payment", "group-81", 70, "2026-11-26")

    Ecto.Migrator.run(Repo, @migrations, :up, to: 20_260_905_000_003, log: false)
    before_balances = balances()
    before_rows = Repo.query!("SELECT * FROM room_allocations ORDER BY id").rows
    before_audit = Repo.all(Operation)
    upgrade()
    assert balances() == before_balances
    assert Repo.all(Operation) == before_audit

    assert Repo.query!("SELECT * FROM room_allocations ORDER BY id").rows ==
             Enum.map(before_rows, &(&1 ++ [0]))

    assert {:ok, statement} = GroupStay.get_payment("pay")
    refute Map.has_key?(statement, :held_by_group)

    for amount <- [150, 50] do
      assert [%{status: "applied"}] =
               GroupStay.submit_operations([
                 operation("transfer_deposit", %{
                   "source_group_id" => "group-81",
                   "destination_group_id" => "destination",
                   "amount_cents" => amount
                 })
               ])
    end

    assert GroupStay.get_group("group-81").deposit_paid_cents == 0
    assert GroupStay.get_group("destination").cash_paid_cents == 120
    assert GroupStay.get_group("destination").credit_paid_cents == 80

    assert {:ok, %{held_by_group: [%{group_id: "destination", amount_cents: 70}]}} =
             GroupStay.get_payment("pay")

    assert [%{credit_issued_cents: 132}] =
             GroupStay.submit_operations([
               operation("cancel_group", %{
                 "group_id" => "destination",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert GroupStay.guest_credit("guest-22", ~D[2026-11-26]).available_cents == 242

    GroupStay.submit_operations([
      operation("charge_back_payment", %{"payment_operation_id" => "pay"})
    ])

    # The senior legacy principal keeps its 55-cent entitlement; only the payment's 77 is revoked.
    assert GroupStay.guest_credit("guest-22", ~D[2026-11-26]).available_cents == 165
    assert {:ok, %{held_by_group: [], charged_back_cents: 70}} = GroupStay.get_payment("pay")
  end

  defp upgrade, do: Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)

  defp old_group(id, deposits, overrides) do
    status = Keyword.get(overrides, :status, "active")
    due = if status == "active", do: Enum.sum(deposits), else: 0

    base = %{
      group_id: id,
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: "2026-10-03",
      arrival_on: "2026-12-10",
      departure_on: "2026-12-11",
      rate_plan: "flexible",
      policy_version: "flex-14",
      status: status,
      revision: 7,
      lodging_total_cents: Enum.sum(deposits) * 5,
      deposit_due_cents: due,
      deposit_paid_cents: 0,
      credit_paid_cents: 0,
      cash_refunded_cents: 0,
      cash_retained_cents: 0,
      cash_converted_to_credit_cents: 0
    }

    insert("groups", Map.merge(base, Map.new(overrides)))

    for {due, position} <- Enum.with_index(deposits) do
      insert("rooms", %{
        group_id: id,
        room_id: "r-#{position}",
        position: position,
        nightly_rate_cents: due * 5
      })
    end
  end

  defp lot(id, group, source, expiry, issued, remaining) do
    insert("credit_lots", %{
      id: id,
      guest_id: "guest-22",
      source_group_id: group,
      source_operation_id: source,
      expires_on: expiry,
      issued_cents: issued,
      remaining_cents: remaining
    })
  end

  defp old_credit(group, lot, amount),
    do: insert("credit_allocations", %{group_id: group, credit_lot_id: lot, amount_cents: amount})

  defp remembered(id, type, group, amount, occurred, status \\ "applied") do
    payload =
      operation(type, %{
        "operation_id" => id,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => occurred
      })

    Repo.insert!(%Operation{
      operation_id: id,
      type: type,
      payload: payload,
      result: %{
        "operation_id" => id,
        "status" => status,
        "group_id" => group,
        "amount_cents" => amount,
        "revision" => 7,
        "outstanding_deposit_cents" => 0
      }
    })

    payload
  end

  defp balances do
    {
      Repo.query!(
        "SELECT group_id, deposit_paid_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents, revision FROM groups ORDER BY group_id"
      ).rows,
      Repo.query!("SELECT id, issued_cents, remaining_cents FROM credit_lots ORDER BY id").rows
    }
  end

  defp insert(table, values) do
    {columns, values} = Enum.unzip(values)

    Repo.query!(
      "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{Enum.map_join(values, ", ", fn _ -> "?" end)})",
      values
    )
  end
end
